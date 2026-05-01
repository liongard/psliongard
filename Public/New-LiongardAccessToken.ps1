function New-LiongardAccessToken {
<#
.SYNOPSIS
    Creates a new agent install access token in the Liongard platform.

.DESCRIPTION
    Posts a new access token to the Liongard REST API with the isAgentInstallKey
    flag set to true. The returned object is normalized so that the access key ID
    is always available under the AccessKeyID property and the secret under Secret,
    regardless of which property names the API version returns.

    On failure the function logs a warning and returns $null rather than throwing.

.PARAMETER LiongardURL
    Hostname of the Liongard instance (e.g. us1.app.liongard.com).

.PARAMETER ApiKey
    Admin API key.

.PARAMETER ApiSecret
    Admin API secret.

.PARAMETER TokenName
    Display name for the new access token.

.PARAMETER DaysUntilExpiration
    Number of days until the token expires, or "Unlimited" for no expiry.
    Default: Unlimited.

.OUTPUTS
    System.Management.Automation.PSCustomObject
    The created token object with normalized AccessKeyID and Secret properties,
    or $null if creation failed.

.EXAMPLE
    $token = New-LiongardAccessToken -LiongardURL "us1.app.liongard.com" -ApiKey $key -ApiSecret $secret -TokenName "AgentInstall"
    Install-LiongardAgent -AccessKey $token.AccessKeyID -AccessSecret $token.Secret ...

.EXAMPLE
    New-LiongardAccessToken -LiongardURL "us1.app.liongard.com" -ApiKey $key -ApiSecret $secret -TokenName "TempToken" -DaysUntilExpiration 30
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
        [string]$TokenName,

        [string]$DaysUntilExpiration = "Unlimited"
    )

    Write-LiongardLog "Creating access token (Agent Install Key): $TokenName"

    if (-not $PSCmdlet.ShouldProcess($LiongardURL, "Create access token '$TokenName'")) {
        return $null
    }

    $body = @{
        isAgentInstallKey   = $true
        daysUntilExpiration = $DaysUntilExpiration
    }

    $result = Invoke-LiongardApi -LiongardURL $LiongardURL -Method "POST" -Endpoint "/api/v1/access-keys" -Body $body -ApiKey $ApiKey -ApiSecret $ApiSecret

    if (-not $result.Success) {
        $result = Invoke-LiongardApi -LiongardURL $LiongardURL -Method "POST" -Endpoint "/v2/access-keys" -Body $body -ApiKey $ApiKey -ApiSecret $ApiSecret -UseApiSubdomain
    }

    if (-not $result.Success) {
        Write-LiongardLog "Failed to create access token: $($result.Error). Token may need to be created manually in the UI." "WARNING"
        return $null
    }

    Write-LiongardLog "Successfully created access token: $TokenName" "SUCCESS"
    $tokenData = $result.Data

    # Normalize AccessKeyID: PSObject.Properties lookups are case-insensitive, so checking
    # Properties['AccessKeyID'] would find the API's 'AccessKeyId' and prevent normalization.
    # Use direct value access instead and always write the canonical uppercase-D name.
    $normalizedKeyId = $tokenData.AccessKeyId
    if (-not $normalizedKeyId) { $normalizedKeyId = $tokenData.Key }
    if (-not $normalizedKeyId) { $normalizedKeyId = $tokenData.AccessKey }
    if (-not $normalizedKeyId) { $normalizedKeyId = $tokenData.ID }
    if ($normalizedKeyId) {
        $tokenData | Add-Member -NotePropertyName 'AccessKeyID' -NotePropertyValue $normalizedKeyId -Force
    }

    # Normalize Secret: the API may return a null 'Secret' field alongside a populated
    # 'AccessKeySecret'. Checking Properties['Secret'] returns a truthy PSPropertyInfo even
    # for a null value, blocking normalization. Resolve by value with AccessKeySecret first.
    $normalizedSecret = $tokenData.AccessKeySecret
    if (-not $normalizedSecret) { $normalizedSecret = $tokenData.SecretAccessKey }
    if (-not $normalizedSecret) { $normalizedSecret = $tokenData.SecretKey }
    if (-not $normalizedSecret) { $normalizedSecret = $tokenData.Secret }
    if ($normalizedSecret) {
        $tokenData | Add-Member -NotePropertyName 'Secret' -NotePropertyValue $normalizedSecret -Force
    }

    return $tokenData
}
