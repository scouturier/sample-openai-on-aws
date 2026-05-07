# Local Testing Guide

Before distributing Codex authentication to your organization, thorough local testing ensures everything works perfectly. While the `cxwb test` command handles most validation automatically, this guide covers additional scenarios and performance testing for complete confidence in your deployment.

## The Power of Automated Testing

The CLI provides comprehensive automated testing that simulates exactly what your users will experience:

```bash
poetry run cxwb test         # Basic authentication test
poetry run cxwb test --api   # Full test including Bedrock API calls
```

This single command runs through the entire user journey - installation, authentication, and Bedrock access. For most deployments, this automated testing provides sufficient validation. However, understanding what happens behind the scenes and testing edge cases helps you support users more effectively.

## Understanding Your Deployed Infrastructure

Before testing the authentication flow, you might want to verify that your AWS infrastructure deployed correctly. The CloudFormation stacks created by `cxwb deploy` contain all the necessary components for authentication.

To check your authentication stack status:

```bash
# Check the auth stack (uses the identity pool name from your deployment)
poetry run cxwb status --detailed
```

This shows the status of all your deployed stacks.

A healthy deployment shows "CREATE_COMPLETE" or "UPDATE_COMPLETE". The stack outputs contain important values like the Identity Pool ID and IAM role ARN that enable the authentication flow. While you don't need to interact with these directly, understanding they exist helps when troubleshooting.

## Examining Your Distribution Package

The package created by `cxwb package` contains everything needed for end-user installation. Understanding its contents helps you support users and troubleshoot issues.

Explore the distribution directory:

```bash
ls -la dist/
```

You'll find platform-specific executables (credential-process-macos and credential-process-linux), the configuration file with your organization's settings, and the intelligent installer script. If monitoring is enabled, you'll also see OTEL helper executables and Codex settings.

The configuration file contains your OIDC provider details and the Cognito Identity Pool ID:

```bash
cat dist/config.json | jq .
```

This configuration gets copied to the user's home directory during installation, where the credential process reads it at runtime.

## Manual Installation Testing

While `cxwb test` handles most validation, you might want to manually walk through the installation process to understand the user experience better.

Create a test environment that simulates a fresh user installation:

```bash
mkdir -p ~/test-user
cp -r dist ~/test-user/
cd ~/test-user/dist
./install.sh
```

The installer detects your platform, copies the appropriate binary to `~/codex-with-bedrock/`, and configures the AWS CLI profile. This mimics exactly what your users will experience.

Test the authentication:

```bash
aws sts get-caller-identity --profile Codex
```

On first run, a browser window opens for authentication. After successful login, you'll see your federated AWS identity, confirming the entire flow works correctly.

## Testing Authentication Flows

Understanding how authentication works helps you support users effectively. The credential process implements sophisticated caching to minimize authentication prompts while maintaining security.

To force a fresh authentication and observe the complete flow:

```bash
# Clear any cached credentials (this replaces them with expired dummies to preserve keychain permissions)
~/codex-with-bedrock/credential-process --clear-cache

# Trigger authentication
aws sts get-caller-identity --profile Codex
```

Your browser opens to your organization's login page. After authentication, the terminal displays your federated identity.

Credentials are cached after the first authentication. Test this by making successive calls:

```bash
# First call - includes authentication
time aws sts get-caller-identity --profile Codex

# Second call - uses cached credentials
time aws sts get-caller-identity --profile Codex
```

The first call takes 3-10 seconds including authentication. Cached calls complete in under a second. Credentials remain valid for up to 8 hours.

## Validating Bedrock Access

With authentication working, verify that users can access Amazon Bedrock models as intended. Start by listing available Bedrock models:

```bash
aws bedrock list-foundation-models \
  --profile Codex \
  --region us-west-2 \
  --query 'modelSummaries[?contains(modelId, `openai`)].[modelId,modelName]' \
  --output table
```

This confirms your IAM permissions grant access to Bedrock models. For a complete end-to-end test, invoke a Bedrock model:

```bash
# Create a simple test prompt
echo '{
  "messages": [{"role": "user", "content": "Say hello!"}],
  "max_tokens": 50
}' > test-prompt.json

# Invoke Bedrock model
aws bedrock-runtime invoke-model \
  --profile Codex \
  --region us-west-2 \
  --model-id openai.gpt-5.4 \
  --body fileb://test-prompt.json \
  response.json

# View the response
jq -r '.choices[0].message.content' response.json
```

## Codex Integration

The ultimate test involves using Codex with your authentication system. Set the AWS profile environment variable:

```bash
export AWS_PROFILE=Codex
```

If you enabled monitoring, verify the Codex settings were installed correctly:

```bash
cat ~/.codex/settings.json | jq '.env.OTEL_EXPORTER_OTLP_ENDPOINT'
```

Now launch Codex:

```bash
codex
```

Codex automatically uses the AWS profile for authentication. Behind the scenes, it calls the credential process whenever it needs to access Bedrock, with all authentication handled transparently.

### Important: AWS Credential Precedence

When testing, be aware that AWS CLI uses the following credential precedence order:

1. **Environment variables** (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`) - highest priority
2. Command line options
3. Environment variable `AWS_PROFILE`
4. Credential process from AWS config
5. Config file credentials
6. Instance metadata

If you have AWS credentials in environment variables (e.g., from other tools like Isengard), they will override the Codex profile. To ensure you're using the Codex authentication:

```bash
# Clear any existing AWS credentials from environment
unset AWS_ACCESS_KEY_ID
unset AWS_SECRET_ACCESS_KEY
unset AWS_SESSION_TOKEN

# Then use the Codex profile
export AWS_PROFILE=Codex
aws sts get-caller-identity
```
