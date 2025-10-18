# URL der Release Notes-Seite
$ReleaseNotesUrl = "https://www.acronis.com/en-us/support/updates/changes.html?p=41675"

# Funktion, um die neueste Build-Version abzurufen
function Get-LatestBuild {
    try {
        # Abrufen der Webseite
        $WebContent = Invoke-WebRequest -Uri $ReleaseNotesUrl -UseBasicParsing
        # Suchen der Build-Version im HTML-Code
        if ($WebContent.Content -match '<span class="build-number">\s*(\d{5})\s*</span>') {
            return $matches[1]
        } else {
            Write-Host "Konnte die neueste Build-Version nicht ermitteln." -ForegroundColor Red
            return $null
        }
    } catch {
        Write-Host "Fehler beim Abrufen der Webseite: $_" -ForegroundColor Red
        return $null
    }
}

# Funktion zum Herunterladen der ISO-Datei
function Download-ISO {
    param (
        [string]$BuildVersion
    )
    $DownloadUrl = "https://dl.acronis.com/s/AcronisTrueImage_$BuildVersion.iso"
    $OutputFile = "AcronisTrueImage_$BuildVersion.iso"

    if (-Not (Test-Path $OutputFile)) {
        Write-Host "Lade Acronis True Image Version $BuildVersion herunter..." -ForegroundColor Green
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $OutputFile -UseBasicParsing
        if (Test-Path $OutputFile) {
            Write-Host "Download abgeschlossen: $OutputFile" -ForegroundColor Green
        } else {
            Write-Host "Fehler beim Herunterladen der Datei." -ForegroundColor Red
        }
    } else {
        Write-Host "Die Datei $OutputFile existiert bereits." -ForegroundColor Yellow
    }
}

# Hauptlogik
$LatestBuild = Get-LatestBuild
if ($LatestBuild) {
    Write-Host "Neueste Build-Version: $LatestBuild" -ForegroundColor Cyan

    # Benutzerabfrage, ob der Download gestartet werden soll
    $UserInput = Read-Host "Möchten Sie die Build-Version $LatestBuild herunterladen? (ja/nein)"
    if ($UserInput -match '^(ja|j|yes|y)$') {
        Download-ISO -BuildVersion $LatestBuild
    } else {
        Write-Host "Download abgebrochen." -ForegroundColor Yellow
    }
} else {
    Write-Host "Abbruch: Keine gültige Build-Version gefunden." -ForegroundColor Red
}
