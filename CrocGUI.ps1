#requires -version 5.1
<# Croc Mini GUI - WinForms (Clipboard only) + Version Button + Auto-Arch
   - Start fragt: Senden | Empfangen
   - Senden: Datei/Ordner waehlen -> sofort "croc send" (OHNE --code), Code aus Zwischenablage
   - Empfangen: Code eingeben -> Ziel Desktop (--yes)
   - Versions-Button: zeigt "local / online", aktualisiert bei Klick
   - Logs: .\logs\CrocGUI.log
   - croc.exe: immer lokal im Skriptordner; PATH nur als Quelle; Auto-Download von GitHub
#>

# --- nur PS 5.1 + STA ---
if ($PSVersionTable.PSVersion.Major -ge 6) {
  Add-Type -AssemblyName System.Windows.Forms
  [System.Windows.Forms.MessageBox]::Show("Bitte mit Windows PowerShell 5.1 starten.","Croc GUI") | Out-Null
  return
}
if ([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA) {
  powershell -NoProfile -ExecutionPolicy Bypass -STA -File $PSCommandPath
  return
}

# --- TLS / Assemblies ---
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
try { Add-Type -AssemblyName System.IO.Compression.FileSystem } catch {}
[System.Windows.Forms.Application]::EnableVisualStyles()

# --- Pfade & Log ---
if ($PSScriptRoot) { $Script:AppDir = $PSScriptRoot }
elseif ($MyInvocation.MyCommand.Path) { $Script:AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
else { $Script:AppDir = Split-Path -Parent ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) }

$Script:CrocPath = Join-Path $Script:AppDir "croc.exe"
$Script:LogDir   = Join-Path $Script:AppDir "logs"
New-Item -ItemType Directory -Path $Script:LogDir -Force -ErrorAction SilentlyContinue | Out-Null
$Script:LogPath  = Join-Path $Script:LogDir "CrocGUI.log"

$sw = New-Object System.IO.StreamWriter($Script:LogPath, $true, [System.Text.Encoding]::UTF8)
$Script:LogWriter = [System.IO.TextWriter]::Synchronized($sw)
$Script:LogWriter.WriteLine("[{0}] ---- CrocGUI gestartet ----", (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")); $Script:LogWriter.Flush()
function Log([string]$m){ try{$Script:LogWriter.WriteLine("[{0}] {1}",(Get-Date).ToString("yyyy-MM-dd HH:mm:ss"),$m);$Script:LogWriter.Flush()}catch{} }

# ---------- GitHub / Version Helpers ----------
function Get-CrocAssetUrl {
  param([ValidateSet('amd64','386','arm64')]$Arch='amd64')
  $api='https://api.github.com/repos/schollz/croc/releases/latest'
  try {
    $r = Invoke-WebRequest -Uri $api -Headers @{ 'User-Agent'='CrocGUI-PS' } -UseBasicParsing -ErrorAction Stop
    $j = $r.Content | ConvertFrom-Json

    $winAssets = @($j.assets) | Where-Object {
      $_.name -match '(?i)windows' -and $_.name -match '\.zip$'
    }

    $candidates = switch ($Arch) {
      'arm64' {
        # NUR ARM64/AARCH64
        $winAssets | Where-Object { $_.name -match '(?i)(^|[^a-z])(arm64|aarch64)([^a-z]|$)' }
      }
      'amd64' {
        # NUR echte 64-bit x86: amd64/x86_64/x64/win64/64-bit
        # UND ARM ausschließen
        $winAssets | Where-Object {
          $_.name -notmatch '(?i)arm' -and
          $_.name -match '(?i)(^|[^a-z])(x86_64|amd64|x64|win64|64bit|64-bit)([^a-z]|$)'
        }
      }
      '386' {
        # 32-bit, 64 ausschließen
        $winAssets | Where-Object {
          $_.name -match '(?i)(^|[^a-z])(386|x86|win32|32bit|32-bit)([^a-z]|$)' -and $_.name -notmatch '(?i)64'
        }
      }
    }

    $asset = $candidates | Select-Object -First 1
    if ($asset) {
      Log ("Gewaehltes Asset ($Arch): " + $asset.name)
      return $asset.browser_download_url
    } else {
      Log "Kein passendes Windows-Asset fuer Arch=$Arch gefunden."
      return $null
    }
  }
  catch {
    Log "GitHub API Fehler: $($_.Exception.Message)"
    return $null
  }
}

function Get-RemoteCrocTag {
  $api='https://api.github.com/repos/schollz/croc/releases/latest'
  try {
    $r = Invoke-WebRequest -Uri $api -Headers @{ 'User-Agent'='CrocGUI-PS' } -UseBasicParsing -ErrorAction Stop
    ($r.Content | ConvertFrom-Json).tag_name
  } catch {
    Log "Get-RemoteCrocTag Fehler: $($_.Exception.Message)"; $null
  }
}
function ConvertTo-Version([string]$tag){
  if ([string]::IsNullOrWhiteSpace($tag)) { return $null }
  $s = $tag.TrimStart('v','V') -replace '[^\d\.].*$',''
  try { return [Version]$s } catch { return $null }
}
function Get-LocalCrocVersion {
  if (-not (Test-Path $Script:CrocPath)) { return $null }
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName=(Resolve-Path $Script:CrocPath).Path; $psi.Arguments='--version'
    $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true
    $p=New-Object System.Diagnostics.Process; $p.StartInfo=$psi; [void]$p.Start(); $p.WaitForExit(3000) | Out-Null
    $out=$p.StandardOutput.ReadToEnd()
    if ($out -match 'v(\d+(?:\.\d+){1,3})') { return [Version]$Matches[1] }
  } catch { Log "Get-LocalCrocVersion Fehler: $($_.Exception.Message)" }
  $null
}

# ---------- Arch-Erkennung (auto, robust) ----------
# Optionales Override: $Script:ForceCrocArch = 'amd64'|'arm64'|'386'  (sonst auto)
$Script:ForceCrocArch = $null

function Get-NativeArch {
  # Liefert: 'amd64' | 'arm64' | '386' (beachtet WOW64)
  $archEnv = if ([string]::IsNullOrEmpty($env:PROCESSOR_ARCHITEW6432)) { $env:PROCESSOR_ARCHITECTURE } else { $env:PROCESSOR_ARCHITEW6432 }
  switch -Regex ($archEnv) {
    '^(AMD64|X64)$' { return 'amd64' }
    '^ARM64$'       { return 'arm64' }
    '^(X86|x86)$'   { return '386' }
    default {
      if ([Environment]::Is64BitOperatingSystem) { return 'amd64' } else { return '386' }
    }
  }
}
function Get-DesiredCrocArch {
  if ($Script:ForceCrocArch) { return $Script:ForceCrocArch }
  try {
    $det = Get-NativeArch
    Log ("Auto-Arch erkannt: {0} (PA={1}; W6432={2})" -f $det, $env:PROCESSOR_ARCHITECTURE, $env:PROCESSOR_ARCHITEW6432)
    return $det
  }
  catch {
    Log "Arch-Erkennung fehlgeschlagen: $($_.Exception.Message)"
    if ([Environment]::Is64BitOperatingSystem) {
      return 'amd64'
    } else {
      return '386'
    }
  }
}


# ---------- Installer / Ensure ----------
function Test-CrocStreams([string]$exePath) {
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName=$exePath; $psi.Arguments='--version'
    $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
    $p = New-Object System.Diagnostics.Process; $p.StartInfo=$psi; [void]$p.Start()
    $p.WaitForExit(4000) | Out-Null
    $out=$p.StandardOutput.ReadToEnd().Trim(); $err=$p.StandardError.ReadToEnd().Trim()
    Log "Probe --version: stdout='$out'; stderr='$err'"
    return ([bool]$out -or [bool]$err)
  } catch { Log "Probe-Fehler: $($_.Exception.Message)"; return $false }
}
function Install-CrocFromGitHub {
  $arch = Get-DesiredCrocArch
  $url  = Get-CrocAssetUrl -Arch $arch
  if (-not $url) { [Windows.Forms.MessageBox]::Show("croc-Version konnte nicht ermittelt werden.","Croc GUI") | Out-Null; return $false }
  try {
    $tmp = Join-Path $env:TEMP "croc_latest.zip"
    Log "Lade croc ($arch): $url"
    Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -Headers @{ 'User-Agent'='CrocGUI-PS' }
    $zip = [IO.Compression.ZipFile]::OpenRead($tmp)
    try {
      $entry = $zip.Entries | Where-Object { $_.FullName -match '(?i)(^|/|\\)croc\.exe$' } | Select-Object -First 1
      if (-not $entry) { throw "croc.exe nicht im Archiv gefunden" }
      $fs = $entry.Open()
      try {
        $out=[IO.File]::Create($Script:CrocPath)
        try { $fs.CopyTo($out) } finally { $out.Dispose() }
      } finally { $fs.Dispose() }
      Log "croc installiert (Download): $Script:CrocPath"
    } finally { $zip.Dispose(); Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    return (Test-CrocStreams (Resolve-Path $Script:CrocPath).Path)
  } catch {
    Log "Download/Install-Fehler: $($_.Exception.Message)"
    [Windows.Forms.MessageBox]::Show("croc-Download fehlgeschlagen.`r`n$($_.Exception.Message)","Croc GUI") | Out-Null
    return $false
  }
}
function Ensure-Croc {
  if (Test-Path $Script:CrocPath) {
    if (Test-CrocStreams (Resolve-Path $Script:CrocPath).Path) { Log "croc vorhanden (lokal, ok): $Script:CrocPath"; return $true }
    Log "lokale croc.exe stumm - ersetze"; Remove-Item $Script:CrocPath -Force -ErrorAction SilentlyContinue
  }
  $cmd = Get-Command croc.exe -ErrorAction SilentlyContinue
  if ($cmd -and (Test-Path $cmd.Source)) {
    try {
      Copy-Item -LiteralPath $cmd.Source -Destination $Script:CrocPath -Force
      Log "croc von PATH nach lokal kopiert: $($cmd.Source) -> $Script:CrocPath"
      if (Test-CrocStreams (Resolve-Path $Script:CrocPath).Path) { return $true }
      Log "kopierte PATH-EXE stumm - entferne"; Remove-Item $Script:CrocPath -Force -ErrorAction SilentlyContinue
    } catch { Log "Kopieren aus PATH fehlgeschlagen: $($_.Exception.Message)" }
  }
  return Install-CrocFromGitHub
}
function Ensure-CrocUpToDate {
  if (-not (Ensure-Croc)) { return $false }
  $vLocal = Get-LocalCrocVersion
  $tag = Get-RemoteCrocTag
  $vRemote = ConvertTo-Version $tag
  if ($vLocal -ne $null -and $vRemote -ne $null -and $vRemote -gt $vLocal) {
    Log "Update noetig: local $vLocal < remote $vRemote"
    return Install-CrocFromGitHub
  }
  return $true
}

# ---------- SEND (Clipboard) ----------
function Start-CrocSendViaClipboard {
  param([string[]]$PathsToSend,[System.Windows.Forms.Form]$Form,[System.Windows.Forms.Label]$CodeLabel)

  Log "Ensure-Croc (Send)"
  if (-not (Ensure-Croc)) { return $null }
  if ($CodeLabel -and -not $CodeLabel.IsDisposed) { $CodeLabel.Text = "warte auf Code ..." }

  # Clipboard vor Start merken (Race vermeiden)
  $beforeClip = $null
  try { $beforeClip = [System.Windows.Forms.Clipboard]::GetText() } catch {}

  $exe=(Resolve-Path $Script:CrocPath).Path
  $args=@('send') + $PathsToSend
  $argStr=($args|%{ if($_ -match '[\s"`]'){'"'+($_ -replace '"','\"')+'"' } else { $_ }}) -join ' '
  Log ("Starte croc (hidden): {0} {1}" -f $exe,$argStr)

  $p = Start-Process -FilePath $exe -ArgumentList $argStr -WorkingDirectory $Script:AppDir -WindowStyle Hidden -PassThru

  # Regexe
  $rx1 = New-Object System.Text.RegularExpressions.Regex '(?i)\bcode(?:\s+is)?\s*:\s*([a-z0-9][a-z0-9\-\._]+)'
  $rxFallback = New-Object System.Text.RegularExpressions.Regex '^(?=.{5,64}$)(?!.*\s)(?=.*-)[a-z0-9][a-z0-9\-\._]+$'
  $tryText = [Func[string,string]]{
    param($t)
    if([string]::IsNullOrWhiteSpace($t)){return $null}
    $m=$rx1.Match($t); if($m.Success){return $m.Groups[1].Value}
    if($rxFallback.IsMatch($t.Trim())){return $t.Trim()}
    foreach($tok in ($t -split '\s+')){ if($rxFallback.IsMatch($tok)){return $tok} }
    return $null
  }
  $updateLbl=[Action[Windows.Forms.Label,string]]{ param($lbl,$text) if($lbl -and -not $lbl.IsDisposed -and -not [string]::IsNullOrWhiteSpace($text)){ $lbl.Text=$text } }

  # Bis zu 30s die Zwischenablage pollen
  $deadline=(Get-Date).AddSeconds(30); $code=$null
  do{
    Start-Sleep -Milliseconds 250
    [Windows.Forms.Application]::DoEvents()
    try{
      $clip=[Windows.Forms.Clipboard]::GetText()
      if($clip -and $clip -ne $beforeClip){
        $maybe=$tryText.Invoke($clip)
        if($maybe){
          $code=$maybe
          Log "[CLIP] $code"
          [Windows.Forms.Clipboard]::SetText($code)  # wieder setzen
          if($Form -and -not $Form.IsDisposed -and $CodeLabel -and -not $CodeLabel.IsDisposed){
            $null=$Form.BeginInvoke($updateLbl,@($CodeLabel,$code))
          }
          break
        }
      }
    }catch{}
  } while(-not $code -and (Get-Date) -lt $deadline)

  $p.add_Exited([EventHandler]{ param($s,$e) try{$Script:LogWriter.WriteLine("[{0}] [EXIT SEND] {1}",(Get-Date).ToString("yyyy-MM-dd HH:mm:ss"),$s.ExitCode);$Script:LogWriter.Flush()}catch{} })
  if(-not $code){ Log "Kein Code aus Zwischenablage (30s)." }
  return $p
}

# ---------- RECEIVE ----------
function Start-CrocReceive {
  param([string]$Code)
  Log "Ensure-Croc (Recv)"; if (-not (Ensure-Croc)) { return $null }
  $exe=(Resolve-Path $Script:CrocPath).Path
  $desktop=[Environment]::GetFolderPath('Desktop')
  $args=@('--yes','--out',$desktop,$Code)
  $argStr=($args|%{ if($_ -match '[\s"`]'){'"'+($_ -replace '"','\"')+'"' } else { $_ }}) -join ' '
  Log ("Empfang starten: {0} {1}" -f $exe,$argStr)
  $p=Start-Process -FilePath $exe -ArgumentList $argStr -WorkingDirectory $Script:AppDir -WindowStyle Hidden -PassThru
  $p.add_Exited([EventHandler]{ param($s,$e) try{$Script:LogWriter.WriteLine("[{0}] [EXIT RECV] {1}",(Get-Date).ToString("yyyy-MM-dd HH:mm:ss"),$s.ExitCode);$Script:LogWriter.Flush()}catch{} })
  return $p
}

# ---------------- UI ----------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "Croc GUI - Minimal"
$form.StartPosition = "CenterScreen"
$form.AutoScaleMode = 'Font'
$form.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $true
$form.ClientSize = New-Object System.Drawing.Size(520,240)
$form.Padding = New-Object System.Windows.Forms.Padding(10)

$panelStart = New-Object System.Windows.Forms.Panel -Property @{Dock='Fill'}
$panelSend  = New-Object System.Windows.Forms.Panel -Property @{Dock='Fill'; Visible=$false}
$panelRecv  = New-Object System.Windows.Forms.Panel -Property @{Dock='Fill'; Visible=$false}
$form.Controls.AddRange(@($panelStart,$panelSend,$panelRecv))

# Versions-Button (oben rechts)
$btnVer = New-Object System.Windows.Forms.Button -Property @{
  Text = "croc: checking..."
  Width = 240; Height = 26
  Location = New-Object System.Drawing.Point(260,10)
}
$panelStart.Controls.Add($btnVer)

# Start
$lblStart = New-Object System.Windows.Forms.Label -Property @{Text="Was moechtest du tun?"; AutoSize=$true; Font=(New-Object System.Drawing.Font("Segoe UI",12,[System.Drawing.FontStyle]::Bold)); Location=(New-Object System.Drawing.Point(10,10))}
$btnStartSend = New-Object System.Windows.Forms.Button -Property @{Text="Senden"; Width=180; Height=44; Location=(New-Object System.Drawing.Point(40,60))}
$btnStartRecv = New-Object System.Windows.Forms.Button -Property @{Text="Empfangen"; Width=180; Height=44; Location=(New-Object System.Drawing.Point(260,60))}
$panelStart.Controls.AddRange(@($lblStart,$btnStartSend,$btnStartRecv))

# Senden
$panelSend.Controls.Add((New-Object System.Windows.Forms.Label -Property @{Text="Senden"; AutoSize=$true; Font=(New-Object System.Drawing.Font("Segoe UI",12,[System.Drawing.FontStyle]::Bold)); Location=(New-Object System.Drawing.Point(10,10))}))
$panelSend.Controls.Add((New-Object System.Windows.Forms.Label -Property @{Text="Auswahl:"; AutoSize=$true; Location=(New-Object System.Drawing.Point(10,56))}))
$lblPicked = New-Object System.Windows.Forms.Label -Property @{Text="-"; AutoSize=$true; Location=(New-Object System.Drawing.Point(75,56))}
$panelSend.Controls.Add($lblPicked)
$panelSend.Controls.Add((New-Object System.Windows.Forms.Label -Property @{Text="Code:"; AutoSize=$true; Location=(New-Object System.Drawing.Point(10,140))}))
$lblCode = New-Object System.Windows.Forms.Label -Property @{Text="-"; AutoSize=$true; Font=(New-Object System.Drawing.Font("Segoe UI",18,[System.Drawing.FontStyle]::Bold)); Location=(New-Object System.Drawing.Point(65,134))}
$panelSend.Controls.Add($lblCode)
$btnCopyCode = New-Object System.Windows.Forms.Button -Property @{Text="Kopieren"; Width=100; Location=(New-Object System.Drawing.Point(400,132))}
$panelSend.Controls.Add($btnCopyCode)
$btnBackFromSend = New-Object System.Windows.Forms.Button -Property @{Text="Zurueck"; Width=100; Location=(New-Object System.Drawing.Point(400,10))}
$panelSend.Controls.Add($btnBackFromSend)

# Empfangen
$panelRecv.Controls.Add((New-Object System.Windows.Forms.Label -Property @{Text="Empfangen"; AutoSize=$true; Font=(New-Object System.Drawing.Font("Segoe UI",12,[System.Drawing.FontStyle]::Bold)); Location=(New-Object System.Drawing.Point(10,10))}))
$panelRecv.Controls.Add((New-Object System.Windows.Forms.Label -Property @{Text="Code eingeben:"; AutoSize=$true; Location=(New-Object System.Drawing.Point(10,56))}))
$txtRecvCode = New-Object System.Windows.Forms.TextBox -Property @{Location=(New-Object System.Drawing.Point(120,52)); Width=260}
$panelRecv.Controls.Add($txtRecvCode)
$btnDoRecv = New-Object System.Windows.Forms.Button -Property @{Text="Empfangen starten"; Width=160; Location=(New-Object System.Drawing.Point(10,90))}
$panelRecv.Controls.Add($btnDoRecv)
$panelRecv.Controls.Add((New-Object System.Windows.Forms.Label -Property @{Text="Ziel: Desktop (--yes)"; AutoSize=$true; Location=(New-Object System.Drawing.Point(180,96))}))
$btnBackFromRecv = New-Object System.Windows.Forms.Button -Property @{Text="Zurueck"; Width=100; Location=(New-Object System.Drawing.Point(400,10))}
$panelRecv.Controls.Add($btnBackFromRecv)

# Navigation
$switchToStart = { $panelSend.Visible=$false; $panelRecv.Visible=$false; $panelStart.Visible=$true }
$switchToSend  = { $panelStart.Visible=$false; $panelRecv.Visible=$false; $panelSend.Visible=$true }
$switchToRecv  = { $panelStart.Visible=$false; $panelSend.Visible=$false; $panelRecv.Visible=$true }
$btnBackFromSend.Add_Click({ $switchToStart.Invoke() })
$btnBackFromRecv.Add_Click({ $switchToStart.Invoke() })

# Version Button Refresh + Click
function Refresh-CrocVersionButton {
  try {
    $vLocal = Get-LocalCrocVersion
    $tag = Get-RemoteCrocTag
    $vRemote = ConvertTo-Version $tag
    $tLocal  = if($vLocal){ "v$($vLocal.ToString())" } else { "-" }
    $tRemote = if($vRemote){ "v$($vRemote.ToString())" } else { "-" }
    $btnVer.Text = "croc: local $tLocal / online $tRemote"
    if ($vLocal -ne $null -and $vRemote -ne $null) {
      if ($vRemote -gt $vLocal) { $btnVer.BackColor = [System.Drawing.Color]::Khaki }
      else { $btnVer.BackColor = [System.Drawing.Color]::PaleGreen }
    } else {
      $btnVer.BackColor = [System.Drawing.SystemColors]::Control
    }
  } catch { $btnVer.Text = "croc: versions unknown" }
}
$btnVer.Add_Click({
  try {
    if (Ensure-CrocUpToDate) {
      Refresh-CrocVersionButton
      [System.Windows.Forms.MessageBox]::Show("croc wurde geprueft/aktualisiert.","Croc GUI") | Out-Null
    } else {
      [System.Windows.Forms.MessageBox]::Show("croc konnte nicht aktualisiert werden.","Croc GUI") | Out-Null
    }
  } catch {
    [System.Windows.Forms.MessageBox]::Show("Fehler beim Aktualisieren.`r`n$($_.Exception.Message)","Croc GUI") | Out-Null
  }
})
$form.Add_Shown({ Refresh-CrocVersionButton })

# Senden-Flow
function Invoke-SendFlow {
  try {
    $files = $null
    $ofd = New-Object System.Windows.Forms.OpenFileDialog -Property @{Title="Datei(en) zum Senden waehlen"; Multiselect=$true}
    if ($ofd.ShowDialog() -eq 'OK' -and $ofd.FileNames.Count -gt 0) { $files = @($ofd.FileNames) }
    else {
      $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
      if ($fbd.ShowDialog() -eq 'OK' -and $fbd.SelectedPath) { $files = @($fbd.SelectedPath) }
    }
    if (-not $files) { Log "Auswahl abgebrochen."; return }
    Log ("Auswahl bestaetigt: " + (($files -join '; ')))
    if ($files.Count -eq 1) { $lblPicked.Text = [IO.Path]::GetFileName($files[0]) } else { $lblPicked.Text = "$($files.Count) Dateien" }
    $switchToSend.Invoke()
    $null = Start-CrocSendViaClipboard -PathsToSend $files -Form $form -CodeLabel $lblCode
  } catch {
    Log "Invoke-SendFlow Fehler: $($_.Exception.Message)"
    [System.Windows.Forms.MessageBox]::Show("Fehler beim Starten des Sendens.`r`n$($_.Exception.Message)","Croc GUI") | Out-Null
  }
}

# Empfangen-Flow
$btnStartSend.Add_Click({ Invoke-SendFlow })
$btnStartRecv.Add_Click({ $switchToRecv.Invoke() })
$btnDoRecv.Add_Click({
  try {
    $code = $txtRecvCode.Text
    if ([string]::IsNullOrWhiteSpace($code)) { [System.Windows.Forms.MessageBox]::Show("Bitte Code eingeben.","Croc GUI") | Out-Null; return }
    $null = Start-CrocReceive -Code $code
    [System.Windows.Forms.MessageBox]::Show("Empfang gestartet. Ziel: Desktop.","Croc GUI") | Out-Null
  } catch { Log "Empfangen-Fehler: $($_.Exception.Message)" }
})

# Kopieren-Button
$btnCopyCode.Add_Click({
  if ($lblCode.Text -and $lblCode.Text -ne "-" -and $lblCode.Text -ne "warte auf Code ...") {
    [System.Windows.Forms.Clipboard]::SetText($lblCode.Text)
  }
})

# Log sauber schliessen
$form.Add_FormClosed({ try{$Script:LogWriter.WriteLine("[{0}] ---- CrocGUI beendet ----",(Get-Date).ToString("yyyy-MM-dd HH:mm:ss"));$Script:LogWriter.Flush();$Script:LogWriter.Dispose()}catch{} })

# Start
[System.Windows.Forms.Application]::Run($form)
