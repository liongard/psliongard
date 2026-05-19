function Install-LiongardAgent {
<#
.SYNOPSIS
    Installs the Liongard Agent on the local Windows machine.

.DESCRIPTION
    Runs the Liongard Agent installer silently and verifies the installation by
    checking the Windows service and install directory. Supports both the legacy
    MSI installer and the newer EXE installer.

    Provide exactly one of -MSIPath or -InstallerPath. MSI installations use
    msiexec.exe; EXE installations call the installer directly and additionally
    support the -InstallEnhancedNetworkDiscovery flag.

    Credentials are redacted in log output.

    Returns $true on success, $false on failure.

.PARAMETER LiongardURL
    Hostname of the Liongard instance (e.g. us1.app.liongard.com).

.PARAMETER AccessKey
    Agent install token access key.

.PARAMETER AccessSecret
    Agent install token access secret.

.PARAMETER MSIPath
    Full path to the LiongardAgent .msi file.

.PARAMETER InstallerPath
    Full path to the LiongardAgentInstaller .exe file.

.PARAMETER Environment
    Environment name to register the agent in. If omitted, the agent is placed
    in the default environment.

.PARAMETER AgentName
    Custom name for the agent. Defaults to the machine hostname.

.PARAMETER InstallEnhancedNetworkDiscovery
    Enables Network IQ when using the EXE installer. Ignored for MSI installs.

.OUTPUTS
    System.Boolean
    $true if installation succeeded, $false otherwise.

.EXAMPLE
    Install-LiongardAgent -LiongardURL "us1.app.liongard.com" `
        -AccessKey $token.AccessKeyID -AccessSecret $token.Secret `
        -MSIPath "C:\LiongardAgent.msi"

.EXAMPLE
    Install-LiongardAgent -LiongardURL "us1.app.liongard.com" `
        -AccessKey $token.AccessKeyID -AccessSecret $token.Secret `
        -InstallerPath "C:\LiongardAgentInstaller.exe" `
        -Environment "Production" -AgentName "web-01" -InstallEnhancedNetworkDiscovery
#>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory=$true)]
        [string]$LiongardURL,

        [Parameter(Mandatory=$true)]
        [string]$AccessKey,

        [Parameter(Mandatory=$true)]
        [string]$AccessSecret,

        [ValidateScript({ -not $_ -or (Test-Path $_ -PathType Leaf) })]
        [string]$MSIPath,

        [ValidateScript({ -not $_ -or (Test-Path $_ -PathType Leaf) })]
        [string]$InstallerPath,

        [string]$Environment,

        [string]$AgentName,

        [switch]$InstallEnhancedNetworkDiscovery
    )

    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Install-LiongardAgent requires Administrator privileges."
    }

    Write-LiongardLog "Installing agent with parameters:"
    Write-LiongardLog "  Environment: $(if ($Environment) { $Environment } else { 'Not specified' })"
    Write-LiongardLog "  Agent Name: $(if ($AgentName) { $AgentName } else { 'Default (hostname)' })"
    Write-LiongardLog "  Installer: $(if ($InstallerPath) { $InstallerPath } else { 'Not specified' })"
    Write-LiongardLog "  MSI: $(if ($MSIPath) { $MSIPath } else { 'Not specified' })"

    if ($MSIPath) {
        $logFile     = "$env:TEMP\LiongardAgent-Install-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
        $installArgs = @(
            "/i", "`"$MSIPath`"", "/qn", "/norestart",
            "/L*V", "`"$logFile`"",
            "LIONGARDURL=$LiongardURL",
            "LIONGARDACCESSKEY=$AccessKey",
            "LIONGARDACCESSSECRET=$AccessSecret"
        )
        if ($Environment) { $installArgs += "LIONGARDENVIRONMENT=`"$Environment`"" }
        if ($AgentName)   { $installArgs += "LIONGARDAGENTNAME=$AgentName" }

        $installArgsString = $installArgs -join " "
        $redacted = $installArgsString -replace '(?i)(Access(?:Key|Secret)=)\S+', '$1***'
        Write-LiongardLog "Running: msiexec $redacted"

        if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Install Liongard Agent from MSI")) {
            return $false
        }

        $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $installArgsString -Wait -PassThru -NoNewWindow
    }
    elseif ($InstallerPath) {
        $logFile     = "$env:TEMP\LiongardAgent-Install-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
        $installArgs = @(
            "/quiet", "/log", "`"$logFile`"",
            "EulaAccepted=1",
            "LiongardUrl=$LiongardURL",
            "LiongardAccessKey=$AccessKey",
            "LiongardAccessSecret=$AccessSecret"
        )
        if ($InstallEnhancedNetworkDiscovery) { $installArgs += "InstallEnhancedNetworkDiscovery=1" }
        if ($Environment) { $installArgs += "LiongardEnvironment=`"$Environment`"" }
        if ($AgentName)   { $installArgs += "LiongardAgentName=$AgentName" }

        $installArgsString = $installArgs -join " "
        $redacted = $installArgsString -replace '(?i)(Access(?:Key|Secret)=)\S+', '$1***'
        Write-LiongardLog "Running: $InstallerPath $redacted"

        if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Install Liongard Agent from EXE")) {
            return $false
        }

        $process = Start-Process -FilePath $InstallerPath -ArgumentList $installArgsString -Wait -PassThru -NoNewWindow
    }
    else {
        Write-LiongardLog "Installation file not specified; provide -MSIPath or -InstallerPath" "ERROR"
        return $false
    }

    Start-Sleep -Seconds 5

    if ($process.ExitCode -ne 0) {
        Write-LiongardLog "Installation failed with exit code: $($process.ExitCode)" "ERROR"
        return $false
    }

    Write-LiongardLog "Installation completed successfully (exit code: 0)" "SUCCESS"
    Start-Sleep -Seconds 3

    $service = Get-Service -Name $agentServiceName -ErrorAction SilentlyContinue
    if ($service) {
        Write-LiongardLog "Service found: $($service.Name) - Status: $($service.Status)" "SUCCESS"
        if ($service.Status -ne "Running") {
            Write-LiongardLog "Starting service..."
            Start-Service -Name $agentServiceName -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
        }
    } else {
        Write-LiongardLog "Service not found after installation" "WARNING"
    }

    if (Test-Path $liongardInstallPath) {
        Write-LiongardLog "Installation folder exists: $liongardInstallPath" "SUCCESS"
    } else {
        Write-LiongardLog "Installation folder not found" "WARNING"
    }

    if ($InstallerPath -and $InstallEnhancedNetworkDiscovery) {
        $vcRedist = Get-ItemProperty $uninstallPaths -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like "Microsoft Visual C++*Redistributable*x86*" -and $_.DisplayVersion } |
            Sort-Object DisplayVersion -Descending |
            Select-Object -First 1

        if ($vcRedist) {
            Write-LiongardLog "Verified C++ Runtime: $($vcRedist.DisplayName) $($vcRedist.DisplayVersion)"
        } else {
            Write-LiongardLog "C++ Runtime (x86) is NOT installed" "ERROR"
            return $false
        }

        $npcapService = Get-Service -Name Npcap -ErrorAction SilentlyContinue
        if ($npcapService -and $npcapService.Status -eq "Running") {
            Write-LiongardLog "Npcap service is running: $($npcapService.DisplayName)"
        } else {
            Write-LiongardLog "Npcap service is not running" "WARNING"
        }
    }

    return $true
}
