package sbi

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestCallFunction_Success(t *testing.T) {
	expected := map[string]string{"status": "ok", "value": "42"}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/test-func" {
			t.Errorf("path = %s, want /test-func", r.URL.Path)
		}
		if r.Method != http.MethodPost {
			t.Errorf("method = %s, want POST", r.Method)
		}
		if ct := r.Header.Get("Content-Type"); ct != "application/json" {
			t.Errorf("content-type = %s, want application/json", ct)
		}

		// Verify the payload was sent correctly
		var payload map[string]string
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Errorf("decode request body: %v", err)
		}
		if payload["key"] != "val" {
			t.Errorf("payload[key] = %s, want val", payload["key"])
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(expected)
	}))
	defer srv.Close()

	client := NewClientWithTemplate(srv.URL + "/%s")
	var result map[string]string
	if err := client.CallFunction("test-func", map[string]string{"key": "val"}, &result); err != nil {
		t.Fatalf("CallFunction: %v", err)
	}
	if result["status"] != "ok" {
		t.Errorf("result[status] = %s, want ok", result["status"])
	}
	if result["value"] != "42" {
		t.Errorf("result[value] = %s, want 42", result["value"])
	}
}

func TestCallFunction_NilResult(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	client := NewClientWithTemplate(srv.URL + "/%s")
	if err := client.CallFunction("fire-and-forget", map[string]string{}, nil); err != nil {
		t.Fatalf("CallFunction with nil result: %v", err)
	}
}

func TestCallFunction_ServerError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		w.Write([]byte("internal error"))
	}))
	defer srv.Close()

	client := NewClientWithTemplate(srv.URL + "/%s")
	var result map[string]string
	err := client.CallFunction("failing-func", map[string]string{}, &result)
	if err == nil {
		t.Fatal("expected error for 500 response")
	}
	if got := err.Error(); got == "" {
		t.Error("error message should not be empty")
	}
}

func TestCallFunction_ConnectionRefused(t *testing.T) {
	client := NewClientWithTemplate("http://127.0.0.1:1/%s") // nothing listening
	err := client.CallFunction("unreachable", map[string]string{}, nil)
	if err == nil {
		t.Fatal("expected error for unreachable server")
	}
}

func TestNewClient_DefaultTemplate(t *testing.T) {
	t.Setenv("FUNCTION_URL_TEMPLATE", "")
	t.Setenv("FUNCTION_NAMESPACE", "")
	t.Setenv("CLUSTER_DOMAIN", "")
	client := NewClient()
	if client.urlTemplate != "http://%s.default.svc.cluster.local" {
		t.Errorf("default template = %s, want http://%%s.default.svc.cluster.local", client.urlTemplate)
	}
}

func TestNewClient_EnvTemplate(t *testing.T) {
	t.Setenv("FUNCTION_URL_TEMPLATE", "http://%s.functions.svc.cluster.local")
	client := NewClient()
	if client.urlTemplate != "http://%s.functions.svc.cluster.local" {
		t.Errorf("template = %s, want http://%%s.functions.svc.cluster.local", client.urlTemplate)
	}
}
