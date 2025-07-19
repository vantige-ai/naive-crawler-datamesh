# AI Assistant Guide - GCP Serverless Web Crawler

**For AI assistants helping users with this codebase**

## 🎯 Overview

This is a **production-ready, serverless web crawler** built on Google Cloud Platform. It automatically discovers URLs using Firecrawl API and converts web pages to Markdown format, storing results in BigQuery for analytics.

### Key Characteristics
- **Enterprise-grade**: Production-tested with 9,876+ messages processed
- **Centralized configuration**: Template-based system for easy customization
- **Security-first**: Sensitive data removed, git-ignored configuration files
- **Multi-environment**: Supports multiple crawler instances in same project

## 📂 Codebase Structure

### Core Application Code
```
url_mapper/          # Go service - discovers URLs via Firecrawl API
page_processor/      # Go service - fetches pages, converts to Markdown
scripts/             # Deployment and infrastructure scripts
templates/           # Template files for documentation generation
```

### Configuration System
```
setup.sh            # Interactive setup - creates config.sh
variables.sh         # Centralized config (git-ignored)
config.sh           # Deployment config (git-ignored)
.env.example        # Setup instructions
config.sh.template  # Template for sharing
```

### Documentation
```
README.md           # User-facing documentation (generated from template)
architecture.md     # System architecture (generated from template)
SETUP_README.md     # Quick start for new users
AI.md              # This file - for AI assistants
settings.md        # Real project values (git-ignored)
```

## 🔧 How the Configuration System Works

### Template-Based Generation
1. **Templates**: All documentation files are generated from `templates/*.template`
2. **Variables**: Centralized in `variables.sh` (or user runs `setup.sh`)
3. **Generation**: `scripts/generate_docs.sh` replaces `{{placeholders}}` with real values
4. **Security**: Real values never committed to version control

### Key Template Variables
- `{{EXAMPLE_PROJECT_ID}}` → User's GCP project
- `{{EXAMPLE_DOMAIN}}` → Target domain to crawl
- `{{EXAMPLE_API_KEY}}` → Firecrawl API key
- `{{DEFAULT_CRAWLER_ID}}` → Unique crawler identifier
- `{{DEFAULT_REGION}}` → GCP region

## 🚨 Critical Security Considerations

### Files That Contain Sensitive Data (Never Commit)
- `config.sh` - Real deployment configuration
- `variables.sh` - Centralized real values  
- `settings.md` - Production values backup
- `.env` files with real values

### Files Safe to View/Edit
- `*.template` files - Contains `{{placeholders}}`
- `README.md` - Generated, should not contain real values
- `architecture.md` - Generated, should not contain real values
- `SETUP_README.md` - Generic setup instructions

### Git-Ignored Files
Check `.gitignore` for complete list. Key ones:
```
config.sh
variables.sh
settings.md
.backup/
```

## 🛠️ When Users Ask For Help

### Configuration Changes
1. **Never edit generated files directly** (README.md, architecture.md)
2. **Edit templates instead**: `templates/*.template`
3. **Regenerate docs**: `./scripts/generate_docs.sh`
4. **Or run setup**: `./setup.sh` for complete reconfiguration

### New Deployments
1. **Use setup.sh**: `./setup.sh` creates all config files
2. **Deploy infrastructure**: `./scripts/setup_infra.sh`
3. **Deploy services**: `./scripts/deploy.sh`
4. **Manual steps required**: BigQuery write metadata (UI only)

### Multiple Environments
- Each crawler needs unique `CRAWLER_ID`
- Resources are prefixed with crawler ID
- Same project, different resource names
- Separate BigQuery tables

## 📋 Common User Requests & Responses

### "How do I deploy this?"
→ Point to SETUP_README.md, emphasize `./setup.sh` first

### "I want to change the domain/project/API key"
→ Run `./setup.sh` to reconfigure, or edit `variables.sh` + regenerate

### "The documentation shows wrong values"
→ Documentation is generated - they need to run setup or regenerate

### "Can I have multiple crawlers?"
→ Yes, use different `CRAWLER_ID` values, completely isolated

### "I'm getting authentication errors"
→ Check service account setup, BigQuery write metadata configuration

## 🔍 Troubleshooting Guide

### Template Issues
- Check for remaining `{{placeholders}}` in generated files
- Verify `variables.sh` has real values (not template placeholders)
- Regenerate docs: `./scripts/generate_docs.sh`

### Deployment Issues  
- Verify `config.sh` exists with real values
- Check GCP authentication: `gcloud auth list`
- Ensure BigQuery write metadata enabled (manual UI step)

### Configuration Problems
- User should run `./setup.sh` for clean configuration
- Check `.gitignore` to ensure sensitive files not committed
- Validate all required APIs enabled in GCP project

## 🎯 Architecture Understanding

### Data Flow
1. **Input**: User publishes domain to `{crawler-id}-input-topic`
2. **URL Discovery**: URL Mapper calls Firecrawl API, publishes URLs
3. **Processing**: Page Processor fetches pages, converts to Markdown
4. **Storage**: Results stream to BigQuery table via Pub/Sub

### Resource Naming
All resources prefixed with `CRAWLER_ID`:
- Topics: `{crawler-id}-input-topic`, `{crawler-id}-urls-topic`, etc.
- Services: `{crawler-id}-mapper-svc`, `{crawler-id}-processor-svc`
- Tables: `{crawler-id//-/_}_raw`, `{crawler-id//-/_}_processed`

### Scaling
- Serverless auto-scaling (0-100 instances)
- Event-driven processing via Pub/Sub
- BigQuery for analytics and monitoring

## 💡 Best Practices for AI Assistants

### Reading the Codebase
1. **Check for templates first** - Don't assume generated files are authoritative
2. **Look for {{placeholders}}** - Indicates template files
3. **Verify .gitignore** - Understand what's real vs generated
4. **Read settings.md** - Contains real production values if present

### Helping Users
1. **Security first** - Never expose API keys or project IDs
2. **Template awareness** - Guide users to edit templates, not generated files  
3. **Setup process** - Always recommend `./setup.sh` for configuration
4. **Manual steps** - Warn about BigQuery UI configuration requirement

### Making Changes
1. **Edit templates** - Never edit generated documentation directly
2. **Test locally** - Use `./scripts/generate_docs.sh` to test changes
3. **Validate security** - Ensure no sensitive data in templates
4. **Update this guide** - Keep AI.md current with changes

### ⚠️ Common Deployment Issues & Solutions

#### Configuration File Setup
- **Problem**: Variables like `MAPPER_SA_NAME`, `INPUT_TOPIC_ID` not defined, causing deployment failures
- **Solution**: Use the complete `config.sh.template` as base, not just `.env.example`
- **Root Cause**: `.env.example` only has core config; full template includes derived resource names
- **Fix**: Copy from `config.sh.template` and update with real values

#### Timeout and Long-Running Operations
- **Problem**: CLI tools timeout during Cloud Run builds (typically 2-5 minutes)
- **Expected Behavior**: Scripts have 60-minute internal timeouts and retry logic
- **What to do**: Use extended timeouts (10+ minutes) for deployment commands
- **Don't panic**: If tool times out, deployment likely continues in background
- **Verification**: Check Cloud Run console or re-run deployment script

#### Authentication and IAM Issues
- **Problem**: 403 errors in Cloud Run logs after deployment
- **Root Cause**: Organization policies may prevent `--allow-unauthenticated` flag
- **Manual Fix Required**: User must configure authentication in Cloud Console
- **Process**: Go to Cloud Run service → Security tab → Adjust authentication settings
- **Alternative**: Use IAM policy bindings for specific service accounts
- **Don't attempt**: Multiple automated IAM fixes - let user handle via Console

#### BigQuery Write Metadata
- **Critical Step**: Cannot be automated via gcloud CLI as of 2024/2025
- **User Action Required**: Manual configuration in Cloud Console
- **Timing**: Must be done after infrastructure setup, before testing
- **How to Guide**: Provide direct console link and step-by-step instructions
- **Verification**: Check for data flow to BigQuery tables after configuration

## 🚀 Success Indicators

### Properly Configured System
- `config.sh` exists with real values (git-ignored)
- Generated docs contain user's actual project values
- No `{{placeholders}}` remaining in generated files
- `.gitignore` properly excludes sensitive files

### Successful Deployment
- All Pub/Sub topics and subscriptions created
- Cloud Run services deployed and running
- BigQuery tables created with proper schema
- Messages flowing from input to BigQuery storage

### Working Pipeline
- Test message: `gcloud pubsub topics publish {crawler-id}-input-topic --message '{"domain": "example.com"}'`
- Data appears in BigQuery within 1-2 minutes
- Monitoring queries return results
- Error handling gracefully manages failed URLs

Remember: This is a **production system** with **real infrastructure costs**. Always emphasize testing in isolated environments and understanding billing implications.