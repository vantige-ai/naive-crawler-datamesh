#!/bin/bash

# Teardown script for Unified Crawler
# This script removes all resources created by setup_infra.sh and deploy.sh

# Exit immediately if a command exits with a non-zero status.
set -e

# --- 1. Load Configuration ---
echo "🚀 Loading configuration..."
SOURCE_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "$SOURCE_DIR/../config.sh"

echo "⚠️  DANGER: This will DELETE all resources for CRAWLER_ID: $CRAWLER_ID"
echo "   Project: $PROJECT_ID"
echo "   Region: $REGION"
echo ""
echo "Resources to be deleted:"
echo "   • Cloud Run Services: $URL_MAPPER_SERVICE_NAME, $PAGE_PROCESSOR_SERVICE_NAME"
echo "   • Pub/Sub Topics: $INPUT_TOPIC_ID, $URL_TOPIC_ID, $OUTPUT_TOPIC_ID"
echo "   • Pub/Sub Subscriptions: $MAPPER_SUBSCRIPTION_ID, $PROCESSOR_SUBSCRIPTION_ID, $RAW_DATA_SUBSCRIPTION_ID"
echo "   • Service Accounts: $MAPPER_SA_NAME, $PROCESSOR_SA_NAME"
echo "   • BigQuery Tables: $BQ_DATASET.$BQ_RAW_TABLE, $BQ_DATASET.$BQ_PROCESSED_TABLE"
echo "   • BigQuery Views: All views in $BQ_DATASET dataset"
echo ""
read -p "Are you sure you want to proceed? (type 'yes' to confirm): " confirmation

if [ "$confirmation" != "yes" ]; then
    echo "❌ Teardown cancelled."
    exit 0
fi

echo "🧹 Starting teardown process..."

# --- 2. Delete Cloud Run Services ---
echo "🚀 Deleting Cloud Run services..."
gcloud run services delete "$URL_MAPPER_SERVICE_NAME" \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --quiet 2>/dev/null || echo "   -> Service '$URL_MAPPER_SERVICE_NAME' not found or already deleted"

gcloud run services delete "$PAGE_PROCESSOR_SERVICE_NAME" \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --quiet 2>/dev/null || echo "   -> Service '$PAGE_PROCESSOR_SERVICE_NAME' not found or already deleted"

echo "✅ Cloud Run services deleted."

# --- 3. Delete Pub/Sub Subscriptions ---
echo "🚀 Deleting Pub/Sub subscriptions..."
gcloud pubsub subscriptions delete "$MAPPER_SUBSCRIPTION_ID" \
    --project="$PROJECT_ID" \
    --quiet 2>/dev/null || echo "   -> Subscription '$MAPPER_SUBSCRIPTION_ID' not found or already deleted"

gcloud pubsub subscriptions delete "$PROCESSOR_SUBSCRIPTION_ID" \
    --project="$PROJECT_ID" \
    --quiet 2>/dev/null || echo "   -> Subscription '$PROCESSOR_SUBSCRIPTION_ID' not found or already deleted"

gcloud pubsub subscriptions delete "$RAW_DATA_SUBSCRIPTION_ID" \
    --project="$PROJECT_ID" \
    --quiet 2>/dev/null || echo "   -> Subscription '$RAW_DATA_SUBSCRIPTION_ID' not found or already deleted"

echo "✅ Pub/Sub subscriptions deleted."

# --- 4. Delete Pub/Sub Topics ---
echo "🚀 Deleting Pub/Sub topics..."
gcloud pubsub topics delete "$INPUT_TOPIC_ID" \
    --project="$PROJECT_ID" \
    --quiet 2>/dev/null || echo "   -> Topic '$INPUT_TOPIC_ID' not found or already deleted"

gcloud pubsub topics delete "$URL_TOPIC_ID" \
    --project="$PROJECT_ID" \
    --quiet 2>/dev/null || echo "   -> Topic '$URL_TOPIC_ID' not found or already deleted"

gcloud pubsub topics delete "$OUTPUT_TOPIC_ID" \
    --project="$PROJECT_ID" \
    --quiet 2>/dev/null || echo "   -> Topic '$OUTPUT_TOPIC_ID' not found or already deleted"

echo "✅ Pub/Sub topics deleted."

# --- 5. Delete Pub/Sub Schemas ---
echo "🚀 Deleting Pub/Sub schemas..."
SCHEMA_NAME="${CRAWLER_ID}-output-schema"
gcloud pubsub schemas delete "$SCHEMA_NAME" \
    --project="$PROJECT_ID" \
    --quiet 2>/dev/null || echo "   -> Schema '$SCHEMA_NAME' not found or already deleted"

echo "✅ Pub/Sub schemas deleted."

# --- 6. Delete BigQuery Views ---
echo "🚀 Deleting BigQuery views..."
# List of all views created by the crawler
VIEWS=(
    "parsed_messages"
    "successful_crawls"
    "error_analysis"
    "daily_stats"
    "url_patterns"
    "hourly_performance"
    "domain_summary"
    "recent_activity"
    "content_analysis"
    "crawler_comparison"
)

for view in "${VIEWS[@]}"; do
    bq rm --force --project_id="$PROJECT_ID" "$BQ_DATASET.$view" 2>/dev/null || echo "   -> View '$view' not found or already deleted"
done

echo "✅ BigQuery views deleted."

# --- 7. Delete BigQuery Tables ---
echo "🚀 Deleting BigQuery tables..."
bq rm --force --project_id="$PROJECT_ID" --table "$BQ_DATASET.$BQ_RAW_TABLE" 2>/dev/null || echo "   -> Table '$BQ_RAW_TABLE' not found or already deleted"
bq rm --force --project_id="$PROJECT_ID" --table "$BQ_DATASET.$BQ_PROCESSED_TABLE" 2>/dev/null || echo "   -> Table '$BQ_PROCESSED_TABLE' not found or already deleted"

echo "✅ BigQuery tables deleted."

# --- 8. Delete Service Accounts ---
echo "🚀 Deleting service accounts..."
gcloud iam service-accounts delete "$MAPPER_SA_EMAIL" \
    --project="$PROJECT_ID" \
    --quiet 2>/dev/null || echo "   -> Service account '$MAPPER_SA_EMAIL' not found or already deleted"

gcloud iam service-accounts delete "$PROCESSOR_SA_EMAIL" \
    --project="$PROJECT_ID" \
    --quiet 2>/dev/null || echo "   -> Service account '$PROCESSOR_SA_EMAIL' not found or already deleted"

echo "✅ Service accounts deleted."

# --- 9. Clean up any remaining IAM bindings ---
echo "🚀 Cleaning up IAM bindings..."
# Remove any topic-level IAM bindings that might still exist
gcloud pubsub topics remove-iam-policy-binding "$URL_TOPIC_ID" \
    --member="serviceAccount:$MAPPER_SA_EMAIL" \
    --role="roles/pubsub.publisher" \
    --project="$PROJECT_ID" \
    --quiet 2>/dev/null || echo "   -> IAM binding for URL topic already removed"

gcloud pubsub topics remove-iam-policy-binding "$OUTPUT_TOPIC_ID" \
    --member="serviceAccount:$PROCESSOR_SA_EMAIL" \
    --role="roles/pubsub.publisher" \
    --project="$PROJECT_ID" \
    --quiet 2>/dev/null || echo "   -> IAM binding for output topic already removed"

echo "✅ IAM bindings cleaned up."

# --- 10. Summary ---
echo ""
echo "🎉 Teardown completed successfully!"
echo ""
echo "All resources for crawler '$CRAWLER_ID' have been deleted:"
echo "   ✅ Cloud Run services removed"
echo "   ✅ Pub/Sub topics and subscriptions removed"
echo "   ✅ BigQuery tables and views removed"
echo "   ✅ Service accounts removed"
echo "   ✅ IAM bindings cleaned up"
echo ""
echo "⚠️  Note: The BigQuery dataset '$BQ_DATASET' was not deleted as it may contain"
echo "   other crawler instances. Delete it manually if no longer needed:"
echo "   bq rm -r --force --project_id=$PROJECT_ID $BQ_DATASET"
echo ""
echo "💡 To recreate this crawler, run:"
echo "   ./scripts/setup_infra.sh && ./scripts/deploy.sh"