# PSScriptAnalyzer settings for PSLiongard
# Run:  Invoke-ScriptAnalyzer -Path . -Settings .\PSScriptAnalyzerSettings.psd1 -Recurse
# Install: Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
@{
    Severity = @('Error', 'Warning', 'Information')

    ExcludeRules = @(
        # Write-LiongardLog is an intentional console-output logging function
        'PSAvoidUsingWriteHost'
    )

    Rules = @{
        # Enforce compatibility with PowerShell 5.1 and 7.x
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.2', '7.4')
        }

        # Warn on positional parameters in function calls (harder to read)
        PSAvoidUsingPositionalParameters = @{
            Enable           = $true
            CommandAllowList = @('Write-Host', 'Join-Path', 'Split-Path')
        }

        # Flag declared variables that are never read
        PSUseDeclaredVarsMoreThanAssignments = @{
            Enable = $true
        }

        # Flag parameters that are declared but never used
        PSReviewUnusedParameter = @{
            Enable = $true
        }
    }
}
