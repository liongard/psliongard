function Test-LiongardHeartbeatLog {
<#
.SYNOPSIS
    Verifies that heartbeat log files exist in the Liongard Agent log directory.

.DESCRIPTION
    Checks for the presence of heartbeat log files (*heartbeat*.log) or a general
    agent.log file in the agent log directory. Returns $true when at least one
    non-empty log file is found.

.PARAMETER LogsDirectory
    Path to the agent logs folder.
    Default: C:\Program Files (x86)\LiongardInc\LiongardAgent\logs

.OUTPUTS
    System.Boolean
    $true if heartbeat or agent log files were found with content, $false otherwise.

.EXAMPLE
    Test-LiongardHeartbeatLog

.EXAMPLE
    Test-LiongardHeartbeatLog -LogsDirectory "D:\LiongardAgent\logs"
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string]$LogsDirectory = "C:\Program Files (x86)\LiongardInc\LiongardAgent\logs"
    )

    Write-LiongardLog "Checking for heartbeat logs in: $LogsDirectory"

    if (-not (Test-Path $LogsDirectory)) {
        Write-LiongardLog "Logs directory does not exist: $LogsDirectory" "ERROR"
        return $false
    }

    $heartbeatLogs = Get-ChildItem -Path $LogsDirectory -Filter "*heartbeat*" -ErrorAction SilentlyContinue

    if ($heartbeatLogs -and $heartbeatLogs.Count -gt 0) {
        Write-LiongardLog "Found $($heartbeatLogs.Count) heartbeat log file(s):" "SUCCESS"
        foreach ($log in $heartbeatLogs) {
            $size      = (Get-Item $log.FullName).Length
            $lastWrite = (Get-Item $log.FullName).LastWriteTime
            Write-LiongardLog "  - $($log.Name) ($size bytes, last modified: $lastWrite)"
            Write-LiongardLog "    $(if ($size -gt 0) { 'File has content' } else { 'File is empty' })" $(if ($size -gt 0) { 'SUCCESS' } else { 'WARNING' })
        }
        return $true
    }

    $agentLog = Join-Path $LogsDirectory "agent.log"
    if (Test-Path $agentLog) {
        $logFile = Get-Item $agentLog
        Write-LiongardLog "Found agent.log ($($logFile.Length) bytes, last modified: $($logFile.LastWriteTime))" "SUCCESS"
        if ($logFile.Length -gt 0) {
            Write-LiongardLog "File has content" "SUCCESS"
            return $true
        } else {
            Write-LiongardLog "agent.log is empty" "WARNING"
            return $false
        }
    }

    Write-LiongardLog "No heartbeat log files or agent.log found in: $LogsDirectory" "ERROR"

    $allLogs = Get-ChildItem -Path $LogsDirectory -Filter "*.log" -ErrorAction SilentlyContinue
    if ($allLogs) {
        Write-LiongardLog "Other log files present:" "INFO"
        foreach ($log in $allLogs) { Write-LiongardLog "  - $($log.Name)" }
    } else {
        Write-LiongardLog "No log files found in directory" "WARNING"
    }

    return $false
}
