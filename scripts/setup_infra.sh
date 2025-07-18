#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# Track if we need to clean up on failure
CLEANUP_ON_FAILURE=false

# Function to handle errors
error_handler() {
    echo "❌ Error occurred in setup script at line $1"
    if [ "$CLEANUP_ON_FAILURE" = true ]; then
        echo "   Run ./scripts/teardown.sh to clean up partial resources"
    fi
    exit 1
}

# Set error trap
trap 'error_handler $LINENO' ERR

# --- 1. Load Configuration ---
echo "🚀 Loading configuration..."
SOURCE_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "$SOURCE_DIR/../config.sh"

echo "✅ Configuration loaded for CRAWLER_ID: $CRAWLER_ID"
echo "   Project: $PROJECT_ID"
echo "   Region: $REGION"

# --- 2. Enable Required GCP Services ---
echo "🚀 Enabling required GCP services..."
gcloud services enable \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  pubsub.googleapis.com \
  bigquery.googleapis.com \
  iam.googleapis.com \
  --project=$PROJECT_ID --quiet

echo "✅ Services enabled."

# --- 2a. Ensure Pub/Sub Service Agent Exists and Has Correct Role ---
echo "🚀 Ensuring Pub/Sub Service Agent is ready..."
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format='value(projectNumber)')
GCP_PUBSUB_SA="service-${PROJECT_NUMBER}@gcp-sa-pubsub.iam.gserviceaccount.com"

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${GCP_PUBSUB_SA}" \
    --role="roles/pubsub.serviceAgent" \
    --quiet

echo "✅ Pub/Sub Service Agent role granted."

# --- 3. Create Service Accounts ---
echo "🚀 Creating Service Accounts..."
# Create Mapper Service Account
gcloud iam service-accounts create $MAPPER_SA_NAME \
  --display-name="URL Mapper Service Account for $CRAWLER_ID" \
  --project=$PROJECT_ID \
  --quiet || echo "   -> Mapper SA '$MAPPER_SA_NAME' already exists."

# Create Processor Service Account
gcloud iam service-accounts create $PROCESSOR_SA_NAME \
  --display-name="Page Processor Service Account for $CRAWLER_ID" \
  --project=$PROJECT_ID \
  --quiet || echo "   -> Processor SA '$PROCESSOR_SA_NAME' already exists."

echo "✅ Service Accounts created or verified."

# --- 4. Create Pub/Sub Topics ---
echo "🚀 Creating Pub/Sub Topics..."
# Create Input Topic
gcloud pubsub topics create $INPUT_TOPIC_ID --project=$PROJECT_ID \
  --quiet || echo "   -> Input Topic '$INPUT_TOPIC_ID' already exists."

# Create URL Topic
gcloud pubsub topics create $URL_TOPIC_ID --project=$PROJECT_ID \
  --quiet || echo "   -> URL Topic '$URL_TOPIC_ID' already exists."

# Create Output Topic with Schema
echo "   -> Defining schema for Output Topic..."
SCHEMA_FILE=$(mktemp)
cat > $SCHEMA_FILE <<EOF
{
    "type": "record",
    "name": "CrawlerOutput",
    "fields": [
        {"name": "url", "type": "string"},
        {"name": "markdown", "type": "string"},
        {"name": "timestamp", "type": "string"}
    ]
}
EOF
SCHEMA_NAME="${CRAWLER_ID}-output-schema"
gcloud pubsub schemas create $SCHEMA_NAME --type=AVRO --definition-file=$SCHEMA_FILE --project=$PROJECT_ID \
  --quiet || echo "   -> Schema '$SCHEMA_NAME' already exists."
rm $SCHEMA_FILE

gcloud pubsub topics create $OUTPUT_TOPIC_ID \
  --project=$PROJECT_ID \
  --message-encoding=JSON \
  --schema=$SCHEMA_NAME \
  --quiet || echo "   -> Output Topic '$OUTPUT_TOPIC_ID' already exists."

echo "✅ Pub/Sub Topics created."

# --- 5. Grant IAM Permissions for Pub/Sub ---
echo "🚀 Granting IAM permissions for Pub/Sub..."
# Grant Mapper SA permission to publish to the URL topic
gcloud pubsub topics add-iam-policy-binding $URL_TOPIC_ID \
  --member="serviceAccount:$MAPPER_SA_EMAIL" \
  --role="roles/pubsub.publisher" \
  --project=$PROJECT_ID \
  --quiet

# Grant Processor SA permission to publish to the Output topic
gcloud pubsub topics add-iam-policy-binding $OUTPUT_TOPIC_ID \
  --member="serviceAccount:$PROCESSOR_SA_EMAIL" \
  --role="roles/pubsub.publisher" \
  --project=$PROJECT_ID \
  --quiet

echo "✅ Pub/Sub IAM permissions granted."

# --- 6. Create BigQuery Resources ---
echo "🚀 Creating BigQuery Dataset and Tables..."

# Temporarily disable exit on error for BigQuery operations
set +e

# Create Dataset - always assume it exists, focus on tables
echo "   -> Checking BigQuery dataset..."
if bq ls --project_id=$PROJECT_ID 2>/dev/null | grep -q "^  $BQ_DATASET "; then
    echo "   -> Dataset '$BQ_DATASET' already exists (this is normal)."
else
    echo "   -> Creating new dataset '$BQ_DATASET'..."
    bq --location=$REGION --project_id=$PROJECT_ID mk --dataset \
        --description "Crawler data for all instances" \
        $BQ_DATASET 2>/dev/null || {
        # Check again if it exists (might have been created concurrently)
        if bq ls --project_id=$PROJECT_ID 2>/dev/null | grep -q "^  $BQ_DATASET "; then
            echo "   -> Dataset '$BQ_DATASET' exists (created by another process)."
        else
            echo "   ❌ Failed to create dataset '$BQ_DATASET'"
            exit 1
        fi
    }
fi

# Keep error handling disabled for BigQuery operations
# set -e will be re-enabled after all BigQuery operations

# Create Raw Data Table (with partitioning and clustering)
echo "   -> Checking raw data table..."
if bq ls --project_id=$PROJECT_ID $BQ_DATASET 2>/dev/null | grep -q "^  *$BQ_RAW_TABLE "; then
    echo "   -> Raw table '$BQ_RAW_TABLE' already exists."
else
    echo "   -> Creating raw data table with partitioning and clustering..."
    if ! bq --project_id=$PROJECT_ID mk --table \
      --description "Raw Pub/Sub messages with metadata" \
      --schema='subscription_name:STRING,message_id:STRING,publish_time:TIMESTAMP,data:JSON,attributes:JSON' \
      --time_partitioning_field=publish_time \
      --time_partitioning_type=DAY \
      --clustering_fields=subscription_name \
      $BQ_DATASET.$BQ_RAW_TABLE; then
        echo "   ❌ Failed to create raw table"
        exit 1
    fi
    echo "   ✅ Raw table created successfully"
fi

# Create Processed Data Table 
echo "   -> Checking processed data table..."
if bq ls --project_id=$PROJECT_ID $BQ_DATASET 2>/dev/null | grep -q "^  *$BQ_PROCESSED_TABLE "; then
    echo "   -> Processed table '$BQ_PROCESSED_TABLE' already exists."
else
    echo "   -> Creating processed data table..."
    if ! bq --project_id=$PROJECT_ID mk --table \
      --description "Processed and structured page content" \
      --schema='url:STRING,markdown:STRING,timestamp:TIMESTAMP,crawler_id:STRING,domain:STRING,status:STRING' \
      --time_partitioning_field=timestamp \
      --time_partitioning_type=DAY \
      --clustering_fields=crawler_id,domain,status \
      $BQ_DATASET.$BQ_PROCESSED_TABLE; then
        echo "   ❌ Failed to create processed table"
        exit 1
    fi
    echo "   ✅ Processed table created successfully"
fi

echo "✅ BigQuery resources created."

# Re-enable exit on error now that BigQuery operations are complete
set -e

# --- 7. Grant Pub/Sub permissions to write to BigQuery ---
echo "🚀 Granting BigQuery permissions to Pub/Sub service account..."
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format='value(projectNumber)')
PUB_SUB_SA="service-${PROJECT_NUMBER}@gcp-sa-pubsub.iam.gserviceaccount.com"

# Grant the Pub/Sub SA the BigQuery Data Editor role at the project level.
# This is a simplified approach to avoid gcloud CLI issues.
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${PUB_SUB_SA}" \
    --role="roles/bigquery.dataEditor" \
    --quiet

echo "   -> Waiting 30 seconds for IAM permissions to propagate..."
sleep 30

# --- 8. Create Pub/Sub to BigQuery Subscriptions ---
echo "🚀 Creating Pub/Sub to BigQuery Subscriptions..."

# Create subscription for raw data (all output messages go to raw table)
echo "   -> Creating raw data subscription..."
gcloud pubsub subscriptions create $RAW_DATA_SUBSCRIPTION_ID \
  --topic=$OUTPUT_TOPIC_ID \
  --bigquery-table="$PROJECT_ID:$BQ_DATASET.$BQ_RAW_TABLE" \
  --project=$PROJECT_ID \
  --quiet || echo "   -> Raw data subscription '$RAW_DATA_SUBSCRIPTION_ID' already exists."

echo "✅ Pub/Sub to BigQuery subscriptions established."

# Important note about manual configuration
echo ""
echo "⚠️  MANUAL CONFIGURATION REQUIRED:"
echo ""
echo "   📋 STEP 1: Configure BigQuery Write Metadata"
echo "   The BigQuery subscription '$RAW_DATA_SUBSCRIPTION_ID' needs 'Write metadata' enabled."
echo "   "
echo "   📋 STEP-BY-STEP CONFIGURATION:"
echo "   "
echo "   1. Open Google Cloud Console:"
echo "      https://console.cloud.google.com/cloudpubsub/subscription/detail/$RAW_DATA_SUBSCRIPTION_ID?project=$PROJECT_ID"
echo "   "
echo "   2. Click 'EDIT' at the top of the page"
echo "   "
echo "   3. In the 'Delivery type' section, find 'BigQuery settings'"
echo "   "
echo "   4. Configure the following BigQuery settings:"
echo "      📍 Delivery type: Write to BigQuery"
echo "      📍 BigQuery table: $PROJECT_ID.$BQ_DATASET.$BQ_RAW_TABLE"
echo ""
echo "   5. Schema Configuration:"
echo "      ❌ Use topic schema: DISABLED (unchecked)"
echo "      ✅ Write metadata: ENABLED (checked) ⭐ CRITICAL"
echo "      ❌ Drop unknown fields: DISABLED (unchecked)"
echo ""
echo "   6. Advanced Settings (recommended):"
echo "      📍 Message retention: 1 day (86400s)"
echo "      📍 Acknowledgment deadline: 10 seconds"
echo "      📍 Exactly-once delivery: DISABLED"
echo "      📍 Message ordering: DISABLED"
echo "      📍 Dead letter policy: DISABLED"
echo "      📍 Retry policy: Retry immediately"
echo "   "
echo "   7. Verify BigQuery table settings:"
echo "      📍 Table: $PROJECT_ID.$BQ_DATASET.$BQ_RAW_TABLE"
echo "      📍 Write metadata adds these columns automatically:"
echo "         • subscription_name (STRING)"
echo "         • message_id (STRING)" 
echo "         • publish_time (TIMESTAMP)"
echo "         • data (JSON) - your message content"
echo "         • attributes (JSON) - message attributes"
echo "   "
echo "   8. Click 'UPDATE' to save changes"
echo "   "
echo "   ⚡ EXPECTED RESULT:"
echo "   When properly configured, each Pub/Sub message will create a BigQuery row with:"
echo "   • The message payload in the 'data' column (JSON)"
echo "   • Metadata fields for tracking and debugging"
echo "   • Automatic partitioning by publish_time (daily partitions)"
echo "   "
echo "   🚨 TROUBLESHOOTING:"
echo "   • If 'Write metadata' option is missing, ensure the subscription delivery type is 'BigQuery'"
echo "   • Table schema will be automatically managed - do not manually modify"
echo "   • Messages will appear in BigQuery within 1-2 minutes of publishing"
echo "   "
echo "   📖 Note: This manual step is required because gcloud CLI doesn't support"
echo "           BigQuery write metadata configuration as of 2024/2025."
echo ""
echo "   📋 STEP 2: Configure Cloud Run Authentication"
echo "   After deployment, you may need to adjust Cloud Run authentication settings:"
echo ""
echo "   • If you see 403 authentication errors in logs, the services need to allow"
echo "     unauthenticated requests for Pub/Sub push subscriptions to work"
echo "   • Go to Cloud Run console for each service:"
echo "     - $URL_MAPPER_SERVICE_NAME"
echo "     - $PAGE_PROCESSOR_SERVICE_NAME"
echo "   • Click 'Security' tab → Uncheck 'Require authentication'"
echo "   • Or set ALLOW_UNAUTHENTICATED=\"true\" in config.sh before deployment"

# --- 9. Verify All Resources ---
echo ""
echo "🔍 Verifying infrastructure setup..."

# Check topics
echo "   Topics created:"
TOPIC_COUNT=$(gcloud pubsub topics list --project=$PROJECT_ID --filter="name ~ $CRAWLER_ID" --format="value(name)" | wc -l)
echo "   - Found $TOPIC_COUNT topics (expected 3)"

# Check service accounts
echo "   Service accounts:"
for SA in "$MAPPER_SA_EMAIL" "$PROCESSOR_SA_EMAIL"; do
    if gcloud iam service-accounts describe "$SA" --project=$PROJECT_ID &>/dev/null; then
        echo "   - ✅ $SA"
    else
        echo "   - ❌ $SA (missing)"
    fi
done

# Check BigQuery tables
echo "   BigQuery tables:"
for TABLE in "$BQ_RAW_TABLE" "$BQ_PROCESSED_TABLE"; do
    if bq ls --project_id=$PROJECT_ID $BQ_DATASET 2>/dev/null | grep -q "^  *$TABLE "; then
        echo "   - ✅ $BQ_DATASET.$TABLE"
    else
        echo "   - ❌ $BQ_DATASET.$TABLE (missing)"
    fi
done

# Check BigQuery subscription
echo "   BigQuery subscription:"
if gcloud pubsub subscriptions describe "$RAW_DATA_SUBSCRIPTION_ID" --project=$PROJECT_ID &>/dev/null; then
    echo "   - ✅ $RAW_DATA_SUBSCRIPTION_ID (created)"
    echo "   - ⚠️  IMPORTANT: Enable 'Write metadata' manually (see detailed instructions above)"
    echo "   - 🔗 Direct link: https://console.cloud.google.com/cloudpubsub/subscription/detail/$RAW_DATA_SUBSCRIPTION_ID?project=$PROJECT_ID"
else
    echo "   - ❌ $RAW_DATA_SUBSCRIPTION_ID (missing)"
fi

echo ""
echo "✅ All infrastructure has been successfully provisioned!"
echo ""
echo "📋 NEXT STEPS:"
echo "   1. Run the deployment script: ./scripts/deploy.sh"
echo "   2. ⚠️  REQUIRED: Configure BigQuery write metadata (see detailed instructions above)"
echo "   3. ⚠️  REQUIRED: If you see 403 errors, adjust Cloud Run authentication (see Step 2 above)"
echo "   4. Test the pipeline with a crawl request"
echo ""
echo "🧪 TESTING COMMANDS (after deployment):"
echo "   # Test the crawler with Wood Mackenzie (oil & gas consulting)"
echo "   gcloud pubsub topics publish $INPUT_TOPIC_ID \\"
echo "     --message '{\"domain\": \"www.woodmac.com\"}' \\"
echo "     --project=$PROJECT_ID"
echo ""
echo "   # Monitor progress in BigQuery (after configuring write metadata)"
echo "   bq query --use_legacy_sql=false \\"
echo "     'SELECT COUNT(*) as messages, MAX(publish_time) as latest \\"
echo "      FROM \`$PROJECT_ID.$BQ_DATASET.$BQ_RAW_TABLE\` \\"
echo "      WHERE DATE(publish_time) = CURRENT_DATE()'"
echo ""
echo "   # View processed results"
echo "   bq query --use_legacy_sql=false \\"
echo "     'SELECT url, status, timestamp \\"
echo "      FROM \`$PROJECT_ID.crawler.crawler_basic_processed\` \\"
echo "      WHERE DATE(timestamp) = CURRENT_DATE() \\"
echo "      ORDER BY timestamp DESC LIMIT 10'"
