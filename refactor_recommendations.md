# Refactoring Recommendations for Serverless Web Crawler

## Table of Contents
1. [Implemented Improvements](#implemented-improvements)
2. [Executive Summary](#executive-summary)
3. [Critical Security Issues](#critical-security-issues)
4. [Infrastructure Improvements](#infrastructure-improvements)
5. [Code Quality Enhancements](#code-quality-enhancements)
6. [Reliability & Resilience](#reliability--resilience)
7. [Performance Optimizations](#performance-optimizations)
8. [Operational Excellence](#operational-excellence)
9. [Cost Optimization](#cost-optimization)
10. [Implementation Roadmap](#implementation-roadmap)

## Implemented Improvements

### ✅ Completed Enhancements (as of July 2025)

The following improvements have been implemented in the deployment scripts:

#### 1. **Deployment Script Enhancements** (`deploy.sh`)
- **Retry Logic**: Services retry deployment up to 3 times on failure
- **Service Readiness Checks**: Waits up to 5 minutes for services to be ready
- **Memory Configuration**: 
  - URL Mapper: 512Mi (default)
  - Page Processor: 1Gi (increased for better performance)
- **Pre-deployment Verification**: Checks all prerequisites before deployment
- **Timeout Handling**: Increased to 60 minutes for long builds
- **Authentication**: Enforces IAM authentication (`--no-allow-unauthenticated`)
- **Comprehensive Output**: Shows deployment summary with all resources

#### 2. **Infrastructure Script Improvements** (`setup_infra.sh`)
- **Error Handling**: Line-number error reporting for debugging
- **BigQuery Resilience**: Continues even if dataset already exists
- **Table Existence Checks**: Verifies tables before creation
- **Resource Verification**: Post-setup verification of all components
- **Manual Configuration Guidance**: Clear instructions for BigQuery write metadata
- **Service Account Fix**: Corrected format to `service-PROJECT_NUMBER@gcp-sa-pubsub.iam.gserviceaccount.com`

#### 3. **Configuration Updates**
- **BigQuery Write Metadata**: Added manual configuration instructions (CLI not supported)
- **Memory Optimization**: Dynamic allocation based on service requirements
- **IAM Security**: All services require authentication by default

#### 4. **Job Tracking Implementation** (NEW - July 2025)
- **UID Functionality**: Added unique job identifiers for tracking crawl jobs
- **Domain Propagation**: Domain field flows through entire pipeline
- **Backward Compatibility**: Supports existing messages without UID
- **Auto-Generation**: Creates UID automatically if not provided
- **BigQuery Analytics**: Enhanced queries for job-level tracking and analytics

### ⚠️ Manual Steps Still Required
1. **BigQuery Write Metadata**: Must be enabled manually in Cloud Console
   - Navigate to subscription settings
   - Enable "Write metadata" checkbox
   - This adds message_id, publish_time, and attributes to BigQuery

## Executive Summary

This document outlines comprehensive refactoring recommendations for the serverless web crawler system. The recommendations are prioritized by impact and urgency, with security issues taking precedence. Each recommendation includes specific implementation details, expected benefits, and potential trade-offs.

### Priority Matrix

| Priority | Category | Effort | Impact |
|----------|----------|--------|--------|
| P0 - Critical | Security vulnerabilities | Low-Medium | Critical |
| P1 - High | Reliability & data integrity | Medium | High |
| P2 - Medium | Performance & operations | Medium-High | Medium |
| P3 - Low | Developer experience | Low | Low |

## Critical Security Issues

### 1. Secret Management (P0)

**Current State**: API keys are hardcoded in `config.sh`

**Recommended Solution**:
```bash
# 1. Create secret in Secret Manager
gcloud secrets create firecrawl-api-key \
  --data-file=- <<< "your-api-key"

# 2. Grant access to service accounts
gcloud secrets add-iam-policy-binding firecrawl-api-key \
  --member="serviceAccount:crawler-basic-mapper-sa@PROJECT.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"

# 3. Update deployment script
gcloud run deploy "$URL_MAPPER_SERVICE_NAME" \
  --set-secrets="FIRECRAWL_API_KEY=firecrawl-api-key:latest"
```

**Code Changes Required**:
- Remove `FIRECRAWL_API_KEY` from config.sh
- Update deploy.sh to use `--set-secrets` instead of `--set-env-vars`
- No application code changes needed (Cloud Run handles secret injection)

**Benefits**:
- Eliminates secret exposure in version control
- Enables secret rotation without redeployment
- Provides audit trail for secret access

### 2. Least Privilege IAM (P0)

**Current State**: BigQuery permissions granted at project level

**Recommended Solution**:
```bash
# 1. Create custom role for Pub/Sub to BigQuery
gcloud iam roles create pubsubBigQueryWriter \
  --project=$PROJECT_ID \
  --title="Pub/Sub to BigQuery Writer" \
  --description="Write access to specific BigQuery tables" \
  --permissions="bigquery.tabledata.create,bigquery.tabledata.update"

# 2. Grant at dataset level instead of project
gcloud alpha bigquery datasets add-iam-policy-binding $BQ_DATASET \
  --member="serviceAccount:service-PROJECT_NUMBER@gcp-sa-pubsub.iam.gserviceaccount.com" \
  --role="projects/$PROJECT_ID/roles/pubsubBigQueryWriter"
```

**Additional Security Hardening**:
```yaml
# Create VPC Service Controls perimeter
accessPolicies:
  - name: "crawler-perimeter"
    servicePerimeter:
      resources:
        - projects/PROJECT_NUMBER
      restrictedServices:
        - bigquery.googleapis.com
        - pubsub.googleapis.com
      vpcAccessibleServices:
        enableRestriction: true
```

### 3. Input Validation & Sanitization (P1)

**Current Issues**:
- No domain validation in URL Mapper
- No URL validation before processing
- Potential for injection attacks

**Recommended Implementation**:
```go
// Add to URL Mapper
import (
    "net/url"
    "regexp"
)

func validateDomain(domain string) error {
    // Remove protocol if present
    domain = regexp.MustCompile(`^https?://`).ReplaceAllString(domain, "")
    
    // Validate domain format
    domainRegex := regexp.MustCompile(`^([a-zA-Z0-9-]+\.)*[a-zA-Z0-9-]+\.[a-zA-Z]{2,}$`)
    if !domainRegex.MatchString(domain) {
        return fmt.Errorf("invalid domain format: %s", domain)
    }
    
    // Check against allowlist if configured
    if allowedDomains := os.Getenv("ALLOWED_DOMAINS"); allowedDomains != "" {
        allowed := strings.Split(allowedDomains, ",")
        if !contains(allowed, domain) {
            return fmt.Errorf("domain not in allowlist: %s", domain)
        }
    }
    
    return nil
}

// Add to Page Processor
func validateURL(urlStr string) error {
    parsedURL, err := url.Parse(urlStr)
    if err != nil {
        return fmt.Errorf("invalid URL: %w", err)
    }
    
    // Only allow HTTP(S)
    if parsedURL.Scheme != "http" && parsedURL.Scheme != "https" {
        return fmt.Errorf("unsupported scheme: %s", parsedURL.Scheme)
    }
    
    // Prevent SSRF attacks
    if isPrivateIP(parsedURL.Hostname()) {
        return fmt.Errorf("private IP addresses not allowed")
    }
    
    return nil
}
```

## Infrastructure Improvements

### 4. Implement Dead Letter Queues (P1)

**Purpose**: Prevent message loss and enable debugging of failed messages

**Implementation**:
```bash
# Create dead letter topics
gcloud pubsub topics create "${CRAWLER_ID}-dlq-topic"

# Create dead letter subscription with extended retention
gcloud pubsub subscriptions create "${CRAWLER_ID}-dlq-sub" \
  --topic="${CRAWLER_ID}-dlq-topic" \
  --message-retention-duration=30d

# Update existing subscriptions
gcloud pubsub subscriptions update "${MAPPER_SUBSCRIPTION_ID}" \
  --dead-letter-topic="${CRAWLER_ID}-dlq-topic" \
  --max-delivery-attempts=5
```

**Monitoring Setup**:
```yaml
# monitoring/alerts.yaml
alertPolicy:
  displayName: "Dead Letter Queue Messages"
  conditions:
    - displayName: "DLQ has messages"
      conditionThreshold:
        filter: |
          resource.type="pubsub_subscription"
          resource.labels.subscription_id="${CRAWLER_ID}-dlq-sub"
          metric.type="pubsub.googleapis.com/subscription/num_undelivered_messages"
        comparison: COMPARISON_GT
        thresholdValue: 0
```

### 5. Add Cloud Scheduler for Orchestration (P2)

**Purpose**: Enable scheduled crawls and better job management

**Implementation**:
```bash
# Create scheduler job
gcloud scheduler jobs create pubsub "${CRAWLER_ID}-daily-crawl" \
  --schedule="0 2 * * *" \
  --topic="${INPUT_TOPIC_ID}" \
  --message-body='{"domain":"${DOMAIN_TO_CRAWL}","scheduled":true}' \
  --time-zone="America/New_York"
```

**Enhanced Input Schema**:
```json
{
  "domain": "example.com",
  "scheduled": true,
  "depth_limit": 3,
  "include_subdomains": false,
  "exclude_patterns": ["/admin/*", "/api/*"],
  "crawl_id": "daily-2024-01-15"
}
```

### 6. Implement State Management with Firestore (P1)

**Purpose**: Track crawl progress and enable resumability

**Data Model**:
```go
type CrawlJob struct {
    ID              string    `firestore:"id"`
    Domain          string    `firestore:"domain"`
    Status          string    `firestore:"status"` // pending, running, completed, failed
    StartedAt       time.Time `firestore:"started_at"`
    CompletedAt     time.Time `firestore:"completed_at,omitempty"`
    URLsDiscovered  int       `firestore:"urls_discovered"`
    URLsProcessed   int       `firestore:"urls_processed"`
    URLsFailed      int       `firestore:"urls_failed"`
    LastError       string    `firestore:"last_error,omitempty"`
}

type ProcessedURL struct {
    URL         string    `firestore:"url"`
    CrawlJobID  string    `firestore:"crawl_job_id"`
    ProcessedAt time.Time `firestore:"processed_at"`
    Status      string    `firestore:"status"`
    Hash        string    `firestore:"content_hash"`
}
```

**Integration Points**:
```go
// URL Mapper: Create job entry
func createCrawlJob(domain string) (*CrawlJob, error) {
    ctx := context.Background()
    client, err := firestore.NewClient(ctx, projectID)
    if err != nil {
        return nil, err
    }
    defer client.Close()
    
    job := &CrawlJob{
        ID:        uuid.New().String(),
        Domain:    domain,
        Status:    "running",
        StartedAt: time.Now(),
    }
    
    _, err = client.Collection("crawl_jobs").Doc(job.ID).Set(ctx, job)
    return job, err
}

// Page Processor: Check for duplicates
func isDuplicateURL(url, contentHash string) (bool, error) {
    ctx := context.Background()
    client, err := firestore.NewClient(ctx, projectID)
    if err != nil {
        return false, err
    }
    defer client.Close()
    
    // Check if URL with same hash exists
    docs, err := client.Collection("processed_urls").
        Where("url", "==", url).
        Where("content_hash", "==", contentHash).
        Limit(1).
        Documents(ctx).
        GetAll()
    
    return len(docs) > 0, err
}
```

### 6. Configurable Crawl Depth Parameter (P1) 🆕

**Purpose**: Allow users to control the number of URLs discovered from Firecrawl API

**Current State**: Fixed `PAGE_LIMIT` environment variable controls total URLs

**Requested Enhancement**: Add `depth` parameter to input message for per-job control

**Recommended Implementation**:
```go
// Enhanced Input Message Schema
type InputMessage struct {
    Domain string `json:"domain"`
    UID    string `json:"uid,omitempty"`
    Depth  int    `json:"depth,omitempty"`  // NEW: Number of URLs to discover
}

// Usage in URL Mapper
func (s *Server) processDepthLimit(domain string, depth int) int {
    // Use message depth if provided, otherwise fall back to PAGE_LIMIT env var
    if depth > 0 {
        return depth
    }
    
    // Parse PAGE_LIMIT from environment (existing behavior)
    if pageLimitStr := os.Getenv("PAGE_LIMIT"); pageLimitStr != "" {
        if pageLimit, err := strconv.Atoi(pageLimitStr); err == nil {
            return pageLimit * 1000  // Convert to actual count
        }
    }
    
    return 100  // Default fallback
}

// Enhanced Firecrawl API call
func callFirecrawlAPI(ctx context.Context, apiKey, url string, depth int) (*firecrawlResponse, error) {
    reqBody := firecrawlRequest{
        URL:               url,
        IncludeSubdomains: true,
        Limit:            depth,  // Pass depth to Firecrawl API
    }
    // ... rest of implementation
}
```

**Input Message Examples**:
```json
// Specific depth control
{"domain": "example.com", "uid": "job-001", "depth": 50}

// Use environment default
{"domain": "example.com", "uid": "job-001"}

// Backward compatibility 
{"domain": "example.com"}
```

**Benefits**:
- **Per-job Control**: Different crawl jobs can have different depth requirements
- **Cost Management**: Limit expensive Firecrawl API calls per job
- **Flexible Crawling**: Quick samples vs comprehensive crawls
- **Backward Compatible**: Existing jobs continue to work

**Implementation Effort**: 2-3 hours
- Update URL Mapper input parsing
- Modify Firecrawl API call structure
- Add validation for depth parameter
- Update documentation with examples

## Code Quality Enhancements

### 7. Structured Logging with Context (P2)

**Current State**: Basic fmt.Printf logging

**Recommended Solution**:
```go
import (
    "cloud.google.com/go/logging"
    "github.com/google/uuid"
)

type Logger struct {
    client *logging.Client
    logger *logging.Logger
}

func NewLogger(projectID string) (*Logger, error) {
    ctx := context.Background()
    client, err := logging.NewClient(ctx, projectID)
    if err != nil {
        return nil, err
    }
    
    return &Logger{
        client: client,
        logger: client.Logger("crawler"),
    }, nil
}

func (l *Logger) LogRequest(ctx context.Context, severity logging.Severity, msg string, fields map[string]interface{}) {
    // Add trace context for request correlation
    trace := ctx.Value("trace").(string)
    
    entry := logging.Entry{
        Severity: severity,
        Payload: map[string]interface{}{
            "message":   msg,
            "trace":     trace,
            "timestamp": time.Now().Unix(),
        },
    }
    
    // Add custom fields
    for k, v := range fields {
        entry.Payload.(map[string]interface{})[k] = v
    }
    
    l.logger.Log(entry)
}

// Usage in URL Mapper
func (s *Server) handleCrawlRequest(ctx context.Context, msg *pubsub.Message) error {
    traceID := uuid.New().String()
    ctx = context.WithValue(ctx, "trace", traceID)
    
    s.logger.LogRequest(ctx, logging.Info, "Processing crawl request", map[string]interface{}{
        "domain":     domain,
        "message_id": msg.ID,
        "attributes": msg.Attributes,
    })
    
    // ... processing logic
    
    s.logger.LogRequest(ctx, logging.Info, "Crawl request completed", map[string]interface{}{
        "domain":      domain,
        "urls_found":  len(urls),
        "duration_ms": time.Since(start).Milliseconds(),
    })
}
```

### 8. Add Comprehensive Testing (P2)

**Unit Tests**:
```go
// url_mapper/main_test.go
func TestValidateDomain(t *testing.T) {
    tests := []struct {
        name    string
        domain  string
        wantErr bool
    }{
        {"valid domain", "example.com", false},
        {"valid subdomain", "sub.example.com", false},
        {"with protocol", "https://example.com", false},
        {"invalid format", "not a domain", true},
        {"empty", "", true},
        {"local IP", "192.168.1.1", true},
    }
    
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            err := validateDomain(tt.domain)
            if (err != nil) != tt.wantErr {
                t.Errorf("validateDomain() error = %v, wantErr %v", err, tt.wantErr)
            }
        })
    }
}
```

**Integration Tests**:
```go
// integration/crawler_test.go
func TestEndToEndCrawl(t *testing.T) {
    if testing.Short() {
        t.Skip("skipping integration test")
    }
    
    ctx := context.Background()
    
    // Start test server
    ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        w.Write([]byte("<html><body>Test Page</body></html>"))
    }))
    defer ts.Close()
    
    // Publish test message
    client, err := pubsub.NewClient(ctx, testProjectID)
    require.NoError(t, err)
    
    topic := client.Topic(inputTopicID)
    result := topic.Publish(ctx, &pubsub.Message{
        Data: []byte(fmt.Sprintf(`{"domain":"%s"}`, ts.URL)),
    })
    
    _, err = result.Get(ctx)
    require.NoError(t, err)
    
    // Verify output
    eventually(t, func() bool {
        // Check BigQuery for result
        query := fmt.Sprintf(`
            SELECT COUNT(*) as count 
            FROM %s.%s 
            WHERE url LIKE '%s%%' 
            AND timestamp > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 MINUTE)
        `, dataset, processedTable, ts.URL)
        
        // ... execute query and verify
        return count > 0
    }, 30*time.Second, 1*time.Second)
}
```

### 9. Configuration Management Improvements (P2)

**Replace Shell Script with YAML/JSON**:
```yaml
# config/crawler-config.yaml
crawlers:
  - id: crawler-basic
    domain: example.com
    settings:
      page_limit: 10
      include_subdomains: true
      crawl_depth: 3
      allowed_content_types:
        - text/html
        - application/xhtml+xml
      exclude_patterns:
        - /admin/*
        - /api/*
        - *.pdf
    scheduling:
      enabled: true
      cron: "0 2 * * *"
      timezone: "America/New_York"
    alerts:
      email: ops@example.com
      slack_webhook: ${SLACK_WEBHOOK_URL}
```

**Configuration Loader**:
```go
type Config struct {
    Crawlers []CrawlerConfig `yaml:"crawlers"`
}

type CrawlerConfig struct {
    ID       string   `yaml:"id"`
    Domain   string   `yaml:"domain"`
    Settings Settings `yaml:"settings"`
}

func LoadConfig(path string) (*Config, error) {
    data, err := ioutil.ReadFile(path)
    if err != nil {
        return nil, err
    }
    
    // Expand environment variables
    expanded := os.ExpandEnv(string(data))
    
    var config Config
    err = yaml.Unmarshal([]byte(expanded), &config)
    return &config, err
}
```

## Reliability & Resilience

### 10. Implement Circuit Breakers (P1)

**Purpose**: Prevent cascading failures when external services are down

**Implementation**:
```go
import "github.com/sony/gobreaker"

type FirecrawlClient struct {
    client  *http.Client
    breaker *gobreaker.CircuitBreaker
    apiKey  string
}

func NewFirecrawlClient(apiKey string) *FirecrawlClient {
    settings := gobreaker.Settings{
        Name:        "firecrawl",
        MaxRequests: 3,
        Interval:    10 * time.Second,
        Timeout:     30 * time.Second,
        ReadyToTrip: func(counts gobreaker.Counts) bool {
            failureRatio := float64(counts.TotalFailures) / float64(counts.Requests)
            return counts.Requests >= 3 && failureRatio >= 0.6
        },
        OnStateChange: func(name string, from gobreaker.State, to gobreaker.State) {
            log.Printf("Circuit breaker %s: %s -> %s", name, from, to)
        },
    }
    
    return &FirecrawlClient{
        client:  &http.Client{Timeout: 30 * time.Second},
        breaker: gobreaker.NewCircuitBreaker(settings),
        apiKey:  apiKey,
    }
}

func (c *FirecrawlClient) MapDomain(domain string) ([]string, error) {
    body, err := c.breaker.Execute(func() (interface{}, error) {
        // Actual API call
        return c.callAPI(domain)
    })
    
    if err != nil {
        return nil, err
    }
    
    return body.([]string), nil
}
```

### 11. Add Retry Logic with Exponential Backoff (P1)

**HTTP Client with Retries**:
```go
import "github.com/hashicorp/go-retryablehttp"

func createRetryableClient() *http.Client {
    retryClient := retryablehttp.NewClient()
    retryClient.RetryMax = 3
    retryClient.RetryWaitMin = 1 * time.Second
    retryClient.RetryWaitMax = 30 * time.Second
    retryClient.Logger = nil // Use structured logging instead
    
    retryClient.CheckRetry = func(ctx context.Context, resp *http.Response, err error) (bool, error) {
        // Retry on network errors
        if err != nil {
            return true, nil
        }
        
        // Retry on 5xx errors
        if resp.StatusCode >= 500 {
            return true, nil
        }
        
        // Retry on rate limit (429)
        if resp.StatusCode == 429 {
            if retryAfter := resp.Header.Get("Retry-After"); retryAfter != "" {
                // Parse and sleep for Retry-After duration
            }
            return true, nil
        }
        
        return false, nil
    }
    
    return retryClient.StandardClient()
}
```

### 12. Health Checks and Readiness Probes (P2)

**Implementation**:
```go
// Add to both services
func healthHandler(w http.ResponseWriter, r *http.Request) {
    checks := map[string]string{
        "service": "healthy",
        "pubsub":  checkPubSubConnection(),
    }
    
    allHealthy := true
    for _, status := range checks {
        if status != "healthy" {
            allHealthy = false
            break
        }
    }
    
    w.Header().Set("Content-Type", "application/json")
    if !allHealthy {
        w.WriteHeader(http.StatusServiceUnavailable)
    }
    
    json.NewEncoder(w).Encode(checks)
}

func readinessHandler(w http.ResponseWriter, r *http.Request) {
    // Check if service is ready to accept traffic
    if !isServiceReady() {
        w.WriteHeader(http.StatusServiceUnavailable)
        return
    }
    
    w.WriteHeader(http.StatusOK)
}

// Update Cloud Run deployment
gcloud run deploy $SERVICE_NAME \
  --health-check-path=/health \
  --health-check-interval=30s \
  --health-check-timeout=10s \
  --health-check-initial-delay=10s
```

## Performance Optimizations

### 13. Implement Caching Layer (P2)

**Purpose**: Avoid re-crawling unchanged content

**Redis Integration**:
```go
import (
    "github.com/go-redis/redis/v8"
    "crypto/md5"
)

type CacheClient struct {
    client *redis.Client
}

func NewCacheClient(addr string) *CacheClient {
    return &CacheClient{
        client: redis.NewClient(&redis.Options{
            Addr:         addr,
            DialTimeout:  5 * time.Second,
            ReadTimeout:  3 * time.Second,
            WriteTimeout: 3 * time.Second,
        }),
    }
}

func (c *CacheClient) GetContentHash(url string) (string, error) {
    ctx := context.Background()
    return c.client.Get(ctx, fmt.Sprintf("hash:%s", url)).Result()
}

func (c *CacheClient) SetContentHash(url, content string, ttl time.Duration) error {
    ctx := context.Background()
    hash := fmt.Sprintf("%x", md5.Sum([]byte(content)))
    return c.client.Set(ctx, fmt.Sprintf("hash:%s", url), hash, ttl).Err()
}

// Usage in Page Processor
func (p *Processor) shouldProcessURL(url string) bool {
    oldHash, _ := p.cache.GetContentHash(url)
    if oldHash == "" {
        return true // Not in cache, process it
    }
    
    // Fetch headers only to check Last-Modified
    resp, err := http.Head(url)
    if err != nil {
        return true // On error, process anyway
    }
    
    if lastMod := resp.Header.Get("Last-Modified"); lastMod != "" {
        // Compare with stored last modified time
        // Return true if changed
    }
    
    return false
}
```

### 14. Batch Processing for BigQuery (P2)

**Current**: Individual message inserts
**Recommended**: Batch inserts with micro-batching

```go
type BatchWriter struct {
    client      *bigquery.Client
    table       *bigquery.Table
    batch       []interface{}
    batchSize   int
    flushTicker *time.Ticker
    mu          sync.Mutex
}

func NewBatchWriter(projectID, datasetID, tableID string) (*BatchWriter, error) {
    ctx := context.Background()
    client, err := bigquery.NewClient(ctx, projectID)
    if err != nil {
        return nil, err
    }
    
    bw := &BatchWriter{
        client:      client,
        table:       client.Dataset(datasetID).Table(tableID),
        batchSize:   100,
        batch:       make([]interface{}, 0, 100),
        flushTicker: time.NewTicker(5 * time.Second),
    }
    
    go bw.periodicFlush()
    return bw, nil
}

func (bw *BatchWriter) Write(record interface{}) error {
    bw.mu.Lock()
    defer bw.mu.Unlock()
    
    bw.batch = append(bw.batch, record)
    
    if len(bw.batch) >= bw.batchSize {
        return bw.flush()
    }
    
    return nil
}

func (bw *BatchWriter) flush() error {
    if len(bw.batch) == 0 {
        return nil
    }
    
    ctx := context.Background()
    inserter := bw.table.Inserter()
    
    err := inserter.Put(ctx, bw.batch)
    if err != nil {
        return fmt.Errorf("batch insert failed: %w", err)
    }
    
    bw.batch = bw.batch[:0] // Clear batch
    return nil
}
```

### 15. Concurrent URL Processing (P2)

**Current**: Sequential processing
**Recommended**: Worker pool pattern

```go
type WorkerPool struct {
    workers   int
    taskQueue chan Task
    wg        sync.WaitGroup
}

type Task struct {
    URL       string
    MessageID string
}

func NewWorkerPool(workers int) *WorkerPool {
    return &WorkerPool{
        workers:   workers,
        taskQueue: make(chan Task, workers*2),
    }
}

func (wp *WorkerPool) Start(processor func(Task) error) {
    for i := 0; i < wp.workers; i++ {
        wp.wg.Add(1)
        go func(workerID int) {
            defer wp.wg.Done()
            
            for task := range wp.taskQueue {
                start := time.Now()
                err := processor(task)
                
                metrics.RecordProcessingTime(time.Since(start))
                if err != nil {
                    metrics.IncrementErrors()
                    log.Printf("Worker %d failed task %s: %v", workerID, task.URL, err)
                }
            }
        }(i)
    }
}

func (wp *WorkerPool) Submit(task Task) {
    wp.taskQueue <- task
}

func (wp *WorkerPool) Stop() {
    close(wp.taskQueue)
    wp.wg.Wait()
}
```

## Operational Excellence

### 16. Comprehensive Monitoring Dashboard (P1)

**Metrics to Track**:
```yaml
# monitoring/dashboard.yaml
dashboardDisplayName: "Crawler Operations"
widgets:
  - title: "Crawl Throughput"
    xyChart:
      dataSets:
        - timeSeriesQuery:
            timeSeriesFilter:
              filter: |
                resource.type="pubsub_topic"
                metric.type="pubsub.googleapis.com/topic/send_message_operation_count"
  
  - title: "Processing Latency"
    xyChart:
      dataSets:
        - timeSeriesQuery:
            timeSeriesFilter:
              filter: |
                resource.type="cloud_run_revision"
                metric.type="run.googleapis.com/request_latencies"
  
  - title: "Error Rate"
    xyChart:
      dataSets:
        - timeSeriesQuery:
            timeSeriesFilter:
              filter: |
                resource.type="cloud_run_revision"
                metric.type="run.googleapis.com/request_count"
                metric.label.response_code_class!="2xx"
  
  - title: "BigQuery Streaming Errors"
    xyChart:
      dataSets:
        - timeSeriesQuery:
            timeSeriesFilter:
              filter: |
                resource.type="bigquery_project"
                metric.type="bigquery.googleapis.com/streaming/errors"
```

**Custom Metrics**:
```go
import (
    monitoring "cloud.google.com/go/monitoring/apiv3/v2"
    "google.golang.org/api/option"
)

type MetricsClient struct {
    client    *monitoring.MetricClient
    projectID string
}

func (m *MetricsClient) RecordCrawlMetrics(domain string, urlCount int, duration time.Duration) error {
    ctx := context.Background()
    
    req := &monitoringpb.CreateTimeSeriesRequest{
        Name: fmt.Sprintf("projects/%s", m.projectID),
        TimeSeries: []*monitoringpb.TimeSeries{
            {
                Metric: &metricpb.Metric{
                    Type: "custom.googleapis.com/crawler/urls_discovered",
                    Labels: map[string]string{
                        "domain":     domain,
                        "crawler_id": os.Getenv("CRAWLER_ID"),
                    },
                },
                Points: []*monitoringpb.Point{
                    {
                        Interval: &monitoringpb.TimeInterval{
                            EndTime: timestamppb.Now(),
                        },
                        Value: &monitoringpb.TypedValue{
                            Value: &monitoringpb.TypedValue_Int64Value{
                                Int64Value: int64(urlCount),
                            },
                        },
                    },
                },
            },
        },
    }
    
    return m.client.CreateTimeSeries(ctx, req)
}
```

### 17. Automated Runbooks (P2)

**Incident Response Automation**:
```yaml
# runbooks/high-error-rate.yaml
name: "High Error Rate Response"
trigger:
  condition: "error_rate > 10%"
  duration: "5m"

steps:
  - name: "Gather diagnostics"
    actions:
      - type: "gcloud_command"
        command: |
          gcloud logging read "severity=ERROR" \
            --limit=100 \
            --format=json > /tmp/errors.json
      
      - type: "query_bigquery"
        query: |
          SELECT 
            status, 
            COUNT(*) as count,
            ARRAY_AGG(url LIMIT 10) as sample_urls
          FROM `${PROJECT}.crawler.${CRAWLER_ID}_processed`
          WHERE timestamp > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 HOUR)
          GROUP BY status
  
  - name: "Check external dependencies"
    actions:
      - type: "http_check"
        url: "https://api.firecrawl.dev/health"
        expected_status: 200
  
  - name: "Scale services"
    actions:
      - type: "gcloud_command"
        command: |
          gcloud run services update ${URL_MAPPER_SERVICE} \
            --min-instances=2 \
            --max-instances=20
  
  - name: "Notify on-call"
    actions:
      - type: "slack_notification"
        channel: "#crawler-alerts"
        message: "High error rate detected. Diagnostics gathered and scaling applied."
```

### 18. Deployment Pipeline Improvements (P1) ✅ PARTIALLY IMPLEMENTED

**GitOps with Cloud Build**:
```yaml
# cloudbuild.yaml
steps:
  # Run tests
  - name: 'golang:1.22'
    entrypoint: 'go'
    args: ['test', './...', '-v']
    env:
      - 'CGO_ENABLED=0'
  
  # Build and push images
  - name: 'gcr.io/cloud-builders/docker'
    args: 
      - 'build'
      - '-t'
      - 'gcr.io/$PROJECT_ID/url-mapper:$SHORT_SHA'
      - './url_mapper'
  
  - name: 'gcr.io/cloud-builders/docker'
    args: ['push', 'gcr.io/$PROJECT_ID/url-mapper:$SHORT_SHA']
  
  # Deploy to staging
  - name: 'gcr.io/cloud-builders/gcloud'
    args:
      - 'run'
      - 'deploy'
      - 'url-mapper-staging'
      - '--image=gcr.io/$PROJECT_ID/url-mapper:$SHORT_SHA'
      - '--region=us-central1'
      - '--platform=managed'
  
  # Run integration tests
  - name: 'golang:1.22'
    entrypoint: 'go'
    args: ['test', './integration/...', '-v']
    env:
      - 'STAGING_URL=https://url-mapper-staging.run.app'
  
  # Deploy to production (manual approval required)
  - name: 'gcr.io/cloud-builders/gcloud'
    args:
      - 'run'
      - 'deploy'
      - 'url-mapper'
      - '--image=gcr.io/$PROJECT_ID/url-mapper:$SHORT_SHA'
      - '--region=us-central1'
      - '--platform=managed'
    waitFor: ['manual-approval']

options:
  machineType: 'N1_HIGHCPU_8'
  
timeout: 1200s
```

## Cost Optimization

### 19. Resource Right-Sizing (P2) ✅ PARTIALLY IMPLEMENTED

**Cloud Run Optimization**:
```bash
# Analyze actual usage
gcloud monitoring read \
  --filter='resource.type="cloud_run_revision" AND 
           metric.type="run.googleapis.com/container/cpu/utilizations"' \
  --format=json | jq '.[] | .points[0].value.distributionValue'

# Update based on analysis
gcloud run services update $SERVICE_NAME \
  --cpu=0.5 \
  --memory=256Mi \
  --max-instances=10 \
  --concurrency=20
```

### 20. BigQuery Cost Controls (P2)

**Implement Partitioning Expiration**:
```sql
-- Set partition expiration to reduce storage costs
ALTER TABLE `${PROJECT}.crawler.${CRAWLER_ID}_raw`
SET OPTIONS (
  partition_expiration_days=30
);

-- Create materialized views for common queries
CREATE MATERIALIZED VIEW `${PROJECT}.crawler.daily_summary`
PARTITION BY DATE(timestamp)
AS
SELECT
  DATE(timestamp) as crawl_date,
  domain,
  crawler_id,
  status,
  COUNT(*) as page_count,
  AVG(LENGTH(markdown)) as avg_content_length
FROM `${PROJECT}.crawler.${CRAWLER_ID}_processed`
GROUP BY crawl_date, domain, crawler_id, status;
```

## Implementation Roadmap

### ✅ Completed Items
- Deployment script retry logic and error handling
- Service readiness checks
- Cloud Run memory optimization (1Gi for processor)
- Pre-deployment verification
- BigQuery dataset error handling
- Service account format fixes
- IAM authentication enforcement
- Resource verification in scripts

### Phase 1: Security & Reliability (Weeks 1-2)
1. ⏳ Implement Secret Manager for API keys
2. ⏳ Fix IAM permissions to least privilege
3. ⏳ Add input validation
4. ⏳ Implement dead letter queues
5. ⏳ Add basic health checks
6. 🆕 **Add configurable crawl depth parameter**

### Phase 2: Observability (Weeks 3-4)
1. ⏳ Implement structured logging
2. ⏳ Create monitoring dashboards
3. ⏳ Set up alerting rules
4. ⏳ Add custom metrics
5. ⏳ Create runbook automation

### Phase 3: Performance (Weeks 5-6)
1. ⏳ Add caching layer
2. ⏳ Implement batch processing
3. ⏳ Add worker pools
4. ✅ Optimize Cloud Run settings (partially completed)
5. ⏳ Add circuit breakers

### Phase 4: Operations (Weeks 7-8)
1. ⏳ Implement state management
2. ⏳ Add comprehensive testing
3. ✅ Set up CI/CD pipeline (deployment scripts enhanced)
4. ⏳ Create configuration management
5. ✅ Document operational procedures (partially completed)

### Success Metrics
- **Security**: Zero exposed secrets, 100% least privilege IAM
- **Reliability**: 99.9% uptime, <1% message loss
- **Performance**: 10x throughput improvement, 50% latency reduction
- **Cost**: 30% reduction in BigQuery costs, 20% reduction in Cloud Run costs
- **Operations**: <15 minute MTTR, 90% automated incident response

## Conclusion

These refactoring recommendations address the current system's limitations while maintaining its serverless, event-driven architecture. The phased approach allows for incremental improvements with measurable outcomes at each stage. Priority should be given to security fixes and reliability improvements before optimizing for performance and cost.