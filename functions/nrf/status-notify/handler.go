package function

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"

	handler "github.com/haidinhtuan/serverless5gc/pkg/function"
	"github.com/haidinhtuan/serverless5gc/pkg/models"
	"github.com/haidinhtuan/serverless5gc/pkg/state"
)

// store is the backing KVStore. Set via init() in production; overridden in tests.
var store state.KVStore

// SetStore allows tests to inject a mock store.
func SetStore(s state.KVStore) {
	store = s
}

func init() {
	if store != nil {
		return
	}
	endpoint := os.Getenv("ETCD_ENDPOINT")
	if endpoint == "" {
		endpoint = "localhost:2379"
	}
	etcdStore, err := state.NewEtcdStore([]string{endpoint})
	if err != nil {
		panic(fmt.Sprintf("connect etcd at %s: %v", endpoint, err))
	}
	store = etcdStore
}

// StatusNotification represents an NF status change event per TS 29.510.
type StatusNotification struct {
	NFInstanceID string `json:"nfInstanceId"`
	NFStatus     string `json:"nfStatus"` // REGISTERED, SUSPENDED, UNDISCOVERABLE
}

// Handle processes NF status notifications and updates the NRF registry.
func Handle(req handler.Request) (handler.Response, error) {
	ctx := req.Context()
	if ctx == nil {
		ctx = context.Background()
	}

	var notif StatusNotification
	if err := json.Unmarshal(req.Body, &notif); err != nil {
		return handler.Response{
			StatusCode: http.StatusBadRequest,
			Body:       []byte(fmt.Sprintf(`{"error":"invalid body: %s"}`, err)),
		}, nil
	}

	if notif.NFInstanceID == "" {
		return handler.Response{
			StatusCode: http.StatusBadRequest,
			Body:       []byte(`{"error":"nfInstanceId is required"}`),
		}, nil
	}

	key := fmt.Sprintf("/nrf/nf-instances/%s", notif.NFInstanceID)

	var profile models.NFProfile
	if err := store.Get(ctx, key, &profile); err != nil {
		return handler.Response{
			StatusCode: http.StatusNotFound,
			Body:       []byte(fmt.Sprintf(`{"error":"nf instance not found: %s"}`, err)),
		}, nil
	}

	profile.NFStatus = notif.NFStatus
	if err := store.Put(ctx, key, profile); err != nil {
		return handler.Response{
			StatusCode: http.StatusInternalServerError,
			Body:       []byte(fmt.Sprintf(`{"error":"store put: %s"}`, err)),
		}, nil
	}

	return handler.Response{
		StatusCode: http.StatusNoContent,
	}, nil
}
