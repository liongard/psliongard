<#
.SYNOPSIS
    Liongard Agent install for N-able N-central.
.DESCRIPTION
    - Reads inputs from script parameters, falling back to .env-style environment
      variables: LIONGARD_URL, LIONGARD_ACCESS_KEY, LIONGARD_ACCESS_SECRET,
      LIONGARD_ENVIRONMENT.
    - Auto-detects Environment from N-central AgentConfig.xml CustomerName when
      neither parameter nor env var supplies one.
    - Friendly enforcement loop interactively; graceful exit non-interactively.
    - Delegates install to PSLiongard module's Install-LiongardAgent.
#>
param(
    [string]$Url,
    [string]$AccessKey,
    [string]$AccessSecret,
    [string]$Environment
)

try {
    Import-Module "$PSScriptRoot\..\..\..\PSLiongard.psd1" -Force -ErrorAction Stop
}
catch {
    throw "Failed to import PSLiongard module: $($_.Exception.Message)"
}

function Get-EnvVarSafe {
    param([Parameter(Mandatory=$true)][string]$Name)
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($v)) { return $null }
    $t = $v.Trim()
    if ($t.ToLower() -eq "null") { return $null }
    return $t
}

if ([string]::IsNullOrWhiteSpace($Url))          { $Url          = Get-EnvVarSafe "LIONGARD_URL" }
if ([string]::IsNullOrWhiteSpace($AccessKey))    { $AccessKey    = Get-EnvVarSafe "LIONGARD_ACCESS_KEY" }
if ([string]::IsNullOrWhiteSpace($AccessSecret)) { $AccessSecret = Get-EnvVarSafe "LIONGARD_ACCESS_SECRET" }
if ([string]::IsNullOrWhiteSpace($Environment))  { $Environment  = Get-EnvVarSafe "LIONGARD_ENVIRONMENT" }

$Folder         = "$env:ProgramData\Liongard"
$TranscriptPath = "$Folder\ScriptInstall.log"

if (-not (Test-Path -Path $Folder)) { New-Item -Path $Folder -ItemType Directory -ErrorAction SilentlyContinue | Out-Null }

try { Start-Transcript -Path $TranscriptPath -Append -Force -ErrorAction Stop }
catch { Write-Host "WARNING: Transcript failed. Proceeding without it." -ForegroundColor Yellow }

function Exit-Smart {
    param ([int]$Code)
    Stop-Transcript -ErrorAction SilentlyContinue
    if ([Environment]::UserInteractive) {
        Write-Host "`n---------------------------------------------------"
        if ($Code -ne 0) { Write-Host "SCRIPT FAILED (Exit Code $Code) - Check logs above." -ForegroundColor Red }
        else { Write-Host "SCRIPT FINISHED SUCCESSFULLY" -ForegroundColor Green }
        Write-Host "---------------------------------------------------"
        Read-Host "Press Enter to close this window..."
    }
    Exit $Code
}

function Get-RequiredInput {
    param ( [string]$CurrentValue, [string]$PromptName )
    if (-not [string]::IsNullOrWhiteSpace($CurrentValue)) { return $CurrentValue }
    if (-not [Environment]::UserInteractive) { return $null }
    $Val = $null
    do {
        $Val = Read-Host "`n$PromptName (Required)"
        if ([string]::IsNullOrWhiteSpace($Val)) {
            Write-Host "   [!] We can't proceed without the $PromptName." -ForegroundColor Yellow
            Write-Host "       Please enter it to continue." -ForegroundColor Gray
        }
    } until (-not [string]::IsNullOrWhiteSpace($Val))
    return $Val
}

Write-LiongardLog "--- Starting Liongard Agent Installation (N-central) ---"

$Url          = Get-RequiredInput -CurrentValue $Url          -PromptName "1. Liongard URL"
$AccessKey    = Get-RequiredInput -CurrentValue $AccessKey    -PromptName "2. Access Key ID"
$AccessSecret = Get-RequiredInput -CurrentValue $AccessSecret -PromptName "3. Access Key Secret"

if ([string]::IsNullOrWhiteSpace($Environment)) {
    $NcentralConfig = "${env:ProgramFiles(x86)}\N-able Technologies\Windows Agent\config\AgentConfig.xml"
    if (-not (Test-Path $NcentralConfig)) {
        $NcentralConfig = "$env:ProgramFiles\N-able Technologies\Windows Agent\config\AgentConfig.xml"
    }
    if (Test-Path $NcentralConfig) {
        try {
            Write-LiongardLog "Attempting to auto-detect Environment from N-central Agent..."
            [xml]$AgentXml = Get-Content $NcentralConfig
            $DetectedName = $AgentXml.AgentConfig.CustomerName
            if (-not [string]::IsNullOrWhiteSpace($DetectedName)) {
                $Environment = $DetectedName
                Write-LiongardLog "Auto-detected Environment: '$Environment'"
            } else {
                Write-LiongardLog "Could not find CustomerName in AgentConfig.xml." "WARNING"
            }
        }
        catch {
            Write-LiongardLog "Failed to read N-central config: $_" "WARNING"
        }
    } else {
        Write-LiongardLog "N-central Agent Config not found. Skipping auto-discovery." "WARNING"
    }
}

if ([string]::IsNullOrWhiteSpace($Environment) -and [Environment]::UserInteractive) {
    $Environment = Read-Host "`n4. Environment Name (Optional - Press Enter to skip)"
}

if (-not $Url -or -not $AccessKey -or -not $AccessSecret) {
    Write-LiongardLog "FATAL ERROR: Missing required variables." "ERROR"
    Write-LiongardLog "If running via RMM, you MUST pass these as script arguments." "ERROR"
    Exit-Smart 1
}

if ($Url -match "https://") { $Url = $Url -replace "https://","" -replace "/","" }
if ($Url -notmatch "\.app\.liongard\.com") {
    $Url = "$Url.app.liongard.com"
    Write-LiongardLog "Auto-corrected URL to: $Url"
}

$MsiPath        = "$env:TEMP\LiongardAgent-lts.msi"
$DownloadUri    = "https://agents.static.liongard.com/LiongardAgent-lts.msi"
$MinMsiSize     = 10485760
$MinFreeSpaceMB = 200
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

Write-LiongardLog "Checking for existing Liongard Agent Service..."
if (Get-Service | Where-Object { $_.Name -like "*Liongard*" -or $_.DisplayName -like "*Liongard*" }) {
    Write-LiongardLog "A Liongard Agent service is already present. Aborting." "WARNING"
    Exit-Smart 0
}

try {
    $Disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" | Select-Object FreeSpace
    if (([math]::Round($Disk.FreeSpace / 1MB)) -lt $MinFreeSpaceMB) { throw "Insufficient disk space." }
    Write-LiongardLog "Verifying connectivity..."
    $Request = [System.Net.WebRequest]::Create($DownloadUri); $Request.Method = "HEAD"; $Response = $Request.GetResponse(); $Response.Close()
}
catch { Write-LiongardLog "Pre-check failed: $_" "ERROR"; Exit-Smart 1 }

Write-LiongardLog "Downloading MSI..."
try {
    Invoke-WebRequest -Uri $DownloadUri -OutFile $MsiPath -UseBasicParsing -ErrorAction Stop
    if ((Get-Item $MsiPath).Length -lt $MinMsiSize) { throw "File too small." }
}
catch { Write-LiongardLog "Download failed: $_" "ERROR"; Exit-Smart 1 }

$installParams = @{
    LiongardURL  = $Url
    AccessKey    = $AccessKey
    AccessSecret = $AccessSecret
    MSIPath      = $MsiPath
    AgentName    = $env:COMPUTERNAME
}
if (-not [string]::IsNullOrWhiteSpace($Environment)) { $installParams.Environment = $Environment }

try { $installed = Install-LiongardAgent @installParams }
catch { Write-LiongardLog "Install threw: $_" "ERROR"; Exit-Smart 1 }

Remove-Item $MsiPath -Force -ErrorAction SilentlyContinue
if ($installed) { Exit-Smart 0 } else { Exit-Smart 1 }
