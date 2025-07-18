# Manual Configuration Steps

## Critical Manual Steps Required After Infrastructure Setup

### 1. BigQuery Write Metadata Configuration (REQUIRED)

**Why this is needed**: Google Cloud CLI doesn't support configuring BigQuery write metadata for Pub/Sub subscriptions as of 2025. This must be done through the console.

**When to do this**: After running `./scripts/setup_infra.sh` but before running `./scripts/deploy.sh`

#### Step-by-Step Instructions:

1. **Open the subscription in Google Cloud Console**
   - The setup script will provide a direct link
   - Or navigate to: Pub/Sub → Subscriptions → `{crawler-id}-raw-data-sub`

2. **Click 'EDIT' at the top of the page**

3. **Find 'BigQuery settings' section**

4. **Configure these exact settings:**
   - ✅ **Write metadata: ENABLED** (CRITICAL - without this, no data will flow)
   - ❌ Use topic schema: DISABLED
   - ❌ Drop unknown fields: DISABLED

5. **Verify the table path:**
   - Should be: `{project-id}.crawler.{crawler_id}_raw`
   - Example: `my-project.crawler.qa_test_raw`

6. **Click 'UPDATE' to save**

**How to verify it worked**: 
- The subscription detail page should show "Write metadata: Enabled"
- After deploying and testing, data should appear in BigQuery within 1-2 minutes

### 2. Cloud Run Authentication (If Needed)

**Why this might be needed**: If you see 403 authentication errors in logs after deployment.

**When to do this**: After running `./scripts/deploy.sh` if you see authentication errors

#### For each service (`{crawler-id}-mapper-svc` and `{crawler-id}-processor-svc`):

1. Go to Cloud Run in Google Cloud Console
2. Click on the service name
3. Click the 'Security' tab
4. Uncheck "Require authentication"
5. Click 'Save'

**Alternative**: Set `ALLOW_UNAUTHENTICATED="true"` in your config.sh before deployment

### 3. Monitoring Setup (Optional but Recommended)

1. **Create BigQuery Views**:
   ```bash
   ./scripts/create_bigquery_views.sh
   ```

2. **Set up Alerts**:
   - Go to Monitoring → Alerting
   - Create alerts for:
     - Cloud Run error rates > 5%
     - Pub/Sub undelivered messages > 100
     - BigQuery insertion errors

### Common Issues and Solutions

#### No data in BigQuery after testing
- **Check**: Is "Write metadata" enabled on the subscription?
- **Check**: Run `gcloud logging read` to see if messages are being processed
- **Check**: Verify the BigQuery table name matches exactly

#### 403 Authentication Errors
- **Solution**: Disable authentication requirement on Cloud Run services (see step 2)
- **Alternative**: Ensure service accounts have proper IAM roles

#### Build Timeouts During Deployment
- **Solution**: The deploy script has retry logic, but you can increase timeout:
  ```bash
  gcloud config set builds/timeout 3600  # 1 hour
  ```

### Testing Your Setup

After completing manual configuration:

```bash
# Send test message
gcloud pubsub topics publish {crawler-id}-input-topic \
  --message '{"domain": "example.com", "uid": "test-001"}' \
  --project={project-id}

# Wait 2 minutes, then check BigQuery
bq query --use_legacy_sql=false \
  "SELECT COUNT(*) FROM \`{project-id}.crawler.{crawler_id}_raw\`"
```

If count > 0, your setup is working correctly!