function New-LiongardEnvironment {
<#
.SYNOPSIS
    Creates a new environment in the Liongard platform.

.DESCRIPTION
    Posts a new environment record to the Liongard REST API. If the v1 endpoint
    fails, the function automatically retries against the v2 endpoint.

    On failure the function logs a warning and returns $null rather than throwing,
    so callers should check the return value before proceeding.

.PARAMETER LiongardURL
    Hostname of the Liongard instance (e.g. us1.app.liongard.com).

.PARAMETER ApiKey
    Admin API key.

.PARAMETER ApiSecret
    Admin API secret.

.PARAMETER Name
    Display name for the new environment.

.OUTPUTS
    System.Management.Automation.PSCustomObject
    The created environment object returned by the API, or $null if creation failed.

.EXAMPLE
    $env = New-LiongardEnvironment -LiongardURL "us1.app.liongard.com" -ApiKey $key -ApiSecret $secret -Name "Production"
    if (-not $env) { Write-Error "Environment creation failed" }
#>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory=$true)]
        [string]$LiongardURL,

        [Parameter(Mandatory=$true)]
        [string]$ApiKey,

        [Parameter(Mandatory=$true)]
        [string]$ApiSecret,

        [Parameter(Mandatory=$true)]
        [string]$Name
    )

    Write-LiongardLog "Creating environment: $Name"

    if (-not $PSCmdlet.ShouldProcess($LiongardURL, "Create environment '$Name'")) {
        return $null
    }

    $body   = @{ Name = $Name }
    $result = Invoke-LiongardApi -LiongardURL $LiongardURL -Method "POST" -Endpoint "/api/v1/environments" -Body $body -ApiKey $ApiKey -ApiSecret $ApiSecret

    if (-not $result.Success) {
        $result = Invoke-LiongardApi -LiongardURL $LiongardURL -Method "POST" -Endpoint "/v2/environments" -Body $body -ApiKey $ApiKey -ApiSecret $ApiSecret -UseApiSubdomain
    }

    if ($result.Success) {
        Write-LiongardLog "Successfully created environment: $Name" "SUCCESS"
        return $result.Data
    } else {
        Write-LiongardLog "Failed to create environment: $($result.Error). Environment may need to be created manually in the UI." "WARNING"
        return $null
    }
}
