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
#                        right-click Stop    = disk clobber + parked stub
#                                              (about a minute after the
#                                              Stop task ends)
#                        right-click Start   = boot the parked, never-
#                                              booted stub + provisioning
#                      Proxmox holds the CT's lock for the whole Start and
#                      Stop tasks, hooks included, so no hook can destroy
#                      or create the CT: post-stop hands the rebuild to a
#                      transient systemd unit that runs once the Stop task
#                      has released the CT, and pre-start only boots a
#                      pristine stub ($STUB_MARKER), else refuses (run
#                      `up`). Restart therefore refuses its Start half:
#                      use Stop, then Start once the park has finished.
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
#                      disables; `update` does it explicitly. A copy
#                      inside a git checkout is never self-updated (that
#                      would conflict with `git pull`).
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
#                      RFC1918 LAN, link-local/metadata, CGNAT, and IPv6 ULA,
#                      plus EGRESS_DENY (set it to your site's public IPv6
#                      prefix: with native IPv6 the LAN is not only private);
#                      EGRESS_POLICY=strict sets policy_out=DROP with explicit
#                      EGRESS_ALLOW CIDRs/IPs; EGRESS_POLICY=off disables.
#                      Enforced when Proxmox Datacenter firewall is enabled.
#
# Settings: every variable in the configuration block below can be set on
# the command line for one run, or in /root/.vibe-sandbox.conf (CONFIG_FILE;
# plain KEY=value lines, root-owned, never executed) for EVERY run. Use the
# file for anything that must also hold for GUI Start/Stop: the PVE
# hookscript runs without your shell's environment.
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
#   ssh       ssh into the CT with the managed key: ssh [command...]
#   ip        print the current IP (empty if not running)
#   version   print the script's release version
#   export    bundle the keypair + ssh-config for desktop use (after 'up')
#   update    self-update the script from main (previous copy kept as .bak;
#             refuses inside a git checkout: use git pull there)
#   hook      INTERNAL — called by the PVE hookscript shim with (vmid, phase)
#   park-deferred INTERNAL — run by systemd after a GUI Stop (see schedule_park)
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

# Release version. Bumped only in a release PR, together with CHANGELOG.md;
# the release workflow refuses a tag that does not match it.
VIBE_SANDBOX_VERSION="1.0.0"

# --------------------------- host config file --------------------------------
# Settings that must hold for EVERY run go in $CONFIG_FILE (default
# /root/.vibe-sandbox.conf): plain KEY=value lines, read but NEVER executed.
# Exported variables only reach the CLI run they were set for; PVE runs the
# GUI hookscript with an almost empty environment, so a GUI Stop or Start
# would rebuild the stub and its firewall ruleset without them (e.g. a
# missing EGRESS_DENY silently drops the site-range rule). The file is read
# on every run, CLI and hook alike. Precedence: command-line env > file >
# built-in default. Must be owned by root and not group/other-writable.
CONFIG_FILE="${CONFIG_FILE:-/root/.vibe-sandbox.conf}"

load_config_file() {   # $1 = path
  local file="$1" line key val
  [ -f "$file" ] || return 0
  [ "$(stat -c %u "$file")" = "0" ] || { echo "error: refusing $file: not owned by root" >&2; exit 1; }
  case "$(stat -c %a "$file")" in
    *[2367]?|*?[2367]) echo "error: refusing $file: group/other-writable" >&2; exit 1 ;;
  esac
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|'#'*) continue ;; esac
    [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Z][A-Z0-9_]*)=(.*)$ ]] \
      || { echo "error: bad line in $file: $line" >&2; exit 1; }
    key="${BASH_REMATCH[2]}"
    val="${BASH_REMATCH[3]}"
    case "$key" in
      CONFIG_FILE|PATH|HOME) echo "error: $key cannot be set in $file" >&2; exit 1 ;;
    esac
    # strip one pair of matching surrounding quotes; no expansion, ever
    if [[ "$val" =~ ^\"(.*)\"$ ]] || [[ "$val" =~ ^\'(.*)\'$ ]]; then
      val="${BASH_REMATCH[1]}"
    fi
    # plain assignment, NOT export: config values stay on the host
    [ -n "${!key+x}" ] || printf -v "$key" '%s' "$val"
  done < "$file"
}
load_config_file "$CONFIG_FILE"

# --------------------------- configuration ---------------------------------
CTID="${CTID:-1042}"               # fixed ID = only one sandbox ever exists
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
STUB_MARKER="${STUB_MARKER:-/root/.vibe-sandbox.pristine-stub}"  # "the stopped CT has never booted"
PARK_UNIT="vibe-sandbox-park-${CTID}"  # transient systemd unit that parks after a GUI Stop
CT_MAC="${CT_MAC:-}"                   # optional override; empty = managed MAC
SECRETS_FILE="${SECRETS_FILE:-/root/.vibe-sandbox.env}"   # host-side key store
HOOK="${HOOK:-on}"                    # on = attach PVE hookscript (GUI trap)
CLOBBER="${CLOBBER:-discard}"         # discard | zero | off - post-stop rootfs wipe
SANDBOX_TAG="${SANDBOX_TAG:-vibe-sandbox}"   # ownership tag; guard_ct() enforces it
HOOK_VOL_ID="local:snippets/vibe-sandbox-hook.sh"
HOOK_SNIPPET_DIR="${HOOK_SNIPPET_DIR:-/var/lib/vz/snippets}"
# beside the REAL script (symlinks resolved), so CLI runs through a symlink
# such as /root/vibe-sandbox.sh and the GUI hook shim (which execs the
# resolved path) find the same file
PROVISION_HOOK="${PROVISION_HOOK:-$(dirname "$(readlink -f "$0")")/provision.sh}"
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
EGRESS_DENY="${EGRESS_DENY:-}"        # extra CIDRs lan-block drops: your site's PUBLIC IPv6 range(s)
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
  echo "vibe-sandbox: operation in progress - $1 hook passthrough" >&2
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

# A copy inside a git checkout is updated with `git pull`: self-update
# would rewrite a tracked file and leave a .bak beside it, so a later pull
# conflicts. Detected by a .git entry in the script's directory or above
# (no dependency on git being installed on the host).
script_git_checkout() {   # echoes the checkout root, rc 0 when inside one
  local d
  d="$(dirname "$(readlink -f "$0")")"
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    [ -e "$d/.git" ] && { echo "$d"; return 0; }
    d="$(dirname "$d")"
  done
  return 1
}

self_check() {   # "$@" = full original argv; installs + re-execs once if stale
  [ "$AUTO_UPDATE" = "on" ] || return 0
  [ -z "${VIBE_SANDBOX_SELF_UPDATED:-}" ] || return 0
  local repo
  if repo="$(script_git_checkout)"; then
    echo "self-check: skipped - running from the git checkout at $repo (update it with git pull)"
    return 0
  fi
  local tmp bak
  tmp="$(mktemp 2>/dev/null)" || { echo "self-check: mktemp failed - skipping" >&2; return 0; }
  if ! fetch_current_script "$tmp" 15; then
    rm -f "$tmp"
    echo "self-check: could not fetch/validate $RAW_URL - continuing with the current script" >&2
    return 0
  fi
  if [ "$(sha256sum "$(readlink -f "$0")" | awk '{print $1}')" = "$(sha256sum "$tmp" | awk '{print $1}')" ]; then
    rm -f "$tmp"
    return 0
  fi
  bak="$(install_current_script "$tmp")"
  echo "self-update: local script was stale - installed the current copy from main"
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
    || die "invalid MAC '$CT_MAC' in $MAC_FILE - delete the file or set CT_MAC"
}

# Auto-deploy the PVE hookscript shim (idempotent). The shim only forwards
# (vmid, phase) to this script's internal `hook` subcommand.
ensure_hook_snippet() {
  [ "$HOOK" = "on" ] || return 0
  local self
  self="$(readlink -f "$0")"
  mkdir -p "$HOOK_SNIPPET_DIR"
  printf '#!/usr/bin/env bash\n# vibe-sandbox PVE hookscript shim - auto-generated, safe to overwrite\nvmid="$1"; phase="$2"\nexec %q hook "$vmid" "$phase"\n' \
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

# Run a command inside the CT with a fixed, clean root environment.
# `pct exec` (lxc-attach) passes the CALLER's environment into the CT:
# from a shell that is your HOME/LANG/exported overrides, from a PVE
# hookscript it is almost nothing (no HOME - the Vibe installer dies on
# that under set -u). Either way builds would differ by how they were
# started; env -i makes CLI `up` and GUI Start provision identically.
CT_ENV=(env -i HOME=/root USER=root LOGNAME=root SHELL=/bin/bash TERM=dumb
  LANG=C.UTF-8 PATH=/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin)
ct_run() { pct exec "$CTID" -- "${CT_ENV[@]}" "$@"; }

# Copy a host file into the CT as root:root with the given mode, creating
# the destination directory. Streams the file through `pct exec` (stdin)
# rather than `pct push`: push takes the CT's config lock, which Proxmox
# holds for the whole Start task - post-start hook included - so a push
# from GUI-Start provisioning times out. exec goes straight to lxc-attach.
# The file is created under umask 077 and only then given its final mode,
# so a secret is never briefly world-readable.
ct_push_file() {   # $1 = host src, $2 = CT dest path, $3 = octal mode
  ct_run sh -c 'umask 077 && mkdir -p "$(dirname "$1")" && cat > "$1" && chown root:root "$1" && chmod "$2" "$1"' \
    sh "$2" "$3" < "$1"
}

ct_exists()  { pct status "$CTID" >/dev/null 2>&1; }
ct_running() { [ "$(pct status "$CTID" 2>/dev/null | awk '{print $2}')" = "running" ]; }

sandbox_ip() {
  pct exec "$CTID" -- sh -c 'hostname -I 2>/dev/null | cut -d" " -f1' 2>/dev/null || true
}

wait_for_ip() {
  local ip="" _
  for _ in $(seq 1 45); do
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
  ct_run bash -c '
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
    echo "guard: untagged legacy sandbox found - tagging CT $CTID as '$SANDBOX_TAG'"
    pct set "$CTID" --tags "${tags:+${tags};}${SANDBOX_TAG}"
    return 0
  fi
  die "refusing to touch CT $CTID: it is not this script's sandbox (hostname '$hostname', tags '${tags:-none}'; expected hostname '$CTHOST' with tag '$SANDBOX_TAG'). If that CT is something else, move it or set CTID to a free ID; only if you are CERTAIN it is an old sandbox, tag it manually: pct set $CTID --tags $SANDBOX_TAG"
}

destroy_sandbox() {
  guard_ct   # ownership interlock: never destroy a CT that is not ours
  work_guard destroy || die "work guard: refusing to destroy CT $CTID"
  clear_stub_marker   # whatever comes next is not the parked stub
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
  local var entry
  for var in EGRESS_ALLOW EGRESS_DENY; do
    while IFS= read -r entry; do
      validate_cidr_or_ip "$entry" || die "invalid IP/CIDR '$entry' in $var"
    done < <(csv_entries "${!var}")
  done
}

csv_entries() {   # $1 = comma-separated list; prints one trimmed entry per line
  local saved_ifs="$IFS" entry
  IFS=','
  for entry in $1; do
    IFS="$saved_ifs"
    entry="$(printf '%s' "$entry" | tr -d ' \t')"
    [ -n "$entry" ] && printf '%s\n' "$entry"
  done
  IFS="$saved_ifs"
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

# lan-block's built-in ranges are all private; a sandbox holding a PUBLIC
# IPv6 address can reach your LAN devices' public IPv6 addresses unless
# EGRESS_DENY lists your site's range. Warn when that gap is open.
warn_public_ipv6() {
  [ "$FIREWALL" = "on" ] && [ "$EGRESS_POLICY" = "lan-block" ] || return 0
  [ -z "$EGRESS_DENY" ] || return 0
  local addrs first suggest=""
  addrs="$(ct_run ip -6 -o addr show scope global 2>/dev/null | awk '{print $4}' | sort -u)"
  [ -n "$addrs" ] || return 0
  first="$(head -n1 <<<"$addrs")"
  [[ "$first" =~ ^([0-9a-fA-F]{1,4}:[0-9a-fA-F]{1,4}:[0-9a-fA-F]{1,4}): ]] && suggest="${BASH_REMATCH[1]}::/48"
  echo "warning: the sandbox has public IPv6 address(es):"
  sed 's/^/    /' <<<"$addrs"
  echo "  lan-block only drops private ranges, so your LAN devices' public IPv6 addresses are reachable."
  echo "  add your site's delegated prefix to $CONFIG_FILE, then run '$0 up':"
  echo "    EGRESS_DENY=${suggest:-<your ISP-delegated IPv6 prefix>}"
}

warn_datacenter_firewall() {
  firewall_active || return 0
  datacenter_firewall_enabled && return 0
  echo "warning: Proxmox Datacenter firewall is disabled (${FW_DIR}/cluster.fw) - per-CT egress rules in ${FW_DIR}/${CTID}.fw are NOT enforced yet." >&2
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
  local entry
  while IFS= read -r entry; do
    printf 'OUT ACCEPT -dest %s -log nolog # EGRESS_ALLOW\n' "$entry"
  done < <(csv_entries "$EGRESS_ALLOW")
  if [ "$EGRESS_POLICY" = "lan-block" ]; then
    # Your LAN is not only RFC1918: with native IPv6, every device also has
    # a PUBLIC address in the ISP-delegated prefix, which no private-range
    # rule matches. EGRESS_DENY carries that range (e.g. your /48). It
    # comes after EGRESS_ALLOW, so a single allowed host inside it still
    # gets through.
    while IFS= read -r entry; do
      printf 'OUT DROP -dest %s -log nolog # EGRESS_DENY (site range)\n' "$entry"
    done < <(csv_entries "$EGRESS_DENY")
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
    die "refusing to overwrite unmanaged firewall ruleset at $fw_file - remove it or set FIREWALL=off"
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
    echo "hardening: VIBE_HARDEN=off - skipping /root/.vibe/config.toml injection"
    return 0
  fi
  local cfg_tmp
  cfg_tmp="$(mktemp)"
  render_vibe_config > "$cfg_tmp"
  if ! ct_push_file "$cfg_tmp" /root/.vibe/config.toml 400; then
    rm -f "$cfg_tmp"
    die "hardening: failed to inject /root/.vibe/config.toml"
  fi
  rm -f "$cfg_tmp"
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
    *) echo "clobber: $volid is not /dev-backed ($dev) - skipping wipe" >&2; return 0 ;;
  esac
  if [ "$CLOBBER" = "zero" ]; then
    echo "clobber: zero-filling $dev ..."
    dd if=/dev/zero of="$dev" bs=1M status=none || true
  else
    # -f is required: util-linux >= 2.36 refuses a device that still holds
    # a filesystem signature (the rootfs always does) whenever stdin is a
    # terminal, so an interactive `down` would silently skip the wipe.
    local err
    err="$(blkdiscard -f "$dev" 2>&1)" \
      || echo "clobber: blkdiscard failed on $dev: ${err:-unknown error} - set CLOBBER=zero to overwrite instead" >&2
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
  mark_stub_pristine
}

# GUI Stop cannot park in its own post-stop hook either: Proxmox keeps the
# CT's config lock for the whole Stop task, and the task does not end until
# the post-stop hook has returned (and `pct status` still says "running"
# meanwhile). Any pct stop/destroy/create from the hook times out on that
# lock. So post-stop only hands the park to a transient systemd unit
# ($PARK_UNIT) and returns; the unit waits until PVE has finished the Stop
# (pve-container@<CTID> inactive, lock released), takes the serial lock,
# re-checks, then parks. systemd-run, not `cmd &`: a background child of
# the hook would sit in the container's cgroup and be killed with it.
park_job_active() { systemctl is-active --quiet "$PARK_UNIT" 2>/dev/null; }

schedule_park() {
  if park_job_active; then
    echo "post-stop: a park job ($PARK_UNIT) is already running"
    return 0
  fi
  systemd-run --unit "$PARK_UNIT" --collect --no-block --quiet \
    --description "vibe-sandbox: park CT $CTID after GUI Stop" \
    "$(readlink -f "$0")" park-deferred \
    || die "post-stop: could not schedule the park job (systemd-run). On the host, run: $0 down"
}

# INTERNAL: body of $PARK_UNIT (run by systemd, outside any PVE task).
cmd_park_deferred() {
  exec 9>"$LOCK_FILE"
  flock -w 600 9 || die "park: timed out waiting for the serial lock"
  local waited=0
  while systemctl is-active --quiet "pve-container@${CTID}" 2>/dev/null; do
    [ "$waited" -lt 180 ] || die "park: CT $CTID still not fully stopped after 3 minutes. On the host, run: $0 down"
    sleep 2; waited=$((waited + 2))
  done
  ct_exists || { echo "park: CT $CTID is gone - nothing to park"; return 0; }
  ct_running && { echo "park: CT $CTID was started again meanwhile - not parking it"; return 0; }
  stub_is_pristine && { echo "park: CT $CTID is already a fresh stub"; return 0; }
  validate_hardening_config
  park_sandbox
  echo "park: CT $CTID clobbered and parked as a fresh stub - ready for GUI Start"
}

# Pristine-stub marker. GUI Start cannot rebuild the CT: Proxmox holds the
# CT's config lock (/run/lock/lxc/pve-config-<CTID>.lock) for the whole
# Start task, pre-start hook included, so any pct destroy/create from the
# hook waits on its own task and times out. Instead, every park (down, GUI
# Stop) leaves a freshly created, never-booted stub and records that here;
# pre-start only lets a stub carrying this mark boot. The mark lives on
# the host (survives a host reboot) and is cleared by any destroy and by
# pre-start itself, so a disk that has ever booted never counts as fresh.
mark_stub_pristine() {
  mkdir -p "$(dirname "$STUB_MARKER")"
  printf '%s\n' "$CTID" > "$STUB_MARKER"
}

clear_stub_marker() { rm -f "$STUB_MARKER"; }

stub_is_pristine() {
  [ -f "$STUB_MARKER" ] && [ "$(cat "$STUB_MARKER" 2>/dev/null)" = "$CTID" ] \
    && ct_exists && ! ct_running
}

# The stub's net0 firewall flag was fixed when it was parked; if FIREWALL or
# EGRESS_POLICY changed since, the CT config would need editing, which
# pre-start cannot do under Proxmox's lock.
stub_firewall_consistent() {
  local net0
  net0="$(pct config "$CTID" 2>/dev/null | awk '/^net0:/ {print $2}')"
  if firewall_active; then
    [[ ",${net0}," == *",firewall=1,"* ]]
  else
    [[ ",${net0}," != *",firewall=1,"* ]]
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
# runs under ct_run's clean environment (HOME=/root, LANG=C.UTF-8, PATH
# with /root/.local/bin first, where uv installs the Vibe CLI); the C
# locale keeps apt/perl quiet in a fresh CT
export LC_ALL=C
export PATH="/root/.local/bin:$PATH"

# general-purpose baseline: the agent extends this at runtime as needed.
# Dpkg::Use-Pty=0: no "(Reading database ... 5%" redraws, which the PVE
# task log would show as one line each
apt-get update -qq
apt-get install -y -qq --no-install-recommends -o Dpkg::Use-Pty=0 \
  ca-certificates curl wget git build-essential \
  python3 python3-pip python3-venv \
  unzip zip jq ripgrep man-db sudo locales || true

# current iteration of Mistral tooling, fetched at build time
curl -LsSf https://mistral.ai/vibe/install.sh | bash

# make the CLI reachable from non-login shells
ln -sf /root/.local/bin/vibe     /usr/local/bin/vibe     2>/dev/null || true
ln -sf /root/.local/bin/vibe-acp /usr/local/bin/vibe-acp 2>/dev/null || true

# access is by the injected keypair ONLY: the template ships root's
# password locked and the script never sets one. Pin key-only login
# explicitly so a template change can never quietly enable password auth,
# and stop offering password / keyboard-interactive at all: otherwise an
# ssh without the sandbox key sits at a password prompt that can never
# succeed, instead of failing at once with "Permission denied (publickey)".
# The drop-in sorts first, so its values win (sshd takes the first one it
# reads). Needs the template's Include of sshd_config.d (Debian ships it).
mkdir -p /etc/ssh/sshd_config.d
printf 'PermitRootLogin prohibit-password\nPasswordAuthentication no\nKbdInteractiveAuthentication no\n' \
  > /etc/ssh/sshd_config.d/10-vibe-root-key-only.conf
sshd -t && systemctl reload ssh >/dev/null 2>&1 || true

vibe --version
EOF
}

# Re-inject the permanent credential store into the fresh CT.
# The CLI reads /root/.vibe/.env automatically on startup; shell env vars
# take precedence over it, but the sandbox sets none, so this is the source.
inject_credentials() {
  if [ ! -f "$SECRETS_FILE" ]; then
    echo "warning: no key store at $SECRETS_FILE - CLI will need the setup wizard" >&2
    echo "  create a key at chat.mistral.ai (Code > Vibe CLI), then run:" >&2
    echo "    printf 'MISTRAL_API_KEY=<key>\n' > $SECRETS_FILE && chmod 600 $SECRETS_FILE" >&2
    return 0
  fi
  [ "$(stat -c %a "$SECRETS_FILE")" = "600" ] || chmod 600 "$SECRETS_FILE"
  ct_push_file "$SECRETS_FILE" /root/.vibe/.env 600 \
    || die "failed to inject credentials into CT $CTID"
  echo "credentials injected (host: $SECRETS_FILE -> CT: /root/.vibe/.env)"
}

# Shared post-build provisioning: base toolchain + CLI + credentials + hook.
provision_and_report() {
  echo "provisioning base toolchain and Vibe CLI ..."
  local prov
  prov="$(mktemp)"
  provision_base_script > "$prov"
  ct_push_file "$prov" /root/provision-base.sh 700
  ct_run bash /root/provision-base.sh
  rm -f "$prov"

  # permanent credential store -> fresh CT, every build
  inject_credentials

  # hardened Vibe CLI config (default-deny connectors, MCP, auto-approve)
  inject_vibe_config

  # user hook (deterministic per-use extras), if present
  if [ -f "$PROVISION_HOOK" ]; then
    echo "running user provisioning hook $PROVISION_HOOK ..."
    ct_push_file "$PROVISION_HOOK" /root/provision.sh 700
    ct_run bash /root/provision.sh
  fi
}

print_ssh_line() {
  local ip="${1:-$(sandbox_ip)}"
  if [ -n "$SSH_KEY_FILE" ]; then
    echo "  ssh -i ${SSH_KEY_FILE} root@${ip}"
  else
    echo "  ssh root@${ip}"
  fi
  echo "  (or on this host: $(readlink -f "$0") ssh)"
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
  warn_public_ipv6
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
  The sandbox MAC is also permanent - retained on the host across
  rebuilds - so reserve the IP for it on your DHCP server (router,
  pfSense/OPNsense, Pi-hole, whatever hands out addresses):
    ${mac:-unknown}
  With that reservation, the IP below never goes stale and 'ssh
  vibe-sandbox' just works after every rebuild. Without it, only the
  HostName (IP) goes stale per rebuild - re-run 'export' on the host and
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
  IDENTIFICATION HAS CHANGED after each rebuild - expected rotation,
  not an attack; recover and reconnect:
    ssh-keygen -R $ip

PuTTY instead of OpenSSH
------------------------
  puttygen "%USERPROFILE%\.ssh\vibe-sandbox" -o vibe-sandbox.ppk
  Host Name: $ip   Port: 22   User: root
  (load vibe-sandbox.ppk under Connection > SSH > Auth > Credentials)
  (each rebuild mints a fresh host key - accept it when PuTTY asks)

Security
--------
  The private key now also lives on this desktop. It is a dedicated
  sandbox keypair - it unlocks the sandbox (every future rebuild too),
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
    echo "  note: this host is multi-homed ($(hostname -I | awk '{$1=$1};1')) -"
    echo "  if $hostip is not reachable from your desktop, rerun with:"
    echo "    HOST_IP=<reachable-address> $0 export"
  fi
  echo "  then follow the README.txt inside; connect with: ssh vibe-sandbox"
  echo "recommended: set a DHCP reservation for the sandbox MAC ${mac:-unknown} -"
  echo "  it is retained across rebuilds, so the IP stays stable forever"
  echo "note: without a reservation, re-run 'export' after each rebuild - only the IP changes; the key is permanent"
  echo "note: rebuilds mint a fresh host key; the bundled ssh-config pins"
  echo "  StrictHostKeyChecking no for the sandbox Host, so desktop connects survive rebuilds"
}

# INTERNAL: entry point for the PVE hookscript shim. PVE calls the shim with
# (vmid, phase); the shim execs this. Phases:
#   pre-start  — allow the boot only if the CT is a pristine stub (see
#                mark_stub_pristine); otherwise abort the Start
#   post-start — wait for IP, provision, log the ssh line
#   pre-stop   — work guard: refuse stops that would lose unextracted work
#   post-stop  — schedule the park ($PARK_UNIT: clobber + fresh stub), which
#                runs once PVE has released the CT (see schedule_park)
# All destructive phases go through guard_ct(): if the CT at $CTID is not
# provably ours, the hook ABORTS the GUI task instead of touching it.
# Hook phases lock with hook_lock(), never lock_or_die: a phase can fire
# from inside `up`'s or `down`'s own pct call, which already holds the
# serial lock. Lock free -> standalone/GUI task, this hook does the
# phase's work; lock held -> the holder is the triggering operation and
# does the work itself, this hook passes through with exit 0.
cmd_hook() {
  local vmid="${1:-}" phase="${2:-}"
  # One stream for the PVE task log: it reads stdout and stderr separately,
  # so warnings otherwise land out of order (after "ready via GUI").
  exec 2>&1
  [ "$vmid" = "$CTID" ] || exit 0
  case "$phase" in
    pre-start)
      # Runs INSIDE Proxmox's Start task, under the CT's config lock: no
      # pct destroy/create/set on this CT from here (they would time out
      # on that lock). Boot only a pristine stub left by down / GUI Stop;
      # anything else aborts the Start (non-zero exit) with directions.
      self_check hook "$vmid" "$phase"
      # checked before hook_lock: the park job holds the serial lock, and
      # a lock holder would otherwise make this phase pass through
      ! park_job_active || die "pre-start: CT $CTID is still being parked after the last Stop (unit $PARK_UNIT). Wait a minute, then Start again; progress: journalctl -u $PARK_UNIT"
      hook_lock "$phase" || exit 0
      validate_hardening_config
      guard_ct
      stub_is_pristine || die "pre-start: CT $CTID is not a fresh stub (it has booted since it was built, or was not parked by 'down' / GUI Stop). GUI Start cannot rebuild it, because Proxmox holds the CT's lock during Start. On the host, run: $0 up"
      stub_firewall_consistent || die "pre-start: firewall settings changed since CT $CTID was parked (FIREWALL=$FIREWALL, EGRESS_POLICY=$EGRESS_POLICY). On the host, run: $0 up"
      configure_firewall   # refresh the host-side ruleset (a file under /etc/pve/firewall, not the CT config)
      clear_stub_marker    # booting now: from here on this is a used disk
      echo "pre-start: CT $CTID is a fresh, never-booted stub - starting it"
      ;;  # PVE now boots the stub; post-start provisions it
    post-start)
      hook_lock "$phase" || exit 0
      guard_ct
      local ip
      ip="$(wait_for_ip)" || { echo "post-start: no IP (check ${BRIDGE}/DHCP)"; exit 0; }
      purge_known_hosts "$ip"
      provision_and_report
      print_hardening_summary
      warn_public_ipv6
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
      schedule_park
      echo "post-stop: parking CT $CTID once Proxmox releases it (unit $PARK_UNIT, about a minute);"
      echo "  GUI Start works when it is done. Progress: journalctl -u $PARK_UNIT"
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
  elif park_job_active; then
    echo "CT $CTID stopped: being parked after GUI Stop (unit $PARK_UNIT); GUI Start works when done, firewall: ${fw_info}"
  elif stub_is_pristine; then
    echo "CT $CTID stopped: fresh stub, ready for GUI Start, firewall: ${fw_info}"
  else
    echo "CT $CTID stopped: NOT a fresh stub (GUI Start will refuse; run '$0 up'), firewall: ${fw_info}"
  fi
}

# ssh into the sandbox with the managed key: `ssh [command...]`.
# Host keys rotate on every rebuild; build paths purge the stale
# known_hosts entry, and accept-new records the fresh key on first use
# (a key CHANGING under a live sandbox would still be refused).
cmd_ssh() {   # "$@" = optional remote command
  ct_running || die "sandbox not running; run 'up' first"
  local ip keyargs=()
  ip="$(sandbox_ip)"
  [ -n "$ip" ] || die "no IP for the sandbox (check ${BRIDGE}/DHCP)"
  [ -z "$SSH_PUBKEY" ] && keyargs=(-i "$SSH_KEY_FILE" -o IdentitiesOnly=yes)
  exec ssh "${keyargs[@]}" -o StrictHostKeyChecking=accept-new "root@${ip}" "$@"
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
  local self tmp bak repo
  if repo="$(script_git_checkout)"; then
    die "this copy lives in the git checkout at $repo - update it with: git -C $repo pull"
  fi
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
  version|--version) echo "vibe-sandbox $VIBE_SANDBOX_VERSION" ;;
  shell)  shift; cmd_shell ;;
  ssh)    shift; cmd_ssh "$@" ;;
  export) shift; cmd_export ;;
  update)  shift; cmd_update ;;
  hook)   shift; cmd_hook "$@" ;;
  park-deferred) shift; cmd_park_deferred ;;
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
