package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"sync"
	"time"

	"cloud.google.com/go/pubsub"
)

// PubSubMessage is the payload of a Pub/Sub event.
type PubSubMessage struct {
	Data []byte `json:"data"`
}

// PushRequest represents the request body from Pub/Sub push subscription
type PushRequest struct {
	Message PubSubMessage `json:"message"`
}

// InputMessage is the expected format of the data within the input Pub/Sub message.
type InputMessage struct {
	Domain string `json:"domain"`
	UID    string `json:"uid,omitempty"`
}

// URLMessage is the structure for the message published to the next Pub/Sub topic.
type URLMessage struct {
	URL    string `json:"url"`
	UID    string `json:"uid"`
	Domain string `json:"domain"`
}

// firecrawlRequest is the request sent to the Firecrawl API.
type firecrawlRequest struct {
	URL               string `json:"url"`
	IncludeSubdomains bool   `json:"includeSubdomains"`
}

// firecrawlResponse is the response received from the Firecrawl API.
type firecrawlResponse struct {
	Links []string `json:"links"`
}

var (
	projectID       string
	topicID         string
	firecrawlAPIKey string
	firecrawlAPIURL = "https://api.firecrawl.dev/v1/map"
)

func init() {
	projectID = os.Getenv("PROJECT_ID")
	topicID = os.Getenv("URL_TOPIC_ID")
	firecrawlAPIKey = os.Getenv("FIRECRAWL_API_KEY")

	if projectID == "" || topicID == "" || firecrawlAPIKey == "" {
		log.Fatal("Missing required environment variables (PROJECT_ID, URL_TOPIC_ID, FIRECRAWL_API_KEY)")
	}
}

// generateUID creates a unique identifier if one wasn't provided
func generateUID() string {
	// Generate 4 random bytes for uniqueness
	bytes := make([]byte, 4)
	rand.Read(bytes)
	randomHex := hex.EncodeToString(bytes)
	
	// Format: auto-{unix-timestamp}-{random-hex}
	return fmt.Sprintf("auto-%d-%s", time.Now().Unix(), randomHex)
}

// ProcessPubSubPush is the entry point for the Cloud Function.
// It's triggered by a message on a Pub/Sub topic.
func ProcessPubSubPush(ctx context.Context, m PubSubMessage) error {
	var d InputMessage
	if err := json.Unmarshal(m.Data, &d); err != nil {
		log.Printf("failed to unmarshal message data: %v", err)
		// Return nil to acknowledge the message and prevent retries for malformed data.
		return nil
	}

	if d.Domain == "" {
		log.Printf("Domain is empty in message, acknowledging to avoid retry.")
		return nil
	}

	// Generate UID if not provided
	if d.UID == "" {
		d.UID = generateUID()
		log.Printf("Generated UID for domain %s: %s", d.Domain, d.UID)
	}

	log.Printf("Received crawl request for domain: %s, UID: %s", d.Domain, d.UID)

	apiResponse, err := callFirecrawlAPI(ctx, firecrawlAPIKey, d.Domain, true)
	if err != nil {
		log.Printf("Error calling Firecrawl API for domain %s (UID: %s): %v", d.Domain, d.UID, err)
		// Return the error to signal that the function failed and should be retried.
		return err
	}

	if err := publishLinks(ctx, apiResponse.Links, d.UID, d.Domain); err != nil {
		log.Printf("Error publishing links for domain %s (UID: %s): %v", d.Domain, d.UID, err)
		return err
	}

	log.Printf("Successfully published %d URLs for domain %s (UID: %s) to topic %s", len(apiResponse.Links), d.Domain, d.UID, topicID)
	return nil
}

// publishLinks publishes a list of URLs to the Pub/Sub topic.
func publishLinks(ctx context.Context, links []string, uid string, domain string) error {
	client, err := pubsub.NewClient(ctx, projectID)
	if err != nil {
		return fmt.Errorf("failed to create pubsub client: %w", err)
	}
	defer client.Close()

	topic := client.Topic(topicID)
	defer topic.Stop()

	var wg sync.WaitGroup
	var errs []error
	var mu sync.Mutex

	for _, link := range links {
		wg.Add(1)
		go func(l string) {
			defer wg.Done()
			msgData, err := json.Marshal(URLMessage{
				URL:    l,
				UID:    uid,
				Domain: domain,
			})
			if err != nil {
				mu.Lock()
				errs = append(errs, fmt.Errorf("failed to marshal message for %s: %w", l, err))
				mu.Unlock()
				return
			}

			res := topic.Publish(ctx, &pubsub.Message{Data: msgData})
			if _, err := res.Get(ctx); err != nil {
				mu.Lock()
				errs = append(errs, fmt.Errorf("failed to publish message for %s: %w", l, err))
				mu.Unlock()
				log.Printf("Failed to publish message for %s: %v", l, err)
			}
		}(link)
	}

	wg.Wait()

	if len(errs) > 0 {
		return fmt.Errorf("encountered %d errors while publishing. First error: %w", len(errs), errs[0])
	}

	return nil
}

// callFirecrawlAPI encapsulates the logic for calling the external API.
func callFirecrawlAPI(ctx context.Context, apiKey, url string, includeSubdomains bool) (*firecrawlResponse, error) {
	reqBody := firecrawlRequest{
		URL:               url,
		IncludeSubdomains: includeSubdomains,
	}

	jsonBody, err := json.Marshal(reqBody)
	if err != nil {
		return nil, fmt.Errorf("failed to create Firecrawl request body: %w", err)
	}

	client := &http.Client{}
	firecrawlReq, err := http.NewRequestWithContext(ctx, "POST", firecrawlAPIURL, bytes.NewBuffer(jsonBody))
	if err != nil {
		return nil, fmt.Errorf("failed to create Firecrawl request: %w", err)
	}

	firecrawlReq.Header.Set("Content-Type", "application/json")
	firecrawlReq.Header.Set("Authorization", "Bearer "+apiKey)

	resp, err := client.Do(firecrawlReq)
	if err != nil {
		return nil, fmt.Errorf("failed to call Firecrawl API: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		bodyBytes, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("firecrawl API request failed with status %d: %s", resp.StatusCode, string(bodyBytes))
	}

	var apiResp firecrawlResponse
	if err := json.NewDecoder(resp.Body).Decode(&apiResp); err != nil {
		return nil, fmt.Errorf("failed to decode Firecrawl response: %w", err)
	}

	return &apiResp, nil
}

// httpHandler wraps the Cloud Function logic for Cloud Run
func httpHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		http.Error(w, "Only POST method allowed", http.StatusMethodNotAllowed)
		return
	}

	var pushReq PushRequest
	if err := json.NewDecoder(r.Body).Decode(&pushReq); err != nil {
		log.Printf("Failed to decode push request: %v", err)
		http.Error(w, "Invalid request body", http.StatusBadRequest)
		return
	}

	// Decode base64 data if needed
	var data []byte
	if len(pushReq.Message.Data) > 0 {
		// Try base64 decode first (Pub/Sub sends base64 encoded data)
		decodedData, err := base64.StdEncoding.DecodeString(string(pushReq.Message.Data))
		if err != nil {
			// If base64 decode fails, use raw data
			data = pushReq.Message.Data
		} else {
			data = decodedData
		}
	}

	message := PubSubMessage{Data: data}
	ctx := r.Context()

	if err := ProcessPubSubPush(ctx, message); err != nil {
		log.Printf("Error processing message: %v", err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)
		return
	}

	w.WriteHeader(http.StatusOK)
	w.Write([]byte("OK"))
}

func main() {
	http.HandleFunc("/", httpHandler)
	log.Println("URL Mapper server starting on port 8080...")
	if err := http.ListenAndServe(":8080", nil); err != nil {
		log.Fatal(err)
	}
}
