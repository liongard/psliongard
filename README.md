# PSLiongard

PowerShell module and scripts for managing the Liongard Agent lifecycle — downloading, installing, uninstalling, and validating agents against a Liongard instance.

[github.com/liongard/psliongard](https://github.com/liongard/psliongard)

---

## Getting started

### Requirements

- Windows 10 / 11 with PowerShell 5.1 or later (built-in)
- Administrator rights for install and uninstall operations

### Step 1 — Get the module

**Option A: Download ZIP** *(no tools required)*

1. Open [github.com/liongard/psliongard](https://github.com/liongard/psliongard) in your browser
2. Click **Code → Download ZIP**
3. Extract the ZIP to a folder, e.g. `C:\Tools\psliongard`

**Option B: Clone with git**

```powershell
git clone https://github.com/liongard/psliongard C:\Tools\psliongard
```

### Step 2 — Open an Administrator PowerShell

Press **Win+X** and choose **Terminal (Admin)** or **Windows PowerShell (Admin)**.

### Step 3 — Unblock and import

Windows marks files downloaded from the internet as blocked. Run this block once, replacing the path if you extracted to a different folder:

```powershell
cd C:\Tools\psliongard
Get-ChildItem -Recurse | Unblock-File
Import-Module .\PSLiongard.psd1 -Force
Get-Command -Module PSLiongard
```

If the import succeeded you'll see ~11 functions listed (e.g. `Get-LiongardAgent`, `Install-LiongardAgent`, etc.).

---

## Module functions

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

## Scripts

Scripts live in `Scripts/` and import the module automatically. Run them from the repo root or with their full path. All scripts require Administrator rights.

### Install-LiongardAgent.ps1

Installs the Liongard Agent on the local machine. Handles pre-uninstall of an existing agent, environment resolution, access token creation, installer download, and post-install validation.

```powershell
# Basic install — assigns the agent to an environment
.\Scripts\Install-LiongardAgent.ps1 `
    -InstancePrefix   us1 `
    -ApiTokenKey      "your-admin-key" `
    -ApiTokenSecret   "your-admin-secret" `
    -AgentTokenKey    "your-agent-key" `
    -AgentTokenSecret "your-agent-secret" `
    -Environment      "Acme Corp"

# Install without environment assignment
.\Scripts\Install-LiongardAgent.ps1 `
    -InstancePrefix          us1 `
    -ApiTokenKey             "your-admin-key" `
    -ApiTokenSecret          "your-admin-secret" `
    -AgentTokenKey           "your-agent-key" `
    -AgentTokenSecret        "your-agent-secret" `
    -IncludeEnvironmentValue $false

# Install with Network IQ (installs Npcap for network discovery)
.\Scripts\Install-LiongardAgent.ps1 `
    -InstancePrefix   us1 `
    -ApiTokenKey      "your-admin-key" `
    -ApiTokenSecret   "your-admin-secret" `
    -AgentTokenKey    "your-agent-key" `
    -AgentTokenSecret "your-agent-secret" `
    -Environment      "Acme Corp" `
    -InstallNetworkIQ $true
```

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-InstancePrefix` | `[string]` | required | Liongard instance prefix (e.g. `us1`) |
| `-ApiTokenKey` | `[string]` | required | Admin API key |
| `-ApiTokenSecret` | `[string]` | required | Admin API secret |
| `-AgentTokenKey` | `[string]` | required | Agent Install Token key |
| `-AgentTokenSecret` | `[string]` | required | Agent Install Token secret |
| `-Environment` | `[string]` | | Environment name to assign the agent to |
| `-IncludeEnvironmentValue` | `[bool]` | `$true` | Pass the environment to the installer |
| `-InstallNetworkIQ` | `[bool]` | `$false` | Install Npcap for network discovery |
| `-EnablePreUninstall` | `[bool]` | `$true` | Remove an existing agent before installing |
| `-InstallerUrl` | `[string]` | LTS URL | Override the installer download URL |

Run `Get-Help .\Scripts\Install-LiongardAgent.ps1 -Full` for all parameters.

---

### Download-LiongardAgentInstaller.ps1

Downloads the Liongard Agent installer and verifies its integrity. For versions 5.2.1+ the SHA-256 checksum is verified; for 5.3.0+ the cosign signature is also verified (cosign is installed automatically if not present).

```powershell
# Download version 5.3.0 (verifies cosign signature)
.\Scripts\Download-LiongardAgentInstaller.ps1 -Version "5.3.0"

# Download a preview build
.\Scripts\Download-LiongardAgentInstaller.ps1 `
    -Version     "5.4.0" `
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

For contributors working on the module source.

### Bootstrap

Install [Task](https://taskfile.dev) for your platform, then run `task install:deps` once to get everything else.

| Platform | Install Task |
|---|---|
| macOS | `brew install go-task` |
| Windows | `winget install Task.Task` |
| Linux | `sh -c "$(curl --location https://taskfile.dev/install.sh)" -- -d -b /usr/local/bin` |

> **Windows — winget not available?** Run this from an Administrator PowerShell to install it first:
>
> ```powershell
> powershell -NonInteractive -Command "Invoke-WebRequest -Uri https://aka.ms/getwinget -OutFile winget.msixbundle -UseBasicParsing"
> powershell -NonInteractive -Command "if ((Get-AuthenticodeSignature winget.msixbundle).Status -ne 'Valid') { throw \"winget signature invalid [$(Get-AuthenticodeSignature winget.msixbundle).Status]\" }"
> Add-AppxPackage "winget.msixbundle"; Remove-Item "winget.msixbundle"
> winget install Task.Task
> ```

Then from the repo root:

```powershell
task install:deps
```

This installs PowerShell Core, PSScriptAnalyzer, and the pre-commit git hook in one step.

### Running the linter

```powershell
task lint
```

PSScriptAnalyzer runs against all module source files using the rules in `PSScriptAnalyzerSettings.psd1`. Resolve any warnings before committing — the pre-commit hook runs the same check automatically.

### All tasks

| Task | Description |
|---|---|
| `task install:deps` | Install all development dependencies (one-time setup) |
| `task lint` | Run PSScriptAnalyzer against all module source files |
| `task validate` | Validate the module can be imported and list its commands |
| `task test:agent` | Run agent installation test suite against a live instance (Windows, requires `.env`) |
| `task unblock` | Unblock all files after cloning (Windows only) |

Run `task --list` for descriptions. Pass `--force` to reinstall dependencies that are already present.

### Pre-commit hooks

[pre-commit](https://pre-commit.com) runs PSScriptAnalyzer and [gitleaks](https://github.com/gitleaks/gitleaks) (secrets detection) automatically before each commit. Installed by `task install:deps`.

To install manually without Task:

```bash
# macOS / Linux
brew install pre-commit && pre-commit install

# Windows
winget install astral-sh.uv
uv tool install pre-commit && uv tool update-shell
uv tool run pre-commit install
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
└── Tests/                   # Test files (*.Tests.ps1 — Pester-compatible)
    ├── Agent/
    │   └── Install-LiongardAgent.Tests.ps1   # Integration: agent install scenarios
    └── Unit/                                  # Pester unit tests for public functions
        ├── Get-LiongardAgent.Tests.ps1        # Example: mocking Invoke-LiongardApi, v1/v2 fallback
        └── Write-LiongardLog.Tests.ps1        # Example: mocking Write-Host inside module scope
```

---

## Legal

This project is licensed under the [Apache License 2.0](LICENSE).

Use of this software is subject to the Liongard [Terms of Use](https://www.liongard.com/terms-of-use/) and [Privacy Policy](https://www.liongard.com/privacy-policy/).

"Liongard" and the Liongard logo are trademarks of Liongard, Inc. Unauthorized use is prohibited.
