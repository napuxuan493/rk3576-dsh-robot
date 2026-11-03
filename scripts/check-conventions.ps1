# Light convention checks for rk3576-dsh-robot (Windows).
# Optional: install shellcheck and set SHELLCHECK=1 to lint board/*.sh
$ErrorActionPreference = "Stop"
$Root = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $Root
$failed = 0

function Fail([string]$msg) {
  Write-Host "FAIL: $msg" -ForegroundColor Red
  $script:failed++
}
function Ok([string]$msg) { Write-Host "OK:   $msg" -ForegroundColor Green }

$required = @(
  "README.md",
  "docs/CONVENTIONS.md",
  "board/board-dsh-chat.sh",
  "board/board-dsh-pair.sh",
  "board/board-dsh-pair-url.sh",
  "board/board-voice-once.sh",
  "board/board-dsh.env.example",
  "board/hdmi-emotion-ui/emotion_fb.py",
  "windows/dsh-voice-bridge/server.mjs",
  "windows/dsh-voice-bridge/start.ps1",
  "windows/dsh-voice-bridge/env.example",
  "windows/dsh-voice-bridge/package.json"
)
foreach ($rel in $required) {
  if (Test-Path (Join-Path $Root $rel)) { Ok "exists $rel" }
  else { Fail "missing $rel" }
}

# No tracked .env
$trackedEnv = git ls-files "*.env" ".env" "*/.env" 2>$null | Where-Object { $_ -notmatch '\.env\.example$' }
if ($trackedEnv) {
  Fail "tracked env files: $($trackedEnv -join ', ')"
} else {
  Ok "no tracked .env"
}

# Shebangs + SCRIPT_DIR on key board scripts
$keyScripts = @(
  "board/board-dsh-chat.sh",
  "board/board-dsh-pair.sh",
  "board/board-dsh-pair-url.sh",
  "board/board-voice-once.sh",
  "board/board-tts-pull.sh",
  "board/board-greet.sh"
)
foreach ($rel in $keyScripts) {
  $path = Join-Path $Root $rel
  if (-not (Test-Path $path)) { Fail "missing $rel"; continue }
  $lines = Get-Content -LiteralPath $path -TotalCount 30
  $head = $lines[0]
  if ($head -notmatch '^#!/') { Fail "$rel missing shebang" } else { Ok "$rel shebang" }
  $body = Get-Content -Raw -LiteralPath $path
  if ($body -notmatch 'SCRIPT_DIR=') { Fail "$rel missing SCRIPT_DIR pattern" }
  else { Ok "$rel SCRIPT_DIR" }
}

# All board/*.sh should have a shebang
Get-ChildItem (Join-Path $Root "board") -Filter "*.sh" -File | ForEach-Object {
  $h = (Get-Content -LiteralPath $_.FullName -TotalCount 1)
  if ($h -notmatch '^#!/') { Fail "$($_.Name) missing shebang" }
}
Get-ChildItem (Join-Path $Root "board\hdmi-emotion-ui") -Filter "*.sh" -File -ErrorAction SilentlyContinue | ForEach-Object {
  $h = (Get-Content -LiteralPath $_.FullName -TotalCount 1)
  if ($h -notmatch '^#!/') { Fail "hdmi-emotion-ui/$($_.Name) missing shebang" }
}

# package.json type module + start script
$pkgPath = Join-Path $Root "windows\dsh-voice-bridge\package.json"
$pkg = Get-Content -Raw -LiteralPath $pkgPath | ConvertFrom-Json
if ($pkg.type -ne "module") { Fail "package.json type must be module" } else { Ok "package.json type=module" }
if (-not $pkg.scripts.start) { Fail "package.json missing scripts.start" } else { Ok "package.json scripts.start" }

if ($env:SHELLCHECK -eq "1") {
  $sc = Get-Command shellcheck -ErrorAction SilentlyContinue
  if (-not $sc) {
    Write-Host "WARN: SHELLCHECK=1 but shellcheck not on PATH" -ForegroundColor Yellow
  } else {
    & shellcheck (Get-ChildItem (Join-Path $Root "board") -Filter "*.sh" -File).FullName
    if ($LASTEXITCODE -ne 0) { Fail "shellcheck reported issues" } else { Ok "shellcheck clean" }
  }
}

if ($failed -gt 0) {
  Write-Host "`n$failed check(s) failed." -ForegroundColor Red
  exit 1
}
Write-Host "`nAll convention checks passed." -ForegroundColor Green
exit 0
