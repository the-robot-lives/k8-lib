#!/usr/bin/env bash
# Shared Bash runtime guard for k8-lib consumers.

_k8_require_bash4() {
  if [ -n "${BASH_VERSION:-}" ] && [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
    return 0
  fi

  local script_path="${1:-$0}"
  shift || true
  if [ "$script_path" != "-c" ] && [ ! -f "$script_path" ]; then
    local resolved_script
    resolved_script="$(command -v "$script_path" 2>/dev/null || true)"
    [ -n "$resolved_script" ] && [ -f "$resolved_script" ] && script_path="$resolved_script"
  fi

  if [ "${_K8_BASH4_REEXECED:-}" != "1" ] && { [ "$script_path" = "-c" ] || [ -f "$script_path" ]; }; then
    local candidate candidate_path
    for candidate in "${K8_BASH:-}" /opt/homebrew/bin/bash /usr/local/bin/bash bash; do
      [ -n "$candidate" ] || continue

      if [ -x "$candidate" ]; then
        candidate_path="$candidate"
      else
        candidate_path="$(command -v "$candidate" 2>/dev/null || true)"
      fi
      [ -n "$candidate_path" ] || continue

      if "$candidate_path" -c '[ -n "${BASH_VERSION:-}" ] && [ "${BASH_VERSINFO[0]}" -ge 4 ]' >/dev/null 2>&1; then
        export _K8_BASH4_REEXECED=1
        exec "$candidate_path" "$script_path" "$@"
      fi
    done
  fi

  {
    echo "ERROR: $(basename "$script_path") requires Bash 4+."
    echo "This utility uses Bash associative arrays, which macOS /bin/bash 3.2 does not support."
    echo "Install modern Bash (for example: brew install bash), put it before /bin in PATH, or set K8_BASH=/path/to/bash."
    if [ -n "${BASH_VERSION:-}" ]; then
      echo "Current Bash: ${BASH_VERSION} (${BASH:-unknown})"
    else
      echo "Current shell is not Bash."
    fi
  } >&2
  exit 2
}
