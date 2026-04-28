function Remove-LiongardAgent {
<#
.SYNOPSIS
    Removes one or more Liongard agents from the platform.

.DESCRIPTION
    Deletes agent records from the Liongard platform via the REST API. Agents can
    be targeted by numeric ID, by exact name, or all agents can be removed at once.

    Supports -WhatIf and -Confirm. Use -All with caution - it deletes every agent
    in the platform. The -All parameter set uses ConfirmImpact=High, so PowerShell
    prompts for confirmation unless -Force or -Confirm:$false is supplied.

.PARAMETER LiongardURL
    Hostname of the Liongard instance (e.g. us1.app.liongard.com).

.PARAMETER ApiKey
    Admin API key.

.PARAMETER ApiSecret
    Admin API secret.

.PARAMETER AgentID
    Numeric ID of the agent to delete.

.PARAMETER AgentName
    Exact name of the agent to delete. Resolves the name to an ID first.

.PARAMETER All
    Deletes every agent in the platform. Prompts for confirmation.

.EXAMPLE
    Remove-LiongardAgent -LiongardURL "us1.app.liongard.com" -ApiKey $key -ApiSecret $secret -AgentID 42

.EXAMPLE
    Remove-LiongardAgent -LiongardURL "us1.app.liongard.com" -ApiKey $key -ApiSecret $secret -AgentName "TestAgent"

.EXAMPLE
    Remove-LiongardAgent -LiongardURL "us1.app.liongard.com" -ApiKey $key -ApiSecret $secret -All -Confirm:$false
#>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'ByID')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'All',
        Justification = 'Discriminates parameter sets; checked via $PSCmdlet.ParameterSetName')]
    [OutputType([void])]
    param(
        [Parameter(Mandatory=$true)]
        [string]$LiongardURL,

        [Parameter(Mandatory=$true)]
        [string]$ApiKey,

        [Parameter(Mandatory=$true)]
        [string]$ApiSecret,

        [Parameter(Mandatory=$true, ParameterSetName='ByID')]
        [int]$AgentID,

        [Parameter(Mandatory=$true, ParameterSetName='ByName')]
        [string]$AgentName,

        [Parameter(Mandatory=$true, ParameterSetName='All')]
        [switch]$All
    )

    $apiParams = @{ LiongardURL = $LiongardURL; ApiKey = $ApiKey; ApiSecret = $ApiSecret }

    switch ($PSCmdlet.ParameterSetName) {
        'ByID' {
            Write-LiongardLog "Deleting agent with ID: $AgentID"
            if ($PSCmdlet.ShouldProcess("Agent ID $AgentID", "Delete from Liongard platform")) {
                $result = Invoke-LiongardApi @apiParams -Method "DELETE" -Endpoint "/api/v1/agents/$AgentID"

                if (-not $result.Success) {
                    $result = Invoke-LiongardApi @apiParams -Method "DELETE" -Endpoint "/v2/agents/$AgentID" -UseApiSubdomain
                }

                if ($result.Success) {
                    Write-LiongardLog "Successfully deleted agent $AgentID" "SUCCESS"
                } else {
                    Write-LiongardLog "Failed to delete agent ${AgentID}: $($result.Error)" "ERROR"
                }
            }
        }

        'ByName' {
            Write-LiongardLog "Removing agent by name: $AgentName"
            $agent = Get-LiongardAgent @apiParams -Name $AgentName

            if ($agent) {
                Write-LiongardLog "Found agent: $($agent.Name) (ID: $($agent.ID))"
                Remove-LiongardAgent @apiParams -AgentID $agent.ID
            } else {
                Write-LiongardLog "Agent not found: $AgentName" "WARNING"
            }
        }

        'All' {
            Write-LiongardLog "WARNING: Deleting ALL agents from platform..." "WARNING"
            $result = Invoke-LiongardApi @apiParams -Method "GET" -Endpoint "/api/v1/agents"

            if (-not $result.Success) {
                $result = Invoke-LiongardApi @apiParams -Method "GET" -Endpoint "/v2/agents" -UseApiSubdomain
            }

            if ($result.Success -and $result.Data) {
                Write-LiongardLog "Found $($result.Data.Count) agent(s) to delete"
                if ($PSCmdlet.ShouldProcess("$($result.Data.Count) agents", "Delete all from Liongard platform")) {
                    foreach ($agent in $result.Data) {
                        Remove-LiongardAgent @apiParams -AgentID $agent.ID -Confirm:$false
                        Start-Sleep -Seconds 2
                    }
                }
            } else {
                Write-LiongardLog "No agents found or error retrieving agents" "WARNING"
            }
        }
    }
}
