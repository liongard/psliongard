<#
.SYNOPSIS
    Tests Liongard Agent installation scenarios on Windows.

.DESCRIPTION
    Tests five installation scenarios for the Liongard Agent:
    - Scenario 1: Defining an environment and leaving default Agent name
    - Scenario 2: Defining an environment and adding a new custom Agent name
    - Scenario 3: Not defining an environment and leaving default Agent name
    - Scenario 4: Not defining an environment and adding a new custom Agent name
    - Scenario 5: Install with Enhanced Network Discovery enabled (EXE installer only)
    - Scenario 6: Install with Proxy Server

    Recommended: run via Task using a .env file rather than passing credentials
    directly. Copy .env.example to .env (or .env.<instance> for named instances),
    fill in LIONGARD_URL, LIONGARD_ACCESS_KEY, LIONGARD_ACCESS_SECRET, and
    LIONGARD_AGENT_VERSION, then run: task test:agent

.PARAMETER LiongardURL
    The Liongard instance URL (e.g., "us1.app.liongard.com")

.PARAMETER AdminApiKey
    API key for admin operations (creating environments, tokens, deleting agents)

.PARAMETER AdminApiSecret
    API secret for admin operations

.PARAMETER MSIPath
    Path to the LiongardAgent MSI file to install.

.PARAMETER InstallerPath
    Path to the LiongardAgentInstaller.exe file to install.

.PARAMETER TestEnvironmentName
    Name of the test environment. Defaults to a timestamped name.

.PARAMETER AccessKey
    Pre-created Agent Install Token Access Key.

.PARAMETER AccessSecret
    Pre-created Agent Install Token Access Secret. Required when AccessKey is provided.

.PARAMETER SkipEnvironmentCreation
    Skip environment creation and use the provided TestEnvironmentName as-is.

.PARAMETER SkipTokenCreation
    Skip token creation and use provided AccessKey/AccessSecret.

.EXAMPLE
    .\Tests\Agent\Install-LiongardAgent.Tests.ps1 -LiongardURL "us1.app.liongard.com" -AdminApiKey "key" -AdminApiSecret "secret" -MSIPath "C:\LiongardAgent.msi"

.EXAMPLE
    .\Tests\Agent\Install-LiongardAgent.Tests.ps1 -LiongardURL "us1.app.liongard.com" -AdminApiKey "key" -AdminApiSecret "secret" -InstallerPath "C:\LiongardAgentInstaller.exe"

.EXAMPLE
    .\Tests\Agent\Install-LiongardAgent.Tests.ps1 -LiongardURL "us1.app.liongard.com" -AdminApiKey "key" -AdminApiSecret "secret" -MSIPath "C:\LiongardAgent.msi" -AccessKey "token-key" -AccessSecret "token-secret" -TestEnvironmentName "ExistingEnv"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$LiongardURL,

    [Parameter(Mandatory=$true)]
    [string]$AdminApiKey,

    [Parameter(Mandatory=$true)]
    [string]$AdminApiSecret,

    [Parameter(Mandatory=$false)]
    [bool]$DownloadAgent = $true,

    [Parameter(Mandatory=$false)]
    [Version]$Version,

    [Parameter(Mandatory=$false)]
    [switch]$UseMsi,

    [Parameter(Mandatory=$false)]
    [Guid]$PreviewGuid,

    [Parameter(Mandatory=$false)]
    [string]$MSIPath,

    [Parameter(Mandatory=$false)]
    [string]$InstallerPath,

    [Parameter(Mandatory=$false)]
    [string]$TestEnvironmentName = "AutomatedTest-$(Get-Date -Format 'yyyyMMdd-HHmmss')",

    [Parameter(Mandatory=$false)]
    [string]$AccessKey = $null,

    [Parameter(Mandatory=$false)]
    [string]$AccessSecret = $null,

    [Parameter(Mandatory=$false)]
    [switch]$SkipEnvironmentCreation = $false,

    [Parameter(Mandatory=$false)]
    [switch]$SkipTokenCreation = $false
)

Import-Module "$PSScriptRoot\..\..\PSLiongard.psd1" -Force

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$TestResults = @()

#region Orchestration

function Test-AgentInstallation {
    param(
        [string]$ScenarioName,
        [string]$AccessKey,
        [string]$AccessSecret,
        [string]$Environment     = $null,
        [string]$AgentName       = $null,
        [switch]$InstallEnhancedNetworkDiscovery
    )

    Write-LiongardLog "========================================"
    Write-LiongardLog "Testing: $ScenarioName"
    Write-LiongardLog "========================================"

    $expectedName = if ($AgentName) { $AgentName } else { $env:COMPUTERNAME }

    $apiParams = @{ LiongardURL = $LiongardURL; ApiKey = $AdminApiKey; ApiSecret = $AdminApiSecret }

    $installParams = @{
        LiongardURL   = $LiongardURL
        AccessKey     = $AccessKey
        AccessSecret  = $AccessSecret
        MSIPath       = $MSIPath
        InstallerPath = $InstallerPath
        Environment   = $Environment
        AgentName     = $AgentName
    }
    if ($InstallEnhancedNetworkDiscovery) { $installParams.InstallEnhancedNetworkDiscovery = $true }

    $installSuccess = Install-LiongardAgent @installParams

    if (-not $installSuccess) {
        $script:TestResults += @{ Scenario = $ScenarioName; Status = "FAILED"; Reason = "Installation failed" }
        return $null
    }

    Write-LiongardLog "Waiting for agent to register with platform..."
    Start-Sleep -Seconds 10

    $maxRetries  = 6
    $retryCount  = 0
    $agent       = $null

    while ($retryCount -lt $maxRetries -and -not $agent) {
        $agent = Get-LiongardAgent @apiParams -Name $expectedName

        if (-not $agent -and $retryCount -ge 2) {
            Write-LiongardLog "Agent not found by exact name, trying broader search..."
            $matchingAgents = Get-LiongardAgent @apiParams -NamePattern "$expectedName*"
            if ($matchingAgents -and $matchingAgents.Count -gt 0) {
                $agent = $matchingAgents | Sort-Object -Property ID -Descending | Select-Object -First 1
                if ($agent) { Write-LiongardLog "Found agent with similar name: $($agent.Name) (ID: $($agent.ID))" }
            }
        }

        if (-not $agent) {
            Write-LiongardLog "Agent not found yet, retrying... ($retryCount/$maxRetries)"
            Start-Sleep -Seconds 10
            $retryCount++
        }
    }

    if (-not $agent) {
        Write-LiongardLog "Agent not found in platform after installation" "ERROR"
        $script:TestResults += @{ Scenario = $ScenarioName; Status = "FAILED"; Reason = "Agent not found in platform" }
        return $null
    }

    Write-LiongardLog "Agent found: ID=$($agent.ID)  Name=$($agent.Name)  Type=$($agent.Type)" "SUCCESS"
    Write-LiongardLog "  Environment: $(if ($agent.Environment) { $agent.Environment.Name } else { 'Not assigned' })"

    if ($Environment) {
        if ($agent.Environment -and $agent.Environment.Name -eq $Environment) {
            Write-LiongardLog "Environment matches: $Environment" "SUCCESS"
        } else {
            Write-LiongardLog "Environment mismatch! Expected: $Environment, Got: $(if ($agent.Environment) { $agent.Environment.Name } else { 'None' })" "ERROR"
            $script:TestResults += @{ Scenario = $ScenarioName; Status = "FAILED"; Reason = "Environment mismatch"; AgentID = $agent.ID; AgentName = $agent.Name }
            return @{ AgentID = $agent.ID; AgentName = $agent.Name }
        }
    } else {
        if ($agent.Environment) {
            Write-LiongardLog "Warning: no environment specified but agent has one: $($agent.Environment.Name)" "WARNING"
        } else {
            Write-LiongardLog "Agent has no environment (as expected)" "SUCCESS"
        }
    }

    $service = Get-Service -Name "roaragent.exe" -ErrorAction SilentlyContinue
    if ($service -and $service.Status -eq "Running") {
        Write-LiongardLog "Service is running" "SUCCESS"
    } else {
        Write-LiongardLog "Service is not running" "WARNING"
    }

    if ($InstallEnhancedNetworkDiscovery) {
        $npcapSvc = Get-Service -Name "npcap" -ErrorAction SilentlyContinue
        if ($npcapSvc) {
            Write-LiongardLog "Npcap service detected (status: $($npcapSvc.Status))" "SUCCESS"
        } else {
            Write-LiongardLog "Npcap service not found after Enhanced Network Discovery components should be installed" "ERROR"
            $script:TestResults += @{ Scenario = $ScenarioName; Status = "FAILED"; Reason = "Npcap service not found"; AgentID = $agent.ID; AgentName = $agent.Name }
            return @{ AgentID = $agent.ID; AgentName = $agent.Name }
        }
    }

    Write-LiongardLog "Waiting for agent to send heartbeat..."
    Start-Sleep -Seconds 30

    $heartbeatSuccess = $false
    for ($i = 0; $i -lt 6 -and -not $heartbeatSuccess; $i++) {
        $heartbeatSuccess = Test-LiongardAgentHeartbeat @apiParams -AgentID $agent.ID -MaxAgeMinutes 5
        if (-not $heartbeatSuccess) {
            Write-LiongardLog "Heartbeat check failed, retrying... ($i/6)"
            Start-Sleep -Seconds 15
        }
    }

    if (-not $heartbeatSuccess) {
        Write-LiongardLog "Agent heartbeat check failed after 6 attempts" "ERROR"
        $script:TestResults += @{ Scenario = $ScenarioName; Status = "FAILED"; Reason = "Heartbeat check failed"; AgentID = $agent.ID; AgentName = $agent.Name }
        return @{ AgentID = $agent.ID; AgentName = $agent.Name }
    }

    if (-not (Test-LiongardHeartbeatLog)) {
        Write-LiongardLog "Heartbeat logs check failed" "ERROR"
        $script:TestResults += @{ Scenario = $ScenarioName; Status = "FAILED"; Reason = "Heartbeat logs not found"; AgentID = $agent.ID; AgentName = $agent.Name }
        return @{ AgentID = $agent.ID; AgentName = $agent.Name }
    }

    if (-not (Test-LiongardScheduledTask)) {
        Write-LiongardLog "Scheduled task check failed" "ERROR"
        $script:TestResults += @{ Scenario = $ScenarioName; Status = "FAILED"; Reason = "Scheduled task not found"; AgentID = $agent.ID; AgentName = $agent.Name }
        return @{ AgentID = $agent.ID; AgentName = $agent.Name }
    }

    $script:TestResults += @{ Scenario = $ScenarioName; Status = "PASSED"; AgentID = $agent.ID; AgentName = $agent.Name }
    Write-LiongardLog "Test PASSED: $ScenarioName" "SUCCESS"
    return @{ AgentID = $agent.ID; AgentName = $agent.Name }
}

function Remove-TestAgent {
    [CmdletBinding(SupportsShouldProcess)]
    param([hashtable]$AgentInfo)
    if (-not $AgentInfo) { return }
    $apiParams = @{ LiongardURL = $LiongardURL; ApiKey = $AdminApiKey; ApiSecret = $AdminApiSecret }
    if ($AgentInfo.AgentID) {
        Write-LiongardLog "Removing test agent: $($AgentInfo.AgentName) (ID: $($AgentInfo.AgentID))"
        if ($PSCmdlet.ShouldProcess("Agent ID $($AgentInfo.AgentID)", "Remove test agent")) {
            Remove-LiongardAgent @apiParams -AgentID $AgentInfo.AgentID -Confirm:$false
        }
    } elseif ($AgentInfo.AgentName) {
        Write-LiongardLog "Removing test agent: $($AgentInfo.AgentName)"
        if ($PSCmdlet.ShouldProcess("Agent '$($AgentInfo.AgentName)'", "Remove test agent")) {
            Remove-LiongardAgent @apiParams -AgentName $AgentInfo.AgentName -Confirm:$false
        }
    }
}

#endregion

#region Main

Write-LiongardLog "========================================"
Write-LiongardLog "Liongard Agent Installation Test Suite"
Write-LiongardLog "========================================"
Write-LiongardLog "Liongard URL:     $LiongardURL"
Write-LiongardLog "Test Environment: $TestEnvironmentName"
Write-LiongardLog "Installer Path:   $(if ($InstallerPath) { $InstallerPath } else { 'Not specified' })"
Write-LiongardLog "MSI Path:         $(if ($MSIPath) { $MSIPath } else { 'Not specified' })"

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-LiongardLog "ERROR: This script must be run as Administrator" "ERROR"
    exit 1
}

if ($DownloadAgent) {
    if (-not $Version) {
        Write-LiongardLog "ERROR: -Version is required when -DownloadAgent is true" "ERROR"
        exit 1
    }

    $downloadOutFile = if ($UseMsi) {
        Join-Path $env:TEMP "LiongardAgent$Version.msi"
    } else {
        Join-Path $env:TEMP "LiongardAgentInstaller$Version.exe"
    }

    Write-LiongardLog "Downloading Liongard Agent v$Version..."

    $downloadParams = @{ Version = $Version; OutFile = $downloadOutFile }
    if ($UseMsi)      { $downloadParams.UseMsi      = $true }
    if ($PreviewGuid) { $downloadParams.PreviewGuid = $PreviewGuid }

    try {
        & "$PSScriptRoot\..\..\Scripts\Download-LiongardAgentInstaller.ps1" @downloadParams
    } catch {
        Write-LiongardLog "ERROR: Agent download failed: $($_.Exception.Message)" "ERROR"
        exit 1
    }

    if ($UseMsi) { $MSIPath = $downloadOutFile } else { $InstallerPath = $downloadOutFile }
    Write-LiongardLog "Downloaded agent to: $downloadOutFile" "SUCCESS"
} elseif (-not $MSIPath -and -not $InstallerPath) {
    Write-LiongardLog "ERROR: Provide -Version (to download) or -MSIPath / -InstallerPath" "ERROR"
    exit 1
}

if ($InstallerPath) {
    if (-not [System.IO.Path]::IsPathRooted($InstallerPath)) {
        $InstallerPath = Join-Path (Get-Location).Path $InstallerPath
    }
    $InstallerPath = [System.IO.Path]::GetFullPath($InstallerPath)
    if (-not (Test-Path $InstallerPath)) {
        Write-LiongardLog "ERROR: Installer not found at: $InstallerPath" "ERROR"
        exit 1
    }
    Write-LiongardLog "Resolved Installer path: $InstallerPath"
}

if ($MSIPath) {
    if (-not [System.IO.Path]::IsPathRooted($MSIPath)) {
        $MSIPath = Join-Path (Get-Location).Path $MSIPath
    }
    $MSIPath = [System.IO.Path]::GetFullPath($MSIPath)
    if (-not (Test-Path $MSIPath)) {
        Write-LiongardLog "ERROR: MSI not found at: $MSIPath" "ERROR"
        exit 1
    }
    Write-LiongardLog "Resolved MSI path: $MSIPath"
}

$apiParams = @{ LiongardURL = $LiongardURL; ApiKey = $AdminApiKey; ApiSecret = $AdminApiSecret }

Write-LiongardLog "Step 1: Cleaning up existing agents and installations..."

Uninstall-LiongardAgent -InstallerPath $InstallerPath

if (-not $SkipEnvironmentCreation) {
    Write-LiongardLog "Creating test environment..."
    $env = New-LiongardEnvironment @apiParams -Name $TestEnvironmentName
    if (-not $env) {
        Write-LiongardLog "Failed to create environment. Proceeding with name: $TestEnvironmentName" "WARNING"
    }
} else {
    Write-LiongardLog "Skipping environment creation. Using: $TestEnvironmentName"
}

if (-not $SkipTokenCreation) {
    if ($AccessKey -and $AccessSecret) {
        Write-LiongardLog "Using provided access token."
        $accessKey    = $AccessKey
        $accessSecret = $AccessSecret
    } else {
        $tokenName = "TestToken-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        $token     = New-LiongardAccessToken @apiParams -TokenName $tokenName
        if (-not $token) {
            Write-LiongardLog "ERROR: Failed to create access token. Create one manually and provide via -AccessKey and -AccessSecret." "ERROR"
            exit 1
        }
        $accessKey    = $token.AccessKeyID
        $accessSecret = $token.Secret

        if (-not $accessKey -or -not $accessSecret) {
            Write-LiongardLog "ERROR: Token created but missing AccessKey or Secret. Response: $($token | ConvertTo-Json)" "ERROR"
            exit 1
        }
    }
} else {
    if (-not $AccessKey -or -not $AccessSecret) {
        Write-LiongardLog "ERROR: -SkipTokenCreation requires -AccessKey and -AccessSecret" "ERROR"
        exit 1
    }
    $accessKey    = $AccessKey
    $accessSecret = $AccessSecret
    Write-LiongardLog "Using provided access token (skipping creation)."
}

Write-LiongardLog "Access token ready." "SUCCESS"

Write-LiongardLog "========================================"
Write-LiongardLog "Running Installation Test Scenarios"
Write-LiongardLog "========================================"

function Assert-Uninstalled {
    $svc = Get-Service -Name "roaragent.exe" -ErrorAction SilentlyContinue
    if ($svc) { Write-LiongardLog "WARNING: roaragent.exe service still present after uninstall" "WARNING" }
}

# Scenario 1: Environment + Default Agent Name
$s1 = Test-AgentInstallation -ScenarioName "Scenario 1: Environment + Default Agent Name" `
    -AccessKey $accessKey -AccessSecret $accessSecret -Environment $TestEnvironmentName -AgentName $null
Uninstall-LiongardAgent -InstallerPath $InstallerPath
Assert-Uninstalled
Remove-TestAgent $s1
Start-Sleep -Seconds 5

# Scenario 2: Environment + Custom Agent Name
$s2 = Test-AgentInstallation -ScenarioName "Scenario 2: Environment + Custom Agent Name" `
    -AccessKey $accessKey -AccessSecret $accessSecret -Environment $TestEnvironmentName `
    -AgentName "TestAgent-CustomName-$(Get-Date -Format 'HHmmss')"
Uninstall-LiongardAgent -InstallerPath $InstallerPath
Assert-Uninstalled
Remove-TestAgent $s2
Start-Sleep -Seconds 5

# Scenario 3: No Environment + Default Agent Name
$s3 = Test-AgentInstallation -ScenarioName "Scenario 3: No Environment + Default Agent Name" `
    -AccessKey $accessKey -AccessSecret $accessSecret -Environment $null -AgentName $null
Uninstall-LiongardAgent -InstallerPath $InstallerPath
Assert-Uninstalled
Remove-TestAgent $s3
Start-Sleep -Seconds 5

# Scenario 4: No Environment + Custom Agent Name
$s4 = Test-AgentInstallation -ScenarioName "Scenario 4: No Environment + Custom Agent Name" `
    -AccessKey $accessKey -AccessSecret $accessSecret -Environment $null `
    -AgentName "TestAgent-CustomName2-$(Get-Date -Format 'HHmmss')"
Uninstall-LiongardAgent -InstallerPath $InstallerPath
Assert-Uninstalled
Remove-TestAgent $s4
Start-Sleep -Seconds 5

# Scenario 5: Install with Enhanced Network Discovery enabled (EXE installer only - skipped when only MSIPath is provided)
if ($InstallerPath) {
    $s5 = Test-AgentInstallation -ScenarioName "Scenario 5: Install Enhanced Network Discovery" `
        -AccessKey $accessKey -AccessSecret $accessSecret -Environment $TestEnvironmentName `
        -AgentName $null -InstallEnhancedNetworkDiscovery
    Uninstall-LiongardAgent -InstallerPath $InstallerPath
    Assert-Uninstalled
    Remove-TestAgent $s5
} else {
    Write-LiongardLog "Scenario 5 (EnhancedNetworkDiscovery) skipped: requires EXE installer (-InstallerPath)." "WARNING"
    $script:TestResults += @{ Scenario = "Scenario 5: Install Enhanced Network Discovery"; Status = "SKIPPED"; Reason = "No InstallerPath provided" }
}

# Results summary
Write-LiongardLog "========================================"
Write-LiongardLog "Test Results Summary"
Write-LiongardLog "========================================"

$passed  = @($TestResults | Where-Object { $_.Status -eq "PASSED" }).Count
$failed  = @($TestResults | Where-Object { $_.Status -eq "FAILED" }).Count
$skipped = @($TestResults | Where-Object { $_.Status -eq "SKIPPED" }).Count

foreach ($result in $TestResults) {
    $color = switch ($result.Status) { "PASSED" { "Green" } "SKIPPED" { "Yellow" } default { "Red" } }
    Write-Host "$($result.Scenario): " -NoNewline
    Write-Host $result.Status -ForegroundColor $color
    if ($result.Reason)  { Write-Host "  Reason: $($result.Reason)"  -ForegroundColor "Yellow" }
    if ($result.AgentID) { Write-Host "  Agent ID: $($result.AgentID)" }
}

Write-LiongardLog "Total: $($TestResults.Count)  Passed: $passed  Failed: $failed  Skipped: $skipped"

if ($failed -eq 0) {
    Write-LiongardLog "All tests PASSED!" "SUCCESS"
    exit 0
} else {
    Write-LiongardLog "Some tests FAILED!" "ERROR"
    exit 1
}

#endregion
