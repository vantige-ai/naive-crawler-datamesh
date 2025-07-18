#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# --- 1. Load Configuration ---
echo "🚀 Loading configuration..."
SOURCE_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "$SOURCE_DIR/../config.sh"

echo "✅ Configuration loaded for CRAWLER_ID: $CRAWLER_ID"

# --- 2. Create Useful BigQuery Views ---
echo "🚀 Creating BigQuery views for data analysis..."

# Create a view for parsed raw data
echo "   -> Creating parsed_messages view..."
bq --project_id=$PROJECT_ID query --use_legacy_sql=false "
CREATE OR REPLACE VIEW \`$PROJECT_ID.$BQ_DATASET.parsed_messages\` AS
SELECT 
  subscription_name,
  message_id,
  publish_time,
  JSON_VALUE(data, '$.url') as url,
  JSON_VALUE(data, '$.crawler_id') as crawler_id,
  JSON_VALUE(data, '$.domain') as domain,
  JSON_VALUE(data, '$.status') as status,
  JSON_VALUE(data, '$.timestamp') as processed_timestamp,
  LENGTH(JSON_VALUE(data, '$.markdown')) as markdown_length,
  JSON_VALUE(data, '$.markdown') as markdown_content
FROM \`$PROJECT_ID.$BQ_DATASET.$BQ_RAW_TABLE\`
WHERE JSON_VALUE(data, '$.url') IS NOT NULL
"

# Create a summary view for crawler statistics
echo "   -> Creating crawler_stats view..."
bq --project_id=$PROJECT_ID query --use_legacy_sql=false "
CREATE OR REPLACE VIEW \`$PROJECT_ID.$BQ_DATASET.crawler_stats\` AS
SELECT 
  JSON_VALUE(data, '$.crawler_id') as crawler_id,
  JSON_VALUE(data, '$.domain') as domain,
  JSON_VALUE(data, '$.status') as status,
  DATE(publish_time) as crawl_date,
  COUNT(*) as page_count,
  AVG(LENGTH(JSON_VALUE(data, '$.markdown'))) as avg_content_length,
  MIN(publish_time) as first_crawl,
  MAX(publish_time) as last_crawl
FROM \`$PROJECT_ID.$BQ_DATASET.$BQ_RAW_TABLE\`
WHERE JSON_VALUE(data, '$.url') IS NOT NULL
GROUP BY 1, 2, 3, 4
ORDER BY crawl_date DESC, crawler_id, domain
"

# Create a view for error analysis
echo "   -> Creating error_analysis view..."
bq --project_id=$PROJECT_ID query --use_legacy_sql=false "
CREATE OR REPLACE VIEW \`$PROJECT_ID.$BQ_DATASET.error_analysis\` AS
SELECT 
  JSON_VALUE(data, '$.crawler_id') as crawler_id,
  JSON_VALUE(data, '$.domain') as domain,
  JSON_VALUE(data, '$.url') as failed_url,
  JSON_VALUE(data, '$.markdown') as error_message,
  publish_time,
  DATE(publish_time) as error_date
FROM \`$PROJECT_ID.$BQ_DATASET.$BQ_RAW_TABLE\`
WHERE JSON_VALUE(data, '$.status') = 'error'
ORDER BY publish_time DESC
"

echo "✅ BigQuery views created successfully!"
echo ""
echo "Available views:"
echo "  • \`$PROJECT_ID.$BQ_DATASET.parsed_messages\` - Structured view of all crawled data"
echo "  • \`$PROJECT_ID.$BQ_DATASET.crawler_stats\` - Summary statistics by crawler/domain/date"
echo "  • \`$PROJECT_ID.$BQ_DATASET.error_analysis\` - Failed URLs and error details"
echo ""
echo "Example queries:"
echo "  SELECT * FROM \`$PROJECT_ID.$BQ_DATASET.crawler_stats\` WHERE crawler_id = '$CRAWLER_ID'"
echo "  SELECT * FROM \`$PROJECT_ID.$BQ_DATASET.error_analysis\` WHERE crawler_id = '$CRAWLER_ID'"