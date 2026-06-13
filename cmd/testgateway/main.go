package main

import (
	"fmt"
	"io"
	"log"
	"net/http"
	"os"

	handler "github.com/haidinhtuan/serverless5gc/pkg/function"
	"github.com/haidinhtuan/serverless5gc/pkg/sbi"
	"github.com/haidinhtuan/serverless5gc/pkg/state"

	// NRF functions (etcd-backed)
	nrfDiscover "github.com/haidinhtuan/serverless5gc/functions/nrf/discover"
	nrfRegister "github.com/haidinhtuan/serverless5gc/functions/nrf/register"
	nrfStatusNotify "github.com/haidinhtuan/serverless5gc/functions/nrf/status-notify"

	// AMF functions (redis-backed)
	amfAuthInitiate "github.com/haidinhtuan/serverless5gc/functions/amf/auth-initiate"
	amfDeregistration "github.com/haidinhtuan/serverless5gc/functions/amf/deregistration"
	amfHandover "github.com/haidinhtuan/serverless5gc/functions/amf/handover"
	amfPduSessionRelay "github.com/haidinhtuan/serverless5gc/functions/amf/pdu-session-relay"
	amfRegistration "github.com/haidinhtuan/serverless5gc/functions/amf/registration"
	amfServiceRequest "github.com/haidinhtuan/serverless5gc/functions/amf/service-request"

	// SMF functions (redis-backed)
	smfN4SessionSetup "github.com/haidinhtuan/serverless5gc/functions/smf/n4-session-setup"
	smfPduSessionCreate "github.com/haidinhtuan/serverless5gc/functions/smf/pdu-session-create"
	smfPduSessionRelease "github.com/haidinhtuan/serverless5gc/functions/smf/pdu-session-release"
	smfPduSessionUpdate "github.com/haidinhtuan/serverless5gc/functions/smf/pdu-session-update"

	// UDM functions (redis-backed)
	udmGenerateAuthData "github.com/haidinhtuan/serverless5gc/functions/udm/generate-auth-data"
	udmGetSubscriberData "github.com/haidinhtuan/serverless5gc/functions/udm/get-subscriber-data"

	// UDR functions (redis-backed)
	udrDataRead "github.com/haidinhtuan/serverless5gc/functions/udr/data-read"
	udrDataWrite "github.com/haidinhtuan/serverless5gc/functions/udr/data-write"

	// AUSF functions (redis-backed)
	ausfAuthenticate "github.com/haidinhtuan/serverless5gc/functions/ausf/authenticate"

	// PCF functions (redis-backed)
	pcfPolicyCreate "github.com/haidinhtuan/serverless5gc/functions/pcf/policy-create"
	pcfPolicyGet "github.com/haidinhtuan/serverless5gc/functions/pcf/policy-get"

	// NSSF functions (redis-backed)
	nssfSliceSelect "github.com/haidinhtuan/serverless5gc/functions/nssf/slice-select"

	// NWDAF functions (redis-backed, R17)
	nwdafAnalyticsSubscribe "github.com/haidinhtuan/serverless5gc/functions/nwdaf/analytics-subscribe"
	nwdafDataCollect "github.com/haidinhtuan/serverless5gc/functions/nwdaf/data-collect"

	// CHF functions (redis-backed, R17)
	chfChargingCreate "github.com/haidinhtuan/serverless5gc/functions/chf/charging-create"
	chfChargingRelease "github.com/haidinhtuan/serverless5gc/functions/chf/charging-release"
	chfChargingUpdate "github.com/haidinhtuan/serverless5gc/functions/chf/charging-update"

	// NSACF functions (redis-backed, R17)
	nsacfSliceAvailabilityCheck "github.com/haidinhtuan/serverless5gc/functions/nsacf/slice-availability-check"
	nsacfUpdateCounters "github.com/haidinhtuan/serverless5gc/functions/nsacf/update-counters"

	// BSF functions (redis-backed, R17)
	bsfBindingDeregister "github.com/haidinhtuan/serverless5gc/functions/bsf/binding-deregister"
	bsfBindingDiscover "github.com/haidinhtuan/serverless5gc/functions/bsf/binding-discover"
	bsfBindingRegister "github.com/haidinhtuan/serverless5gc/functions/bsf/binding-register"
)

// wrapHandler converts a procedure handler into a standard http.HandlerFunc.
// It reads the incoming HTTP request, constructs a handler.Request, calls the
// function handler, and writes the handler.Response back to the HTTP response.
func wrapHandler(fn func(handler.Request) (handler.Response, error)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, fmt.Sprintf(`{"error":"read body: %s"}`, err), http.StatusInternalServerError)
			return
		}
		defer r.Body.Close()

		req := handler.Request{
			Body:        body,
			Header:      r.Header,
			QueryString: r.URL.RawQuery,
			Method:      r.Method,
			Host:        r.Host,
		}
		req.WithContext(r.Context())

		resp, err := fn(req)
		if err != nil {
			http.Error(w, fmt.Sprintf(`{"error":"%s"}`, err), http.StatusInternalServerError)
			return
		}

		for k, vals := range resp.Header {
			for _, v := range vals {
				w.Header().Add(k, v)
			}
		}

		if resp.StatusCode == 0 {
			resp.StatusCode = http.StatusOK
		}
		w.WriteHeader(resp.StatusCode)
		w.Write(resp.Body)
	}
}

func main() {
	// Redis store for most functions
	redisAddr := os.Getenv("REDIS_ADDR")
	if redisAddr == "" {
		redisAddr = "redis:6379"
	}
	redisStore := state.NewRedisStore(redisAddr)

	// Etcd store for NRF functions
	etcdEndpoint := os.Getenv("ETCD_ENDPOINT")
	if etcdEndpoint == "" {
		etcdEndpoint = "etcd:2379"
	}
	etcdStore, err := state.NewEtcdStore([]string{etcdEndpoint})
	if err != nil {
		log.Fatalf("Failed to connect to etcd at %s: %v", etcdEndpoint, err)
	}

	// SBI client pointing to this gateway for inter-function calls.
	sbiClient := sbi.NewClientWithTemplate("http://localhost:8080/%s")

	// --- Configure NRF functions (etcd-backed) ---
	nrfRegister.SetStore(etcdStore)
	nrfDiscover.SetStore(etcdStore)
	nrfStatusNotify.SetStore(etcdStore)

	// --- Configure AMF functions (redis-backed) ---
	amfRegistration.SetStore(redisStore)
	amfRegistration.SetSBI(sbiClient)

	amfDeregistration.SetStore(redisStore)
	amfDeregistration.SetSBI(sbiClient)

	amfServiceRequest.SetStore(redisStore)

	amfPduSessionRelay.SetStore(redisStore)
	amfPduSessionRelay.SetSBI(sbiClient)

	amfHandover.SetStore(redisStore)

	amfAuthInitiate.SetStore(redisStore)
	amfAuthInitiate.SetSBI(sbiClient)

	// --- Configure SMF functions (redis-backed) ---
	// PFCP is left nil; handlers skip PFCP operations when nil.
	smfPduSessionCreate.SetStore(redisStore)
	smfPduSessionCreate.SetSBI(sbiClient)

	smfPduSessionUpdate.SetStore(redisStore)

	smfPduSessionRelease.SetStore(redisStore)
	smfPduSessionRelease.SetSBI(sbiClient)

	smfN4SessionSetup.SetStore(redisStore)

	// --- Configure UDM functions (redis-backed) ---
	udmGenerateAuthData.SetStore(redisStore)
	udmGetSubscriberData.SetStore(redisStore)

	// --- Configure UDR functions (redis-backed) ---
	udrDataRead.SetStore(redisStore)
	udrDataWrite.SetStore(redisStore)

	// --- Configure AUSF function (redis-backed) ---
	ausfAuthenticate.SetStore(redisStore)

	// --- Configure PCF functions (redis-backed) ---
	pcfPolicyCreate.SetStore(redisStore)
	pcfPolicyGet.SetStore(redisStore)

	// --- Configure NSSF function (redis-backed) ---
	nssfSliceSelect.SetStore(redisStore)

	// --- Configure NWDAF functions (redis-backed, R17) ---
	nwdafAnalyticsSubscribe.SetStore(redisStore)
	nwdafDataCollect.SetStore(redisStore)

	// --- Configure CHF functions (redis-backed, R17) ---
	chfChargingCreate.SetStore(redisStore)
	chfChargingUpdate.SetStore(redisStore)
	chfChargingRelease.SetStore(redisStore)

	// --- Configure NSACF functions (redis-backed, R17) ---
	nsacfSliceAvailabilityCheck.SetStore(redisStore)
	nsacfUpdateCounters.SetStore(redisStore)

	// --- Configure BSF functions (redis-backed, R17) ---
	bsfBindingRegister.SetStore(redisStore)
	bsfBindingDiscover.SetStore(redisStore)
	bsfBindingDeregister.SetStore(redisStore)

	// --- Register HTTP routes matching Knative service names ---
	mux := http.NewServeMux()

	// Health check for integration test readiness probe
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	})

	// NRF
	mux.HandleFunc("/nrf-register", wrapHandler(nrfRegister.Handle))
	mux.HandleFunc("/nrf-discover", wrapHandler(nrfDiscover.Handle))
	mux.HandleFunc("/nrf-status-notify", wrapHandler(nrfStatusNotify.Handle))

	// AMF
	mux.HandleFunc("/amf-initial-registration", wrapHandler(amfRegistration.Handle))
	mux.HandleFunc("/amf-deregistration", wrapHandler(amfDeregistration.Handle))
	mux.HandleFunc("/amf-service-request", wrapHandler(amfServiceRequest.Handle))
	mux.HandleFunc("/amf-pdu-session-relay", wrapHandler(amfPduSessionRelay.Handle))
	mux.HandleFunc("/amf-handover", wrapHandler(amfHandover.Handle))
	mux.HandleFunc("/amf-auth-initiate", wrapHandler(amfAuthInitiate.Handle))

	// SMF
	mux.HandleFunc("/smf-pdu-session-create", wrapHandler(smfPduSessionCreate.Handle))
	mux.HandleFunc("/smf-pdu-session-update", wrapHandler(smfPduSessionUpdate.Handle))
	mux.HandleFunc("/smf-pdu-session-release", wrapHandler(smfPduSessionRelease.Handle))
	mux.HandleFunc("/smf-n4-session-setup", wrapHandler(smfN4SessionSetup.Handle))

	// UDM
	mux.HandleFunc("/udm-generate-auth-data", wrapHandler(udmGenerateAuthData.Handle))
	mux.HandleFunc("/udm-get-subscriber-data", wrapHandler(udmGetSubscriberData.Handle))

	// UDR
	mux.HandleFunc("/udr-data-read", wrapHandler(udrDataRead.Handle))
	mux.HandleFunc("/udr-data-write", wrapHandler(udrDataWrite.Handle))

	// AUSF
	mux.HandleFunc("/ausf-authenticate", wrapHandler(ausfAuthenticate.Handle))

	// PCF
	mux.HandleFunc("/pcf-policy-create", wrapHandler(pcfPolicyCreate.Handle))
	mux.HandleFunc("/pcf-policy-get", wrapHandler(pcfPolicyGet.Handle))

	// NSSF
	mux.HandleFunc("/nssf-slice-select", wrapHandler(nssfSliceSelect.Handle))

	// NWDAF (R17)
	mux.HandleFunc("/nwdaf-analytics-subscribe", wrapHandler(nwdafAnalyticsSubscribe.Handle))
	mux.HandleFunc("/nwdaf-data-collect", wrapHandler(nwdafDataCollect.Handle))

	// CHF (R17)
	mux.HandleFunc("/chf-charging-create", wrapHandler(chfChargingCreate.Handle))
	mux.HandleFunc("/chf-charging-update", wrapHandler(chfChargingUpdate.Handle))
	mux.HandleFunc("/chf-charging-release", wrapHandler(chfChargingRelease.Handle))

	// NSACF (R17)
	mux.HandleFunc("/nsacf-slice-availability-check", wrapHandler(nsacfSliceAvailabilityCheck.Handle))
	mux.HandleFunc("/nsacf-update-counters", wrapHandler(nsacfUpdateCounters.Handle))

	// BSF (R17)
	mux.HandleFunc("/bsf-binding-register", wrapHandler(bsfBindingRegister.Handle))
	mux.HandleFunc("/bsf-binding-discover", wrapHandler(bsfBindingDiscover.Handle))
	mux.HandleFunc("/bsf-binding-deregister", wrapHandler(bsfBindingDeregister.Handle))

	addr := ":8080"
	log.Printf("Test gateway listening on %s", addr)
	log.Printf("Redis: %s | etcd: %s", redisAddr, etcdEndpoint)
	log.Printf("Registered 31 function handlers")
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}
