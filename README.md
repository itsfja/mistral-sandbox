# mistral-sandbox

A single-use, auto-rebuild Linux container (LXC) sandbox for Proxmox VE,
provisioned on every build with the current
[Mistral Vibe CLI](https://docs.mistral.ai/vibe/code/cli/install-setup).
A contained environment for letting an AI coding agent work with full
outbound internet access — without handing it your machine.

## Design

- **Single use** — one sandbox at a time (fixed CTID); `down` destroys it
  completely, nothing persists between uses.
- **Auto rebuild on startup** — `up` never resumes an old container: it
  destroys any existing one and rebuilds from the template, so every
  session starts clean.
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

## Requirements

- Proxmox VE 8.x; run on the host as root (uses `pct` / `pveam`).
- A bridge with DHCP (default `vmbr0`).
- A storage pool for the rootfs (default `local-lvm`).
- No SSH key needed in advance: the script generates a dedicated keypair on
  the first `up` and retains it at `/root/.vibe-sandbox-ssh`.

## Usage

```bash
chmod +x vibe-sandbox.sh
./vibe-sandbox.sh up        # rebuild + start + provision; prints ssh line
ssh -i /root/.vibe-sandbox-ssh root@<ip>   # work inside the sandbox
./vibe-sandbox.sh down       # destroy completely
```

The keypair at `/root/.vibe-sandbox-ssh` is retained across rebuilds, so
the same `ssh -i` line works for every session. If you set `SSH_PUBKEY`
instead, your own key is injected and the plain `ssh root@<ip>` line
applies.

Subcommands: `up`, `down`, `reset` (fresh rebuild mid-work), `status`,
`ip`, `shell`.

## Credential store (one-time setup)

Generate an API key at chat.mistral.ai (Code > Vibe CLI), then on the host:

```bash
printf 'MISTRAL_API_KEY=<key>\n' > /root/.vibe-sandbox.env
chmod 600 /root/.vibe-sandbox.env
```

Every `up` pushes this file into the fresh container as `/root/.vibe/.env`,
which the Vibe CLI loads automatically on startup. Rotate or revoke the key
from the Mistral console at any time; to rotate locally, just edit the host
file — the next rebuild picks it up. Verify the active credential source
inside a session with `/whoami` or `/status`.

Use a dedicated key for the sandbox so revoking it never disturbs your
other Mistral usage.

## Configuration

All overridable by environment variables: `CTID`, `CTHOST`, `CORES`,
`RAM_MB`, `SWAP_MB`, `DISK_GB`, `STORAGE`, `BRIDGE`, `TEMPLATE`,
`SSH_PUBKEY` (use an existing key instead of the managed one),
`SSH_KEY_FILE` (where the managed keypair lives), `SECRETS_FILE`.

## Hooks

Place a `provision.sh` beside the script to run extra setup inside each
fresh container after base provisioning (toolchains, repo clones). Keep it
deterministic to keep rebuilds identical.

## Auto-rebuild on host boot (optional)

`/etc/cron.d/vibe-sandbox`:

```cron
@root /root/vibe-sandbox.sh up >> /var/log/vibe-sandbox.log 2>&1
```

## Security notes

- No credentials are stored in this repository (see `.gitignore`); the API
  key and the sandbox SSH private key live only on the host (key store and
  `/root/.vibe-sandbox-ssh`) and inside the ephemeral container.
- The container is unprivileged with nesting enabled.
- Treat the sandbox like a CI job: least-privileged, revocable credentials
  only.
