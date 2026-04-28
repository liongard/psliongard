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
    support the -InstallNetworkIQ flag.

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

.PARAMETER InstallNetworkIQ
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
        -Environment "Production" -AgentName "web-01" -InstallNetworkIQ
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

        [string]$MSIPath,

        [string]$InstallerPath,

        [string]$Environment,

        [string]$AgentName,

        [switch]$InstallNetworkIQ
    )

    $agentServiceName    = "roaragent.exe"
    $liongardInstallPath = "C:\Program Files (x86)\LiongardInc"

    Write-LiongardLog "Installing agent with parameters:"
    Write-LiongardLog "  Environment: $(if ($Environment) { $Environment } else { 'Not specified' })"
    Write-LiongardLog "  Agent Name: $(if ($AgentName) { $AgentName } else { 'Default (hostname)' })"
    Write-LiongardLog "  Installer: $(if ($InstallerPath) { $InstallerPath } else { 'Not specified' })"
    Write-LiongardLog "  MSI: $(if ($MSIPath) { $MSIPath } else { 'Not specified' })"

    if ($MSIPath) {
        if (-not (Test-Path $MSIPath)) { throw "MSI file not found at: $MSIPath" }

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
        Write-LiongardLog "Running: msiexec $installArgsString"

        if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Install Liongard Agent from MSI")) {
            return $false
        }

        $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $installArgsString -Wait -PassThru -NoNewWindow
    }
    elseif ($InstallerPath) {
        if (-not (Test-Path $InstallerPath)) { throw "Installer file not found at: $InstallerPath" }

        $logFile     = "$env:TEMP\LiongardAgent-Install-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
        $installArgs = @(
            "/quiet", "/log", "`"$logFile`"",
            "EulaAccepted=1",
            "LiongardUrl=$LiongardURL",
            "LiongardAccessKey=$AccessKey",
            "LiongardAccessSecret=$AccessSecret"
        )
        if ($InstallNetworkIQ) { $installArgs += "InstallNetworkIQ=1" }
        if ($Environment) { $installArgs += "LiongardEnvironment=`"$Environment`"" }
        if ($AgentName)   { $installArgs += "LiongardAgentName=$AgentName" }

        $installArgsString = $installArgs -join " "
        Write-LiongardLog "Running: $InstallerPath $installArgsString"

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

    if ($InstallerPath -and $InstallNetworkIQ) {
        $vcRedist = Get-ItemProperty `
            HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*, `
            HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* `
            -ErrorAction SilentlyContinue |
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
