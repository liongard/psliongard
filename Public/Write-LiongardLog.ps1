function Write-LiongardLog {
<#
.SYNOPSIS
    Writes a timestamped, color-coded log message to the console.

.DESCRIPTION
    Outputs a formatted log entry prefixed with the current timestamp and severity
    level. Used throughout PSLiongard module functions and scripts for consistent
    console output.

.PARAMETER Message
    The text to write.

.PARAMETER Level
    Severity label. Controls foreground color. Default: INFO.

.EXAMPLE
    Write-LiongardLog "Agent installed successfully" -Level SUCCESS

.EXAMPLE
    Write-LiongardLog "Connection refused" -Level ERROR
#>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,

        [ValidateSet("INFO", "SUCCESS", "WARNING", "ERROR")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "ERROR"   { "Red" }
        "WARNING" { "Yellow" }
        "SUCCESS" { "Green" }
        default   { "White" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}
