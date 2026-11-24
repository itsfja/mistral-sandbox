# Changelog

All notable changes to vibe-sandbox are listed here, newest first.
Versions follow [Semantic Versioning](https://semver.org/): patch for
fixes, minor for new features or settings, major for changes that need
you to act. See [Releases](README.md#releases) for how releases are cut
and deployed.

## Unreleased

Nothing yet.

## 1.0.0 - 2026-11-24

First tagged release: a single-use, firewalled Proxmox LXC sandbox for the
Mistral Vibe CLI, driven from the shell or the Proxmox GUI.

### Lifecycle
- `up` rebuilds the sandbox from the Debian template every time and
  provisions it (toolchain, Vibe CLI, credentials, hardened Vibe config);
  `down` clobbers the disk and parks a fresh, never-booted stub; `purge`,
  `reset`, `status`, `ip`, `shell`, `ssh`, `export`, `update`, `version`
  (#2, #6, #9, #13, #47).
- GUI lifecycle through a pct hookscript: right-click Stop parks a fresh
  stub through a deferred systemd job, right-click Start boots it and
  provisions it. Proxmox holds the CT's lock for the whole Start and
  Stop tasks, so no hook creates or destroys the CT (#6, #15, #47, #52).
- Same MAC on every rebuild, so a DHCP reservation keeps the IP (#19).

### Safety
- Ownership guard: refuses to touch any CT it cannot prove it built (#7).
- Work-loss guard and rescue archive: a running sandbox with unpushed git
  work is not destroyed without confirmation, and is backed up with
  vzdump first (#25, #27, #29).
- Disk clobber on park, with `blkdiscard -f` (instant on SSDs) or
  `CLOBBER=zero` (#6, #47).

### Network and access
- Host-enforced Proxmox firewall, `EGRESS_POLICY=lan-block` by default:
  blocks RFC1918, link-local, CGNAT and IPv6 ULA, plus `EGRESS_DENY` for
  your site's public IPv6 range; warns when the sandbox has public IPv6
  and nothing blocks it (#47).
- Vibe connectors, MCP and auto-approve off by default (#47).
- Key-only SSH: no root password, and sshd offers no password prompt
  (#19, #51). Host keys rotate per rebuild; stale `known_hosts` entries
  are purged automatically (#23).
- Desktop bundle and VS Code Remote-SSH scripts (`vscode-connect.sh`,
  `vscode-connect.ps1`) (#9, #21, #31, #34, #36, #38, #39, #47).

### Configuration
- Host config file `/root/.vibe-sandbox.conf`: plain `KEY=value` lines,
  read by CLI runs and GUI hooks alike, never executed (#48).
- Optional `provision.sh` beside the script for your own setup steps
  (#49).

### Maintenance
- Self-update from `main` for copies installed by hand; skipped inside a
  git checkout, where `git pull` or `git checkout <tag>` is the update
  (#13, #47).
- Dry-run test suite against mock Proxmox commands and CI on every PR
  (#47, #48, #50).

### Known limitations
- GUI **Restart** is not supported: use Stop, wait about a minute for the
  park to finish, then Start (#52).
- Builds install the latest Vibe CLI, uv and Python from the internet, so
  a build can change without a change here. Pinning is planned for 1.1.
- Self-update (copies outside a git checkout) follows `main`, not
  releases. Run a release from a git checkout of its tag instead.
- A failed provisioning step in a GUI Start is only visible in the
  Start task's log.
