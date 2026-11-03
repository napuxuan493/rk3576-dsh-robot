# Start DSH LAN voice bridge (run while DSH Desktop is up).
# Default listen: http://0.0.0.0:43128  → board http://192.168.137.1:43128
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$run = Join-Path $env:USERPROFILE "dsh-voice-bridge"
New-Item -ItemType Directory -Force -Path $run | Out-Null
# Sync from script dir → run dir (skip when already launching from %USERPROFILE%\dsh-voice-bridge)
$srcServer = Join-Path $here "server.mjs"
$dstServer = Join-Path $run "server.mjs"
if ((Resolve-Path $here).Path -ne (Resolve-Path $run -ErrorAction SilentlyContinue).Path) {
  Copy-Item -Force $srcServer $dstServer
  Copy-Item -Force (Join-Path $here "start.ps1") (Join-Path $run "start.ps1") -ErrorAction SilentlyContinue
} elseif (Test-Path $srcServer) {
  # same folder — already the run copy
}

$env:DSH_VOICE_BIND = if ($env:DSH_VOICE_BIND) { $env:DSH_VOICE_BIND } else { "0.0.0.0" }
$env:DSH_VOICE_PORT = if ($env:DSH_VOICE_PORT) { $env:DSH_VOICE_PORT } else { "43128" }
$env:DSH_RPC_BASE = if ($env:DSH_RPC_BASE) { $env:DSH_RPC_BASE } else { "http://127.0.0.1:43127" }
$env:DSH_VOICE_MODE_BASE = if ($env:DSH_VOICE_MODE_BASE) { $env:DSH_VOICE_MODE_BASE } else { "http://127.0.0.1:43129" }
# Optional shared token (board normally uses dsh_mobile cookie instead):
# $env:DSH_VOICE_BRIDGE_TOKEN = "..."
# Force WAV via Windows SAPI (board aplay-friendly; lower quality than Edge):
# $env:DSH_TTS_FORCE_WAV = "1"

$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
  $candidates = @(
    "$env:LOCALAPPDATA\dsh-desktop\node-runtime\node.exe",
    "$env:APPDATA\dsh-desktop\node-runtime\node.exe",
    "C:\Program Files\DSH Desktop\resources\node\node.exe"
  )
  foreach ($c in $candidates) {
    if (Test-Path $c) { $node = $c; break }
  }
}
if (-not $node) { throw "node not found — install Node 18+ or start from DSH Desktop toolchain" }
$nodeExe = if ($node.Source) { $node.Source } else { $node }

Write-Host "Starting bridge with $nodeExe"
Write-Host "Listen http://$($env:DSH_VOICE_BIND):$($env:DSH_VOICE_PORT)  (board: http://192.168.137.1:$($env:DSH_VOICE_PORT))"
Set-Location $run
& $nodeExe .\server.mjs
