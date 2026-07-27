#!/usr/bin/env bash
# =============================================================================
# deploy-fingerprint.sh — Source fingerprint helpers for deploy drift tracking.
#
# Sourced by deploy-status and helm-upgrade. Uses docker-config.sh as the
# authoritative deployable-image registry and stores deployed truth on Helm
# release Secrets via Kubernetes annotations.
# =============================================================================

_DEPLOY_FP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_DEPLOY_FP_LIB_DIR/bash-runtime.sh"
_k8_require_bash4 "$0" "$@"

[[ "${_DEPLOY_FINGERPRINT_LOADED:-0}" -eq 1 ]] && return 0
_DEPLOY_FINGERPRINT_LOADED=1

DEPLOY_FP_ANNOTATION_KEY="${DEPLOY_FP_ANNOTATION_KEY:-infra.noizu.com/deploy-fingerprints.v1}"

if ! declare -F get_all_docker_repos >/dev/null; then
  source "$_DEPLOY_FP_LIB_DIR/docker-config.sh"
fi

_deploy_fp_require_jq() {
  command -v jq >/dev/null || {
    echo "ERROR: jq is required for deploy fingerprint JSON" >&2
    return 1
  }
}

_deploy_fp_sha256_pipe() {
  if command -v sha256sum >/dev/null; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

_deploy_fp_sha256_file() {
  if command -v sha256sum >/dev/null; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

_deploy_fp_stat_mode() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}

_deploy_fp_stat_size() {
  if stat -c '%s' "$1" >/dev/null 2>&1; then
    stat -c '%s' "$1"
  else
    stat -f '%z' "$1"
  fi
}

_deploy_fp_stat_mtime() {
  if stat -c '%Y' "$1" >/dev/null 2>&1; then
    stat -c '%Y' "$1"
  else
    stat -f '%m' "$1"
  fi
}

_deploy_fp_relpath() {
  local path="$1"
  if [[ -n "${INFRA_ROOT:-}" && "$path" == "${INFRA_ROOT}/"* ]]; then
    echo "${path#${INFRA_ROOT}/}"
  else
    echo "$path"
  fi
}

_deploy_fp_path_excluded() {
  local rel="$1" base
  base="$(basename "$rel")"
  case "/$rel/" in
    */.git/*|*/node_modules/*|*/target/*|*/_build/*|*/deps/*|*/dist/*|*/build/*|*/.next/*|*/coverage/*|*/.cache/*|*/.tmp/*|*/.docker-state/*|*/.helm-state/*)
      return 0
      ;;
  esac
  case "$base" in
    .DS_Store|*.log|.env|.env.*|.envrc|.envrc.*)
      return 0
      ;;
  esac
  return 1
}

_deploy_fp_emit_files() {
  local context="$1" root rel_context rel abs
  root="$(git -C "${INFRA_ROOT:-.}" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "$root" && ( "$context" == "$root" || "$context" == "$root/"* ) ]]; then
    if [[ "$context" == "$root" ]]; then
      rel_context="."
    else
      rel_context="${context#${root}/}"
    fi
    git -C "$root" ls-files -co --exclude-standard -z -- "$rel_context" |
      while IFS= read -r -d '' rel; do
        abs="$root/$rel"
        [[ -f "$abs" ]] || continue
        local local_rel="${abs#${context}/}"
        [[ "$local_rel" == "$abs" ]] && continue
        _deploy_fp_path_excluded "$local_rel" && continue
        printf '%s\0' "$abs"
      done
    return 0
  fi

  find "$context" \
    \( -type d \( \
      -name .git -o -name node_modules -o -name target -o -name _build -o \
      -name deps -o -name dist -o -name build -o -name .next -o \
      -name coverage -o -name .cache -o -name .tmp -o \
      -name .docker-state -o -name .helm-state \
    \) -prune \) -o \
    \( -type f \
      ! -name '.DS_Store' \
      ! -name '*.log' \
      ! -name '.env' \
      ! -name '.env.*' \
      ! -name '.envrc' \
      ! -name '.envrc.*' \
      -print0 \)
}

deploy_fingerprint_resolve_image_helm() {
  local key="$1" cfg="${_K8_MERGED_CONFIG:-}" q hj
  DEPLOY_FP_CHART_PATH=""
  DEPLOY_FP_VALUES_PATH=""
  DEPLOY_FP_FORMAT=""

  [[ -n "$cfg" && -f "$cfg" ]] || return 1
  if [[ "$key" == */* ]]; then
    local domain="${key%%/*}" svc="${key#*/}"
    q=".project.projects[]? | select(.domain == \"$domain\") | .services[]? | select(.name == \"$svc\") | .helm"
  else
    q=".project.docker.images[]? | select(.name == \"$key\") | .helm"
  fi

  hj="$(yq -o=json -I=0 "$q // \"\"" "$cfg" 2>/dev/null | head -n1 || true)"
  [[ -z "$hj" || "$hj" == '""' || "$hj" == "null" ]] && return 1

  DEPLOY_FP_CHART_PATH="$(printf '%s' "$hj" | yq -r '.chart_path // ""')"
  DEPLOY_FP_VALUES_PATH="$(printf '%s' "$hj" | yq -r '.values_path // ""')"
  DEPLOY_FP_FORMAT="$(printf '%s' "$hj" | yq -r '.format // "tag"')"
  [[ -n "$DEPLOY_FP_CHART_PATH" ]]
}

deploy_fingerprint_image_keys_for_chart() {
  local chart="$1" key chart_path chart_name
  for key in $(get_all_docker_repos); do
    if deploy_fingerprint_resolve_image_helm "$key"; then
      chart_path="$DEPLOY_FP_CHART_PATH"
      chart_name="$(basename "$chart_path")"
      [[ "$chart_name" == "$chart" ]] && echo "$key"
    fi
  done
}

deploy_fingerprint_image_checksum() {
  local image="$1" context_raw context tmp_dir abs_file rel_file mode_file hash_file mtime_file checksum
  context_raw="$(get_repo_dir "$image")"
  [[ -d "$context_raw" ]] || return 1
  context="$(cd "$context_raw" && pwd -P)"
  tmp_dir="$(mktemp -d)"
  abs_file="$tmp_dir/files"
  rel_file="$tmp_dir/rels"
  mode_file="$tmp_dir/modes"
  hash_file="$tmp_dir/hashes"
  mtime_file="$tmp_dir/mtimes"
  DEPLOY_FP_CONTEXT="$context"
  DEPLOY_FP_CHECKSUM=""
  DEPLOY_FP_LATEST_MTIME=0
  DEPLOY_FP_LATEST_FILE=""
  DEPLOY_FP_FILE_COUNT=0

  _deploy_fp_emit_files "$context" |
    sort -z |
    while IFS= read -r -d '' file; do
      [[ -f "$file" ]] || continue
      rel="${file#${context}/}"
      mode="$(_deploy_fp_stat_mode "$file" 2>/dev/null)" || continue
      mtime="$(_deploy_fp_stat_mtime "$file" 2>/dev/null)" || continue
      printf '%s\n' "$file" >> "$abs_file"
      printf '%s\n' "$rel" >> "$rel_file"
      printf '%s\n' "$mode" >> "$mode_file"
      printf '%s|%s\n' "$mtime" "$rel" >> "$mtime_file"
    done

  if [[ -s "$abs_file" ]]; then
    if ! git hash-object --stdin-paths < "$abs_file" > "$hash_file" 2>/dev/null; then
      rm -rf "$tmp_dir"
      return 1
    fi
    checksum="$(paste "$rel_file" "$mode_file" "$hash_file" |
      while IFS=$'\t' read -r rel mode hash; do
        [[ -n "$rel" && -n "$hash" ]] || continue
        printf '%s\0%s\0%s\0' "$rel" "$mode" "$hash"
      done |
      _deploy_fp_sha256_pipe)"
  else
    checksum="$(printf '' |
    _deploy_fp_sha256_pipe)"
  fi

  if [[ -f "$mtime_file" ]]; then
    DEPLOY_FP_FILE_COUNT="$(wc -l < "$mtime_file" | tr -d ' ')"
    if [[ "$DEPLOY_FP_FILE_COUNT" -gt 0 ]]; then
      local latest
      latest="$(sort -t'|' -k1,1n "$mtime_file" | tail -1)"
      DEPLOY_FP_LATEST_MTIME="${latest%%|*}"
      DEPLOY_FP_LATEST_FILE="${latest#*|}"
    fi
  fi

  rm -rf "$tmp_dir"
  DEPLOY_FP_CHECKSUM="$checksum"
  printf '%s\n' "$checksum"
}

deploy_fingerprint_image_json() {
  local image="$1" checksum context dockerfile registry_path
  _deploy_fp_require_jq || return 1
  deploy_fingerprint_image_checksum "$image" >/dev/null || return 1
  checksum="$DEPLOY_FP_CHECKSUM"
  context="$(_deploy_fp_relpath "$DEPLOY_FP_CONTEXT")"
  dockerfile="$(_dockerfile_for_image "$image")"
  registry_path="$(_registry_path_for_image "$image")"
  jq -n \
    --arg image_key "$image" \
    --arg context "$context" \
    --arg dockerfile "$dockerfile" \
    --arg registry_path "$registry_path" \
    --arg checksum "$checksum" \
    --arg latest_file "$DEPLOY_FP_LATEST_FILE" \
    --argjson latest_mtime "${DEPLOY_FP_LATEST_MTIME:-0}" \
    --argjson file_count "${DEPLOY_FP_FILE_COUNT:-0}" \
    '{image_key:$image_key,context:$context,dockerfile:$dockerfile,registry_path:$registry_path,checksum:$checksum,latest_mtime:$latest_mtime,latest_file:$latest_file,file_count:$file_count}'
}

deploy_fingerprint_release_json() {
  local chart="$1" release="$2" namespace="$3" tmp git_sha generated key
  _deploy_fp_require_jq || return 1
  tmp="$(mktemp)"
  for key in $(deploy_fingerprint_image_keys_for_chart "$chart"); do
    deploy_fingerprint_image_json "$key" >> "$tmp"
  done
  git_sha="$(git -C "${INFRA_ROOT:-.}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  generated="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  jq -s \
    --arg schema "deploy-fingerprints.v1" \
    --arg generated_at "$generated" \
    --arg git_sha "$git_sha" \
    --arg chart "$chart" \
    --arg release "$release" \
    --arg namespace "$namespace" \
    '{schema:$schema,generated_at:$generated_at,git_sha:$git_sha,chart:$chart,release:$release,namespace:$namespace,images:.}' \
    "$tmp"
  rm -f "$tmp"
}

deploy_fingerprint_release_secret_name() {
  local release="$1" namespace="$2"
  command -v kubectl >/dev/null || return 2
  kubectl --request-timeout="${DEPLOY_FP_KUBECTL_TIMEOUT:-5s}" get secret -n "$namespace" \
    -l "owner=helm,name=${release},status=deployed" \
    -o json 2>/dev/null |
    jq -r '.items | sort_by(.metadata.creationTimestamp) | last | .metadata.name // empty'
}

deploy_fingerprint_release_annotation() {
  local secret="$1" namespace="$2"
  command -v kubectl >/dev/null || return 2
  kubectl --request-timeout="${DEPLOY_FP_KUBECTL_TIMEOUT:-5s}" get secret "$secret" -n "$namespace" -o json 2>/dev/null |
    jq -r --arg key "$DEPLOY_FP_ANNOTATION_KEY" '.metadata.annotations[$key] // empty'
}

deploy_fingerprint_annotate_release() {
  local chart="$1" release="$2" namespace="$3" secret payload compact
  _deploy_fp_require_jq || return 1
  command -v kubectl >/dev/null || return 2
  secret="$(deploy_fingerprint_release_secret_name "$release" "$namespace")"
  [[ -n "$secret" ]] || return 1
  payload="$(deploy_fingerprint_release_json "$chart" "$release" "$namespace")" || return 1
  compact="$(printf '%s' "$payload" | jq -c '.')"
  kubectl --request-timeout="${DEPLOY_FP_KUBECTL_TIMEOUT:-5s}" annotate secret "$secret" -n "$namespace" \
    "${DEPLOY_FP_ANNOTATION_KEY}=${compact}" \
    --overwrite >/dev/null
}
