#!/usr/bin/env bash
# =============================================================================
# helm-publish-config.sh — Discovery and state management for Helm chart
#                          packaging and OCI registry publishing.
#
# Sourced by: helm-tools/bin/helm-publish
#
# Configuration:
#   K8_HELM_OCI_REGISTRY  — OCI registry URL (from k8-util-config.yaml or env var)
#   K8_HELM_REGISTRY_HOST — Registry hostname for login (default: ghcr.io)
#   K8_HELM_REGISTRY_USER — Registry username for login
#
# Chart discovery:
#   Scans project.yaml files for helm.charts[] entries.
#   Composite projects: projects[].helm.charts[]
#   Flat projects:      helm.charts[]
# =============================================================================

[[ "${_HELM_PUBLISH_CONFIG_LOADED:-0}" -eq 1 ]] && return 0
_HELM_PUBLISH_CONFIG_LOADED=1

# --- Auto-yes flag (set by --yes/-y in callers) ------------------------------
AUTO_YES=${AUTO_YES:-false}

# --- Confirm prompt ----------------------------------------------------------
_is_yes() {
  case "$(echo "$1" | tr '[:upper:]' '[:lower:]')" in
    y|yes|si) return 0 ;;
    *)        return 1 ;;
  esac
}

_confirm() {
  local prompt="$1"
  if [[ "$AUTO_YES" == "true" ]]; then
    echo "${prompt} [y/N] y (auto)"
    return 0
  fi
  local answer
  while true; do
    read -r -p "${prompt} [y/N] " answer
    if [[ -z "$answer" ]] || [[ "$answer" =~ ^[Nn]([Oo])?$ ]]; then
      return 1
    elif _is_yes "$answer"; then
      return 0
    fi
    echo "   Please enter y or n."
  done
}

# --- yq dependency check ---
_require_yq() {
  if ! command -v yq &>/dev/null; then
    echo "❌ yq is required but not installed. Install via: brew install yq"
    exit 1
  fi
}

# =============================================================================
# CONSTANTS (from k8-util-config.yaml via config.sh)
# =============================================================================

HELM_OCI_REGISTRY="${K8_HELM_OCI_REGISTRY:-}"
HELM_REGISTRY_HOST="${K8_HELM_REGISTRY_HOST:-ghcr.io}"
HELM_REGISTRY_USER="${K8_HELM_REGISTRY_USER:-}"
HELM_STATE_DIR="${INFRA_ROOT:-.}/.helm-state"

# =============================================================================
# YAML-BASED CHART REGISTRY
# =============================================================================

YAML_HELM_CHARTS=()
_YAML_HELM_LOADED=0

declare -A _HELM_CHART_YAML_MAP 2>/dev/null || true
declare -A _HELM_CHART_PATH_MAP 2>/dev/null || true
declare -A _HELM_CHART_PROJECT_MAP 2>/dev/null || true
declare -A _HELM_CHART_REGISTRY_MAP 2>/dev/null || true

_load_yaml_helm_charts() {
  local projects_dir="${INFRA_ROOT}"
  local yaml

  _require_yq

  # Scan for project.yaml files — supports arbitrary nesting patterns
  while IFS= read -r -d '' yaml; do
    [ -f "$yaml" ] || continue

    local project_name
    project_name="$(basename "$(dirname "$yaml")")"
    local project_dir
    project_dir="$(dirname "$yaml")"

    if yq eval '.type // ""' "$yaml" 2>/dev/null | grep -q "composite"; then
      _load_composite_helm_charts "$yaml" "$project_name"
    fi

    _load_flat_helm_charts "$yaml" "$project_name" "$project_dir"
  done < <(find "$projects_dir" -name "project.yaml" -maxdepth 5 -print0 2>/dev/null)
}

_load_composite_helm_charts() {
  local yaml="$1"
  local project_name="$2"
  local _hc_domain _hc_chart_name _hc_chart_path _hc_chart_registry

  local domains
  domains="$(yq eval '.projects[] | .domain' "$yaml" 2>/dev/null || true)"

  for _hc_domain in $domains; do
    local chart_count
    chart_count="$(yq eval ".projects[] | select(.domain==\"$_hc_domain\") | .helm.charts | length // 0" "$yaml" 2>/dev/null || echo "0")"
    [[ "$chart_count" -eq 0 || "$chart_count" == "null" ]] && continue

    # base_path override: allows projects outside the standard projects/<domain>/ convention
    local _hc_base_path
    _hc_base_path="$(yq eval ".projects[] | select(.domain==\"$_hc_domain\") | .base_path // \"\"" "$yaml" 2>/dev/null || echo "")"

    local chart_idx=0
    while [[ $chart_idx -lt $chart_count ]]; do
      _hc_chart_name="$(yq eval ".projects[] | select(.domain==\"$_hc_domain\") | .helm.charts[$chart_idx].name" "$yaml" 2>/dev/null || echo "")"
      _hc_chart_path="$(yq eval ".projects[] | select(.domain==\"$_hc_domain\") | .helm.charts[$chart_idx].path" "$yaml" 2>/dev/null || echo "")"
      _hc_chart_registry="$(yq eval ".projects[] | select(.domain==\"$_hc_domain\") | .helm.charts[$chart_idx].registry // \"\"" "$yaml" 2>/dev/null || echo "")"

      [[ -z "$_hc_chart_name" || "$_hc_chart_name" == "null" ]] && { chart_idx=$((chart_idx + 1)); continue; }

      local chart_key="${_hc_domain}/${_hc_chart_name}"

      local yaml_dir
      yaml_dir="$(dirname "$yaml")"
      local abs_path
      if [[ -n "$_hc_base_path" && "$_hc_base_path" != "null" ]]; then
        abs_path="${yaml_dir}/${_hc_base_path}/${_hc_chart_path}"
      else
        abs_path="${yaml_dir}/projects/${_hc_domain}/${_hc_chart_path}"
      fi

      YAML_HELM_CHARTS+=("$chart_key")
      _HELM_CHART_YAML_MAP["$chart_key"]="$yaml"
      _HELM_CHART_PATH_MAP["$chart_key"]="$abs_path"
      _HELM_CHART_PROJECT_MAP["$chart_key"]="$project_name"
      _HELM_CHART_REGISTRY_MAP["$chart_key"]="${_hc_chart_registry:-$HELM_OCI_REGISTRY}"

      chart_idx=$((chart_idx + 1))
    done
  done
}

_load_flat_helm_charts() {
  local yaml="$1"
  local project_name="$2"
  local project_dir="$3"

  local chart_count
  chart_count="$(yq eval '.helm.charts | length // 0' "$yaml" 2>/dev/null || echo "0")"
  [[ "$chart_count" -eq 0 || "$chart_count" == "null" ]] && return 0

  local chart_idx=0
  local _fhc_name _fhc_path _fhc_registry
  while [[ $chart_idx -lt $chart_count ]]; do
    _fhc_name="$(yq eval ".helm.charts[$chart_idx].name" "$yaml" 2>/dev/null || echo "")"
    _fhc_path="$(yq eval ".helm.charts[$chart_idx].path" "$yaml" 2>/dev/null || echo "")"
    _fhc_registry="$(yq eval ".helm.charts[$chart_idx].registry // \"\"" "$yaml" 2>/dev/null || echo "")"

    [[ -z "$_fhc_name" || "$_fhc_name" == "null" ]] && { chart_idx=$((chart_idx + 1)); continue; }

    local abs_path="${project_dir}/${_fhc_path}"

    YAML_HELM_CHARTS+=("$_fhc_name")
    _HELM_CHART_YAML_MAP["$_fhc_name"]="$yaml"
    _HELM_CHART_PATH_MAP["$_fhc_name"]="$abs_path"
    _HELM_CHART_PROJECT_MAP["$_fhc_name"]="$project_name"
    _HELM_CHART_REGISTRY_MAP["$_fhc_name"]="${_fhc_registry:-$HELM_OCI_REGISTRY}"

    chart_idx=$((chart_idx + 1))
  done
}

_init_yaml_helm_charts() {
  if [[ $_YAML_HELM_LOADED -eq 0 ]]; then
    _load_yaml_helm_charts
    _YAML_HELM_LOADED=1
  fi
}

# =============================================================================
# PUBLIC API
# =============================================================================

get_all_helm_charts() {
  _init_yaml_helm_charts
  printf '%s\n' "${YAML_HELM_CHARTS[@]}"
}

get_helm_chart_path() {
  local key="$1"
  _init_yaml_helm_charts
  echo "${_HELM_CHART_PATH_MAP[$key]:-}"
}

get_helm_chart_version() {
  local key="$1"
  local chart_path
  chart_path="$(get_helm_chart_path "$key")"
  [[ -z "$chart_path" || ! -f "$chart_path/Chart.yaml" ]] && return 1
  yq eval '.version' "$chart_path/Chart.yaml" 2>/dev/null
}

get_helm_chart_app_version() {
  local key="$1"
  local chart_path
  chart_path="$(get_helm_chart_path "$key")"
  [[ -z "$chart_path" || ! -f "$chart_path/Chart.yaml" ]] && return 1
  yq eval '.appVersion // ""' "$chart_path/Chart.yaml" 2>/dev/null
}

get_helm_registry_url() {
  local key="$1"
  _init_yaml_helm_charts
  echo "${_HELM_CHART_REGISTRY_MAP[$key]:-$HELM_OCI_REGISTRY}"
}

get_helm_chart_name() {
  local key="$1"
  local chart_path
  chart_path="$(get_helm_chart_path "$key")"
  [[ -z "$chart_path" || ! -f "$chart_path/Chart.yaml" ]] && { echo "${key##*/}"; return; }
  yq eval '.name' "$chart_path/Chart.yaml" 2>/dev/null
}

normalize_chart_name() {
  local input="$1"
  _init_yaml_helm_charts

  # Exact match
  if [[ -n "${_HELM_CHART_PATH_MAP[$input]:-}" ]]; then
    echo "$input"
    return 0
  fi

  # Partial match: try as chart name suffix
  local match_count=0
  local matched_key=""
  for key in "${YAML_HELM_CHARTS[@]}"; do
    if [[ "${key##*/}" == "$input" ]]; then
      matched_key="$key"
      match_count=$((match_count + 1))
    fi
  done

  if [[ $match_count -eq 1 ]]; then
    echo "$matched_key"
    return 0
  elif [[ $match_count -gt 1 ]]; then
    echo "Ambiguous chart name '$input' — matches multiple charts. Use full key (domain/name)." >&2
    return 1
  fi

  echo "Unknown chart: $input" >&2
  return 1
}

detect_helm_chart() {
  local dir="${1:-$(pwd)}"
  _init_yaml_helm_charts

  local check_dir="$dir"
  while [[ "$check_dir" != "/" ]]; do
    if [[ -f "$check_dir/Chart.yaml" ]]; then
      local real_check
      real_check="$(cd "$check_dir" && pwd)"
      for key in "${YAML_HELM_CHARTS[@]}"; do
        local real_known
        real_known="$(cd "${_HELM_CHART_PATH_MAP[$key]}" 2>/dev/null && pwd)" || continue
        if [[ "$real_check" == "$real_known" ]]; then
          echo "$key"
          return 0
        fi
      done
    fi
    check_dir="$(dirname "$check_dir")"
  done
  return 1
}

# =============================================================================
# STATE MANAGEMENT
# =============================================================================

_ensure_helm_state_dir() {
  mkdir -p "$HELM_STATE_DIR"
}

save_helm_publish_state() {
  local chart_key="$1"
  local version="$2"
  local registry_url="$3"
  local timestamp
  timestamp="$(date +%s)"

  _ensure_helm_state_dir

  cat > "$HELM_STATE_DIR/last-publish" <<EOF
LAST_PUBLISH_CHART="$chart_key"
LAST_PUBLISH_VERSION="$version"
LAST_PUBLISH_REGISTRY="$registry_url"
LAST_PUBLISH_TIME="$timestamp"
EOF

  echo "${timestamp}|${chart_key}|${version}|${registry_url}" >> "$HELM_STATE_DIR/publishes"

  if [[ -f "$HELM_STATE_DIR/publishes" ]]; then
    local line_count
    line_count="$(wc -l < "$HELM_STATE_DIR/publishes")"
    if [[ $line_count -gt 10 ]]; then
      tail -10 "$HELM_STATE_DIR/publishes" > "$HELM_STATE_DIR/publishes.tmp"
      mv "$HELM_STATE_DIR/publishes.tmp" "$HELM_STATE_DIR/publishes"
    fi
  fi
}

load_helm_publish_state() {
  if [[ -f "$HELM_STATE_DIR/last-publish" ]]; then
    # shellcheck disable=SC1091
    source "$HELM_STATE_DIR/last-publish"
  fi
}
