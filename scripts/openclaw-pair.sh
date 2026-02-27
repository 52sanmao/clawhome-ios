#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_PORT=18789

EXPOSURE="lan"
OVERRIDE_HOST=""
OVERRIDE_PORT=""
NO_QR=0
PRINT_URL=0
DETACH=0
FORCE=0
CLOUDFLARE_TIMEOUT=30
OPENCLAW_BIN=""
OPENCLAW_LABEL=""

OPENCLAW_CMD=()

CF_PID=""
CF_LOG=""
CF_PUBLIC_HTTPS=""
CLEANUP_TUNNEL=1

usage() {
  cat <<USAGE
Usage: $SCRIPT_NAME [options]

Pair ClawHome iOS with an OpenClaw Gateway by generating a ws/wss URL + QR code.
The script auto-detects OpenClaw config path, auth mode, and token/password.

Options:
  --exposure <local|lan|cloudflare|tailscale>  Connection mode (default: lan)
  --host <hostname-or-ip>                       Override host for local/lan/tailscale
  --port <port>                                 Override gateway port
  --no-qr                                       Do not render terminal QR code
  --print-url                                   Print full pairing URL (contains secret)
  --detach                                      Keep cloudflared running after script exits
  --force                                       Bypass bind-mode safety checks for lan/tailscale
  --cloudflare-timeout <seconds>                Wait time for tunnel URL (default: 30)
  --openclaw-bin <path>                         OpenClaw CLI binary/script path
  -h, --help                                    Show this help message

Examples:
  $SCRIPT_NAME --exposure lan
  $SCRIPT_NAME --exposure cloudflare
  $SCRIPT_NAME --exposure tailscale
  $SCRIPT_NAME --openclaw-bin /usr/local/bin/openclaw --exposure lan
  $SCRIPT_NAME --exposure cloudflare --detach --print-url
USAGE
}

log() {
  printf '[INFO] %s\n' "$1"
}

warn() {
  printf '[WARN] %s\n' "$1" >&2
}

die() {
  printf '[ERROR] %s\n' "$1" >&2
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

trim() {
  local value="$1"
  # shellcheck disable=SC2001
  printf '%s' "$value" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

expand_path() {
  local raw="$1"
  local home_dir="${OPENCLAW_HOME:-$HOME}"

  if [[ "$raw" == "~" ]]; then
    printf '%s\n' "$home_dir"
    return
  fi

  if [[ "$raw" == ~/* ]]; then
    printf '%s/%s\n' "$home_dir" "${raw#~/}"
    return
  fi

  if [[ "$raw" == /* ]]; then
    printf '%s\n' "$raw"
    return
  fi

  printf '%s/%s\n' "$(pwd)" "$raw"
}

detect_config_path() {
  local home_dir="${OPENCLAW_HOME:-$HOME}"
  local state_dir="${OPENCLAW_STATE_DIR:-${CLAWDBOT_STATE_DIR:-}}"
  local candidates=()

  if [[ -n "${OPENCLAW_CONFIG_PATH:-}" ]]; then
    printf '%s\n' "$(expand_path "$OPENCLAW_CONFIG_PATH")"
    return
  fi

  if [[ -n "$state_dir" ]]; then
    state_dir="$(expand_path "$state_dir")"
    candidates+=(
      "$state_dir/openclaw.json"
      "$state_dir/clawdbot.json"
      "$state_dir/moltbot.json"
      "$state_dir/moldbot.json"
    )
  else
    candidates+=(
      "$home_dir/.openclaw/openclaw.json"
      "$home_dir/.openclaw/clawdbot.json"
      "$home_dir/.openclaw/moltbot.json"
      "$home_dir/.openclaw/moldbot.json"
      "$home_dir/.clawdbot/openclaw.json"
      "$home_dir/.clawdbot/clawdbot.json"
      "$home_dir/.moltbot/moltbot.json"
      "$home_dir/.moldbot/moldbot.json"
    )
  fi

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done

  if [[ -n "${OPENCLAW_STATE_DIR:-}" ]]; then
    printf '%s\n' "$(expand_path "$OPENCLAW_STATE_DIR")/openclaw.json"
    return
  fi

  printf '%s\n' "$home_dir/.openclaw/openclaw.json"
}

openclaw_get() {
  local path="$1"
  local out

  if ! out="$(OPENCLAW_NO_RICH=1 NO_COLOR=1 "${OPENCLAW_CMD[@]}" config get "$path" 2>/dev/null)"; then
    return 1
  fi

  # For our scalar fields we only need the first line.
  printf '%s' "$out" | awk 'NR==1 { print; exit }'
}

mask_secret() {
  local value="$1"
  local len=${#value}

  if (( len <= 4 )); then
    printf '****'
    return
  fi

  local prefix="${value:0:2}"
  local suffix="${value:len-2:2}"
  printf '%s****%s' "$prefix" "$suffix"
}

mask_pair_url() {
  local raw="$1"
  printf '%s' "$raw" | sed -E 's/([?&](token|password|secret)=)[^&]+/\1***REDACTED***/g'
}

urlencode() {
  local input="$1"
  local output=""
  local i char

  for (( i = 0; i < ${#input}; i++ )); do
    char="${input:i:1}"
    case "$char" in
      [a-zA-Z0-9.~_-])
        output+="$char"
        ;;
      *)
        printf -v char '%%%02X' "'${char}"
        output+="$char"
        ;;
    esac
  done

  printf '%s' "$output"
}

detect_lan_ip() {
  local default_iface=""
  local ip=""

  if command_exists route; then
    default_iface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
  fi

  if [[ -n "$default_iface" ]] && command_exists ipconfig; then
    ip="$(ipconfig getifaddr "$default_iface" 2>/dev/null || true)"
  fi

  if [[ -z "$ip" ]] && command_exists hostname; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi

  if [[ -z "$ip" ]] && command_exists ifconfig; then
    ip="$(ifconfig 2>/dev/null | awk '/inet / && $2 != "127.0.0.1" {print $2; exit}' || true)"
  fi

  ip="$(trim "$ip")"
  if [[ -z "$ip" ]]; then
    die "Unable to detect LAN IP. Use --host <your-ip>."
  fi

  printf '%s\n' "$ip"
}

detect_tailscale_host() {
  local host=""

  if ! command_exists tailscale; then
    die "tailscale CLI not found. Install Tailscale or use --exposure lan/cloudflare."
  fi

  host="$(tailscale ip -4 2>/dev/null | awk 'NR==1 {print; exit}' || true)"
  host="$(trim "$host")"

  if [[ -z "$host" ]]; then
    die "Unable to detect Tailscale IPv4. Ensure tailscale is running and logged in."
  fi

  printf '%s\n' "$host"
}

start_cloudflare_tunnel() {
  local port="$1"

  if ! command_exists cloudflared; then
    die "cloudflared not found. Install with: brew install cloudflared"
  fi

  local local_url="http://127.0.0.1:${port}"
  CF_LOG="${TMPDIR:-/tmp}/clawhome-cloudflared-$(date +%s).log"

  if (( DETACH == 1 )); then
    nohup cloudflared tunnel --no-autoupdate --url "$local_url" >"$CF_LOG" 2>&1 &
  else
    cloudflared tunnel --no-autoupdate --url "$local_url" >"$CF_LOG" 2>&1 &
  fi
  CF_PID="$!"

  local deadline=$((SECONDS + CLOUDFLARE_TIMEOUT))
  local found=""

  while (( SECONDS < deadline )); do
    if ! kill -0 "$CF_PID" 2>/dev/null; then
      break
    fi

    found="$(grep -Eo 'https://[-a-z0-9]+\.trycloudflare\.com' "$CF_LOG" | head -n 1 || true)"
    if [[ -n "$found" ]]; then
      break
    fi

    sleep 0.5
  done

  if [[ -z "$found" ]]; then
    if kill -0 "$CF_PID" 2>/dev/null; then
      kill "$CF_PID" >/dev/null 2>&1 || true
    fi
    die "Failed to obtain cloudflared public URL. Check log: $CF_LOG"
  fi

  CF_PUBLIC_HTTPS="${found%/}"
}

print_qr() {
  local payload="$1"

  if (( NO_QR == 1 )); then
    return
  fi

  if command_exists qrencode; then
    qrencode -t ANSIUTF8 "$payload"
    return
  fi

  warn "qrencode is not installed, cannot render terminal QR."
  warn "Install with: brew install qrencode"
}

cleanup() {
  if [[ -n "$CF_PID" ]] && (( CLEANUP_TUNNEL == 1 )); then
    if kill -0 "$CF_PID" 2>/dev/null; then
      kill "$CF_PID" >/dev/null 2>&1 || true
    fi
  fi
}

trap cleanup EXIT INT TERM

resolve_openclaw_cmd() {
  if [[ -n "$OPENCLAW_BIN" ]]; then
    OPENCLAW_CMD=("$OPENCLAW_BIN")
    OPENCLAW_LABEL="$OPENCLAW_BIN"
    return
  fi

  if command_exists openclaw; then
    OPENCLAW_CMD=("openclaw")
    OPENCLAW_LABEL="openclaw"
    return
  fi

  local sibling_openclaw="$REPO_ROOT/../openclaw/openclaw.mjs"
  if [[ -f "$sibling_openclaw" ]] && command_exists node; then
    OPENCLAW_CMD=("node" "$sibling_openclaw")
    OPENCLAW_LABEL="node $sibling_openclaw"
    return
  fi

  die "openclaw CLI not found. Install OpenClaw or pass --openclaw-bin <path>."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --exposure)
      [[ $# -ge 2 ]] || die "Missing value for --exposure"
      EXPOSURE="$2"
      shift 2
      ;;
    --host)
      [[ $# -ge 2 ]] || die "Missing value for --host"
      OVERRIDE_HOST="$2"
      shift 2
      ;;
    --port)
      [[ $# -ge 2 ]] || die "Missing value for --port"
      OVERRIDE_PORT="$2"
      shift 2
      ;;
    --no-qr)
      NO_QR=1
      shift
      ;;
    --print-url)
      PRINT_URL=1
      shift
      ;;
    --detach)
      DETACH=1
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --cloudflare-timeout)
      [[ $# -ge 2 ]] || die "Missing value for --cloudflare-timeout"
      CLOUDFLARE_TIMEOUT="$2"
      shift 2
      ;;
    --openclaw-bin)
      [[ $# -ge 2 ]] || die "Missing value for --openclaw-bin"
      OPENCLAW_BIN="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

case "$EXPOSURE" in
  local|lan|cloudflare|tailscale)
    ;;
  *) 
    die "Invalid --exposure: $EXPOSURE"
    ;;
esac

resolve_openclaw_cmd

CONFIG_PATH="$(detect_config_path)"
PORT_RAW="$(openclaw_get gateway.port || true)"
BIND_MODE="$(openclaw_get gateway.bind || true)"
AUTH_MODE="$(openclaw_get gateway.auth.mode || true)"

PORT_RAW="$(trim "$PORT_RAW")"
BIND_MODE="$(trim "$BIND_MODE")"
AUTH_MODE="$(trim "$AUTH_MODE" | tr '[:upper:]' '[:lower:]')"

if [[ -n "$OVERRIDE_PORT" ]]; then
  PORT="$OVERRIDE_PORT"
elif [[ "$PORT_RAW" =~ ^[0-9]+$ ]]; then
  PORT="$PORT_RAW"
else
  PORT="$DEFAULT_PORT"
fi

if [[ ! "$PORT" =~ ^[0-9]+$ ]]; then
  die "Invalid port: $PORT"
fi

TOKEN="$(trim "${OPENCLAW_GATEWAY_TOKEN:-}")"
PASSWORD="$(trim "${OPENCLAW_GATEWAY_PASSWORD:-}")"
TOKEN_SOURCE=""
PASSWORD_SOURCE=""

if [[ -n "$TOKEN" ]]; then
  TOKEN_SOURCE="OPENCLAW_GATEWAY_TOKEN"
else
  TOKEN="$(trim "$(openclaw_get gateway.auth.token || true)")"
  if [[ -n "$TOKEN" ]]; then
    TOKEN_SOURCE="gateway.auth.token"
  fi
fi

if [[ -n "$PASSWORD" ]]; then
  PASSWORD_SOURCE="OPENCLAW_GATEWAY_PASSWORD"
else
  PASSWORD="$(trim "$(openclaw_get gateway.auth.password || true)")"
  if [[ -n "$PASSWORD" ]]; then
    PASSWORD_SOURCE="gateway.auth.password"
  fi
fi

if [[ -z "$AUTH_MODE" ]]; then
  if [[ -n "$TOKEN" ]]; then
    AUTH_MODE="token"
  elif [[ -n "$PASSWORD" ]]; then
    AUTH_MODE="password"
  else
    AUTH_MODE="none"
  fi
fi

AUTH_QUERY=""
AUTH_SOURCE=""

if [[ "$AUTH_MODE" == "token" ]]; then
  [[ -n "$TOKEN" ]] || die "Auth mode is token, but no token found in env/config."
  AUTH_QUERY="token=$(urlencode "$TOKEN")"
  AUTH_SOURCE="$TOKEN_SOURCE"
elif [[ "$AUTH_MODE" == "password" ]]; then
  [[ -n "$PASSWORD" ]] || die "Auth mode is password, but no password found in env/config."
  AUTH_QUERY="password=$(urlencode "$PASSWORD")"
  AUTH_SOURCE="$PASSWORD_SOURCE"
else
  if [[ -n "$TOKEN" ]]; then
    AUTH_MODE="token"
    AUTH_QUERY="token=$(urlencode "$TOKEN")"
    AUTH_SOURCE="$TOKEN_SOURCE"
  elif [[ -n "$PASSWORD" ]]; then
    AUTH_MODE="password"
    AUTH_QUERY="password=$(urlencode "$PASSWORD")"
    AUTH_SOURCE="$PASSWORD_SOURCE"
  else
    warn "No gateway token/password detected. Pairing URL will be unauthenticated."
  fi
fi

HOST=""
BASE_URL=""

case "$EXPOSURE" in
  local)
    HOST="${OVERRIDE_HOST:-127.0.0.1}"
    BASE_URL="ws://${HOST}:${PORT}"
    ;;
  lan)
    if [[ -n "$OVERRIDE_HOST" ]]; then
      HOST="$OVERRIDE_HOST"
    else
      HOST="$(detect_lan_ip)"
    fi

    if [[ "$FORCE" -ne 1 ]] && [[ "$BIND_MODE" == "loopback" || "$BIND_MODE" == "auto" || -z "$BIND_MODE" ]]; then
      die "Gateway bind mode is '${BIND_MODE:-auto}'. For LAN phones, start OpenClaw with --bind lan (or set gateway.bind=lan), then retry. You can bypass with --force."
    fi

    BASE_URL="ws://${HOST}:${PORT}"
    ;;
  tailscale)
    if [[ -n "$OVERRIDE_HOST" ]]; then
      HOST="$OVERRIDE_HOST"
    else
      HOST="$(detect_tailscale_host)"
    fi

    if [[ "$FORCE" -ne 1 ]] && [[ "$BIND_MODE" != "tailnet" ]]; then
      warn "gateway.bind is '${BIND_MODE:-auto}', not 'tailnet'. Direct tailnet ws may be unreachable."
      warn "Use --force to continue, or configure gateway.bind=tailnet."
      exit 1
    fi

    BASE_URL="ws://${HOST}:${PORT}"
    ;;
  cloudflare)
    start_cloudflare_tunnel "$PORT"
    HOST="${CF_PUBLIC_HTTPS#https://}"
    BASE_URL="wss://${HOST}"
    ;;
esac

PAIR_URL="$BASE_URL"
if [[ -n "$AUTH_QUERY" ]]; then
  if [[ "$PAIR_URL" == *\?* ]]; then
    PAIR_URL="${PAIR_URL}&${AUTH_QUERY}"
  else
    PAIR_URL="${PAIR_URL}?${AUTH_QUERY}"
  fi
fi

MASKED_PAIR_URL="$(mask_pair_url "$PAIR_URL")"

log "OpenClaw config path: $CONFIG_PATH"
log "OpenClaw CLI: $OPENCLAW_LABEL"
log "Gateway bind mode: ${BIND_MODE:-auto}"
log "Gateway port: $PORT"
log "Exposure mode: $EXPOSURE"
log "Auth mode: $AUTH_MODE"
if [[ -n "$AUTH_SOURCE" ]]; then
  log "Auth source: $AUTH_SOURCE"
fi

if [[ "$AUTH_MODE" == "token" ]]; then
  log "Token (masked): $(mask_secret "$TOKEN")"
elif [[ "$AUTH_MODE" == "password" ]]; then
  log "Password (masked): $(mask_secret "$PASSWORD")"
fi

log "Pairing URL (masked): $MASKED_PAIR_URL"

if (( PRINT_URL == 1 )); then
  printf '\nFULL_PAIRING_URL=%s\n' "$PAIR_URL"
fi

printf '\nScan this QR in ClawHome -> Add Gateway -> Scan QR Code\n\n'
print_qr "$PAIR_URL"

if (( NO_QR == 1 )); then
  printf '%s\n' "$PAIR_URL"
fi

if [[ "$EXPOSURE" == "cloudflare" ]]; then
  if (( DETACH == 1 )); then
    CLEANUP_TUNNEL=0
    log "Cloudflare tunnel is running in background (pid: $CF_PID)."
    log "Tunnel log: $CF_LOG"
    log "Stop tunnel: kill $CF_PID"
  else
    log "Cloudflare tunnel running (pid: $CF_PID). Keep this terminal open."
    log "Press Ctrl+C to stop."
    wait "$CF_PID"
  fi
fi
