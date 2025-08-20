<#
.SYNOPSIS
  Generiert, aktualisiert oder entfernt ein AlwaysOn-VPN-User-Tunnel-Profil (VPNv2 CSP) – fest auf SSTP.

.DESCRIPTION
  - Default (Ensure-Set): Erstellt/aktualisiert ein VPNv2-Profil via MDM-Bridge (WMI/CIM).
  - Remove-Set: Entfernt ein bestehendes Profil.
  - Fest verdrahtet: <NativeProtocolType>Sstp</NativeProtocolType>.
  - ProfileXML wird beim Deploy IMMER korrekt ge-escaped (für WMI/CSP-Bridge).
  - Optional: TrustedNetworkDetection (TND), zusätzliche Routen (CIDR), Temp-Beibehalt.
  - Interaktive Abfragen:
      * TrustedNetworkDetection: wird gefragt, wenn leer (Enter = überspringen).
      * Routes: wird gefragt, wenn leer (Enter = keine).
  - Merkt Anmeldedaten: <RememberCredentials>true</RememberCredentials>

.PARAMETER ProfileName
  Eindeutiger Name für das VPN-Profil (alphanumerisch, Bindestriche/Unterstriche).

.PARAMETER ServerFqdn
  FQDN des VPN-Servers (Ensure-Set).

.PARAMETER TrustedNetworkDetection
  DNS-Suffix eines vertrauenswürdigen LANs (Ensure-Set, optional).

.PARAMETER Routes
  Zusätzliche Routen als CIDR (z. B. '192.168.10.0/24','10.50.0.0/16').

.PARAMETER KeepTemp
  Behält den Temp-Ordner und die erzeugte XML nach Deploy bei (zum Debuggen).

.PARAMETER Remove
  Entfernt das Profil (Remove-Set).

.PARAMETER TempPath
  Pfad für temporäre Dateien. Default: $env:TEMP\VPNDeploy

.EXAMPLE
  # Interaktiv TND & Routen abfragen, Erfolgsmeldungen ohne -Verbose sichtbar:
  .\Deploy-AlwaysOnVpn.ps1 -ProfileName MeinVPN -ServerFqdn vpn.contoso.com

.EXAMPLE
  .\Deploy-AlwaysOnVpn.ps1 -ProfileName MeinVPN -ServerFqdn vpn.contoso.com `
    -TrustedNetworkDetection corp.contoso.local -Routes '192.168.10.0/24'

.EXAMPLE
  .\Deploy-AlwaysOnVpn.ps1 -ProfileName MeinVPN -Remove
#>

[CmdletBinding(DefaultParameterSetName = 'Ensure', SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    # ProfileName in beiden Sets mandatory
    [Parameter(Mandatory, Position = 0, ParameterSetName = 'Ensure')]
    [Parameter(Mandatory, Position = 0, ParameterSetName = 'Remove')]
    [ValidatePattern('^[\w\-]+$', 
        ErrorMessage = 'ProfileName darf nur Buchstaben, Zahlen, Bindestriche oder Unterstriche enthalten.')]
    [string]$ProfileName,

    # ServerFqdn nur im Ensure-Set
    [Parameter(Mandatory, Position = 1, ParameterSetName = 'Ensure')]
    [ValidatePattern('^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$', 
        ErrorMessage = 'ServerFqdn muss ein gültiger Hostname sein.')]
    [string]$ServerFqdn,

    # TrustedNetworkDetection optional im Ensure-Set
    [Parameter(Position = 2, ParameterSetName = 'Ensure')]
    [ValidatePattern('^([a-zA-Z0-9-]+\.)*[a-zA-Z0-9-]*$', 
        ErrorMessage = 'TrustedNetworkDetection muss ein gültiges DNS-Suffix sein.')]
    [string]$TrustedNetworkDetection = '',

    # Zusätzliche Routen (CIDR)
    [Parameter(ParameterSetName = 'Ensure')]
    [string[]]$Routes = @(),

    # Temp behalten
    [Parameter(ParameterSetName = 'Ensure')]
    [switch]$KeepTemp,

    # Remove-Schalter definiert Remove-Set
    [Parameter(ParameterSetName = 'Remove')]
    [switch]$Remove,

    # TempPath in beiden Sets optional
    [Parameter()]
    [string]$TempPath = (Join-Path $env:TEMP "VPNDeploy")
)

# --- Konstanten / globale Variablen ---
$NodeCsp    = './Vendor/MSFT/VPNv2'
$Namespace  = 'root\cimv2\mdm\dmmap'
$ClassName  = 'MDM_VPNv2_01'
$InstanceId = $ProfileName -replace ' ', '%20'

# --- Hilfsfunktionen ---

function Assert-Admin {
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw 'Dieses Skript muss als Administrator ausgeführt werden.' }
}

function Assert-MdmBridge {
    if (-not (Get-CimClass -Namespace $Namespace -ClassName $ClassName -ErrorAction SilentlyContinue)) {
        throw "MDM-Bridge (Namespace '$Namespace', Klasse '$ClassName') nicht verfügbar. Gerät MDM-registriert? OS-Version kompatibel?"
    }
}

function Ensure-TempDir {
    param([string]$Path)
    Write-Verbose "Säubere temporären Ordner: $Path"
    if (Test-Path $Path) {
        Remove-Item -Path (Join-Path $Path '*') -Force -Recurse -ErrorAction SilentlyContinue
    } else {
        New-Item -Path $Path -ItemType Directory | Out-Null
    }
}

function Generate-VpnXml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Fqdn,
        [Parameter(Mandatory)][string]$ProfileNameParam,
        [string]$TrustedNet,
        [string[]]$Routes
    )

    Write-Verbose "Erzeuge VPN XML in: $Path"

    $content = @"
<VPNProfile>
  <ProfileName>$ProfileNameParam</ProfileName>
  <NativeProfile>
    <Servers>$Fqdn</Servers>
    <NativeProtocolType>Sstp</NativeProtocolType>
    <Authentication>
      <UserMethod>MSChapv2</UserMethod>
    </Authentication>
    <RoutingPolicyType>SplitTunnel</RoutingPolicyType>
    <DisableClassBasedDefaultRoute>true</DisableClassBasedDefaultRoute>
  </NativeProfile>
  <AlwaysOn>true</AlwaysOn>
"@

    if ($TrustedNet) {
        $content += "  <TrustedNetworkDetection>$TrustedNet</TrustedNetworkDetection>`n"
    }

    # Routen (Top-Level unterhalb von <VPNProfile>)
    if ($Routes -and $Routes.Count -gt 0) {
        foreach ($r in $Routes) {
            if ($r -match '^(\d{1,3}(?:\.\d{1,3}){3})/(\d{1,2})$') {
                $addr   = $Matches[1]
                $prefix = [int]$Matches[2]
                if ($prefix -lt 0 -or $prefix -gt 32) {
                    Write-Warning "Route '$r' hat ungültige PrefixSize ($prefix). Übersprungen."
                    continue
                }
                $content += @"
  <Route>
    <Address>$addr</Address>
    <PrefixSize>$prefix</PrefixSize>
  </Route>
"@
            } else {
                Write-Warning "Ungültiges Route-Format: '$r' (erwartet z. B. 192.168.10.0/24). Route wird übersprungen."
            }
        }
    }

    $content += @"
  <DeviceTunnel>false</DeviceTunnel>
  <RegisterDNS>true</RegisterDNS>
  <RememberCredentials>true</RememberCredentials>
</VPNProfile>
"@

    $content | Out-File -FilePath $Path -Encoding UTF8 -Force
}

function Get-ExistingInstance {
    try {
        return Get-CimInstance -Namespace $Namespace -ClassName $ClassName `
            -Filter "InstanceID='$InstanceId' AND ParentID='$NodeCsp'" -ErrorAction SilentlyContinue
    } catch {
        Write-Verbose "Fehler beim Abfragen vorhandener Instanz(en): $_"
        return $null
    }
}

function Read-ProfileXmlRaw {
    param([Parameter(Mandatory)][string]$Path)
    return Get-Content $Path -Raw -ErrorAction Stop
}

function Escape-ForCsp {
    param([Parameter(Mandatory)][string]$XmlRaw)
    # Escape für die WMI/CSP-Bridge: &, <, >, ", '
    return [System.Security.SecurityElement]::Escape($XmlRaw)
}

function Remove-VpnCsp {
    $existing = Get-ExistingInstance
    if ($null -ne $existing) {
        if ($PSCmdlet.ShouldProcess("VPN-Profil '$ProfileName'", 'Löschen')) {
            try {
                Remove-CimInstance -InputObject $existing -ErrorAction Stop
                Write-Host "✅ VPN-Profil '$ProfileName' wurde gelöscht." -ForegroundColor Green
            } catch {
                Write-Error "Fehler beim Löschen: $_"
            }
        }
    } else {
        Write-Warning "Kein Profil '$ProfileName' zum Löschen gefunden."
    }
}

function Deploy-VpnCsp {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$XmlFile)

    $raw = Read-ProfileXmlRaw -Path $XmlFile

    if (-not $raw -or $raw -notmatch '<VPNProfile>') {
        throw "Erzeugte XML scheint leer/ungültig zu sein: '$XmlFile'"
    }

    $profileXmlEscaped = Escape-ForCsp -XmlRaw $raw

    $existing = Get-ExistingInstance
    if ($null -ne $existing) {
        if ($PSCmdlet.ShouldProcess("VPN-Profil '$ProfileName'", 'Aktualisieren')) {
            try {
                Set-CimInstance -InputObject $existing -Property @{ ProfileXML = $profileXmlEscaped } -ErrorAction Stop | Out-Null
                Write-Host "✅ VPN-Profil '$ProfileName' erfolgreich aktualisiert." -ForegroundColor Green
            } catch {
                Write-Error "Fehler beim Aktualisieren: $_"
            }
        }
    } else {
        if ($PSCmdlet.ShouldProcess("VPN-Profil '$ProfileName'", 'Erstellen')) {
            try {
                New-CimInstance -Namespace $Namespace -ClassName $ClassName -Property @{
                    ParentID   = $NodeCsp
                    InstanceID = $InstanceId
                    ProfileXML = $profileXmlEscaped
                } -ErrorAction Stop | Out-Null
                Write-Host "✅ VPN-Profil '$ProfileName' erfolgreich erstellt." -ForegroundColor Green
            } catch {
                Write-Error "Fehler beim Erstellen: $_"
            }
        }
    }
}

# --- Hauptlogik ---

try {
    Assert-Admin
    Assert-MdmBridge

    if ($Remove) {
        Remove-VpnCsp
        return
    }

    # Interaktive TND-Abfrage (wenn leer)
    if ([string]::IsNullOrWhiteSpace($TrustedNetworkDetection)) {
        $tndInput = Read-Host "TrustedNetworkDetection (DNS-Suffix, z.B. corp.contoso.local). Leer lassen = kein TND"
        if ($tndInput) {
            if ($tndInput -match '^([a-zA-Z0-9-]+\.)*[a-zA-Z0-9-]*$') {
                $TrustedNetworkDetection = $tndInput
            } else {
                Write-Warning "Ungültiges DNS-Suffix: '$tndInput'. TrustedNetworkDetection bleibt leer."
            }
        }
    }

    # Interaktive Routen-Abfrage (wenn leer)
    if (-not $Routes -or $Routes.Count -eq 0) {
        $input = Read-Host "Route(n) als CIDR, komma-separiert (z.B. 192.168.10.0/24,10.0.0.0/16). Enter = keine"
        if ($input) {
            $Routes = $input -split '\s*,\s*' | Where-Object { $_ }
        }
    }

    # Ensure-Mode
    Ensure-TempDir -Path $TempPath

    $xmlPath = Join-Path $TempPath 'vpn.xml'
    Generate-VpnXml -Path $xmlPath -Fqdn $ServerFqdn -ProfileNameParam $ProfileName `
        -TrustedNet $TrustedNetworkDetection -Routes $Routes

    Deploy-VpnCsp -XmlFile $xmlPath

    Write-Verbose "Temp-Ordner: $TempPath"

    if (-not $KeepTemp) {
        if (Test-Path $xmlPath) { Remove-Item $xmlPath -Force -ErrorAction SilentlyContinue }
    } else {
        Write-Verbose "KeepTemp aktiv: '$TempPath' und 'vpn.xml' bleiben erhalten."
    }
}
catch {
    Write-Error $_
}
