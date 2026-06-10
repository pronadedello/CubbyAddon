# Cubby addon live-installer.
# Run from PowerShell:
#   iwr <BaseUrl>/install.ps1 | iex
#
# Polls every second and mirrors the latest Cubby build into your WoW Classic
# Era AddOns folder. Press Ctrl+C to stop. Run /reload in WoW after it reports
# an update.

$ErrorActionPreference = 'Stop'

# ---- CONFIG ---------------------------------------------------------------
# Folder (no trailing slash) that serves manifest.json and the addon files.
# Point this at your Caddy rendezvous folder.
$BaseUrl     = 'https://staging.justapoint.org/addons/cubby'
$AddonName   = 'Cubby'
$PollSeconds = 1
# ---------------------------------------------------------------------------

$BaseUrl = $BaseUrl.Trim().TrimEnd('/')
$ParsedBase = $null
if (-not [System.Uri]::TryCreate($BaseUrl, [System.UriKind]::Absolute, [ref]$ParsedBase) `
    -or ($ParsedBase.Scheme -notin 'http','https')) {
  Write-Error "BaseUrl is not a valid absolute http(s) URL: '$BaseUrl'"
  return
}
$ManifestUrl = "$BaseUrl/manifest.json"

# Locate the WoW Classic Era AddOns directory.
$Candidates = @(
  "C:\Program Files (x86)\World of Warcraft\_classic_era_\Interface\AddOns",
  "C:\Program Files\World of Warcraft\_classic_era_\Interface\AddOns"
)
$AddOnsDir = $Candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $AddOnsDir) {
  Write-Error "Could not find a WoW Classic Era AddOns directory. Looked in: $($Candidates -join ', ')"
  return
}

$Dest = Join-Path $AddOnsDir $AddonName
if (-not (Test-Path $Dest)) { New-Item -ItemType Directory -Path $Dest | Out-Null }

Write-Host "Watching $AddonName -> $Dest (polling every $PollSeconds s, Ctrl+C to stop)" -ForegroundColor Cyan

function Get-LocalHash {
  param([string]$Path)
  if (-not (Test-Path $Path)) { return $null }
  try { return (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLower() } catch { return $null }
}

$LastVersion = $null
$FirstPoll   = $true

while ($true) {
  # `$lastUrl` tracks whichever URL we most recently tried, so the catch
  # block below can show the user exactly what failed — invaluable for
  # spotting a mangled BaseUrl or a typo'd file path.
  $lastUrl = $null
  try {
    # Cache-bust the manifest so we always see the freshest push.
    $cb = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $lastUrl = "$ManifestUrl`?cb=$cb"
    $manifest = Invoke-RestMethod -UseBasicParsing -Uri $lastUrl

    if ($manifest.version -and $manifest.version -ne $LastVersion) {
      $stamp = Get-Date -Format 'HH:mm:ss'
      if ($FirstPoll) {
        Write-Host "[$stamp] addon version: $($manifest.version)" -ForegroundColor Yellow
      } else {
        Write-Host "[$stamp] addon version: $LastVersion -> $($manifest.version)" -ForegroundColor Yellow
      }
      $LastVersion = $manifest.version
    }
    $FirstPoll = $false

    $expected = @{}
    foreach ($f in $manifest.files) {
      $expected[$f.name] = $f.hash.ToLower()
      $local = Join-Path $Dest $f.name
      if ((Get-LocalHash $local) -ne $f.hash.ToLower()) {
        # Hash mismatch already gates downloads, and Caddy isn't fronted by
        # a CDN — no version-keyed cache-bust needed (and the `+` in our
        # SemVer-style version makes that query parameter brittle anyway).
        $lastUrl = "$BaseUrl/$($f.name)"
        Invoke-WebRequest -UseBasicParsing -Uri $lastUrl -OutFile $local
        $stamp = Get-Date -Format 'HH:mm:ss'
        Write-Host "[$stamp] updated $($f.name)" -ForegroundColor Green
      }
    }

    # Remove shipped-type files no longer in the manifest. Stays away from
    # anything else the user might have dropped in the addon folder.
    $shipped = '.toc','.lua','.xml','.tga','.blp'
    Get-ChildItem -File -Path $Dest | ForEach-Object {
      if ($shipped -contains $_.Extension.ToLower() -and -not $expected.ContainsKey($_.Name)) {
        Remove-Item $_.FullName -Force
        $stamp = Get-Date -Format 'HH:mm:ss'
        Write-Host "[$stamp] removed $($_.Name) (no longer in manifest)" -ForegroundColor DarkYellow
      }
    }
  } catch {
    $stamp = Get-Date -Format 'HH:mm:ss'
    if ($lastUrl) {
      Write-Host "[$stamp] poll failed at $lastUrl : $_" -ForegroundColor DarkRed
    } else {
      Write-Host "[$stamp] poll failed: $_" -ForegroundColor DarkRed
    }
  }
  Start-Sleep -Seconds $PollSeconds
}
