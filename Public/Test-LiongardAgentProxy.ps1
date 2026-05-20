function Test-LiongardAgentProxy {
<#
.SYNOPSIS
    Samples the agent's TCP connections over a window and fails if any direct
    HTTP/HTTPS connection (port 80/443) exists that is not the configured proxy.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProxyUrl,

        [int]$DurationSeconds = 60,

        [int]$IntervalSeconds = 5
    )

    $proxyPort = ([Uri]$ProxyUrl).Port
    $deadline  = (Get-Date).AddSeconds($DurationSeconds)
    $samples   = 0
    $seenAgent = $false

    while ((Get-Date) -lt $deadline) {
        $agentProcesses = Get-Process | Where-Object {
            $_.ProcessName -like '*liongard*' -or $_.ProcessName -like '*roar*'
        }

        if ($agentProcesses) {
            $seenAgent = $true
            $agentPids = $agentProcesses.Id

            $bad = Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
                Where-Object { $agentPids -contains $_.OwningProcess } |
                Where-Object { $_.RemotePort -in @(80, 443) -and $_.RemotePort -ne $proxyPort }

            if ($bad) {
                $bad | Format-Table -AutoSize | Out-String | Write-LiongardLog
                throw "Agent has direct established HTTP/S connections instead of only using proxy."
            }
        }

        $samples++
        Start-Sleep -Seconds $IntervalSeconds
    }

    if (-not $seenAgent) {
        throw "Could not find Liongard agent process during $DurationSeconds-second sampling window."
    }

    Write-LiongardLog "No direct Liongard Agent HTTP/S connections detected over $samples samples." "SUCCESS"
}
