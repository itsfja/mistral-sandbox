# vscode-connect.ps1: open VS Code straight into the vibe sandbox,
# refreshing the desktop ssh entry first, so no manual export fetching
# after rebuilds. Companion to vibe-sandbox.sh
# (https://github.com/itsfja/mistral-sandbox).
#
# Usage (Windows 10+, PowerShell; ssh and scp are built in):
#   $env:PVE_HOST = 'root@192.168.3.188'
#   .\vscode-connect.ps1              # opens /root
#   .\vscode-connect.ps1 /root/work    # other folder
#
# Required env var:
#   PVE_HOST    Proxmox host to reach over ssh, e.g. root@192.168.3.188
#               (needs an account that can read the sandbox key there,
#               root by default, and the host reachable from your LAN)
# Optional env overrides (set before running):
#   PVE_SCRIPT  path of vibe-sandbox.sh on the host (default /root/vibe-sandbox.sh)
#   PVE_KEY     path of the managed sandbox private key on the host (default /root/vibe-sandbox-ssh)
#   SSH_ALIAS   desktop ssh alias for the sandbox (default vibe-sandbox)
#
# Per run: same flow as vscode-connect.sh. See that script's header or the
# README section 'Coding from the sandbox in VS Code (Remote-SSH)'.

$PveHost   = "$(if ($env:PVE_HOST)   { $env:PVE_HOST }   else { '' })"
$PveScript = "$(if ($env:PVE_SCRIPT) { $env:PVE_SCRIPT } else { '/root/vibe-sandbox.sh' })"
$PveKey    = "$(if ($env:PVE_KEY)    { $env:PVE_KEY }    else { '/root/vibe-sandbox-ssh' })"
$SshAlias  = "$(if ($env:SSH_ALIAS)  { $env:SSH_ALIAS }  else { 'vibe-sandbox' })"
$Workspace = if ($args.Count -gt 0 -and $args[0]) { "$($args[0])" } else { '/root' }
if (-not $Workspace.StartsWith('/')) { $Workspace = '/' + $Workspace }

$SshDir     = Join-Path $env:USERPROFILE '.ssh'
$KeyFile    = Join-Path $SshDir 'vibe-sandbox'
$ConfigFile = Join-Path $SshDir 'config'
$MarkBegin  = '# BEGIN vibe-sandbox (managed by vscode-connect.ps1; do not edit between markers)'
$MarkEnd    = '# END vibe-sandbox'

function Die([string]$msg) { Write-Host "vscode-connect: $msg" -ForegroundColor Red; exit 1 }
function Note([string]$msg) { Write-Host "vscode-connect: $msg" }

function Probe {
  ssh -o BatchMode=yes -o ConnectTimeout=5 $SshAlias true 2>$null | Out-Null
  return ($LASTEXITCODE -eq 0)
}

function Launch {
  Note "opening VS Code in ssh-remote+$SshAlias$Workspace ..."
  Note "first connect after a rebuild downloads vscode-server; the Mistral Vibe extension reinstalls itself when listed in remote.SSH.defaultExtensions (README: desktop setup, step 4), else one 'Install in SSH: $SshAlias' click."
  code --folder-uri "vscode-remote://ssh-remote+$SshAlias$Workspace"
  exit $LASTEXITCODE
}

if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
  Die "ssh not found; Settings > Apps > Optional Features > OpenSSH Client, then reopen the terminal"
}
if (-not (Get-Command code -ErrorAction SilentlyContinue)) {
  Die "'code' CLI not found; in VS Code: Command Palette > 'Shell Command: Install code command in PATH'"
}
if (-not $PveHost) {
  Die "PVE_HOST is not set, e.g. `$env:PVE_HOST = 'root@192.168.3.188'; .\vscode-connect.ps1 (transient: this window only)`n  or make it permanent: [Environment]::SetEnvironmentVariable('PVE_HOST', 'root@192.168.3.188', 'User'), then open a new window"
}

# --- fast path: alias already works ------------------------------------
if (Probe) { Launch }

# --- stale path: refresh from the host ---------------------------------
Note "ssh $SshAlias failed (stale IP after a rebuild?), refreshing from $PveHost ..."

$newIp = (ssh $PveHost "$PveScript ip" | Select-Object -First 1)
if ($LASTEXITCODE -ne 0) { Die "could not reach the Proxmox host at $PveHost" }
if (-not $newIp) { Die "the sandbox is not running (no IP). Run '$PveScript up' on the Proxmox host first." }
Note "current sandbox IP: $newIp"

New-Item -ItemType Directory -Force -Path $SshDir | Out-Null
if (-not (Test-Path $KeyFile)) {
  scp -q "${PveHost}:$PveKey" $KeyFile
  if ($LASTEXITCODE -ne 0) { Die "could not fetch the sandbox key from ${PveHost}:$PveKey" }
  # private key readable by this user only (Windows OpenSSH checks ACLs)
  icacls $KeyFile /inheritance:r 2>$null | Out-Null
  icacls $KeyFile /grant:r "$($env:USERNAME):F" 2>$null | Out-Null
  Note "sandbox keypair installed once at $KeyFile (it is permanent; rebuilds reuse it)."
}

# Rewrite ONLY the managed block: drop the previous managed block and any
# legacy unmarked 'Host vibe-sandbox' block left by the manual export flow,
# keep every other host entry untouched, then append a fresh marked block.
$block = @"
$MarkBegin
Host $SshAlias
    HostName $newIp
    User root
    IdentityFile ~/.ssh/vibe-sandbox
    # disposable sandbox: every rebuild mints a FRESH host key, so strict
    # known-hosts checking would block the 2nd+ rebuild connect; scoped to
    # this Host alias only.
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
$MarkEnd
"@

$conf = ''
if (Test-Path $ConfigFile) { $conf = Get-Content -Raw $ConfigFile }
$conf = [regex]::Replace($conf, '(?s)' + [regex]::Escape($MarkBegin) + '.*?' + [regex]::Escape($MarkEnd) + '\r?\n?', '')
$conf = [regex]::Replace($conf, '(?ms)^Host ' + [regex]::Escape($SshAlias) + '[ \t]*\r?\n.*?(?=^(?:Host|Match)[ \t]|\z)', '')
if ([string]::IsNullOrWhiteSpace($conf)) { $conf = $block } else { $conf = $conf.TrimEnd("`r", "`n") + "`r`n" + $block }
Set-Content -Path $ConfigFile -Value $conf -Encoding Ascii
Note "ssh config updated: Host $SshAlias -> $newIp (only the managed block was touched)."

# A just-started sandbox may still be finishing provisioning; wait a bit.
$ok = $false
foreach ($i in 1..15) {
  if (Probe) { $ok = $true; break }
  Start-Sleep -Seconds 2
}
if (-not $ok) { Die "ssh $SshAlias still fails after refresh. Check the network/DHCP, or run '$PveScript status' on the Proxmox host." }
Launch
