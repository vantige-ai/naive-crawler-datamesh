# Serverless Web Crawler Pipeline

A production-ready, distributed web crawler built on Google Cloud Platform that automatically discovers and converts web pages to Markdown format with comprehensive BigQuery analytics.

[![Production Tested](https://img.shields.io/badge/Production-Tested-brightgreen)](https://img.shields.io/badge/Production-Tested-brightgreen)
[![Success Rate](https://img.shields.io/badge/Success%20Rate-91.2%25-brightgreen)](https://img.shields.io/badge/Success%20Rate-91.2%25-brightgreen)
[![Messages Processed](https://img.shields.io/badge/Messages%20Processed-9%2C876%2B-blue)](https://img.shields.io/badge/Messages%20Processed-9%2C876%2B-blue)

## 📋 Table of Contents
- [Overview](#overview)
- [Quick Start](#quick-start)
- [Configuration](#configuration)
- [Deployment Steps](#deployment-steps)
- [Manual Configuration Required](#manual-configuration-required)
- [Testing & Verification](#testing--verification)
- [Monitoring & Operations](#monitoring--operations)
- [Troubleshooting](#troubleshooting)
- [Architecture Details](#architecture-details)

## 🎯 Overview

This system crawls websites at scale, extracting content and storing it in BigQuery for analytics. Built entirely on serverless GCP services for automatic scaling and cost optimization.

### Key Features
- **Serverless Architecture**: Auto-scaling Cloud Run services with scale-to-zero
- **High Throughput**: Processes 5,000+ URLs per domain with 91.2% success rate
- **Job Tracking**: Unique ID (UID) tracking for each crawl job with backward compatibility
- **Real-time Analytics**: Direct BigQuery streaming with metadata enrichment
- **Robust Error Handling**: Graceful failure handling and status tracking
- **Multi-tenant**: Deploy multiple crawler instances in the same project

### Architecture Flow
```
User Request → Input Topic → URL Mapper → URLs Topic → Page Processor → Output Topic → BigQuery
                   ↓             ↓            ↓              ↓             ↓
              Firecrawl API   Discovery     HTTP Fetch   Markdown Conv.  Analytics
```

## 🚀 Quick Start

### Prerequisites
- Google Cloud Platform project with billing enabled
- `gcloud` CLI installed and authenticated
- `bq` CLI tool available
- Firecrawl API key ([get one here](https://www.firecrawl.dev/))

### 1-Minute Setup
```bash
# 1. Clone and configure
git clone <repository>
cd unified_crawler

# 2. Configure your environment (see Configuration section below)
cp .env.example config.sh
nano config.sh

# 3. Deploy infrastructure
./scripts/setup_infra.sh

# 4. Complete manual BigQuery configuration (UI step - see below)

# 5. Deploy services
./scripts/deploy.sh

# 6. Test the pipeline
gcloud pubsub topics publish crawler-basic-input-topic \
  --message '{"domain": "example.com"}' \
  --project=your-project-id
```

## ⚙️ Configuration

### Configure Environment - Required Before Deployment

**⚠️ SECURITY WARNING**: Never commit API keys or project IDs to version control.

1. **Create your configuration file**:
   ```bash
   cp .env.example config.sh
   ```

2. **Edit `config.sh` with your values**:
   ```bash
   # --- CORE CONFIGURATION (EDIT THESE VALUES) ---
   
   # A unique ID for this crawler instance. Use lowercase letters, numbers, and hyphens.
   export CRAWLER_ID="crawler-basic"
   
   # The root domain to crawl.
   export DOMAIN_TO_CRAWL="example.com"
   
   # Max pages to map using Firecrawl.
   export PAGE_LIMIT="10"
   
   # The GCP Project ID.
   export PROJECT_ID="your-project-id"
   export REGION="us-central1"
   
   # IMPORTANT: You must set this value before deploying.
   export FIRECRAWL_API_KEY="fc-your-api-key-here"
   
   # Security setting - REQUIRED for Pub/Sub push subscriptions
   export ALLOW_UNAUTHENTICATED="true"
   ```

3. **Verify `config.sh` is in `.gitignore`** (already configured)

### Configuration Parameters Explained

| Parameter | Description | Example | Required |
|-----------|-------------|---------|----------|
| `CRAWLER_ID` | Unique identifier for this crawler instance | `"crawler-basic"` | ✅ |
| `DOMAIN_TO_CRAWL` | Default domain to crawl | `"example.com"` | ✅ |
| `PAGE_LIMIT` | Max pages to discover (in thousands) | `"10"` | ✅ |
| `PROJECT_ID` | Your GCP project ID | `"my-project-123"` | ✅ |
| `REGION` | GCP deployment region | `"us-central1"` | ✅ |
| `FIRECRAWL_API_KEY` | API key from firecrawl.dev | `"fc-abc123..."` | ✅ |
| `ALLOW_UNAUTHENTICATED` | Enable for Pub/Sub push | `"true"` | ✅ |

### Resource Naming Convention

All GCP resources are automatically named using your `CRAWLER_ID`:

- **Cloud Run Services**: `{CRAWLER_ID}-mapper-svc`, `{CRAWLER_ID}-processor-svc`
- **Pub/Sub Topics**: `{CRAWLER_ID}-input-topic`, `{CRAWLER_ID}-urls-topic`, `{CRAWLER_ID}-output-topic`
- **Subscriptions**: `{CRAWLER_ID}-mapper-sub`, `{CRAWLER_ID}-processor-sub`, `{CRAWLER_ID}-raw-data-sub`
- **Service Accounts**: `{CRAWLER_ID}-mapper-sa`, `{CRAWLER_ID}-processor-sa`
- **BigQuery Tables**: `crawler.{CRAWLER_ID}_raw`, `crawler.{CRAWLER_ID}_processed`

## 📦 Deployment Steps

### Step 1: Infrastructure Setup
```bash
./scripts/setup_infra.sh
```

This script will:
- ✅ Enable required GCP APIs
- ✅ Create service accounts with proper permissions
- ✅ Create Pub/Sub topics and subscriptions
- ✅ Create BigQuery dataset and tables
- ✅ Configure BigQuery subscription (partial)
- ⚠️ Display manual configuration requirements

**Expected Output**: Infrastructure provisioned with instructions for manual steps.

### Step 2: Manual BigQuery Configuration (Required)

The infrastructure script will provide a direct link to configure BigQuery write metadata. **This step is critical and cannot be automated.**

**What you need to do:**
1. Click the provided link to your BigQuery subscription
2. Click "EDIT" at the top of the page
3. Find "BigQuery settings" section
4. **Enable "Write metadata"** ✅ (this is the critical step)
5. Verify table is set to: `your-project.crawler.crawler_basic_raw`
6. Click "UPDATE"

**Why this is required**: The gcloud CLI doesn't support BigQuery write metadata configuration as of 2025.

### Step 3: Service Deployment
```bash
./scripts/deploy.sh
```

This script will:
- ✅ Verify all prerequisites are met
- ✅ Deploy URL Mapper service (512Mi memory)
- ✅ Deploy Page Processor service (1Gi memory)
- ✅ Create authenticated push subscriptions
- ✅ Configure service endpoints
- ✅ Display deployment summary

**Expected Output**: Both services deployed and ready to process messages.

### Step 4: Authentication Fix (If Needed)

If you see 403 authentication errors in logs:
1. Go to Cloud Run console for each service
2. Click "Security" tab
3. **Uncheck "Require authentication"**
4. Save changes

*Note: This is handled automatically if `ALLOW_UNAUTHENTICATED="true"` in config.sh*

## 🛠️ Manual Configuration Required

### 1. BigQuery Write Metadata (Critical)

**When**: After running `setup_infra.sh`
**Where**: Google Cloud Console
**Why**: Required for proper data ingestion

**Steps**:
1. Navigate to the provided subscription URL
2. Click "EDIT" → Find "BigQuery settings"
3. ✅ **Enable "Write metadata"** (most important setting)
4. Verify table: `your-project.crawler.crawler_basic_raw`
5. Advanced settings (recommended):
   - Message retention: 1 day
   - Acknowledgment deadline: 10 seconds
   - Exactly-once delivery: DISABLED
   - Retry policy: Retry immediately

### 2. Cloud Run Authentication (If Needed)

**When**: If you see 403 errors in logs
**Where**: Cloud Run console
**Why**: Pub/Sub push subscriptions need unauthenticated access

**Services to update**:
- `crawler-basic-mapper-svc`
- `crawler-basic-processor-svc`

**Steps per service**:
1. Go to service in Cloud Run console
2. Click "Security" tab
3. Uncheck "Require authentication"
4. Save changes

## 🧪 Testing & Verification

### Start a Test Crawl
```bash
# Test with UID for job tracking (recommended)
gcloud pubsub topics publish crawler-basic-input-topic \
  --message '{"domain": "example.com", "uid": "my-job-001"}' \
  --project=your-project-id

# Test without UID (backward compatibility - auto-generates UID)
gcloud pubsub topics publish crawler-basic-input-topic \
  --message '{"domain": "example.com"}' \
  --project=your-project-id
```

### Monitor Progress
```bash
# Check if messages are reaching BigQuery (wait 1-2 minutes)
bq query --use_legacy_sql=false \
  'SELECT COUNT(*) as message_count, MAX(publish_time) as latest 
   FROM `your-project.crawler.crawler_basic_raw` 
   WHERE DATE(publish_time) = CURRENT_DATE()'

# Check success/error breakdown by job
bq query --use_legacy_sql=false \
  'SELECT 
     JSON_EXTRACT_SCALAR(data, "$.uid") as job_id,
     JSON_EXTRACT_SCALAR(data, "$.domain") as domain,
     JSON_EXTRACT_SCALAR(data, "$.status") as status, 
     COUNT(*) as count 
   FROM `your-project.crawler.crawler_basic_raw` 
   WHERE DATE(publish_time) = CURRENT_DATE() 
   GROUP BY job_id, domain, status ORDER BY count DESC'

# Track specific job progress
bq query --use_legacy_sql=false \
  'SELECT JSON_EXTRACT_SCALAR(data, "$.url") as url, 
          JSON_EXTRACT_SCALAR(data, "$.status") as status
   FROM `your-project.crawler.crawler_basic_raw` 
   WHERE JSON_EXTRACT_SCALAR(data, "$.uid") = "my-job-001"
   ORDER BY publish_time DESC LIMIT 10'
```

### Expected Results
- **URL Discovery**: 5,000+ URLs found per domain
- **Processing Rate**: 90%+ success rate
- **Data Flow**: Messages appearing in BigQuery within 2 minutes
- **Error Handling**: Failed URLs marked with status="error"

## 📊 Monitoring & Operations

### Service Health Checks
```bash
# Check service status
gcloud run services describe crawler-basic-mapper-svc \
  --region=us-central1 --project=your-project \
  --format="value(status.url)"

gcloud run services describe crawler-basic-processor-svc \
  --region=us-central1 --project=your-project \
  --format="value(status.url)"
```

### Application Logs
```bash
# URL Mapper activity
gcloud logging read "resource.type=cloud_run_revision AND \
  resource.labels.service_name=crawler-basic-mapper-svc" \
  --limit=10 --project=your-project

# Page Processor activity  
gcloud logging read "resource.type=cloud_run_revision AND \
  resource.labels.service_name=crawler-basic-processor-svc" \
  --limit=10 --project=your-project
```

### BigQuery Analytics

#### Job Tracking Queries (NEW)
```sql
-- Track all jobs and their progress
SELECT 
  JSON_EXTRACT_SCALAR(data, '$.uid') as job_id,
  JSON_EXTRACT_SCALAR(data, '$.domain') as domain,
  MIN(publish_time) as started_at,
  MAX(publish_time) as completed_at,
  COUNT(*) as total_urls,
  COUNTIF(JSON_EXTRACT_SCALAR(data, '$.status') = 'success') as successful_urls,
  ROUND(COUNTIF(JSON_EXTRACT_SCALAR(data, '$.status') = 'success') / COUNT(*) * 100, 1) as success_rate_pct
FROM `your-project.crawler.crawler_basic_raw`
WHERE DATE(publish_time) = CURRENT_DATE()
GROUP BY job_id, domain
ORDER BY started_at DESC;

-- Monitor specific job completion
SELECT 
  JSON_EXTRACT_SCALAR(data, '$.url') as url,
  JSON_EXTRACT_SCALAR(data, '$.status') as status,
  publish_time,
  LENGTH(JSON_EXTRACT_SCALAR(data, '$.markdown')) as content_length
FROM `your-project.crawler.crawler_basic_raw` 
WHERE JSON_EXTRACT_SCALAR(data, '$.uid') = 'my-job-001'
ORDER BY publish_time DESC
LIMIT 20;
```

#### Real-time Crawl Analytics
```sql
-- Domain-level status summary
SELECT 
  JSON_EXTRACT_SCALAR(data, '$.domain') as domain,
  JSON_EXTRACT_SCALAR(data, '$.status') as status,
  COUNT(*) as page_count,
  MAX(publish_time) as latest_activity
FROM `your-project.crawler.crawler_basic_raw` 
WHERE DATE(publish_time) = CURRENT_DATE()
GROUP BY domain, status
ORDER BY latest_activity DESC;

-- Sample successful crawls
SELECT 
  JSON_EXTRACT_SCALAR(data, '$.url') as url,
  JSON_EXTRACT_SCALAR(data, '$.uid') as job_id,
  JSON_EXTRACT_SCALAR(data, '$.status') as status,
  LENGTH(JSON_EXTRACT_SCALAR(data, '$.markdown')) as content_length
FROM `your-project.crawler.crawler_basic_raw` 
WHERE DATE(publish_time) = CURRENT_DATE() 
  AND JSON_EXTRACT_SCALAR(data, '$.status') = 'success'
ORDER BY publish_time DESC
LIMIT 5;
```

## 🔧 Troubleshooting

### Common Issues & Solutions

#### 1. 403 Authentication Errors in Logs
**Problem**: `The request was not authenticated...`
**Solution**: Disable IAM authentication on Cloud Run services (see Manual Configuration section)

#### 2. No Messages in BigQuery
**Problem**: Pipeline running but no data in BigQuery
**Solution**: Verify BigQuery "Write metadata" is enabled in subscription settings

#### 3. Firecrawl API Errors
**Problem**: URL Mapper failing with API errors
**Solution**: Check your Firecrawl API key and rate limits

#### 4. Build Timeouts
**Problem**: Cloud Run deployment taking too long
**Solution**: The deploy script has 60-minute timeout and retry logic - be patient

### Debug Commands
```bash
# Check subscription configuration
gcloud pubsub subscriptions describe crawler-basic-raw-data-sub \
  --project=your-project

# Test service endpoints (after deployment)
curl -X POST https://your-service-url/ \
  -H "Content-Type: application/json" \
  -d '{"message":{"data":"eyJ0ZXN0IjoidmFsdWUifQ=="}}'

# Monitor Pub/Sub backlog
gcloud pubsub subscriptions describe crawler-basic-mapper-sub \
  --format="value(numUndeliveredMessages)" --project=your-project
```

### Performance Tuning
```bash
# Increase Cloud Run memory for large sites
gcloud run services update crawler-basic-processor-svc \
  --memory=2Gi --region=us-central1 --project=your-project

# Adjust concurrency for higher throughput
gcloud run services update crawler-basic-processor-svc \
  --concurrency=20 --region=us-central1 --project=your-project
```

## 🏗️ Architecture Details

### Components Overview

1. **URL Mapper Service** (Go, 512Mi memory)
   - Receives domain crawl requests
   - Calls Firecrawl API for URL discovery
   - Publishes individual URLs to processing queue

2. **Page Processor Service** (Go, 1Gi memory)
   - Fetches web page content
   - Converts HTML to Markdown
   - Publishes results with status tracking

3. **BigQuery Integration**
   - Raw table: Complete message history with metadata
   - Processed table: Structured data for analytics
   - Automatic partitioning and clustering

### Data Schema

**BigQuery Raw Table**:
```sql
CREATE TABLE crawler.crawler_basic_raw (
  subscription_name STRING,     -- Source subscription
  message_id STRING,           -- Unique message ID
  publish_time TIMESTAMP,      -- Processing timestamp  
  data JSON,                   -- Full crawler result
  attributes JSON              -- Message metadata
)
PARTITION BY DATE(publish_time)
CLUSTER BY subscription_name;
```

**Message Data Structure** (Enhanced with UID tracking):
```json
{
  "url": "https://example.com/page",
  "markdown": "# Page Title\n\nContent...",
  "timestamp": "2025-01-15T10:30:00Z",
  "crawler_id": "crawler-basic",
  "domain": "example.com", 
  "uid": "my-job-001",
  "status": "success"
}
```

**Input Message Options**:
```json
// With UID for job tracking (recommended)
{"domain": "example.com", "uid": "my-job-001"}

// Without UID (auto-generates: "auto-{timestamp}-{random}")
{"domain": "example.com"}
```

### Scaling Characteristics

- **Throughput**: 5,000+ URLs per domain discovery
- **Processing**: 90%+ success rate on typical websites
- **Latency**: Real-time processing with 1-2 minute BigQuery latency
- **Concurrency**: Auto-scaling based on message queue depth
- **Cost**: Pay-per-use with scale-to-zero when idle

### Security Model

- **Service-to-Service**: OIDC token authentication via Pub/Sub
- **External Access**: Unauthenticated endpoints (required for Pub/Sub push)
- **Data Security**: All traffic over HTTPS, no persistent storage
- **IAM**: Least-privilege service account permissions

## 📄 Additional Resources

- [Architecture Documentation](./architecture.md) - Detailed system design
- [Refactor Recommendations](./refactor_recommendations.md) - Future enhancements
- [Configuration Reference](./config.sh) - All available settings

## 🤝 Contributing

This is a production-tested system. For enhancements:
1. Review architecture documentation
2. Test changes in isolated project
3. Update documentation for any new manual steps
4. Verify end-to-end data flow

## 📞 Support

For issues:
1. Check troubleshooting section above
2. Review Cloud Run and Pub/Sub logs
3. Verify BigQuery write metadata configuration
4. Ensure all manual steps completed

---

**Status**: ✅ Production Ready | **Last Tested**: July 2025 | **Success Rate**: 91.2%