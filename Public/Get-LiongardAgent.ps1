function Get-LiongardAgent {
<#
.SYNOPSIS
    Retrieves one or more Liongard agents from the platform.

.DESCRIPTION
    Queries the Liongard REST API to retrieve agent records by exact name, numeric ID,
    or wildcard name pattern. Automatically falls back from the v1 to the v2 API
    endpoint if the first request fails.

.PARAMETER LiongardURL
    Hostname of the Liongard instance (e.g. us1.app.liongard.com). Omit the
    https:// scheme.

.PARAMETER ApiKey
    Admin API key.

.PARAMETER ApiSecret
    Admin API secret.

.PARAMETER Name
    Exact agent name to find. Returns the first matching agent or $null.

.PARAMETER ID
    Numeric agent ID. Returns the agent object or $null.

.PARAMETER NamePattern
    Wildcard pattern to match against agent names (e.g. "TestAgent*").
    Returns an array of matching agents, which may be empty.

.OUTPUTS
    System.Management.Automation.PSCustomObject
    A single agent object for the ByName and ByID parameter sets, an array for
    ByNamePattern, or $null / empty array when no match is found.

.EXAMPLE
    Get-LiongardAgent -LiongardURL "us1.app.liongard.com" -ApiKey $key -ApiSecret $secret -Name "MyAgent"

.EXAMPLE
    Get-LiongardAgent -LiongardURL "us1.app.liongard.com" -ApiKey $key -ApiSecret $secret -ID 42

.EXAMPLE
    Get-LiongardAgent -LiongardURL "us1.app.liongard.com" -ApiKey $key -ApiSecret $secret -NamePattern "TestAgent*"
#>
    [CmdletBinding(DefaultParameterSetName = 'ByName')]
    [OutputType([PSCustomObject], ParameterSetName = 'ByName')]
    [OutputType([PSCustomObject], ParameterSetName = 'ByID')]
    [OutputType([PSCustomObject[]], ParameterSetName = 'ByNamePattern')]
    param(
        [Parameter(Mandatory=$true)]
        [string]$LiongardURL,

        [Parameter(Mandatory=$true)]
        [string]$ApiKey,

        [Parameter(Mandatory=$true)]
        [string]$ApiSecret,

        [Parameter(Mandatory=$true, ParameterSetName='ByName')]
        [string]$Name,

        [Parameter(Mandatory=$true, ParameterSetName='ByID')]
        [int]$ID,

        # Returns all agents whose Name matches the wildcard pattern (e.g. "TestAgent*")
        [Parameter(Mandatory=$true, ParameterSetName='ByNamePattern')]
        [string]$NamePattern
    )

    $apiParams = @{ LiongardURL = $LiongardURL; ApiKey = $ApiKey; ApiSecret = $ApiSecret }

    switch ($PSCmdlet.ParameterSetName) {
        'ByName' {
            $encodedName = [System.Uri]::EscapeDataString($Name)
            $result = Invoke-LiongardApi @apiParams -Method "GET" -Endpoint "/api/v1/agents/?conditions=Name='$encodedName'"

            if (-not $result.Success) {
                $result = Invoke-LiongardApi @apiParams -Method "GET" -Endpoint "/v2/agents/?conditions=Name='$encodedName'" -UseApiSubdomain
            }

            if ($result.Success -and $result.Data) {
                foreach ($agent in $result.Data) {
                    if ($agent.Name -eq $Name) { return $agent }
                }
            }

            return $null
        }

        'ByID' {
            $result = Invoke-LiongardApi @apiParams -Method "GET" -Endpoint "/api/v1/agents/$ID"

            if (-not $result.Success) {
                $result = Invoke-LiongardApi @apiParams -Method "GET" -Endpoint "/v2/agents/$ID" -UseApiSubdomain
            }

            if ($result.Success -and $result.Data) {
                if ($result.Data -is [Array] -and $result.Data.Count -gt 0) {
                    return $result.Data[0]
                } elseif ($result.Data -is [PSCustomObject]) {
                    return $result.Data
                }
            }

            return $null
        }

        'ByNamePattern' {
            $result = Invoke-LiongardApi @apiParams -Method "GET" -Endpoint "/api/v1/agents"

            if (-not $result.Success) {
                $result = Invoke-LiongardApi @apiParams -Method "GET" -Endpoint "/v2/agents" -UseApiSubdomain
            }

            if ($result.Success -and $result.Data) {
                return [PSCustomObject[]]@($result.Data | Where-Object { $_.Name -like $NamePattern })
            }

            return [PSCustomObject[]]@()
        }
    }
}
