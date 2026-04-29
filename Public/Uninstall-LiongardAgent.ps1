function Uninstall-LiongardAgent {
<#
.SYNOPSIS
    Uninstalls the Liongard Agent from the local Windows machine.

.DESCRIPTION
    Removes the Liongard Agent using one of two strategies:

    - If -InstallerPath is provided, the original EXE installer is invoked with
      /uninstall /quiet.
    - Otherwise, the function locates the agent product in the Windows registry
      (both 32-bit and 64-bit hives) and removes it with msiexec /x using the
      product GUID.

    After uninstalling, the function stops and deletes the agent Windows service
    and removes the installation directory. A post-uninstall check verifies that
    the registry entry, service, and install folder are all gone.

.PARAMETER InstallerPath
    Full path to the LiongardAgentInstaller .exe used for the original
    installation. When provided, triggers EXE-based uninstall.

.EXAMPLE
    Uninstall-LiongardAgent

.EXAMPLE
    Uninstall-LiongardAgent -InstallerPath "C:\LiongardAgentInstaller.exe"

.EXAMPLE
    Uninstall-LiongardAgent -WhatIf
#>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [ValidateScript({ -not $_ -or (Test-Path $_ -PathType Leaf) })]
        [string]$InstallerPath
    )

    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Uninstall-LiongardAgent requires Administrator privileges."
    }

    Write-LiongardLog "Uninstalling Liongard Agent..."

    if ($InstallerPath) {
        $liongardProduct = Get-ItemProperty $uninstallPaths -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like "*Liongard*Agent*" } |
            Select-Object -First 1
        $npcapBefore = Get-ItemProperty $uninstallPaths -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like "*Npcap*" } |
            Select-Object -First 1

        if ($liongardProduct) {
            Write-LiongardLog "Found: $($liongardProduct.DisplayName) v$($liongardProduct.DisplayVersion)"
        }

        $target = if ($liongardProduct) { $liongardProduct.DisplayName } else { "Liongard Agent" }
        if ($PSCmdlet.ShouldProcess($target, "Uninstall via EXE installer")) {
            $process = Start-Process -FilePath $InstallerPath -ArgumentList "/uninstall /quiet" -Wait -PassThru -NoNewWindow
            if ($process.ExitCode -eq 0) {
                Write-LiongardLog "Uninstalled: $target" "SUCCESS"
            } else {
                Write-LiongardLog "Uninstall exit code: $($process.ExitCode)" "WARNING"
            }
            Start-Sleep -Seconds 5
        }

        if ($npcapBefore) {
            $npcapAfter = Get-ItemProperty $uninstallPaths -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like "*Npcap*" } |
                Select-Object -First 1
            if ($npcapAfter) {
                Write-LiongardLog "$($npcapAfter.DisplayName) is still installed" "WARNING"
            } else {
                Write-LiongardLog "Uninstalled: $($npcapBefore.DisplayName)" "SUCCESS"
            }
        }

        $vcRedist = Get-ItemProperty $uninstallPaths -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like "Microsoft Visual C++*Redistributable*x86*" -and $_.DisplayVersion } |
            Sort-Object DisplayVersion -Descending |
            Select-Object -First 1

        if ($vcRedist) {
            Write-LiongardLog "C++ Runtime still installed: $($vcRedist.DisplayName) $($vcRedist.DisplayVersion)"
        } else {
            Write-LiongardLog "C++ Runtime (x86) is NOT installed" "WARNING"
        }
    }
    else {
        $products = Get-ItemProperty $uninstallPaths -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like "*Liongard*Agent*" } |
            Sort-Object PSChildName -Unique

        if ($products) {
            foreach ($prod in $products) {
                Write-LiongardLog "Found: $($prod.DisplayName) v$($prod.DisplayVersion)"
                if ($PSCmdlet.ShouldProcess($prod.DisplayName, "Uninstall via msiexec")) {
                    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList "/x $($prod.PSChildName) /qn /norestart" -Wait -PassThru -NoNewWindow
                    if ($process.ExitCode -eq 0) {
                        Write-LiongardLog "Uninstalled: $($prod.DisplayName)" "SUCCESS"
                    } else {
                        Write-LiongardLog "Uninstall exit code: $($process.ExitCode)" "WARNING"
                    }
                    Start-Sleep -Seconds 5
                }
            }
        } else {
            Write-LiongardLog "No Liongard Agent product found" "WARNING"
        }
    }

    $service = Get-Service -Name $agentServiceName -ErrorAction SilentlyContinue
    if ($service) {
        Write-LiongardLog "Stopping service: $agentServiceName"
        if ($PSCmdlet.ShouldProcess($agentServiceName, "Stop and delete Windows service")) {
            Stop-Service -Name $agentServiceName -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            sc.exe delete $agentServiceName | Out-Null
            Start-Sleep -Seconds 2
        }
    }

    if (Test-Path $liongardInstallPath) {
        Write-LiongardLog "Removing installation folder: $liongardInstallPath"
        if ($PSCmdlet.ShouldProcess($liongardInstallPath, "Remove installation directory")) {
            try {
                Remove-Item -Path $liongardInstallPath -Recurse -Force -ErrorAction Stop
                Write-LiongardLog "Removed installation folder" "SUCCESS"
            } catch {
                Write-LiongardLog "Failed to remove folder: $($_.Exception.Message)" "WARNING"
            }
        }
    }

    $remaining = Get-ItemProperty $uninstallPaths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "*Liongard*Agent*" }
    if ($remaining) {
        Write-LiongardLog "Agent product still found in registry after uninstall" "WARNING"
    } else {
        Write-LiongardLog "Agent product removed from registry" "SUCCESS"
    }

    $serviceCheck = Get-Service -Name $agentServiceName -ErrorAction SilentlyContinue
    if ($serviceCheck) {
        Write-LiongardLog "Service still exists: $agentServiceName" "WARNING"
    } else {
        Write-LiongardLog "Service removed: $agentServiceName" "SUCCESS"
    }

    if (Test-Path $liongardInstallPath) {
        Write-LiongardLog "Installation folder still exists: $liongardInstallPath" "WARNING"
    } else {
        Write-LiongardLog "Installation folder removed" "SUCCESS"
    }
}
