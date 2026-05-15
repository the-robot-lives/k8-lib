# k8-lib — Shared Shell Library

Core shell functions and configuration templates sourced by all devops tools. Not invoked directly.

## Installation

```bash
make install    # Installs to ~/.local/share/k8-lib
```

## Configuration Files

These files are **templates**. Copy them to your project root and customize:

### config.env

Primary configuration for all tools. Controls AWS, Docker registry, Kubernetes namespaces, Infisical credentials, and Terraform settings.

```bash
cp config.env.example /path/to/project/config.env
```

| Variable | Default | Description |
|----------|---------|-------------|
| `K8_AWS_PROFILE` | `terraformer` | AWS CLI profile name |
| `K8_AWS_ACCOUNT_ID` | (empty) | AWS account ID for IAM validation |
| `K8_AWS_REGION` | `us-east-1` | AWS region |
| `K8_DOCKER_REGISTRY` | (empty) | Docker registry host (e.g., `ops.noizu.com`) |
| `K8_NAMESPACE` | `default` | Default Kubernetes namespace |
| `K8_STAGING_NAMESPACE` | `staging` | Staging namespace |
| `K8_INFRA_NAMESPACE` | `infra` | Infrastructure namespace |
| `K8_INFISICAL_HOST` | (empty) | Infisical API URL |
| `K8_INFISICAL_PROJECT_ID` | (empty) | Infisical project ID |
| `K8_INFISICAL_CLIENT_ID` | (empty) | Universal Auth client ID |
| `K8_INFISICAL_CLIENT_SECRET` | (empty) | Universal Auth client secret |
| `K8_TF_DIR` | (empty) | Terraform directory (defaults to `$REPO_ROOT/terraform/production`) |
| `K8_TF_STATE_BUCKET` | (empty) | S3 bucket for Terraform state |
| `K8_TF_KMS_ALIAS` | (empty) | KMS alias for state encryption |
| `K8_TF_LOCK_TABLE` | `terraform-lock` | DynamoDB lock table |
| `K8_CREDENTIALS_LINK` | (empty) | Link to credentials vault (1Password, etc.) |
| `K8_DIFF_VIEWER` | `code` | Diff tool for helm preview (`code`, `kdiff3`, `opendiff`, `meld`, `terminal`) |
| `K8_ADMIN_EMAIL` | `admin@example.com` | Admin email for services |

### tiers.yaml

Defines Helm deployment ordering. Each tier completes before the next begins. Charts within a tier deploy in parallel.

```yaml
tiers:
  - name: "Secrets"
    charts:
      - infisical-core
  - name: "Applications"
    charts:
      - my-app
```

### namespaces.conf

Override namespace for charts where `global.namespace` in values.yaml doesn't match the target:

```
chart-name=target-namespace
```

### timeout-overrides.conf

Per-chart Helm timeout overrides (default: 5m):

```
my-database=30m
my-backend=15m
```

## Library Scripts

| Script | Purpose |
|--------|---------|
| `bin/config.sh` | Loads `config.env`, sets defaults for all `K8_*` variables |
| `bin/common.sh` | Color output, logging helpers (`step`, `ok`, `warn`, `fail`, `die`) |
| `bin/helm-common.sh` | Tier loading, namespace resolution, environment overlays, impact analysis |
| `bin/docker-config.sh` | Registry config, repo mappings, build state tracking |
| `bin/docker-vsn.sh` | Version resolution and tag management |
| `bin/terraform.sh` | Terraform helpers |
| `bin/iam.sh` | IAM utilities |
| `bin/doctor.sh` | Health checks |
