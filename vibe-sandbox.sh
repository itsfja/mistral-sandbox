#!/usr/bin/env bash
# ============================================================================
# vibe-sandbox.sh — single-use, rebuild-on-demand LXC sandbox for Proxmox VE
#
# Semantics (by design):
#   * SINGLE USE:      one sandbox exists at a time (fixed CTID); `down`
#                      destroys it completely. Nothing persists between uses.
#   * AUTO REBUILD:    `up` NEVER resumes an old container — it destroys any
#                      existing one and builds a fresh CT from the template,
#                      so every startup is a clean rebuild.
#   * SERIALLY REBUILDABLE: a global flock serializes all operations, and the
#                      build is deterministic from the config block below,
#                      so rebuild #1 == rebuild #50.
#   * INTERNET-ENABLED: outbound net is unrestricted — the agent can
#                      download any tool it needs (apt, curl, pip, uv, npm)
#                      and search/fetch the web whenever required.
#   * MISTRAL-TOOLED:  every rebuild installs the CURRENT Vibe CLI
#                      (mistral-vibe) at build time, so each fresh sandbox
#                      gets the latest iteration of Mistral tooling.
#   * CREDENTIALD:     a permanent key store on the HOST ($SECRETS_FILE,
#                      default /root/.vibe-sandbox.env, mode 600) is
#                      re-injected into every rebuild as /root/.vibe/.env.
#                      The key is a normal Mistral API key: create it at
#                      chat.mistral.ai (Code > Vibe CLI), revoke or rotate
#                      it from the console at any time. The key lives only
#                      in the host file and the ephemeral CT — never in
#                      this script or any repository.
#
# Run ON the Proxmox host as root (uses `pct` / `pveam`).
# Tested syntax: PVE 8.x. Review flags against your version before first run.
#
# Subcommands:
#   up        rebuild + start + provision + print SSH line
#   down      stop + destroy (single-use teardown)
#   reset     down && up (fresh rebuild mid-work)
#   status    is the sandbox up? show CTID, state, IP
#   shell     drop into a root shell inside the CT
#   ip        print the current IP (empty if not running)
#
# Optional: place a `provision.sh` beside this script — it runs INSIDE the
# fresh CT on every `up`, AFTER the base provisioning (extra toolchains, repo
# clone, etc.). Keep it deterministic to keep rebuilds identical.
#
# NOTE on auth: with SECRETS_FILE present, `vibe` authenticates from the
# injected /root/.vibe/.env (MISTRAL_API_KEY=...) on every rebuild — no
# interactive wizard needed. If the file is missing, `up` still builds, but
# the first `vibe` launch falls back to the setup wizard (browser URL or
# pasted key). Verify the active credential source in-session with
# `/whoami` or `/status`.
# ============================================================================

set -euo pipefail

# --------------------------- configuration ---------------------------------
CTID="${CTID:-1042}"                 # fixed ID = only one sandbox ever exists
CTHOST="${CTHOST:-vibe-sandbox}"
CORES="${CORES:-4}"
RAM_MB="${RAM_MB:-4096}"
SWAP_MB="${SWAP_MB:-2048}"
DISK_GB="${DISK_GB:-40}"
STORAGE="${STORAGE:-local-lvm}"       # storage for rootfs
BRIDGE="${BRIDGE:-vmbr0}"
TEMPLATE="${TEMPLATE:-}"              # e.g. local:vztmpl/debian-12-standard_...tar.zst
                                     # empty = auto-pick newest Debian 12 template
SSH_PUBKEY="${SSH_PUBKEY:-$HOME/.ssh/id_ed25519.pub}"
SECRETS_FILE="${SECRETS_FILE:-/root/.vibe-sandbox.env}"   # host-side key store
PROVISION_HOOK="$(dirname "$0")/provision.sh"
LOCK_FILE="/run/lock/vibe-sandbox.lock"

# --------------------------- helpers ---------------------------------------
die() { echo "error: $*" >&2; exit 1; }

lock_or_die() {
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "another vibe-sandbox operation is running (serial rebuild only)"
}

template_auto() {
  pveam update >/dev/null 2>&1 || true
  local t
  t="$(pveam available --section system 2>/dev/null \
       | awk '/debian-12-standard/ {print $2}' | tail -n1)"
  [ -n "$t" ] || die "no debian-12 template found; set TEMPLATE manually"
  # download if not already present
  pveam list local 2>/dev/null | grep -q "${t##*/}" || pveam download local "$t"
  echo "local:vztmpl/${t##*/}"
}

ct_exists()  { pct status "$CTID" >/dev/null 2>&1; }
ct_running() { [ "$(pct status "$CTID" 2>/dev/null | awk '{print $2}')" = "running" ]; }

sandbox_ip() {
  pct exec "$CTID" -- sh -c 'hostname -I 2>/dev/null | cut -d" " -f1' 2>/dev/null || true
}

wait_for_ip() {
  local ip="" i
  for i in $(seq 1 45); do
    ip="$(sandbox_ip)"
    [ -n "$ip" ] && { echo "$ip"; return 0; }
    sleep 2
  done
  return 1
}

destroy_sandbox() {
  if ct_exists; then
    ct_running && pct stop "$CTID"
    pct destroy "$CTID" --purge
    echo "destroyed CT $CTID"
  fi
}

# Base provisioning script, executed INSIDE the fresh CT on every build.
# A general-purpose baseline toolchain plus the CURRENT Vibe CLI (always the
# latest release at build time — no pinning, by design). Anything beyond
# this, the agent installs itself at runtime over the open outbound net.
provision_base_script() {
  cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# general-purpose baseline: the agent extends this at runtime as needed
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  ca-certificates curl wget git build-essential \
  python3 python3-pip python3-venv \
  unzip zip jq ripgrep man-db sudo || true

# current iteration of Mistral tooling, fetched at build time
curl -LsSf https://mistral.ai/vibe/install.sh | bash

# make the CLI reachable from non-login shells
ln -sf /root/.local/bin/vibe     /usr/local/bin/vibe     2>/dev/null || true
ln -sf /root/.local/bin/vibe-acp /usr/local/bin/vibe-acp 2>/dev/null || true

vibe --version
EOF
}

# Re-inject the permanent credential store into the fresh CT.
# The CLI reads /root/.vibe/.env automatically on startup; shell env vars
# take precedence over it, but the sandbox sets none, so this is the source.
inject_credentials() {
  if [ ! -f "$SECRETS_FILE" ]; then
    echo "warning: no key store at $SECRETS_FILE — CLI will need the setup wizard" >&2
    echo "  create a key at chat.mistral.ai (Code > Vibe CLI), then run:" >&2
    echo "    printf 'MISTRAL_API_KEY=<key>\n' > $SECRETS_FILE && chmod 600 $SECRETS_FILE" >&2
    return 0
  fi
  [ "$(stat -c %a "$SECRETS_FILE")" = "600" ] || chmod 600 "$SECRETS_FILE"
  pct exec "$CTID" -- mkdir -p /root/.vibe
  pct push "$CTID" "$SECRETS_FILE" /root/.vibe/.env
  pct exec "$CTID" -- chown root:root /root/.vibe/.env
  pct exec "$CTID" -- chmod 600 /root/.vibe/.env
  echo "credentials injected (host: $SECRETS_FILE -> CT: /root/.vibe/.env)"
}

# --------------------------- subcommands ------------------------------------
cmd_up() {
  lock_or_die
  # AUTO REBUILD: never resume — tear down any prior sandbox first
  destroy_sandbox

  [ "$EUID" -eq 0 ] || die "must run as root on the Proxmox host"
  [ -f "$SSH_PUBKEY" ] || die "no SSH public key at $SSH_PUBKEY (set SSH_PUBKEY)"
  [ -n "$TEMPLATE" ] || TEMPLATE="$(template_auto)"

  echo "building CT $CTID from $TEMPLATE ..."
  pct create "$CTID" "$TEMPLATE" \
    --hostname "$CTHOST" \
    --cores "$CORES" --memory "$RAM_MB" --swap "$SWAP_MB" \
    --rootfs "${STORAGE}:${DISK_GB}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --unprivileged 1 \
    --features nesting=1 \
    --ssh-public-keys "$SSH_PUBKEY" \
    --onboot 0 \
    --start 1

  local ip
  ip="$(wait_for_ip)" || { echo "container started but no IP (check vmbr0/DHCP)"; exit 1; }

  # base provisioning: latest toolchain + current Mistral tooling
  echo "provisioning base toolchain and Vibe CLI ..."
  local prov
  prov="$(mktemp)"
  provision_base_script > "$prov"
  pct push "$CTID" "$prov" /root/provision-base.sh
  pct exec "$CTID" -- bash /root/provision-base.sh
  rm -f "$prov"

  # permanent credential store -> fresh CT, every build
  inject_credentials

  # user hook (deterministic per-use extras), if present
  if [ -f "$PROVISION_HOOK" ]; then
    pct push "$CTID" "$PROVISION_HOOK" /root/provision.sh
    pct exec "$CTID" -- bash /root/provision.sh
  fi

  echo "sandbox ready."
  echo "  ssh root@${ip}"
}

cmd_down() {
  lock_or_die
  destroy_sandbox
  echo "sandbox is gone; next 'up' builds fresh from the template."
}

cmd_status() {
  if ! ct_exists; then echo "no sandbox (CT $CTID absent)"; exit 0; fi
  if ct_running; then
    echo "CT $CTID running, ip: $(sandbox_ip)"
  else
    echo "CT $CTID exists but stopped"
  fi
}

cmd_shell() {
  ct_running || die "sandbox not running; run 'up' first"
  pct enter "$CTID"
}

# --------------------------- dispatch ---------------------------------------
case "${1:-}" in
  up)     shift; cmd_up ;;
  down)   shift; cmd_down ;;
  reset)  shift; cmd_down; cmd_up ;;
  status) shift; cmd_status ;;
  ip)     sandbox_ip ;;
  shell)  shift; cmd_shell ;;
  *) awk '/^set -/ {exit} /^#/ {print}' "$0"; exit 1 ;;
esac

# --------------------------- auto-rebuild-on-boot (optional) -----------------
# To make the Proxmox host rebuild the sandbox on every host boot, save as
# /etc/cron.d/vibe-sandbox (rebuilds even if a stale CT survived a crash):
#
#   @root /root/vibe-sandbox.sh up >> /var/log/vibe-sandbox.log 2>&1
#
# For an on-demand session model instead (recommended for single-use):
# pair `up` before the agent starts and `down` after review, e.g. a wrapper:
#
#   vibe-sandbox.sh up && ssh root@$(vibe-sandbox.sh ip) ; vibe-sandbox.sh down
