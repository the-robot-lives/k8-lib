#!/usr/bin/env bash
# =============================================================================
# docker-config.sh — Shared configuration and state management for docker
#                    build/push workflow.
#
# Sourced by: utils/docker-build, utils/docker-push
#
# Configuration:
#   DOCKER_REPOS     — Override via K8_DOCKER_REPOS env var or docker-repos.conf
#   REGISTRY         — Override via K8_DOCKER_REGISTRY env var or config.env
#   Repo mappings    — Override via docker-mappings.conf (see below)
# =============================================================================

# --- Auto-yes flag (set by --yes/-y in callers) ------------------------------
AUTO_YES=${AUTO_YES:-false}

# --- Confirm prompt (loops until valid input) --------------------------------
# Usage: _confirm "prompt text" → returns 0 (yes) or 1 (no)
#        _confirm_yiN "prompt text" → sets CONFIRM_RESULT to "y", "i", or "n"
# When AUTO_YES=true, auto-accepts and prints "(auto)" for auditability.
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

_confirm_yiN() {
  local prompt="$1"
  if [[ "$AUTO_YES" == "true" ]]; then
    echo "${prompt} [y/i/N] y (auto)"
    CONFIRM_RESULT="y"; return 0
  fi
  local answer
  while true; do
    read -r -p "${prompt} [y/i/N] " answer
    if [[ -z "$answer" ]] || [[ "$answer" =~ ^[Nn]([Oo])?$ ]]; then
      CONFIRM_RESULT="n"; return 0
    elif _is_yes "$answer"; then
      CONFIRM_RESULT="y"; return 0
    elif [[ "$answer" =~ ^[Ii]$ ]]; then
      CONFIRM_RESULT="i"; return 0
    fi
    echo "   Please enter y, i, or n."
  done
}

# --- Docker repos list -------------------------------------------------------
# Load from: 1) K8_DOCKER_REPOS env var (space-separated)
#            2) docker-repos.conf file (one per line, # comments)
#            3) Empty array (caller must populate)
_DOCKER_CFG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -n "${K8_DOCKER_REPOS:-}" ]]; then
  read -ra DOCKER_REPOS <<< "$K8_DOCKER_REPOS"
elif [[ -f "${INFRA_ROOT:-.}/docker-repos.conf" ]]; then
  mapfile -t DOCKER_REPOS < <(grep -v '^\s*#' "${INFRA_ROOT:-.}/docker-repos.conf" | grep -v '^\s*$')
elif [[ -f "$_DOCKER_CFG_DIR/docker-repos.conf" ]]; then
  mapfile -t DOCKER_REPOS < <(grep -v '^\s*#' "$_DOCKER_CFG_DIR/docker-repos.conf" | grep -v '^\s*$')
else
  DOCKER_REPOS=()
fi

REGISTRY="${K8_DOCKER_REGISTRY:-}"

# --- State directory (persists build/push tracking) ---
DOCKER_STATE_DIR="${INFRA_ROOT:-.}/.docker-state"

# =============================================================================
# Repo mapping configuration
#
# docker-mappings.conf format (one mapping per line):
#   image_name|dir_name|dockerfile|single_stage
#
# Example:
#   my-api|web|Dockerfile.api|false
#   my-admin|||true
#
# Empty fields use defaults: dir=image_name, dockerfile=Dockerfile, single_stage=false
# =============================================================================
declare -A _DOCKER_DIR_MAP
declare -A _DOCKER_DOCKERFILE_MAP
declare -A _DOCKER_SINGLE_STAGE_MAP

_load_docker_mappings() {
  local mappings_file=""
  if [[ -f "${INFRA_ROOT:-.}/docker-mappings.conf" ]]; then
    mappings_file="${INFRA_ROOT:-.}/docker-mappings.conf"
  elif [[ -f "$_DOCKER_CFG_DIR/docker-mappings.conf" ]]; then
    mappings_file="$_DOCKER_CFG_DIR/docker-mappings.conf"
  fi
  [[ -z "$mappings_file" ]] && return

  while IFS='|' read -r image dir dockerfile single_stage; do
    [[ "$image" =~ ^#.*$ || -z "$image" ]] && continue
    image=$(echo "$image" | xargs)
    [[ -n "$dir" ]]          && _DOCKER_DIR_MAP["$image"]="$(echo "$dir" | xargs)"
    [[ -n "$dockerfile" ]]   && _DOCKER_DOCKERFILE_MAP["$image"]="$(echo "$dockerfile" | xargs)"
    [[ -n "$single_stage" ]] && _DOCKER_SINGLE_STAGE_MAP["$image"]="$(echo "$single_stage" | xargs)"
  done < "$mappings_file"
}

_load_docker_mappings

# -----------------------------------------------------------------------------
# _repo_dir_name — return the directory name under repos/ for an image
#   Checks mappings config first, then falls back to image name as-is.
# -----------------------------------------------------------------------------
_repo_dir_name() {
  local image="$1"
  if [[ -n "${_DOCKER_DIR_MAP[$image]+x}" ]]; then
    echo "${_DOCKER_DIR_MAP[$image]}"
  else
    echo "$image"
  fi
}

# -----------------------------------------------------------------------------
# _image_for_dir — reverse lookup: directory name → image name
#   Checks mappings config first, then falls back to directory name as-is.
# -----------------------------------------------------------------------------
_image_for_dir() {
  local dir="$1"
  for image in "${!_DOCKER_DIR_MAP[@]}"; do
    if [[ "${_DOCKER_DIR_MAP[$image]}" == "$dir" ]]; then
      echo "$image"
      return
    fi
  done
  echo "$dir"
}

# -----------------------------------------------------------------------------
# _dockerfile_for_image — return the Dockerfile path for an image
#   Returns empty string for images using the default Dockerfile.
# -----------------------------------------------------------------------------
_dockerfile_for_image() {
  local image="$1"
  if [[ -n "${_DOCKER_DOCKERFILE_MAP[$image]+x}" ]]; then
    echo "${_DOCKER_DOCKERFILE_MAP[$image]}"
  else
    echo ""
  fi
}

# -----------------------------------------------------------------------------
# _is_single_stage — returns 0 if image uses a single-stage Dockerfile
#   (no --target flag should be passed)
# -----------------------------------------------------------------------------
_is_single_stage() {
  local image="$1"
  if [[ -n "${_DOCKER_SINGLE_STAGE_MAP[$image]+x}" ]]; then
    [[ "${_DOCKER_SINGLE_STAGE_MAP[$image]}" == "true" ]] && return 0
    return 1
  fi
  return 1
}

# -----------------------------------------------------------------------------
# normalize_repo_name — resolve directory names / shorthand to canonical image name
# -----------------------------------------------------------------------------
normalize_repo_name() {
  local name="$1"
  # Check if it's already a known image name
  for repo in "${DOCKER_REPOS[@]}"; do
    [[ "$repo" == "$name" ]] && echo "$name" && return 0
  done
  # Check if it's a directory name that maps to an image
  local image
  image="$(_image_for_dir "$name")"
  for repo in "${DOCKER_REPOS[@]}"; do
    [[ "$repo" == "$image" ]] && echo "$image" && return 0
  done
  return 1
}

# -----------------------------------------------------------------------------
# is_docker_repo — check if a name is a known docker repo
# -----------------------------------------------------------------------------
is_docker_repo() {
  normalize_repo_name "$1" > /dev/null 2>&1
}

# -----------------------------------------------------------------------------
# detect_docker_repo — detect repo from a directory path
#   Sets DETECTED_REPO on success, returns 1 if not in a known repo.
# -----------------------------------------------------------------------------
detect_docker_repo() {
  local dir="$1"
  for repo in "${DOCKER_REPOS[@]}"; do
    local repo_dir
    repo_dir="$(_repo_dir_name "$repo")"
    # Match /repos/DIR or /repos/DIR/... anywhere in the path
    if [[ "$dir" =~ /repos/${repo_dir}(/|$) || "$dir" == *"/${repo_dir}" ]]; then
      DETECTED_REPO="$repo"
      return 0
    fi
  done
  return 1
}

# -----------------------------------------------------------------------------
# get_repo_dir — return absolute path for a repo
# -----------------------------------------------------------------------------
get_repo_dir() {
  local image="$1"
  local dir
  dir="$(_repo_dir_name "$image")"
  echo "${INFRA_ROOT}/repos/${dir}"
}

# =============================================================================
# STATE MANAGEMENT
#
# State files:
#   .docker-state/last      — last build vars (sourced)
#   .docker-state/shadow    — shadow of last pushed build (sourced)
#   .docker-state/builds    — unpushed build queue (line log, max 10)
#   .docker-state/pushes    — push history (line log, max 10)
#
# Line format: epoch|image|sha|vsn
# =============================================================================

_ensure_state_dir() {
  mkdir -p "$DOCKER_STATE_DIR"
}

# --- Save after a build ---
save_build_state() {
  local image="$1" sha="$2" vsn="$3"
  local now
  now=$(date +%s)
  _ensure_state_dir

  cat > "$DOCKER_STATE_DIR/last" <<EOF
LAST_BUILD_TIME=${now}
LAST_BUILD_IMAGE=${image}
LAST_BUILD_SHA=${sha}
LAST_BUILD_VSN=${vsn}
EOF

  # Append to unpushed builds queue, cap at 10
  echo "${now}|${image}|${sha}|${vsn}" >> "$DOCKER_STATE_DIR/builds"
  tail -10 "$DOCKER_STATE_DIR/builds" > "$DOCKER_STATE_DIR/builds.tmp"
  mv "$DOCKER_STATE_DIR/builds.tmp" "$DOCKER_STATE_DIR/builds"
}

# --- Load last build vars ---
load_build_state() {
  LAST_BUILD_TIME="" LAST_BUILD_IMAGE="" LAST_BUILD_SHA="" LAST_BUILD_VSN=""
  if [[ -f "$DOCKER_STATE_DIR/last" ]]; then
    source "$DOCKER_STATE_DIR/last"
  fi
}

# --- Record a push (moves build→shadow, clears last, logs push) ---
record_push_state() {
  local image="$1" sha="$2" vsn="$3"
  local now
  now=$(date +%s)
  _ensure_state_dir

  # Copy current last → shadow
  if [[ -f "$DOCKER_STATE_DIR/last" ]]; then
    sed 's/^LAST_/SHADOW_/' "$DOCKER_STATE_DIR/last" > "$DOCKER_STATE_DIR/shadow"
  fi

  # Clear last build
  cat > "$DOCKER_STATE_DIR/last" <<EOF
LAST_BUILD_TIME=
LAST_BUILD_IMAGE=
LAST_BUILD_SHA=
LAST_BUILD_VSN=
EOF

  # Remove matching entry from builds queue
  if [[ -f "$DOCKER_STATE_DIR/builds" ]]; then
    grep -v "|${image}|${sha}|" "$DOCKER_STATE_DIR/builds" \
      > "$DOCKER_STATE_DIR/builds.tmp" 2>/dev/null || true
    mv "$DOCKER_STATE_DIR/builds.tmp" "$DOCKER_STATE_DIR/builds"
  fi

  # Append to push history, cap at 10
  echo "${now}|${image}|${sha}|${vsn}" >> "$DOCKER_STATE_DIR/pushes"
  tail -10 "$DOCKER_STATE_DIR/pushes" > "$DOCKER_STATE_DIR/pushes.tmp"
  mv "$DOCKER_STATE_DIR/pushes.tmp" "$DOCKER_STATE_DIR/pushes"
}

# --- Load shadow build vars ---
load_shadow_state() {
  SHADOW_BUILD_TIME="" SHADOW_BUILD_IMAGE="" SHADOW_BUILD_SHA="" SHADOW_BUILD_VSN=""
  if [[ -f "$DOCKER_STATE_DIR/shadow" ]]; then
    source "$DOCKER_STATE_DIR/shadow"
  fi
}

# --- Get unpushed builds (raw lines) ---
get_unpushed_builds() {
  if [[ -f "$DOCKER_STATE_DIR/builds" && -s "$DOCKER_STATE_DIR/builds" ]]; then
    cat "$DOCKER_STATE_DIR/builds"
  fi
}

# --- Seconds since last build (999999 if none) ---
seconds_since_last_build() {
  load_build_state
  if [[ -z "${LAST_BUILD_TIME:-}" ]]; then
    echo "999999"
    return
  fi
  local now
  now=$(date +%s)
  echo $(( now - LAST_BUILD_TIME ))
}
