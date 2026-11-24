#!/usr/bin/env bash
# Dry-run tests for vibe-sandbox.sh against mock Proxmox commands
# (tests/mock/bin: pct, pvesm, blkdiscard, ssh). Covers the GUI Start lock
# fix (#41), the blkdiscard wipe (#42), EGRESS_DENY / public IPv6 (#43)
# and the tidy-ups in #45.
# Needs root (/run/lock), bash, ssh-keygen. Never run on a Proxmox host.
# Usage: sudo bash tests/run-tests.sh [path/to/vibe-sandbox.sh]
set -uo pipefail
[ ! -d /etc/pve ] || { echo "refusing to run on a Proxmox host: the tests clear /run/lock/vibe-sandbox.* (live locks)" >&2; exit 2; }
SRC="$(readlink -f "${1:-$(dirname "$0")/../vibe-sandbox.sh}")"
HERE="$(cd "$(dirname "$0")" && pwd)/mock"
pass=0; fail=0
ok()   { echo "  PASS $*"; pass=$((pass+1)); }
bad()  { echo "  FAIL $*"; fail=$((fail+1)); }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

fresh() {   # new isolated world; sets T and S (script copy outside any git checkout)
  T="$(mktemp -d)"; export MOCK_T="$T"
  mkdir -p "$T/host" "$T/fw" "$T/snip" "$T/home/.ssh"
  S="$T/vibe-sandbox.sh"; cp "$SRC" "$S"; chmod +x "$S"
  rm -f /run/lock/vibe-sandbox.*
}
# Host-side paths, redirected into the test world. A PVE hookscript gets
# none of the caller's environment, so gui_hook passes them explicitly
# (on a real host they are the script defaults).
HOSTVARS='CONFIG_FILE=$T/host/conf SSH_KEY_FILE=$T/host/ssh MAC_FILE=$T/host/mac SECRETS_FILE=$T/host/secrets.env STUB_MARKER=$T/host/pristine-stub FW_DIR=$T/fw HOOK_SNIPPET_DIR=$T/snip AUTO_UPDATE=off TEMPLATE=local:vztmpl/debian-12.tar.zst'
run() {   # run the script copy in the mock world, with the caller's env
  eval "env PATH=\"$HERE/bin:\$PATH\" HOME=\"\$T/home\" $HOSTVARS EXPORT_DIR=\"\$T/export\" \"\$@\""
}
gui_hook() {   # $1 = vmid, $2 = phase, $3 = extra VAR=val; env-less like PVE
  env -i PATH="$HERE/bin:/usr/bin:/bin" MOCK_T="$T" \
    bash -c "$(eval echo "$HOSTVARS") ${3:-} $S hook $1 $2" 2>&1
}
calls_lack() { ! grep -qE "$1" "$T/calls.log"; }
run_deferred() {   # run the job post-stop handed to systemd-run, env-less like a unit
  env -i PATH="$HERE/bin:/usr/bin:/bin" MOCK_T="$T" \
    bash -c "$(eval echo "$HOSTVARS") ${1:-} $(cat "$T/deferred.cmd")" 2>&1
}
# A GUI Stop as PVE runs it: the CT has stopped, but `pct status` still says
# running and the CT config lock is held until post-stop returns. Sets
# STOP_OUT (hook output) and STOP_RC; the park job is left in deferred.cmd.
gui_stop_hook() {
  rm -f "$T/run/1042" "$T/deferred.cmd"
  mkdir -p "$T/locked" "$T/stopping" "$T/unit-active"
  touch "$T/locked/1042" "$T/stopping/1042" "$T/unit-active/1042"
  : > "$T/calls.log"
  STOP_OUT="$(gui_hook 1042 post-stop "${1:-}")"; STOP_RC=$?
  rm -f "$T/locked/1042" "$T/stopping/1042" "$T/unit-active/1042"   # Stop task ends
}

echo "== up"
fresh
out="$(run "$S" up 2>&1)"; rc=$?
check "up exits 0" [ $rc -eq 0 ]
[ $rc -eq 0 ] || echo "$out" | tail -15
check "CT 1042 created, tagged, hooked, firewall=1" grep -q '^tags: vibe-sandbox$' "$T/conf/1042.conf" && grep -q '^hookscript: ' "$T/conf/1042.conf" && grep -q 'firewall=1' "$T/conf/1042.conf"
check "no pristine-stub marker after up" [ ! -e "$T/host/pristine-stub" ]
check "provisioning without pct push" calls_lack '^pct push '
check "provisioning in a clean env with HOME=/root" grep -qE '^pct exec 1042 -- env -i HOME=/root .*PATH=/root/.local/bin:[^ ]* bash /root/provision-base.sh$' "$T/calls.log"
check "provision script pushed, mode 700" [ "$(stat -c %a "$T/ct/1042/root/provision-base.sh")" = 700 ]
check "  ...disables dpkg progress lines" grep -q 'Dpkg::Use-Pty=0' "$T/ct/1042/root/provision-base.sh"
check "  ...is valid bash" bash -n "$T/ct/1042/root/provision-base.sh"
check "  ...pins key-only sshd: no root password login" grep -q 'PermitRootLogin prohibit-password' "$T/ct/1042/root/provision-base.sh"
check "  ...and no password or keyboard-interactive auth at all" bash -c "grep -q 'PasswordAuthentication no' '$T/ct/1042/root/provision-base.sh' && grep -q 'KbdInteractiveAuthentication no' '$T/ct/1042/root/provision-base.sh'"
C="$T/ct/1042/root/.vibe/config.toml"
check "vibe config injected, mode 400, all default-deny" [ "$(stat -c %a "$C")" = 400 ] && [ "$(grep -c '= false$' "$C")" = 3 ]
check "missing key store -> wizard warning" grep -q 'no key store at' <<<"$out"
check "ready line offers the ssh shortcut" grep -q "or on this host: $S ssh" <<<"$out"

echo "== credentials"
fresh
printf 'MISTRAL_API_KEY=test-not-real\n' > "$T/host/secrets.env"; chmod 644 "$T/host/secrets.env"
run "$S" up >/dev/null 2>&1
check "key pushed to /root/.vibe/.env" grep -q 'MISTRAL_API_KEY=test-not-real' "$T/ct/1042/root/.vibe/.env"
check "  ...mode 600 in CT" [ "$(stat -c %a "$T/ct/1042/root/.vibe/.env")" = 600 ]
check "  ...host file tightened to 600" [ "$(stat -c %a "$T/host/secrets.env")" = 600 ]

echo "== down: blkdiscard -f + pristine stub (#42, #41)"
fresh
run "$S" up >/dev/null 2>&1
out="$(run FORCE=1 RESCUE=0 "$S" down 2>&1)"; rc=$?
check "down exits 0" [ $rc -eq 0 ]
check "  ...clobbered via blkdiscard -f" grep -q '^blkdiscard -f /dev/mock/' "$T/calls.log"
check "  ...with no clobber failure" bash -c "! grep -q 'blkdiscard failed' <<<\"\$1\"" _ "$out"
check "  ...stub exists, stopped, hook attached" [ -f "$T/conf/1042.conf" ] && [ ! -e "$T/run/1042" ] && grep -q hookscript "$T/conf/1042.conf"
check "  ...pristine-stub marker written for CT 1042" [ "$(cat "$T/host/pristine-stub" 2>/dev/null)" = 1042 ]
out="$(run "$S" status 2>&1)"
check "status reports a fresh stub" grep -q 'stopped: fresh stub, ready for GUI Start' <<<"$out"
# a failing discard reports blkdiscard's own reason, not a guess
out="$(run FORCE=1 RESCUE=0 PATH="$T/nodiscard:$HERE/bin:$PATH" bash -c 'mkdir -p "$1"; printf "#!/bin/sh\necho \"blkdiscard: BLKDISCARD ioctl failed: Operation not supported\" >&2; exit 1\n" > "$1/blkdiscard"; chmod +x "$1/blkdiscard"; "$2" down' _ "$T/nodiscard" "$S" 2>&1)"
check "failed discard reports blkdiscard's message" grep -q 'blkdiscard failed on /dev/mock/.*: blkdiscard: BLKDISCARD ioctl failed' <<<"$out"
check "  ...and no longer guesses 'rotational disk'" bash -c "! grep -q 'rotational' <<<\"\$1\"" _ "$out"

echo "== GUI Start under the Proxmox CT lock (#41)"
fresh
run "$S" up >/dev/null 2>&1
run FORCE=1 RESCUE=0 "$S" down >/dev/null 2>&1
mkdir -p "$T/locked"; touch "$T/locked/1042"; : > "$T/calls.log"
out="$(gui_hook 1042 pre-start)"; rc=$?
check "pre-start on a fresh stub succeeds under the lock" [ $rc -eq 0 ]
[ $rc -eq 0 ] || echo "$out" | tail -5
check "  ...without destroy/create/set/push" calls_lack '^pct (destroy|create|set|push) '
check "  ...says it is starting the stub" grep -q 'fresh, never-booted stub' <<<"$out"
check "  ...and consumes the marker" [ ! -e "$T/host/pristine-stub" ]
touch "$T/run/1042"; : > "$T/calls.log"
out="$(gui_hook 1042 post-start)"; rc=$?
check "post-start under the lock provisions + reports" [ $rc -eq 0 ] && grep -q 'sandbox ready via GUI' <<<"$out"
[ $rc -eq 0 ] || echo "$out" | tail -5
check "  ...without pct push" calls_lack '^pct push '
check "  ...provisioning has HOME=/root although the hook env is empty" grep -qE '^pct exec 1042 -- env -i HOME=/root .* bash /root/provision-base.sh$' "$T/calls.log"
check "  ...config + provision script in place" [ -f "$T/ct/1042/root/provision-base.sh" ] && [ -f "$T/ct/1042/root/.vibe/config.toml" ]
check "  ...hook output is ASCII-only (PVE task log mangles UTF-8)" bash -c "! LC_ALL=C grep -q '[^ -~]' <<<\"\$1\"" _ "$out"
check "  ...warnings land in order on stdout" bash -c "[ \$(grep -n 'Datacenter firewall is disabled' <<<\"\$1\" | cut -d: -f1) -lt \$(grep -n 'ready via GUI' <<<\"\$1\" | cut -d: -f1) ]" _ "$out"
rm -f "$T/run/1042"; : > "$T/calls.log"
out="$(gui_hook 1042 pre-start)"; rc=$?
check "pre-start refuses a CT that has booted" [ $rc -ne 0 ] && grep -q "is not a fresh stub.*run: $S up" <<<"$out"
check "  ...without touching the CT" calls_lack '^pct (destroy|create|set) '
rm -f "$T/locked/1042"
out="$(run "$S" status 2>&1)"
check "status flags the used stopped CT" grep -q 'NOT a fresh stub' <<<"$out"
run FORCE=1 RESCUE=0 "$S" down >/dev/null 2>&1
touch "$T/locked/1042"
out="$(gui_hook 1042 pre-start FIREWALL=off)"; rc=$?
check "pre-start refuses when firewall settings changed since park" [ $rc -ne 0 ] && grep -q 'firewall settings changed' <<<"$out"
check "  ...and keeps the stub pristine" [ -e "$T/host/pristine-stub" ]
out="$(gui_hook 1042 pre-start)"; rc=$?
check "  ...then starts with the original settings" [ $rc -eq 0 ]
rm -f "$T/locked/1042"

echo "== GUI Stop: park deferred until Proxmox releases the CT"
gui_stop_hook
check "post-stop under the PVE lock exits 0" [ $STOP_RC -eq 0 ]
[ $STOP_RC -eq 0 ] || echo "$STOP_OUT" | tail -5
check "  ...without pct stop/destroy/create (they need the lock)" calls_lack '^pct (stop|destroy|create|set|push) '
check "  ...schedules the park via systemd-run" grep -q "^systemd-run --unit vibe-sandbox-park-1042 .* park-deferred$" "$T/calls.log"
check "  ...and says so in the task log" grep -q 'parking CT 1042 once Proxmox releases it' <<<"$STOP_OUT"
check "  ...nothing parked yet" [ ! -e "$T/host/pristine-stub" ]
touch "$T/park-active"; touch "$T/locked/1042"
out="$(gui_hook 1042 pre-start)"; rc=$?
check "Start while the park job runs is refused with directions" [ $rc -ne 0 ] && grep -q 'still being parked.*journalctl -u vibe-sandbox-park-1042' <<<"$out"
rm -f "$T/locked/1042"
out="$(run "$S" status 2>&1)"
check "status says parking is in progress" grep -q 'being parked after GUI Stop' <<<"$out"
rm -f "$T/park-active"
# the job waits while PVE still has the CT's unit up
touch "$T/unit-active/1042"; ( sleep 3; rm -f "$T/unit-active/1042" ) &
: > "$T/calls.log"; start=$(date +%s)
out="$(run_deferred FORCE=1)"; rc=$?
check "park job exits 0" [ $rc -eq 0 ]
[ $rc -eq 0 ] || echo "$out" | tail -5
check "  ...waited for pve-container@1042 to go inactive" [ $(( $(date +%s) - start )) -ge 2 ]
check "  ...clobbered via blkdiscard -f" grep -q '^blkdiscard -f /dev/mock/' "$T/calls.log"
check "  ...parked a fresh stub, marked pristine" [ "$(cat "$T/host/pristine-stub" 2>/dev/null)" = 1042 ] && [ ! -e "$T/run/1042" ]
check "  ...says it is ready for GUI Start" grep -q 'parked as a fresh stub - ready for GUI Start' <<<"$out"
touch "$T/locked/1042"
out="$(gui_hook 1042 pre-start)"; rc=$?
check "GUI Start then boots the stub" [ $rc -eq 0 ] && grep -q 'fresh, never-booted stub' <<<"$out"
rm -f "$T/locked/1042"
# Stop, then the CT is started again (CLI up) before the job runs: leave it alone
touch "$T/run/1042"; gui_stop_hook; touch "$T/run/1042"; : > "$T/calls.log"
out="$(run_deferred)"
check "park job leaves a CT that was started meanwhile alone" grep -q 'started again meanwhile - not parking' <<<"$out" && calls_lack '^pct (stop|destroy|create) '
rm -f "$T/run/1042"
run_deferred FORCE=1 >/dev/null   # parks the used CT
: > "$T/calls.log"; out="$(run_deferred FORCE=1)"
check "park job is a no-op on an already fresh stub" grep -q 'already a fresh stub' <<<"$out" && calls_lack '^pct (stop|destroy|create) '
check "hook ignores other CTs" bash -c "[ -z \"\$1\" ]" _ "$(gui_hook 999 pre-start)"

echo "== ownership guard"
fresh
mkdir -p "$T/conf"; printf 'hostname: wordpress\ntags: web\n' > "$T/conf/1042.conf"
echo 1042 > "$T/host/pristine-stub"
out="$(gui_hook 1042 pre-start)"; rc=$?
check "pre-start refuses a foreign CT even with a marker" [ $rc -ne 0 ] && grep -q 'refusing to touch CT 1042' <<<"$out"

echo "== IPv6: EGRESS_DENY and the public-IPv6 warning (#43)"
fresh
V6="2a10:d585:7f66:2:56:1dff:fef2:f487 2a10:d585:7f66:0:56:1dff:fef2:f487"
out="$(run "$S" up 2>&1)"
check "no IPv6 -> no warning" bash -c "! grep -q 'public IPv6' <<<\"\$1\"" _ "$out"
out="$(run MOCK_IPV6="$V6" FORCE=1 RESCUE=0 "$S" up 2>&1)"
check "public IPv6 + lan-block + no EGRESS_DENY -> warning" grep -q 'the sandbox has public IPv6 address' <<<"$out"
check "  ...lists the addresses" grep -q '2a10:d585:7f66:0:56:1dff:fef2:f487/64' <<<"$out"
check "  ...and suggests the /48" grep -q 'EGRESS_DENY=2a10:d585:7f66::/48' <<<"$out"
out="$(run MOCK_IPV6="$V6" EGRESS_DENY=2a10:d585:7f66::/48 FORCE=1 RESCUE=0 "$S" up 2>&1)"
check "EGRESS_DENY set -> no warning" bash -c "! grep -q 'public IPv6' <<<\"\$1\"" _ "$out"
check "  ...and the .fw drops the site range" grep -q '^OUT DROP -dest 2a10:d585:7f66::/48 -log nolog # EGRESS_DENY' "$T/fw/1042.fw"
check "  ...before the private-range drops" bash -c "[ \$(grep -n 'EGRESS_DENY' '$T/fw/1042.fw' | cut -d: -f1) -lt \$(grep -n '10.0.0.0/8' '$T/fw/1042.fw' | cut -d: -f1) ]"
run EGRESS_DENY=2a10:d585:7f66::/48 EGRESS_ALLOW=2a10:d585:7f66:2::50/128 FORCE=1 RESCUE=0 "$S" up >/dev/null 2>&1
check "EGRESS_ALLOW still punches a hole first" bash -c "[ \$(grep -n 'EGRESS_ALLOW' '$T/fw/1042.fw' | cut -d: -f1) -lt \$(grep -n 'EGRESS_DENY' '$T/fw/1042.fw' | cut -d: -f1) ]"
out="$(run EGRESS_DENY='2a10::/48;DROP' FORCE=1 RESCUE=0 "$S" up 2>&1)"; rc=$?
check "invalid EGRESS_DENY rejected (no .fw injection)" [ $rc -ne 0 ] && grep -q "invalid IP/CIDR '2a10::/48;DROP' in EGRESS_DENY" <<<"$out"
out="$(run MOCK_IPV6="$V6" EGRESS_POLICY=strict FORCE=1 RESCUE=0 "$S" up 2>&1)"
check "strict policy -> no IPv6 warning" bash -c "! grep -q 'public IPv6' <<<\"\$1\"" _ "$out"

echo "== host config file (settings that survive GUI hooks)"
fresh
printf '# site settings\nEGRESS_DENY=2a10:d585:7f66::/48\nCORES="2"\nBOGUS=$(touch %s/pwned)\n' "$T" > "$T/host/conf"; chmod 600 "$T/host/conf"
out="$(run "$S" up 2>&1)"; rc=$?
check "up with a config file exits 0" [ $rc -eq 0 ]
[ $rc -eq 0 ] || echo "$out" | tail -5
check "  ...EGRESS_DENY from the file lands in the .fw" grep -q '^OUT DROP -dest 2a10:d585:7f66::/48 .*EGRESS_DENY' "$T/fw/1042.fw"
check "  ...quoted value read (cores 2)" grep -q -- '--cores 2 ' "$T/calls.log"
check "  ...values are never executed" [ ! -e "$T/pwned" ]
run CORES=6 FORCE=1 RESCUE=0 "$S" up >/dev/null 2>&1
check "command-line env beats the file (cores 6)" grep -q -- '--cores 6 ' "$T/calls.log"
gui_stop_hook; out="$(run_deferred FORCE=1)"; rc=$?
check "GUI Stop + park job (empty env) parks a stub" [ $STOP_RC -eq 0 ] && [ $rc -eq 0 ] && [ -e "$T/host/pristine-stub" ]
check "  ...and the rewritten .fw keeps EGRESS_DENY" grep -q 'EGRESS_DENY' "$T/fw/1042.fw"
mkdir -p "$T/locked"; touch "$T/locked/1042"
out="$(gui_hook 1042 pre-start)"; rc=$?
check "GUI Start (empty env) keeps EGRESS_DENY too" [ $rc -eq 0 ] && grep -q 'EGRESS_DENY' "$T/fw/1042.fw"
rm -f "$T/locked/1042"
touch "$T/run/1042"
out="$(run MOCK_IPV6=2a10:d585:7f66:2::5 "$S" hook 1042 post-start 2>&1)"
check "  ...so no public-IPv6 warning" bash -c "! grep -q 'public IPv6' <<<\"\$1\"" _ "$out"
chmod 666 "$T/host/conf"
out="$(run "$S" status 2>&1)"; check "group/world-writable config refused" grep -q 'refusing .*conf: group/other-writable' <<<"$out"
chmod 600 "$T/host/conf"; printf 'CONFIG_FILE=/tmp/x\n' >> "$T/host/conf"
out="$(run "$S" status 2>&1)"; check "CONFIG_FILE cannot be set from the file" grep -q 'CONFIG_FILE cannot be set' <<<"$out"
printf 'not a valid line\n' > "$T/host/conf"
out="$(run "$S" status 2>&1)"; check "malformed line refused" grep -q 'bad line in' <<<"$out"
printf 'X=1\n' > "$T/host/conf"; chown 65534 "$T/host/conf"
out="$(run "$S" status 2>&1)"; check "non-root-owned config refused" grep -q 'not owned by root' <<<"$out"
fresh
out="$(run MOCK_IPV6=2a10:d585:7f66:2::5 "$S" up 2>&1)"
check "IPv6 warning points at the config file" grep -q "add your site's delegated prefix to $T/host/conf" <<<"$out"

echo "== ssh, self-update in a git checkout (#45)"
fresh
out="$(run "$S" ssh 2>&1)"
check "ssh refuses when the sandbox is not running" grep -q 'sandbox not running' <<<"$out"
run "$S" up >/dev/null 2>&1; : > "$T/calls.log"
run "$S" ssh uname -a >/dev/null 2>&1
check "ssh uses the managed key, accept-new, and passes the command" grep -qx "ssh -i $T/host/ssh -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new root@192.168.3.77 uname -a" "$T/calls.log"
out="$(run AUTO_UPDATE=on RAW_URL=http://127.0.0.1:9/none FORCE=1 RESCUE=0 "$S" up 2>&1)"
check "self-check outside a checkout tries RAW_URL" grep -q 'self-check: could not fetch' <<<"$out"
mkdir "$T/.git"
out="$(run AUTO_UPDATE=on RAW_URL=http://127.0.0.1:9/none FORCE=1 RESCUE=0 "$S" up 2>&1)"
check "self-check inside a git checkout is skipped" grep -q "self-check: skipped - running from the git checkout at $T" <<<"$out"
check "  ...without touching the network or writing a .bak" bash -c "! grep -q 'could not fetch' <<<\"\$1\" && [ ! -e '$S.bak' ]" _ "$out"
out="$(run "$S" update 2>&1)"; rc=$?
check "update refuses in a git checkout, pointing at git pull" [ $rc -ne 0 ] && grep -q 'git -C .* pull' <<<"$out"

echo "== provision.sh beside the real script, symlinked or not"
fresh
printf 'echo user-hook\n' > "$T/provision.sh"
mkdir -p "$T/link"; ln -s "$S" "$T/link/vibe-sandbox.sh"
printf 'echo wrong-hook\n' > "$T/link/provision.sh"
out="$(run "$T/link/vibe-sandbox.sh" up 2>&1)"; rc=$?
check "up via a symlink exits 0" [ $rc -eq 0 ]
check "  ...runs provision.sh beside the real script" grep -q "running user provisioning hook $T/provision.sh" <<<"$out"
check "  ...not the one beside the symlink" grep -q '^echo user-hook$' "$T/ct/1042/root/provision.sh"
check "  ...hook shim execs the resolved script" grep -q "exec $S hook" "$T/snip/vibe-sandbox-hook.sh"
run FORCE=1 RESCUE=0 "$T/link/vibe-sandbox.sh" down >/dev/null 2>&1
mkdir -p "$T/locked"; touch "$T/locked/1042"; gui_hook 1042 pre-start >/dev/null; rm -f "$T/locked/1042"
touch "$T/run/1042"; rm -f "$T/ct/1042/root/provision.sh"
out="$(gui_hook 1042 post-start)"
check "GUI post-start runs the same provision.sh" grep -q "running user provisioning hook $T/provision.sh" <<<"$out" && grep -q '^echo user-hook$' "$T/ct/1042/root/provision.sh"

echo "== version"
fresh
V="$(sed -n 's/^VIBE_SANDBOX_VERSION="\(.*\)"$/\1/p' "$S")"
check "VIBE_SANDBOX_VERSION is semver" grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' <<<"$V"
check "version subcommand prints it" [ "$(run "$S" version 2>&1)" = "vibe-sandbox $V" ]
check "  ...and --version too" [ "$(run "$S" --version 2>&1)" = "vibe-sandbox $V" ]

echo "== vscode-connect PVE_KEY default (#44)"
D="$(dirname "$SRC")"
check "vscode-connect.sh defaults to /root/.vibe-sandbox-ssh" grep -q 'PVE_KEY="${PVE_KEY:-/root/.vibe-sandbox-ssh}"' "$D/vscode-connect.sh"
check "vscode-connect.ps1 defaults to /root/.vibe-sandbox-ssh" grep -q "'/root/.vibe-sandbox-ssh'" "$D/vscode-connect.ps1"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
