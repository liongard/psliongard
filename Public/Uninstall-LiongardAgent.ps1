function Uninstall-LiongardAgent {
<#
.SYNOPSIS
    Uninstalls the Liongard Agent from the local Windows machine.

.DESCRIPTION
    Removes the Liongard Agent using one of two strategies:

    - If -InstallerPath is provided, the original EXE installer is invoked with
      /uninstall /quiet.
    - Otherwise, the function searches for the agent product via CIM
      (Win32_Product) and removes it with Invoke-CimMethod, falling
      back to msiexec /x if needed.

    After uninstalling, the function stops and deletes the agent Windows service
    and removes the installation directory.

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
        [string]$InstallerPath
    )

    $agentServiceName    = "roaragent.exe"
    $liongardInstallPath = "C:\Program Files (x86)\LiongardInc"

    Write-LiongardLog "Uninstalling Liongard Agent..."

    if ($InstallerPath) {
        $liongardProduct = Get-CimInstance -ClassName Win32_Product | Where-Object { $_.Name -like "*Liongard*Agent*" }
        $npcapInstalled  = Get-ItemProperty "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" |
            Where-Object { $_.DisplayName -like "*Npcap*" }

        if ($liongardProduct) {
            Write-LiongardLog "Found: $($liongardProduct.Name) v$($liongardProduct.Version)"
            if ($PSCmdlet.ShouldProcess($liongardProduct.Name, "Uninstall via EXE installer")) {
                $process = Start-Process -FilePath $InstallerPath -ArgumentList "/uninstall /quiet" -Wait -PassThru -NoNewWindow
                if ($process.ExitCode -eq 0) {
                    Write-LiongardLog "Uninstalled: $($liongardProduct.Name)" "SUCCESS"
                } else {
                    Write-LiongardLog "Uninstall exit code: $($process.ExitCode)" "WARNING"
                }
                Start-Sleep -Seconds 5
            }
        }

        if ($npcapInstalled) {
            $stillInstalled = Get-ItemProperty "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" |
                Where-Object { $_.DisplayName -like "*Npcap*" }
            if ($stillInstalled) {
                Write-LiongardLog "$($stillInstalled.DisplayName) is still installed" "WARNING"
            } else {
                Write-LiongardLog "Uninstalled: $($npcapInstalled.DisplayName)" "SUCCESS"
            }
        }

        $vcRedist = Get-ItemProperty `
            HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*, `
            HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* `
            -ErrorAction SilentlyContinue |
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
        $product = Get-CimInstance -ClassName Win32_Product | Where-Object { $_.Name -like "*Liongard*Agent*" }

        if ($product) {
            Write-LiongardLog "Found: $($product.Name) v$($product.Version)"
            if ($PSCmdlet.ShouldProcess($product.Name, "Uninstall via CIM")) {
                $result = Invoke-CimMethod -InputObject $product -MethodName 'Uninstall'
                if ($result.ReturnValue -eq 0) {
                    Write-LiongardLog "Agent uninstalled successfully" "SUCCESS"
                } else {
                    Write-LiongardLog "Uninstall returned code: $($result.ReturnValue)" "WARNING"
                }
                Start-Sleep -Seconds 5
            }
        } else {
            Write-LiongardLog "No Liongard Agent MSI product found" "WARNING"
        }

        $installedProducts = Get-ItemProperty "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" |
            Where-Object { $_.DisplayName -like "*Liongard*Agent*" }

        if ($installedProducts) {
            foreach ($prod in $installedProducts) {
                Write-LiongardLog "Uninstalling via msiexec: $($prod.DisplayName)"
                if ($PSCmdlet.ShouldProcess($prod.DisplayName, "Uninstall via msiexec")) {
                    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList "/x $($prod.PSChildName) /qn /norestart" -Wait -PassThru -NoNewWindow
                    if ($process.ExitCode -eq 0) {
                        Write-LiongardLog "Uninstalled successfully" "SUCCESS"
                    } else {
                        Write-LiongardLog "Uninstall exit code: $($process.ExitCode)" "WARNING"
                    }
                    Start-Sleep -Seconds 5
                }
            }
        }
    }

    # Common cleanup
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

    Start-Sleep -Seconds 3
}
