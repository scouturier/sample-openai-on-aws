# Quick Start Guide

Complete deployment walkthrough for IT administrators deploying Codex with Amazon Bedrock.

**Time Required:** 2-3 hours for initial deployment
**Skill Level:** AWS administrator with IAM/CloudFormation experience

---

## Prerequisites

### Software Requirements

- Python 3.10-3.13
- Poetry (dependency management)
- AWS CLI v2
- Git

### AWS Requirements

- AWS account with appropriate IAM permissions to create:
  - CloudFormation stacks
  - IAM OIDC Providers or Cognito Identity Pools
  - IAM roles and policies
  - (Optional) Amazon Elastic Container Service (Amazon ECS) tasks and Amazon CloudWatch dashboards
  - (Optional) Amazon Athena, AWS Glue, AWS Lambda, and Amazon Data Firehose resources
  - (Optional) AWS CodeBuild
- Amazon Bedrock activated in target regions

### OIDC Provider Requirements

- Existing OIDC identity provider (Okta, Azure AD, Auth0, etc.)
- Ability to create OIDC applications
- Redirect URI support for `http://localhost:8400/callback`

### Supported AWS Regions

The guidance can be deployed in any AWS region that supports:

- IAM OIDC Providers or Amazon Cognito Identity Pools
- Amazon Bedrock
- (Optional) Amazon Elastic Container Service (Amazon ECS) tasks and Amazon CloudWatch dashboards
- (Optional) Amazon Athena, AWS Glue, AWS Lambda, and Amazon Data Firehose resources
- (Optional) AWS CodeBuild

### Bedrock Mantle and OpenAI Models

Codex on Amazon Bedrock uses **Bedrock Mantle** — AWS's native OpenAI-compatible endpoint. During setup, you select from three models:

- `openai.gpt-5.4` — **Recommended default**
- `openai.gpt-oss-120b` — GPT-OSS 120B
- `openai.gpt-oss-20b` — GPT-OSS 20B

Codex CLI is configured via `~/.codex/config.toml` with `model_provider = "amazon-bedrock"`. Authentication uses the AWS profile configured by the installer — no API key needed.

**Note:** OpenAI models on Bedrock are currently available in US regions only: us-east-1, us-east-2, us-west-2.

---

## Deployment Steps

### Step 1: Clone Repository and Install Dependencies

```bash
# Clone the repository
git clone https://github.com/aws-solutions-library-samples/guidance-for-codex-with-amazon-bedrock
cd guidance-for-codex-with-amazon-bedrock/source

# Install dependencies
poetry install
```

### Step 2: Initialize Configuration

Run the interactive setup wizard:

```bash
poetry run cxwb init
```

The wizard will guide you through:

- OIDC provider configuration (domain, client ID)
- AWS region selection for infrastructure
- Bedrock Mantle model selection (GPT-OSS 120B or 20B)
- Credential storage method (keyring or session files)
- Optional monitoring setup with VPC configuration

#### Understanding Profiles (v2.0+)

**What are profiles?** Profiles let you manage multiple deployments from one machine (different AWS accounts, regions, or organizations).

**Common use cases:**
- Production vs development accounts
- US vs EU regional deployments
- Multiple customer/tenant deployments

**Profile commands:**
- `cxwb context list` - See all profiles
- `cxwb context use <name>` - Switch between profiles
- `cxwb context show` - View active profile details

See [CLI Reference](assets/docs/CLI_REFERENCE.md) for complete command list.

**Upgrading from v1.x:** Profile configuration automatically migrates from `source/.cxwb-config/` to `~/.cxwb/` on first run. Your profile names and active profile are preserved. A timestamped backup is created automatically.

### Step 3: Deploy Infrastructure

Deploy the AWS CloudFormation stacks:

```bash
poetry run cxwb deploy
```

This creates the following AWS resources:

**Authentication Infrastructure:**

- IAM OIDC Provider or Amazon Cognito Identity Pool for OIDC federation
- IAM trust relationship for federated access
- IAM role with policies for:
  - Bedrock model invocation in specified regions
  - CloudWatch metrics (if monitoring enabled)

**Optional Monitoring Infrastructure:**

- VPC and networking resources (or integration with existing VPC)
- ECS Fargate cluster running OpenTelemetry collector
- Application Load Balancer for OTLP ingestion
- CloudWatch Log Groups and Metrics
- CloudWatch Dashboard with comprehensive usage analytics
- DynamoDB table for metrics aggregation and storage
- Lambda functions for custom dashboard widgets
- Kinesis Data Firehose for streaming metrics to S3 (if analytics enabled)
- Amazon Athena for SQL analytics on collected metrics (if analytics enabled)
- S3 bucket for long-term metrics storage (if analytics enabled)

### Step 4: Create Distribution Package

Build the package for end users:

```bash
# Build all platforms (starts Windows build in background)
poetry run cxwb package --target-platform all

# Check Windows build status (optional)
poetry run cxwb builds

# When ready, create distribution URL (optional)
poetry run cxwb distribute
```

**Package Workflow:**

1. **Local builds**: macOS/Linux executables are built locally using PyInstaller
2. **Windows builds**: Trigger AWS CodeBuild for Windows executables (20+ minutes) - requires enabling CodeBuild during `init`
3. **Check status**: Monitor build progress with `poetry run cxwb builds`
4. **Create distribution**: Use `distribute` to upload and generate presigned URLs

> **Note**: Windows builds are optional and require CodeBuild to be enabled during the `init` process. If not enabled, the package command will skip Windows builds and continue with other platforms.

The `dist/` folder will contain:

- `credential-process-macos-arm64` - Authentication executable for macOS ARM64
- `credential-process-macos-intel` - Authentication executable for macOS Intel (if built)
- `credential-process-windows.exe` - Authentication executable for Windows
- `credential-process-linux` - Authentication executable for Linux (if built on Linux)
- `config.json` - Embedded configuration
- `install.sh` - Installation script for Unix systems
- `install.bat` - Installation script for Windows
- `README.md` - User instructions
- `.codex/config.yaml` - Codex telemetry settings (if monitoring enabled)
- `otel-helper-*` - OTEL helper executables for each platform (if monitoring enabled)

The package builder:

- Automatically builds binaries for both macOS and Linux by default
- Uses Docker for cross-platform Linux builds when running on macOS
- Includes the OTEL helper for extracting user attributes from JWT tokens
- Creates a unified installer that auto-detects the user's platform

### Step 5: Test the Setup

Verify everything works correctly:

```bash
poetry run cxwb test
```

This will:

- Simulate the end-user installation process
- Test OIDC authentication
- Verify AWS credential retrieval
- Check Amazon Bedrock access
- (Optional) Test actual API calls with `--api` flag

### Step 6: Distribute Packages to Users

You have three options for sharing packages with users. The distribution method is configured during `cxwb init` (Step 2).

#### Option 1: Manual Sharing

No additional infrastructure required. Share the built packages directly:

```bash
# Navigate to dist directory
cd dist

# Create a zip file of all packages
zip -r codex-packages.zip .

# Share via email or internal file sharing
# Users extract and run install.sh (Unix) or install.bat (Windows)
```

**Best for:** Any size team, no automation required

#### Option 2: Presigned S3 URLs

Automated distribution via time-limited S3 URLs:

```bash
poetry run cxwb distribute
```

Generates presigned URLs (default 48-hour expiry) that you share with users via email or messaging.

**Best for:** Automated distribution without authentication requirements

**Setup:** Select "presigned-s3" distribution type during `cxwb init` (Step 2)

#### Option 3: Authenticated Landing Page

Self-service portal with IdP authentication:

```bash
# Deploy landing page infrastructure (if not done during Step 3)
poetry run cxwb deploy distribution

# Upload packages to landing page
poetry run cxwb distribute
```

Users visit your landing page URL, authenticate with SSO, and download packages for their platform.

**Best for:** Self-service portal with compliance and audit requirements

**Setup:** Select "landing-page" distribution type during `cxwb init` (Step 2), then deploy distribution infrastructure

See [Distribution Comparison](assets/docs/distribution/comparison.md) for detailed feature comparison and setup guides.

---

## Platform Builds

### Build Requirements

- **Windows**: AWS CodeBuild with Nuitka (automated)
- **macOS**: PyInstaller with architecture-specific builds
  - ARM64: Native build on Apple Silicon Macs
  - Intel: Optional - requires x86_64 Python environment on ARM Macs
  - Universal: Requires both architectures' Python libraries
- **Linux**: Docker with PyInstaller (for building on non-Linux hosts)

### Optional: Intel Mac Builds

Intel Mac builds require an x86_64 Python environment on Apple Silicon Macs.

See [CLI Reference - Intel Mac Build Setup](assets/docs/CLI_REFERENCE.md#intel-mac-build-setup-optional) for setup instructions.

If not configured, the package command will skip Intel builds and continue with other platforms.

---

## Cleanup

You are responsible for the costs of AWS services while running this guidance. If you decide that you no longer need the guidance, please ensure that infrastructure resources are removed.

```bash
poetry run cxwb destroy
```

---

## Troubleshooting

### Authentication Issues

Force re-authentication:

```bash
~/codex-with-bedrock/credential-process --clear-cache
```

### Build Failures

Check Windows build status:

```bash
poetry run cxwb builds
```

### Stack Deployment Issues

View stack status:

```bash
poetry run cxwb status
```

For detailed troubleshooting, see [Deployment Guide](assets/docs/DEPLOYMENT.md).

---

## Next Steps

- [Architecture Deep Dive](assets/docs/ARCHITECTURE.md) - Technical architecture details
- [Enable Monitoring](assets/docs/MONITORING.md) - Setup OpenTelemetry monitoring
- [Setup Analytics](assets/docs/ANALYTICS.md) - Configure S3 data lake and Athena queries
- [CLI Reference](assets/docs/CLI_REFERENCE.md) - Complete command reference
