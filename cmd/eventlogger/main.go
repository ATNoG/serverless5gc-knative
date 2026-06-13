package main

import (
	"encoding/json"
	"io"
	"log"
	"net/http"
	"os"
)

type cloudEventLog struct {
	ID              string          `json:"id"`
	Type            string          `json:"type"`
	Source          string          `json:"source"`
	Subject         string          `json:"subject,omitempty"`
	DataContentType string          `json:"datacontenttype,omitempty"`
	Data            json.RawMessage `json:"data,omitempty"`
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/", handleEvent)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	})

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	log.Printf("eventlogger listening on :%s", port)
	log.Fatal(http.ListenAndServe(":"+port, mux))
}

func handleEvent(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "read body", http.StatusBadRequest)
		return
	}
	defer r.Body.Close()

	event := cloudEventLog{
		ID:              r.Header.Get("Ce-Id"),
		Type:            r.Header.Get("Ce-Type"),
		Source:          r.Header.Get("Ce-Source"),
		Subject:         r.Header.Get("Ce-Subject"),
		DataContentType: r.Header.Get("Content-Type"),
	}
	if len(body) > 0 && json.Valid(body) {
		event.Data = body
	}

	encoded, _ := json.Marshal(event)
	log.Printf("cloudevent %s", encoded)
	w.WriteHeader(http.StatusAccepted)
}
