<#
.SYNOPSIS
    Downloads the Liongard Agent Installer for Windows.

.DESCRIPTION
    Downloads the Liongard Agent Installer and verifies its SHA-256 checksum and/or
    cosign signature depending on the agent version.

.PARAMETER Version
    The Liongard Agent version to download. Format: major.minor.patch (e.g. 5.2.1)

.PARAMETER UseMsi
    Download the MSI instead of the Installer.

.PARAMETER PreviewGuid
    The GUID portion of the preview download URL.
    Example: 54BA085D-AECD-4304-B279-B14216C11E93

.PARAMETER OutFile
    The local filename for the downloaded installer.
    Defaults to LiongardAgentInstaller<Version>.exe.

.EXAMPLE
    .\Download-LiongardAgentInstaller.ps1

.EXAMPLE
    .\Download-LiongardAgentInstaller.ps1 -Version "5.3.0" -PreviewGuid "5EA64AA0-8C56-44DA-BAC2-3CCFA712100E"

.EXAMPLE
    .\Download-LiongardAgentInstaller.ps1 -Version "5.1.2" -UseMsi

.EXAMPLE
    .\Download-LiongardAgentInstaller.ps1 -Version "5.2.1" -PreviewGuid "54BA085D-AECD-4304-B279-B14216C11E93" -OutFile "LiongardAgentInstaller5.2.1.exe"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [Version]$Version = "5.3.0",

    [Parameter(Mandatory = $false)]
    [bool]$ValidateSignature = $true,

    [Parameter(Mandatory = $false)]
    [Guid]$PreviewGuid,

    [Parameter(Mandatory = $false)]
    [switch]$UseMsi,

    [Parameter(Mandatory = $false)]
    [string]$OutFile
)

Import-Module "$PSScriptRoot\..\PSLiongard.psd1" -Force

# Enable TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if ($UseMsi) {
    $filename = "LiongardAgent$Version.msi"
} else {
    $filename = "LiongardAgentInstaller$Version.exe"
}

if ([string]::IsNullOrWhiteSpace($OutFile)) {
    $OutFile = $filename
}

$baseUrl         = "https://agents.static.liongard.com"
$baseDownloadUrl = if ($PreviewGuid) { "$baseUrl/$PreviewGuid" } else { $baseUrl }
$downloadUrl     = "$baseDownloadUrl/$filename"
$shaUrl          = "$downloadUrl.sha256"
$shaFile         = "$OutFile.sha256"
$pubKeyUrl       = "$baseDownloadUrl/liongard.pub"
$pubKeyFile      = "liongard.pub"
$bundleUrl       = "$baseDownloadUrl/$filename.sigstore.json"
$bundleFile      = "$filename.sigstore.json"

$verifyWithChecksum = $Version -ge [Version]"5.2.1"
$verifyWithCosign   = $ValidateSignature -and ($Version -ge [Version]"5.3.0")

Write-Output "Checking for cosign..."

if ($verifyWithCosign) {
    if (Get-Command cosign -ErrorAction SilentlyContinue) {
        cosign version
    } else {
        Write-Output "cosign not found, attempting install..."
        Install-Cosign `
            -CosignVer "3.0.5" `
            -CosignOs  "windows-amd64" `
            -TempDir   (Join-Path $env:TEMP "cosign-verify")
    }
}

Write-Host "Downloading the Liongard Agent Installer..."

try {
    if ($verifyWithChecksum) {
        Invoke-WebRequest -Uri $shaUrl -OutFile $shaFile -ErrorAction Stop
        if (-not (Test-Path $shaFile) -or (Get-Item $shaFile).Length -eq 0) {
            throw "Checksum download failed: file missing or empty."
        }
    }

    if ($verifyWithCosign) {
        Invoke-WebRequest -Uri $pubKeyUrl -OutFile $pubKeyFile -ErrorAction Stop
        if (-not (Test-Path $pubKeyFile) -or (Get-Item $pubKeyFile).Length -eq 0) {
            throw "Public key download failed: file missing or empty."
        }

        Invoke-WebRequest -Uri $bundleUrl -OutFile $bundleFile -ErrorAction Stop
        if (-not (Test-Path $bundleFile) -or (Get-Item $bundleFile).Length -eq 0) {
            throw "Bundle download failed: file missing or empty."
        }
    }

    Invoke-WebRequest -Uri $downloadUrl -OutFile $OutFile -ErrorAction Stop

    if (-not (Test-Path $OutFile) -or (Get-Item $OutFile).Length -lt 1KB) {
        throw "Installer download failed: file missing or unexpectedly small."
    }

    if ($verifyWithChecksum) {
        $expectedSha = ((Get-Content $shaFile | Select-Object -First 1) -split '\s+')[0].Trim().ToUpper()
        if ([string]::IsNullOrWhiteSpace($expectedSha)) {
            throw "Checksum verification failed: could not read SHA-256 from $shaFile."
        }

        $actualSha = (Get-FileHash -Path $OutFile -Algorithm SHA256).Hash.ToUpper()

        if ($actualSha -ne $expectedSha) {
            throw "Checksum verification failed.`nExpected: '$expectedSha'`nActual:   '$actualSha'"
        }
    }

    if ($verifyWithCosign) {
        & cosign verify-blob "$OutFile" --bundle "$bundleFile" --key "$pubKeyFile"
        if ($LASTEXITCODE -ne 0) { throw "cosign verify-blob failed." }
    }

    Write-Host "$OutFile downloaded and verified successfully."
}
catch {
    Remove-Item $OutFile  -Force -ErrorAction SilentlyContinue
    Remove-Item $shaFile  -Force -ErrorAction SilentlyContinue
    throw
}
