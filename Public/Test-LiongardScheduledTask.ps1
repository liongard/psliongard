function Test-LiongardScheduledTask {
<#
.SYNOPSIS
    Verifies that the Liongard Agent scheduled task exists and is enabled.

.DESCRIPTION
    Looks up the named scheduled task and reports its state, author, and enabled
    status. First searches the root task folder; if not found there and -TaskPath
    is supplied, retries with the fully-qualified path.

    Returns $true when the task is found (regardless of author match), $false
    when the task cannot be located.

.PARAMETER TaskName
    Name of the scheduled task to check. Default: LiongardAgentUpdater.

.PARAMETER TaskPath
    Optional task folder path (e.g. "\Liongard"). When provided, used as a
    fallback if the task is not found in the root folder.

.PARAMETER ExpectedAuthor
    Author string to compare against the task definition. A mismatch is logged
    as a warning but does not cause the function to return $false.
    Default: Liongard\DevelopmentTeam.

.OUTPUTS
    System.Boolean
    $true if the scheduled task was found, $false if not found.

.EXAMPLE
    Test-LiongardScheduledTask

.EXAMPLE
    Test-LiongardScheduledTask -TaskName "LiongardAgentUpdater" -TaskPath "\Liongard"
#>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ExpectedAuthor',
        Justification = 'Used inside $checkTask scriptblock closure')]
    [OutputType([bool])]
    param(
        [string]$TaskName       = "LiongardAgentUpdater",
        [string]$TaskPath,
        [string]$ExpectedAuthor = "Liongard\DevelopmentTeam"
    )

    Write-LiongardLog "Checking for scheduled task: $TaskName"

    $checkTask = {
        param($t)
        Write-LiongardLog "Found: $($t.TaskName) at $($t.TaskPath)" "SUCCESS"
        Write-LiongardLog "  State: $($t.State)  Author: $($t.Author)"
        if ($t.Author -eq $ExpectedAuthor) {
            Write-LiongardLog "  Author matches: $ExpectedAuthor" "SUCCESS"
        } else {
            Write-LiongardLog "  Author mismatch. Expected: $ExpectedAuthor, Got: $($t.Author)" "WARNING"
        }
        Write-LiongardLog "  Enabled: $($t.Settings.Enabled)" $(if ($t.Settings.Enabled) { 'SUCCESS' } else { 'WARNING' })
        return $true
    }

    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        return & $checkTask $task
    }
    catch {
        if (-not $TaskPath) {
            Write-LiongardLog "Scheduled task '$TaskName' not found" "ERROR"
            return $false
        }

        Write-LiongardLog "Not in root folder, trying path: $TaskPath\$TaskName" "WARNING"
        try {
            $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop
            return & $checkTask $task
        }
        catch {
            Write-LiongardLog "Scheduled task '$TaskName' not found at $TaskPath\$TaskName" "ERROR"
            return $false
        }
    }
}
