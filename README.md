# mistral-sandbox

A single-use, auto-rebuild Linux container (LXC) sandbox for Proxmox VE,
provisioned on every build with the current
[Mistral Vibe CLI](https://docs.mistral.ai/vibe/code/cli/install-setup).
A contained environment for letting an AI coding agent work with full
outbound internet access — without handing it your machine.

## Design

- **Single use** — one sandbox at a time (fixed CTID); nothing persists
  between uses.
- **Auto rebuild on startup** — `up` (or a GUI Start) never resumes an old
  container: it destroys any existing one and rebuilds from the template,
  so every session starts clean.
- **Serially rebuildable** — a global `flock` serializes operations and the
  build is deterministic from the config block; rebuild #1 == rebuild #50.
- **Internet-enabled** — unrestricted outbound net: the agent can download
  any tool it needs (apt, curl, pip, uv, npm) and search or fetch the web
  whenever required (the Vibe CLI also has web search and fetch built in).
- **Mistral-tooled** — the current Vibe CLI (`mistral-vibe`) is installed
  at build time, unpinned, so each rebuild gets the latest iteration.
- **Credential store** — a host-side key file is re-injected into every
  rebuild; the key is created and revocable at chat.mistral.ai
  (Code > Vibe CLI) and never lives in this repository.
- **SSH-kept** — a dedicated sandbox keypair is permanently retained on the
  host (default `/root/.vibe-sandbox-ssh`), generated automatically on the
  first `up`, and its public half is injected into every rebuild. The
  private key stays on the host; override with `SSH_PUBKEY` to reuse an
  existing key instead.
- **MAC-kept** — the sandbox's MAC address is generated once and retained
  on the host (default `/root/.vibe-sandbox.mac`), then pinned on every
  rebuild — PVE would otherwise mint a fresh random MAC each time, silently
  breaking DHCP reservations. Fix the sandbox IP by reserving it on your
  DHCP server for that MAC: the reservation then holds for every future
  rebuild. Override with `CT_MAC`.
- **GUI-trapped** — the Proxmox GUI drives the lifecycle: right-click
  Start = fresh rebuild + provisioning; Stop = disk clobber + parked stub;
  Restart = fresh rebuild. Implemented with a `pct` hookscript, whose shim
  is auto-deployed on every run. `HOOK=off` disables it.
- **Clobbered** — on stop, the rootfs is discarded (`CLOBBER=discard`,
  instant on SSD) or zero-filled (`CLOBBER=zero`, overwrite-grade) and the
  CT is replaced by a pristine, unprovisioned stopped stub: the GUI keeps
  a Start-able object while the stopped sandbox holds nothing from the
  previous session. `CLOBBER=off` skips the wipe.
- **Ownership-guarded** — every destroy or clobber first verifies the CT
  carries this script's ownership tag (`vibe-sandbox`) and the sandbox
  hostname. A same-ID collision — another system squatting on the CTID,
  by design or by operator error — aborts loudly instead of being
  destroyed. In the GUI, a refused check aborts the task: it fails closed.
- **Self-updating** — the script is installed by hand, so local copies
  drift; build paths (`up`, GUI Start) sha256-check against the copy on
  `main`, auto-install the current version (previous copy kept beside
  the script), and re-run once. `AUTO_UPDATE=off` disables; the `update`
  subcommand does it on demand.

## Requirements

- Proxmox VE 8.x; run on the host as root (uses `pct` / `pveam` / `pvesm`).
- A bridge with DHCP (default `vmbr0`).
- A storage pool for the rootfs (default `local-lvm`).
- Internet access from the host (the build downloads the container
  template, the toolchain, and the Vibe CLI).
- No SSH key needed in advance: the script generates a dedicated keypair on
  the first `up` and retains it at `/root/.vibe-sandbox-ssh`.

## Quick start (step by step)

Every command below runs in a root shell on the Proxmox VE host itself.
Open the host console or SSH into it, then:

```bash
sudo -i
```

### 1. Download the script to the host

```bash
curl -fsSL https://raw.githubusercontent.com/itsfja/mistral-sandbox/main/vibe-sandbox.sh -o /root/vibe-sandbox.sh
chmod +x /root/vibe-sandbox.sh
```

Check it landed and works — this prints the built-in help, nothing else:

```bash
ls -l /root/vibe-sandbox.sh    # must show -rwx... (an x in the permissions)
/root/vibe-sandbox.sh          # prints usage; no side effects
```

Prefer git? `git clone https://github.com/itsfja/mistral-sandbox.git`
and use the script from the checkout; every later step is identical.

The script also keeps itself current: every `up` (and every GUI Start)
sha256-checks against the copy on `main` and self-updates if the local
one is stale — the previous copy is kept at
`/root/vibe-sandbox.sh.bak`. `AUTO_UPDATE=off` disables it; see
[Self-update](#self-update).

### 2. Add your Mistral API key (one time)

Create a key at chat.mistral.ai (Code > Vibe CLI), then store it on the
host — replacing `paste_your_key_here` with the real key:

```bash
printf 'MISTRAL_API_KEY=paste_your_key_here\n' > /root/.vibe-sandbox.env
chmod 600 /root/.vibe-sandbox.env
```

Check it — exactly one line starting with `MISTRAL_API_KEY=`:

```bash
cat /root/.vibe-sandbox.env
```

Never paste the real key anywhere except this file — not into issues, PRs,
chats, or screenshots. If you skip this step entirely, builds still work,
but the first `vibe` launch inside the sandbox will fall back to an
interactive sign-in.

### 3. Check three host settings (two minutes)

```bash
pct list       # CT 1042 must not already exist; if it does, pick another: CTID=1043
pvesm status   # find your rootfs storage name; default expected: local-lvm
ip -br link show type bridge    # list the bridges that exist; default expected: vmbr0
```

Then confirm the bridge actually carries working networking. Best signal:
what your existing CTs already use (each line shows
`<file>: net0: ...bridge=<name>...`):

```bash
grep -H net0 /etc/pve/lxc/*.conf 2>/dev/null || echo "no existing CTs — use the DHCP probe below"
```

That check only means something if you already have CTs. On a fresh node
with none, or if the grep printed nothing:

- Bridges are rebuilt from `/etc/network/interfaces` at boot, so check
  what PVE is configured to create there:
  `grep -E '^iface|bridge-ports' /etc/network/interfaces`.
- Probe the candidate bridge for a DHCP server without creating any CT:

  ```bash
  timeout 60 dhclient -1 -d -sf /bin/true -lf /dev/null -pf /tmp/dhcptest.pid vmbr0 \
    && echo "DHCP reachable on vmbr0" || echo "no DHCP answer on vmbr0"
  ```

  One real DHCPDISCOVER is sent (a DHCP server may briefly hold the lease
  it offers), but the offered address is never applied (`-sf /bin/true`)
  and the probe exits on its own. If `dhclient` is not installed:
  `apt install isc-dhcp-client`. A timeout here predicts the
  `no IP` build failure later — fix DHCP on that network first.
- Or skip the probe entirely: run `up` and treat its
  `container started but no IP` error as the check. That failure is
  benign — remove the half-built CT with `purge`, fix the bridge/DHCP,
  and run `up` again.

If your storage or network bridge differ from the defaults, pass them on
the command line (with every command you run):

```bash
STORAGE=my-pool BRIDGE=vmbr1 /root/vibe-sandbox.sh up
```

### 4. Build the sandbox

```bash
/root/vibe-sandbox.sh up
```

The first run downloads the container template, generates the retained
SSH keypair, provisions the toolchain and Vibe CLI, and auto-deploys the
GUI hookscript shim — expect a few minutes. It ends with `sandbox ready.`
followed by the ssh line. If you do not see both lines, it failed: read the
message above them and check Troubleshooting below.

### 5. Get inside

```bash
ssh -i /root/.vibe-sandbox-ssh root@$(/root/vibe-sandbox.sh ip)
```

The IP is the one `up` printed; `/root/vibe-sandbox.sh ip` shows it again
any time. Once inside, confirm the tooling:

```bash
vibe --version    # the CLI is installed
vibe              # start a session; /whoami shows which credentials are in use
```

Or work from your desktop instead of the host: see
[From your desktop (export)](#from-your-desktop-export) below.

Other doors in and out:

- `/root/vibe-sandbox.sh shell` — run on the **host**, it drops into a
  root shell in the CT (`pct enter`, no password).
- The Proxmox GUI **console** is the one door that never opens: the
  sandbox has no root password (root ships locked, the script never
  sets one, and root SSH is key-only), so the console login prompt
  refuses everything, by design. Use ssh or `shell`.

### 6. When you are done

```bash
/root/vibe-sandbox.sh down
```

The disk is clobbered and the sandbox is parked as a fresh, stopped stub:
nothing from your session is recoverable from it. Your API key store and
SSH keypair stay on the host. The next session is either `up` again, or
just right-click Start on the stub in the Proxmox GUI. To remove the CT
from the tree entirely, use `purge` instead.

## From your desktop (export)

Only the build (`up`) and teardown (`down`) have to run on the PVE
console; your day-to-day ssh sessions can run from your desktop. After
`up`:

```bash
/root/vibe-sandbox.sh export
```

writes a desktop bundle to `/root/vibe-sandbox-export` (overridable:
`EXPORT_DIR`): a copy of the sandbox keypair, an `ssh-config` snippet
(`ssh vibe-sandbox`), and a README.txt with per-OS instructions
(Linux/macOS, Windows built-in OpenSSH, and a PuTTY `.ppk` conversion).
It prints the `scp` command to fetch the tarball from your desktop
(host SSH must be reachable from your LAN), then:

```text
mkdir -p ~/.ssh && chmod 700 ~/.ssh          # Linux/macOS
cp vibe-sandbox vibe-sandbox.pub ~/.ssh/
cat ssh-config >> ~/.ssh/config
ssh vibe-sandbox
```

### Fix the IP on your DHCP server (recommended)

The sandbox gets its address over DHCP, so the IP can change on every
rebuild — but the **MAC address is permanent**: the script retains it on
the host (default `/root/.vibe-sandbox.mac`, like the keypair) and pins it
on every rebuild. So fix the IP once on whatever hands out addresses
(router, pfSense/OPNsense, Pi-hole, Windows DHCP...): create a DHCP
reservation for the sandbox MAC, and the same IP comes back for every
future rebuild — `ssh vibe-sandbox` then works forever without touching
your ssh config again.

The retained MAC is **locally administered** (`02:...`, the
locally-administered bit set — deliberate, so it never squats on a
real vendor OUI). Some routers flag such MACs with a
"private MAC"/"unknown manufacturer" warning on the device; that is
cosmetic — the MAC is stable and pinned on every rebuild, so the
reservation holds. If your router genuinely objects, pin a
universally-administered MAC instead: overwrite the retained store
(`printf 'xx:xx:xx:xx:xx:xx\n' > /root/.vibe-sandbox.mac`, durable —
every later command uses it), or pass `CT_MAC=xx:xx:xx:xx:xx:xx` per
command.

Find the MAC with any of:

```bash
pct config 1042 | grep net0        # hwaddr=... on the host
cat /root/.vibe-sandbox.mac        # the retained MAC store
```

`export` also prints it and lists it in the bundle README.txt.

Notes:

- **The keypair is permanent**: one export unlocks every future rebuild.
  Only the IP embedded in `ssh-config` can go stale after each rebuild —
  re-run `export`, or avoid it entirely with the DHCP reservation above
  (the MAC it binds is retained across rebuilds, so the reservation holds
  forever).
- `export` requires a running sandbox (it embeds the current IP) and the
  managed keypair; with an `SSH_PUBKEY` override, export your own key
  yourself — the script will not copy keys it does not manage.
- Honest cost: the private key then also exists in the host's export dir
  and on your desktop. That is the point of the feature, but it means the
  key no longer lives only on the host — delete the export dir after
  fetching the tarball (the bundle README says how).

## GUI-driven lifecycle (Proxmox right-click)

With `HOOK=on` (the default), the sandbox CT carries a `pct` hookscript, so
the Proxmox GUI becomes the front end:

```mermaid
flowchart TD
    S["GUI: right-click Start"] --> PS1["pre-start hook:<br/>guard + destroy + recreate fresh"]
    PS1 --> PVEB["PVE boots the NEW container"]
    PVEB --> PS2["post-start hook:<br/>provision + inject credentials<br/>ssh line goes to the task log"]
    T["GUI: right-click Stop / Shutdown"] --> PR2["post-stop hook:<br/>guard + clobber rootfs + park fresh stub"]
    R["GUI: right-click Restart"] --> PR2
    PR2 --> S
```

| GUI action | What actually happens |
| --- | --- |
| Start | fresh rebuild from template, then provisioning; the Start task stays busy until provisioning finishes — open its log for the `ssh -i ...` line |
| Stop / Shutdown | rootfs clobbered (`CLOBBER`), CT replaced by a pristine stopped stub; the GUI keeps a Start-able object holding nothing from the session |
| Restart | stop phases, then start phases: a fresh rebuild |
| Snapshot / Clone / Migrate / Backup / Console | **not trappable** (no hook phase) — harmless, since the next Start purges everything, but they cannot be blocked per-CT |

CLI and hooks coexist: a hook phase fires from *inside* the `pct` call
that triggered it. When `up` or `down` triggers one (`up` starts the CT,
`down` stops it), that CLI operation already holds the serial lock and
does the phase's work itself — the hook passes through with a one-line
notice. When the GUI triggers the phase, the hook takes the lock and
does the work. A hook phase therefore never aborts a CLI build with
"another operation is running"; it only ever guards the CT.

Honest caveats:

- **Test on your PVE build first.** The pre-start hook recreates the CT
  while PVE is mid-Start on the same vmid. It works because the recreated
  config and disk volid are identical (same vmid, same storage), but it is
  the piece most sensitive to PVE updates.
- **Clobber levels.** `discard` is instant on SSDs and defeats casual and
  software-level recovery, but relies on the drive honoring TRIM — it is
  not guaranteed against chip-level forensics. `zero` is overwrite-grade
  at the cost of a few minutes per stop. Neither protects the *host's* key
  store: if physical theft is in your threat model, encrypt the PVE root
  VG with LUKS, and rely on the sandbox's dedicated, instantly revocable
  API key.

## Ownership guard

The script destroys and wipes a fixed CTID on every rebuild, so it refuses
to touch any CT it cannot prove it owns. Ownership = the CT carries both
the sandbox hostname (`vibe-sandbox`) and the ownership tag
(`vibe-sandbox`, both overridable) on its config:

- **Created by this script** — the tag is set automatically at `pct create`;
  nothing to do.
- **Legacy sandbox from an older script version** (no tag) — recognized and
  auto-tagged, but only if it also carries the managed hookscript.
- **Anything else at that ID** — your wordpress CT, someone's test box, a
  mis-set `CTID` — every `up`, `down`, `purge`, and GUI hook aborts with
  `refusing to touch CT <id>` and states what to do: move the CT or pick
  another `CTID`. Tag it manually only if you are certain it is an old
  sandbox: `pct set <id> --tags vibe-sandbox`.

The guard fails closed: in the GUI, a refused Start or Stop aborts the task
with the refusal message in the task log rather than touching the CT.

## Troubleshooting

- `no debian-12 template found; set TEMPLATE manually` — the host's
  template list is empty. Run `pveam update`, then find the name with
  `pveam available --section system` and download it with
  `pveam download local <name>`; or set `TEMPLATE=local:vztmpl/<name>`.
- `container started but no IP (check vmbr0/DHCP)` — the bridge has no
  DHCP server handing out addresses. Fix DHCP on that network, or create
  a bridge that has one, and pass `BRIDGE=<name>`. The step-3 DHCP probe
  can confirm this before you build again.
- `must run as root` or `permission denied` — you are not root. `sudo -i`
  first; every command in Quick start assumes root.
- `curl` failed to download the script — check the host's internet:
  `curl -I https://github.com` should return HTTP 200.
- `another vibe-sandbox operation is running` — a build is in progress;
  the script refuses to run two at a time by design. Wait for it to
  finish (or check `ps aux | grep vibe-sandbox`).
- `hookscript error ... on pre-start` at the end of a CLI `up`, right
  after the CT is created — a script from before the hook-lock fix:
  the pre-start hook demanded the serial lock while `up` itself held
  it, aborting the very start it was part of. Update the script
  (`update` subcommand, or the step-1 `curl` one-liner) and re-run
  `up`: the half-built CT is destroyed first and the rebuild proceeds.
- `up` aborts right after the Vibe installer's `[ERROR] Your PATH does
  not include ...` (no `sandbox ready.` line) — a script from before
  the provisioning PATH fix: provisioning died when the installer
  exited nonzero over the missing `~/.local/bin` PATH, so the CT was
  left WITHOUT credentials (`/root/.vibe/.env` never injected).
  Update the script and re-run `up` for a clean rebuild; the
  half-provisioned CT is destroyed first.
- `clobber: blkdiscard failed` — your rootfs sits on rotational storage;
  use `CLOBBER=zero` for overwrite-grade wiping.
- `refusing to touch CT <id>: it is not this script's sandbox` — the
  ownership guard fired: something that is not a tagged, sandbox-hostnamed
  CT sits at that ID. Move it or set `CTID` to a free ID; only if you are
  certain it is an old sandbox, tag it manually:
  `pct set <id> --tags vibe-sandbox`.
- `400 Parameter verification failed. ostemplate: value may only be 255
  characters long` — an older script version captured the template
  download's progress log into the template name on the first run (before
  the template was cached). Update the script (the step-1 `curl` one-liner
  again) and re-run `up`: the downloaded template is kept, so the retry
  skips the download and builds normally.
- `ssh vibe-sandbox` connects to nothing after a rebuild — the IP in your
  ssh config went stale (DHCP). Re-run `export` on the host and re-fetch,
  or edit the `HostName` line in your ssh config; the key itself is still
  valid, so only the IP needs changing. To make it permanent, set a DHCP
  reservation for the sandbox MAC (retained across rebuilds): see
  [Fix the IP on your DHCP server](#fix-the-ip-on-your-dhcp-server-recommended).
- GUI Start finishes but no ssh line in the task log — the post-start
  hook found no IP or provisioning failed; read the task log output
  above it, and the same checks as the `no IP` case apply.
- `self-check: could not fetch/validate ...` (warning, build continues) —
  the self-update check could not reach `RAW_URL` or the fetched file
  failed `bash -n`; the build proceeds with the current script.
  Harmless on an offline host; otherwise check `RAW_URL`.
- GUI console / `pct console` refuses every login (`Login incorrect`) —
  by design: the sandbox has no root password (root ships locked; the
  script never sets one) and root SSH is key-only. Use
  `ssh -i /root/.vibe-sandbox-ssh root@<ip>` (note the leading dot), or
  run `/root/vibe-sandbox.sh shell` on the host (`pct enter`, no
  password).
- `ssh` says `Identity file ... not accessible` or the shell says
  `vibe-sandbox.sh: command not found` — the key lives at
  `/root/.vibe-sandbox-ssh` (leading dot) and the script is not on
  PATH: use full paths —
  `ssh -i /root/.vibe-sandbox-ssh root@$(/root/vibe-sandbox.sh ip)`.
- Router flags the sandbox device with a "private MAC" warning — the
  retained MAC is locally administered (`02:...`) by design; stable
  across rebuilds, so DHCP reservations hold. To silence it, pin a
  universally-administered MAC:
  `printf 'xx:xx:xx:xx:xx:xx\n' > /root/.vibe-sandbox.mac` (or
  `CT_MAC=...` per command).

## Subcommands

| Command | Action |
| --- | --- |
| `up` | destroy any prior sandbox, rebuild, start, provision, print ssh line |
| `down` | clobber the disk and park a fresh stopped stub (GUI Start-able) |
| `purge` | destroy completely — no stub, gone from the tree |
| `reset` | `down` then `up` — fresh rebuild mid-work |
| `status` | is the sandbox up? CTID, state, IP |
| `ip` | print the current IP (empty if not running) |
| `shell` | drop into a root shell inside the CT |
| `export` | write a desktop bundle (keypair copy + ssh-config + per-OS instructions) to `EXPORT_DIR` |
| `update` | self-update the script from `main` (previous copy kept beside it) |
| `hook` | internal — called by the PVE hookscript shim with (vmid, phase) |

## Self-update

The script is installed by hand, so local copies drift: after a merged
PR, the copy on your host keeps running the old code until you
re-download it. So the script checks itself on every build path (`up`
and GUI Start — the pre-start hook; `status`, `ip`, `shell`, and
`down` stay instant and network-free):

- **How**: sha256 of the running script vs the copy at `RAW_URL` (the
  raw GitHub copy of this file on `main`). No version numbers to bump —
  a different hash means stale.
- **Stale**: the current copy is installed (it must pass `bash -n`
  first), the previous copy is kept beside the script as
  `vibe-sandbox.sh.bak`, the swap is an atomic `mv` (a concurrently
  running instance keeps executing the old file undisturbed), and the
  script re-execs itself once — so the build that noticed the drift
  runs current code.
- **Never blocks**: if the check cannot run (host offline, GitHub down,
  timeout) or the fetched file fails `bash -n`, the script warns on
  stderr and proceeds with the current copy. A stale script never
  fails a build that would otherwise succeed.
- **Controls**: `AUTO_UPDATE=off` disables the automatic check
  entirely; `vibe-sandbox.sh update` performs the update explicitly
  (same backup and validation), regardless of `AUTO_UPDATE`.

Honest caveats:

- This is code that runs as root, fetched over HTTPS from GitHub and
  executed without further review — like the install one-liner in
  step 1, but automatic. The trust boundary is this repo's `main`
  branch: anyone who can push to it can change what runs on your host.
- Hand-edited local copies are overwritten on the next build-path run
  (your edits land in the `.bak`). Patch locally only with
  `AUTO_UPDATE=off`.

## Credential store (rotation and revocation)

Every build pushes `/root/.vibe-sandbox.env` into the fresh container as
`/root/.vibe/.env`, which the Vibe CLI loads automatically on startup.
Rotate or revoke the key from the Mistral console at any time; to rotate
locally, just edit the host file — the next rebuild picks it up. Use a
dedicated key for the sandbox so revoking it never disturbs your other
Mistral usage.

## Configuration

All overridable by environment variables: `CTID`, `CTHOST`, `CORES`,
`RAM_MB`, `SWAP_MB`, `DISK_GB`, `STORAGE`, `BRIDGE`, `TEMPLATE`,
`SSH_PUBKEY` (use an existing key instead of the managed one),
`SSH_KEY_FILE` (where the managed keypair lives), `MAC_FILE` (where the
retained MAC lives), `CT_MAC` (pin a specific MAC instead of the managed
one), `SECRETS_FILE`, `HOOK` (`on`/`off`: GUI lifecycle trapping),
`CLOBBER` (`discard`/`zero`/`off`: post-stop rootfs wipe), `SANDBOX_TAG`
(ownership tag enforced by the guard before any destroy or wipe),
`EXPORT_DIR` (where the desktop bundle is written),
`AUTO_UPDATE` (`on`/`off`: build-path self-check against main), and
`RAW_URL` (where the self-check fetches the current script from).

## Hooks

Place a `provision.sh` beside the script to run extra setup inside each
fresh container after base provisioning (toolchains, repo clones). Keep it
deterministic to keep rebuilds identical. (Unrelated to the PVE
hookscript — this one is your per-use provisioning hook.)

## Auto-rebuild on host boot (optional)

`/etc/cron.d/vibe-sandbox`:

```cron
@root /root/vibe-sandbox.sh up >> /var/log/vibe-sandbox.log 2>&1
```

## Security notes

- No credentials are stored in this repository (see `.gitignore`); the API
  key and the sandbox SSH private key live only on the host (key store and
  `/root/.vibe-sandbox-ssh`) and inside the ephemeral container — until
  you run `export`, after which a copy of the private key also exists on
  your desktop (and in the host's export dir until you delete it).
- The container is unprivileged with nesting enabled.
- Root access to the sandbox is key-only, by construction: the template
  ships root's password locked, the script never sets one, and
  provisioning pins `PermitRootLogin prohibit-password` — so the PVE
  GUI console cannot log in and root SSH accepts only the managed
  keypair (plus `pct enter` from the host).
- Treat the sandbox like a CI job: least-privileged, revocable credentials
  only.
- Clobber protects the stopped CT's disk only. For physical-theft threat
  models, LUKS-encrypt the PVE host and keep the sandbox API key dedicated
  and instantly revocable.
- Destructive operations are ownership-guarded: the script refuses to
  destroy or wipe any CT that does not carry its tag and hostname, and
  the guard fails closed in GUI hooks.
