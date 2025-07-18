#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# --- 1. Load Configuration ---
echo "🚀 Loading configuration..."
SOURCE_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "$SOURCE_DIR/../config.sh"

echo "✅ Configuration loaded for CRAWLER_ID: $CRAWLER_ID"

# --- Pre-deployment Verification ---
echo ""
echo "🔍 Verifying prerequisites..."

# Check if setup_infra.sh has been run
MISSING_RESOURCES=false

# Check topics
echo -n "   Checking topics... "
TOPIC_COUNT=$(gcloud pubsub topics list --project=$PROJECT_ID --filter="name ~ $CRAWLER_ID" --format="value(name)" 2>/dev/null | wc -l)
if [ "$TOPIC_COUNT" -eq 3 ]; then
    echo "✅"
else
    echo "❌ (found $TOPIC_COUNT, expected 3)"
    MISSING_RESOURCES=true
fi

# Check service accounts
echo -n "   Checking service accounts... "
SA_COUNT=0
for SA in "$MAPPER_SA_EMAIL" "$PROCESSOR_SA_EMAIL"; do
    if gcloud iam service-accounts describe "$SA" --project=$PROJECT_ID &>/dev/null; then
        SA_COUNT=$((SA_COUNT + 1))
    fi
done
if [ "$SA_COUNT" -eq 2 ]; then
    echo "✅"
else
    echo "❌ (found $SA_COUNT, expected 2)"
    MISSING_RESOURCES=true
fi

# Check BigQuery tables
echo -n "   Checking BigQuery tables... "
TABLE_COUNT=0
for TABLE in "$BQ_RAW_TABLE" "$BQ_PROCESSED_TABLE"; do
    if bq ls --project_id=$PROJECT_ID $BQ_DATASET 2>/dev/null | grep -q "^  *$TABLE "; then
        TABLE_COUNT=$((TABLE_COUNT + 1))
    fi
done
if [ "$TABLE_COUNT" -eq 2 ]; then
    echo "✅"
else
    echo "❌ (found $TABLE_COUNT, expected 2)"
    MISSING_RESOURCES=true
fi

if [ "$MISSING_RESOURCES" = true ]; then
    echo ""
    echo "❌ Missing required resources. Please run ./scripts/setup_infra.sh first."
    exit 1
fi

echo "   ✅ All prerequisites satisfied"
echo ""

# --- Helper Functions ---
# Function to deploy Cloud Run service with retry logic
deploy_service() {
    local SERVICE_NAME=$1
    local SOURCE_DIR=$2
    local SERVICE_ACCOUNT=$3
    local ENV_VARS=$4
    local MAX_RETRIES=3
    local RETRY_COUNT=0
    
    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        echo "   Attempt $((RETRY_COUNT + 1)) of $MAX_RETRIES..."
        
        # Deploy with increased timeout
        # Set memory based on service type (1Gi for processor, 512Mi for mapper)
        local MEMORY_SIZE="512Mi"
        if [[ "$SERVICE_NAME" == *"processor"* ]]; then
            MEMORY_SIZE="1Gi"
        fi
        
        if gcloud run deploy "$SERVICE_NAME" \
            --source "$SOURCE_DIR" \
            --platform "managed" \
            --region "$REGION" \
            --project="$PROJECT_ID" \
            --service-account="$SERVICE_ACCOUNT" \
            --set-env-vars="$ENV_VARS" \
            --timeout=60m \
            --memory="$MEMORY_SIZE" \
            $ALLOW_UNAUTH_FLAG \
            --quiet; then
            
            echo "   ✅ Deployment successful!"
            return 0
        else
            RETRY_COUNT=$((RETRY_COUNT + 1))
            if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
                echo "   ⚠️  Deployment failed, retrying in 10 seconds..."
                sleep 10
            fi
        fi
    done
    
    echo "   ❌ Deployment failed after $MAX_RETRIES attempts"
    return 1
}

# Function to wait for service to be ready
wait_for_service() {
    local SERVICE_NAME=$1
    local MAX_WAIT=300  # 5 minutes
    local WAIT_TIME=0
    
    echo "   Waiting for service to be ready..."
    while [ $WAIT_TIME -lt $MAX_WAIT ]; do
        if gcloud run services describe "$SERVICE_NAME" \
            --platform managed \
            --region "$REGION" \
            --project="$PROJECT_ID" \
            --format="value(status.conditions[0].status)" 2>/dev/null | grep -q "True"; then
            echo "   ✅ Service is ready!"
            return 0
        fi
        
        echo -n "."
        sleep 5
        WAIT_TIME=$((WAIT_TIME + 5))
    done
    
    echo ""
    echo "   ⚠️  Service not ready after ${MAX_WAIT} seconds"
    return 1
}

# --- 2. Deploy URL Mapper Service ---
echo "🚀 Deploying URL Mapper service: $URL_MAPPER_SERVICE_NAME..."
ALLOW_UNAUTH_FLAG=""
if [ "$ALLOW_UNAUTHENTICATED" = "true" ]; then
  ALLOW_UNAUTH_FLAG="--allow-unauthenticated"
else
  ALLOW_UNAUTH_FLAG="--no-allow-unauthenticated"
fi

# Deploy URL Mapper with retry logic
MAPPER_ENV_VARS="URL_TOPIC_ID=$URL_TOPIC_ID,PROJECT_ID=$PROJECT_ID,FIRECRAWL_API_KEY=$FIRECRAWL_API_KEY,PAGE_LIMIT=$PAGE_LIMIT"
if deploy_service "$URL_MAPPER_SERVICE_NAME" "./url_mapper" "$MAPPER_SA_EMAIL" "$MAPPER_ENV_VARS"; then
    wait_for_service "$URL_MAPPER_SERVICE_NAME"
    MAPPER_URL=$(gcloud run services describe $URL_MAPPER_SERVICE_NAME --platform managed --region $REGION --format 'value(status.url)' --project=$PROJECT_ID)
    echo "✅ URL Mapper deployed. URL: $MAPPER_URL"
    echo "   Memory: 512Mi | Authentication: IAM required (--no-allow-unauthenticated)"
else
    echo "❌ Failed to deploy URL Mapper service"
    exit 1
fi

# --- 3. Deploy Page Processor Service ---
echo "🚀 Deploying Page Processor service: $PAGE_PROCESSOR_SERVICE_NAME..."

# Deploy Page Processor with retry logic
PROCESSOR_ENV_VARS="OUTPUT_TOPIC_ID=$OUTPUT_TOPIC_ID,PROJECT_ID=$PROJECT_ID,CRAWLER_ID=$CRAWLER_ID,DOMAIN_TO_CRAWL=$DOMAIN_TO_CRAWL"
if deploy_service "$PAGE_PROCESSOR_SERVICE_NAME" "./page_processor" "$PROCESSOR_SA_EMAIL" "$PROCESSOR_ENV_VARS"; then
    wait_for_service "$PAGE_PROCESSOR_SERVICE_NAME"
    PROCESSOR_URL=$(gcloud run services describe $PAGE_PROCESSOR_SERVICE_NAME --platform managed --region $REGION --format 'value(status.url)' --project=$PROJECT_ID)
    echo "✅ Page Processor deployed. URL: $PROCESSOR_URL"
    echo "   Memory: 1Gi | Authentication: IAM required (--no-allow-unauthenticated)"
else
    echo "❌ Failed to deploy Page Processor service"
    exit 1
fi

# --- 4. Create Authenticated Pub/Sub Push Subscriptions ---
echo "🚀 Creating authenticated push subscriptions..."

# Get project number and construct Pub/Sub service account
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format='value(projectNumber)')
GCP_PUBSUB_SA_EMAIL="service-${PROJECT_NUMBER}@gcp-sa-pubsub.iam.gserviceaccount.com"

# Grant IAM permissions for Mapper
echo "   Granting IAM permissions for Mapper subscription..."
if gcloud iam service-accounts add-iam-policy-binding "$MAPPER_SA_EMAIL" \
  --member="serviceAccount:${GCP_PUBSUB_SA_EMAIL}" \
  --role="roles/iam.serviceAccountTokenCreator" \
  --project="$PROJECT_ID" \
  --quiet; then
    echo "   ✅ IAM permissions granted for Mapper"
else
    echo "   ⚠️  IAM binding might already exist (continuing...)"
fi

# Create or update Mapper subscription
echo "   Creating/updating Mapper subscription..."
if gcloud pubsub subscriptions describe "$MAPPER_SUBSCRIPTION_ID" --project="$PROJECT_ID" &>/dev/null; then
    echo "   Subscription exists, updating..."
    gcloud pubsub subscriptions update "$MAPPER_SUBSCRIPTION_ID" \
        --push-endpoint="$MAPPER_URL" \
        --push-auth-service-account="$MAPPER_SA_EMAIL" \
        --project="$PROJECT_ID" \
        --quiet
else
    echo "   Creating new subscription..."
    gcloud pubsub subscriptions create "$MAPPER_SUBSCRIPTION_ID" \
        --topic="$INPUT_TOPIC_ID" \
        --project="$PROJECT_ID" \
        --push-endpoint="$MAPPER_URL" \
        --push-auth-service-account="$MAPPER_SA_EMAIL" \
        --ack-deadline=600 \
        --quiet
fi
echo "   ✅ Mapper subscription configured"

# Grant IAM permissions for Processor
echo "   Granting IAM permissions for Processor subscription..."
if gcloud iam service-accounts add-iam-policy-binding "$PROCESSOR_SA_EMAIL" \
  --member="serviceAccount:${GCP_PUBSUB_SA_EMAIL}" \
  --role="roles/iam.serviceAccountTokenCreator" \
  --project="$PROJECT_ID" \
  --quiet; then
    echo "   ✅ IAM permissions granted for Processor"
else
    echo "   ⚠️  IAM binding might already exist (continuing...)"
fi

# Create or update Processor subscription
echo "   Creating/updating Processor subscription..."
if gcloud pubsub subscriptions describe "$PROCESSOR_SUBSCRIPTION_ID" --project="$PROJECT_ID" &>/dev/null; then
    echo "   Subscription exists, updating..."
    gcloud pubsub subscriptions update "$PROCESSOR_SUBSCRIPTION_ID" \
        --push-endpoint="$PROCESSOR_URL" \
        --push-auth-service-account="$PROCESSOR_SA_EMAIL" \
        --project="$PROJECT_ID" \
        --quiet
else
    echo "   Creating new subscription..."
    gcloud pubsub subscriptions create "$PROCESSOR_SUBSCRIPTION_ID" \
        --topic="$URL_TOPIC_ID" \
        --project="$PROJECT_ID" \
        --push-endpoint="$PROCESSOR_URL" \
        --push-auth-service-account="$PROCESSOR_SA_EMAIL" \
        --ack-deadline=600 \
        --quiet
fi
echo "   ✅ Processor subscription configured"

echo "✅ Authenticated subscriptions created/updated."

# --- 5. Verification ---
echo ""
echo "🔍 Verifying deployment..."
echo ""
echo "📊 Infrastructure Summary:"
echo "   ├── Topics (3):"
gcloud pubsub topics list --project="$PROJECT_ID" --filter="name ~ $CRAWLER_ID" --format="table[box](name.basename())" 2>/dev/null || true
echo ""
echo "   ├── Services (2):"
echo "   │   ├── URL Mapper: $MAPPER_URL (512Mi RAM)"
echo "   │   └── Page Processor: $PROCESSOR_URL (1Gi RAM)"
echo ""
echo "   ├── Subscriptions (3):"
gcloud pubsub subscriptions list --project="$PROJECT_ID" --filter="name ~ $CRAWLER_ID" --format="table[box](name.basename(),topic.basename(),pushConfig.pushEndpoint,bigqueryConfig.table.basename())" 2>/dev/null || true
echo ""
echo "   └── BigQuery Tables (2):"
bq ls --project_id=$PROJECT_ID $BQ_DATASET 2>/dev/null | grep -E "(${BQ_RAW_TABLE}|${BQ_PROCESSED_TABLE})" | awk '{print "       ├── " $1}' || true
echo ""

# Final success message
echo "🎉 Deployment complete! 🎉"
echo ""
echo "📝 Quick Start:"
echo "   To start a crawl, run:"
echo "   gcloud pubsub topics publish $INPUT_TOPIC_ID --message '{\"domain\": \"$DOMAIN_TO_CRAWL\"}' --project=$PROJECT_ID"
echo ""
echo "   To monitor crawl progress:"
echo "   bq query --use_legacy_sql=false 'SELECT COUNT(*) as urls_processed FROM \`$PROJECT_ID.$BQ_DATASET.$BQ_RAW_TABLE\` WHERE DATE(publish_time) = CURRENT_DATE()'"