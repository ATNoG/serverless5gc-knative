// Package sbi provides the inter-NF communication client for the serverless 5GC.
// In the Function-per-Procedure architecture, each procedure runs as a Knative
// Service and calls other procedures using HTTP POST with JSON payloads. This
// mirrors the 3GPP Service-Based Interface (SBI) pattern where NFs communicate
// via RESTful HTTP/2 APIs (TS 29.500).
package sbi

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
)

// Client calls other NF procedure services.
type Client struct {
	urlTemplate string
	httpClient  *http.Client
}

// NewClient creates an SBI client using FUNCTION_URL_TEMPLATE, or the Knative
// in-cluster service DNS pattern when unset.
func NewClient() *Client {
	return &Client{urlTemplate: DefaultURLTemplate(), httpClient: &http.Client{}}
}

// DefaultURLTemplate returns the function URL template for the current process.
// The template must include one %s placeholder for the function name.
func DefaultURLTemplate() string {
	if tmpl := os.Getenv("FUNCTION_URL_TEMPLATE"); tmpl != "" {
		return tmpl
	}
	namespace := os.Getenv("FUNCTION_NAMESPACE")
	if namespace == "" {
		namespace = "default"
	}
	clusterDomain := os.Getenv("CLUSTER_DOMAIN")
	if clusterDomain == "" {
		clusterDomain = "cluster.local"
	}
	return fmt.Sprintf("http://%%s.%s.svc.%s", namespace, clusterDomain)
}

// NewClientWithTemplate creates an SBI client with an explicit URL template.
func NewClientWithTemplate(urlTemplate string) *Client {
	return &Client{urlTemplate: urlTemplate, httpClient: &http.Client{}}
}

// CallFunction invokes another procedure service by name.
func (c *Client) CallFunction(funcName string, payload interface{}, result interface{}) error {
	body, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("marshal payload: %w", err)
	}

	url := fmt.Sprintf(c.urlTemplate, funcName)
	resp, err := c.httpClient.Post(url, "application/json", bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("call %s: %w", funcName, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		errBody, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("%s returned %d: %s", funcName, resp.StatusCode, errBody)
	}

	if result != nil {
		return json.NewDecoder(resp.Body).Decode(result)
	}
	return nil
}
