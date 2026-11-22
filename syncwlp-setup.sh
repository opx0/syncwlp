#!/bin/bash
# syncwlp-setup.sh — sync wallpapers across machines via syncthing
#
# one script, one curl. works over the internet — no VPN needed.
# syncthing handles discovery, NAT traversal, and encryption.
#
# usage:
#   first machine  — bash syncwlp-setup.sh
#   other machines — bash syncwlp-setup.sh --join DEVICE_ID
#
# env vars:
#   SYNCWLP_FOLDER_ID — syncthing folder id (default: wallpapers)
#
# what happens:
#   1. installs syncthing + jq via pacman
#   2. starts syncthing, configures shared wallpaper folder
#   3. if --join: adds the introducer device (syncthing connects via global discovery)
#
# After setup, accept the joining device AND share Wallpapers with it on the
# introducer. No global folder auto-accept policy is changed.

set -euo pipefail

main() {

# ── config ────────────────────────────────────────────────────────────────────
WALLPAPER_DIR="$HOME/Pictures/Wallpapers"
FOLDER_ID="${SYNCWLP_FOLDER_ID:-wallpapers}"
FOLDER_LABEL="Wallpapers"
ST_API=""
API_KEY=""  # set after syncthing starts

# ── output ────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' N='\033[0m'
else
  R='' G='' Y='' C='' N=''
fi
log()  { printf "${G}::${N} %s\n" "$*"; }
warn() { printf "${Y}::${N} %s\n" "$*"; }
die()  { printf "${R}::${N} %s\n" "$*" >&2; exit 1; }

# ── args ──────────────────────────────────────────────────────────────────────
INTRODUCER_ID=""
MODE="introducer"
CHECK_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK_ONLY=true; shift ;;
    --join)
      [[ $# -lt 2 ]] && die "--join requires a device ID"
      INTRODUCER_ID="$2"
      # validate syncthing device ID format: 8 groups of 7 base32 chars
      if ! [[ "$INTRODUCER_ID" =~ ^[A-Z2-7]{7}-[A-Z2-7]{7}-[A-Z2-7]{7}-[A-Z2-7]{7}-[A-Z2-7]{7}-[A-Z2-7]{7}-[A-Z2-7]{7}-[A-Z2-7]{7}$ ]]; then
        die "invalid device ID format: $INTRODUCER_ID"
      fi
      MODE="join"; shift 2 ;;
    -h|--help)
      printf "usage: bash syncwlp-setup.sh [--check] [--join INTRODUCER_DEVICE_ID]\n\n"
      printf "  --check  inspect the running instance without changing it\n"
      printf "  first machine:   bash syncwlp-setup.sh\n"
      printf "  other machines:  %s --join <DEVICE_ID>\n" "$0"
      printf "\nenv vars:\n"
      printf "  SYNCWLP_FOLDER_ID  syncthing folder id (default: wallpapers)\n"
      exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ "$EUID" -ne 0 ]] || die "Run as your desktop user, not root or sudo"
[[ "$FOLDER_ID" =~ ^[A-Za-z0-9._-]+$ && "$FOLDER_ID" != . && "$FOLDER_ID" != .. ]] || die "Invalid folder ID: use letters, numbers, dot, underscore or hyphen, but not . or .."

# ── helpers ───────────────────────────────────────────────────────────────────
st() {
  [[ -z "$API_KEY" ]] && die "BUG: st() called before API_KEY is set"
  local method="$1" path="$2" body="${3:-}"
  local args=(--silent --show-error --fail --noproxy '*' --connect-timeout 2 --max-time 10
    -H "X-API-Key: ${API_KEY}" -H "Content-Type: application/json")
  [[ "$method" != "GET" ]] && args+=(-X "$method")
  [[ -n "$body" ]] && args+=(-d "$body")
  curl "${args[@]}" "${ST_API}${path}"
}

wait_for_api() {
  local tries=30 i
  for ((i=1; i<=tries; i++)); do
    if st GET /rest/system/ping >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  die "syncthing API not responding after ${tries} attempts"
}

# ══════════════════════════════════════════════════════════════════════════════
# step 1: packages
# ══════════════════════════════════════════════════════════════════════════════
log "installing packages..."

for pkg in syncthing jq python curl; do
  if command -v "$pkg" >/dev/null 2>&1; then
    log "  $pkg: already installed"
  else
    [[ "$CHECK_ONLY" == false ]] || die "--check needs $pkg installed; no packages were changed"
    command -v pacman >/dev/null || die "Automatic installation requires Arch Linux / pacman"
    sudo pacman -S --needed --noconfirm "$pkg"
  fi
done

# ══════════════════════════════════════════════════════════════════════════════
# step 2: syncthing
# ══════════════════════════════════════════════════════════════════════════════
log "starting syncthing..."

# Leave active service enablement and unrelated watcher units untouched.
if systemctl --user is-active --quiet syncthing.service; then
  log "  reusing the running Syncthing service"
else
  [[ "$CHECK_ONLY" == false ]] || die "--check requires a running syncthing.service; nothing was started"
  command -v pgrep >/dev/null || die "Cannot check for another instance: pgrep is required"
  if pgrep -u "$EUID" -x syncthing >/dev/null; then
    die "Syncthing is running outside the user unit; refusing to start another instance"
  fi
  systemctl --user enable --now syncthing.service
fi
PID=$(systemctl --user show syncthing.service -p MainPID --value)
[[ "$PID" =~ ^[1-9][0-9]*$ ]] || die "Syncthing service has no running main process"
CONFIG=$(python - "$PID" <<'PY'
import os
from pathlib import Path
import subprocess
import sys

proc = Path('/proc') / sys.argv[1]
args = [os.fsdecode(a) for a in (proc / 'cmdline').read_bytes().split(b'\0') if a]
env = dict(os.fsdecode(entry).split('=', 1)
           for entry in (proc / 'environ').read_bytes().split(b'\0') if b'=' in entry)
flags = []
it = iter(args[1:])
for arg in it:
    name, sep, value = arg.partition('=')
    # Forward only path flags; other serve flags do not belong to `paths`.
    if name in ('--home', '--config', '--data', '-home', '-config', '-data', '-H', '-C', '-D'):
        value = value if sep else next(it, '')
        if not value:
            sys.exit('Missing service path option value')
        option = {'-H': '--home', '-C': '--config', '-D': '--data'}.get(name, '--' + name.lstrip('-'))
        flags.extend([option, value])
    elif name in ('--gui-address', '--gui-apikey', '-gui-address', '-gui-apikey'):
        sys.exit('GUI command-line overrides are unsupported')
if env.get('STGUIADDRESS') or env.get('STGUIAPIKEY'):
    sys.exit('GUI environment overrides are unsupported')
cwd = (proc / 'cwd').resolve(strict=True)
paths = subprocess.check_output([str(proc / 'exe'), 'paths', *flags],
                                cwd=cwd, env=env, text=True, timeout=10)
for line in paths.splitlines():
    path = Path(line.strip())
    if path.name == 'config.xml':
        print((cwd / path).resolve())
        break
else:
    sys.exit('Syncthing did not report a config.xml path; this service/version is unsupported')
PY
) || die "Cannot resolve the running service's config path"

for ((i=0; i<30; i++)); do
  [[ -s "$CONFIG" ]] && break
  sleep 1
done
[[ -s "$CONFIG" ]] || die "Timed out waiting for $CONFIG"
GUI=$(python - "$CONFIG" <<'PY'
import sys
import xml.etree.ElementTree as ET

gui = ET.parse(sys.argv[1]).getroot().find('gui')
if gui is None or gui.get('enabled', 'true').lower() == 'false':
    sys.exit('Enable the Syncthing GUI first')
host, _, port = gui.findtext('address', '').strip().rpartition(':')
if host not in ('127.0.0.1', 'localhost', '0.0.0.0', '[::1]', '[::]') or not port.isdigit() or not 0 < int(port) < 65536:
    sys.exit('Expected a local TCP GUI address')
if gui.get('tls', 'false').lower() == 'true':
    sys.exit('This installer requires a local HTTP GUI; HTTPS is unsupported')
key = gui.findtext('apikey', '').strip()
if not key:
    sys.exit('Missing Syncthing API key')
host = '[::1]' if host.startswith('[') else '127.0.0.1'
print(f'http://{host}:{port}')
print(key)
PY
) || die "Cannot read GUI settings from $CONFIG"
ST_API=${GUI%%$'\n'*}
API_KEY=${GUI#*$'\n'}
wait_for_api
ACTIVE_CONFIG=$(st GET /rest/system/paths | jq -er '.config')
[[ "$ACTIVE_CONFIG" -ef "$CONFIG" ]] || die "API belongs to a different Syncthing configuration"
MY_ID=$(st GET /rest/system/status | jq -er '.myID')
[[ "$MY_ID" != "$INTRODUCER_ID" ]] || die "Cannot join this device to itself"
log "  device id: $MY_ID"

# ══════════════════════════════════════════════════════════════════════════════
# step 4: configure syncthing
# ══════════════════════════════════════════════════════════════════════════════
log "configuring syncthing..."

# ══════════════════════════════════════════════════════════════════════════════
# step 5: wallpapers folder
# ══════════════════════════════════════════════════════════════════════════════
log "setting up wallpapers folder..."
if [[ "$CHECK_ONLY" == false ]]; then mkdir -p "$WALLPAPER_DIR"; fi

EXISTING=$(st GET /rest/config/folders | jq -r --arg id "$FOLDER_ID" '.[] | select(.id==$id) | .id')
if [[ "$EXISTING" == "$FOLDER_ID" ]]; then
  CURRENT=$(st GET "/rest/config/folders/${FOLDER_ID}")
  EXISTING_PATH=$(jq -r '.path' <<<"$CURRENT")
  EXISTING_TYPE=$(jq -r '.type' <<<"$CURRENT")
  if [[ "$EXISTING_PATH" != "$WALLPAPER_DIR" || "$EXISTING_TYPE" != sendreceive ]]; then
    die "folder '$FOLDER_ID' already points to '$EXISTING_PATH' ($EXISTING_TYPE); refusing to repoint shared data"
  fi
  log "  reusing existing folder '$FOLDER_ID' at '$EXISTING_PATH'"
else
  if [[ "$CHECK_ONLY" == true ]]; then
    log "  --check: would create folder '$FOLDER_ID' at '$WALLPAPER_DIR'"
  else
    PAYLOAD=$(jq -n \
      --arg id "$FOLDER_ID" \
      --arg label "$FOLDER_LABEL" \
      --arg path "$WALLPAPER_DIR" \
      --arg myid "$MY_ID" \
      '{id:$id, label:$label, path:$path, type:"sendreceive",
        rescanIntervalS:60, fsWatcherEnabled:true, fsWatcherDelayS:5,
        devices:[{deviceID:$myid}]}')
    st POST /rest/config/folders "$PAYLOAD" >/dev/null
    log "  created folder: $WALLPAPER_DIR"
  fi
fi
# ══════════════════════════════════════════════════════════════════════════════
# step 6: device registration
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$MODE" == "introducer" ]]; then
  log "this machine is the introducer"

else
  # ── joining an existing network ──
  log "joining network via introducer..."

  # add introducer device locally
  KNOWN=$(st GET /rest/config/devices | jq -r --arg id "$INTRODUCER_ID" '.[] | select(.deviceID==$id) | .deviceID')
  if [[ "$KNOWN" == "$INTRODUCER_ID" ]]; then
    log "  preserving existing introducer trust settings"
  elif [[ "$CHECK_ONLY" == true ]]; then
    log "  --check: would add introducer $INTRODUCER_ID; no settings changed"
  else
    st POST /rest/config/devices "$(jq -n \
      --arg id "$INTRODUCER_ID" \
      '{deviceID:$id, name:"syncwlp-introducer", addresses:["dynamic"],
        introducer:true, autoAcceptFolders:false}')" >/dev/null
    log "  added introducer to local config"
  fi

  # add introducer to the wallpapers folder
  FOLDER_JSON=$(st GET "/rest/config/folders/${FOLDER_ID}")
  HAS_IT=$(echo "$FOLDER_JSON" | jq -r --arg id "$INTRODUCER_ID" '.devices[] | select(.deviceID==$id) | .deviceID')
  if [[ "$HAS_IT" != "$INTRODUCER_ID" ]]; then
    if [[ "$CHECK_ONLY" == true ]]; then
      log "  --check: introducer not in folder device list; no settings changed"
    else
      DEVS=$(echo "$FOLDER_JSON" | jq --arg id "$INTRODUCER_ID" '.devices + [{"deviceID":$id}]')
      st PATCH "/rest/config/folders/${FOLDER_ID}" "{\"devices\":${DEVS}}" >/dev/null
      log "  added introducer to wallpapers folder"
    fi
  fi

  if [[ "$CHECK_ONLY" == false ]]; then
    warn "On the introducer, accept this device AND share the Wallpapers folder with it in folder settings."
    warn "Syncthing does not automatically share existing folders with newly accepted devices."
  fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# step 7: restart syncthing (apply config changes)
# ══════════════════════════════════════════════════════════════════════════════
restart_required() {
  st GET /rest/config/restart-required | jq -er '.requiresRestart | booleans | tostring'
}
required=$(restart_required)
if [[ "$CHECK_ONLY" == true ]]; then
  log "  --check: restart required=$required; no restart performed"
elif [[ "$required" == true ]]; then
  systemctl --user restart syncthing.service
  wait_for_api
  recovered_id=$(st GET /rest/system/status | jq -er '.myID')
  required=$(restart_required)
  [[ "$MY_ID" == "$recovered_id" && "$required" == false ]] || die "Restart verification failed"
  log "  Syncthing restarted and identity verified"
else
  log "  Syncthing restart not required"
fi

if [[ "$CHECK_ONLY" == true ]]; then
  log "check complete; no configuration, service, or filesystem changes made"
  return 0
fi

# ══════════════════════════════════════════════════════════════════════════════
# done
# ══════════════════════════════════════════════════════════════════════════════
printf "\n"
log "setup complete"
printf "\n"
printf "  wallpapers:  %s\n" "$WALLPAPER_DIR"
printf "  folder id:   %s\n" "$FOLDER_ID"
printf "  device id:   %s\n" "$MY_ID"
printf "  syncthing:   %s\n" "$ST_API"
printf "\n"

if [[ "$MODE" == "introducer" ]]; then
  printf "  ${C}share this with friends:${N}\n"
  printf "\n"
  printf "    ${C}curl -fsSL https://raw.githubusercontent.com/opx0/syncwlp/main/syncwlp-setup.sh | bash -s -- --join %s${N}\n" "$MY_ID"
  if [[ "$FOLDER_ID" != wallpapers ]]; then
    printf "  include the same folder ID on every peer:\n"
    printf "    ${C}curl -fsSL https://raw.githubusercontent.com/opx0/syncwlp/main/syncwlp-setup.sh | SYNCWLP_FOLDER_ID=%q bash -s -- --join %s${N}\n" "$FOLDER_ID" "$MY_ID"
  fi
  printf "\n"
  printf "  accept each joining device and share Wallpapers with it in Syncthing.\n"
else
  printf "  waiting for introducer to accept this device.\n"
  printf "  once accepted, wallpapers will sync automatically.\n"
fi
printf "\n"

} # end main

main "$@"
