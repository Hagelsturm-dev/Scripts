<#
.SYNOPSIS
  Generiert und deployed ein AlwaysOn-SSTP-User-Tunnel-VPN-Profil per MDM-CSP oder entfernt es wieder.

.DESCRIPTION
  - Ohne Schalter: Standard-ParameterSet „Ensure“ → Abfrage von ProfileName, ServerFqdn, TrustedNetworkDetection (optional).
  - Mit -Remove: ParameterSet „Remove“ → nur ProfileName wird abgefragt.
  - TrustedNetworkDetection wird nur ins XML geschrieben, wenn ein Wert angegeben wurde.
  - Validiert Eingaben, räumt Temp-Dateien auf, bietet verbose Logging.

.PARAMETER ProfileName
  Eindeutiger Name für das VPN-Profil (alphanumerisch, Bindestriche/Unterstriche erlaubt).

.PARAMETER ServerFqdn
  FQDN deines SSTP-Servers. (Nur im Ensure-Set.)

.PARAMETER TrustedNetworkDetection
  DNS-Suffix deines vertrauenswürdigen LANs. (Nur im Ensure-Set, optional.)

.PARAMETER Remove
  Schaltet in das Remove-ParameterSet: löscht das bestehende Profil.

.PARAMETER TempPath
  Optionaler Pfad für temporäre Dateien. Default: $env:TEMP\VPNDeploy

.EXAMPLE
  .\Deploy-AlwaysOnVpn.ps1 -ProfileName MeinVPN -ServerFqdn vpn.contoso.com `
    -TrustedNetworkDetection corp.contoso.local -Verbose

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

    # Remove-Schalter definiert Remove-Set
    [Parameter(ParameterSetName = 'Remove')]
    [switch]$Remove,

    # TempPath in beiden Sets optional
    [Parameter()]
    [string]$TempPath = (Join-Path $env:TEMP "VPNDeploy")
)

# CSP-Konstanten
$NodeCsp    = './Vendor/MSFT/VPNv2'
$Namespace  = 'root\cimv2\mdm\dmmap'
$ClassName  = 'MDM_VPNv2_01'
$InstanceId = $ProfileName -replace ' ', '%20'

function Ensure-TempDir {
    param([string]$Path)
    Write-Verbose "Säubere temporären Ordner: $Path"
    if (Test-Path $Path) {
        Remove-Item -Path "$Path\*" -Force -Recurse -ErrorAction SilentlyContinue
    } else {
        New-Item -Path $Path -ItemType Directory | Out-Null
    }
}

function Generate-VpnXml {
    param(
        [string]$Path,
        [string]$Fqdn,
        [string]$TrustedNet
    )
    Write-Verbose "Erzeuge VPN XML in: $Path"

    $content = @"
<VPNProfile>
  <NativeProfile>
    <Servers>$Fqdn</Servers>
    <NativeProtocolType>Automatic</NativeProtocolType>
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

    $content += @"
  <DeviceTunnel>false</DeviceTunnel>
  <RegisterDNS>true</RegisterDNS>
</VPNProfile>
"@

    $content | Out-File -FilePath $Path -Encoding UTF8
}

function Get-ExistingInstance {
    try {
        return Get-CimInstance -Namespace $Namespace -ClassName $ClassName `
            -Filter "InstanceID='$InstanceId' AND ParentID='$NodeCsp'" -ErrorAction SilentlyContinue
    } catch {
        Write-Verbose "Fehler beim Abfragen vorhandener Instances: $_"
        return $null
    }
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
    param([string]$XmlFile)

   $escapedXml = (Get-Content $XmlFile -Raw).Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;')        

    # CSP-Instanz aufbauen
    $instance = New-Object Microsoft.Management.Infrastructure.CimInstance($ClassName, $Namespace)
    $instance.CimInstanceProperties.Add(
        [Microsoft.Management.Infrastructure.CimProperty]::Create('ParentID', $NodeCsp, 'String','Key')
    )
    $instance.CimInstanceProperties.Add(
        [Microsoft.Management.Infrastructure.CimProperty]::Create('InstanceID', $InstanceId,'String','Key')
    )
    $instance.CimInstanceProperties.Add(
        [Microsoft.Management.Infrastructure.CimProperty]::Create('ProfileXML', $escapedXml,'String','Property')
    )

    # Existenz prüfen
    $existing = Get-ExistingInstance
    if ($null -ne $existing) {
        if ($PSCmdlet.ShouldProcess("VPN-Profil '$ProfileName'", 'Aktualisieren')) {
            try {
                Set-CimInstance -InputObject $existing -Property @{ ProfileXML = $escapedXml } -ErrorAction Stop
                Write-Host "✅ VPN-Profil '$ProfileName' erfolgreich aktualisiert." -ForegroundColor Green
            } catch {
                Write-Error "Fehler beim Aktualisieren: $_"
            }
        }
    } else {
        if ($PSCmdlet.ShouldProcess("VPN-Profil '$ProfileName'", 'Erstellen')) {
            try {
                $session = New-CimSession
                $session.CreateInstance($Namespace, $instance) | Out-Null
                Write-Host "✅ VPN-Profil '$ProfileName' erfolgreich erstellt." -ForegroundColor Green
            } catch {
                Write-Error "Fehler beim Erstellen: $_"
            }
        }
    }
}

# Hauptlogik
if ($Remove) {
    Remove-VpnCsp
    return
}

# Ensure-Mode
Ensure-TempDir -Path $TempPath
$xmlPath = Join-Path $TempPath 'vpn.xml'
Generate-VpnXml -Path $xmlPath -Fqdn $ServerFqdn -TrustedNet $TrustedNetworkDetection
Deploy-VpnCsp -XmlFile $xmlPath

Write-Verbose "Temp-Ordner: $TempPath"
