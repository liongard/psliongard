@{
    ModuleVersion     = '0.1.0'
    GUID              = 'a3c5e7b9-d1f2-4a6c-8e0f-2b4d6c8a0e2f'
    Author            = 'Liongard'
    CompanyName       = 'Liongard'
    Description       = 'PowerShell module for managing Liongard Agent lifecycle and platform operations.'
    PowerShellVersion = '5.1'
    RootModule        = 'PSLiongard.psm1'
    FunctionsToExport = @(
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
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
