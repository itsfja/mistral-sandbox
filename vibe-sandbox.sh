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
#   * SSH-KEYED:       a dedicated sandbox keypair is retained on the HOST
#                      (default /root/.vibe-sandbox-ssh), generated on the
#                      first `up` and reused for every rebuild; only the
#                      public half is injected into the CT. The private key
#                      stays on the host. Override with SSH_PUBKEY to
#                      reuse an existing key instead.
#   * GUI-TRAPPED:      with HOOK=on (default), the Proxmox GUI drives the
#                      whole lifecycle through a pct hookscript:
#                        right-click Start   = fresh rebuild + provisioning
#                        right-click Stop    = disk clobber + parked stub
#                        right-click Restart = fresh rebuild
#                      The hook shim is auto-deployed to local:snippets on
#                      every run; set HOOK=off to disable GUI trapping.
#   * CLOBBERED:        on stop, the rootfs is discarded (CLOBBER=discard,
#                      default, instant on SSD) or zero-filled (CLOBBER=zero,
#                      slower but overwrite-grade) and the CT is replaced
#                      by a pristine, unprovisioned STOPPED STUB with the
#                      same CTID — so the GUI keeps a Start-able object
#                      while the stopped sandbox holds nothing from the
#                      previous session. CLOBBER=off skips the wipe.
#
# Run ON the Proxmox host as root (uses `pct` / `pveam` / `pvesm`).
# Tested syntax: PVE 8.x. Review flags against your version before first run.
#
# Subcommands:
#   up        rebuild + start + provision + print SSH line
#   down      clobber disk + park a fresh stopped stub (GUI Start-able)
#   purge     destroy completely — no stub, gone from the tree
#   reset     down then up (fresh rebuild mid-work)
#   status    is the sandbox up? show CTID, state, IP
#   shell     drop into a root shell inside the CT
#   ip        print the current IP (empty if not running)
#   hook      INTERNAL — called by the PVE hookscript shim with (vmid, phase)
#
# Optional: place a `provision.sh` beside this script — it runs INSIDE the
# fresh CT on every build, AFTER the base provisioning (extra toolchains, repo
# clone, etc.). Keep it deterministic to keep rebuilds identical.
#
# NOTE on auth: with SECRETS_FILE present, `vibe` authenticates from the
# injected /root/.vibe/.env (MISTRAL_API_KEY=...) on every rebuild — no
# interactive wizard needed. If the file is missing, builds still work, but
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
SSH_PUBKEY="${SSH_PUBKEY:-}"           # optional override; empty = managed keypair
SSH_KEY_FILE="${SSH_KEY_FILE:-/root/.vibe-sandbox-ssh}"   # host-side keypair (permanent)
SECRETS_FILE="${SECRETS_FILE:-/root/.vibe-sandbox.env}"   # host-side key store
HOOK="${HOOK:-on}"                    # on = attach PVE hookscript (GUI trap)
CLOBBER="${CLOBBER:-discard}"         # discard | zero | off — post-stop rootfs wipe
HOOK_VOL_ID="local:snippets/vibe-sandbox-hook.sh"
HOOK_SNIPPET_DIR="${HOOK_SNIPPET_DIR:-/var/lib/vz/snippets}"
PROVISION_HOOK="$(dirname "$0")/provision.sh"
LOCK_FILE="/run/lock/vibe-sandbox.lock"

# --------------------------- helpers ---------------------------------------
die() { echo "error: $*" >&2; exit 1; }

lock_or_die() {
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "another vibe-sandbox operation is running (serial rebuild only)"
}

# Permanent, script-managed SSH keypair, retained on the HOST across
# rebuilds (same pattern as the credential store). Generated once on the
# first `up`; the public half is injected into every fresh CT. The private
# key never leaves the host and never enters any repository.
# With SSH_PUBKEY set, the override is used and no key is generated.
ensure_ssh_key() {
  if [ -n "$SSH_PUBKEY" ]; then
    [ -f "$SSH_PUBKEY" ] || die "no SSH public key at $SSH_PUBKEY (set SSH_PUBKEY)"
    SSH_KEY_FILE=""
    return 0
  fi
  if [ ! -f "$SSH_KEY_FILE" ]; then
    ssh-keygen -t ed25519 -N "" -C "vibe-sandbox" -f "$SSH_KEY_FILE" >/dev/null
    echo "generated sandbox keypair (retained on host): $SSH_KEY_FILE"
  fi
  chmod 600 "$SSH_KEY_FILE"
  SSH_PUBKEY="${SSH_KEY_FILE}.pub"
}

# Auto-deploy the PVE hookscript shim (idempotent). The shim only forwards
# (vmid, phase) to this script's internal `hook` subcommand.
ensure_hook_snippet() {
  [ "$HOOK" = "on" ] || return 0
  local self
  self="$(readlink -f "$0")"
  mkdir -p "$HOOK_SNIPPET_DIR"
  printf '#!/usr/bin/env bash\n# vibe-sandbox PVE hookscript shim — auto-generated, safe to overwrite\nvmid="$1"; phase="$2"\nexec %q hook "$vmid" "$phase"\n' \
    "$self" > "${HOOK_SNIPPET_DIR}/vibe-sandbox-hook.sh"
  chmod +x "${HOOK_SNIPPET_DIR}/vibe-sandbox-hook.sh"
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

# Create the sandbox CT. $1 = start | stopped. The hookscript is attached
# whenever HOOK=on so the GUI trap works on every incarnation, stub included.
create_sandbox() {
  local hookargs=() startargs=()
  [ "$HOOK" = "on" ] && hookargs=(--hookscript "$HOOK_VOL_ID")
  [ "${1:-start}" = "start" ] && startargs=(--start 1)
  pct create "$CTID" "$TEMPLATE" \
    --hostname "$CTHOST" \
    --cores "$CORES" --memory "$RAM_MB" --swap "$SWAP_MB" \
    --rootfs "${STORAGE}:${DISK_GB}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --unprivileged 1 \
    --features nesting=1 \
    --ssh-public-keys "$SSH_PUBKEY" \
    --onboot 0 \
    "${hookargs[@]}" \
    "${startargs[@]}"
}

# Wipe the rootfs of the STOPPED CT (keep the disk object, destroy the data).
clobber_disk() {
  [ "$CLOBBER" = "off" ] && return 0
  local line volid dev
  line="$(pct config "$CTID" 2>/dev/null | awk '/^rootfs:/')" || true
  volid="$(echo "$line" | cut -d' ' -f2 | cut -d, -f1)"
  [ -n "$volid" ] || { echo "clobber: no rootfs volid found, skipping"; return 0; }
  dev="$(pvesm path "$volid" 2>/dev/null || true)"
  case "$dev" in
    /dev/*) ;;
    *) echo "clobber: $volid is not /dev-backed ($dev) — skipping wipe" >&2; return 0 ;;
  esac
  if [ "$CLOBBER" = "zero" ]; then
    echo "clobber: zero-filling $dev ..."
    dd if=/dev/zero of="$dev" bs=1M status=none || true
  else
    blkdiscard "$dev" 2>/dev/null \
      || echo "clobber: blkdiscard failed on $dev (rotational disk? use CLOBBER=zero)" >&2
  fi
}

# Stop-then-park: clobber the disk, destroy the CT, recreate a pristine
# stopped stub (Start-able in the GUI, hook attached).
park_sandbox() {
  ct_running && pct stop "$CTID"
  clobber_disk
  destroy_sandbox
  ensure_ssh_key
  [ -n "$TEMPLATE" ] || TEMPLATE="$(template_auto)"
  ensure_hook_snippet
  create_sandbox stopped
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

# Shared post-build provisioning: base toolchain + CLI + credentials + hook.
provision_and_report() {
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
}

print_ssh_line() {
  local ip="${1:-$(sandbox_ip)}"
  if [ -n "$SSH_KEY_FILE" ]; then
    echo "  ssh -i ${SSH_KEY_FILE} root@${ip}"
  else
    echo "  ssh root@${ip}"
  fi
}

# --------------------------- subcommands ------------------------------------
cmd_up() {
  lock_or_die
  # AUTO REBUILD: never resume — tear down any prior sandbox first
  destroy_sandbox

  [ "$EUID" -eq 0 ] || die "must run as root on the Proxmox host"
  ensure_ssh_key
  [ -n "$TEMPLATE" ] || TEMPLATE="$(template_auto)"
  ensure_hook_snippet

  echo "building CT $CTID from $TEMPLATE ..."
  create_sandbox start

  local ip
  ip="$(wait_for_ip)" || { echo "container started but no IP (check ${BRIDGE}/DHCP)"; exit 1; }

  provision_and_report

  echo "sandbox ready."
  print_ssh_line "$ip"
}

cmd_down() {
  lock_or_die
  [ "$EUID" -eq 0 ] || die "must run as root on the Proxmox host"
  park_sandbox
  echo "sandbox parked: disk clobbered (CLOBBER=$CLOBBER), fresh stub at CT $CTID."
  echo "  right-click Start in the Proxmox GUI, or run 'up', for the next session."
}

cmd_purge() {
  lock_or_die
  ct_running && pct stop "$CTID"
  destroy_sandbox
  echo "CT $CTID removed entirely (no stub left in the tree)."
}

# INTERNAL: entry point for the PVE hookscript shim. PVE calls the shim with
# (vmid, phase); the shim execs this. Phases:
#   pre-start  — destroy + recreate fresh, stopped; PVE then boots the NEW CT
#   post-start — wait for IP, provision, log the ssh line
#   pre-stop   — no-op (PVE handles the stop)
#   post-stop  — clobber + park stub
cmd_hook() {
  local vmid="${1:-}" phase="${2:-}"
  [ "$vmid" = "$CTID" ] || exit 0
  case "$phase" in
    pre-start)
      lock_or_die
      echo "pre-start: rebuilding CT $CTID fresh"
      destroy_sandbox
      ensure_ssh_key
      [ -n "$TEMPLATE" ] || TEMPLATE="$(template_auto)"
      ensure_hook_snippet
      create_sandbox stopped
      ;;  # PVE now starts the newly created CT
    post-start)
      lock_or_die
      local ip
      ip="$(wait_for_ip)" || { echo "post-start: no IP (check ${BRIDGE}/DHCP)"; exit 0; }
      provision_and_report
      echo "sandbox ready via GUI."
      print_ssh_line "$ip"
      ;;
    pre-stop)
      : ;;
    post-stop)
      lock_or_die
      park_sandbox
      echo "post-stop: sandbox clobbered and parked as a fresh stub (CT $CTID)"
      ;;
    *)
      exit 0 ;;
  esac
}

cmd_status() {
  if ! ct_exists; then echo "no sandbox (CT $CTID absent)"; exit 0; fi
  if ct_running; then
    echo "CT $CTID running, ip: $(sandbox_ip)"
  else
    echo "CT $CTID exists but stopped (stub or unprovisioned)"
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
  purge)  shift; cmd_purge ;;
  reset)  shift; cmd_down; cmd_up ;;
  status) shift; cmd_status ;;
  ip)     sandbox_ip ;;
  shell)  shift; cmd_shell ;;
  hook)   shift; cmd_hook "$@" ;;
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
#   vibe-sandbox.sh up && ssh -i /root/.vibe-sandbox-ssh root@$(vibe-sandbox.sh ip) ; vibe-sandbox.sh down
