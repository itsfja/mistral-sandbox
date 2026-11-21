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
#   * MAC-RETAINED:    the sandbox's MAC address is generated once and
#                      retained on the HOST ($MAC_FILE, default
#                      /root/.vibe-sandbox.mac), then pinned (hwaddr) on
#                      every rebuild — PVE would otherwise mint a fresh
#                      random MAC each time. A DHCP reservation for that
#                      MAC therefore keeps the same IP across rebuilds.
#                      Override with CT_MAC to pin a specific MAC.
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
#   * GUARDED:          every destroy/clobber passes guard_ct(): the CT must
#                      carry this script's ownership tag (SANDBOX_TAG,
#                      default 'vibe-sandbox') AND the sandbox hostname.
#                      A same-ID collision — another system squatting on
#                      $CTID by design or by operator error — aborts loudly
#                      instead of being destroyed. The guard fails closed:
#                      in GUI hooks, a refused check aborts the task.
#
#   * WORK-GUARDED:     no teardown silently incinerates unextracted work.
#                      Before up/down/purge or a GUI Stop/Restart kills a
#                      RUNNING sandbox, it is scanned for git repos holding
#                      uncommitted changes, meaningful new files, or
#                      commits not on any remote. Findings abort the
#                      teardown (interactive default-No confirm;
#                      fail-closed when unattended, e.g. cron) unless
#                      FORCE=1. An approved teardown is first rescue-
#                      archived to backup storage (vzdump, keeping the
#                      last RESCUE_KEEP copies; RESCUE=0 skips the
#                      archive). A pass is stamped in /run so the
#                      hookscript's pre-stop, a separate PVE process
#                      without the caller's environment, lets an
#                      already-approved stop through.
#
#   * SELF-UPDATING:    the script is installed by hand, so local copies
#                      drift silently — a bug fixed on main keeps biting a
#                      stale copy (that is how #10 went unnoticed). Build
#                      paths (`up`, GUI pre-start) sha256-check against
#                      main (RAW_URL): if stale, install the current copy
#                      (backup at $0.bak, atomic mv) and re-exec ONCE, so
#                      the build runs current code. The check degrades to
#                      a warning when it cannot run. AUTO_UPDATE=off
#                      disables; `update` does it explicitly.
#
#   * CONNECTOR-HARDENED: every rebuild injects a hardened /root/.vibe/config.toml
#                      (mode 400) disabling Vibe connectors (VIBE_CONNECTORS=off),
#                      MCP servers (VIBE_MCP=off), and auto-approve/YOLO bypass
#                      (VIBE_AUTO_APPROVE=off) by default. VIBE_HARDEN=off skips
#                      config injection. Account-level Vibe Work connectors live
#                      outside the CT and must also be disabled per-chat (README).
#
#   * EGRESS-FIREWALLED: with FIREWALL=on (default), net0 is attached with
#                      firewall=1 and a host-side PVE ruleset is written to
#                      /etc/pve/firewall/<CTID>.fw (outside container root
#                      control). Default EGRESS_POLICY=lan-block allows inbound
#                      SSH + outbound DHCP/DNS/internet while dropping outbound
#                      RFC1918 LAN, link-local/metadata, CGNAT, and IPv6 ULA;
#                      EGRESS_POLICY=strict sets policy_out=DROP with explicit
#                      EGRESS_ALLOW CIDRs/IPs; EGRESS_POLICY=off disables.
#                      Enforced when Proxmox Datacenter firewall is enabled.
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
#   export    bundle the keypair + ssh-config for desktop use (after 'up')
#   update    self-update the script from main (previous copy kept as .bak)
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
MAC_FILE="${MAC_FILE:-/root/.vibe-sandbox.mac}"  # host-side MAC store (permanent)
CT_MAC="${CT_MAC:-}"                   # optional override; empty = managed MAC
SECRETS_FILE="${SECRETS_FILE:-/root/.vibe-sandbox.env}"   # host-side key store
HOOK="${HOOK:-on}"                    # on = attach PVE hookscript (GUI trap)
CLOBBER="${CLOBBER:-discard}"         # discard | zero | off — post-stop rootfs wipe
SANDBOX_TAG="${SANDBOX_TAG:-vibe-sandbox}"   # ownership tag; guard_ct() enforces it
HOOK_VOL_ID="local:snippets/vibe-sandbox-hook.sh"
HOOK_SNIPPET_DIR="${HOOK_SNIPPET_DIR:-/var/lib/vz/snippets}"
PROVISION_HOOK="$(dirname "$0")/provision.sh"
EXPORT_DIR="${EXPORT_DIR:-/root/vibe-sandbox-export}"     # desktop bundle output dir
AUTO_UPDATE="${AUTO_UPDATE:-on}"        # on = build paths self-check against main; off = never check
RAW_URL="${RAW_URL:-https://raw.githubusercontent.com/itsfja/mistral-sandbox/main/vibe-sandbox.sh}"
LOCK_FILE="/run/lock/vibe-sandbox.lock"
FORCE="${FORCE:-0}"                   # 1 = skip the work-loss guard entirely
GUARD_STAMP="/run/lock/vibe-sandbox.workguard-ok"  # fresh pass lets the hook pre-stop through
GUARD_STAMP_TTL=600                   # seconds a guard pass remains valid
RESCUE="${RESCUE:-1}"                 # 1 = before an approved guarded teardown, vzdump the CT to rescue storage
RESCUE_STORAGE="${RESCUE_STORAGE:-unraid-lvm,auto}"  # rescue backup storages in preference order; "auto" = first with backup content
RESCUE_KEEP="${RESCUE_KEEP:-2}"       # rescue archives of this CT to keep on the storage
STORAGE_CFG="${STORAGE_CFG:-/etc/pve/storage.cfg}"  # storage definitions (content/path lookup)
VIBE_HARDEN="${VIBE_HARDEN:-on}"      # on = inject hardened /root/.vibe/config.toml; off = skip
VIBE_CONNECTORS="${VIBE_CONNECTORS:-off}"       # off = disable Vibe connectors; on = allow
VIBE_MCP="${VIBE_MCP:-off}"                     # off = disable MCP servers; on = allow
VIBE_AUTO_APPROVE="${VIBE_AUTO_APPROVE:-off}"   # off = disable auto-approve/YOLO; on = allow
FIREWALL="${FIREWALL:-on}"            # on = attach PVE firewall=1 and write per-CT rules; off = skip
EGRESS_POLICY="${EGRESS_POLICY:-lan-block}"     # lan-block | strict | off
EGRESS_ALLOW="${EGRESS_ALLOW:-}"      # optional comma-separated IPs/CIDRs allowed outbound
FW_DIR="${FW_DIR:-/etc/pve/firewall}" # Proxmox firewall config dir (contains cluster.fw & <CTID>.fw)

# --------------------------- helpers ---------------------------------------
die() { echo "error: $*" >&2; exit 1; }

lock_or_die() {
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "another vibe-sandbox operation is running (serial rebuild only)"
}

# Hook phases fire from INSIDE the pct call of the operation that already
# holds the serial lock: `up` runs `pct create --start` (pre-start and
# post-start fire under up's lock), `down`/`purge` run `pct stop`
# (post-stop fires under theirs), a GUI Start/Stop runs under nobody's.
# A hook phase must therefore never DEMAND the lock (lock_or_die) — when
# `up` builds, the pre-start hook would abort the very start it is part
# of. Instead: lock free = standalone/GUI task, take it and do the
# phase's work; lock held = the holder IS the operation whose pct call
# triggered this hook and it does that work itself — pass through
# quietly with exit 0.
hook_lock() {   # $1 = phase; rc 0 = lock acquired (do the work), rc 1 = passthrough
  exec 9>"$LOCK_FILE"
  if flock -n 9; then
    return 0
  fi
  echo "vibe-sandbox: operation in progress — $1 hook passthrough" >&2
  return 1
}

# Self-update: the script is installed by hand (curl one-liner), so local
# copies drift silently — bugs fixed on main keep biting a stale host
# copy (that is literally how #10 went undetected). Design:
#   * build paths only (`up` and the GUI pre-start hook) self-check
#     against main (RAW_URL) via a sha256 comparison; status/ip/shell
#     stay instant and network-free.
#   * stale -> install the current copy (bash -n validated, previous
#     copy kept as $0.bak, atomic mv: a concurrently running instance
#     keeps executing the old inode undisturbed) and re-exec ONCE
#     (VIBE_SANDBOX_SELF_UPDATED guard), so the build that noticed the
#     drift runs current code.
#   * the check never blocks: an unreachable URL, a timeout, or a
#     fetched file that fails bash -n all degrade to a warning and the
#     current (old) script proceeds.
#   * AUTO_UPDATE=off disables the automatic check entirely; the
#     `update` subcommand performs the same install explicitly.
#   * hand-edited local copies are overwritten on build paths (the
#     edits land in the .bak); patch locally only with AUTO_UPDATE=off.

fetch_current_script() {   # $1 = dest path, $2 = curl timeout (s)
  curl -fsSL -m "${2:-15}" "$RAW_URL" > "$1" 2>/dev/null && bash -n "$1"
}

install_current_script() {   # $1 = temp file holding the new script; echoes backup path
  local self new mode
  self="$(readlink -f "$0")"
  new="$1"
  mode="$(stat -c %a "$self")"
  cp -a "$self" "${self}.bak"
  chmod "$mode" "$new"
  mv -f "$new" "$self"
  echo "${self}.bak"
}

self_check() {   # "$@" = full original argv; installs + re-execs once if stale
  [ "$AUTO_UPDATE" = "on" ] || return 0
  [ -z "${VIBE_SANDBOX_SELF_UPDATED:-}" ] || return 0
  local tmp bak
  tmp="$(mktemp 2>/dev/null)" || { echo "self-check: mktemp failed — skipping" >&2; return 0; }
  if ! fetch_current_script "$tmp" 15; then
    rm -f "$tmp"
    echo "self-check: could not fetch/validate $RAW_URL — continuing with the current script" >&2
    return 0
  fi
  if [ "$(sha256sum "$(readlink -f "$0")" | awk '{print $1}')" = "$(sha256sum "$tmp" | awk '{print $1}')" ]; then
    rm -f "$tmp"
    return 0
  fi
  bak="$(install_current_script "$tmp")"
  echo "self-update: local script was stale — installed the current copy from main"
  echo "  (previous copy: $bak); re-running on the new script"
  export VIBE_SANDBOX_SELF_UPDATED=1
  exec "$(readlink -f "$0")" "$@"
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

# Permanent, script-managed MAC, retained on the HOST across rebuilds
# (same pattern as the keypair). Without a pinned hwaddr, every recreate
# would get a fresh random MAC from PVE, which silently breaks DHCP
# reservations. Generated once on the first build; pinned on every
# recreate. With CT_MAC set, the override is used and none is generated.
ensure_mac() {
  [ -n "$CT_MAC" ] && return 0
  if [ -s "$MAC_FILE" ]; then
    CT_MAC="$(cat "$MAC_FILE")"
  else
    # locally administered unicast (02:xx:xx:xx:xx:xx), otherwise random
    CT_MAC="02:$(od -An -N5 -tx1 /dev/urandom | tr -d ' \n' | sed 's/../&:/g;s/:$//')"
    printf '%s\n' "$CT_MAC" > "$MAC_FILE"
    chmod 600 "$MAC_FILE"
    echo "generated sandbox MAC (retained on host): $CT_MAC"
  fi
  echo "$CT_MAC" | grep -Eq '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$' \
    || die "invalid MAC '$CT_MAC' in $MAC_FILE — delete the file or set CT_MAC"
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
  # download if not already present. The >&2 is load-bearing: this function
  # is consumed via TEMPLATE="$(template_auto)", and pveam download prints
  # its whole verbose progress (downloading/wget/checksum) to stdout —
  # without the redirect that log is captured into TEMPLATE and pct create
  # rejects the oversized ostemplate ("value may only be 255 characters
  # long"). stderr passes through $(...) to the terminal, so the progress
  # stays visible live.
  pveam list local 2>/dev/null | grep -q "${t##*/}" || pveam download local "$t" >&2
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

# --------------------------- work-loss guard ----------------------------------
# "Disposable" must never silently mean "destroys your unpushed commits".
# Every teardown that kills a RUNNING sandbox (up / down / purge, GUI Stop
# or Restart via the hookscript) first scans it for git repos holding work
# that exists nowhere outside the CT: modified or staged files, meaningful
# new files, or commits not on any remote. Findings abort the teardown —
# interactive default-No confirm, fail-closed when unattended — unless
# FORCE=1. A pass is stamped in /run: the hookscript's pre-stop runs as a
# separate PVE process WITHOUT the caller's environment, so a fresh stamp
# is the only way it can know an interactive guard already said yes.

sandbox_work_findings() {   # echoes findings for a running CT; empty = clean
  ct_running || return 0
  pct exec "$CTID" -- bash -c '
    command -v git >/dev/null 2>&1 || exit 0
    find /root /home -maxdepth 4 -type d -name .git 2>/dev/null |
    while IFS= read -r g; do
      repo="${g%/.git}"
      cd "$repo" 2>/dev/null || continue
      dirty="$(git status --porcelain 2>/dev/null | grep -cv "^??")"
      new="$(git status --porcelain 2>/dev/null | grep "^??" |
        grep -cvE "(\.pytest_cache|__pycache__|node_modules|\.venv|\.mypy_cache|\.ruff_cache|/dist/|/build/|\.DS_Store)")"
      unpushed="$(git rev-list --count --all --not --remotes 2>/dev/null)" ||
        unpushed=0
      [ "${dirty:-0}" -gt 0 ] || [ "${new:-0}" -gt 0 ] ||
        [ "${unpushed:-0}" -gt 0 ] || continue
      printf "  %s: %s modified, %s new, %s unpushed\n" \
        "$repo" "$dirty" "$new" "$unpushed"
    done
  ' 2>/dev/null
}

storage_cfg_value() {   # $1 = storage name, $2 = key (content|path) from $STORAGE_CFG
  awk -v s="$1" -v key="$2" '
    /^[A-Za-z0-9]+: / { sec = ($2 == s) }
    sec && $1 == key { print $2; exit }
  ' "$STORAGE_CFG" 2>/dev/null
}

rescue_storage_autodetect() {   # first non-local storage with backup content; local fallback
  # Detection happens in $STORAGE_CFG: pvesm status prints no Content
  # column, so it cannot tell which storages accept backups. Prefer the
  # first non-local storage with backup content; fall back to local
  # (archives share the host boot disk) with the caveat logged.
  local pick
  pick="$(awk '
    /^[A-Za-z0-9]+: / { name = $2 }
    name && $1 == "content" && $2 ~ /(^|,)backup(,|$)/ {
      if (name != "local" && !printed) { print name; printed = 1 }
      if (name == "local") fallback = 1
    }
    END { if (!printed && fallback) print "local" }
  ' "$STORAGE_CFG" 2>/dev/null)"
  if [ -z "$pick" ]; then
    return 1
  fi
  if [ "$pick" = "local" ]; then
    echo "rescue: only 'local' has backup content; archives share the host boot disk" >&2
  fi
  echo "$pick"
}

rescue_storage() {   # rescue backup storage: ordered preference list of IDs / "auto"
  local list="${RESCUE_STORAGE:-auto}" candidate contents pick saved_ifs
  saved_ifs="$IFS"
  IFS=','
  for candidate in $list; do
    IFS="$saved_ifs"
    candidate="$(printf '%s' "$candidate" | tr -d ' \t')"
    [ -n "$candidate" ] || continue
    if [ "$candidate" = "auto" ]; then
      pick="$(rescue_storage_autodetect)"
      if [ -n "$pick" ]; then
        echo "$pick"
        return 0
      fi
      echo "rescue: 'auto' found no storage with backup content in $STORAGE_CFG" >&2
      continue
    fi
    contents="$(storage_cfg_value "$candidate" content)"
    case ",${contents}," in
      *",backup,"*)
        echo "$candidate"
        return 0
        ;;
    esac
    echo "rescue: '$candidate' has no backup content ($STORAGE_CFG says '${contents:-nothing}'), skipping" >&2
  done
  IFS="$saved_ifs"
  echo "rescue: no usable storage in RESCUE_STORAGE='$list'; use an ordered list of storage IDs with backup content, or add 'auto'" >&2
  return 1
}

rescue_archive() {   # vzdump the CT to rescue storage before an approved teardown
  [ "$RESCUE" = "1" ] || {
    echo "rescue: RESCUE=0 - proceeding without an archive" >&2
    return 0
  }
  ct_exists || return 0
  local storage out archive path dumpdir old
  storage="$(rescue_storage)" || return 1
  echo "rescue: archiving CT $CTID to '$storage' before teardown ..."
  if ! out="$(vzdump "$CTID" --mode stop --storage "$storage" --compress zstd 2>&1)"; then
    echo "$out" >&2
    echo "rescue: vzdump failed - nothing was destroyed" >&2
    return 1
  fi
  archive="$(printf '%s\n' "$out" | sed -n "s/.*creating vzdump archive '\([^']*\)'.*/\1/p" | head -n 1)"
  echo "rescue: archive created${archive:+: $archive}"
  # retention: keep only the newest RESCUE_KEEP archives of this CT
  path="$(storage_cfg_value "$storage" path)"
  [ -n "$path" ] || return 0   # e.g. PBS storage manages its own retention
  dumpdir="$path/dump"
  ls -1t "$dumpdir"/vzdump-lxc-"$CTID"-*.tar.* 2>/dev/null |
    tail -n +"$((RESCUE_KEEP + 1))" |
    while read -r old; do
      rm -f "$old" "${old%.tar.*}.log"
      echo "rescue: pruned old archive $(basename "$old")"
    done
}

guard_stamp_ok() {   # true when the last guard pass is fresher than the TTL
  [ -f "$GUARD_STAMP" ] || return 1
  local age
  age="$(( $(date +%s) - $(stat -c %Y "$GUARD_STAMP" 2>/dev/null || echo 0) ))"
  [ "$age" -le "$GUARD_STAMP_TTL" ]
}

work_guard() {   # $1 = teardown label (up|down|purge|pre-stop); fail-closed
  local findings ans label="${1:-teardown}"
  if guard_stamp_ok; then
    touch "$GUARD_STAMP" 2>/dev/null || true
    return 0
  fi
  findings="$(sandbox_work_findings)"
  if [ -z "$findings" ]; then
    touch "$GUARD_STAMP" 2>/dev/null || true
    return 0
  fi
  echo "work guard ($label): the sandbox holds work that exists nowhere else:" >&2
  echo "$findings" >&2
  if [ "$FORCE" = "1" ]; then
    echo "work guard ($label): FORCE=1 - rescue-archiving, then proceeding" >&2
  elif [ -t 0 ] && [ -t 1 ]; then
    read -r -p "tearing it down loses it. Rescue-archive it first, then proceed? [y/N] " ans
    case "$ans" in
      y | Y | yes | Yes | YES) ;;
      *)
        echo "aborted: push or extract the work, or re-run with FORCE=1" >&2
        return 1
        ;;
    esac
  else
    echo "no terminal attached: aborting $label (push/extract, or FORCE=1)" >&2
    return 1
  fi
  # Approval given. Stamp BEFORE vzdump: its stop-mode stop triggers the
  # pre-stop hook, which must see a fresh stamp to let the backup's stop through.
  touch "$GUARD_STAMP" 2>/dev/null || true
  if ! rescue_archive; then
    rm -f "$GUARD_STAMP" 2>/dev/null || true
    die "work guard: rescue archive failed - nothing was destroyed. Fix backup storage (RESCUE_STORAGE), or RESCUE=0 to destroy without an archive"
  fi
  return 0
}

# Ownership interlock: EVERY destructive operation must pass this gate.
# The sandbox is identified by BOTH the sandbox hostname AND the ownership
# tag on the CT config. A same-ID collision — some other system squatting
# on $CTID by design or by operator error — aborts loudly instead of being
# destroyed. Pre-tagging sandboxes are recognized (and healed) only when
# they also carry this script's managed hookscript.
guard_ct() {
  ct_exists || return 0
  local cfg hostname tags
  cfg="$(pct config "$CTID")"
  hostname="$(echo "$cfg" | awk '/^hostname:/ {print $2}')"
  tags="$(echo "$cfg" | awk '/^tags:/ {print $2}')"
  if [ "$hostname" = "$CTHOST" ] && echo "$tags" | grep -qw "$SANDBOX_TAG"; then
    return 0
  fi
  # legacy sandbox from before tagging: our hostname AND our hookscript
  if [ "$hostname" = "$CTHOST" ] && echo "$cfg" | grep -q "^hookscript: ${HOOK_VOL_ID}$"; then
    echo "guard: untagged legacy sandbox found — tagging CT $CTID as '$SANDBOX_TAG'"
    pct set "$CTID" --tags "${tags:+${tags};}${SANDBOX_TAG}"
    return 0
  fi
  die "refusing to touch CT $CTID: it is not this script's sandbox (hostname '$hostname', tags '${tags:-none}'; expected hostname '$CTHOST' with tag '$SANDBOX_TAG'). If that CT is something else, move it or set CTID to a free ID; only if you are CERTAIN it is an old sandbox, tag it manually: pct set $CTID --tags $SANDBOX_TAG"
}

destroy_sandbox() {
  guard_ct   # ownership interlock: never destroy a CT that is not ours
  work_guard destroy || die "work guard: refusing to destroy CT $CTID"
  if ct_exists; then
    ct_running && pct stop "$CTID"
    pct destroy "$CTID" --purge
    echo "destroyed CT $CTID"
  fi
}

# --------------------------- connector & egress hardening --------------------
# Isolating compute/filesystem does not contain information flow if outbound
# connectors are enabled or if the CT can probe/reach internal LAN services.
# Layer 1 (in-CT guardrail): deterministic /root/.vibe/config.toml disabling
# connectors, MCP servers, and auto-approve by default.
# Layer 2 (host boundary): Proxmox per-CT firewall ruleset enforced on the
# hypervisor bridge — outside container root control.

FW_MARKER="# vibe-sandbox managed firewall"

validate_on_off() {   # $1 = var name, $2 = value
  case "$2" in
    on|off) return 0 ;;
    *) die "invalid $1='$2' (expected 'on' or 'off')" ;;
  esac
}

validate_cidr_or_ip() {   # $1 = token; strict IPv4/IPv6 or CIDR validation (blocks .fw rule injection)
  local token="$1" addr prefix o1 o2 o3 o4
  # Full-string regex (rejects newlines, whitespace, comments, and metacharacters)
  [[ "$token" =~ ^[0-9A-Fa-f.:/]+$ ]] || return 1
  if [[ "$token" == *.* ]]; then
    # IPv4 or IPv4/prefix
    if [[ "$token" == */* ]]; then
      addr="${token%%/*}"
      prefix="${token#*/}"
      [[ "$prefix" =~ ^[0-9]{1,2}$ ]] && [ "$prefix" -ge 0 ] && [ "$prefix" -le 32 ] || return 1
    else
      addr="$token"
    fi
    [[ "$addr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    o1="${BASH_REMATCH[1]}"; o2="${BASH_REMATCH[2]}"
    o3="${BASH_REMATCH[3]}"; o4="${BASH_REMATCH[4]}"
    [ "$o1" -le 255 ] && [ "$o2" -le 255 ] && [ "$o3" -le 255 ] && [ "$o4" -le 255 ] || return 1
    return 0
  elif [[ "$token" == *:* ]]; then
    # IPv6 or IPv6/prefix
    if [[ "$token" == */* ]]; then
      addr="${token%%/*}"
      prefix="${token#*/}"
      [[ "$prefix" =~ ^[0-9]{1,3}$ ]] && [ "$prefix" -ge 0 ] && [ "$prefix" -le 128 ] || return 1
    else
      addr="$token"
    fi
    # Require valid hex groups (1-4 hex digits), no :::, at most one ::, not bare ":"
    [[ "$addr" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
    [ "$addr" != ":" ] || return 1
    [[ "$addr" != *:::* ]] || return 1
    local stripped="${addr/::/}"
    [[ "$stripped" != *::* ]] || return 1
    [[ "$addr" =~ [0-9A-Fa-f] ]] || [ "$addr" = "::" ] || return 1
    [[ ! "$addr" =~ [0-9A-Fa-f]{5} ]] || return 1
    return 0
  fi
  return 1
}

validate_hardening_config() {
  validate_on_off VIBE_HARDEN "$VIBE_HARDEN"
  validate_on_off VIBE_CONNECTORS "$VIBE_CONNECTORS"
  validate_on_off VIBE_MCP "$VIBE_MCP"
  validate_on_off VIBE_AUTO_APPROVE "$VIBE_AUTO_APPROVE"
  validate_on_off FIREWALL "$FIREWALL"
  case "$EGRESS_POLICY" in
    lan-block|strict|off) ;;
    *) die "invalid EGRESS_POLICY='$EGRESS_POLICY' (expected 'lan-block', 'strict', or 'off')" ;;
  esac
  if [ -n "$EGRESS_ALLOW" ]; then
    local saved_ifs="$IFS" entry
    IFS=','
    for entry in $EGRESS_ALLOW; do
      IFS="$saved_ifs"
      entry="$(printf '%s' "$entry" | tr -d ' \t')"
      [ -n "$entry" ] || continue
      validate_cidr_or_ip "$entry" || die "invalid IP/CIDR '$entry' in EGRESS_ALLOW"
    done
    IFS="$saved_ifs"
  fi
}

bool_toml() {
  [ "$1" = "on" ] && echo "true" || echo "false"
}

firewall_active() {
  [ "$FIREWALL" = "on" ] && [ "$EGRESS_POLICY" != "off" ]
}

datacenter_firewall_enabled() {
  local cluster_fw="${FW_DIR}/cluster.fw"
  [ -f "$cluster_fw" ] || return 1
  awk '
    /^\[/ { in_opt = ($0 ~ /^\[OPTIONS\][[:space:]]*$/); next }
    in_opt && /^[[:space:]]*enable:[[:space:]]*1([[:space:]]*(#.*)?)?$/ { found = 1; exit }
    END { exit(found ? 0 : 1) }
  ' "$cluster_fw" 2>/dev/null
}

warn_datacenter_firewall() {
  firewall_active || return 0
  datacenter_firewall_enabled && return 0
  echo "warning: Proxmox Datacenter firewall is disabled (${FW_DIR}/cluster.fw) — per-CT egress rules in ${FW_DIR}/${CTID}.fw are NOT enforced yet." >&2
  echo "  to enable safely: ensure host SSH (22) & PVE UI (8006) access, then set Datacenter > Firewall > Options > Firewall: Yes." >&2
}

render_firewall_rules() {
  local policy_out="ACCEPT"
  [ "$EGRESS_POLICY" = "strict" ] && policy_out="DROP"
  cat <<EOF
${FW_MARKER} (CT ${CTID}, EGRESS_POLICY=${EGRESS_POLICY})
[OPTIONS]
enable: 1
dhcp: 1
policy_in: DROP
policy_out: ${policy_out}

[RULES]
IN ACCEPT -p tcp -dport 22 -log nolog # sandbox SSH
OUT ACCEPT -p udp -sport 68 -dport 67 -log nolog # DHCP client
OUT ACCEPT -p udp -dport 53 -log nolog # DNS (UDP)
OUT ACCEPT -p tcp -dport 53 -log nolog # DNS (TCP)
EOF
  if [ -n "$EGRESS_ALLOW" ]; then
    local saved_ifs="$IFS" entry
    IFS=','
    for entry in $EGRESS_ALLOW; do
      IFS="$saved_ifs"
      entry="$(printf '%s' "$entry" | tr -d ' \t')"
      [ -n "$entry" ] || continue
      printf 'OUT ACCEPT -dest %s -log nolog # EGRESS_ALLOW\n' "$entry"
    done
    IFS="$saved_ifs"
  fi
  if [ "$EGRESS_POLICY" = "lan-block" ]; then
    cat <<'EOF'
OUT DROP -dest 10.0.0.0/8 -log nolog # block RFC1918 LAN
OUT DROP -dest 172.16.0.0/12 -log nolog # block RFC1918 LAN
OUT DROP -dest 192.168.0.0/16 -log nolog # block RFC1918 LAN
OUT DROP -dest 169.254.0.0/16 -log nolog # block link-local / metadata
OUT DROP -dest 100.64.0.0/10 -log nolog # block CGNAT
OUT DROP -dest fc00::/7 -log nolog # block IPv6 ULA
OUT DROP -dest fe80::/10 -log nolog # block IPv6 link-local
EOF
  fi
}

configure_firewall() {
  validate_hardening_config
  local fw_file="${FW_DIR}/${CTID}.fw" tmp_file
  if ! firewall_active; then
    if [ -f "$fw_file" ] && grep -qF "$FW_MARKER" "$fw_file" 2>/dev/null; then
      rm -f "$fw_file"
      echo "firewall: disabled (removed managed ruleset $fw_file)"
    fi
    return 0
  fi
  if [ -f "$fw_file" ] && ! grep -qF "$FW_MARKER" "$fw_file" 2>/dev/null; then
    die "refusing to overwrite unmanaged firewall ruleset at $fw_file — remove it or set FIREWALL=off"
  fi
  mkdir -p "$FW_DIR"
  # Atomic same-directory rename avoids partial writes on pmxcfs (/etc/pve)
  tmp_file="${FW_DIR}/.${CTID}.fw.tmp.$$"
  if ! render_firewall_rules > "$tmp_file"; then
    rm -f "$tmp_file"
    die "failed to write firewall ruleset temp file $tmp_file"
  fi
  mv -f "$tmp_file" "$fw_file"
  echo "firewall: wrote host-enforced ruleset $fw_file (EGRESS_POLICY=$EGRESS_POLICY)"
}

remove_firewall() {
  local fw_file="${FW_DIR}/${CTID}.fw"
  if [ -f "$fw_file" ] && grep -qF "$FW_MARKER" "$fw_file" 2>/dev/null; then
    rm -f "$fw_file"
    echo "firewall: removed managed ruleset $fw_file"
  fi
}

render_vibe_config() {
  cat <<EOF
# Managed by vibe-sandbox.sh (Issue #40 connector hardening)
# Override at build time via VIBE_CONNECTORS / VIBE_MCP / VIBE_AUTO_APPROVE / VIBE_HARDEN
enable_connectors = $(bool_toml "$VIBE_CONNECTORS")
enable_mcp = $(bool_toml "$VIBE_MCP")
enable_auto_approve = $(bool_toml "$VIBE_AUTO_APPROVE")
EOF
}

inject_vibe_config() {
  if [ "$VIBE_HARDEN" != "on" ]; then
    echo "hardening: VIBE_HARDEN=off — skipping /root/.vibe/config.toml injection"
    return 0
  fi
  local cfg_tmp
  cfg_tmp="$(mktemp)"
  render_vibe_config > "$cfg_tmp"
  if ! pct exec "$CTID" -- mkdir -p /root/.vibe || ! pct push "$CTID" "$cfg_tmp" /root/.vibe/config.toml; then
    rm -f "$cfg_tmp"
    return 1
  fi
  rm -f "$cfg_tmp"
  pct exec "$CTID" -- chown root:root /root/.vibe/config.toml
  pct exec "$CTID" -- chmod 400 /root/.vibe/config.toml
  echo "hardening: injected /root/.vibe/config.toml (connectors=$VIBE_CONNECTORS, mcp=$VIBE_MCP, auto_approve=$VIBE_AUTO_APPROVE)"
}

print_hardening_summary() {
  local fw_state="off" vibe_state="off"
  if firewall_active; then
    if datacenter_firewall_enabled; then
      fw_state="${EGRESS_POLICY} (active)"
    else
      fw_state="${EGRESS_POLICY} (pending Datacenter firewall)"
    fi
  fi
  if [ "$VIBE_HARDEN" = "on" ]; then
    vibe_state="connectors=${VIBE_CONNECTORS}, mcp=${VIBE_MCP}, auto_approve=${VIBE_AUTO_APPROVE}"
  fi
  echo "hardening: firewall=${fw_state}; vibe=(${vibe_state})"
}

# Create the sandbox CT. $1 = start | stopped. The hookscript is attached
# whenever HOOK=on so the GUI trap works on every incarnation, stub included.
# The ownership tag is set here; guard_ct() enforces it before any destroy.
# The retained MAC is pinned via hwaddr so DHCP reservations survive rebuilds.
# When firewall_active, the host-side PVE ruleset is written BEFORE pct create
# and net0 carries firewall=1 so there is no unfiltered boot window.
create_sandbox() {
  local hookargs=() startargs=() net0_opts
  validate_hardening_config
  ensure_mac
  configure_firewall
  net0_opts="name=eth0,bridge=${BRIDGE},ip=dhcp${CT_MAC:+,hwaddr=$CT_MAC}"
  firewall_active && net0_opts="${net0_opts},firewall=1"
  [ "$HOOK" = "on" ] && hookargs=(--hookscript "$HOOK_VOL_ID")
  [ "${1:-start}" = "start" ] && startargs=(--start 1)
  pct create "$CTID" "$TEMPLATE" \
    --hostname "$CTHOST" \
    --cores "$CORES" --memory "$RAM_MB" --swap "$SWAP_MB" \
    --rootfs "${STORAGE}:${DISK_GB}" \
    --net0 "$net0_opts" \
    --unprivileged 1 \
    --features nesting=1 \
    --ssh-public-keys "$SSH_PUBKEY" \
    --tags "$SANDBOX_TAG" \
    --onboot 0 \
    "${hookargs[@]}" \
    "${startargs[@]}"
}

# Wipe the rootfs of the STOPPED CT (keep the disk object, destroy the data).
clobber_disk() {
  [ "$CLOBBER" = "off" ] && return 0
  guard_ct   # ownership interlock: never wipe a CT that is not ours
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
# headless-clean locale for apt/perl: the host's LANG leaks into the CT
# through pct exec (lxc-attach passes the calling environment) and is
# usually not compiled into the fresh CT, so apt/perl would spam
# warnings; use C here
export LC_ALL=C
# uv installs the CLI into /root/.local/bin, which is NOT on the PATH
# of the pct-exec context — the installer treats that as fatal, and
# `vibe --version` below would fail the same way — so put it up front
export PATH="/root/.local/bin:$PATH"

# general-purpose baseline: the agent extends this at runtime as needed
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  ca-certificates curl wget git build-essential \
  python3 python3-pip python3-venv \
  unzip zip jq ripgrep man-db sudo locales || true

# generate the locale that leaked in from the host (now that the
# `locales` package is installed): subsequent pct exec calls stop
# warning and the CT matches the host, whatever LANG says
[ -n "${LANG:-}" ] && locale-gen "$LANG" >/dev/null 2>&1 || true

# current iteration of Mistral tooling, fetched at build time
curl -LsSf https://mistral.ai/vibe/install.sh | bash

# make the CLI reachable from non-login shells
ln -sf /root/.local/bin/vibe     /usr/local/bin/vibe     2>/dev/null || true
ln -sf /root/.local/bin/vibe-acp /usr/local/bin/vibe-acp 2>/dev/null || true

# root access is by the injected keypair ONLY: the template ships root's
# password locked and the script never sets one; pin key-only root login
# explicitly (the Debian default, made unconditional here) so a template
# change can never quietly enable password auth. Needs the template's
# Include of sshd_config.d (Debian ships it).
mkdir -p /etc/ssh/sshd_config.d
printf 'PermitRootLogin prohibit-password\n' > /etc/ssh/sshd_config.d/10-vibe-root-key-only.conf
sshd -t && systemctl reload ssh >/dev/null 2>&1 || true

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

  # hardened Vibe CLI config (default-deny connectors, MCP, auto-approve)
  inject_vibe_config

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

# Every rebuild mints a fresh SSH host key, so a stale known_hosts
# entry for the sandbox IP on the HOST makes the ssh line above die
# with REMOTE HOST IDENTIFICATION HAS CHANGED on the second rebuild.
# Purge the stale entry at generation time; strict host-key checking
# stays fully on for every other host.
purge_known_hosts() {   # $1 = sandbox IP
  [ -n "${1:-}" ] || return 0
  ssh-keygen -R "$1" >/dev/null 2>&1 || true
}

# --------------------------- subcommands ------------------------------------
cmd_up() {
  self_check up
  lock_or_die
  validate_hardening_config
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

  # fresh host key per rebuild: drop the stale host-side entry now
  purge_known_hosts "$ip"

  provision_and_report
  print_hardening_summary
  warn_datacenter_firewall

  echo "sandbox ready."
  print_ssh_line "$ip"
}

cmd_down() {
  lock_or_die
  [ "$EUID" -eq 0 ] || die "must run as root on the Proxmox host"
  validate_hardening_config
  work_guard down || die "work guard: refusing to park CT $CTID"
  park_sandbox
  echo "sandbox parked: disk clobbered (CLOBBER=$CLOBBER), fresh stub at CT $CTID."
  echo "  right-click Start in the Proxmox GUI, or run 'up', for the next session."
}

cmd_purge() {
  lock_or_die
  work_guard purge || die "work guard: refusing to purge CT $CTID"
  ct_running && pct stop "$CTID"
  destroy_sandbox
  remove_firewall
  echo "CT $CTID removed entirely (no stub left in the tree)."
}

# Desktop bundle: copy the managed keypair + an ssh-config snippet +
# per-OS instructions, so the sandbox can be used from a desktop (Windows
# or Linux) instead of the PVE console. The keypair is permanent, so one
# export unlocks every future rebuild; only the embedded IP may go stale
# per rebuild — unless a DHCP reservation pins it (the MAC is retained
# across rebuilds, so one reservation holds forever).
# Honest cost: the private key then also exists in $EXPORT_DIR and on the
# desktop — delete the export dir after fetching the tarball.
cmd_export() {
  lock_or_die
  [ "$EUID" -eq 0 ] || die "must run as root on the Proxmox host"
  ct_running || die "sandbox not running; run 'up' first (export embeds the current IP)"
  [ -n "$SSH_KEY_FILE" ] || die "export needs the managed keypair; SSH_PUBKEY-override keys live outside this script"
  local ip mac hostip
  ip="$(sandbox_ip)"
  [ -n "$ip" ] || die "no IP for the sandbox (check ${BRIDGE}/DHCP)"
  mac="$(pct config "$CTID" | awk -F'[,=]' '/^net0:/ {for (i=1;i<=NF;i++) if ($i=="hwaddr") print $(i+1)}')"
  hostip="${HOST_IP:-$(hostname -I | awk '{print $1}')}"

  mkdir -p "$EXPORT_DIR"
  chmod 700 "$EXPORT_DIR"
  cp "$SSH_KEY_FILE" "$EXPORT_DIR/vibe-sandbox"
  cp "${SSH_KEY_FILE}.pub" "$EXPORT_DIR/vibe-sandbox.pub"
  chmod 600 "$EXPORT_DIR/vibe-sandbox"
  chmod 644 "$EXPORT_DIR/vibe-sandbox.pub"

  cat > "$EXPORT_DIR/ssh-config" <<EOF
# vibe-sandbox — append to ~/.ssh/config (Linux/macOS)
# or %USERPROFILE%\.ssh\config (Windows). HostName goes stale after each
# rebuild UNLESS you set a DHCP reservation for the sandbox MAC (see
# README.txt) — the MAC is permanent, so the reservation holds forever.
Host vibe-sandbox
    HostName $ip
    User root
    IdentityFile ~/.ssh/vibe-sandbox
    # disposable sandbox: every rebuild mints a FRESH host key, so
    # strict known-hosts checking would block the 2nd+ rebuild connect.
    # Scoped to this Host alias only — never copy it to other hosts.
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF

  cat > "$EXPORT_DIR/README.txt" <<EOF
vibe-sandbox desktop bundle (exported $(date '+%Y-%m-%d %H:%M'), CT $CTID)
======================================================================

Use the sandbox from your desktop instead of the Proxmox console.

Contents:
  vibe-sandbox        private key (copy of the host-managed sandbox keypair)
  vibe-sandbox.pub    public key
  ssh-config          ssh config snippet -> 'ssh vibe-sandbox'
  README.txt          this file

The keypair is permanent: one export unlocks every future rebuild.

FIX THE IP (recommended)
------------------------
  The sandbox MAC is also permanent — retained on the host across
  rebuilds — so reserve the IP for it on your DHCP server (router,
  pfSense/OPNsense, Pi-hole, whatever hands out addresses):
    ${mac:-unknown}
  With that reservation, the IP below never goes stale and 'ssh
  vibe-sandbox' just works after every rebuild. Without it, only the
  HostName (IP) goes stale per rebuild — re-run 'export' on the host and
  re-fetch, or edit the HostName line in your ssh config.

Current sandbox IP: $ip

Linux / macOS
-------------
  mkdir -p ~/.ssh && chmod 700 ~/.ssh
  cp vibe-sandbox vibe-sandbox.pub ~/.ssh/
  cat ssh-config >> ~/.ssh/config
  ssh vibe-sandbox

Windows 10+ (built-in OpenSSH; PowerShell or CMD)
-------------------------------------------------
  if not exist "%USERPROFILE%\.ssh" mkdir "%USERPROFILE%\.ssh"
  copy vibe-sandbox "%USERPROFILE%\.ssh\vibe-sandbox"
  copy vibe-sandbox.pub "%USERPROFILE%\.ssh\vibe-sandbox.pub"
  type ssh-config >> "%USERPROFILE%\.ssh\config"
  ssh vibe-sandbox

  (no 'ssh' command? Settings > Apps > Optional features > OpenSSH Client,
  then reopen the terminal)

REBUILDS AND HOST KEYS
----------------------
  Every rebuild mints a fresh SSH host key for the sandbox. The bundled
  ssh-config pins StrictHostKeyChecking no + UserKnownHostsFile /dev/null
  for this one Host, so 'ssh vibe-sandbox' just works after every rebuild.
  (Windows OpenSSH maps /dev/null to NUL; if your ssh rejects the line,
  write NUL there instead.) With a hand-rolled config, expect REMOTE HOST
  IDENTIFICATION HAS CHANGED after each rebuild — expected rotation,
  not an attack; recover and reconnect:
    ssh-keygen -R $ip

PuTTY instead of OpenSSH
------------------------
  puttygen "%USERPROFILE%\.ssh\vibe-sandbox" -o vibe-sandbox.ppk
  Host Name: $ip   Port: 22   User: root
  (load vibe-sandbox.ppk under Connection > SSH > Auth > Credentials)
  (each rebuild mints a fresh host key — accept it when PuTTY asks)

Security
--------
  The private key now also lives on this desktop. It is a dedicated
  sandbox keypair — it unlocks the sandbox (every future rebuild too),
  not the Proxmox host. After fetching the tarball, delete the host-side
  copy so the key lives only on host and desktop:
    rm -rf $EXPORT_DIR
EOF

  tar -czf "$EXPORT_DIR/vibe-sandbox-desktop.tar.gz" \
      -C "$EXPORT_DIR" vibe-sandbox vibe-sandbox.pub ssh-config README.txt
  chmod 600 "$EXPORT_DIR/vibe-sandbox-desktop.tar.gz"

  echo "desktop bundle written to $EXPORT_DIR"
  echo "  fetch from your desktop (host SSH must be reachable from your LAN):"
  echo "    scp root@${hostip}:$EXPORT_DIR/vibe-sandbox-desktop.tar.gz ."
  if [ "$(hostname -I | wc -w)" -gt 1 ]; then
    echo "  note: this host is multi-homed ($(hostname -I | awk '{$1=$1};1')) —"
    echo "  if $hostip is not reachable from your desktop, rerun with:"
    echo "    HOST_IP=<reachable-address> $0 export"
  fi
  echo "  then follow the README.txt inside; connect with: ssh vibe-sandbox"
  echo "recommended: set a DHCP reservation for the sandbox MAC ${mac:-unknown} —"
  echo "  it is retained across rebuilds, so the IP stays stable forever"
  echo "note: without a reservation, re-run 'export' after each rebuild — only the IP changes; the key is permanent"
  echo "note: rebuilds mint a fresh host key; the bundled ssh-config pins"
  echo "  StrictHostKeyChecking no for the sandbox Host, so desktop connects survive rebuilds"
}

# INTERNAL: entry point for the PVE hookscript shim. PVE calls the shim with
# (vmid, phase); the shim execs this. Phases:
#   pre-start  — destroy + recreate fresh, stopped; PVE then boots the NEW CT
#   post-start — wait for IP, provision, log the ssh line
#   pre-stop   — work guard: refuse stops that would lose unextracted work
#   post-stop  — clobber + park stub
# All destructive phases go through guard_ct(): if the CT at $CTID is not
# provably ours, the hook ABORTS the GUI task instead of touching it.
# Hook phases lock with hook_lock(), never lock_or_die: a phase can fire
# from inside `up`'s or `down`'s own pct call, which already holds the
# serial lock. Lock free -> standalone/GUI task, this hook does the
# phase's work; lock held -> the holder is the triggering operation and
# does the work itself, this hook passes through with exit 0.
cmd_hook() {
  local vmid="${1:-}" phase="${2:-}"
  [ "$vmid" = "$CTID" ] || exit 0
  case "$phase" in
    pre-start)
      self_check hook "$vmid" "$phase"
      hook_lock "$phase" || exit 0
      validate_hardening_config
      echo "pre-start: rebuilding CT $CTID fresh"
      destroy_sandbox
      ensure_ssh_key
      [ -n "$TEMPLATE" ] || TEMPLATE="$(template_auto)"
      ensure_hook_snippet
      create_sandbox stopped
      ;;  # PVE now starts the newly created CT
    post-start)
      hook_lock "$phase" || exit 0
      local ip
      ip="$(wait_for_ip)" || { echo "post-start: no IP (check ${BRIDGE}/DHCP)"; exit 0; }
      purge_known_hosts "$ip"
      provision_and_report
      print_hardening_summary
      warn_datacenter_firewall
      echo "sandbox ready via GUI."
      print_ssh_line "$ip"
      ;;
    pre-stop)
      # Last moment the sandbox is alive: GUI Stop/Restart cannot
      # prompt, so findings abort the stop (PVE aborts the action when a
      # hookscript exits non-zero) unless a CLI guard pass was stamped
      # moments ago. Read-only; never blocks a clean sandbox.
      work_guard pre-stop || die "work guard: refusing to stop CT $CTID with unextracted work"
      ;;
    post-stop)
      hook_lock "$phase" || exit 0
      park_sandbox
      echo "post-stop: sandbox clobbered and parked as a fresh stub (CT $CTID)"
      ;;
    *)
      exit 0 ;;
  esac
}

cmd_status() {
  local fw_file="${FW_DIR}/${CTID}.fw" fw_info="none"
  if [ -f "$fw_file" ]; then
    local pol
    pol="$(sed -n 's/.*EGRESS_POLICY=\([^)]*\)).*/\1/p' "$fw_file" | head -n 1)"
    if datacenter_firewall_enabled; then
      fw_info="${pol:-custom} (enforced)"
    else
      fw_info="${pol:-custom} (Datacenter firewall OFF)"
    fi
  fi
  if ! ct_exists; then echo "no sandbox (CT $CTID absent)"; exit 0; fi
  if ct_running; then
    echo "CT $CTID running, ip: $(sandbox_ip), firewall: ${fw_info}"
  else
    echo "CT $CTID exists but stopped (stub or unprovisioned), firewall: ${fw_info}"
  fi
}

cmd_shell() {
  ct_running || die "sandbox not running; run 'up' first"
  pct enter "$CTID"
}

# Manual self-update: install main's copy explicitly. Works regardless of
# AUTO_UPDATE; never re-execs. cmp against the current file first so a
# no-op is quiet.
cmd_update() {
  [ "$EUID" -eq 0 ] || die "must run as root on the Proxmox host"
  local self tmp bak
  self="$(readlink -f "$0")"
  tmp="$(mktemp)" || die "mktemp failed"
  fetch_current_script "$tmp" 60 || die "could not fetch/validate $RAW_URL"
  if cmp -s "$self" "$tmp"; then
    rm -f "$tmp"
    echo "script already current: $self"
    return 0
  fi
  bak="$(install_current_script "$tmp")"
  echo "updated $self from main (previous copy: $bak)"
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
  export) shift; cmd_export ;;
  update)  shift; cmd_update ;;
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
