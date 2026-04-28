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

    # Normalize AccessKeyID across API versions that return different property names
    if ($tokenData.PSObject.Properties['AccessKeyId'] -and -not $tokenData.PSObject.Properties['AccessKeyID']) {
        $tokenData | Add-Member -NotePropertyName 'AccessKeyID' -NotePropertyValue $tokenData.AccessKeyId -Force
    } elseif ($tokenData.PSObject.Properties['Key'] -and -not $tokenData.PSObject.Properties['AccessKeyID']) {
        $tokenData | Add-Member -NotePropertyName 'AccessKeyID' -NotePropertyValue $tokenData.Key -Force
    } elseif ($tokenData.PSObject.Properties['AccessKey'] -and -not $tokenData.PSObject.Properties['AccessKeyID']) {
        $tokenData | Add-Member -NotePropertyName 'AccessKeyID' -NotePropertyValue $tokenData.AccessKey -Force
    } elseif ($tokenData.PSObject.Properties['ID'] -and -not $tokenData.PSObject.Properties['AccessKeyID']) {
        $tokenData | Add-Member -NotePropertyName 'AccessKeyID' -NotePropertyValue $tokenData.ID -Force
    }

    # Normalize Secret across API versions
    if ($tokenData.PSObject.Properties['AccessKeySecret'] -and -not $tokenData.PSObject.Properties['Secret']) {
        $tokenData | Add-Member -NotePropertyName 'Secret' -NotePropertyValue $tokenData.AccessKeySecret -Force
    } elseif ($tokenData.PSObject.Properties['SecretAccessKey'] -and -not $tokenData.PSObject.Properties['Secret']) {
        $tokenData | Add-Member -NotePropertyName 'Secret' -NotePropertyValue $tokenData.SecretAccessKey -Force
    } elseif ($tokenData.PSObject.Properties['SecretKey'] -and -not $tokenData.PSObject.Properties['Secret']) {
        $tokenData | Add-Member -NotePropertyName 'Secret' -NotePropertyValue $tokenData.SecretKey -Force
    }

    return $tokenData
}
