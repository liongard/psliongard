# psliongard

The PSLiongard module contains the collection of scripts, tools and common code used to power the automation, configuration and deployment operations of the Liongard platform.

## Repo layout

```
liongard-powershell/
├── PSLiongard.psd1          # Module manifest
├── PSLiongard.psm1          # Module loader (dot-sources Private/ + Public/)
├── Private/               # Internal helpers – NOT exported
│   └── Invoke-LiongardApi.ps1
├── Public/                # Exported functions – one file per function
│   ├── Write-LiongardLog.ps1
│   ├── Get-LiongardAgent.ps1
│   ├── Remove-LiongardAgent.ps1
│   ├── New-LiongardEnvironment.ps1
│   ├── New-LiongardAccessToken.ps1
│   ├── Install-LiongardAgent.ps1
│   ├── Uninstall-LiongardAgent.ps1
│   ├── Install-Cosign.ps1
│   ├── Test-LiongardAgentHeartbeat.ps1
│   ├── Test-LiongardHeartbeatLog.ps1
│   └── Test-LiongardScheduledTask.ps1
├── Scripts/               # Standalone operational scripts
│   ├── Download-LiongardAgentInstaller.ps1
│   ├── Install-LiongardAgent.ps1
│   ├── Uninstall-LiongardAgent.ps1
│   └── RMM/               # RMM-specific install wrappers around the module
│       ├── NCentral/
│       │   ├── Install-LiongardAgent.ps1
│       │   └── README.md
│       └── NinjaRMM/
│           ├── Install-LiongardAgent.ps1
│           └── README.md
└── Tests/                 # Test files (*.Tests.ps1 – Pester-compatible)
    ├── Agent/
    │   └── Install-LiongardAgent.Tests.ps1   # Integration: agent install scenarios
    └── Unit/                                  # Pester unit tests for public functions
        ├── Get-LiongardAgent.Tests.ps1        # Example: mocking Invoke-LiongardApi, v1/v2 fallback
        └── Write-LiongardLog.Tests.ps1        # Example: mocking Write-Host inside module scope
```

## Module conventions

- All exported functions use the `Liongard` noun prefix.
- `Invoke-LiongardApi` is private; never call it from outside the module.
- `Write-LiongardLog` is exported so scripts can share the same log format.
- Each Public/ file contains exactly one function whose name matches the filename.

## Adding a new public function

1. Create `Public/Verb-LiongardNoun.ps1` containing the function.
2. Add the function name to `FunctionsToExport` in `PSLiongard.psd1`.
3. `PSLiongard.psm1` auto-discovers the file — no edits needed there.

## Adding a new script

Scripts live in `Scripts/` and begin with:
```powershell
Import-Module "$PSScriptRoot\..\PSLiongard.psd1" -Force
```

## Running scripts

```powershell
# Install the Liongard Agent on this machine
.\Scripts\Install-LiongardAgent.ps1 `
    -InstancePrefix   us1 `
    -ApiTokenKey      "key" -ApiTokenSecret   "secret" `
    -AgentTokenKey    "key" -AgentTokenSecret "secret" `
    -Environment      "Acme Corp"

# Install without environment assignment
.\Scripts\Install-LiongardAgent.ps1 `
    -InstancePrefix          us1 `
    -ApiTokenKey             "key" -ApiTokenSecret   "secret" `
    -AgentTokenKey           "key" -AgentTokenSecret "secret" `
    -IncludeEnvironmentValue $false

# Install with NetworkIQ components
.\Scripts\Install-LiongardAgent.ps1 `
    -InstancePrefix   us1 `
    -ApiTokenKey      "key" -ApiTokenSecret   "secret" `
    -AgentTokenKey    "key" -AgentTokenSecret "secret" `
    -Environment      "Acme Corp" `
    -InstallNetworkIQ $true

# Download latest agent installer (defaults to version 5.3.0, validates cosign signature)
.\Scripts\Download-LiongardAgentInstaller.ps1 -Version "5.3.0"

# Download a preview build
.\Scripts\Download-LiongardAgentInstaller.ps1 `
    -Version "5.4.0" `
    -PreviewGuid "54BA085D-AECD-4304-B279-B14216C11E93"

# Download without signature validation
.\Scripts\Download-LiongardAgentInstaller.ps1 -Version "5.3.0" -ValidateSignature $false

```

## Verify module loads correctly

```powershell
Import-Module .\PSLiongard.psd1 -Force
Get-Command -Module PSLiongard
```
