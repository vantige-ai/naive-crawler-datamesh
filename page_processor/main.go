package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io/ioutil"
	"log"
	"net/http"
	"os"
	"time"

	"cloud.google.com/go/pubsub"
	md "github.com/JohannesKaufmann/html-to-markdown/v2"
	"github.com/lib4u/fake-useragent"
)

var (
	projectID    string
	topicID      string
	crawlerID    string
	domainToCrawl string
)

func init() {
	projectID = os.Getenv("PROJECT_ID")
	topicID = os.Getenv("OUTPUT_TOPIC_ID")
	crawlerID = os.Getenv("CRAWLER_ID")
	domainToCrawl = os.Getenv("DOMAIN_TO_CRAWL")

	if projectID == "" || topicID == "" {
		log.Fatal("Missing required environment variables (PROJECT_ID, OUTPUT_TOPIC_ID)")
	}
	
	// Set defaults for optional fields
	if crawlerID == "" {
		crawlerID = "unknown"
	}
	if domainToCrawl == "" {
		domainToCrawl = "unknown"
	}
}

// PubSubMessage is the payload of a Pub/Sub event.
type PubSubMessage struct {
	Data []byte `json:"data"`
}

// PushRequest represents the request body from Pub/Sub push subscription
type PushRequest struct {
	Message PubSubMessage `json:"message"`
}

// InputMessage is the expected format of the data within the Pub/Sub message.
type InputMessage struct {
	URL    string `json:"url"`
	UID    string `json:"uid"`
	Domain string `json:"domain"`
}

// OutputMessage is the message that will be published to the output topic.
type OutputMessage struct {
	URL       string    `json:"url"`
	Markdown  string    `json:"markdown"`
	Timestamp time.Time `json:"timestamp"`
	CrawlerID string    `json:"crawler_id"`
	Domain    string    `json:"domain"`
	UID       string    `json:"uid"`
	Status    string    `json:"status"`
}

// ProcessPubSubPush is the entry point for the Cloud Function.
func ProcessPubSubPush(ctx context.Context, m PubSubMessage) error {
	var d InputMessage
	if err := json.Unmarshal(m.Data, &d); err != nil {
		log.Printf("failed to unmarshal message data: %v", err)
		return nil // Acknowledge and don't retry malformed messages
	}

	if d.URL == "" {
		log.Printf("URL is empty in message")
		return nil // Acknowledge and don't retry empty messages
	}

	// Use domain from message if provided, otherwise fall back to env var
	domain := d.Domain
	if domain == "" {
		domain = domainToCrawl
	}

	// Use UID from message if provided, otherwise use "unknown" for backward compatibility
	uid := d.UID
	if uid == "" {
		uid = "unknown"
	}

	markdown, err := convertURLToMarkdown(d.URL)
	status := "success"
	if err != nil {
		log.Printf("Failed to convert URL to markdown for %s: %v", d.URL, err)
		status = "error"
		markdown = err.Error()
	}

	output := OutputMessage{
		URL:       d.URL,
		Markdown:  markdown,
		Timestamp: time.Now(),
		CrawlerID: crawlerID,
		Domain:    domain,
		UID:       uid,
		Status:    status,
	}

	outputData, err := json.Marshal(output)
	if err != nil {
		log.Printf("Failed to marshal output message for %s: %v", d.URL, err)
		return err // Return error to retry
	}

	client, err := pubsub.NewClient(ctx, projectID)
	if err != nil {
		log.Printf("Failed to create pubsub client: %v", err)
		return err
	}
	defer client.Close()

	topic := client.Topic(topicID)
	res := topic.Publish(ctx, &pubsub.Message{
		Data: outputData,
	})

	if _, err := res.Get(ctx); err != nil {
		log.Printf("Failed to publish message for %s: %v", d.URL, err)
		return err
	}

	log.Printf("Successfully processed and published data for URL: %s (status: %s)", d.URL, status)
	return nil
}

func convertURLToMarkdown(url string) (string, error) {
	httpClient := &http.Client{}
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return "", fmt.Errorf("failed to create request: %v", err)
	}

	// Using a fake user-agent to avoid being blocked by some websites.
	ua, err := fakeUserAgent.New()
	if err != nil {
		// Fallback to a generic user-agent if the library fails
		req.Header.Set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/58.0.3029.110 Safari/537.36")
	} else {
		req.Header.Set("User-Agent", ua.GetRandom())
	}

	resp, err := httpClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("failed to download URL: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("failed to download URL: status code %d", resp.StatusCode)
	}

	html, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("failed to read response body: %v", err)
	}

	markdown, err := md.ConvertString(string(html))
	if err != nil {
		return "", fmt.Errorf("failed to convert HTML to Markdown: %v", err)
	}

	return markdown, nil
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
	log.Println("Page Processor server starting on port 8080...")
	if err := http.ListenAndServe(":8080", nil); err != nil {
		log.Fatal(err)
	}
}
