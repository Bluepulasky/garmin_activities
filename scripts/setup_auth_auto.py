#!/usr/bin/env python3
"""
Bootstrap activity-provider auth and GitHub setup for this repository.

This script performs:
0) Optional local virtualenv bootstrap (.venv + requirements install).
1) Provider-specific auth/bootstrap (Strava OAuth or Garmin credentials).
2) GitHub secret + variable updates via gh CLI.
3) Best-effort GitHub setup automation (workflows, pages, first run).
"""

import argparse
# import random
# import getpass
import html
import http.server
import os
import re
# import secrets
# import shutil
import socketserver
import subprocess
import sys
# import tempfile
# import time
# import urllib.error
import urllib.parse
# import urllib.request
# import json
# import webbrowser
from email.utils import parsedate_to_datetime
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Iterator, Optional, Tuple
import subprocess
import sys
from pathlib import Path
import yaml

from garmin_token_store import (
    decode_token_store_b64,
    encode_token_store_dir_as_zip_b64,
    hydrate_token_store_from_legacy_file,
    token_store_ready,
    write_token_store_bytes,
)
from repo_helpers import (
    normalize_dashboard_url as _shared_normalize_dashboard_url,
    normalize_repo_slug as _shared_normalize_repo_slug,
    pages_url_from_slug as _shared_pages_url_from_slug,
)

if sys.version_info < (3, 9):
    raise SystemExit(
        "Python 3.9+ is required to run scripts/setup_auth.py. "
        f"Detected {sys.version.split()[0]}. "
        "Please run with Python 3.11 (recommended)."
    )


TOKEN_ENDPOINT = "https://www.strava.com/oauth/token"
AUTHORIZE_ENDPOINT = "https://www.strava.com/oauth/authorize"
STRAVA_ATHLETE_ENDPOINT = "https://www.strava.com/api/v3/athlete"
CALLBACK_PATH = "/exchange_token"
DEFAULT_PORT = 8765
DEFAULT_TIMEOUT = 180
DEFAULT_SOURCE = "strava"
DEFAULT_TEMPLATE_REPO = "aspain/git-sweaty"
VENV_DIRNAME = ".venv"
GARMIN_AUTH_MAX_ATTEMPTS = 3

STATUS_OK = "OK"
STATUS_SKIPPED = "SKIPPED"
STATUS_MANUAL_REQUIRED = "MANUAL_REQUIRED"

UNIT_PRESETS = {
    "us": ("mi", "ft"),
    "metric": ("km", "m"),
}
DEFAULT_WEEK_START = "sunday"
WEEK_START_CHOICES = {"sunday", "monday"}
STRAVA_HOST_RE = re.compile(r"(^|\.)strava\.com$", re.IGNORECASE)
GARMIN_CONNECT_HOST_RE = re.compile(r"(^|\.)connect\.garmin\.com$", re.IGNORECASE)
TRUTHY_BOOL_TEXT = {"1", "true", "yes", "y", "on"}
FALSEY_BOOL_TEXT = {"0", "false", "no", "n", "off", ""}
STRAVA_REQUIRED_SECRET_NAMES = {
    "STRAVA_CLIENT_ID",
    "STRAVA_CLIENT_SECRET",
    "STRAVA_REFRESH_TOKEN",
}
GARMIN_PRIMARY_SECRET_NAMES = {"GARMIN_TOKENS_B64"}
GARMIN_FALLBACK_SECRET_NAMES = {"GARMIN_EMAIL", "GARMIN_PASSWORD"}


@dataclass
class StepResult:
    name: str
    status: str
    detail: str
    manual_help: Optional[str] = None


@dataclass
class CallbackResult:
    code: Optional[str] = None
    error: Optional[str] = None


@dataclass
class ExistingDashboardSettings:
    source: str
    distance_unit: str
    elevation_unit: str
    week_start: str


class ReusableTCPServer(socketserver.TCPServer):
    allow_reuse_address = True


class OAuthCallbackHandler(http.server.BaseHTTPRequestHandler):
    result: CallbackResult = CallbackResult()
    expected_state: str = ""

    def do_GET(self) -> None:  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != CALLBACK_PATH:
            self.send_error(404, "Not Found")
            return

        query = urllib.parse.parse_qs(parsed.query)
        state = query.get("state", [""])[0]
        code = query.get("code", [""])[0]
        error = query.get("error", [""])[0]

        if error:
            self.__class__.result.error = f"Strava returned error: {error}"
        elif not code:
            self.__class__.result.error = "Missing code query parameter in callback URL."
        elif state != self.__class__.expected_state:
            self.__class__.result.error = "State mismatch in callback. Please retry."
        else:
            self.__class__.result.code = code

        message = "Authorization received. You can close this tab and return to the terminal."
        if self.__class__.result.error:
            message = f"Authorization failed: {self.__class__.result.error}"

        safe_message = html.escape(message, quote=True)
        body = (
            "<!doctype html><html><head><meta charset='utf-8'>"
            "<title>Strava Auth</title></head><body>"
            f"<p>{safe_message}</p></body></html>"
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args) -> None:  # noqa: A003
        return


def _run(
    cmd: list[str],
    *,
    check: bool = True,
    input_text: Optional[str] = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        input=input_text,
        text=True,
        capture_output=True,
        check=check,
    )

def load_config() -> dict:
    project_root = Path(__file__).resolve().parents[1]

    config = {}

    base_config = project_root / "config.yaml"
    local_config = project_root / "config.local.yaml"

    if base_config.exists():
        with open(base_config, "r") as f:
            config.update(yaml.safe_load(f) or {})

    if local_config.exists():
        with open(local_config, "r") as f:
            config.update(yaml.safe_load(f) or {})

    return config

# def _store_credentials_locally(
#     *,
#     source: str,
#     distance_unit: str,
#     elevation_unit: str,
#     week_start: str,
#     client_id: Optional[str] = None,
#     client_secret: Optional[str] = None,
#     refresh_token: Optional[str] = None,
#     garmin_token_store_b64: Optional[str] = None,
#     garmin_email: Optional[str] = None,
#     garmin_password: Optional[str] = None,
# ) -> None:
#     """
#     Persist credentials and dashboard settings into config.local.yaml
#     without overwriting unrelated existing keys.
#     """

#     config_path = Path("config.local.yaml")

#     # Load existing config if present
#     if config_path.exists():
#         with config_path.open("r", encoding="utf-8") as f:
#             config = yaml.safe_load(f) or {}
#     else:
#         config = {}

#     # Ensure base keys exist
#     config["source"] = source

#     dashboard = config.setdefault("dashboard", {})
#     dashboard["distance_unit"] = distance_unit
#     dashboard["elevation_unit"] = elevation_unit
#     dashboard["week_start"] = week_start

#     if source == "strava":
#         strava_cfg = config.setdefault("strava", {})
#         if client_id is not None:
#             strava_cfg["client_id"] = client_id
#         if client_secret is not None:
#             strava_cfg["client_secret"] = client_secret
#         if refresh_token is not None:
#             strava_cfg["refresh_token"] = refresh_token

#     elif source == "garmin":
#         garmin_cfg = config.setdefault("garmin", {})
#         if garmin_token_store_b64 is not None:
#             garmin_cfg["token_store_b64"] = garmin_token_store_b64
#         if garmin_email is not None:
#             garmin_cfg["email"] = garmin_email
#         if garmin_password is not None:
#             garmin_cfg["password"] = garmin_password

#     else:
#         raise RuntimeError(f"Unsupported source for local storage: {source}")

#     # Write back safely
#     with config_path.open("w", encoding="utf-8") as f:
#         yaml.safe_dump(config, f, sort_keys=False)

#     print(f"Local credentials stored in {config_path}")


def _run_stream(cmd: list[str], *, cwd: Optional[str] = None) -> None:
    subprocess.run(cmd, check=True, cwd=cwd)


def _first_stderr_line(stderr: str) -> str:
    text = (stderr or "").strip()
    if not text:
        return "Unknown error."
    return text.splitlines()[0]

def _isatty() -> bool:
    return bool(sys.stdin.isatty() and sys.stdout.isatty())

def _normalize_repo_slug(value: Optional[str]) -> Optional[str]:
    return _shared_normalize_repo_slug(value)


def _repo_slug_from_git() -> Optional[str]:
    result = _run(["git", "config", "--get", "remote.origin.url"], check=False)
    if result.returncode != 0:
        return None
    return _normalize_repo_slug(result.stdout.strip())


def _repo_slug_from_gh_context() -> Optional[str]:
    result = _run(
        ["gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"],
        check=False,
    )
    if result.returncode != 0:
        return None
    return _normalize_repo_slug(result.stdout.strip())


def _resolve_repo_slug(explicit_repo: Optional[str]) -> Optional[str]:
    candidates = [
        explicit_repo,
        _repo_slug_from_git(),
        os.environ.get("GH_REPO"),
        _repo_slug_from_gh_context(),
    ]
    for candidate in candidates:
        normalized = _normalize_repo_slug(candidate)
        if normalized:
            return normalized
    return None


def _project_root() -> str:
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _in_virtualenv() -> bool:
    base_prefix = getattr(sys, "base_prefix", sys.prefix)
    real_prefix = getattr(sys, "real_prefix", None)
    return bool(real_prefix or (sys.prefix != base_prefix))


def _venv_python_path(venv_dir: str) -> str:
    if os.name == "nt":
        return os.path.join(venv_dir, "Scripts", "python.exe")
    return os.path.join(venv_dir, "bin", "python")


def _venv_has_pip(venv_python: str) -> bool:
    probe = _run([venv_python, "-m", "pip", "--version"], check=False)
    return probe.returncode == 0


def _ensure_venv_pip(venv_python: str) -> None:
    if _venv_has_pip(venv_python):
        return

    print("pip is missing in .venv; attempting bootstrap via ensurepip...")
    ensure = _run([venv_python, "-m", "ensurepip", "--upgrade"], check=False)
    if ensure.returncode != 0:
        detail = _first_stderr_line(ensure.stderr or ensure.stdout)
        raise RuntimeError(
            "The local virtual environment was created without pip and automatic pip bootstrap failed "
            f"({detail}). Install Python with ensurepip support (for example install the OS package that "
            "provides python3-venv), or run with --no-bootstrap-env and manage your environment manually."
        )
    if not _venv_has_pip(venv_python):
        raise RuntimeError(
            "The local virtual environment was created without pip and could not be repaired automatically."
        )


def _bootstrap_env_and_reexec(args: argparse.Namespace) -> None:
    if args.no_bootstrap_env or args.env_bootstrapped or _in_virtualenv():
        return

    root = _project_root()
    requirements = os.path.join(root, "requirements.txt")
    if not os.path.exists(requirements):
        return

    venv_dir = os.path.join(root, VENV_DIRNAME)
    venv_python = _venv_python_path(venv_dir)
    if not os.path.exists(venv_python):
        print("\nCreating local virtual environment (.venv)...")
        _run_stream([sys.executable, "-m", "venv", venv_dir], cwd=root)

    _ensure_venv_pip(venv_python)
    # print("Installing Python dependencies into .venv...")
    _run_stream([venv_python, "-m", "pip", "install", "--upgrade", "pip"], cwd=root)
    _run_stream([venv_python, "-m", "pip", "install", "-r", requirements], cwd=root)

    script_path = os.path.abspath(__file__)
    child_args = [arg for arg in sys.argv[1:] if arg != "--env-bootstrapped"]
    child_args.append("--env-bootstrapped")
    # print("Re-launching setup inside .venv...")
    raise SystemExit(subprocess.call([venv_python, script_path, *child_args], cwd=root))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Bootstrap provider auth and automate GitHub setup for this repository."
    )
    parser.add_argument(
        "--source",
        choices=["strava", "garmin"],
        default=None,
        help="Activity source to configure.",
    )
    parser.add_argument(
        "--no-bootstrap-env",
        action="store_true",
        help="Skip automatic local virtualenv bootstrap (.venv + requirements install).",
    )
    parser.add_argument(
        "--env-bootstrapped",
        action="store_true",
        help=argparse.SUPPRESS,
    )
    parser.add_argument("--client-id", default=None, help="Strava client ID.")
    parser.add_argument(
        "--client-secret",
        default=None,
        help="Strava client secret.",
    )
    parser.add_argument(
        "--garmin-token-store-b64",
        default=None,
        help="Garmin token store as base64 (optional; generated from email/password if omitted).",
    )
    parser.add_argument(
        "--garmin-email",
        default=None,
        help="Garmin account email (used to generate GARMIN_TOKENS_B64 when token is omitted).",
    )
    parser.add_argument(
        "--garmin-password",
        default=None,
        help="Garmin account password (used to generate GARMIN_TOKENS_B64 when token is omitted).",
    )
    parser.add_argument(
        "--store-garmin-password-secrets",
        action="store_true",
        help="Deprecated: GARMIN_EMAIL and GARMIN_PASSWORD are now stored automatically when provided.",
    )
    parser.add_argument(
        "--repo",
        default=None,
        help="Optional GitHub repo in OWNER/REPO form. If omitted, the script auto-detects it.",
    )
    parser.add_argument(
        "--template-repo",
        default=None,
        help=(
            "Template source repository used to seed empty targets when workflow files are missing "
            "(defaults to GIT_SWEATY_UPSTREAM_REPO or aspain/git-sweaty)."
        ),
    )
    parser.add_argument(
        "--unit-system",
        choices=["us", "metric"],
        default=None,
        help="Units preset for dashboard metrics.",
    )
    parser.add_argument(
        "--week-start",
        choices=["sunday", "monday"],
        default=None,
        help="Week start day for yearly heatmap y-axis labels.",
    )
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="Local callback port.")
    parser.add_argument(
        "--timeout",
        type=int,
        default=DEFAULT_TIMEOUT,
        help="Seconds to wait for OAuth callback.",
    )
    parser.add_argument(
        "--scope",
        default="read,activity:read_all",
        help="Strava OAuth scopes.",
    )
    parser.add_argument(
        "--strava-profile-url",
        default=None,
        help="Optional Strava profile URL override shown in the dashboard header (auto-detected by default).",
    )
    parser.add_argument(
        "--strava-activity-links",
        choices=["yes", "no", "true", "false", "1", "0"],
        default=None,
        help="Whether to show Strava activity links in yearly heatmap tooltip details.",
    )
    parser.add_argument(
        "--garmin-profile-url",
        default=None,
        help="Optional Garmin profile URL override shown in the dashboard header (auto-detected by default).",
    )
    parser.add_argument(
        "--garmin-activity-links",
        choices=["yes", "no", "true", "false", "1", "0"],
        default=None,
        help="Whether to show Garmin activity links in yearly heatmap tooltip details.",
    )
    parser.add_argument(
        "--custom-domain",
        default=None,
        help="Optional custom GitHub Pages domain host (for example strava.example.com).",
    )
    parser.add_argument(
        "--clear-custom-domain",
        action="store_true",
        help="Clear existing GitHub Pages custom domain during setup.",
    )
    parser.add_argument(
        "--no-browser",
        action="store_true",
        help="Do not auto-open browser; print auth URL only.",
    )
    parser.add_argument(
        "--no-auto-github",
        action="store_true",
        help="Skip GitHub Pages/workflow automation after setting secrets and units.",
    )
    parser.add_argument(
        "--no-watch",
        action="store_true",
        help="Do not watch the first workflow run after dispatching it.",
    )

    parser.add_argument(
    "--local-only",
    action="store_true",
    help="Configure and run dashboard locally without GitHub automation.",
    )

    return parser.parse_args()

def main() -> int:
    args = parse_args()
    _bootstrap_env_and_reexec(args)
    interactive = _isatty()

    if args.local_only:
        # _store_credentials_locally(
        #     source=source,
        #     client_id=client_id if source == "strava" else None,
        #     client_secret=client_secret if source == "strava" else None,
        #     refresh_token=refresh_token if source == "strava" else None,
        #     garmin_token_store_b64=token_store_b64 if source == "garmin" else None,
        #     garmin_email=garmin_email if source == "garmin" else None,
        #     garmin_password=garmin_password if source == "garmin" else None,
        #     distance_unit=distance_unit,
        #     elevation_unit=elevation_unit,
        #     week_start=week_start,
        # )

        config = load_config()

        token_store_b64 = config.get("garmin_tokens_b64")
        garmin_email = config.get("garmin_email")
        garmin_password = config.get("garmin_password")
        distance_unit = config.get("distance_unit")
        elevation_unit = config.get("elevation_unit")
        week_start = config.get("week_start")

        project_root = Path(__file__).resolve().parents[1]

        result = subprocess.run(
            [sys.executable, "scripts/run_pipeline.py"],
            cwd=project_root,
        )

        if result.returncode != 0:
            print("Pipeline failed.")
            return result.returncode
        return 0

if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\nCancelled.", file=sys.stderr)
        raise SystemExit(130)
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
