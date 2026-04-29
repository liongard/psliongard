function Remove-LiongardAgent {
<#
.SYNOPSIS
    Removes a Liongard agent from the platform.

.DESCRIPTION
    Deletes an agent record from the Liongard platform via the REST API. Agents can
    be targeted by numeric ID or by exact name.

    Supports -WhatIf and -Confirm. ConfirmImpact is Medium, so PowerShell does not
    prompt by default; pass -Confirm to force a prompt or -WhatIf to preview.

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

.EXAMPLE
    Remove-LiongardAgent -LiongardURL "us1.app.liongard.com" -ApiKey $key -ApiSecret $secret -AgentID 42

.EXAMPLE
    Remove-LiongardAgent -LiongardURL "us1.app.liongard.com" -ApiKey $key -ApiSecret $secret -AgentName "TestAgent"
#>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium', DefaultParameterSetName = 'ByID')]
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
        [string]$AgentName
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
    }
}
