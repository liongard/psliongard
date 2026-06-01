# Liongard Agent Deployment for N-able N-central

PowerShell wrapper around the [PSLiongard](../../../PSLiongard.psd1) module's `Install-LiongardAgent` function, tuned for N-able N-central.

## What it does

- Imports `PSLiongard.psd1` from `..\..\..\PSLiongard.psd1`. The script throws if the module fails to load.
- Reads `Url`, `AccessKey`, `AccessSecret`, `Environment` from script parameters, falling back to `.env`-style environment variables:
  - `LIONGARD_URL`
  - `LIONGARD_ACCESS_KEY`
  - `LIONGARD_ACCESS_SECRET`
  - `LIONGARD_ENVIRONMENT` *(optional)*
- Auto-detects `Environment` from `AgentConfig.xml` (`CustomerName`) when neither parameter nor env var supplies one:
  - `%ProgramFiles(x86)%\N-able Technologies\Windows Agent\config\AgentConfig.xml`
  - `%ProgramFiles%\N-able Technologies\Windows Agent\config\AgentConfig.xml`
- Auto-corrects URL formatting (strips `https://`, appends `.app.liongard.com` if missing).
- Downloads the LTS MSI to `%TEMP%`, then delegates installation to the module.
- Appends a session transcript to `C:\ProgramData\Liongard\ScriptInstall.log`.

## Prerequisites

From your Liongard instance (Admin > Account > API Tokens):

- **Instance URL** — `yourdomain.app.liongard.com`
- **Access Key ID** + **Access Key Secret**

(Optional) For automation, add a customer-level Custom Property in N-central:

- **Administration > Custom Properties > Add > By Customers**
- Name: `Liongard_Environment_Name`, Type: `Text`
- Populate per customer with the exact Liongard Environment name.

## Method A: Script Repository (recommended)

1. **Configuration > Scheduled Tasks > Script/Software Repository**.
2. Add a new Scripting item; upload `Install-LiongardAgent.ps1`.
3. Mark `AccessSecret` as **Password** type.
4. Deploy: Select devices > Add Task > Run Script. Map the `Environment` parameter to `Liongard_Environment_Name` if you set it up; otherwise the script will auto-detect from `AgentConfig.xml`.

## Method B: Ad-hoc run

Select a device > Add Task > Run Script. Upload the `.ps1` and set Command Line Parameters:

```text
-Url "us1.app.liongard.com" -AccessKey "YOUR_KEY" -AccessSecret "YOUR_SECRET" -Environment "Acme Corp"
```

Run As: **LocalSystem**.

## Local testing with `.env`

For dev-machine smoke tests, populate the repo-root `.env` (copy from `.env.example`) with `LIONGARD_URL`, `LIONGARD_ACCESS_KEY`, `LIONGARD_ACCESS_SECRET`, and optionally `LIONGARD_ENVIRONMENT`, then run via Task or any wrapper that loads the `.env` into the process environment. The script picks the env vars up automatically when the matching parameter is absent.

> **Module dependency:** the script expects `PSLiongard.psd1` at `..\..\..\PSLiongard.psd1` relative to its location. Deploy the whole repo (or arrange equivalent placement) before running.

## Troubleshooting

| File | Contents |
| :--- | :--- |
| `C:\ProgramData\Liongard\ScriptInstall.log` | PowerShell session transcript (module log lines, exit codes). |
| `%TEMP%\LiongardAgent-Install-*.log` | MSI log emitted by `msiexec.exe /L*V`. Check for OS / installer errors. |

| Symptom | Likely cause |
| :--- | :--- |
| Agent lands in "Unknown" environment | `Environment` was empty and `AgentConfig.xml` had no `CustomerName`. Pass `-Environment` explicitly or populate the N-central customer name. |
| `FATAL ERROR: Missing required variables` | One of `-Url` / `-AccessKey` / `-AccessSecret` was not passed (interactive prompt is suppressed under N-central). |
| `INVALIDMSG` in MSI log | Credentials likely invalid — verify Access Key ID/Secret. |
