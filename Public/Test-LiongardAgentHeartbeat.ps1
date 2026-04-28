function Test-LiongardAgentHeartbeat {
<#
.SYNOPSIS
    Verifies that a Liongard agent has sent a heartbeat recently.

.DESCRIPTION
    Retrieves the agent from the Liongard platform and checks how long ago its
    last heartbeat was received. Returns $true if the heartbeat age is within the
    allowed threshold, $false otherwise.

    Handles multiple datetime formats returned by different API versions, including
    ISO 8601 strings, PSCustomObject wrappers, and .NET DateTime values.

    Use -Verbose to see heartbeat timestamp details during the check.

.PARAMETER LiongardURL
    Hostname of the Liongard instance (e.g. us1.app.liongard.com).

.PARAMETER ApiKey
    Admin API key.

.PARAMETER ApiSecret
    Admin API secret.

.PARAMETER AgentID
    Numeric ID of the agent to check.

.PARAMETER MaxAgeMinutes
    Maximum acceptable age of the last heartbeat in minutes. Default: 5.

.OUTPUTS
    System.Boolean
    $true if the agent heartbeated within MaxAgeMinutes, $false otherwise.

.EXAMPLE
    Test-LiongardAgentHeartbeat -LiongardURL "us1.app.liongard.com" -ApiKey $key -ApiSecret $secret -AgentID 42

.EXAMPLE
    Test-LiongardAgentHeartbeat -LiongardURL "us1.app.liongard.com" -ApiKey $key -ApiSecret $secret -AgentID 42 -MaxAgeMinutes 10 -Verbose
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory=$true)]
        [string]$LiongardURL,

        [Parameter(Mandatory=$true)]
        [string]$ApiKey,

        [Parameter(Mandatory=$true)]
        [string]$ApiSecret,

        [Parameter(Mandatory=$true)]
        [int]$AgentID,

        [int]$MaxAgeMinutes = 5
    )

    Write-LiongardLog "Checking agent heartbeat for Agent ID: $AgentID"

    $agent = Get-LiongardAgent -LiongardURL $LiongardURL -ApiKey $ApiKey -ApiSecret $ApiSecret -ID $AgentID

    if (-not $agent) {
        Write-LiongardLog "Failed to retrieve agent details" "ERROR"
        return $false
    }

    if (-not $agent.LastHeartbeat) {
        Write-LiongardLog "Agent has no LastHeartbeat data" "ERROR"
        return $false
    }

    Write-Verbose "LastHeartbeat type: $($agent.LastHeartbeat.GetType().FullName)"
    if ($agent.LastHeartbeat -is [PSCustomObject]) {
        Write-Verbose "LastHeartbeat: $($agent.LastHeartbeat | ConvertTo-Json -Compress)"
    } elseif ($agent.LastHeartbeat -is [String]) {
        Write-Verbose "LastHeartbeat string: $($agent.LastHeartbeat)"
    } elseif ($agent.LastHeartbeat -is [DateTime]) {
        Write-Verbose "LastHeartbeat DateTime: $($agent.LastHeartbeat), Kind: $($agent.LastHeartbeat.Kind)"
    }

    $lastHeartbeatTime = $null
    if ($agent.LastHeartbeat -is [PSCustomObject]) {
        if ($agent.LastHeartbeat.LastHeartbeat) {
            $lastHeartbeatTime = $agent.LastHeartbeat.LastHeartbeat
        } elseif ($agent.LastHeartbeat.PSObject.Properties['DateTime']) {
            $lastHeartbeatTime = $agent.LastHeartbeat.DateTime
        }
    } elseif ($agent.LastHeartbeat -is [DateTime]) {
        $lastHeartbeatTime = $agent.LastHeartbeat
    } elseif ($agent.LastHeartbeat -is [String]) {
        $lastHeartbeatTime = $agent.LastHeartbeat
    }

    if (-not $lastHeartbeatTime) {
        Write-LiongardLog "Could not extract LastHeartbeat timestamp from agent data" "ERROR"
        return $false
    }

    if ($lastHeartbeatTime -is [String]) {
        try {
            $dto               = [DateTimeOffset]::Parse($lastHeartbeatTime, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
            $lastHeartbeatTime = $dto.UtcDateTime
        } catch {
            try {
                $parsed = [DateTime]::Parse($lastHeartbeatTime, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                $lastHeartbeatTime = [DateTime]::SpecifyKind($parsed, [DateTimeKind]::Utc)
            } catch {
                Write-LiongardLog "Failed to parse LastHeartbeat timestamp: $lastHeartbeatTime" "ERROR"
                return $false
            }
        }
    } elseif ($lastHeartbeatTime -is [DateTime]) {
        if ($lastHeartbeatTime.Kind -eq [DateTimeKind]::Local) {
            $lastHeartbeatTime = $lastHeartbeatTime.ToUniversalTime()
        } elseif ($lastHeartbeatTime.Kind -eq [DateTimeKind]::Unspecified) {
            $lastHeartbeatTime = [DateTime]::SpecifyKind($lastHeartbeatTime, [DateTimeKind]::Utc)
        }
    }

    if ($lastHeartbeatTime.Kind -ne [DateTimeKind]::Utc) {
        Write-LiongardLog "LastHeartbeat kind is $($lastHeartbeatTime.Kind), converting to UTC" "WARNING"
        $lastHeartbeatTime = if ($lastHeartbeatTime.Kind -eq [DateTimeKind]::Local) {
            $lastHeartbeatTime.ToUniversalTime()
        } else {
            [DateTime]::SpecifyKind($lastHeartbeatTime, [DateTimeKind]::Utc)
        }
    }

    $now        = [DateTime]::UtcNow
    $ageMinutes = ($now - $lastHeartbeatTime).TotalMinutes

    Write-LiongardLog "Last heartbeat: $lastHeartbeatTime UTC"
    Write-LiongardLog "Current time:   $now UTC"
    Write-LiongardLog "Age: $([math]::Round($ageMinutes, 2)) minutes"

    if ($ageMinutes -le $MaxAgeMinutes) {
        Write-LiongardLog "Agent is heartbeating (within $MaxAgeMinutes min)" "SUCCESS"
        return $true
    } else {
        Write-LiongardLog "Heartbeat is stale ($([math]::Round($ageMinutes, 2)) min ago; max: $MaxAgeMinutes min)" "ERROR"
        return $false
    }
}
