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

### Test-AgentInstallation.ps1

Runs four end-to-end installation scenarios against a live Liongard instance. Requires Administrator rights.

By default the script downloads the specified agent version automatically before running tests. Pass `-DownloadAgent $false` to supply your own installer.

```powershell
# Download and test version 5.3.0
.\Scripts\Test-AgentInstallation.ps1 `
    -LiongardURL "us1.app.liongard.com" `
    -AdminApiKey "your-key" -AdminApiSecret "your-secret" `
    -Version "5.3.0"

# Test using a pre-downloaded MSI
.\Scripts\Test-AgentInstallation.ps1 `
    -LiongardURL "us1.app.liongard.com" `
    -AdminApiKey "your-key" -AdminApiSecret "your-secret" `
    -DownloadAgent $false `
    -MSIPath "C:\LiongardAgent.msi"

# Skip environment and token creation (use existing)
.\Scripts\Test-AgentInstallation.ps1 `
    -LiongardURL "us1.app.liongard.com" `
    -AdminApiKey "your-key" -AdminApiSecret "your-secret" `
    -Version "5.3.0" `
    -TestEnvironmentName "MyEnvironment" `
    -AccessKey "token-key" -AccessSecret "token-secret" `
    -SkipEnvironmentCreation -SkipTokenCreation

# Delete all existing agents from the platform before testing
.\Scripts\Test-AgentInstallation.ps1 `
    -LiongardURL "us1.app.liongard.com" `
    -AdminApiKey "your-key" -AdminApiSecret "your-secret" `
    -Version "5.3.0" `
    -CleanupAllAgents
```

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-LiongardURL` | `[string]` | required | Liongard instance URL (e.g. `us1.app.liongard.com`) |
| `-AdminApiKey` | `[string]` | required | API key for admin operations |
| `-AdminApiSecret` | `[string]` | required | API secret for admin operations |
| `-DownloadAgent` | `[bool]` | `$true` | Download the agent installer before testing |
| `-Version` | `[Version]` | | Agent version to download (required when `-DownloadAgent $true`) |
| `-UseMsi` | `[switch]` | `$false` | Download and install the MSI instead of the .exe installer |
| `-PreviewGuid` | `[Guid]` | | GUID for preview build download URLs |
| `-MSIPath` | `[string]` | | Path to a pre-downloaded MSI (used when `-DownloadAgent $false`) |
| `-InstallerPath` | `[string]` | | Path to a pre-downloaded .exe installer (used when `-DownloadAgent $false`) |
| `-TestEnvironmentName` | `[string]` | auto | Name of the test environment |
| `-AccessKey` | `[string]` | | Pre-created Agent Install Token access key |
| `-AccessSecret` | `[string]` | | Pre-created Agent Install Token access secret |
| `-SkipEnvironmentCreation` | `[switch]` | `$false` | Use `-TestEnvironmentName` as-is without creating it |
| `-SkipTokenCreation` | `[switch]` | `$false` | Use `-AccessKey`/`-AccessSecret` without creating a new token |
| `-CleanupAllAgents` | `[switch]` | `$false` | Delete all existing agents from the platform before running tests |

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
| `task lint` | Run PSScriptAnalyzer against all module source files |
| `task validate` | Validate the module can be imported and list its commands |
| `task unblock` | Unblock all files after cloning (Windows only) |

Run `task --list` to see all tasks with descriptions.

### Pre-commit hooks

[pre-commit](https://pre-commit.com) runs PSScriptAnalyzer automatically before each commit. It is cross-platform (macOS, Linux, Windows).

**One-time setup:**

```bash
# Install pre-commit
pip install pre-commit        # all platforms
# or: brew install pre-commit  # macOS

# Install the git hook
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
| `Get-LiongardAgent` | Look up an agent by `-Name`, `-ID`, or `-NamePattern` |
| `Remove-LiongardAgent` | Delete an agent by `-AgentID`, `-AgentName`, or `-All` |
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
