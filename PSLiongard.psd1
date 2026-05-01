@{
    ModuleVersion        = '0.2.0'
    GUID                 = 'a3c5e7b9-d1f2-4a6c-8e0f-2b4d6c8a0e2f'
    Author               = 'Liongard'
    CompanyName          = 'Liongard, Inc.'
    Copyright            = 'Copyright (c) 2026 Liongard, Inc.'
    Description          = 'PowerShell module for Liongard platform operations.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    RootModule           = 'PSLiongard.psm1'
    FunctionsToExport    = @(
        'Write-LiongardLog',
        'Get-LiongardAgent',
        'Remove-LiongardAgent',
        'New-LiongardEnvironment',
        'New-LiongardAccessToken',
        'Install-LiongardAgent',
        'Uninstall-LiongardAgent',
        'Install-Cosign',
        'Test-LiongardAgentHeartbeat',
        'Test-LiongardHeartbeatLog',
        'Test-LiongardScheduledTask'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags       = @('Liongard', 'Agent', 'MSP', 'Windows')
            LicenseUri = 'https://github.com/liongard/psliongard/blob/main/LICENSE'
            ProjectUri = 'https://github.com/liongard/psliongard'
        }
    }
}
