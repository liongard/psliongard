# Liongard Agent Deployment for NinjaOne (NinjaRMM)

PowerShell wrapper around the [PSLiongard](../../../PSLiongard.psd1) module's `Install-LiongardAgent` function, tuned for NinjaOne Script Variables.

## What it does

- Imports `PSLiongard.psd1` from `..\..\..\PSLiongard.psd1`. The script throws if the module fails to load.
- Accepts inputs from script parameters or environment variables, in this order:
  1. **Preferred (`.env`-compatible):** `LIONGARD_URL`, `LIONGARD_ACCESS_KEY`, `LIONGARD_ACCESS_SECRET`, `LIONGARD_ENVIRONMENT`
  2. **Legacy NinjaOne Script Variables:** `liongardurl`, `liongardaccesskey`, `liongardaccesssecret`, `liongardenvironment`
- URL-decodes `Environment`, so RMM-encoded values like `Acme%20%26%20Co` round-trip cleanly into the installer.
- Auto-corrects URL formatting (strips `https://`, appends `.app.liongard.com` if missing).
- Downloads the LTS MSI to `%TEMP%`, then delegates installation to the module.
- Appends a session transcript to `C:\ProgramData\Liongard\ScriptInstall.log`.

## Prerequisites

From your Liongard instance (Admin > Account > API Tokens):

- **Instance URL** — `yourdomain.app.liongard.com`
- **Access Key ID** + **Access Key Secret**

## Configure in NinjaOne

1. **Administration > Library > Scripting > Create New Script**.
2. Language: **PowerShell**, OS: **Windows**, Architecture: **All**.
3. Paste the contents of `Install-LiongardAgent.ps1`.
4. Define Script Variables on the right-hand side. New deployments should use the `LIONGARD_*` names so the same values can populate a local `.env` for testing:

   | Name | Type | Description |
   | :--- | :--- | :--- |
   | `LIONGARD_URL` | String | e.g. `us1.app.liongard.com` |
   | `LIONGARD_ACCESS_KEY` | Secret | Liongard Access Key ID |
   | `LIONGARD_ACCESS_SECRET` | Secret | Liongard Access Key Secret |
   | `LIONGARD_ENVIRONMENT` | String *(optional)* | Environment name; supports plain or URL-encoded |

   Existing deployments using lowercase `liongardurl` / `liongardaccesskey` / `liongardaccesssecret` / `liongardenvironment` continue to work as a fallback.

## Usage

### Manual (single device)

Select device > **Run Script** > pick this script. Run As: **System**. Fill in the variables and run.

### Automated policy

**Administration > Policies > Agent Policies** > target policy > **Scheduled Scripts > Add a Scheduled Script**. Map variables to **Organization Custom Fields** for dynamic per-client deployment.

### Local testing with `.env`

For dev-machine smoke tests, populate the repo-root `.env` (copy from `.env.example`) with `LIONGARD_URL`, `LIONGARD_ACCESS_KEY`, `LIONGARD_ACCESS_SECRET`, and optionally `LIONGARD_ENVIRONMENT`, then run via Task or any wrapper that loads the `.env` into the process environment. The script picks the env vars up automatically when the matching parameter is absent.

> **Module dependency:** the script expects `PSLiongard.psd1` at `..\..\..\PSLiongard.psd1` relative to its location. Deploy the whole repo (or arrange equivalent placement) before running.

## URL encoding (when needed)

If your Environment name contains `&`, `,`, or other characters that confuse RMM argument parsing, URL-encode it before storing in `liongardenvironment`:

| You enter | Script decodes to |
| :--- | :--- |
| `Bruce%20%26%20Wayne%2C%20LLP` | `Bruce & Wayne, LLP` |

Plain text works for simple names; encoding is the fail-safe.

## Troubleshooting

| File | Contents |
| :--- | :--- |
| `C:\ProgramData\Liongard\ScriptInstall.log` | PowerShell session transcript (module log lines, exit codes). |
| `%TEMP%\LiongardAgent-Install-*.log` | MSI log emitted by `msiexec.exe /L*V`. Check for OS / installer errors. |

| Symptom | Likely cause |
| :--- | :--- |
| `FATAL ERROR: Missing required variables` | Script Variables blank or argument names misspelled. |
| `Insufficient disk space` | Less than 200 MB free on `C:`. |
| Service installed but not running | Credentials likely invalid — check `INVALIDMSG` in the MSI log. |
