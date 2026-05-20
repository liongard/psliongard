function Assert-AgentHasNoDirectLiongardConnection {
    param(
        [Parameter(Mandatory)]
        [string]$ProxyUrl
    )

    $proxyUri = [Uri]$ProxyUrl
    $proxyPort = $proxyUri.Port

    $agentProcesses = Get-Process |
        Where-Object {
            $_.ProcessName -like "*liongard*" -or
            $_.ProcessName -like "*roar*"
        }

    if (-not $agentProcesses) {
        throw "Could not find Liongard agent process."
    }

    $agentPids = $agentProcesses.Id

    $connections = Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
        Where-Object { $agentPids -contains $_.OwningProcess }

    $badConnections = $connections | Where-Object {
        $_.RemotePort -in @(80, 443) -and
        $_.RemotePort -ne $proxyPort
    }

    if ($badConnections) {
        $badConnections | Format-Table -AutoSize | Out-String | Write-LiongardLog
        throw "Agent has direct established HTTP/S connections instead of only using proxy."
    }

    Write-LiongardLog "No direct Liongard Agent HTTP/S connections detected." "SUCCESS"
}

function Assert-ProxyLogContainsLiongardTraffic {
    param(
        [Parameter(Mandatory)]
        [string]$ProxyAccessLogPath,

        [Parameter(Mandatory)]
        [string]$LiongardURL,

        [int]$TimeoutSeconds = 180
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        if (Test-Path $ProxyAccessLogPath) {
            $hits = Select-String `
                -Path $ProxyAccessLogPath `
                -Pattern $LiongardURL `
                -SimpleMatch `
                -ErrorAction SilentlyContinue

            if ($hits) {
                Write-LiongardLog "Proxy access log contains traffic for $LiongardURL." "SUCCESS"
                return
            }
        }

        Start-Sleep -Seconds 5
    }

    throw "Proxy access log did not contain traffic for $LiongardURL."
}