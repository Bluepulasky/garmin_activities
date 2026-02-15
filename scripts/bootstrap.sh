#!/usr/bin/env bash
set -Eeuo pipefail

DEFAULT_UPSTREAM_REPO="${GIT_SWEATY_UPSTREAM_REPO:-aspain/git-sweaty}"
SETUP_SCRIPT_REL="scripts/setup_auth.py"
BOOTSTRAP_SELECTED_REPO_DIR=""
BOOTSTRAP_DETECTED_FORK_REPO=""

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

is_wsl() {
  [[ -n "${WSL_DISTRO_NAME:-}" || -n "${WSL_INTEROP:-}" ]] && return 0
  [[ -r /proc/version ]] && grep -qi "microsoft" /proc/version
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
  local suffix="[y/n] (default: n)"
  local answer

  if [[ "$default" == "Y" ]]; then
    suffix="[y/n] (default: y)"
  fi

  while true; do
    read -r -p "$prompt $suffix " answer || return 1
    answer="$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')"
    case "$answer" in
      "")
        [[ "$default" == "Y" ]] && return 0 || return 1
        ;;
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) info "Please enter y or n." ;;
    esac
  done
}

require_cmd() {
  have_cmd "$1" || fail "Missing required command: $1"
}

gh_is_authenticated() {
  gh auth status >/dev/null 2>&1
}

ensure_gh_auth() {
  require_cmd gh
  if gh_is_authenticated; then
    return 0
  fi

  info "GitHub CLI is not authenticated."
  if prompt_yes_no "Run gh auth login now?" "Y"; then
    gh auth login
  fi

  gh_is_authenticated || fail "GitHub CLI auth is required. Run 'gh auth login' and re-run bootstrap."
}

repo_name_from_slug() {
  local slug="$1"
  printf '%s\n' "${slug##*/}"
}

discover_existing_fork_repo() {
  local login="$1"
  local upstream_repo="$2"

  gh repo list "$login" \
    --fork \
    --limit 1000 \
    --json nameWithOwner,parent \
    --jq ".[] | select(.parent.nameWithOwner == \"$upstream_repo\") | .nameWithOwner" \
    2>/dev/null \
    | head -n 1 \
    || true
}

discover_existing_fork_repo_via_api() {
  local login="$1"
  local upstream_repo="$2"

  gh api "repos/${upstream_repo}/forks?per_page=100" \
    --paginate \
    --jq ".[] | select(.owner.login == \"$login\") | .full_name" \
    2>/dev/null \
    | head -n 1 \
    || true
}

detect_existing_fork_repo() {
  local upstream_repo="$1"
  local login="$2"
  local explicit="${GIT_SWEATY_FORK_REPO:-}"
  local default_fork discovered discovered_api

  if [[ -n "$explicit" ]]; then
    gh repo view "$explicit" >/dev/null 2>&1 || return 1
    printf '%s\n' "$explicit"
    return 0
  fi

  default_fork="${login}/$(repo_name_from_slug "$upstream_repo")"
  if gh repo view "$default_fork" >/dev/null 2>&1; then
    printf '%s\n' "$default_fork"
    return 0
  fi

  discovered="$(discover_existing_fork_repo "$login" "$upstream_repo")"
  if [[ -n "$discovered" ]] && gh repo view "$discovered" >/dev/null 2>&1; then
    printf '%s\n' "$discovered"
    return 0
  fi

  discovered_api="$(discover_existing_fork_repo_via_api "$login" "$upstream_repo")"
  if [[ -n "$discovered_api" ]] && gh repo view "$discovered_api" >/dev/null 2>&1; then
    printf '%s\n' "$discovered_api"
    return 0
  fi

  return 1
}

resolve_fork_repo() {
  local upstream_repo="$1"
  local login="$2"
  local detected

  detected="$(detect_existing_fork_repo "$upstream_repo" "$login" || true)"
  if [[ -n "$detected" ]]; then
    printf '%s\n' "$detected"
    return 0
  fi

  fail "Unable to find an accessible fork for ${upstream_repo} under ${login}. Set GIT_SWEATY_FORK_REPO=<owner>/<repo> and retry."
}

detect_local_repo_root() {
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 1
  fi

  local root
  root="$(git rev-parse --show-toplevel)"
  if [[ -f "$root/$SETUP_SCRIPT_REL" ]]; then
    printf '%s\n' "$root"
    return 0
  fi
  return 1
}

ensure_repo_dir_ready() {
  local repo_dir="$1"
  if is_compatible_clone "$repo_dir"; then
    return 0
  fi
  if [[ -e "$repo_dir" ]]; then
    fail "Path already exists and is not a compatible clone: $repo_dir"
  fi
}

prompt_existing_clone_path() {
  local default_repo_dir="$1"
  local raw repo_dir

  printf '\n' >&2
  printf 'Default clone directory is: %s\n' "$default_repo_dir" >&2
  printf 'Choose this for a fresh setup, or point to an existing compatible clone.\n' >&2
  if ! prompt_yes_no "Use an existing local clone path?" "N"; then
    return 1
  fi

  while true; do
    read -r -p "Existing clone path (press Enter to cancel): " raw || return 1
    raw="$(printf '%s' "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [[ -z "$raw" ]]; then
      return 1
    fi

    repo_dir="$(expand_path "$raw")"
    if is_compatible_clone "$repo_dir"; then
      printf '%s\n' "$repo_dir"
      return 0
    fi

    warn "Not a compatible clone: $repo_dir"
    warn "Expected both: $repo_dir/.git and $repo_dir/$SETUP_SCRIPT_REL"
  done
}

configure_fork_remotes() {
  local repo_dir="$1"
  local upstream_repo="$2"
  local fork_repo="$3"

  git -C "$repo_dir" remote set-url origin "https://github.com/${fork_repo}.git"
  if git -C "$repo_dir" remote get-url upstream >/dev/null 2>&1; then
    git -C "$repo_dir" remote set-url upstream "https://github.com/${upstream_repo}.git"
  else
    git -C "$repo_dir" remote add upstream "https://github.com/${upstream_repo}.git"
  fi
}

prefer_existing_fork_clone_dir() {
  local repo_dir="$1"
  local fork_repo="$2"
  local fork_repo_dir

  fork_repo_dir="$(dirname "$repo_dir")/$(repo_name_from_slug "$fork_repo")"
  if [[ "$fork_repo_dir" == "$repo_dir" ]]; then
    printf '%s\n' "$repo_dir"
    return 0
  fi

  if is_compatible_clone "$fork_repo_dir"; then
    printf '%s\n' "$fork_repo_dir"
    return 0
  fi

  printf '%s\n' "$repo_dir"
}

detect_wsl_windows_clone_by_repo_name() {
  local repo_name="$1"
  local old_ifs
  local users_root user_home base candidate owner_dir
  local default_users_roots="/mnt/c/Users:/mnt/d/Users:/mnt/e/Users"
  local users_roots="${GIT_SWEATY_WSL_USERS_ROOTS:-$default_users_roots}"

  is_wsl || return 1
  [[ -n "$repo_name" ]] || return 1

  old_ifs="$IFS"
  IFS=":"
  for users_root in $users_roots; do
    [[ -d "$users_root" ]] || continue
    for user_home in "$users_root"/*; do
      [[ -d "$user_home" ]] || continue
      for base in \
        "$user_home/source/repos" \
        "$user_home/repos" \
        "$user_home/source" \
        "$user_home/Documents/GitHub" \
        "$user_home/Documents/repos" \
        "$user_home/code" \
        "$user_home/dev"; do
        [[ -d "$base" ]] || continue
        candidate="$base/$repo_name"
        if is_compatible_clone "$candidate"; then
          IFS="$old_ifs"
          printf '%s\n' "$candidate"
          return 0
        fi
        for owner_dir in "$base"/*; do
          [[ -d "$owner_dir" ]] || continue
          candidate="$owner_dir/$repo_name"
          if is_compatible_clone "$candidate"; then
            IFS="$old_ifs"
            printf '%s\n' "$candidate"
            return 0
          fi
        done
      done
    done
  done
  IFS="$old_ifs"
  return 1
}

auto_detect_existing_compatible_clone() {
  local upstream_repo="$1"
  local default_repo_dir="$2"
  local login fork_repo fork_name upstream_name candidate_dir detected_wsl

  BOOTSTRAP_SELECTED_REPO_DIR=""
  BOOTSTRAP_DETECTED_FORK_REPO=""

  if is_compatible_clone "$default_repo_dir"; then
    BOOTSTRAP_SELECTED_REPO_DIR="$default_repo_dir"
    return 0
  fi

  if have_cmd gh && gh_is_authenticated; then
    login="$(gh api user --jq .login 2>/dev/null || true)"
    if [[ -n "$login" ]]; then
      fork_repo="$(detect_existing_fork_repo "$upstream_repo" "$login" || true)"
      if [[ -n "$fork_repo" ]]; then
        fork_name="$(repo_name_from_slug "$fork_repo")"
        upstream_name="$(repo_name_from_slug "$upstream_repo")"
        candidate_dir="$(dirname "$default_repo_dir")/$fork_name"
        if is_compatible_clone "$candidate_dir"; then
          BOOTSTRAP_SELECTED_REPO_DIR="$candidate_dir"
          BOOTSTRAP_DETECTED_FORK_REPO="$fork_repo"
          return 0
        fi

        detected_wsl="$(detect_wsl_windows_clone_by_repo_name "$fork_name" || true)"
        if [[ -n "$detected_wsl" ]]; then
          BOOTSTRAP_SELECTED_REPO_DIR="$detected_wsl"
          BOOTSTRAP_DETECTED_FORK_REPO="$fork_repo"
          return 0
        fi

        if [[ "$fork_name" != "$upstream_name" ]]; then
          detected_wsl="$(detect_wsl_windows_clone_by_repo_name "$upstream_name" || true)"
          if [[ -n "$detected_wsl" ]]; then
            BOOTSTRAP_SELECTED_REPO_DIR="$detected_wsl"
            return 0
          fi
        fi
      fi
    else
      upstream_name="$(repo_name_from_slug "$upstream_repo")"
      detected_wsl="$(detect_wsl_windows_clone_by_repo_name "$upstream_name" || true)"
      if [[ -n "$detected_wsl" ]]; then
        BOOTSTRAP_SELECTED_REPO_DIR="$detected_wsl"
        return 0
      fi
    fi
  fi

  upstream_name="$(repo_name_from_slug "$upstream_repo")"
  detected_wsl="$(detect_wsl_windows_clone_by_repo_name "$upstream_name" || true)"
  if [[ -n "$detected_wsl" ]]; then
    BOOTSTRAP_SELECTED_REPO_DIR="$detected_wsl"
    return 0
  fi
  return 1
}

fork_and_clone() {
  local upstream_repo="$1"
  local repo_dir="$2"
  local login fork_repo

  ensure_gh_auth

  login="$(gh api user --jq .login 2>/dev/null || true)"
  [[ -n "$login" ]] || fail "Unable to resolve GitHub username from current gh auth session."
  info "Ensuring fork exists for ${login}"
  if ! gh repo fork "$upstream_repo" --clone=false --remote=false >/dev/null 2>&1; then
    warn "Fork creation command did not succeed cleanly. Continuing if fork already exists."
  fi
  fork_repo="$(resolve_fork_repo "$upstream_repo" "$login")"
  info "Using fork repository: $fork_repo"
  gh repo view "$fork_repo" >/dev/null 2>&1 || fail "Fork is not accessible: $fork_repo"
  local preferred_repo_dir
  preferred_repo_dir="$(prefer_existing_fork_clone_dir "$repo_dir" "$fork_repo")"
  if [[ "$preferred_repo_dir" != "$repo_dir" ]]; then
    info "Detected existing local fork clone at $preferred_repo_dir"
    repo_dir="$preferred_repo_dir"
  fi

  if is_compatible_clone "$repo_dir"; then
    info "Using existing clone at $repo_dir"
  else
    ensure_repo_dir_ready "$repo_dir"
    info "Cloning fork into $repo_dir"
    git clone "https://github.com/${fork_repo}.git" "$repo_dir"
  fi

  configure_fork_remotes "$repo_dir" "$upstream_repo" "$fork_repo"
  BOOTSTRAP_SELECTED_REPO_DIR="$repo_dir"
}

clone_upstream() {
  local upstream_repo="$1"
  local repo_dir="$2"

  if is_compatible_clone "$repo_dir"; then
    info "Using existing clone at $repo_dir"
    BOOTSTRAP_SELECTED_REPO_DIR="$repo_dir"
    return 0
  fi

  ensure_repo_dir_ready "$repo_dir"
  info "Cloning upstream repository into $repo_dir"
  git clone "https://github.com/${upstream_repo}.git" "$repo_dir"
  BOOTSTRAP_SELECTED_REPO_DIR="$repo_dir"
}

run_setup() {
  local repo_root="$1"
  shift || true

  [[ -f "$repo_root/$SETUP_SCRIPT_REL" ]] || fail "Missing setup script: $repo_root/$SETUP_SCRIPT_REL"
  ensure_gh_auth
  require_cmd python3

  info ""
  info "Launching setup script..."
  (cd "$repo_root" && python3 "$SETUP_SCRIPT_REL" "$@")
}

main() {
  local upstream_repo="$DEFAULT_UPSTREAM_REPO"
  local repo_dir local_root existing_clone_path

  require_cmd git
  require_cmd python3

  if local_root="$(detect_local_repo_root)"; then
    info "Detected local clone: $local_root"
    if prompt_yes_no "Run setup now?" "Y"; then
      run_setup "$local_root" "$@"
    else
      info "Skipped setup. Run this when ready:"
      info "  (cd \"$local_root\" && ./scripts/bootstrap.sh)"
    fi
    return 0
  fi

  repo_dir="$(pwd)/$(repo_name_from_slug "$upstream_repo")"
  info "No compatible local clone detected in current working tree."
  info "Upstream repository: $upstream_repo"
  info "Target clone directory: $repo_dir"
  if auto_detect_existing_compatible_clone "$upstream_repo" "$repo_dir"; then
    repo_dir="$BOOTSTRAP_SELECTED_REPO_DIR"
    info "Detected existing compatible local clone at $repo_dir"
    if [[ -n "$BOOTSTRAP_DETECTED_FORK_REPO" ]]; then
      configure_fork_remotes "$repo_dir" "$upstream_repo" "$BOOTSTRAP_DETECTED_FORK_REPO"
    fi
    if prompt_yes_no "Run setup now?" "Y"; then
      run_setup "$repo_dir" "$@"
    else
      info "Setup not run. Next step:"
      info "  (cd \"$repo_dir\" && ./scripts/bootstrap.sh)"
    fi
    return 0
  fi

  if existing_clone_path="$(prompt_existing_clone_path "$repo_dir")"; then
    repo_dir="$existing_clone_path"
    info "Using existing clone at $repo_dir"
    if prompt_yes_no "Run setup now?" "Y"; then
      run_setup "$repo_dir" "$@"
    else
      info "Setup not run. Next step:"
      info "  (cd \"$repo_dir\" && ./scripts/bootstrap.sh)"
    fi
    return 0
  fi

  if prompt_yes_no "Fork the repo to your GitHub account first?" "Y"; then
    fork_and_clone "$upstream_repo" "$repo_dir"
  else
    if ! prompt_yes_no "Clone upstream directly (without forking)?" "Y"; then
      info "No repository action selected. Exiting."
      return 0
    fi
    clone_upstream "$upstream_repo" "$repo_dir"
  fi

  if [[ -n "$BOOTSTRAP_SELECTED_REPO_DIR" ]]; then
    repo_dir="$BOOTSTRAP_SELECTED_REPO_DIR"
  fi

  if prompt_yes_no "Run setup now?" "Y"; then
    run_setup "$repo_dir" "$@"
  else
    info "Setup not run. Next step:"
    info "  (cd \"$repo_dir\" && ./scripts/bootstrap.sh)"
  fi
}

main "$@"
