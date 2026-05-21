#!/usr/bin/env bash
# =============================================================================
# config-resolver.sh — Unified config resolution for k8-lib tools
#
# Resolves k8-util-config.yaml via (in order):
#   1. --config <path> flag (pre-parsed into K8_CONFIG before sourcing)
#   2. K8_CONFIG environment variable
#   3. $INFRA_ROOT/k8-util-config.yaml
#   4. Git-root walker (CWD upward, checking each .git root)
#   5. $K8_LIB_DIR/k8-util-config.yaml (library defaults)
#
# After resolution, merges optional secrets_file (relative to config dir).
# Env vars always override YAML values.
#
# Requires: yq (https://github.com/mikefarah/yq/)
# =============================================================================

# Guard against double-sourcing
if [[ -n "${_K8_CONFIG_RESOLVER_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
_K8_CONFIG_RESOLVER_LOADED=1

# =============================================================================
# CONSTANTS
# =============================================================================
_K8_CONFIG_FILENAME="k8-util-config.yaml"
_K8_SECRETS_FILENAME=".k8-secrets.yaml"

# =============================================================================
# STATE (set by _resolve_config, read by accessors)
# =============================================================================
_K8_CONFIG_PATH=""        # path to the resolved config file
_K8_CONFIG_DIR=""          # directory containing the config file
_K8_MERGED_CONFIG=""       # path to merged (config + secrets) temp file
_K8_MERGED_TMPFILE=""      # temp file to clean up on exit

_K8_LIB_DIR="${K8_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# =============================================================================
# CLEANUP
# =============================================================================
_k8_config_cleanup() {
  [[ -n "$_K8_MERGED_TMPFILE" && -f "$_K8_MERGED_TMPFILE" ]] && rm -f "$_K8_MERGED_TMPFILE"
  _K8_MERGED_TMPFILE=""
}
trap '_k8_config_cleanup' EXIT

# =============================================================================
# YQ DEPENDENCY
# =============================================================================
_k8_require_yq() {
  if ! command -v yq &>/dev/null; then
    echo "❌ yq is required but not installed. Install via: brew install yq" >&2
    exit 1
  fi
}

# =============================================================================
# GIT-ROOT WALKER
#
# Walk from CWD upward, checking each directory that contains .git for
# the config file. Crosses nested repo boundaries (submodules).
# =============================================================================
_k8_find_config_in_git_roots() {
  local dir
  dir="$(pwd)"
  while [[ "$dir" != "/" ]]; do
    if [[ -e "$dir/.git" ]]; then
      if [[ -f "$dir/$_K8_CONFIG_FILENAME" ]]; then
        echo "$dir/$_K8_CONFIG_FILENAME"
        return 0
      fi
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

# =============================================================================
# SECRETS MERGE
#
# Reads secrets_file from the config YAML. If the referenced file exists
# (resolved relative to config dir), merges it on top of the main config
# into a temp file. All _cfg calls read from the merged result.
# =============================================================================
_k8_merge_secrets() {
  local config_path="$1"
  local config_dir="$2"

  _k8_require_yq

  local secrets_rel
  secrets_rel="$(yq eval '.secrets_file // ""' "$config_path" 2>/dev/null)"
  [[ -z "$secrets_rel" || "$secrets_rel" == "null" ]] && {
    _K8_MERGED_CONFIG="$config_path"
    return 0
  }

  local secrets_path="$config_dir/$secrets_rel"
  if [[ ! -f "$secrets_path" ]]; then
    _K8_MERGED_CONFIG="$config_path"
    return 0
  fi

  _K8_MERGED_TMPFILE="$(mktemp "${TMPDIR:-/tmp}/k8-merged-config.XXXXXX.yaml")"
  yq eval-all 'select(fileIndex==0) * select(fileIndex==1)' \
    "$config_path" "$secrets_path" > "$_K8_MERGED_TMPFILE" 2>/dev/null

  _K8_MERGED_CONFIG="$_K8_MERGED_TMPFILE"
}

# =============================================================================
# MAIN RESOLVER
# =============================================================================
_resolve_config() {
  # Already resolved
  [[ -n "$_K8_CONFIG_PATH" ]] && return 0

  local candidate=""

  # 1. K8_CONFIG env var (set by --config pre-parse or directly)
  if [[ -n "${K8_CONFIG:-}" ]]; then
    if [[ ! -f "$K8_CONFIG" ]]; then
      echo "❌ Config file not found: $K8_CONFIG" >&2
      echo "   (specified via --config flag or K8_CONFIG env var)" >&2
      exit 1
    fi
    candidate="$K8_CONFIG"
  fi

  # 2. $INFRA_ROOT/k8-util-config.yaml
  if [[ -z "$candidate" && -n "${INFRA_ROOT:-}" && -f "$INFRA_ROOT/$_K8_CONFIG_FILENAME" ]]; then
    candidate="$INFRA_ROOT/$_K8_CONFIG_FILENAME"
  fi

  # 3. Git-root walker
  if [[ -z "$candidate" ]]; then
    candidate="$(_k8_find_config_in_git_roots 2>/dev/null)" || true
  fi

  # 4. K8_LIB_DIR fallback (library defaults)
  if [[ -z "$candidate" && -f "$_K8_LIB_DIR/$_K8_CONFIG_FILENAME" ]]; then
    candidate="$_K8_LIB_DIR/$_K8_CONFIG_FILENAME"
  fi

  # 5. No config found at all
  if [[ -z "$candidate" ]]; then
    echo "❌ No $_K8_CONFIG_FILENAME found." >&2
    echo "   Searched:" >&2
    [[ -n "${K8_CONFIG:-}" ]] && echo "     --config / K8_CONFIG: $K8_CONFIG" >&2
    [[ -n "${INFRA_ROOT:-}" ]] && echo "     \$INFRA_ROOT: $INFRA_ROOT/$_K8_CONFIG_FILENAME" >&2
    echo "     Git-root walker: (walked from $(pwd) to /)" >&2
    echo "     \$K8_LIB_DIR: $_K8_LIB_DIR/$_K8_CONFIG_FILENAME" >&2
    echo "" >&2
    echo "   Create one from the template:" >&2
    echo "     cp $_K8_LIB_DIR/$_K8_CONFIG_FILENAME.example ./$_K8_CONFIG_FILENAME" >&2
    exit 1
  fi

  # Resolve to absolute path
  _K8_CONFIG_PATH="$(cd "$(dirname "$candidate")" && pwd)/$(basename "$candidate")"
  _K8_CONFIG_DIR="$(dirname "$_K8_CONFIG_PATH")"

  # Set INFRA_ROOT for backward compatibility if not already set
  : "${INFRA_ROOT:=$_K8_CONFIG_DIR}"
  export INFRA_ROOT

  # Merge secrets
  _k8_merge_secrets "$_K8_CONFIG_PATH" "$_K8_CONFIG_DIR"
}

# =============================================================================
# ACCESSOR FUNCTIONS
# =============================================================================

# Read a value from the merged config.
#   _cfg '.aws.profile'
_cfg() {
  [[ -z "$_K8_MERGED_CONFIG" ]] && return
  yq eval "$1 // \"\"" "$_K8_MERGED_CONFIG" 2>/dev/null
}

# Read with fallback default.
#   _cfg_default '.aws.region' 'us-east-1'
_cfg_default() {
  local val
  val="$(_cfg "$1")"
  echo "${val:-$2}"
}

# Resolve a path field relative to the config file's directory.
#   _cfg_path '.paths.helm_dir'
# Returns absolute path. Empty if field is unset.
_cfg_path() {
  local rel
  rel="$(_cfg "$1")"
  [[ -z "$rel" || "$rel" == "null" ]] && return
  if [[ "$rel" = /* ]]; then
    echo "$rel"
  else
    echo "$_K8_CONFIG_DIR/$rel"
  fi
}

# =============================================================================
# BULK LOADERS
# =============================================================================

# Load all K8_* variables from YAML. Env vars override YAML values.
# Uses a single yq call to emit shell assignments.
_load_k8_vars() {
  _k8_require_yq

  # AWS
  K8_AWS_PROFILE="${K8_AWS_PROFILE:-$(_cfg_default '.aws.profile' 'terraformer')}"
  K8_AWS_ACCOUNT_ID="${K8_AWS_ACCOUNT_ID:-$(_cfg_default '.aws.account_id' '')}"
  K8_AWS_REGION="${K8_AWS_REGION:-$(_cfg_default '.aws.region' 'us-east-1')}"

  # Docker
  K8_DOCKER_REGISTRY="${K8_DOCKER_REGISTRY:-$(_cfg_default '.docker.registry' '')}"

  # Kubernetes
  K8_NAMESPACE="${K8_NAMESPACE:-$(_cfg_default '.kubernetes.namespace' 'default')}"
  K8_STAGING_NAMESPACE="${K8_STAGING_NAMESPACE:-$(_cfg_default '.kubernetes.staging_namespace' 'staging')}"
  K8_INFRA_NAMESPACE="${K8_INFRA_NAMESPACE:-$(_cfg_default '.kubernetes.infra_namespace' 'infra')}"
  K8_APP_PREFIX="${K8_APP_PREFIX:-$(_cfg_default '.kubernetes.app_prefix' 'app')}"

  # Infisical
  K8_INFISICAL_HOST="${K8_INFISICAL_HOST:-$(_cfg_default '.infisical.host' '')}"
  K8_INFISICAL_PROJECT_ID="${K8_INFISICAL_PROJECT_ID:-$(_cfg_default '.infisical.project_id' '')}"
  K8_INFISICAL_CLIENT_ID="${K8_INFISICAL_CLIENT_ID:-$(_cfg_default '.infisical.client_id' '')}"
  K8_INFISICAL_CLIENT_SECRET="${K8_INFISICAL_CLIENT_SECRET:-$(_cfg_default '.infisical.client_secret' '')}"

  # Terraform
  K8_TF_DIR="${K8_TF_DIR:-$(_cfg_path '.paths.terraform_dir')}"
  K8_TF_STATE_BUCKET="${K8_TF_STATE_BUCKET:-$(_cfg_default '.terraform.state_bucket' '')}"
  K8_TF_KMS_ALIAS="${K8_TF_KMS_ALIAS:-$(_cfg_default '.terraform.kms_alias' '')}"
  K8_TF_LOCK_TABLE="${K8_TF_LOCK_TABLE:-$(_cfg_default '.terraform.lock_table' 'terraform-lock')}"

  # Helm
  K8_HELM_OCI_REGISTRY="${K8_HELM_OCI_REGISTRY:-$(_cfg_default '.helm.oci_registry' '')}"
  K8_HELM_REGISTRY_HOST="${K8_HELM_REGISTRY_HOST:-$(_cfg_default '.helm.registry_host' 'ghcr.io')}"
  K8_HELM_REGISTRY_USER="${K8_HELM_REGISTRY_USER:-$(_cfg_default '.helm.registry_user' '')}"

  # Preferences
  K8_DIFF_VIEWER="${K8_DIFF_VIEWER:-$(_cfg_default '.preferences.diff_viewer' 'code')}"
  K8_ADMIN_EMAIL="${K8_ADMIN_EMAIL:-$(_cfg_default '.preferences.admin_email' 'admin@example.com')}"
  K8_CREDENTIALS_LINK="${K8_CREDENTIALS_LINK:-$(_cfg_default '.preferences.credentials_link' '')}"

  # Database
  K8_DB_NAME="${K8_DB_NAME:-$(_cfg_default '.database.name' '')}"
  K8_DB_USER_PREFIX="${K8_DB_USER_PREFIX:-$(_cfg_default '.database.user_prefix' 'app')}"
  K8_PGBOUNCER_HOST="${K8_PGBOUNCER_HOST:-$(_cfg_default '.database.pgbouncer_host' 'pgbouncer.default.svc.cluster.local')}"

  # Status patterns
  K8_STATUS_DB_PATTERN="${K8_STATUS_DB_PATTERN:-$(_cfg_default '.status_patterns.db' '(timescaledb|mysqldb|redis|valkey)')}"
  K8_STATUS_SEARCH_PATTERN="${K8_STATUS_SEARCH_PATTERN:-$(_cfg_default '.status_patterns.search' '(manticore|elasticsearch|opensearch)')}"
  K8_STATUS_APP_PATTERN="${K8_STATUS_APP_PATTERN:-$(_cfg_default '.status_patterns.app' '(backend|frontend|wordpress|api|admin)')}"
  K8_STATUS_NET_PATTERN="${K8_STATUS_NET_PATTERN:-$(_cfg_default '.status_patterns.net' '(pgbouncer|proxysql|haproxy)')}"
  K8_STATUS_INFRA_PATTERN="${K8_STATUS_INFRA_PATTERN:-$(_cfg_default '.status_patterns.infra' '(infisical|signoz|karpenter|nginx-ingress|lb-controller|cert-manager)')}"
  K8_STATUS_JOB_PATTERN="${K8_STATUS_JOB_PATTERN:-$(_cfg_default '.status_patterns.job' '(indexer|migrat|job)')}"

  # Nodepool labels
  K8_NODEPOOL_LABELS="${K8_NODEPOOL_LABELS:-$(_cfg_default '.nodepool_labels | to_entries | map(.key + "=" + .value) | join(",")' '')}"

  # Placement
  K8_PLACEMENT_EXCLUDE_PATTERN="${K8_PLACEMENT_EXCLUDE_PATTERN:-$(_cfg_default '.placement_exclude_pattern' 'aws-node|kube-proxy|ebs-csi-node|efs-csi-node|signoz-node-agent|nginx-ingress')}"

  # Paths (resolve relative to config dir)
  HELM_DIR="${HELM_DIR:-$(_cfg_path '.paths.helm_dir')}"
  PROJECTS_DIR="${PROJECTS_DIR:-$(_cfg_path '.paths.projects_dir')}"
}

# Load deployment tiers into TIERS[] array.
# Each element is a space-separated list of charts for that tier.
_load_tiers() {
  _k8_require_yq

  TIERS=()
  local tier_count
  tier_count="$(yq eval '.tiers | length' "$_K8_MERGED_CONFIG" 2>/dev/null || echo 0)"

  local _t
  for (( _t=0; _t < tier_count; _t++ )); do
    local _charts
    _charts="$(yq eval -r ".tiers[$_t].charts[]" "$_K8_MERGED_CONFIG" 2>/dev/null | tr '\n' ' ')"
    _charts="${_charts% }"
    [[ -n "$_charts" ]] && TIERS+=("$_charts")
  done

  if (( ${#TIERS[@]} == 0 )); then
    echo "⚠️  No tiers loaded from $_K8_CONFIG_FILENAME" >&2
  fi
}

# Load namespace overrides into _NS_OVERRIDES associative array.
_load_ns_overrides() {
  _k8_require_yq

  declare -gA _NS_OVERRIDES=()
  local keys
  keys="$(yq eval '.namespace_overrides | keys | .[]' "$_K8_MERGED_CONFIG" 2>/dev/null || true)"

  local key
  for key in $keys; do
    [[ -z "$key" ]] && continue
    local val
    val="$(yq eval ".namespace_overrides.\"$key\"" "$_K8_MERGED_CONFIG" 2>/dev/null)"
    [[ -n "$val" && "$val" != "null" ]] && _NS_OVERRIDES["$key"]="$val"
  done
}

# Load timeout overrides into _TIMEOUT_OVERRIDES associative array.
_load_timeout_overrides() {
  _k8_require_yq

  declare -gA _TIMEOUT_OVERRIDES=()
  local keys
  keys="$(yq eval '.timeout_overrides | keys | .[]' "$_K8_MERGED_CONFIG" 2>/dev/null || true)"

  local key
  for key in $keys; do
    [[ -z "$key" ]] && continue
    local val
    val="$(yq eval ".timeout_overrides.\"$key\"" "$_K8_MERGED_CONFIG" 2>/dev/null)"
    [[ -n "$val" && "$val" != "null" ]] && _TIMEOUT_OVERRIDES["$key"]="$val"
  done
}

# Load docker repos list into DOCKER_REPOS array.
_load_docker_repos() {
  _k8_require_yq

  DOCKER_REPOS=()
  local count
  count="$(yq eval '.docker.repos | length' "$_K8_MERGED_CONFIG" 2>/dev/null || echo 0)"

  local _i
  for (( _i=0; _i < count; _i++ )); do
    local repo
    repo="$(yq eval -r ".docker.repos[$_i]" "$_K8_MERGED_CONFIG" 2>/dev/null)"
    [[ -n "$repo" && "$repo" != "null" ]] && DOCKER_REPOS+=("$repo")
  done
}

# Load docker mappings into associative arrays.
# YAML format under docker.mappings:
#   image_name:
#     dir: directory_name        # optional, defaults to image_name
#     dockerfile: Dockerfile.api # optional, defaults to Dockerfile
#     single_stage: true         # optional, defaults to false
_load_docker_mappings() {
  _k8_require_yq

  declare -gA _DOCKER_DIR_MAP=()
  declare -gA _DOCKER_DOCKERFILE_MAP=()
  declare -gA _DOCKER_SINGLE_STAGE_MAP=()

  local keys
  keys="$(yq eval '.docker.mappings | keys | .[]' "$_K8_MERGED_CONFIG" 2>/dev/null || true)"

  local key
  for key in $keys; do
    [[ -z "$key" ]] && continue
    local dir dockerfile single_stage
    dir="$(yq eval ".docker.mappings.\"$key\".dir // \"\"" "$_K8_MERGED_CONFIG" 2>/dev/null)"
    dockerfile="$(yq eval ".docker.mappings.\"$key\".dockerfile // \"\"" "$_K8_MERGED_CONFIG" 2>/dev/null)"
    single_stage="$(yq eval ".docker.mappings.\"$key\".single_stage // \"\"" "$_K8_MERGED_CONFIG" 2>/dev/null)"
    [[ -n "$dir" && "$dir" != "null" ]] && _DOCKER_DIR_MAP["$key"]="$dir"
    [[ -n "$dockerfile" && "$dockerfile" != "null" ]] && _DOCKER_DOCKERFILE_MAP["$key"]="$dockerfile"
    [[ -n "$single_stage" && "$single_stage" != "null" ]] && _DOCKER_SINGLE_STAGE_MAP["$key"]="$single_stage"
  done
}

# =============================================================================
# --config PRE-PARSE SNIPPET
#
# Consumer tools should paste this block BEFORE sourcing k8-lib:
#
#   # Pre-parse --config (must resolve before library sourcing)
#   for _k8_arg in "$@"; do
#     case "$_k8_arg" in
#       --config=*) export K8_CONFIG="${_k8_arg#--config=}" ;;
#     esac
#   done
#   _k8_prev=""
#   for _k8_arg in "$@"; do
#     [[ "$_k8_prev" == "--config" ]] && export K8_CONFIG="$_k8_arg"
#     _k8_prev="$_k8_arg"
#   done
#   unset _k8_arg _k8_prev
#
# =============================================================================
