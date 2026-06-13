// Package function provides the small HTTP runtime used by the Knative services.
// Procedure handlers stay framework-agnostic by accepting Request and returning
// Response, while this package adapts them to net/http, Prometheus metrics, and
// optional Knative Eventing delivery through K_SINK.
package function

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"sync/atomic"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Request is the normalized input passed to procedure handlers.
type Request struct {
	Body        []byte
	Header      http.Header
	QueryString string
	Method      string
	Host        string
	Path        string

	ctx context.Context
}

// WithContext attaches a context to the request.
func (r *Request) WithContext(ctx context.Context) {
	r.ctx = ctx
}

// Context returns the request context, or context.Background when unset.
func (r Request) Context() context.Context {
	if r.ctx == nil {
		return context.Background()
	}
	return r.ctx
}

// Response is the normalized output returned by procedure handlers.
type Response struct {
	StatusCode int
	Body       []byte
	Header     http.Header
}

// Handler is a procedure handler.
type Handler func(Request) (Response, error)

var (
	invocations = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "serverless5gc_function_invocations_total",
		Help: "Total procedure function invocations served by the Knative runtime.",
	}, []string{"function_name", "status_code"})

	duration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "serverless5gc_function_duration_seconds",
		Help:    "Procedure function handler duration in seconds.",
		Buckets: prometheus.DefBuckets,
	}, []string{"function_name", "status_code"})

	eventSeq        uint64
	eventHTTPClient = &http.Client{Timeout: 2 * time.Second}
)

// Serve starts an HTTP server for a single procedure function.
func Serve(functionName string, handler Handler) {
	mux := http.NewServeMux()
	mux.HandleFunc("/", WrapNamed(functionName, handler))
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	})
	mux.Handle("/metrics", promhttp.Handler())

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	addr := ":" + port
	log.Printf("%s listening on %s", functionName, addr)
	log.Fatal(http.ListenAndServe(addr, mux))
}

// WrapNamed adapts a procedure handler to an http.HandlerFunc.
func WrapNamed(functionName string, handler Handler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		resp, err := callHandler(r, handler)
		if err != nil {
			resp = Response{
				StatusCode: http.StatusInternalServerError,
				Body:       []byte(fmt.Sprintf("handler error: %s", err)),
				Header:     http.Header{"Content-Type": []string{"text/plain; charset=utf-8"}},
			}
		}
		if resp.StatusCode == 0 {
			resp.StatusCode = http.StatusOK
		}

		for k, vals := range resp.Header {
			for _, v := range vals {
				w.Header().Add(k, v)
			}
		}
		w.WriteHeader(resp.StatusCode)
		w.Write(resp.Body)

		status := fmt.Sprintf("%d", resp.StatusCode)
		elapsed := time.Since(start)
		invocations.WithLabelValues(functionName, status).Inc()
		duration.WithLabelValues(functionName, status).Observe(elapsed.Seconds())
		emitInvocationEvent(functionName, r, resp.StatusCode, elapsed)
	}
}

func callHandler(r *http.Request, handler Handler) (Response, error) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		return Response{}, fmt.Errorf("read body: %w", err)
	}
	defer r.Body.Close()

	req := Request{
		Body:        body,
		Header:      r.Header,
		QueryString: r.URL.RawQuery,
		Method:      r.Method,
		Host:        r.Host,
		Path:        r.URL.Path,
	}
	req.WithContext(r.Context())

	return handler(req)
}

func emitInvocationEvent(functionName string, r *http.Request, statusCode int, elapsed time.Duration) {
	sink := os.Getenv("K_SINK")
	if sink == "" {
		return
	}
	go emitCloudEvent(sink, "dev.serverless5gc.function.invoked", "/serverless5gc/function/"+functionName, map[string]interface{}{
		"function":    functionName,
		"method":      r.Method,
		"path":        r.URL.Path,
		"status_code": statusCode,
		"duration_ms": float64(elapsed.Microseconds()) / 1000.0,
	})
}

// EmitCloudEvent sends a best-effort binary-mode CloudEvent to the given sink.
func EmitCloudEvent(eventType, source string, data interface{}) {
	sink := os.Getenv("K_SINK")
	if sink == "" {
		return
	}
	go emitCloudEvent(sink, eventType, source, data)
}

func emitCloudEvent(sink, eventType, source string, data interface{}) {
	body, err := json.Marshal(data)
	if err != nil {
		log.Printf("encode cloudevent %s: %v", eventType, err)
		return
	}

	req, err := http.NewRequest(http.MethodPost, sink, bytes.NewReader(body))
	if err != nil {
		log.Printf("create cloudevent request: %v", err)
		return
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Ce-Specversion", "1.0")
	req.Header.Set("Ce-Type", eventType)
	req.Header.Set("Ce-Source", source)
	req.Header.Set("Ce-Id", fmt.Sprintf("%d-%d", time.Now().UnixNano(), atomic.AddUint64(&eventSeq, 1)))
	req.Header.Set("Ce-Time", time.Now().UTC().Format(time.RFC3339Nano))

	if overrides := os.Getenv("K_CE_OVERRIDES"); overrides != "" {
		applyCloudEventOverrides(req.Header, overrides)
	}

	resp, err := eventHTTPClient.Do(req)
	if err != nil {
		log.Printf("send cloudevent %s: %v", eventType, err)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		log.Printf("send cloudevent %s returned %d", eventType, resp.StatusCode)
	}
}

func applyCloudEventOverrides(header http.Header, raw string) {
	var parsed map[string]interface{}
	if err := json.Unmarshal([]byte(raw), &parsed); err != nil {
		log.Printf("parse K_CE_OVERRIDES: %v", err)
		return
	}
	for k, v := range parsed {
		key := strings.TrimSpace(k)
		if key == "" {
			continue
		}
		header.Set("Ce-"+key, fmt.Sprint(v))
	}
}
