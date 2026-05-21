# k8-lib — Shared Shell Library

Core shell functions and configuration templates sourced by all devops tools. Not invoked directly.

## Installation

```bash
make install    # Installs to ~/.local/share/k8-lib
```

## Configuration

All tools use a single **`k8-util-config.yaml`** file with an optional gitignored **`.k8-secrets.yaml`** for credentials.

### Quick Start

```bash
cp k8-util-config.yaml.example /path/to/project/k8-util-config.yaml
cp .k8-secrets.yaml.example /path/to/project/.k8-secrets.yaml
echo '.k8-secrets.yaml' >> /path/to/project/.gitignore
```

### Config Resolution

Every tool accepts `--config <path>` to specify the config file. Resolution order:

1. `--config <path>` flag
2. `K8_CONFIG` environment variable
3. `$INFRA_ROOT/k8-util-config.yaml`
4. Git-root walker (walks from CWD up through `.git` roots to `/`)
5. `$K8_LIB_DIR/k8-util-config.yaml` (library defaults)
6. Legacy fallback with deprecation warning

### k8-util-config.yaml (git-safe)

All paths are relative to the config file's directory. Contains:

| Section | Description |
|---------|-------------|
| `aws` | AWS profile, region |
| `docker` | Registry host |
| `kubernetes` | Default, staging, infra namespaces |
| `infisical` | Host, project ID (credentials in secrets file) |
| `terraform` | State bucket, KMS, lock table |
| `helm` | OCI registry, registry host |
| `preferences` | Diff viewer, admin email |
| `database` | DB name, user prefix, PgBouncer host |
| `status_patterns` | grep patterns for cluster-status dashboard |
| `infisical_bootstrap` | Infisical tier-0 bootstrap settings (namespace, secret names, site URL, DB/Redis hosts) |
| `telemetry` | VM telemetry setup (environment, host type, OTel collector version, resource detectors) |
| `tiers` | Deployment ordering (tier N completes before N+1) |
| `namespace_overrides` | Chart-to-namespace overrides |
| `timeout_overrides` | Per-chart Helm timeout overrides |
| `paths` | Relative paths to helm dir, terraform dir, projects dir |

### .k8-secrets.yaml (gitignored)

Merged on top of the main config at load time. Contains credentials:

```yaml
infisical:
  client_id: "..."
  client_secret: "..."
helm:
  registry_user: "..."
aws:
  account_id: "..."
```

Environment variables (`K8_*`) always override values from both files.

## Library Scripts

| Script | Purpose |
|--------|---------|
| `bin/config-resolver.sh` | Unified config resolution, YAML accessors, secrets merge |
| `bin/config.sh` | Loads config (delegates to config-resolver.sh) |
| `bin/common.sh` | Color output, logging helpers (`step`, `ok`, `warn`, `fail`, `die`) |
| `bin/helm-common.sh` | Tier loading, namespace resolution, environment overlays, impact analysis |
| `bin/docker-config.sh` | Registry config, repo mappings, build state tracking |
| `bin/project-registry.sh` | Project.yaml registry loader (parallel arrays for helm release metadata) |
| `bin/docker-vsn.sh` | Version resolution and tag management |
| `bin/terraform.sh` | Terraform helpers |
| `bin/iam.sh` | IAM utilities |
| `bin/doctor.sh` | Health checks |
