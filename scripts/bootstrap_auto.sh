#!/usr/bin/env bash
set -Eeuo pipefail

DEFAULT_UPSTREAM_REPO="${GIT_SWEATY_UPSTREAM_REPO:-aspain/git-sweaty}"
SETUP_SCRIPT_REL="scripts/setup_auth_auto.py"
BOOTSTRAP_SELECTED_REPO_DIR=""
BOOTSTRAP_DETECTED_FORK_REPO=""
BOOTSTRAP_SELECTED_FORK_REPO=""

info() {
  printf '%s\n' "$*"
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

expand_path() {
  local path="$1"
  local drive rest wsl_mount_prefix
  if [[ "$path" == "~" ]]; then
    printf '%s\n' "$HOME"
    return 0
  fi
  if [[ "$path" == ~/* ]]; then
    printf '%s/%s\n' "$HOME" "${path#~/}"
    return 0
  fi
  if is_wsl && [[ "$path" =~ ^([A-Za-z]):[\\/](.*)$ ]]; then
    drive="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')"
    rest="${BASH_REMATCH[2]}"
    rest="${rest//\\//}"
    wsl_mount_prefix="${GIT_SWEATY_WSL_MOUNT_PREFIX:-/mnt}"
    wsl_mount_prefix="${wsl_mount_prefix%/}"
    printf '%s/%s/%s\n' "$wsl_mount_prefix" "$drive" "$rest"
    return 0
  fi
  printf '%s\n' "$path"
}

is_compatible_clone() {
  local repo_dir="$1"
  [[ -e "$repo_dir/.git" && -f "$repo_dir/$SETUP_SCRIPT_REL" ]] || return 1
  git -C "$repo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-Y}"
  local suffix="[y/N]"
  local answer

  if [[ "$default" == "Y" ]]; then
    suffix="[Y/n]"
  fi

  while true; do
    if ! read -r -p "$prompt $suffix: " answer; then
      [[ "$default" == "Y" ]] && return 0 || return 1
    fi
    answer="$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')"
    case "$answer" in
      "")
        [[ "$default" == "Y" ]] && return 0 || return 1
        ;;
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) printf '%s\n' "Please enter y or n." >&2 ;;
    esac
  done
}

trim_whitespace() {
  local value="$1"
  printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

require_cmd() {
  have_cmd "$1" || fail "Missing required command: $1"
}

run_setup() {
  local repo_root="$1"
  shift || true

  [[ -f "$repo_root/$SETUP_SCRIPT_REL" ]] || fail "Missing setup script: $repo_root/$SETUP_SCRIPT_REL"
  require_cmd python3

  info ""
  info "Launching setup script..."
  (cd "$repo_root" && python3 "$SETUP_SCRIPT_REL" "$@")
}

main() {
  local repo_dir="/home/tom/samba/vscode_projects/garmin_activities"

  require_cmd python3

  if [[ ! -d "$repo_dir/.git" ]]; then
    echo "ERROR: Repo not found at $repo_dir"
    exit 1
  fi

  run_setup "$repo_dir" "$@"
}

main "$@"
