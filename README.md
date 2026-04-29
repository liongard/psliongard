# PSLiongard

PowerShell module and scripts for managing the Liongard Agent lifecycle — downloading, installing, uninstalling, and validating agents against a Liongard instance.

https://github.com/liongard/psliongard

## Requirements

- Windows (PowerShell 5.1+)
- Administrator rights for install/uninstall operations
- A Liongard instance URL, API key, and API secret

## Getting started

### 1. Clone the repo

```powershell
git clone https://github.com/liongard/psliongard
cd psliongard
```

### 2. Unblock the files (Windows only)

Windows marks files downloaded from the internet as blocked. Run this once from the repo root to avoid execution prompts:

```powershell
Get-ChildItem -Path . -Recurse | Unblock-File
```

### 3. Import the module

```powershell
Import-Module .\PSLiongard.psd1 -Force
Get-Command -Module PSLiongard
```

---

## Repo layout

```
psliongard/
├── PSLiongard.psd1          # Module manifest
├── PSLiongard.psm1          # Module loader (dot-sources Private/ + Public/)
├── Private/                 # Internal helpers — NOT exported
│   └── Invoke-LiongardApi.ps1
├── Public/                  # Exported functions — one file per function
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
├── Scripts/                 # Standalone operational scripts
│   ├── Download-LiongardAgentInstaller.ps1
│   └── Install-LiongardAgent.ps1
└── Tests/                   # Test files (*.Tests.ps1 – Pester-compatible)
    ├── Agent/
    │   └── Install-LiongardAgent.Tests.ps1   # Integration: agent install scenarios
    └── Unit/                                  # Pester unit tests for public functions
        ├── Get-LiongardAgent.Tests.ps1        # Example: mocking Invoke-LiongardApi, v1/v2 fallback
        └── Write-LiongardLog.Tests.ps1        # Example: mocking Write-Host inside module scope
```

---

## Running Scripts

Scripts live in `Scripts/` and import the module automatically. Run them from the repo root or with their full path.

### Download-LiongardAgentInstaller.ps1

Downloads the Liongard Agent installer and verifies its integrity. For versions 5.2.1+ the SHA-256 checksum is verified; for 5.3.0+ the cosign signature is verified (cosign is installed automatically if not present).

```powershell
# Download the default version
.\Scripts\Download-LiongardAgentInstaller.ps1 -Version "5.3.0"

# Download a preview build
.\Scripts\Download-LiongardAgentInstaller.ps1 `
    -Version "5.2.1" `
    -PreviewGuid "54BA085D-AECD-4304-B279-B14216C11E93"

# Download the MSI instead of the .exe installer
.\Scripts\Download-LiongardAgentInstaller.ps1 -Version "5.3.0" -UseMsi

# Skip cosign signature validation
.\Scripts\Download-LiongardAgentInstaller.ps1 -Version "5.3.0" -ValidateSignature $false
```

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-Version` | `[Version]` | `5.3.0` | Agent version to download |
| `-UseMsi` | `[switch]` | `$false` | Download MSI instead of .exe installer |
| `-PreviewGuid` | `[Guid]` | | GUID for preview build download URLs |
| `-ValidateSignature` | `[bool]` | `$true` | Verify cosign signature after download |
| `-OutFile` | `[string]` | auto | Override the output filename |

---

## Development

### Task runner

[Task](https://taskfile.dev) is used to run common development commands. Install it once:

| Platform | Command |
|---|---|
| macOS | `brew install go-task` |
| Windows | `winget install Task.Task` |
| Linux | `sh -c "$(curl --location https://taskfile.dev/install.sh)" -- -d -b /usr/local/bin` |

Available tasks:

| Task | Description |
|---|---|
| `task install:deps` | Install all development dependencies (one-time setup) |
| `task lint` | Run PSScriptAnalyzer against all module source files |
| `task validate` | Validate the module can be imported and list its commands |
| `task test:agent` | Run agent installation test suite against a live instance (Windows, requires `.env`) |
| `task unblock` | Unblock all files after cloning (Windows only) |

Run `task --list` to see all tasks with descriptions. Pass `--force` to reinstall dependencies that are already present.

### Pre-commit hooks

[pre-commit](https://pre-commit.com) runs PSScriptAnalyzer and [gitleaks](https://github.com/gitleaks/gitleaks) (secrets detection) automatically before each commit. It is installed automatically by `task install:deps`.

To install the hook manually or on a platform without Task:

```bash
# macOS / Linux (via Homebrew)
brew install pre-commit

# Windows (via uv)
winget install astral-sh.uv
uv tool install pre-commit
uv tool update-shell

# Install the git hook (all platforms)
pre-commit install
```

**After that**, `git commit` will automatically run PSScriptAnalyzer on changed PowerShell files. To run it manually against all files:

```bash
pre-commit run --all-files
```

---

## Module functions

The module exposes these functions after `Import-Module .\PSLiongard.psd1`:

| Function | Description |
|---|---|
| `Write-LiongardLog` | Timestamped, colour-coded console logging |
| `Get-LiongardAgent` | Look up an agent by `-Name`, `-ID`, `-NamePattern`, or `-Conditions` |
| `Remove-LiongardAgent` | Delete an agent by `-AgentID` or `-AgentName` |
| `New-LiongardEnvironment` | Create an environment on the platform |
| `New-LiongardAccessToken` | Create an Agent Install Token |
| `Install-LiongardAgent` | Install the agent via MSI or .exe installer |
| `Uninstall-LiongardAgent` | Uninstall the agent and clean up local files |
| `Install-Cosign` | Download, verify, and install the cosign binary |
| `Test-LiongardAgentHeartbeat` | Assert the agent has heartbeated within N minutes |
| `Test-LiongardHeartbeatLog` | Assert heartbeat log files exist and have content |
| `Test-LiongardScheduledTask` | Assert the `LiongardAgentUpdater` scheduled task exists |

---

## Legal

This project is licensed under the [Apache License 2.0](LICENSE).

Use of this software is subject to the Liongard [Terms of Use](https://www.liongard.com/terms-of-use/) and [Privacy Policy](https://www.liongard.com/privacy-policy/).

"Liongard" and the Liongard logo are trademarks of Liongard, Inc. Unauthorized use is prohibited.
