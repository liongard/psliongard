function Install-Cosign {
<#
.SYNOPSIS
    Downloads, verifies, and installs the cosign binary on Windows.

.DESCRIPTION
    Downloads the cosign binary and its sigstore bundle from the official GitHub
    release, verifies the binary signature using cosign verify-blob, then copies
    the binary to C:\Program Files\cosign and adds that directory to the machine
    PATH.

    The download directory is removed after a successful install. Throws on any
    verification failure.

.PARAMETER CosignVer
    Version of cosign to install (e.g. [Version]"3.0.5").

.PARAMETER CosignOs
    Target platform. Must be "windows-amd64" or "windows-arm64".

.PARAMETER TempDir
    Temporary directory used for downloads. Created if it does not exist.

.PARAMETER CosignPubKeyName
    Filename of the cosign release public key. Default: release-cosign.pub.

.PARAMETER CosignPubKeySha
    Expected SHA-256 hash of the public key file (lowercase hex). Used to
    detect tampering of the key before verifying the binary.

.OUTPUTS
    System.String
    Full path to the installed cosign.exe binary.

.EXAMPLE
    Install-Cosign -CosignVer "3.0.5" -CosignOs "windows-amd64" -TempDir "C:\Temp\cosign"

.EXAMPLE
    $path = Install-Cosign -CosignVer "3.0.5" -CosignOs "windows-arm64" -TempDir $env:TEMP
    Write-Host "Cosign installed at: $path"
#>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory=$true)]
        [Version]$CosignVer,

        [Parameter(Mandatory=$true)]
        [ValidateSet("windows-amd64", "windows-arm64")]
        [string]$CosignOs,

        [Parameter(Mandatory=$true)]
        [string]$TempDir,

        [string]$CosignPubKeyName = "release-cosign.pub",
        [string]$CosignPubKeySha  = "f4cea466e5e887a45da5031757fa1d32655d83420639dc1758749b744179f126"
    )

    $ErrorActionPreference = "Stop"

    if (-not (Test-Path -LiteralPath $TempDir)) {
        New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
    }

    $releasesUrl      = "https://github.com/sigstore/cosign/releases/download/v$CosignVer"
    $cosignPubKeyUrl  = "$releasesUrl/$CosignPubKeyName"
    $cosignPubKey     = Join-Path $TempDir $CosignPubKeyName
    $binaryName       = "cosign-$CosignOs.exe"
    $cosignBin        = Join-Path $TempDir $binaryName
    $cosignBinUrl     = "$releasesUrl/$binaryName"
    $sigstoreJson     = Join-Path $TempDir "cosign-$CosignOs.exe-kms.sigstore.json"
    $sigstoreUrl      = "$releasesUrl/cosign-$CosignOs.exe-kms.sigstore.json"
    $sigDecoded       = Join-Path $TempDir "cosign-$CosignOs-kms.sig.decoded"

    Write-Host "Downloading Cosign public key..."
    Invoke-WebRequest -Uri $cosignPubKeyUrl -OutFile $cosignPubKey

    $pubKeySha = (Get-FileHash -Path $cosignPubKey -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($pubKeySha -ne $CosignPubKeySha.ToLowerInvariant()) {
        throw "Cosign public key checksum mismatch.`nExpected: '$CosignPubKeySha'`nActual:   '$pubKeySha'"
    }

    Write-Host "Downloading Cosign bundle... $sigstoreUrl"
    Invoke-WebRequest -Uri $sigstoreUrl -OutFile $sigstoreJson

    Write-Host "Extracting detached signature from bundle..."
    $bundle           = Get-Content -LiteralPath $sigstoreJson -Raw | ConvertFrom-Json
    $messageSignature = $bundle.messageSignature.signature

    if ([string]::IsNullOrWhiteSpace($messageSignature)) {
        throw "messageSignature.signature was missing from '$sigstoreJson'."
    }

    [System.IO.File]::WriteAllBytes($sigDecoded, [System.Convert]::FromBase64String($messageSignature))

    Write-Host "Downloading Cosign binary..."
    Invoke-WebRequest -Uri $cosignBinUrl -OutFile $cosignBin

    Write-Host "Verifying Cosign binary with cosign verify-blob..."
    & $cosignBin verify-blob `
        --bundle $sigstoreJson `
        --key $cosignPubKey `
        $cosignBin

    if ($LASTEXITCODE -ne 0) { throw "cosign verify-blob failed." }

    Write-Host "Verified cosign binary: $cosignBin"

    $installDir = "C:\Program Files\cosign"
    $cosignPath = Join-Path $installDir "cosign.exe"

    if ($PSCmdlet.ShouldProcess($installDir, "Install cosign binary")) {
        if (-not (Test-Path $installDir)) {
            New-Item -ItemType Directory -Path $installDir | Out-Null
        }

        Move-Item -Path $cosignBin -Destination $cosignPath -Force

        $currentPath = [Environment]::GetEnvironmentVariable("Path", "Machine")
        if ($currentPath -notlike "*$installDir*") {
            [Environment]::SetEnvironmentVariable("Path", "$currentPath;$installDir", "Machine")
            $env:Path += ";$installDir"
            Write-Output "Added $installDir to PATH"
        } else {
            Write-Output "PATH already contains $installDir"
        }
    }

    Remove-Item $TempDir -Force -Recurse -ErrorAction SilentlyContinue

    Write-Host "Installed cosign: $cosignPath"
    return $cosignPath
}
