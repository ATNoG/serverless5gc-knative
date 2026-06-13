// The sctp-proxy binary bridges the N2 interface (SCTP/NGAP, TS 38.412) between
// UERANSIM (or any 3GPP-compliant gNB) and the serverless 5GC backend running on
// Knative. It terminates the SCTP association from the gNB, decodes NGAP messages,
// extracts NAS PDUs, and forwards procedure calls as HTTP/JSON to the appropriate
// Knative Services.
//
// The proxy maintains a per-UE state machine (keyed by RAN-UE-NGAP-ID) to track
// the signaling flow: NG Setup → Registration → Authentication → Security Mode →
// PDU Session Establishment. NAS security (integrity protection via 128-EIA2) is
// applied to all downlink messages after Security Mode Command.
//
// Configuration via environment variables:
//
//	SCTP_LISTEN_ADDR  - SCTP listen address (default: 0.0.0.0:38412)
//	FUNCTION_URL_TEMPLATE - URL template with one %s function placeholder
//	FUNCTION_NAMESPACE    - namespace for default Knative service DNS (default: default)
//	CLUSTER_DOMAIN        - Kubernetes cluster DNS domain (default: cluster.local)
//	REDIS_ADDR            - Redis address for reading auth vectors (default: localhost:6379)
//	PLMN_MCC              - PLMN Mobile Country Code (default: 001)
//	PLMN_MNC              - PLMN Mobile Network Code (default: 01)
//	SNSSAI_SD             - S-NSSAI Slice Differentiator hex (default: 010203)
package main

import (
	"encoding/hex"
	"fmt"
	"log"
	"os"

	"github.com/haidinhtuan/serverless5gc/pkg/function"
	ngapCodec "github.com/haidinhtuan/serverless5gc/pkg/ngap"
	"github.com/haidinhtuan/serverless5gc/pkg/state"
)

func main() {
	listenAddr := os.Getenv("SCTP_LISTEN_ADDR")
	if listenAddr == "" {
		listenAddr = "0.0.0.0:38412"
	}
	functionURLTemplate := defaultFunctionURLTemplate()
	redisAddr := os.Getenv("REDIS_ADDR")
	if redisAddr == "" {
		redisAddr = "localhost:6379"
	}

	// Eval config: PLMN 001/01, S-NSSAI SST=1, SD=010203
	mcc := os.Getenv("PLMN_MCC")
	if mcc == "" {
		mcc = "001"
	}
	mnc := os.Getenv("PLMN_MNC")
	if mnc == "" {
		mnc = "01"
	}
	sdHex := os.Getenv("SNSSAI_SD")
	if sdHex == "" {
		sdHex = "010203"
	}

	plmn := ngapCodec.PLMNBytes(mcc, mnc)
	sd, _ := hex.DecodeString(sdHex)
	backend := NewHTTPBackend(functionURLTemplate)
	store := state.NewRedisStore(redisAddr)

	proxy := NewSCTPProxy(listenAddr, backend, store, plmn, 0x01, sd)
	log.Printf("Function URL template: %s", functionURLTemplate)
	function.EmitCloudEvent("dev.serverless5gc.proxy.started", "/serverless5gc/sctp-proxy", map[string]string{
		"listen_addr":           listenAddr,
		"function_url_template": functionURLTemplate,
	})
	log.Fatal(proxy.Start())
}

func defaultFunctionURLTemplate() string {
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
