#!/bin/bash

# =============================================================================
# Documentation Generator for GCP Serverless Web Crawler
# =============================================================================
# This script generates all documentation files from templates using the
# centralized configuration in variables.sh
#
# Usage: ./scripts/generate_docs.sh [--force]
# =============================================================================

set -e

# Get script directory
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load configuration
source "$PROJECT_ROOT/variables.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Print colored output
print_status() {
    echo -e "${GREEN}✅${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠️${NC} $1"
}

print_error() {
    echo -e "${RED}❌${NC} $1"
}

print_info() {
    echo -e "${BLUE}ℹ️${NC} $1"
}

# Check if running with --force flag
FORCE_UPDATE=false
if [[ "$1" == "--force" ]]; then
    FORCE_UPDATE=true
fi

echo "🚀 GCP Serverless Web Crawler - Documentation Generator"
echo "======================================================="
echo ""

# Validate configuration
print_info "Validating configuration..."
if ! validate_config; then
    if [[ "$FORCE_UPDATE" == "false" ]]; then
        print_error "Configuration validation failed. Use --force to proceed anyway."
        exit 1
    else
        print_warning "Configuration validation failed, but proceeding due to --force flag"
    fi
fi
print_status "Configuration validated"

# Create templates directory if it doesn't exist
mkdir -p "$PROJECT_ROOT/templates"

# Function to backup existing files
backup_files() {
    print_info "Creating backup of existing files..."
    mkdir -p "$PROJECT_ROOT/$BACKUP_DIR"
    
    for file in "${TEMPLATE_FILES[@]}"; do
        if [[ -f "$PROJECT_ROOT/$file" ]]; then
            cp "$PROJECT_ROOT/$file" "$PROJECT_ROOT/$BACKUP_DIR/$file.backup.$(date +%Y%m%d_%H%M%S)"
            print_status "Backed up $file"
        fi
    done
}

# Function to substitute variables in a file
substitute_variables() {
    local input_file="$1"
    local output_file="$2"
    
    # Create a temporary file for processing
    local temp_file=$(mktemp)
    
    # Copy input to temp file
    cp "$input_file" "$temp_file"
    
    # Perform substitutions
    sed -i "" "s|{{EXAMPLE_PROJECT_ID}}|$EXAMPLE_PROJECT_ID|g" "$temp_file"
    sed -i "" "s|{{EXAMPLE_DOMAIN}}|$EXAMPLE_DOMAIN|g" "$temp_file"
    sed -i "" "s|{{EXAMPLE_API_KEY}}|$EXAMPLE_API_KEY|g" "$temp_file"
    sed -i "" "s|{{EXAMPLE_REGION}}|$EXAMPLE_REGION|g" "$temp_file"
    sed -i "" "s|{{COMPANY_NAME}}|$COMPANY_NAME|g" "$temp_file"
    sed -i "" "s|{{REPOSITORY_NAME}}|$REPOSITORY_NAME|g" "$temp_file"
    sed -i "" "s|{{DEFAULT_CRAWLER_ID}}|$DEFAULT_CRAWLER_ID|g" "$temp_file"
    sed -i "" "s|{{DEFAULT_PAGE_LIMIT}}|$DEFAULT_PAGE_LIMIT|g" "$temp_file"
    sed -i "" "s|{{DEFAULT_REGION}}|$DEFAULT_REGION|g" "$temp_file"
    sed -i "" "s|{{EXAMPLE_BIGQUERY_TABLE}}|$EXAMPLE_BIGQUERY_TABLE|g" "$temp_file"
    sed -i "" "s|{{EXAMPLE_SERVICE_URL}}|$EXAMPLE_SERVICE_URL|g" "$temp_file"
    sed -i "" "s|{{EXAMPLE_TOPIC_NAME}}|$EXAMPLE_TOPIC_NAME|g" "$temp_file"
    
    # Move temp file to output
    mv "$temp_file" "$output_file"
}

# Check if templates exist, if not create them from current files
create_templates_if_missing() {
    print_info "Checking for template files..."
    
    local templates_missing=false
    
    for file in "${TEMPLATE_FILES[@]}"; do
        local template_path="$PROJECT_ROOT/templates/$file.template"
        
        if [[ ! -f "$template_path" ]]; then
            print_warning "Template missing: $file.template"
            
            if [[ -f "$PROJECT_ROOT/$file" ]]; then
                print_info "Creating template from existing $file..."
                mkdir -p "$(dirname "$template_path")"
                
                # Convert existing file to template by replacing specific values with placeholders
                cp "$PROJECT_ROOT/$file" "$template_path"
                
                # Replace known values with template variables
                sed -i "" "s|$EXAMPLE_PROJECT_ID|{{EXAMPLE_PROJECT_ID}}|g" "$template_path"
                sed -i "" "s|$EXAMPLE_DOMAIN|{{EXAMPLE_DOMAIN}}|g" "$template_path"
                sed -i "" "s|$EXAMPLE_API_KEY|{{EXAMPLE_API_KEY}}|g" "$template_path"
                sed -i "" "s|your-project-id|{{EXAMPLE_PROJECT_ID}}|g" "$template_path"
                sed -i "" "s|example\\.com|{{EXAMPLE_DOMAIN}}|g" "$template_path"
                sed -i "" "s|fc-your-api-key-here|{{EXAMPLE_API_KEY}}|g" "$template_path"
                sed -i "" "s|Your Company Name|{{COMPANY_NAME}}|g" "$template_path"
                
                print_status "Created template: $file.template"
            else
                print_error "Cannot create template for $file - source file doesn't exist"
                templates_missing=true
            fi
        fi
    done
    
    if [[ "$templates_missing" == "true" ]]; then
        print_error "Some templates are missing and couldn't be created"
        exit 1
    fi
}

# Generate documentation files
generate_docs() {
    print_info "Generating documentation files..."
    
    for file in "${TEMPLATE_FILES[@]}"; do
        local template_path="$PROJECT_ROOT/templates/$file.template"
        local output_path="$PROJECT_ROOT/$file"
        
        if [[ -f "$template_path" ]]; then
            print_info "Processing $file..."
            substitute_variables "$template_path" "$output_path"
            print_status "Generated $file"
        else
            print_warning "Template not found: $file.template"
        fi
    done
}

# Main execution
main() {
    # Backup existing files
    backup_files
    
    # Create templates if missing
    create_templates_if_missing
    
    # Generate documentation
    generate_docs
    
    echo ""
    print_status "Documentation generation complete!"
    echo ""
    print_info "Generated files:"
    for file in "${TEMPLATE_FILES[@]}"; do
        if [[ -f "$PROJECT_ROOT/$file" ]]; then
            echo "  ✅ $file"
        else
            echo "  ❌ $file (failed)"
        fi
    done
    
    echo ""
    print_info "Next steps:"
    echo "  1. Review the generated files"
    echo "  2. Update variables.sh if needed"
    echo "  3. Re-run this script to regenerate documentation"
    echo "  4. Backups are stored in $BACKUP_DIR/"
    echo ""
    print_warning "Remember: Never commit real API keys to version control!"
}

# Run main function
main "$@"