function Invoke-LiongardApi {
    param(
        [Parameter(Mandatory=$true)]
        [string]$LiongardURL,

        [Parameter(Mandatory=$true)]
        [string]$Method,

        [Parameter(Mandatory=$true)]
        [string]$Endpoint,

        [hashtable]$Body = $null,

        [Parameter(Mandatory=$true)]
        [string]$ApiKey,

        [Parameter(Mandatory=$true)]
        [string]$ApiSecret,

        [switch]$UseApiSubdomain = $false
    )

    if ($UseApiSubdomain) {
        $baseUrl = "https://api.$LiongardURL"
    } else {
        $baseUrl = "https://$LiongardURL"
    }

    $uri         = "$baseUrl$Endpoint"
    $credentials = "$ApiKey`:$ApiSecret"
    $bytes       = [System.Text.Encoding]::UTF8.GetBytes($credentials)
    $base64Key   = [System.Convert]::ToBase64String($bytes)

    try {
        $headers = @{
            "X-ROAR-API-KEY" = $base64Key
            "Content-Type"   = "application/json"
            "Accept"         = "application/json"
        }

        $requestParams = @{
            Uri             = $uri
            Method          = $Method
            Headers         = $headers
            UseBasicParsing = $true
        }

        if ($Body) {
            $requestParams.Body = ($Body | ConvertTo-Json -Depth 10)
        }

        $response = Invoke-RestMethod @requestParams
        return @{
            Success = $true
            Data    = $response
        }
    }
    catch {
        $errorDetails = $_.ErrorDetails.Message
        if ($errorDetails) {
            try {
                $errorObj     = $errorDetails | ConvertFrom-Json
                $errorMessage = $errorObj.message
            } catch {
                $errorMessage = $errorDetails
            }
        } else {
            $errorMessage = $_.Exception.Message
        }

        Write-LiongardLog "API call failed: $Method $Endpoint - $errorMessage" "ERROR"
        return @{
            Success    = $false
            Error      = $errorMessage
            StatusCode = $_.Exception.Response.StatusCode.value__
        }
    }
}
