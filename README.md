# k8-lib — Shared Shell Library

Core shell functions and configuration templates sourced by all devops tools. Not invoked directly.

## Installation

```bash
make install    # Installs to ~/.local/share/k8-lib
```

## Configuration

Tools use two config layers:

- **`infra-config.yaml`** — Structural data (tiers, namespace overrides, timeouts, paths). Safe to commit.
- **`.envrc.k8.dc`** — Scalar config + secrets via direnv-config (AWS, Docker, Helm, Infisical). Secrets layer is gitignored.

### Quick Start

```bash
cp infra-config.yaml.example /path/to/project/infra-config.yaml
cp .envrc.k8.dc.example /path/to/project/.envrc.k8.dc
# Add to .envrc: source_env_if_exists .envrc.k8.dc
```

### Config Resolution

Every tool accepts `--config <path>` to specify the config file. Resolution order:

1. `--config <path>` flag
2. `K8_CONFIG` environment variable
3. `$INFRA_ROOT/infra-config.yaml`
4. Git-root walker (walks from CWD up through `.git` roots to `/`)
5. `$K8_LIB_DIR/infra-config.yaml` (library defaults)
6. Legacy fallback with deprecation warning

### infra-config.yaml (git-safe)

Structural deployment topology. All paths are relative to the config file's directory:

| Section | Description |
|---------|-------------|
| `paths` | Relative paths to helm dir, terraform dir, projects dir |
| `tiers` | Deployment ordering (tier N completes before N+1) |
| `namespace_overrides` | Chart-to-namespace overrides |
| `timeout_overrides` | Per-chart Helm timeout overrides |
| `helm_scan_dirs` | Directories to scan for Helm charts |
| `chart_path_overrides` | Explicit chart-to-directory overrides |
| `status_patterns` | grep patterns for cluster-status dashboard |
| `nodepool_labels` | Node pool labels for cluster-layout |
| `placement_exclude_pattern` | Pods excluded from placement analysis |

### .envrc.k8.dc (direnv-config)

Scalar config and credentials via direnv-config. Base layer has non-sensitive values (AWS profile, registry host, namespaces); secrets layer has credentials (Infisical client ID/secret, Helm registry password).

Tools resolve values via: env var → `dc get k8 <path>` → YAML fallback → hardcoded default.

## Library Scripts

| Script | Purpose |
|--------|---------|
| `bin/config-resolver.sh` | Unified config resolution, YAML accessors, dc integration |
| `bin/config.sh` | Loads config (delegates to config-resolver.sh) |
| `bin/common.sh` | Color output, logging helpers (`step`, `ok`, `warn`, `fail`, `die`) |
| `bin/helm-common.sh` | Tier loading, namespace resolution, environment overlays, impact analysis |
| `bin/docker-config.sh` | Registry config, repo mappings, build state tracking |
| `bin/project-registry.sh` | infra-config.yaml project registry loader (parallel arrays for helm release metadata) |
| `bin/docker-vsn.sh` | Version resolution and tag management |
| `bin/terraform.sh` | Terraform helpers |
| `bin/iam.sh` | IAM utilities |
| `bin/doctor.sh` | Health checks |
