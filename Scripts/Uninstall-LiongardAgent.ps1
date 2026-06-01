<#
.SYNOPSIS
    Liongard Agent REMOVAL - Production Ready (v1.0)
.DESCRIPTION
    - Detects Liongard Agent via Registry (Fast/Safe).
    - Stops Service -> Uninstalls via MSI -> Cleans Program Files.
    - RMM Safe: Runs silently if non-interactive.
    - Human Safe: Asks for confirmation if run manually (unless -Force is used).
#>
param(
    [switch]$Force # Use this switch to skip the "Are you sure?" prompt when running manually
)

try {
    Import-Module "$PSScriptRoot\..\PSLiongard.psd1" -Force -ErrorAction Stop
}
catch {
    throw "Failed to import PSLiongard module from '$PSScriptRoot\..\PSLiongard.psd1': $($_.Exception.Message)"
}

# --- 0. Setup & Logging ---
$Folder         = "$env:ProgramData\Liongard"
$TranscriptPath = "$Folder\ScriptUninstall.log"
# We log to ProgramData so the log survives the uninstall of Program Files
if (-not (Test-Path -Path $Folder)) { New-Item -Path $Folder -ItemType Directory -ErrorAction SilentlyContinue | Out-Null }

try { Start-Transcript -Path $TranscriptPath -Append -Force -ErrorAction Stop }
catch { Write-Host "WARNING: Transcript failed. Proceeding without it." -ForegroundColor Yellow }

function Exit-Smart {
    param ([int]$Code)
    Stop-Transcript -ErrorAction SilentlyContinue
    if ([Environment]::UserInteractive) {
        Write-Host "`n---------------------------------------------------"
        if ($Code -ne 0) { Write-Host "UNINSTALL FAILED (Exit Code $Code) - Check logs." -ForegroundColor Red }
        else { Write-Host "UNINSTALL COMPLETED SUCCESSFULLY" -ForegroundColor Green }
        Write-Host "---------------------------------------------------"
        Read-Host "Press Enter to close this window..."
    }
    Exit $Code
}

Write-LiongardLog "--- Starting Liongard Agent UNINSTALLATION ---"

# --- 1. Safety Check (The Friendly Gatekeeper) ---
if ([Environment]::UserInteractive -and -not $Force) {
    Write-Host "`nWARNING: You are about to completely remove the Liongard Agent from: $env:COMPUTERNAME" -ForegroundColor Yellow
    $Confirm = Read-Host "Are you sure you want to continue? (y/n)"
    if ($Confirm -notmatch "^[Yy]") {
        Write-LiongardLog "Uninstall cancelled by user." "INFO"
        Exit-Smart 0
    }
}

# --- 2. Uninstall via PSLiongard module ---
try {
    Uninstall-LiongardAgent
    Exit-Smart 0
}
catch {
    Write-LiongardLog "Uninstall failed: $_" "ERROR"
    Exit-Smart 1
}
