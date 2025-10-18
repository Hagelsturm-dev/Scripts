<#
.SYNOPSIS
  Lädt die neueste Veeam Backup & Replication (VBR) ISO herunter (via gebündelter curl) und verifiziert MD5/SHA-1.

.PARAMETER OutputDir
  Zielordner.

.PARAMETER Auto
  Ohne Rückfrage ausführen.

.PARAMETER PreferBits
  Bevorzuge BITS vor curl.

.PARAMETER LookbackDays
  Rückwärts-Suchfenster für das Datums-Suffix (Standard 60).

.PARAMETER SkipHash
  Hashprüfung überspringen.

.PARAMETER CurlZipUrl
  Quelle für curl (ZIP). Standard: curl 8.16.0_8 (win64 mingw).

.PARAMETER CurlCacheDir
  Lokaler Cache-Ordner für die gebündelte curl.exe.

.PARAMETER CurlExpectedVersion
  Erwartete curl-Version (z. B. "8.16.0"). Wenn leer, wird aus CurlZipUrl extrahiert.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
  [string]$LatestPageUrl = "https://www.veeam.com/products/downloads/latest-version.html",
  [string]$OutputDir = ".",
  [switch]$Auto,
  [switch]$PreferBits,
  [int]$LookbackDays = 60,
  [switch]$SkipHash,
  [string]$CurlZipUrl = "https://curl.se/windows/dl-8.16.0_8/curl-8.16.0_8-win64-mingw.zip",
  [string]$CurlCacheDir = "$PSScriptRoot\tools\curl",
  [string]$CurlExpectedVersion = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

function Write-Info([string]$m){ Write-Host $m -ForegroundColor Cyan }
function Write-Ok([string]$m){ Write-Host $m -ForegroundColor Green }
function Write-Warn2([string]$m){ Write-Host $m -ForegroundColor Yellow }
function Write-Err2([string]$m){ Write-Host $m -ForegroundColor Red }

# ---------- 1) "Latest"-Infos parsen ----------
function Get-LatestVbrInfo {
  param([string]$Url)
  Write-Info "Abrufen: $Url"
  $headers = @{ 'User-Agent' = 'Mozilla/5.0 PowerShell-VBR' }
  $resp = Invoke-WebRequest -Uri $Url -Headers $headers -ErrorAction Stop
  $html = $resp.Content

  $pattern = '(?is)Veeam\s*Backup\s*&\s*Replication.*?Version\s*:?\s*(?<ver>\d+\.\d+\.\d+\.\d+).*?Date\s+(?<date>[A-Za-z]+\s+\d{1,2},\s+\d{4}).*?MD5:\s*(?<md5>[0-9a-fA-F]{32}).*?SHA-1:\s*(?<sha1>[0-9a-fA-F]{40})'
  $mBlock = [regex]::Match($html, $pattern)

  $verStr = $null; $dateYmd = $null; $md5 = $null; $sha1 = $null
  if ($mBlock.Success) {
    $verStr = $mBlock.Groups['ver'].Value
    $dateStr = $mBlock.Groups['date'].Value
    if ($dateStr) {
      $date = [datetime]::Parse($dateStr, [Globalization.CultureInfo]::InvariantCulture)
      $dateYmd = $date.ToString('yyyyMMdd')
    }
    if ($mBlock.Groups['md5'].Success)  { $md5  = $mBlock.Groups['md5'].Value }
    if ($mBlock.Groups['sha1'].Success) { $sha1 = $mBlock.Groups['sha1'].Value }
  }
  else {
    $mVer = [regex]::Match($html, '(?is)Veeam\s*Backup\s*&\s*Replication.*?Version\s*:?\s*(?<ver>\d+\.\d+\.\d+\.\d+)')
    if (-not $mVer.Success) { throw "Konnte VBR-Block nicht parsen." }
    $verStr = $mVer.Groups['ver'].Value

    $mDate = [regex]::Match($html, '(?i)Date\s+(?<date>[A-Za-z]+\s+\d{1,2},\s+\d{4})')
    if ($mDate.Success) {
      $date = [datetime]::Parse($mDate.Groups['date'].Value, [Globalization.CultureInfo]::InvariantCulture)
      $dateYmd = $date.ToString('yyyyMMdd')
    }
    $mMd5  = [regex]::Match($html, '(?i)MD5:\s*(?<md5>[0-9a-fA-F]{32})'); if ($mMd5.Success)  { $md5  = $mMd5.Groups['md5'].Value }
    $mSha1 = [regex]::Match($html, '(?i)SHA-1:\s*(?<sha1>[0-9a-fA-F]{40})'); if ($mSha1.Success) { $sha1 = $mSha1.Groups['sha1'].Value }
  }

  $major = [int]($verStr.Split('.')[0])
  [pscustomobject]@{ Build=$verStr; Major=$major; DateYmd=$dateYmd; MD5=$md5; SHA1=$sha1 }
}

# ---------- 2) URL-Existenz prüfen ----------
function Test-RemoteFileExists {
  param([Parameter(Mandatory)][uri]$Uri)
  try {
    $req = [System.Net.WebRequest]::Create($Uri)
    $req.Method = "HEAD"; $req.Timeout = 15000; $req.AllowAutoRedirect = $true
    $resp = $req.GetResponse(); $resp.Close(); return $true
  } catch { return $false }
}

# ---------- 3) ISO-URL ermitteln ----------
function Find-VbrIsoUrl {
  param(
    [Parameter(Mandatory)][string]$Build,
    [Parameter(Mandatory)][int]$Major,
    [string]$DateYmd,
    [int]$LookbackDays = 60
  )
  $base = "https://download2.veeam.com/VBR/v$Major/"
  $prefix = "VeeamBackup%26Replication"
  if ($DateYmd) {
    $u = [uri]("$base$prefix`_${Build}_$DateYmd.iso"); if (Test-RemoteFileExists $u) { return $u }
  }
  $today = (Get-Date).Date
  for ($i = 0; $i -le $LookbackDays; $i++) {
    $d = $today.AddDays(-$i).ToString("yyyyMMdd")
    $u = [uri]("$base$prefix`_${Build}_$d.iso")
    if (Test-RemoteFileExists $u) { return $u }
  }
  if ($DateYmd) {
    $rel = [datetime]::ParseExact($DateYmd,'yyyyMMdd',$null)
    for ($j = 1; $j -le 45; $j++) {
      $d = $rel.AddDays(-$j).ToString("yyyyMMdd")
      $u = [uri]("$base$prefix`_${Build}_$d.iso")
      if (Test-RemoteFileExists $u) { return $u }
    }
  }
  return $null
}

# ---------- 4) curl-Version ermitteln/erzwingen ----------
function Get-DesiredCurlVersionFromUrl {
  param([string]$Url)
  if ($Url -match 'curl-(?<ver>[\d\.]+)') { return $matches['ver'] }
  return $null
}

function Get-CurlVersion {
  param([Parameter(Mandatory)][string]$CurlExePath)
  try {
    $out = & $CurlExePath --version 2>$null
    $m = [regex]::Match($out, '^curl\s+([0-9][^\s]*)', 'IgnoreCase')
    if ($m.Success) { return $m.Groups[1].Value }
  } catch {}
  return $null
}

function Ensure-Curl {
    <#
      Stellt IMMER die gebündelte curl bereit (ignoriert System-curl).
      Lädt/aktualisiert, wenn nicht vorhanden oder Version abweicht.
    #>
    [CmdletBinding()]
    param([string]$CurlZipUrl,[string]$CacheDir,[string]$ExpectedVersion)

    if (-not $ExpectedVersion -or $ExpectedVersion.Trim() -eq "") {
      $ExpectedVersion = Get-DesiredCurlVersionFromUrl -Url $CurlZipUrl
    }

    New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
    $cachedCurl = Join-Path $CacheDir "curl.exe"

    $needDownload = $true
    if (Test-Path $cachedCurl) {
      $have = Get-CurlVersion -CurlExePath $cachedCurl
      if ($ExpectedVersion) {
        if ($have -and $have.StartsWith($ExpectedVersion)) { $needDownload = $false }
      } else {
        if ($have) { $needDownload = $false }
      }
    }

    if ($needDownload) {
      Write-Info "Lade curl ZIP von $CurlZipUrl …"
      $zipPath = Join-Path $CacheDir "curl.zip"
      Invoke-WebRequest -Uri $CurlZipUrl -OutFile $zipPath -UseBasicParsing
      if (-not (Test-Path $zipPath)) { throw "Download des curl ZIP fehlgeschlagen: $CurlZipUrl" }

      Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
      Get-ChildItem -LiteralPath $CacheDir -Force | Where-Object { $_.Name -ne 'curl.zip' } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
      [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $CacheDir)

      $curlExe = Get-ChildItem -Path $CacheDir -Filter "curl.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
      if (-not $curlExe) { throw "curl.exe wurde im ZIP nicht gefunden." }
      Copy-Item -LiteralPath $curlExe.FullName -Destination $cachedCurl -Force
      Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue

      $have = Get-CurlVersion -CurlExePath $cachedCurl
      if ($ExpectedVersion -and (-not $have -or -not $have.StartsWith($ExpectedVersion))) {
        throw "Erwartete curl-Version $ExpectedVersion, gefunden: $have"
      }
      $verText = if ([string]::IsNullOrWhiteSpace($have)) { "unbekannt" } else { $have }
      Write-Ok ("curl bereit: {0} (Version {1})" -f $cachedCurl, $verText)
    }
    else {
      $have = Get-CurlVersion -CurlExePath $cachedCurl
      $verText = if ([string]::IsNullOrWhiteSpace($have)) { "unbekannt" } else { $have }
      Write-Info ("curl aus Cache verwendet: {0} (Version {1})" -f $cachedCurl, $verText)
    }

    return $cachedCurl
}

# ---------- 5) Download via curl ----------
function Invoke-CurlDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CurlPath,
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$DestinationPath
    )
    $destDir = Split-Path -Path $DestinationPath -Parent
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    $args = @('--fail','--location','--continue-at','-','--progress-bar','--output',$DestinationPath,$Url)
    Write-Info "Starte curl Download…"
    $p = Start-Process -FilePath $CurlPath -ArgumentList $args -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0) { throw "curl meldet ExitCode $($p.ExitCode)." }
    if (-not (Test-Path $DestinationPath)) { throw "Zieldatei fehlt nach curl-Download: $DestinationPath" }
    Write-Ok "Download abgeschlossen: $DestinationPath"
    return 0
}

# ---------- 6) Download-Fassade ----------
function Download-File {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)][uri]$Url,
    [Parameter(Mandatory)][string]$OutputDir,
    [switch]$PreferBits
  )
  Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
  $fileName = [System.Web.HttpUtility]::UrlDecode([IO.Path]::GetFileName($Url.AbsolutePath))
  $dest = Join-Path $OutputDir $fileName
  if (Test-Path $dest) { Write-Warn2 "Datei existiert bereits: $dest"; return $dest }

  if ($PSCmdlet.ShouldProcess($Url.AbsoluteUri, "Download nach $dest")) {
    if ($PreferBits) {
      try {
        Write-Info "Download via BITS…"
        Start-BitsTransfer -Source $Url.AbsoluteUri -Destination $dest -DisplayName "VBR ISO $fileName" -Description "Download" -ErrorAction Stop
        if (Test-Path $dest) { Write-Ok "Download abgeschlossen: $dest"; return $dest }
      } catch { Write-Warn2 "BITS fehlgeschlagen: $($_.Exception.Message). Wechsle zu gebündelter curl…" }
    }
    try {
      $curlPath = Ensure-Curl -CurlZipUrl $CurlZipUrl -CacheDir $CurlCacheDir -ExpectedVersion $CurlExpectedVersion
      Write-Info "Benutze gebündelte curl: $curlPath"
      $null = Invoke-CurlDownload -CurlPath $curlPath -Url $Url.AbsoluteUri -DestinationPath $dest
      if (Test-Path $dest) { return $dest }
    } catch { Write-Warn2 "curl-Download fehlgeschlagen: $($_.Exception.Message)" }

    Write-Warn2 "Fallback zu Invoke-WebRequest (ohne schöne Anzeige)…"
    Invoke-WebRequest -Uri $Url -OutFile $dest -UseBasicParsing
    if (Test-Path $dest) { Write-Ok "Download abgeschlossen: $dest"; return $dest }
    throw "Download fehlgeschlagen: $($Url.AbsoluteUri)"
  }
}

# ---------- 7) Hashvergleich ----------
function Compare-Checksums {
  param([Parameter(Mandatory)][string]$FilePath,[string]$ExpectedMD5,[string]$ExpectedSHA1)
  $ok = $true
  if ($ExpectedMD5) {
    $h = Get-FileHash -Path $FilePath -Algorithm MD5
    if ($h.Hash.ToLower() -ne $ExpectedMD5.ToLower()) { Write-Err2 "MD5 stimmt nicht! Erwartet: $ExpectedMD5 | Ist: $($h.Hash)"; $ok=$false }
    else { Write-Ok "MD5 geprüft: $($h.Hash)" }
  } else { Write-Warn2 "Kein erwarteter MD5 – Prüfung übersprungen." }
  if ($ExpectedSHA1) {
    $h = Get-FileHash -Path $FilePath -Algorithm SHA1
    if ($h.Hash.ToLower() -ne $ExpectedSHA1.ToLower()) { Write-Err2 "SHA-1 stimmt nicht! Erwartet: $ExpectedSHA1 | Ist: $($h.Hash)"; $ok=$false }
    else { Write-Ok "SHA-1 geprüft: $($h.Hash)" }
  } else { Write-Warn2 "Kein erwarteter SHA-1 – Prüfung übersprungen." }
  return $ok
}

# ================= MAIN =================
try {
  $info = Get-LatestVbrInfo -Url $LatestPageUrl
  Write-Ok "Neuester VBR-Build: $($info.Build) (Major: v$($info.Major))"
  if ($info.DateYmd) { Write-Info "Veröffentlichungsdatum: $($info.DateYmd)" }
  if ($info.MD5)     { Write-Info "Erwarteter MD5:  $($info.MD5)" }
  if ($info.SHA1)    { Write-Info "Erwarteter SHA1: $($info.SHA1)" }

  $isoUrl = Find-VbrIsoUrl -Build $info.Build -Major $info.Major -DateYmd $info.DateYmd -LookbackDays $LookbackDays
  if (-not $isoUrl) { throw "Keine ISO-URL gefunden für Build $($info.Build) im v$($info.Major)-Zweig." }
  Write-Info "Gefundene ISO-URL: $($isoUrl.AbsoluteUri)"

  $proceed = $Auto
  if (-not $Auto) { $answer = Read-Host "ISO herunterladen? (ja/nein)"; $proceed = ($answer -match '^(ja|j|yes|y)$') }

  if ($proceed) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    $file = Download-File -Url $isoUrl -OutputDir $OutputDir -PreferBits:$PreferBits
    if (-not $file) { throw "Download nicht erfolgreich." }

    if (-not $SkipHash) {
      $ok = Compare-Checksums -FilePath $file -ExpectedMD5 $info.MD5 -ExpectedSHA1 $info.SHA1
      if (-not $ok) { throw "Hashprüfung fehlgeschlagen." }
    } else { Write-Warn2 "Hashprüfung übersprungen (-SkipHash)." }

    Write-Ok "Fertig: $file"
    exit 0
  } else {
    Write-Warn2 "Download abgebrochen."
    exit 2
  }
}
catch {
  Write-Err2 $_.Exception.Message
  exit 1
}
