#requires -Version 5.1
#requires -RunAsAdministrator
<#
.SYNOPSIS
    Deploys the Liongard Agent EXE installer bundle to this machine.

.DESCRIPTION
    Downloads the LiongardAgent EXE from InstallerUrl, optionally removes any
    existing installation first, resolves the target environment name against the
    Liongard API (exact, normalized, prefix, and contains fallbacks), handles
    MachineGuid collision by generating a DEVICEGUID override when needed, launches
    the installer with credential and proxy management, parses the bundle log for
    per-component results, and writes a JSON summary artifact to the Folder directory.

    Requires PowerShell 5.1 and must be run as Administrator.

.PARAMETER InstancePrefix
    Liongard instance prefix (e.g. "us1" for us1.app.liongard.com). May also be
    passed as a full URL - the script extracts the subdomain automatically.

.PARAMETER ApiTokenKey
    API key used for Liongard platform operations (environment resolution, agent
    lookup, optional remote agent deletion).

.PARAMETER ApiTokenSecret
    Secret paired with ApiTokenKey.

.PARAMETER AgentTokenKey
    Agent install token Access Key. Passed to the EXE installer as LiongardAccessKey.

.PARAMETER AgentTokenSecret
    Agent install token Secret. Passed to the EXE installer as LiongardAccessSecret.

.PARAMETER Environment
    Target Liongard environment name. Fuzzy-matched against the platform list
    (exact -> normalized -> prefix -> contains). Required when IncludeEnvironmentValue
    is $true (the default).

.PARAMETER AgentDescription
    Optional free-text description written to the agent record.

.PARAMETER EnablePreUninstall
    When $true (default), any existing Liongard Agent installation is removed before
    installing. Set to $false to skip on a clean machine.

.PARAMETER IncludeEnvironmentValue
    When $true (default), Environment is resolved and passed to the installer. Set to
    $false to install without an environment assignment.

.PARAMETER RemoveAgentFromPlatform
    When $true, attempts to delete the matching Liongard platform record for this
    machine before installing. Requires EnablePreUninstall to also be $true.

.PARAMETER MinimumRemoteDeletionScore
    Confidence threshold (0-100) for remote agent deletion. Default 50. Score is
    based on MachineGuid (100 pts), hostname (30 pts), and MAC address (40 pts).

.PARAMETER Folder
    Working directory for the downloaded installer, log file, and summary artifact.
    Created if it does not exist. Default: C:\Liongard.

.PARAMETER InstallerUrl
    URL for the EXE installer to download. Defaults to the public LTS release.

.PARAMETER InstallerFileName
    Filename used when saving the installer to Folder.

.PARAMETER InstallEnhancedNetworkDiscovery
    Pass 1 (true) to the installer's InstallEnhancedNetworkDiscovery argument
    (installs Npcap and the C++ runtime for Enhanced Network Discovery).
    Default $false.

.PARAMETER EulaAccepted
    Forwarded to the installer as EulaAccepted. Must be $true for silent install.

.PARAMETER SuppressRestart
    Adds /norestart to the installer command line. Default $true.

.PARAMETER PassiveMode
    Uses /passive instead of /quiet for a visible progress UI. Default $false.

.PARAMETER InstallerLogPath
    Explicit path for the bootstrapper log. Defaults to AgentInstall.log inside Folder.

.PARAMETER ProxyUrl
    Explicit proxy URL forwarded to the installer as ProxyUrl. Leave empty to install
    without a proxy.

.PARAMETER AutoUpdate
    When set, passes the value as AutoUpdateArgumentName to the installer. Leave $null
    to omit the argument and accept the installer default.

.PARAMETER AutoUpdateArgumentName
    MSI property name for the AutoUpdate argument. Default "AUTOUPDATE".

.PARAMETER ClearProxyEnvironmentForInstaller
    When $true (default), strips HTTP_PROXY / HTTPS_PROXY / ALL_PROXY from the
    installer child process environment. If ProxyUrl is also set, that value is
    injected instead.

.EXAMPLE
    .\Install-LiongardAgent.ps1 `
        -InstancePrefix   us1 `
        -ApiTokenKey      "key" -ApiTokenSecret   "secret" `
        -AgentTokenKey    "key" -AgentTokenSecret "secret" `
        -Environment      "Acme Corp"

.EXAMPLE
    .\Install-LiongardAgent.ps1 `
        -InstancePrefix                     us1 `
        -ApiTokenKey                        "key" -ApiTokenSecret   "secret" `
        -AgentTokenKey                      "key" -AgentTokenSecret "secret" `
        -IncludeEnvironmentValue            $false `
        -InstallEnhancedNetworkDiscovery    $true

.EXAMPLE
    .\Install-LiongardAgent.ps1 `
        -InstancePrefix          us1 `
        -ApiTokenKey             "key" -ApiTokenSecret   "secret" `
        -AgentTokenKey           "key" -AgentTokenSecret "secret" `
        -Environment             "Acme Corp" `
        -RemoveAgentFromPlatform $true `
        -ProxyUrl                "http://proxy.example.com:8080"
#>

[CmdletBinding()]
param(
    # -- Required: Liongard connection & credentials ------------------------------

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$InstancePrefix,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ApiTokenKey,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ApiTokenSecret,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$AgentTokenKey,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$AgentTokenSecret,

    # -- Optional: Agent placement & behavior -------------------------------------

    [string]$Environment                     = '',
    [string]$AgentDescription                = '',
    [bool]$EnablePreUninstall                = $true,
    [bool]$IncludeEnvironmentValue           = $true,
    [bool]$RemoveAgentFromPlatform           = $false,
    [int]$MinimumRemoteDeletionScore         = 50,

    # -- Optional: Installer settings ---------------------------------------------

    [string]$Folder                          = 'C:\Liongard',
    [string]$InstallerUrl                    = 'https://agents.static.liongard.com/LiongardAgent-lts.exe',
    [string]$InstallerFileName               = 'LiongardAgent-lts.exe',
    [bool]$InstallEnhancedNetworkDiscovery                  = $false,
    [bool]$EulaAccepted                      = $true,
    [bool]$SuppressRestart                   = $true,
    [bool]$PassiveMode                       = $false,
    [string]$InstallerLogPath                = '',
    [string]$ProxyUrl                        = '',
    [Nullable[bool]]$AutoUpdate              = $null,
    [string]$AutoUpdateArgumentName          = 'AUTOUPDATE',
    [bool]$ClearProxyEnvironmentForInstaller = $true
)

try {
    Import-Module "$PSScriptRoot\..\PSLiongard.psd1" -Force -ErrorAction Stop
}
catch {
    throw "Failed to import PSLiongard module: $($_.Exception.Message)"
}

$script:TranscriptStarted = $false
$script:TranscriptPath = $null
$script:EnvironmentResolutionReason = $null
$script:RunWarnings = New-Object System.Collections.Generic.List[string]
$script:RunErrors = New-Object System.Collections.Generic.List[string]
$script:SummaryArtifactPath = $null
$script:CurrentSection = $null

function Convert-ToStringArray {
    param([Parameter()][object]$Value)

    if ($null -eq $Value) { return @() }

    if ($Value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
        return @($Value)
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        return @(
            $Value |
            ForEach-Object { if ($null -ne $_) { [string]$_ } } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
    }

    return @([string]$Value)
}

function Add-RunWarning {
    param([Parameter(Mandatory)][string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) { return }
    $script:RunWarnings.Add($Message) | Out-Null
    Write-Warning $Message
}

function Add-RunError {
    param([Parameter(Mandatory)][string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) { return }
    $script:RunErrors.Add($Message) | Out-Null
    Write-Error $Message
}

function Start-LogSection {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param([Parameter(Mandatory)][string]$Name)

    $script:CurrentSection = $Name
    Write-Host ("=== {0} ===" -f $Name)
}

function Write-SectionValue {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter()][object]$Value
    )

    $text = Convert-ValidationDetailToText -Detail $Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        $text = '<none>'
    }

    Write-Host ("{0}: {1}" -f $Label, $text)
}

function Convert-ToPlainObject {
    param([Parameter()][object]$Value)

    if ($null -eq $Value) { return $null }

    if ($Value -is [string] -or
        $Value -is [bool] -or
        $Value -is [int] -or
        $Value -is [long] -or
        $Value -is [double] -or
        $Value -is [decimal]) {
        return $Value
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $result[$key] = Convert-ToPlainObject -Value $Value[$key]
        }
        return [pscustomobject]$result
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $items = @()
        foreach ($item in $Value) {
            $items += ,(Convert-ToPlainObject -Value $item)
        }
        return @($items)
    }

    if ($Value.PSObject -and $Value.PSObject.Properties.Count -gt 0) {
        $result = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $result[$property.Name] = Convert-ToPlainObject -Value $property.Value
        }
        return [pscustomobject]$result
    }

    return [string]$Value
}

function Convert-ToSingleString {
    param([Parameter()][object]$Value)

    $items = @(Convert-ToStringArray -Value $Value)
    if ($items.Count -eq 0) { return $null }
    return ($items -join '; ')
}

function Complete-LogSection {
    if ($script:CurrentSection) {
        Write-Host ('=' * ([Math]::Max(20, $script:CurrentSection.Length + 8)))
        $script:CurrentSection = $null
    }
    else {
        Write-Host "============================"
    }
}

function Get-LiongardServiceName {
    return @(
        'roaragent',
        'roaragent.exe',
        'LiongardAgentSVC',
        'LiongardAgent',
        'Liongard Agent'
    )
}

function Test-LiongardAgentInstalled {
    $productCodes = @(
        '{1D89F069-B48B-4191-8810-2364C29EC039}'
    )

    $serviceNames = Get-LiongardServiceName

    foreach ($code in $productCodes) {
        foreach ($path in @(
                "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$code",
                "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$code"
            )) {
            if (Test-Path -LiteralPath $path) {
                return $true
            }
        }
    }

    foreach ($svcName in $serviceNames) {
        $service = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($service) { return $true }
    }

    return $false
}

function Get-LiongardAgentDetectionDetail {
    $details = New-Object System.Collections.Generic.List[string]

    foreach ($path in @(
            "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{1D89F069-B48B-4191-8810-2364C29EC039}",
            "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{1D89F069-B48B-4191-8810-2364C29EC039}"
        )) {
        if (Test-Path -LiteralPath $path) {
            $details.Add("Uninstall key present: $path") | Out-Null
        }
    }

    foreach ($svcName in (Get-LiongardServiceName | Select-Object -Unique)) {
        $service = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($service) {
            $details.Add("Service '$svcName' detected with status $($service.Status)") | Out-Null
        }
    }

    foreach ($path in @(
            'C:\Program Files (x86)\LiongardInc\LiongardAgent\roaragent.exe',
            'C:\Program Files (x86)\LiongardInc\LiongardAgent\LiongardAgent.exe',
            'C:\Program Files (x86)\LiongardInc\LiongardAgent'
        )) {
        if (Test-Path -LiteralPath $path) {
            $details.Add("Path present: $path") | Out-Null
        }
    }

    return @($details)
}

function Get-ExitCodeText {
    param([int]$Code)
    switch ($Code) {
        0     { 'Success' }
        3010  { 'Success, restart required' }
        1602  { 'User cancelled' }
        1603  { 'Fatal error during installation' }
        1618  { 'Another install in progress' }
        1638  { 'Another version is already installed' }
        1619  { 'Could not open installation package' }
        1622  { 'Error opening installation log file' }
        default { 'Unknown / check installer log' }
    }
}

function Start-LiongardTranscript {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param([Parameter(Mandatory)][string]$TargetFolder)

    if (-not (Test-Path -LiteralPath $TargetFolder)) {
        try {
            New-Item -Path $TargetFolder -ItemType Directory -Force | Out-Null
        }
        catch {
            Write-Warning "Unable to create folder [$TargetFolder] for transcript logging: $($_.Exception.Message)"
            return
        }
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $script:TranscriptPath = Join-Path -Path $TargetFolder -ChildPath ("LGAgentScript_EXE_{0}.log" -f $timestamp)

    try {
        Start-Transcript -Path $script:TranscriptPath -Force | Out-Null
        $script:TranscriptStarted = $true
        Write-Host "Script transcript logging enabled at [$script:TranscriptPath]."
    }
    catch {
        Write-Warning "Unable to start transcript logging at [$script:TranscriptPath]: $($_.Exception.Message)"
        $script:TranscriptPath = $null
    }
}

function Stop-LiongardTranscript {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param()
    if (-not $script:TranscriptStarted) { return }

    try {
        Stop-Transcript | Out-Null
        if ($script:TranscriptPath) {
            Write-Host "Script transcript saved to [$script:TranscriptPath]."
        }
    }
    catch {
        Write-Warning "Failed to finalize transcript logging: $($_.Exception.Message)"
    }
    finally {
        $script:TranscriptStarted = $false
        $script:TranscriptPath = $null
    }
}

function Write-UninstallLog {
    param(
        [ValidateSet('INFO','STEP','OK','WARN','ERROR')]
        [string]$Level,
        [string]$Message
    )

    $line = "[Pre-Uninstall][$Level] $Message"
    switch ($Level) {
        'WARN'  { Write-Warning $line }
        'ERROR' { Write-Error   $line }
        default { Write-Host    $line }
    }
}

function Get-ObjectPropertyValue {
    param(
        [Parameter()][object]$Object,
        [Parameter()][string]$Name,
        [Parameter()][object]$Default = $null
    )

    if ($null -eq $Object -or [string]::IsNullOrEmpty($Name)) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Initialize-RegistryDrive {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Root
    )

    if (Get-PSDrive -Name $Name -ErrorAction SilentlyContinue) { return }

    try {
        New-PSDrive -Name $Name -PSProvider Registry -Root $Root -Scope Script -ErrorAction Stop | Out-Null
        Write-UninstallLog INFO "Mounted registry drive '${Name}:' at $Root for enumeration."
    }
    catch {
        Write-UninstallLog WARN "Failed to mount registry drive '${Name}:' ($Root): $($_.Exception.Message)"
    }
}

function Get-UninstallEntry {
    param(
        [string[]]$Names,
        [pscustomobject[]]$ProductCodes
    )

    $tokens = $Names | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.ToLowerInvariant() }
    $seenPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $roots = @(
        @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall';             Scope = 'Machine' },
        @{ Path = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; Scope = 'Machine' },
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall';             Scope = 'CurrentUser' },
        @{ Path = 'HKCU:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; Scope = 'CurrentUser' }
    )

    Initialize-RegistryDrive -Name 'HKU' -Root 'HKEY_USERS'

    try {
        $userRoots = Get-ChildItem HKU: -ErrorAction Stop | Where-Object { $_.PSChildName -match '^S-1-5-21' }
        foreach ($sid in $userRoots) {
            $sidBase = "HKU:\$($sid.PSChildName)\Software\Microsoft\Windows\CurrentVersion\Uninstall"
            $roots += @{ Path = $sidBase; Scope = "User:$($sid.PSChildName)" }
            $roots += @{ Path = "$sidBase\WOW6432Node"; Scope = "User:$($sid.PSChildName)" }
        }
    }
    catch {
        Write-UninstallLog WARN "Unable to enumerate HKU hives: $($_.Exception.Message)"
    }

    $found = @()
    foreach ($root in $roots) {
        $path = $root.Path
        if (-not (Test-Path $path)) { continue }

        try {
            $keys = Get-ChildItem -Path $path -ErrorAction Stop
        }
        catch {
            Write-UninstallLog WARN "Skipping uninstall root '$path' due to access error: $($_.Exception.Message)"
            continue
        }

        foreach ($k in $keys) {
            try {
                $props = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction Stop
            }
            catch {
                Write-UninstallLog WARN "Skipping uninstall key due to read error: $($_.Exception.Message)"
                continue
            }

            $display = Get-ObjectPropertyValue -Object $props -Name 'DisplayName'
            $keyName = $k.PSChildName
            $haystack = @($display, $keyName) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            $haystackLower = $haystack | ForEach-Object { $_.ToLowerInvariant() }

            $hasMatch = $false
            foreach ($token in $tokens) {
                if ($haystackLower | Where-Object { $_ -like "*$token*" }) {
                    $hasMatch = $true
                    break
                }
            }

            if (-not $hasMatch) { continue }

            $friendlyName = if ($display) { $display } elseif ($keyName) { $keyName } else { '(Unnamed entry)' }
            if (-not $seenPaths.Add($k.PSPath)) { continue }

            $found += [pscustomobject]@{
                DisplayName = $display
                Name        = $friendlyName
                Quiet       = Get-ObjectPropertyValue -Object $props -Name 'QuietUninstallString'
                Normal      = Get-ObjectPropertyValue -Object $props -Name 'UninstallString'
                KeyPath     = $k.PSPath
                KeyName     = $keyName
                Scope       = $root.Scope
                ProductCode = if ($keyName -and $keyName -match '^\{[0-9A-F\-]+\}$') { $keyName } else { $null }
            }
        }
    }

    foreach ($pc in $ProductCodes) {
        if (-not $pc.Code) { continue }
        $code = $pc.Code
        $candidatePaths = @(
            "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$code",
            "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$code"
        )

        foreach ($kp in $candidatePaths) {
            try {
                if (-not (Test-Path -LiteralPath $kp)) { continue }
                $item = Get-Item -LiteralPath $kp -ErrorAction Stop
                $props = Get-ItemProperty -LiteralPath $kp -ErrorAction Stop
                $display = Get-ObjectPropertyValue -Object $props -Name 'DisplayName'
                $friendlyName = if ($display) { $display } elseif ($pc.Name) { $pc.Name } else { "$code (MSI)" }
                $scope = if ($kp -like 'HKLM:\*') { 'Machine (known)' } else { 'User (known)' }

                if (-not $seenPaths.Add($item.PSPath)) { continue }

                Write-UninstallLog INFO "Including known uninstall entry fallback: $friendlyName -> $kp"

                $found += [pscustomobject]@{
                    DisplayName = $display
                    Name        = $friendlyName
                    Quiet       = Get-ObjectPropertyValue -Object $props -Name 'QuietUninstallString'
                    Normal      = Get-ObjectPropertyValue -Object $props -Name 'UninstallString'
                    KeyPath     = $item.PSPath
                    KeyName     = $item.PSChildName
                    Scope       = $scope
                    ProductCode = $code
                }
            }
            catch {
                Write-UninstallLog WARN "Failed to evaluate known uninstall key '$kp': $($_.Exception.Message)"
            }
        }
    }

    return $found
}

function Clear-LiongardInstallerRegistry {
    $appName = 'Liongard'
    $productPath = 'Registry::HKEY_CLASSES_ROOT\Installer\Products'
    $upgradePath = 'Registry::HKEY_CLASSES_ROOT\Installer\UpgradeCodes'
    $removedProducts = 0
    $removedUpgrades = 0

    Write-UninstallLog STEP "Checking for hidden installer cache entries for '$appName'..."

    if (Test-Path -LiteralPath $productPath) {
        try {
            Get-ChildItem -LiteralPath $productPath -ErrorAction Stop | ForEach-Object {
                $productName = (Get-ItemProperty -LiteralPath $_.PSPath -Name 'ProductName' -ErrorAction SilentlyContinue).ProductName
                if ($productName -and $productName -like "*$appName*") {
                    Write-UninstallLog INFO "Removing corrupted installer product entry: $($_.PSPath) | ProductName: $productName"
                    try {
                        Remove-Item -LiteralPath $_.PSPath -Recurse -Force -ErrorAction Stop
                        $removedProducts++
                    }
                    catch {
                        Write-UninstallLog WARN "Failed to remove installer product entry at $($_.PSPath): $($_.Exception.Message)"
                    }
                }
            }
        }
        catch {
            Write-UninstallLog WARN "Failed to enumerate installer product cache: $($_.Exception.Message)"
        }
    }

    if (Test-Path -LiteralPath $upgradePath) {
        try {
            Get-ChildItem -LiteralPath $upgradePath -ErrorAction Stop | ForEach-Object {
                $values = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
                if ($values) {
                    $upgradeMatches = $values.PSObject.Properties.Value | Where-Object { $_ -is [string] -and $_ -like "*$appName*" }
                    if ($upgradeMatches -and $upgradeMatches.Count -gt 0) {
                        Write-UninstallLog INFO "Removing installer upgrade entry: $($_.PSPath)"
                        try {
                            Remove-Item -LiteralPath $_.PSPath -Recurse -Force -ErrorAction Stop
                            $removedUpgrades++
                        }
                        catch {
                            Write-UninstallLog WARN "Failed to remove installer upgrade entry at $($_.PSPath): $($_.Exception.Message)"
                        }
                    }
                }
            }
        }
        catch {
            Write-UninstallLog WARN "Failed to enumerate installer upgrade cache: $($_.Exception.Message)"
        }
    }

    if ($removedProducts -gt 0 -or $removedUpgrades -gt 0) {
        Write-UninstallLog OK ("Removed {0} installer product entries and {1} upgrade entries related to '{2}'." -f $removedProducts, $removedUpgrades, $appName)
    }
    else {
        Write-UninstallLog INFO "No hidden installer cache entries found for '$appName'."
    }
}

function Remove-UninstallKey {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [string]$KeyPath,
        [string]$Name
    )

    $label = if ([string]::IsNullOrWhiteSpace($Name)) { $KeyPath } else { $Name }

    if ([string]::IsNullOrWhiteSpace($KeyPath)) { return $false }

    if (-not (Test-Path -LiteralPath $KeyPath)) {
        Write-UninstallLog INFO "Uninstall key already removed for '$label'."
        return $true
    }

    try {
        Write-UninstallLog INFO "Removing uninstall registry key for '$label': $KeyPath"
        Remove-Item -LiteralPath $KeyPath -Recurse -Force -ErrorAction Stop
        Write-UninstallLog OK "Removed uninstall registry key for '$label'."
        return $true
    }
    catch {
        Write-UninstallLog WARN "Failed to remove uninstall registry key for '$label': $($_.Exception.Message)"
        return $false
    }
}

function Invoke-Uninstall {
    param([Parameter(Mandatory)][pscustomobject]$Entry)

    $cmd = if ($Entry.Quiet) { $Entry.Quiet } else { $Entry.Normal }

    if ([string]::IsNullOrWhiteSpace($cmd) -and $Entry.ProductCode) {
        $cmd = "msiexec.exe /x $($Entry.ProductCode)"
    }

    if ([string]::IsNullOrWhiteSpace($cmd)) {
        Write-UninstallLog WARN "No uninstall string found for '$($Entry.Name)'."
        return 1
    }

    Write-UninstallLog INFO "Uninstall target: '$($Entry.Name)'. Raw command: $cmd"

    if ($cmd -match '(?i)msiexec\.exe') {
        $cmdArgs = $cmd -replace '(?i).*msiexec\.exe\s*',''
        if ($cmdArgs -notmatch '(?i)\s/q')         { $cmdArgs += ' /qn' }
        if ($cmdArgs -notmatch '(?i)\s/norestart') { $cmdArgs += ' /norestart' }
        Write-UninstallLog INFO "Executing MSI uninstall: msiexec.exe $cmdArgs"
        $p = Start-Process msiexec.exe -ArgumentList $cmdArgs -PassThru -Wait -WindowStyle Hidden
        Write-UninstallLog INFO "MSI exit code: $($p.ExitCode)"
        return $p.ExitCode
    }

    if ($cmd.StartsWith('"')) {
        $exe = $cmd.Split('"')[1]
        $cmdArgs = $cmd.Substring($exe.Length + 2).Trim()
    }
    else {
        $exe = $cmd.Split(' ')[0]
        $cmdArgs = $cmd.Substring($exe.Length).Trim()
    }

    if ($cmdArgs -notmatch '(?i)(/quiet|/silent|/s)') { $cmdArgs += ' /quiet' }
    if ($cmdArgs -notmatch '(?i)(/norestart|/n)')     { $cmdArgs += ' /norestart' }

    if (-not (Test-Path $exe)) {
        Write-UninstallLog WARN "Uninstall executable not found: $exe"
        return 1
    }

    Write-UninstallLog INFO "Executing EXE uninstall: `"$exe`" $cmdArgs"
    $p = Start-Process $exe -ArgumentList $cmdArgs -PassThru -Wait -WindowStyle Hidden
    Write-UninstallLog INFO "EXE exit code: $($p.ExitCode)"
    return $p.ExitCode
}

function Invoke-MsiSilentUninstall {
    param(
        [Parameter(Mandatory)][string]$ProductCode,
        [string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($ProductCode)) { return $null }

    $friendly = if ([string]::IsNullOrWhiteSpace($Label)) { $ProductCode } else { $Label }
    $cmdArgs = "/x $ProductCode /qn /norestart"

    Write-UninstallLog INFO "Forcing MSI uninstall for '$friendly' via product code $ProductCode."
    try {
        $proc = Start-Process msiexec.exe -ArgumentList $cmdArgs -PassThru -Wait -WindowStyle Hidden
        $exit = $proc.ExitCode
    }
    catch {
        Write-UninstallLog WARN "Failed to launch MSI uninstall for '$friendly': $($_.Exception.Message)"
        return $null
    }

    switch ($exit) {
        0     { Write-UninstallLog OK "MSI uninstall completed for '$friendly' (exit code 0)." }
        3010  { Write-UninstallLog WARN "MSI uninstall for '$friendly' completed with reboot required (3010)." }
        1605  { Write-UninstallLog INFO "MSI uninstall for '$friendly' returned 1605 (product not installed)." }
        default { Write-UninstallLog WARN "MSI uninstall for '$friendly' returned exit code $exit." }
    }

    return $exit
}

function Initialize-FolderRemoval {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }

    $prepared = $false

    Write-UninstallLog INFO "Resetting permissions and attributes on '$Path' before removal."

    try {
        & takeown.exe /f $Path /r /d Y | Out-Null
        $prepared = $true
    }
    catch {
        Write-UninstallLog WARN "takeown failed for '$Path': $($_.Exception.Message)"
    }

    try {
        & icacls.exe $Path /grant:r "Administrators:F" /T /C | Out-Null
        $prepared = $true
    }
    catch {
        Write-UninstallLog WARN "icacls grant failed for '$Path': $($_.Exception.Message)"
    }

    try {
        Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction Stop | ForEach-Object {
            try { $_.Attributes = 'Normal' } catch { Write-Verbose $_.Exception.Message }
        }
        $prepared = $true
    }
    catch {
        Write-UninstallLog WARN "Unable to normalize attributes under '$Path': $($_.Exception.Message)"
    }

    return $prepared
}

function Invoke-LiongardAgentUninstall {
    Write-UninstallLog STEP "Attempting Liongard Agent removal prior to installation."

    $serviceNames = Get-LiongardServiceName
    $root = 'C:\Program Files (x86)\LiongardInc'
    $procNames = @('LiongardAgentSVC','roaragent','liongardagent')
    $productCodes = @(
        [pscustomobject]@{
            Code = '{1D89F069-B48B-4191-8810-2364C29EC039}'
            Name = 'Liongard Agent'
        }
    )

    $issues = New-Object System.Collections.Generic.List[string]
    $searchNames = @('Liongard Agent','RoarAgent','Roar Agent','Liongard')
    $entries = @(Get-UninstallEntry -Names $searchNames -ProductCodes $productCodes | Where-Object { $_ })

    if ($entries.Length -gt 0) {
        $entries | ForEach-Object { Write-UninstallLog INFO "Found entry: $($_.Name) (Scope: $($_.Scope)) -> Key: $($_.KeyName)" }
        foreach ($entry in $entries) {
            $exitCode = Invoke-Uninstall -Entry $entry
            if ($exitCode -ne 0 -and $exitCode -ne 3010 -and $exitCode -ne 1605) {
                $issues.Add("uninstall:$($entry.Name)=$exitCode") | Out-Null
            }

            $regCleaned = Remove-UninstallKey -KeyPath $entry.KeyPath -Name $entry.Name
            if (-not $regCleaned) {
                $issues.Add("reg:$($entry.Name)") | Out-Null
            }
        }
    }
    else {
        Write-UninstallLog INFO "No uninstall registry entries located."
    }

    foreach ($pc in $productCodes) {
        $exit = Invoke-MsiSilentUninstall -ProductCode $pc.Code -Label $pc.Name
        if ($null -eq $exit) {
            $issues.Add("msi:$($pc.Code)") | Out-Null
        }
        elseif ($exit -ne 0 -and $exit -ne 3010 -and $exit -ne 1605) {
            $issues.Add("msi:$($pc.Code)=$exit") | Out-Null
        }
    }

    Clear-LiongardInstallerRegistry

    foreach ($svcName in $serviceNames | Select-Object -Unique) {
        Write-UninstallLog STEP "Stopping and deleting service '$svcName'..."
        try {
            $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
            if ($svc) {
                if ($svc.Status -ne 'Stopped') {
                    Stop-Service $svcName -Force -ErrorAction SilentlyContinue
                    Write-UninstallLog OK "Service '$svcName' stopped."
                }
                sc.exe delete $svcName | Out-Null
                Write-UninstallLog OK "Service '$svcName' deleted."
            }
            else {
                Write-UninstallLog INFO "Service '$svcName' not present."
            }
        }
        catch {
            Write-UninstallLog WARN "Service operation failed for '$svcName': $($_.Exception.Message)"
            $issues.Add("svc:$svcName") | Out-Null
        }
    }

    Write-UninstallLog STEP "Terminating remaining Liongard processes..."
    foreach ($pn in $procNames) {
        try {
            $procs = Get-Process -Name $pn -ErrorAction SilentlyContinue
            if ($procs) {
                $procs | Stop-Process -Force -ErrorAction SilentlyContinue
                Write-UninstallLog OK "Process '$pn' terminated."
            }
        }
        catch {
            Write-UninstallLog WARN "Failed to stop process '$pn': $($_.Exception.Message)"
            $issues.Add("proc:$pn") | Out-Null
        }
    }

    Write-UninstallLog STEP "Removing residual folder: $root"
    try {
        if (Test-Path $root) {
            try {
                Remove-Item $root -Recurse -Force -ErrorAction Stop
                Write-UninstallLog OK "Removed residual folder: $root"
            }
            catch {
                Write-UninstallLog WARN "Initial folder removal failed: $($_.Exception.Message). Trying permission reset."
                $prepared = Initialize-FolderRemoval -Path $root
                if ($prepared) {
                    Remove-Item $root -Recurse -Force -ErrorAction Stop
                    Write-UninstallLog OK "Removed residual folder after permission reset: $root"
                }
                else {
                    throw
                }
            }
        }
        else {
            Write-UninstallLog INFO "Residual folder not found: $root"
        }
    }
    catch {
        Write-UninstallLog WARN "Folder cleanup failed for '$root': $($_.Exception.Message)"
        $issues.Add('path') | Out-Null
    }

    if ($issues.Count -eq 0) {
        Write-UninstallLog OK "Pre-install uninstall completed successfully."
    }
    else {
        Write-UninstallLog WARN ("Pre-install uninstall completed with issues: " + ($issues -join ', '))
    }

    return [pscustomobject]@{
        Success = ($issues.Count -eq 0)
        Issues  = $issues
    }
}

function Get-LiongardAuthHeader {
    param(
        [string]$ApiTokenKey,
        [string]$ApiTokenSecret
    )

    $token = "$ApiTokenKey`:$ApiTokenSecret"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($token)
    $encoded = [System.Convert]::ToBase64String($bytes)
    return @{
        'X-ROAR-API-KEY' = $encoded
        'User-Agent'     = 'LiongardAgentInstallerEXE/1.1'
    }
}

function ConvertTo-MaskedValue {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    if ($Value.Length -le 8) { return ('*' * $Value.Length) }

    $prefix = $Value.Substring(0, 4)
    $suffix = $Value.Substring($Value.Length - 4, 4)
    return "$prefix****$suffix"
}

function ConvertTo-MaskedProxy {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return '<empty>' }

    if ($Value -match '^(?<scheme>https?://)(?<user>[^:/@]+)(:(?<pass>[^@]*))?@(?<host>.+)$') {
        return ("{0}{1}:****@{2}" -f $Matches['scheme'], $Matches['user'], $Matches['host'])
    }

    return $Value
}

function Write-ConfigurationSnapshot {
    Start-LogSection -Name 'Config Snapshot'
    Write-SectionValue -Label 'InstancePrefix' -Value $InstancePrefix
    Write-SectionValue -Label 'ApiTokenKey (masked)' -Value (ConvertTo-MaskedValue -Value $ApiTokenKey)
    Write-SectionValue -Label 'ApiTokenSecret (masked)' -Value (ConvertTo-MaskedValue -Value $ApiTokenSecret)
    Write-SectionValue -Label 'AgentTokenKey (masked)' -Value (ConvertTo-MaskedValue -Value $AgentTokenKey)
    Write-SectionValue -Label 'AgentTokenSecret (masked)' -Value (ConvertTo-MaskedValue -Value $AgentTokenSecret)
    Write-SectionValue -Label 'Environment' -Value $Environment
    Write-SectionValue -Label 'AgentDescription' -Value $AgentDescription
    Write-SectionValue -Label 'IncludeEnvironmentValue' -Value $IncludeEnvironmentValue
    Write-SectionValue -Label 'EnablePreUninstall' -Value $EnablePreUninstall
    Write-SectionValue -Label 'RemoveAgentFromPlatform' -Value $RemoveAgentFromPlatform
    Write-SectionValue -Label 'MinimumRemoteDeletionScore' -Value $MinimumRemoteDeletionScore
    Write-SectionValue -Label 'Folder' -Value $Folder
    Write-SectionValue -Label 'InstallerUrl' -Value $InstallerUrl
    Write-SectionValue -Label 'InstallerFileName' -Value $InstallerFileName
    Write-SectionValue -Label 'InstallEnhancedNetworkDiscovery' -Value $InstallEnhancedNetworkDiscovery
    Write-SectionValue -Label 'EulaAccepted' -Value $EulaAccepted
    Write-SectionValue -Label 'SuppressRestart' -Value $SuppressRestart
    Write-SectionValue -Label 'PassiveMode' -Value $PassiveMode
    Write-SectionValue -Label 'InstallerLogPath' -Value $InstallerLogPath
    Write-SectionValue -Label 'ProxyUrl' -Value (ConvertTo-MaskedProxy -Value $ProxyUrl)
    Write-SectionValue -Label 'AutoUpdate' -Value $AutoUpdate
    Write-SectionValue -Label 'AutoUpdateArgumentName' -Value $AutoUpdateArgumentName
    Write-SectionValue -Label 'ClearProxyEnvironmentForInstaller' -Value $ClearProxyEnvironmentForInstaller
    Write-SectionValue -Label 'RawLogWarning' -Value 'Raw bundle/MSI logs may contain secrets. This transcript only prints masked installer arguments and summary data.'
    Complete-LogSection
}

function Get-HttpErrorDetail {
    param([System.Exception]$Exception)

    if ($null -eq $Exception) { return $null }

    try {
        $response = $Exception.Response
        if ($null -eq $response) { return $null }

        $stream = $response.GetResponseStream()
        if ($null -eq $stream) { return $null }

        $reader = New-Object System.IO.StreamReader($stream)
        try {
            $body = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }

        if (-not [string]::IsNullOrWhiteSpace($body)) {
            return $body.Trim()
        }
    }
    catch { Write-Verbose $_.Exception.Message }

    return $null
}

function ConvertTo-NormalizedEnvironmentName {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    $trimmed = $Value.Trim()
    $trimmed = $trimmed -replace '^(?i)\s*(the|a|an)\s+', ''
    $trimmed = $trimmed -replace '&', ' and '
    $trimmed = $trimmed -replace '(?i)\band\b', ' '

    $formD = $trimmed.Normalize([Text.NormalizationForm]::FormD)
    $chars = $formD.ToCharArray() | Where-Object {
        [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne [System.Globalization.UnicodeCategory]::NonSpacingMark
    }
    $folded = -join $chars

    $normalized = ($folded -replace '[^0-9a-zA-Z]', '').ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($normalized)) { return $null }

    return $normalized
}

function Get-LiongardEnvironmentNameValue {
    param($Environment)

    foreach ($key in @('Name','DisplayName','EnvironmentName','Environment')) {
        $prop = $Environment.PSObject.Properties[$key]
        if ($prop -and -not [string]::IsNullOrWhiteSpace($prop.Value)) {
            return [string]$prop.Value
        }
    }

    return $null
}

function Get-LiongardEnvironment {
    param(
        [Parameter(Mandatory)][string]$InstancePrefix,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $uri = "https://$InstancePrefix.app.liongard.com/api/v1/environments"

    try {
        $response = Invoke-RestMethod -Uri $uri -Headers $Headers -ErrorAction Stop
    }
    catch {
        $detail = Get-HttpErrorDetail -Exception $_.Exception
        if ($detail) {
            Write-Warning "Unable to retrieve Liongard environments: $($_.Exception.Message) | Response: $detail"
        }
        else {
            Write-Warning "Unable to retrieve Liongard environments: $($_.Exception.Message)"
        }
        return @()
    }

    if ($null -eq $response) { return @() }
    if ($response -is [System.Array]) { return $response }

    foreach ($key in @('data','items','results','value')) {
        $prop = $response.PSObject.Properties[$key]
        if ($prop -and $prop.Value) {
            $collection = $prop.Value
            if ($collection -is [System.Array]) { return $collection }
            if ($collection -is [System.Collections.IEnumerable] -and -not ($collection -is [string])) {
                return @($collection)
            }
            return @($collection)
        }
    }

    return @($response)
}

function Resolve-LiongardEnvironmentName {
    param(
        [Parameter(Mandatory)][string]$InputName,
        [Parameter(Mandatory)][string]$InstancePrefix,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $script:EnvironmentResolutionReason = 'Unknown'
    $minNormalizedLength = 4
    $inputNormalized = ConvertTo-NormalizedEnvironmentName -Value $InputName
    if (-not $inputNormalized) { return $null }

    if ($inputNormalized.Length -lt $minNormalizedLength) {
        $script:EnvironmentResolutionReason = 'TooShort'
        Write-Warning ("Provided environment value '{0}' normalized to '{1}', which is too short to match reliably (min {2})." -f $InputName, $inputNormalized, $minNormalizedLength)
        return $null
    }

    $environments = Get-LiongardEnvironment -InstancePrefix $InstancePrefix -Headers $Headers
    if (-not $environments -or $environments.Count -eq 0) {
        $script:EnvironmentResolutionReason = 'NoEnvironmentsReturned'
        return $null
    }

    $exact = $environments |
        Where-Object {
            $name = Get-LiongardEnvironmentNameValue -Environment $_
            [string]::Equals($name, $InputName, [System.StringComparison]::InvariantCultureIgnoreCase)
        } |
        Select-Object -First 1

    if ($exact) {
        $script:EnvironmentResolutionReason = 'ExactMatch'
        $exactName = Get-LiongardEnvironmentNameValue -Environment $exact
        if (-not [string]::IsNullOrWhiteSpace($exactName)) {
            return $exactName
        }
    }

    $normalizedCandidates = @()
    foreach ($env in $environments) {
        $name = Get-LiongardEnvironmentNameValue -Environment $env
        $normalized = ConvertTo-NormalizedEnvironmentName -Value $name
        $normalizedCandidates += [pscustomobject]@{
            Name       = $name
            Normalized = $normalized
            Data       = $env
        }
    }

    $normalizedMatches = @($normalizedCandidates | Where-Object { $_.Normalized -and $_.Normalized -eq $inputNormalized })
    if ($normalizedMatches.Count -eq 1) {
        $script:EnvironmentResolutionReason = 'NormalizedMatch'
        return $normalizedMatches[0].Name
    }
    elseif ($normalizedMatches.Count -gt 1) {
        $script:EnvironmentResolutionReason = 'AmbiguousNormalized'
        $sample = ($normalizedMatches | Select-Object -First 3).Name -join '; '
        Write-Warning ("Multiple Liongard environments match provided name '{0}' after normalization; candidates: {1}. Skipping automatic mapping." -f $InputName, $sample)
        return $null
    }

    $prefixMatches = @(
        $normalizedCandidates |
        Where-Object {
            $_.Normalized -and (
                $_.Normalized.StartsWith($inputNormalized) -or
                $inputNormalized.StartsWith($_.Normalized)
            )
        }
    )

    if ($prefixMatches.Count -eq 1) {
        $script:EnvironmentResolutionReason = 'PrefixMatch'
        Write-Host ("Normalized environment prefix match: '{0}' -> '{1}'" -f $InputName, $prefixMatches[0].Name)
        return $prefixMatches[0].Name
    }
    elseif ($prefixMatches.Count -gt 1) {
        $script:EnvironmentResolutionReason = 'AmbiguousPrefix'
        $sample = ($prefixMatches | Select-Object -First 3).Name -join '; '
        Write-Warning ("Multiple Liongard environments partially match provided name '{0}' after normalization; candidates: {1}. Skipping automatic mapping." -f $InputName, $sample)
        return $null
    }

    $containsMatches = @(
        $normalizedCandidates |
        Where-Object {
            $_.Normalized -and (
                $_.Normalized.Contains($inputNormalized) -or
                $inputNormalized.Contains($_.Normalized)
            )
        }
    )

    if ($containsMatches.Count -eq 1) {
        $script:EnvironmentResolutionReason = 'ContainsMatch'
        Write-Host ("Normalized environment contains match: '{0}' -> '{1}'" -f $InputName, $containsMatches[0].Name)
        return $containsMatches[0].Name
    }
    elseif ($containsMatches.Count -gt 1) {
        $script:EnvironmentResolutionReason = 'AmbiguousContains'
        $sample = ($containsMatches | Select-Object -First 3).Name -join '; '
        Write-Warning ("Multiple Liongard environments partially match provided name '{0}' after normalization (contains); candidates: {1}. Skipping automatic mapping." -f $InputName, $sample)
        return $null
    }

    $script:EnvironmentResolutionReason = 'NoMatch'
    $knownNames = ($normalizedCandidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) } | Select-Object -ExpandProperty Name)
    $sampleNames = ($knownNames | Select-Object -First 5) -join '; '
    Write-Warning ("No Liongard environment matched provided name '{0}' (normalized '{1}'). Known environments: {2}" -f $InputName, $inputNormalized, $sampleNames)
    return $null
}

function Resolve-InstancePrefix {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "InstancePrefix must be provided."
    }

    $sanitized = $Value.Trim()
    if ($sanitized -match '^https?://') {
        $uri = [Uri]$sanitized
        $sanitized = $uri.Host
    }

    if ($sanitized -match '\.app\.liongard\.com$') {
        return ($sanitized -split '\.')[0]
    }

    return $sanitized
}

function Get-LocalMachineGuid {
    $registryPath = 'HKLM:\SOFTWARE\Microsoft\Cryptography'
    try {
        if (Test-Path -LiteralPath $registryPath) {
            $machineGuid = (Get-ItemProperty -Path $registryPath -Name 'MachineGuid' -ErrorAction Stop).MachineGuid
            if (-not [string]::IsNullOrWhiteSpace($machineGuid)) {
                return $machineGuid
            }
            Write-Warning "MachineGuid registry value was empty."
        }
        else {
            Write-Warning "Cryptography registry key [$registryPath] was not found."
        }
    }
    catch {
        Write-Warning "Unable to read MachineGuid from registry: $($_.Exception.Message)"
    }

    Write-Warning "Falling back to Win32_ComputerSystemProduct UUID for machine identification."
    try {
        $uuid = (Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction Stop).UUID
        if (-not [string]::IsNullOrWhiteSpace($uuid) -and
            $uuid -notmatch '^(00000000-0000-0000-0000-000000000000|FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF)$') {
            return $uuid
        }
        Write-Warning "Win32_ComputerSystemProduct returned an empty or placeholder UUID."
    }
    catch {
        Write-Warning "Unable to read Win32_ComputerSystemProduct UUID: $($_.Exception.Message)"
    }

    throw "Unable to determine a machine identifier: MachineGuid missing and hardware UUID unavailable."
}

function Get-LocalHostnameVariant {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PrimaryName
    )

    $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::InvariantCultureIgnoreCase)

    foreach ($entry in @(
            $PrimaryName,
            [System.Net.Dns]::GetHostName()
        )) {
        if (-not [string]::IsNullOrWhiteSpace($entry)) {
            $names.Add($entry) | Out-Null
        }
    }

    try {
        $cimHost = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).DNSHostName
        if (-not [string]::IsNullOrWhiteSpace($cimHost)) {
            $names.Add($cimHost) | Out-Null
        }
    }
    catch { Write-Verbose $_.Exception.Message }

    try {
        $fqdn = [System.Net.Dns]::GetHostEntry('localhost').HostName
        if (-not [string]::IsNullOrWhiteSpace($fqdn)) {
            $names.Add($fqdn) | Out-Null
        }
    }
    catch { Write-Verbose $_.Exception.Message }

    if (-not [string]::IsNullOrWhiteSpace($env:USERDNSDOMAIN)) {
        $names.Add("$PrimaryName.$env:USERDNSDOMAIN") | Out-Null
    }

    $existing = @($names)
    foreach ($value in $existing) {
        if ($value.Length -gt 15) {
            $names.Add($value.Substring(0, 15)) | Out-Null
        }
    }

    return @($names)
}

function Get-AgentHostIdentifier {
    param(
        [Parameter(Mandatory = $true)]
        $Agent
    )

    $candidates = @()

    if (-not [string]::IsNullOrWhiteSpace($Agent.Hostname)) { $candidates += $Agent.Hostname }
    if (-not [string]::IsNullOrWhiteSpace($Agent.Name)) { $candidates += $Agent.Name }

    if ($Agent.PSObject.Properties.Match('Data').Count -gt 0) {
        $fqdn = $Agent.Data.FQDN
        if (-not [string]::IsNullOrWhiteSpace($fqdn)) { $candidates += $fqdn }
    }

    $variants = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::InvariantCultureIgnoreCase)
    foreach ($candidate in ($candidates | Sort-Object -Unique)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $variants.Add($candidate) | Out-Null
            if ($candidate.Length -gt 15) {
                $variants.Add($candidate.Substring(0, 15)) | Out-Null
            }
        }
    }

    return @($variants)
}

function Test-AgentHostnameMatch {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$LocalHostnames,
        [Parameter(Mandatory = $true)]
        $Agent
    )

    $agentHosts = Get-AgentHostIdentifier -Agent $Agent
    foreach ($agentHost in $agentHosts) {
        foreach ($localHost in $LocalHostnames) {
            if ([string]::Equals($agentHost, $localHost, [System.StringComparison]::InvariantCultureIgnoreCase)) {
                return $true
            }
        }
    }

    return $false
}

function ConvertTo-NormalizedGuid {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    return $Value.Trim('{}').Trim().ToLowerInvariant()
}

function ConvertTo-NormalizedMac {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $clean = ($Value -replace '[^0-9a-fA-F]', '').ToUpperInvariant()
    if ($clean.Length -lt 12) { return $null }
    return $clean.Substring(0, 12)
}

function Get-LocalMacAddress {
    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    try {
        $adapters = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter "IPEnabled = True" -ErrorAction Stop
        foreach ($adapter in $adapters) {
            $mac = ConvertTo-NormalizedMac -Value $adapter.MACAddress
            if ($mac) { $set.Add($mac) | Out-Null }
        }
    }
    catch {
        Write-Warning "Unable to enumerate NIC MAC addresses: $($_.Exception.Message)"
    }
    return $set
}

function Get-AgentMacAddress {
    param($Agent)

    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if (-not $Agent) { return $set }
    if ($Agent.PSObject.Properties.Match('Data').Count -eq 0) { return $set }

    $data = $Agent.Data
    $potentialKeys = @('MACAddress','MacAddress','MACAddresses','Mac','Macs')
    foreach ($key in $potentialKeys) {
        $prop = $data.PSObject.Properties[$key]
        if (-not $prop) { continue }
        $raw = $prop.Value
        if ($null -eq $raw) { continue }

        if ($raw -is [System.Collections.IEnumerable] -and -not ($raw -is [string])) {
            foreach ($entry in $raw) {
                $mac = ConvertTo-NormalizedMac -Value $entry
                if ($mac) { $set.Add($mac) | Out-Null }
            }
            continue
        }

        $parts = ($raw -split '[,; ]') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        foreach ($part in $parts) {
            $mac = ConvertTo-NormalizedMac -Value $part
            if ($mac) { $set.Add($mac) | Out-Null }
        }
    }

    return $set
}

function Find-LiongardAgentMatch {
    param(
        [array]$Agents,
        $HostIdentity
    )

    if (-not $Agents -or -not $HostIdentity) { return $null }

    $nameSet = if ($HostIdentity.Hostnames) { $HostIdentity.Hostnames } else { [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::InvariantCultureIgnoreCase) }
    $macSet = if ($HostIdentity.MacAddresses) { $HostIdentity.MacAddresses } else { [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase) }
    $machineGuid = $HostIdentity.MachineGuid

    $candidates = @()
    foreach ($agent in $Agents) {
        if (-not $agent) { continue }

        $score = 0
        $signals = @()

        $agentGuid = ConvertTo-NormalizedGuid -Value (Get-ObjectPropertyValue -Object $agent -Name 'MachineGuid')
        if ($machineGuid -and $agentGuid -and $agentGuid -eq $machineGuid) {
            $score += 100
            $signals += 'MachineGuid'
        }

        $agentNames = Get-AgentHostIdentifier -Agent $agent
        $nameMatches = @()
        foreach ($candidateName in $agentNames) {
            if ($nameSet.Contains($candidateName)) {
                $nameMatches += $candidateName
            }
        }
        if ($nameMatches.Count -gt 0) {
            $score += 30 + [Math]::Min(15, 5 * ($nameMatches.Count - 1))
            $signals += "Hostname(s): $($nameMatches -join ', ')"
        }

        $agentMacs = Get-AgentMacAddress -Agent $agent
        $macMatches = @()
        foreach ($mac in $agentMacs) {
            if ($macSet.Contains($mac)) {
                $macMatches += $mac
            }
        }
        if ($macMatches.Count -gt 0) {
            $score += 40 + [Math]::Min(10, 5 * ($macMatches.Count - 1))
            $signals += "MAC(s): $($macMatches -join ', ')"
        }

        if ($score -gt 0) {
            $candidates += [pscustomobject]@{
                Agent   = $agent
                Score   = $score
                Reasons = $signals
            }
        }
    }

    if (-not $candidates) { return $null }
    return ($candidates | Sort-Object Score -Descending | Select-Object -First 1)
}

function Invoke-LiongardRemoteAgentRemoval {
    param(
        [string]$InstancePrefix,
        [string]$ApiKey,
        [string]$ApiSecret,
        [array]$Agents,
        [string[]]$LocalHostnames,
        [string]$LocalMachineGuid,
        [int]$MinimumScore = 50
    )

    $result = [pscustomobject]@{
        Deleted = $false
        AgentId = $null
    }

    if (-not $InstancePrefix -or -not $ApiKey) {
        Write-Warning "Skipping remote agent deletion because the Liongard API context is unavailable."
        return $result
    }

    if (-not $Agents -or $Agents.Count -eq 0) {
        Write-Host "Remote agent deletion skipped because no Liongard agents were returned."
        return $result
    }

    $hostnameSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::InvariantCultureIgnoreCase)
    foreach ($entry in $LocalHostnames) {
        if (-not [string]::IsNullOrWhiteSpace($entry)) {
            $hostnameSet.Add($entry) | Out-Null
        }
    }

    $hostIdentity = [pscustomobject]@{
        Hostnames    = $hostnameSet
        MachineGuid  = ConvertTo-NormalizedGuid -Value $LocalMachineGuid
        MacAddresses = Get-LocalMacAddress
    }

    $match = Find-LiongardAgentMatch -Agents $Agents -HostIdentity $hostIdentity
    if (-not $match) {
        Write-Host "No Liongard agent record matched the local host identity profile; remote deletion skipped."
        return $result
    }

    if ($match.Score -lt $MinimumScore) {
        Write-Warning ("Remote agent deletion skipped because match score {0} is below the minimum threshold ({1}). Signals: {2}" -f $match.Score, $MinimumScore, ($match.Reasons -join '; '))
        return $result
    }

    $agentId = Get-ObjectPropertyValue -Object $match.Agent -Name 'ID'
    if (-not $agentId) {
        Write-Warning "Matched Liongard agent record is missing an ID; remote deletion skipped."
        return $result
    }

    Write-Host ("Attempting to delete Liongard agent ID {0} (score {1}). Signals: {2}" -f $agentId, $match.Score, ($match.Reasons -join '; '))
    $liongardUrl = "$InstancePrefix.app.liongard.com"
    try {
        Remove-LiongardAgent -LiongardURL $liongardUrl -ApiKey $ApiKey -ApiSecret $ApiSecret -AgentID ([int]$agentId) -Confirm:$false
        Write-Host ("Remote Liongard agent ID {0} deleted successfully." -f $agentId)
        return [pscustomobject]@{
            Deleted = $true
            AgentId = $agentId
        }
    }
    catch {
        Write-Warning ("Failed to delete Liongard agent ID {0} from the platform: {1}" -f $agentId, $_.Exception.Message)
    }
    return $result
}

function Resolve-DeviceGuidOverride {
    param(
        [string]$LocalGuid,
        [string[]]$LocalHostnames,
        [array]$Agents
    )

    $matchingAgents = @($Agents | Where-Object { $_.MachineGuid -and $_.MachineGuid -eq $LocalGuid })
    if ($matchingAgents.Count -eq 0) {
        return $null
    }

    $hostnameMatches = @($matchingAgents | Where-Object {
        Test-AgentHostnameMatch -LocalHostnames $LocalHostnames -Agent $_
    })

    if ($matchingAgents.Count -eq 1 -and $hostnameMatches.Count -ge 1) {
        Write-Host "Existing agent matches local MachineGuid and hostname. No DEVICEGUID override required."
        return $null
    }

    $localHostForWarning = if ($LocalHostnames -and $LocalHostnames.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($LocalHostnames[0])) {
        $LocalHostnames[0]
    }
    else {
        $env:COMPUTERNAME
    }

    Write-Warning ("WARNING: Found {0} Liongard agents with MachineGuid {1}, including {2} matching hostname {3}. Backend links by MachineGuid only, so install may overwrite arbitrary agent. Forcing DEVICEGUID override to create a new agent. Delete old duplicate agent(s) and reassign inspectors to new agent after install." -f $matchingAgents.Count, $LocalGuid, $hostnameMatches.Count, $localHostForWarning)
    $newGuid = ([guid]::NewGuid()).Guid
    Write-Host "Generated alternate DEVICEGUID [$newGuid] for installation."
    return $newGuid
}

function Save-LiongardInstaller {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$DestinationPath,
        [int]$MinimumBytes = 1048576,
        [int]$MaxAttempts = 3
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        if (Test-Path -LiteralPath $DestinationPath) {
            try { Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction Stop } catch { Write-Verbose $_.Exception.Message }
        }

        Write-Host ("Downloading Liongard Agent installer (attempt {0}/{1}) to [{2}]..." -f $attempt, $MaxAttempts, $DestinationPath)
        try {
            Invoke-WebRequest -Uri $Uri -OutFile $DestinationPath -UseBasicParsing -ErrorAction Stop
        }
        catch {
            Write-Warning "Installer download failed: $($_.Exception.Message)"
            continue
        }

        try {
            $file = Get-Item -LiteralPath $DestinationPath -ErrorAction Stop
            if ($file.Length -lt $MinimumBytes) {
                Write-Warning ("Downloaded installer size {0} bytes is below expected threshold; retrying..." -f $file.Length)
                continue
            }

            Write-Host ("Installer download verified ({0:N0} bytes)." -f $file.Length)
            return $true
        }
        catch {
            Write-Warning "Unable to validate installer at [$DestinationPath]: $($_.Exception.Message)"
        }
    }

    return $false
}

function Convert-BoolToInstallerValue {
    param([bool]$Value)
    return $Value.ToString().ToLowerInvariant()
}

function Convert-BoolToBundleValue {
    param([bool]$Value)
    if ($Value) { return '1' }
    return '0'
}

function Get-ExeInstallArgument {
    param(
        [Parameter(Mandatory)][string]$LiongardHost,
        [Parameter(Mandatory)][string]$AgentTokenKey,
        [Parameter(Mandatory)][string]$AgentTokenSecret,
        [Parameter(Mandatory)][string]$AgentName,
        [string]$Environment,
        [string]$AgentDescription,
        [string]$DeviceGuidOverride,
        [bool]$EulaAccepted,
        [bool]$InstallEnhancedNetworkDiscovery,
        [bool]$SuppressRestart,
        [bool]$PassiveMode,
        [string]$LogPath,
        [string]$ProxyUrl,
        [Nullable[bool]]$AutoUpdate,
        [string]$AutoUpdateArgumentName
    )

    $arguments = New-Object System.Collections.Generic.List[string]

    if ($PassiveMode) { $arguments.Add('/passive') } else { $arguments.Add('/quiet') }
    if ($SuppressRestart) { $arguments.Add('/norestart') }
    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        $arguments.Add('/log')
        $arguments.Add("`"$LogPath`"")
    }

    $arguments.Add("EulaAccepted=$(Convert-BoolToBundleValue -Value $EulaAccepted)")
    $arguments.Add("InstallEnhancedNetworkDiscovery=$(Convert-BoolToBundleValue -Value $InstallEnhancedNetworkDiscovery)")
    $arguments.Add("LiongardUrl=$LiongardHost")
    $arguments.Add("LiongardAccessKey=$AgentTokenKey")
    $arguments.Add("LiongardAccessSecret=$AgentTokenSecret")
    $arguments.Add("LiongardAgentName=`"$AgentName`"")
    $arguments.Add("ProxyUrl=`"$ProxyUrl`"")

    if (-not [string]::IsNullOrWhiteSpace($Environment)) {
        $arguments.Add("LiongardEnvironment=`"$Environment`"")
    }

    if (-not [string]::IsNullOrWhiteSpace($AgentDescription)) {
        $arguments.Add("LiongardDescription=`"$AgentDescription`"")
    }

    if (-not [string]::IsNullOrWhiteSpace($DeviceGuidOverride)) {
        $arguments.Add("DEVICEGUID=$DeviceGuidOverride")
    }

    if ($null -ne $AutoUpdate -and -not [string]::IsNullOrWhiteSpace($AutoUpdateArgumentName)) {
        $arguments.Add("$AutoUpdateArgumentName=$((Convert-BoolToBundleValue -Value ([bool]$AutoUpdate)))")
    }

    return ,$arguments.ToArray()
}

function Get-MaskedInstallArgument {
    param([string[]]$Arguments)

    $masked = New-Object System.Collections.Generic.List[string]
    foreach ($arg in $Arguments) {
        if ($arg -match '^LiongardAccessKey=') {
            $value = $arg.Substring('LiongardAccessKey='.Length).Trim('"')
            $masked.Add("LiongardAccessKey=$(ConvertTo-MaskedValue -Value $value)")
        }
        elseif ($arg -match '^LiongardAccessSecret=') {
            $value = $arg.Substring('LiongardAccessSecret='.Length).Trim('"')
            $masked.Add("LiongardAccessSecret=$(ConvertTo-MaskedValue -Value $value)")
        }
        elseif ($arg -match '^ProxyUrl=') {
            $value = $arg.Substring('ProxyUrl='.Length).Trim('"')
            if ([string]::IsNullOrWhiteSpace($value)) {
                $masked.Add('ProxyUrl="<empty>"')
            }
            else {
                $masked.Add("ProxyUrl=$(ConvertTo-MaskedValue -Value $value)")
            }
        }
        else {
            $masked.Add($arg)
        }
    }

    return @($masked)
}

function Get-ProxyEnvironmentSnapshot {
    $entries = New-Object System.Collections.Generic.List[object]
    $proxyNames = @(
        'HTTP_PROXY',
        'HTTPS_PROXY',
        'ALL_PROXY',
        'http_proxy',
        'https_proxy',
        'all_proxy',
        'NO_PROXY',
        'no_proxy'
    )

    foreach ($name in $proxyNames) {
        try {
            $value = [Environment]::GetEnvironmentVariable($name, 'Process')
            if ([string]::IsNullOrWhiteSpace($value)) {
                $value = [Environment]::GetEnvironmentVariable($name, 'Machine')
            }
            if ([string]::IsNullOrWhiteSpace($value)) {
                $value = [Environment]::GetEnvironmentVariable($name, 'User')
            }

            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $entries.Add([pscustomobject]@{
                    Name   = $name
                    Value  = $value
                    Masked = $(if ($name -match 'proxy') { ConvertTo-MaskedProxy -Value $value } else { ConvertTo-MaskedValue -Value $value })
                }) | Out-Null
            }
        }
        catch { Write-Verbose $_.Exception.Message }
    }

    return @($entries)
}

function Start-LiongardInstallerProcess {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [Parameter(Mandatory)][string]$InstallerPath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][bool]$ClearProxyEnvironment,
        [Parameter()][string]$ExplicitProxyUrl
    )

    if (-not $ClearProxyEnvironment) {
        return Start-Process -FilePath $InstallerPath -ArgumentList $Arguments -Wait -PassThru
    }

    $argumentText = [string]::Join(' ', $Arguments)
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $InstallerPath
    $startInfo.Arguments = $argumentText
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true

    foreach ($proxyName in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','http_proxy','https_proxy','all_proxy','NO_PROXY','no_proxy')) {
        if ($startInfo.EnvironmentVariables.ContainsKey($proxyName)) {
            $null = $startInfo.EnvironmentVariables.Remove($proxyName)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ExplicitProxyUrl)) {
        $startInfo.EnvironmentVariables['HTTP_PROXY'] = $ExplicitProxyUrl
        $startInfo.EnvironmentVariables['HTTPS_PROXY'] = $ExplicitProxyUrl
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $null = $process.Start()
    $process.WaitForExit()
    return $process
}

function Read-InstallerLogSummary {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MaxWaitSeconds = 30
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{
            Found       = $false
            StatusLine  = $null
            ErrorLine   = $null
            Tail        = @()
        }
    }

    $deadline = (Get-Date).AddSeconds($MaxWaitSeconds)
    do {
        try {
            $lines = @(Get-Content -LiteralPath $Path -ErrorAction Stop)
        }
        catch {
            $lines = @()
        }

        if ($lines.Count -gt 0) {
            $trimmed = @($lines | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $statusLine = $null
            $errorLine = $null

            for ($index = $trimmed.Count - 1; $index -ge 0; $index--) {
                $line = $trimmed[$index]
                if (-not $statusLine -and $line -match '(?i)(success|completed|return value 0|exit code:? 0)') {
                    $statusLine = $line
                }
                if (-not $errorLine -and $line -match '(?i)(error|failed|fatal|return value 3|exception)') {
                    $errorLine = $line
                }
                if ($statusLine -or $errorLine) { break }
            }

            if ($statusLine -or $errorLine) {
                return [pscustomobject]@{
                    Found      = $true
                    StatusLine = $statusLine
                    ErrorLine  = $errorLine
                    Tail       = @($trimmed | Select-Object -Last 10)
                }
            }
        }

        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    return [pscustomobject]@{
        Found      = $false
        StatusLine = $null
        ErrorLine  = $null
        Tail       = @($lines | Select-Object -Last 10)
    }
}

function Get-TextFileContent {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }

    $encodings = @('UTF8','Unicode','BigEndianUnicode','Default')
    foreach ($encoding in $encodings) {
        try {
            $content = Get-Content -LiteralPath $Path -Raw -Encoding $encoding -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($content)) {
                return $content -replace "`0", ''
            }
        }
        catch { Write-Verbose $_.Exception.Message }
    }

    return $null
}

function Get-ComponentValidationKind {
    param([string]$PackageId)

    if ([string]::IsNullOrWhiteSpace($PackageId)) { return $null }
    $token = $PackageId.ToLowerInvariant()

    if ($token -match 'npcap') { return 'Npcap' }
    if ($token -match 'visual|vcredist|vc_redist|vc\+\+|msvc|cpp') { return 'VisualCpp' }
    if ($token -match 'liongard|agent') { return 'AgentMsi' }

    return $null
}

function Get-InstallerBundlePackageSummary {
    param([Parameter(Mandatory)][string]$Path)

    $content = Get-TextFileContent -Path $Path
    if ([string]::IsNullOrWhiteSpace($content)) { return @() }

    $packages = @{}
    $lines = $content -split "`r?`n"
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        if ($line -match 'Detected package:\s*(?<id>[^,]+),\s*state:\s*(?<state>[^,]+)(?:,\s*cached:\s*(?<cached>[^,]+))?') {
            $id = $Matches['id'].Trim()
            if (-not $packages.ContainsKey($id)) {
                $packages[$id] = [ordered]@{ PackageId = $id; Kind = (Get-ComponentValidationKind -PackageId $id) }
            }
            $packages[$id].DetectedState = $Matches['state'].Trim()
            if ($Matches['cached']) { $packages[$id].Cached = $Matches['cached'].Trim() }
            continue
        }

        if ($line -match 'Planned package:\s*(?<id>[^,]+),\s*state:\s*(?<state>[^,]+).*?\bexecute:\s*(?<execute>[^,]+)') {
            $id = $Matches['id'].Trim()
            if (-not $packages.ContainsKey($id)) {
                $packages[$id] = [ordered]@{ PackageId = $id; Kind = (Get-ComponentValidationKind -PackageId $id) }
            }
            $packages[$id].PlannedState = $Matches['state'].Trim()
            $packages[$id].PlannedExecute = $Matches['execute'].Trim()
            continue
        }

        if ($line -match 'Applied execute package:\s*(?<id>[^,]+),\s*result:\s*(?<result>[^,]+)') {
            $id = $Matches['id'].Trim()
            if (-not $packages.ContainsKey($id)) {
                $packages[$id] = [ordered]@{ PackageId = $id; Kind = (Get-ComponentValidationKind -PackageId $id) }
            }
            $packages[$id].ApplyResult = $Matches['result'].Trim()
            continue
        }

        if ($line -match 'The process for package:\s*(?<id>[^,]+)\s+exited with code:\s*(?<code>0x[0-9A-Fa-f]+|\d+).*?type:\s*(?<type>[^ ]+)\s+and restart:\s*(?<restart>[^\.]+)') {
            $id = $Matches['id'].Trim()
            if (-not $packages.ContainsKey($id)) {
                $packages[$id] = [ordered]@{ PackageId = $id; Kind = (Get-ComponentValidationKind -PackageId $id) }
            }
            $packages[$id].ProcessExitCode = $Matches['code'].Trim()
            $packages[$id].ProcessExitType = $Matches['type'].Trim()
            $packages[$id].Restart = $Matches['restart'].Trim()
            continue
        }

        if ($line -match 'Package \(.*?\)\s*:\s*(?<id>[^,]+),\s*result:\s*(?<result>[^,]+)') {
            $id = $Matches['id'].Trim()
            if (-not $packages.ContainsKey($id)) {
                $packages[$id] = [ordered]@{ PackageId = $id; Kind = (Get-ComponentValidationKind -PackageId $id) }
            }
            $packages[$id].ApplyResult = $Matches['result'].Trim()
            continue
        }
    }

    return @(
        $packages.Values |
        Where-Object { $_.Kind } |
        ForEach-Object { [pscustomobject]$_ }
    )
}

function Get-BundlePackageRecord {
    param(
        [Parameter(Mandatory)][object[]]$BundlePackages,
        [Parameter(Mandatory)][string]$PackageId
    )

    return ($BundlePackages | Where-Object { $_.PackageId -eq $PackageId } | Select-Object -First 1)
}

function Get-VcRuntimeRegistryStatus {
    $results = New-Object System.Collections.Generic.List[object]

    foreach ($arch in @('X86','X64')) {
        $path = "HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\$arch"
        $isInstalled = $false
        $version = $null

        try {
            if (Test-Path -LiteralPath $path) {
                $item = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
                $installedFlag = Get-ObjectPropertyValue -Object $item -Name 'Installed' -Default 0
                $version = Get-ObjectPropertyValue -Object $item -Name 'Version'
                $isInstalled = ($installedFlag -eq 1)
            }
        }
        catch { Write-Verbose $_.Exception.Message }

        $results.Add([pscustomobject]@{
            Architecture = $arch
            Installed    = $isInstalled
            Version      = $version
            Path         = $path
        }) | Out-Null
    }

    return @($results)
}

function Test-NpcapInstalled {
    foreach ($path in @(
            'C:\Windows\System32\drivers\npcap.sys',
            'C:\Windows\SysWOW64\Npcap\npcap.dll',
            'C:\Program Files\Npcap',
            'C:\Program Files (x86)\Npcap'
        )) {
        if (Test-Path -LiteralPath $path) {
            return $true
        }
    }

    foreach ($regPath in @(
            'HKLM:\SYSTEM\CurrentControlSet\Services\npcap',
            'HKLM:\SYSTEM\CurrentControlSet\Services\npf'
        )) {
        if (Test-Path -LiteralPath $regPath) {
            return $true
        }
    }

    $services = @('npcap','npcapwatchdog','npf')
    foreach ($serviceName in $services) {
        if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
            return $true
        }
    }

    $entries = @(Get-UninstallEntry -Names @('Npcap') -ProductCodes @())
    return ($entries.Count -gt 0)
}

function Get-VisualCppEntry {
    return @(Get-UninstallEntry -Names @('Microsoft Visual C++','Visual C++') -ProductCodes @() | Where-Object {
        $_.Name -match '(?i)redistributable' -and $_.Name -match '(?i)\((x86|x64)\)'
    })
}

function Test-VisualCppInstalled {
    if ((Get-VisualCppEntry).Count -gt 0) {
        return $true
    }

    return (@(Get-VcRuntimeRegistryStatus | Where-Object { $_.Installed }).Count -gt 0)
}

function Get-NpcapDetectionDetail {
    $details = New-Object System.Collections.Generic.List[string]

    foreach ($serviceName in @('npcap','npcapwatchdog','npf')) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($service) {
            $details.Add("Service '$serviceName' status=$($service.Status)") | Out-Null
        }
    }

    foreach ($regPath in @(
            'HKLM:\SYSTEM\CurrentControlSet\Services\npcap',
            'HKLM:\SYSTEM\CurrentControlSet\Services\npf'
        )) {
        if (Test-Path -LiteralPath $regPath) {
            $details.Add("Registry key present: $regPath") | Out-Null
        }
    }

    foreach ($path in @(
            'C:\Windows\System32\drivers\npcap.sys',
            'C:\Windows\SysWOW64\Npcap\npcap.dll',
            'C:\Program Files\Npcap',
            'C:\Program Files (x86)\Npcap'
        )) {
        if (Test-Path -LiteralPath $path) {
            $details.Add("Path present: $path") | Out-Null
        }
    }

    $entries = @(Get-UninstallEntry -Names @('Npcap') -ProductCodes @())
    foreach ($entry in ($entries | Select-Object -First 2)) {
        $details.Add("Uninstall entry: $($entry.Name)") | Out-Null
    }

    return @($details)
}

function Get-InstallerFailureHint {
    param([Parameter(Mandatory)][string]$LogPath)

    $content = Get-TextFileContent -Path $LogPath
    if ([string]::IsNullOrWhiteSpace($content)) { return @() }

    $hints = New-Object System.Collections.Generic.List[string]

    if ($content -match '(?i)\(407\)\s+Proxy Authentication Required') {
        $hints.Add('Installer API validation failed with HTTP 407 Proxy Authentication Required. The MSI is attempting to use a proxy that is not accepted for this connection.') | Out-Null
    }
    if ($content -match '(?i)unable to contact the Liongard server with the URL and credentials provided') {
        $hints.Add('The Liongard MSI could not validate registration against the Liongard API endpoint.') | Out-Null
    }
    if ($content -match '(?i)\bPROXYURL\s*=\s*(?<proxy>[^\r\n]+)') {
        $proxyValue = $Matches['proxy'].Trim().Trim('"')
        if (-not [string]::IsNullOrWhiteSpace($proxyValue)) {
            $maskedProxy = if ($proxyValue -match '^(?<scheme>https?://)(?<user>[^:/@]+)(:(?<pass>[^@]*))?@(?<host>.+)$') {
                "{0}{1}:****@{2}" -f $Matches['scheme'], $Matches['user'], $Matches['host']
            }
            else {
                $proxyValue
            }
            $hints.Add("MSI runtime proxy value: $maskedProxy") | Out-Null
        }
    }
    if ($content -match '(?i)\bRebootPending\s*=\s*1\b' -or $content -match '(?i)\bMsiSystemRebootPending\s*=\s*1\b') {
        $hints.Add('A pending reboot was detected during installation. This was not the primary failure in this run, but it can interfere with future installer attempts.') | Out-Null
    }

    return @($hints | Select-Object -Unique)
}

function Resolve-ComponentValidationStatus {
    param(
        [string]$Name,
        [pscustomobject[]]$BundlePackages,
        [bool]$InstallEnhancedNetworkDiscoveryRequested
    )

    $matchingPackages = @($BundlePackages | Where-Object { $_.Kind -eq $Name })
    $packageDetail = if ($matchingPackages.Count -gt 0) {
        $matchingPackages | Select-Object -First 3 | ForEach-Object {
            $bits = @($_.PackageId)
            if ($_.DetectedState) { $bits += "detected=$($_.DetectedState)" }
            if ($_.PlannedExecute) { $bits += "execute=$($_.PlannedExecute)" }
            if ($_.ApplyResult) { $bits += "result=$($_.ApplyResult)" }
            ($bits -join ', ')
        }
    } else { @() }

    switch ($Name) {
        'AgentMsi' {
            $installed = Test-LiongardAgentInstalled
            $package = $matchingPackages | Select-Object -First 1
            $status = if ($installed) { 'Installed' } else { 'NotDetected' }
            if ($package -and $package.DetectedState -match 'Present' -and ($package.PlannedExecute -eq 'None' -or -not $package.PlannedExecute) -and $installed) {
                $status = 'AlreadyPresent'
            }
            $localDetails = Get-LiongardAgentDetectionDetail
            $detail = if ($packageDetail.Count -gt 0) {
                if ($localDetails.Count -gt 0) { ($packageDetail -join ' | ') + ' | ' + ($localDetails -join '; ') } else { $packageDetail -join ' | ' }
            }
            elseif ($localDetails.Count -gt 0) { $localDetails -join '; ' }
            else { 'Validated via local agent detection.' }
            return [pscustomobject]@{
                Name   = 'Liongard Agent MSI'
                Status = $status
                Detail = Convert-ValidationDetailToText -Detail $detail
            }
        }
        'VisualCpp' {
            $installed = Test-VisualCppInstalled
            $package = $matchingPackages | Select-Object -First 1
            $status = if ($installed) { 'Installed' } else { 'NotDetected' }
            if ($package -and $package.DetectedState -match 'Present' -and ($package.PlannedExecute -eq 'None' -or -not $package.PlannedExecute) -and $installed) {
                $status = 'AlreadyPresent'
            }
            $localDetail = if ($installed) {
                $vcEntries = Get-VisualCppEntry | Select-Object -First 4 -ExpandProperty Name
                $runtimeKeys = @(Get-VcRuntimeRegistryStatus | Where-Object { $_.Installed } | ForEach-Object {
                    if ($_.Version) { "$($_.Architecture)=$($_.Version)" } else { "$($_.Architecture)=Installed" }
                })
                $parts = @()
                if ($vcEntries) { $parts += "Uninstall entries: $($vcEntries -join '; ')" }
                if ($runtimeKeys) { $parts += "Runtime registry: $($runtimeKeys -join '; ')" }
                if ($parts.Count -gt 0) { $parts -join ' | ' } else { 'Validated via local Visual C++ redistributable detection.' }
            } else { 'Local Visual C++ redistributable entry not found.' }
            $detail = if ($packageDetail.Count -gt 0) { ($packageDetail -join ' | ') + ' | ' + $localDetail } else { $localDetail }
            return [pscustomobject]@{
                Name   = 'Visual C++ Runtime'
                Status = $status
                Detail = Convert-ValidationDetailToText -Detail $detail
            }
        }
        'Npcap' {
            if (-not $InstallEnhancedNetworkDiscoveryRequested) {
                return [pscustomobject]@{
                    Name   = 'Npcap'
                    Status = 'SkippedByConfig'
                    Detail = 'InstallEnhancedNetworkDiscovery is false.'
                }
            }

            $installed = Test-NpcapInstalled
            $package = $matchingPackages | Select-Object -First 1
            $status = if ($installed) { 'Installed' } else { 'NotDetected' }
            if ($package -and $package.DetectedState -match 'Present' -and ($package.PlannedExecute -eq 'None' -or -not $package.PlannedExecute) -and $installed) {
                $status = 'AlreadyPresent'
            }
            $npcapDetails = Get-NpcapDetectionDetail
            $localDetail = if ($installed) {
                if ($npcapDetails.Count -gt 0) { $npcapDetails -join '; ' } else { 'Validated via local Npcap service/uninstall detection.' }
            } else { 'Local Npcap service/uninstall entry not found.' }
            $detail = if ($packageDetail.Count -gt 0) { ($packageDetail -join ' | ') + ' | ' + $localDetail } else { $localDetail }
            return [pscustomobject]@{
                Name   = 'Npcap'
                Status = $status
                Detail = Convert-ValidationDetailToText -Detail $detail
            }
        }
    }

    return $null
}

function Convert-ValidationDetailToText {
    param([Parameter()][object]$Detail)

    if ($null -eq $Detail) { return $null }

    if ($Detail -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Detail)) { return $null }
        return $Detail
    }

    if ($Detail -is [System.Collections.IEnumerable] -and -not ($Detail -is [string])) {
        $parts = @(
            $Detail |
            ForEach-Object { if ($null -ne $_) { [string]$_ } } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )

        if ($parts.Count -eq 0) { return $null }
        return ($parts -join ' | ')
    }

    $text = [string]$Detail
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text
}

function New-BundlePackageSnapshot {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [Parameter()][object]$Package,
        [Parameter(Mandatory)][string]$PackageId
    )

    if (-not $Package) {
        return [pscustomobject]@{
            PackageId      = $PackageId
            DetectedState  = $null
            PlannedState   = $null
            PlannedExecute = $null
            ApplyResult    = $null
            Restart        = $null
            ProcessExitCode = $null
            ProcessExitType = $null
        }
    }

    return [pscustomobject]@{
        PackageId       = $Package.PackageId
        DetectedState   = $Package.DetectedState
        PlannedState    = $Package.PlannedState
        PlannedExecute  = $Package.PlannedExecute
        ApplyResult     = $Package.ApplyResult
        Restart         = $Package.Restart
        ProcessExitCode = $Package.ProcessExitCode
        ProcessExitType = $Package.ProcessExitType
    }
}

function Get-LiongardAgentLocalValidation {
    $evidence = Get-LiongardAgentDetectionDetail
    $serviceNames = Get-LiongardServiceName | Select-Object -Unique
    $serviceObjects = @($serviceNames | ForEach-Object { Get-Service -Name $_ -ErrorAction SilentlyContinue } | Where-Object { $_ })
    $status = if ((Test-LiongardAgentInstalled) -or $evidence.Count -gt 0) { 'Installed' } else { 'NotDetected' }

    return [pscustomobject]@{
        Status   = $status
        Evidence = @($evidence)
        Services = @($serviceObjects | ForEach-Object { "$($_.Name)=$($_.Status)" })
    }
}

function Get-VisualCppLocalValidation {
    $entries = @(Get-VisualCppEntry)
    $runtimeKeys = @(Get-VcRuntimeRegistryStatus)
    $versions = @(
        $runtimeKeys |
        Where-Object { $_.Installed } |
        ForEach-Object {
            if ($_.Version) { "$($_.Architecture)=$($_.Version)" } else { "$($_.Architecture)=Installed" }
        }
    )

    $evidence = @()
    $evidence += @($entries | Select-Object -ExpandProperty Name -ErrorAction SilentlyContinue)
    $evidence += $versions

    $status = if ($evidence.Count -gt 0) { 'Installed' } else { 'NotDetected' }

    return [pscustomobject]@{
        Status   = $status
        Evidence = @($evidence)
        Versions = @($versions)
    }
}

function Get-NpcapLocalValidation {
    $evidence = @(Get-NpcapDetectionDetail)
    $status = if (Test-NpcapInstalled) { 'Installed' } else { 'NotDetected' }

    return [pscustomobject]@{
        Status   = $status
        Evidence = @($evidence)
    }
}

function Resolve-FinalComponentStatus {
    param(
        [Parameter(Mandatory)][bool]$Requested,
        [Parameter(Mandatory)][pscustomobject]$Bundle,
        [Parameter(Mandatory)][pscustomobject]$Local,
        [string]$SkipStatus = 'SkippedByConfig'
    )

    if (-not $Requested) { return $SkipStatus }

    if ($Local.Status -eq 'Installed') {
        if ($Bundle.ApplyResult -eq '0x0' -or $Bundle.ProcessExitCode -eq '0x0') { return 'Installed' }
        if ($Bundle.DetectedState -eq 'Present' -and ($Bundle.PlannedExecute -eq 'None' -or -not $Bundle.PlannedExecute)) { return 'AlreadyPresent' }
        return 'Installed'
    }

    if ($Bundle.DetectedState -eq 'Present' -and ($Bundle.PlannedExecute -eq 'None' -or -not $Bundle.PlannedExecute)) {
        return 'AlreadyPresent'
    }
    if ($Bundle.ApplyResult -and $Bundle.ApplyResult -ne '0x0') {
        return 'Failed'
    }
    if ($Bundle.ProcessExitCode -and $Bundle.ProcessExitCode -ne '0x0') {
        return 'Failed'
    }
    if ($Bundle.PackageId -and ($Bundle.PlannedExecute -eq 'Install' -or $Bundle.DetectedState -or $Bundle.ApplyResult)) {
        return 'BundleOnly'
    }

    return 'NotDetected'
}

function New-ComponentValidationRecord {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Requested,
        [Parameter(Mandatory)][pscustomobject]$Bundle,
        [Parameter(Mandatory)][pscustomobject]$Local,
        [string]$SkipStatus = 'SkippedByConfig'
    )

    $status = Resolve-FinalComponentStatus -Requested $Requested -Bundle $Bundle -Local $Local -SkipStatus $SkipStatus
    $evidence = @()
    $evidence += Convert-ToStringArray -Value $Local.Evidence

    return [pscustomobject]@{
        Name      = $Name
        Requested = $Requested
        Bundle    = $Bundle
        Local     = $Local
        Evidence  = @($evidence)
        Status    = $status
    }
}

function Get-ComponentValidationResult {
    param(
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][bool]$InstallEnhancedNetworkDiscoveryRequested
    )

    $bundlePackages = @(Get-InstallerBundlePackageSummary -Path $LogPath)
    if (-not $bundlePackages) { $bundlePackages = @() }

    $agentBundleRecord = Get-BundlePackageRecord -BundlePackages $bundlePackages -PackageId 'LiongardAgentMsi'
    $vcBundleRecord = Get-BundlePackageRecord -BundlePackages $bundlePackages -PackageId 'VC_redist.x86.exe'
    $npcapBundleRecord = Get-BundlePackageRecord -BundlePackages $bundlePackages -PackageId 'Npcap'

    $agentBundle = New-BundlePackageSnapshot -Package $agentBundleRecord -PackageId 'LiongardAgentMsi'
    $vcBundle = New-BundlePackageSnapshot -Package $vcBundleRecord -PackageId 'VC_redist.x86.exe'
    $npcapBundle = New-BundlePackageSnapshot -Package $npcapBundleRecord -PackageId 'Npcap'

    $results = @(
        New-ComponentValidationRecord -Name 'Liongard Agent MSI' -Requested $true -Bundle $agentBundle -Local (Get-LiongardAgentLocalValidation)
        New-ComponentValidationRecord -Name 'Visual C++ Runtime' -Requested $true -Bundle $vcBundle -Local (Get-VisualCppLocalValidation)
        New-ComponentValidationRecord -Name 'Npcap' -Requested $InstallEnhancedNetworkDiscoveryRequested -Bundle $npcapBundle -Local (Get-NpcapLocalValidation) -SkipStatus 'SkippedByConfig'
    )

    return [pscustomobject]@{
        BundlePackages = @($bundlePackages)
        Components     = @($results)
    }
}

function Write-BundlePackageResult {
    param([Parameter(Mandatory)][pscustomobject[]]$BundlePackages)

    Start-LogSection -Name 'Bundle Results'
    foreach ($package in $BundlePackages) {
        Write-Host "Package: $($package.PackageId)"
        Write-SectionValue -Label 'Detected State' -Value $package.DetectedState
        Write-SectionValue -Label 'Planned State' -Value $package.PlannedState
        Write-SectionValue -Label 'Planned Action' -Value $package.PlannedExecute
        Write-SectionValue -Label 'Result' -Value $package.ApplyResult
        Write-SectionValue -Label 'Process Exit Code' -Value $package.ProcessExitCode
        Write-SectionValue -Label 'Process Exit Type' -Value $package.ProcessExitType
        Write-SectionValue -Label 'Restart' -Value $package.Restart
        Write-Host "-----------------------------"
    }
    Complete-LogSection
}

function Write-ComponentValidationSummary {
    param([Parameter(Mandatory)][pscustomobject[]]$Components)

    Start-LogSection -Name 'Component Validation'
    foreach ($result in $Components) {
        Write-Host ("Component: {0}" -f $result.Name)
        Write-SectionValue -Label 'Requested' -Value $result.Requested
        Write-SectionValue -Label 'Bundle Package' -Value $result.Bundle.PackageId
        Write-SectionValue -Label 'Bundle Detected State' -Value $result.Bundle.DetectedState
        Write-SectionValue -Label 'Bundle Planned Action' -Value $result.Bundle.PlannedExecute
        Write-SectionValue -Label 'Bundle Result' -Value $result.Bundle.ApplyResult
        Write-SectionValue -Label 'Bundle Restart' -Value $result.Bundle.Restart
        Write-SectionValue -Label 'Local Validation' -Value $result.Local.Status
        Write-SectionValue -Label 'Supporting Evidence' -Value $result.Evidence
        Write-SectionValue -Label 'Final Component Status' -Value $result.Status
        Write-Host "-----------------------------"
    }
    Complete-LogSection
}

function Get-FinalRunStatus {
    param(
        [Parameter(Mandatory)][int]$InstallerExitCode,
        [Parameter(Mandatory)][bool]$AgentDetected,
        [Parameter(Mandatory)][pscustomobject[]]$Components,
        [Parameter(Mandatory)][string[]]$Warnings,
        [Parameter(Mandatory)][string[]]$Errors
    )

    if ($Errors.Count -gt 0 -and ($InstallerExitCode -ne 0 -and $InstallerExitCode -ne 3010)) {
        return 'Failed'
    }

    $agentComponent = @($Components | Where-Object { $_.Name -eq 'Liongard Agent MSI' } | Select-Object -First 1)
    if (($InstallerExitCode -ne 0 -and $InstallerExitCode -ne 3010) -or -not $AgentDetected -or ($agentComponent.Status -eq 'Failed')) {
        return 'Failed'
    }

    $problemComponents = @($Components | Where-Object { $_.Status -in @('Failed','BundleOnly','NotDetected') })
    if ($problemComponents.Count -gt 0) {
        return 'PartialValidation'
    }

    if ($Warnings.Count -gt 0) {
        return 'SuccessWithWarnings'
    }

    return 'Success'
}

function Export-RunSummaryArtifact {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Summary
    )

    try {
        $folderPath = Split-Path -Path $Path -Parent
        if (-not (Test-Path -LiteralPath $folderPath)) {
            New-Item -Path $folderPath -ItemType Directory -Force | Out-Null
        }

        $Summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
        Write-SectionValue -Label 'Summary Artifact' -Value $Path
    }
    catch {
        Add-RunWarning "Failed to write JSON summary artifact: $($_.Exception.Message)"
    }
}

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = 'Stop'

$uninstallResult = $null
$remoteDeletionRequested = $false
$componentValidation = $null
$finalStatus = 'Failed'
$exitCode = -1
$agentDetected = $false
$logPath = $null
$environmentInput = $Environment
$environmentNormalized = ConvertTo-NormalizedEnvironmentName -Value $Environment
$resolvedEnvironmentValue = $null
$localFqdn = $null
$proxyEnvironmentSnapshot = @()
$matchingAgentCount = 0
$hostnameMatchCount = 0
$deviceGuidOverride = $null
$deviceGuidOverrideApplied = $false
$deviceGuidDecision = 'Undetermined'
$deviceGuidDecisionReason = $null

try {
    if ($IncludeEnvironmentValue -and [string]::IsNullOrWhiteSpace($Environment)) {
        throw "Parameter 'Environment' must be provided when IncludeEnvironmentValue is true."
    }

    Start-LiongardTranscript -TargetFolder $Folder
    $summaryStamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $script:SummaryArtifactPath = Join-Path -Path $Folder -ChildPath ("LGAgentSummary_{0}.json" -f $summaryStamp)
    Write-ConfigurationSnapshot

    if ($EnablePreUninstall) {
        Start-LogSection -Name 'Pre-Uninstall'
        Write-SectionValue -Label 'Enabled' -Value $EnablePreUninstall
        Write-Host "Pre-uninstall toggle is enabled. Attempting to remove any existing Liongard Agent..."
        $uninstallResult = Invoke-LiongardAgentUninstall
        if (-not $uninstallResult.Success) {
            Add-RunWarning "Liongard Agent uninstall completed with issues: $($uninstallResult.Issues -join ', ')"
            if ($RemoveAgentFromPlatform) {
                Add-RunWarning "Skipping remote agent deletion because the local uninstall did not complete successfully."
            }
        }
        elseif ($RemoveAgentFromPlatform) {
            $remoteDeletionRequested = $true
            Write-Host "Remote agent deletion flag enabled. Will attempt to remove the matching Liongard record after identifying it."
        }

        if (Test-LiongardAgentInstalled) {
            throw "Liongard Agent is still detected after uninstall attempt. Aborting installation."
        }
        Complete-LogSection
    }
    else {
        Start-LogSection -Name 'Pre-Uninstall'
        Write-SectionValue -Label 'Enabled' -Value $EnablePreUninstall
        if (Test-LiongardAgentInstalled) {
            Write-Host "Liongard Agent is already installed. Skipping installation."
            Complete-LogSection
            return
        }
        if ($RemoveAgentFromPlatform) {
            Add-RunWarning "Remote agent deletion request ignored because pre-uninstall is disabled."
        }
        Complete-LogSection
    }

    Write-Host "No Liongard Agent installation was found. Proceeding with installation..."

    $instancePrefix = Resolve-InstancePrefix -Value $InstancePrefix
    $liongardHost = "$instancePrefix.app.liongard.com"
    $localHostname = $env:COMPUTERNAME
    $localMachineGuid = Get-LocalMachineGuid
    $localHostnames = Get-LocalHostnameVariant -PrimaryName $localHostname
    $localFqdn = ($localHostnames | Where-Object { $_ -match '\.' } | Select-Object -First 1)

    Start-LogSection   -Name  'Host Identity'
    Write-SectionValue -Label 'Resolved Liongard Host' -Value $liongardHost
    Write-SectionValue -Label 'Local Hostname' -Value $localHostname
    Write-SectionValue -Label 'Local FQDN' -Value $localFqdn
    Write-SectionValue -Label 'Local MachineGuid' -Value $localMachineGuid
    Write-SectionValue -Label 'Host Identifiers Considered' -Value ($localHostnames -join ', ')
    Complete-LogSection

    $proxyEnvironmentSnapshot = @(Get-ProxyEnvironmentSnapshot)
    Start-LogSection -Name 'Proxy Preflight'
    Write-SectionValue -Label 'Configured ProxyUrl' -Value $(if ([string]::IsNullOrWhiteSpace($ProxyUrl)) { '<empty>' } else { ConvertTo-MaskedProxy -Value $ProxyUrl })
    Write-SectionValue -Label 'Clear Proxy Environment For Installer' -Value $ClearProxyEnvironmentForInstaller
    if ($proxyEnvironmentSnapshot.Count -gt 0) {
        Write-Host "Detected proxy-related environment variables that the MSI may import at runtime:"
        foreach ($proxyEntry in $proxyEnvironmentSnapshot) {
            Write-SectionValue -Label $proxyEntry.Name -Value $proxyEntry.Masked
        }

        if ($ClearProxyEnvironmentForInstaller -and [string]::IsNullOrWhiteSpace($ProxyUrl)) {
            Write-Host "Installer child process will have proxy-related environment variables removed so the MSI does not repopulate PROXYURL from environment."
        }
        elseif ($ClearProxyEnvironmentForInstaller -and -not [string]::IsNullOrWhiteSpace($ProxyUrl)) {
            Write-Host "Installer child process will have inherited proxy variables removed and replaced with the explicit ProxyUrl value."
        }
        else {
            Add-RunWarning "Proxy-related environment variables are present and may override a blank PROXYURL inside the MSI."
        }
    }
    else {
        Write-Host "No proxy-related environment variables were detected."
    }
    Complete-LogSection

    $headers = Get-LiongardAuthHeader -ApiTokenKey $ApiTokenKey -ApiTokenSecret $ApiTokenSecret

    Start-LogSection -Name 'Environment Resolution'
    Write-SectionValue -Label 'Environment Input' -Value $environmentInput
    Write-SectionValue -Label 'Environment Input Normalized' -Value $environmentNormalized
    if ($IncludeEnvironmentValue -and -not [string]::IsNullOrWhiteSpace($Environment)) {
        $script:EnvironmentResolutionReason = $null
        $resolvedEnvironment = Resolve-LiongardEnvironmentName -InputName $Environment -InstancePrefix $instancePrefix -Headers $headers
        if ($resolvedEnvironment -and -not [string]::Equals($resolvedEnvironment, $Environment, [System.StringComparison]::Ordinal)) {
            Write-Host ("Matched provided environment to Liongard: '{0}' -> '{1}' (Reason: {2})" -f $Environment, $resolvedEnvironment, $script:EnvironmentResolutionReason)
            $Environment = $resolvedEnvironment
        }
        elseif ($resolvedEnvironment) {
            Write-Host ("Environment confirmed in Liongard: '{0}' (Reason: {1})" -f $Environment, $script:EnvironmentResolutionReason)
        }
        else {
            $normalizedEnv = ConvertTo-NormalizedEnvironmentName -Value $Environment
            $reasonLabel = if ($script:EnvironmentResolutionReason) { $script:EnvironmentResolutionReason } else { 'Unknown' }
            if ($reasonLabel -eq 'NoEnvironmentsReturned') {
                Add-RunWarning ("Environment lookup API did not return environments for host '{0}'. Continuing with the supplied LiongardEnvironment value '{1}' without API confirmation." -f $liongardHost, $Environment)
            }
            else {
                throw ("Environment '{0}' (normalized '{1}') could not be resolved in Liongard. Reason: {2}. Aborting installation because LiongardEnvironment is required." -f $Environment, $normalizedEnv, $reasonLabel)
            }
        }
    }
    $resolvedEnvironmentValue = $Environment
    Write-SectionValue -Label 'Resolution Reason' -Value $script:EnvironmentResolutionReason
    Write-SectionValue -Label 'Resolved Environment' -Value $resolvedEnvironmentValue
    Complete-LogSection

    $agents = @()
    if ($localMachineGuid) {
        $escapedGuid = $localMachineGuid -replace "'", "''"
        $machineGuidCondition = "MachineGuid = '$escapedGuid'"
        $agents = @(Get-LiongardAgent -LiongardURL $liongardHost -ApiKey $ApiTokenKey -ApiSecret $ApiTokenSecret -Conditions $machineGuidCondition)
    }
    if (-not $agents -or $agents.Count -eq 0) {
        Write-Host "No agents returned for filtered MachineGuid lookup; skipping pagination by design."
    }

    if ($remoteDeletionRequested) {
        $remoteDeleteOutcome = Invoke-LiongardRemoteAgentRemoval -InstancePrefix $instancePrefix -ApiKey $ApiTokenKey -ApiSecret $ApiTokenSecret -Agents $agents -LocalHostnames $localHostnames -LocalMachineGuid $localMachineGuid -MinimumScore $MinimumRemoteDeletionScore
        if ($remoteDeleteOutcome.Deleted -and $remoteDeleteOutcome.AgentId) {
            $agents = @($agents | Where-Object { $_.ID -ne $remoteDeleteOutcome.AgentId })
        }
    }

    Start-LogSection -Name 'Existing Agent Lookup'
    $agentInventory = @(
        $agents |
        Where-Object { $_.MachineGuid } |
        Select-Object -Property @{ Name = 'Name'; Expression = { $_.Name } },
        @{ Name = 'Hostname'; Expression = { $_.Hostname } },
        @{ Name = 'MachineGuid'; Expression = { $_.MachineGuid } }
    )

    if ($agentInventory.Count -gt 0) {
        Write-Host "Collected $($agentInventory.Count) Liongard agent record(s) with MachineGuid values."
        foreach ($entry in ($agentInventory | Select-Object -First 5)) {
            $displayHost = if (-not [string]::IsNullOrWhiteSpace($entry.Hostname)) { $entry.Hostname } else { $entry.Name }
            Write-Host " - Hostname: $displayHost | MachineGuid: $($entry.MachineGuid)"
        }
        if ($agentInventory.Count -gt 5) {
            Write-Host " - ...(additional entries truncated)..."
        }
    }
    else {
        Write-Host "No existing Liongard agents reported MachineGuid values."
    }
    Complete-LogSection

    $deviceGuidOverride = Resolve-DeviceGuidOverride -LocalGuid $localMachineGuid -LocalHostnames $localHostnames -Agents $agents
    $matchingMachineGuidAgents = @($agents | Where-Object { $_.MachineGuid -and $_.MachineGuid -eq $localMachineGuid })
    $matchingAgentCount = $matchingMachineGuidAgents.Count
    $hostnameMatchCount = @($matchingMachineGuidAgents | Where-Object { Test-AgentHostnameMatch -LocalHostnames $localHostnames -Agent $_ }).Count
    $deviceGuidOverrideApplied = -not [string]::IsNullOrWhiteSpace($deviceGuidOverride)
    if ($deviceGuidOverrideApplied) {
        $deviceGuidDecision = 'Override DEVICEGUID'
        $deviceGuidDecisionReason = 'Duplicate MachineGuid records would cause ambiguous backend association'
    }
    else {
        $deviceGuidDecision = 'Reuse local MachineGuid'
        $deviceGuidDecisionReason = 'Single matching MachineGuid record aligns with hostname/FQDN or no duplicate conflict was found'
    }

    Start-LogSection -Name 'DEVICEGUID Decision'
    Write-SectionValue -Label 'Local MachineGuid' -Value $localMachineGuid
    Write-SectionValue -Label 'Local Hostname(s)' -Value ($localHostnames -join ', ')
    Write-SectionValue -Label 'Local FQDN' -Value $localFqdn
    Write-SectionValue -Label 'Matching Liongard Agents By MachineGuid' -Value $matchingAgentCount
    Write-SectionValue -Label 'Hostname/FQDN Matches' -Value $hostnameMatchCount
    Write-SectionValue -Label 'Decision' -Value $deviceGuidDecision
    Write-SectionValue -Label 'Reason' -Value $deviceGuidDecisionReason
    Write-SectionValue -Label 'Generated DEVICEGUID' -Value $deviceGuidOverride
    Complete-LogSection

    Start-LogSection -Name 'Installer Download / Path Verification'
    Write-Host "Checking if folder [$Folder] exists..."
    if (-not (Test-Path -Path $Folder)) {
        Write-Host "Path does not exist. Creating directory at [$Folder]..."
        New-Item -Path $Folder -ItemType Directory -Force | Out-Null
    }

    if (-not (Test-Path -Path $Folder)) {
        throw "Failed to create directory [$Folder]. Check permissions and rerun the script."
    }

    $installerPath = Join-Path -Path $Folder -ChildPath $InstallerFileName
    if (-not (Save-LiongardInstaller -Uri $InstallerUrl -DestinationPath $installerPath -MinimumBytes 1048576 -MaxAttempts 3)) {
        throw "Failed to download installer from [$InstallerUrl] after multiple attempts."
    }
    Write-SectionValue -Label 'Installer Path' -Value $installerPath

    $logPath = if ([string]::IsNullOrWhiteSpace($InstallerLogPath)) {
        Join-Path -Path $Folder -ChildPath 'AgentInstall.log'
    }
    else {
        $InstallerLogPath
    }
    Write-SectionValue -Label 'Bootstrapper Log Path' -Value $logPath

    if (Test-Path -LiteralPath $logPath) {
        Write-Host "Removing existing installer log [$logPath] to capture fresh results..."
        Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
    }
    Complete-LogSection

    $exeArguments = Get-ExeInstallArgument `
        -LiongardHost $liongardHost `
        -AgentTokenKey $AgentTokenKey `
        -AgentTokenSecret $AgentTokenSecret `
        -AgentName $localHostname `
        -Environment $(if ($IncludeEnvironmentValue) { $Environment } else { $null }) `
        -AgentDescription $AgentDescription `
        -DeviceGuidOverride $deviceGuidOverride `
        -EulaAccepted $EulaAccepted `
        -InstallEnhancedNetworkDiscovery $InstallEnhancedNetworkDiscovery `
        -SuppressRestart $SuppressRestart `
        -PassiveMode $PassiveMode `
        -LogPath $logPath `
        -ProxyUrl $ProxyUrl `
        -AutoUpdate $AutoUpdate `
        -AutoUpdateArgumentName $AutoUpdateArgumentName

    $maskedArguments = Get-MaskedInstallArgument -Arguments $exeArguments

    Start-LogSection -Name 'Installer Launch'
    Write-Host "Launching EXE installer..."
    Write-SectionValue -Label 'Masked Command' -Value ("`"{0}`" {1}" -f $installerPath, ($maskedArguments -join ' '))

    $process = Start-LiongardInstallerProcess -InstallerPath $installerPath -Arguments $exeArguments -ClearProxyEnvironment $ClearProxyEnvironmentForInstaller -ExplicitProxyUrl $ProxyUrl
    $exitCode = if ($process) { $process.ExitCode } else { $LASTEXITCODE }

    Write-SectionValue -Label 'Installer Exit Code' -Value "$exitCode ($(Get-ExitCodeText -Code $exitCode))"

    if (Test-Path -LiteralPath $logPath) {
        $logFile = Get-Item -LiteralPath $logPath -ErrorAction SilentlyContinue
        if ($logFile) {
            Write-SectionValue -Label 'Installer Log Path' -Value ("{0} ({1:N0} bytes)" -f $logPath, $logFile.Length)
        }
        else {
            Write-SectionValue -Label 'Installer Log Path' -Value $logPath
        }
    }
    else {
        Add-RunWarning "Installer log path was not found: $logPath"
    }

    $summary = Read-InstallerLogSummary -Path $logPath -MaxWaitSeconds 30
    if ($summary.Found) {
        if ($summary.StatusLine) {
            Write-SectionValue -Label 'Installer Log Status' -Value $summary.StatusLine
        }
        if ($summary.ErrorLine) {
            Add-RunWarning "Installer log error hint: $($summary.ErrorLine)"
        }
    }
    elseif ($summary.Tail -and $summary.Tail.Count -gt 0) {
        Write-Host "Installer log tail:"
        foreach ($line in $summary.Tail) {
            Write-Host " - $line"
        }
    }
    Complete-LogSection

    try {
        $componentValidation = Get-ComponentValidationResult -LogPath $logPath -InstallEnhancedNetworkDiscoveryRequested $InstallEnhancedNetworkDiscovery
        Write-BundlePackageResult -BundlePackages $componentValidation.BundlePackages
        Write-ComponentValidationSummary -Components $componentValidation.Components
        $failureHints = @(Get-InstallerFailureHint -LogPath $logPath)
        if ($failureHints.Count -gt 0) {
            Start-LogSection -Name 'Installer Failure Hints'
            foreach ($hint in $failureHints) {
                Add-RunWarning ([string]$hint)
            }
            Complete-LogSection
        }
    }
    catch {
        Add-RunWarning "Post-install validation summary encountered an error but the installer itself completed successfully: $($_.Exception.Message)"
    }

    Start-Sleep -Seconds 2
    $agentDetected = $false
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        if (Test-LiongardAgentInstalled) {
            $agentDetected = $true
            break
        }
        Start-Sleep -Seconds 2
    }

    if (($exitCode -eq 0 -or $exitCode -eq 3010) -and $agentDetected) {
        $finalStatus = Get-FinalRunStatus -InstallerExitCode $exitCode -AgentDetected $agentDetected -Components $(if ($componentValidation) { $componentValidation.Components } else { @() }) -Warnings @($script:RunWarnings) -Errors @($script:RunErrors)
        Start-LogSection -Name 'Final Outcome'
        Write-SectionValue -Label 'Final Status' -Value $finalStatus
        Write-SectionValue -Label 'Installer Exit Code' -Value "$exitCode ($(Get-ExitCodeText -Code $exitCode))"
        Write-SectionValue -Label 'Agent Detected' -Value $agentDetected
        Write-SectionValue -Label 'Warnings' -Value @($script:RunWarnings)
        Write-SectionValue -Label 'Errors' -Value @($script:RunErrors)
        Write-Host "Liongard Agent installation verified successfully."
        Complete-LogSection
        return
    }

    if (($exitCode -eq 0 -or $exitCode -eq 3010) -and -not $agentDetected) {
        Add-RunWarning "Installer returned success, but the agent was not detected yet. Review the installer log and allow additional time."
    }
    else {
        Add-RunWarning "Liongard Agent installation failed or agent not detected."
    }

    if (-not $agentDetected) {
        Add-RunWarning "Test-LiongardAgentInstalled returned false after the install attempt."
    }

    throw "Installer returned exit code $exitCode ($(Get-ExitCodeText -Code $exitCode))."
}
catch {
    $finalStatus = 'Failed'
    $script:RunErrors.Add($_.Exception.Message) | Out-Null
    Start-LogSection -Name 'Final Outcome'
    Write-SectionValue -Label 'Final Status' -Value $finalStatus
    Write-SectionValue -Label 'Installer Exit Code' -Value $(if ($exitCode -ge 0) { "$exitCode ($(Get-ExitCodeText -Code $exitCode))" } else { '<not reached>' })
    Write-SectionValue -Label 'Warnings' -Value @($script:RunWarnings)
    Write-SectionValue -Label 'Errors' -Value @($script:RunErrors)
    Complete-LogSection
    Write-Error $_.Exception.Message
    exit 1
}
finally {
    try {
        $componentList = if ($componentValidation) { @($componentValidation.Components) } else { @() }
        $agentComponent = @($componentList | Where-Object { $_.Name -eq 'Liongard Agent MSI' } | Select-Object -First 1)
        $visualCppComponent = @($componentList | Where-Object { $_.Name -eq 'Visual C++ Runtime' } | Select-Object -First 1)
        $npcapComponent = @($componentList | Where-Object { $_.Name -eq 'Npcap' } | Select-Object -First 1)
        if ($finalStatus -eq 'Failed' -and ($exitCode -eq 0 -or $exitCode -eq 3010) -and $agentDetected) {
            $finalStatus = Get-FinalRunStatus -InstallerExitCode $exitCode -AgentDetected $agentDetected -Components $componentList -Warnings @($script:RunWarnings) -Errors @($script:RunErrors)
        }

        $summary = [ordered]@{
            hostname                    = $env:COMPUTERNAME
            fqdn                        = $localFqdn
            localMachineGuid            = $localMachineGuid
            environmentInput            = $environmentInput
            environmentResolved         = $resolvedEnvironmentValue
            environmentResolutionReason = $script:EnvironmentResolutionReason
            matchingAgentCount          = $matchingAgentCount
            hostnameMatchCount          = $hostnameMatchCount
            deviceGuidOverrideApplied   = $deviceGuidOverrideApplied
            deviceGuidOverrideValue     = $deviceGuidOverride
            installerExitCode           = $exitCode
            bundlePackageResults        = if ($componentValidation) { @(Convert-ToPlainObject -Value $componentValidation.BundlePackages) } else { @() }
            liongardAgentStatus         = if ($agentComponent) { $agentComponent.Status } else { $null }
            visualCppStatus             = if ($visualCppComponent) { $visualCppComponent.Status } else { $null }
            visualCppVersions           = if ($visualCppComponent) { @(Convert-ToStringArray -Value $visualCppComponent.Local.Versions) } else { @() }
            npcapStatus                 = if ($npcapComponent) { $npcapComponent.Status } else { $null }
            proxyEnvironmentDetected    = @(Convert-ToPlainObject -Value $proxyEnvironmentSnapshot)
            finalStatus                 = $finalStatus
            warnings                    = @(Convert-ToStringArray -Value $script:RunWarnings)
            errors                      = @(Convert-ToStringArray -Value $script:RunErrors)
        }

        if ($script:SummaryArtifactPath) {
            Start-LogSection -Name 'Summary Artifact'
            Export-RunSummaryArtifact -Path $script:SummaryArtifactPath -Summary $summary
            Complete-LogSection
        }
    }
    catch {
        Write-Warning "Failed during summary artifact finalization: $($_.Exception.Message)"
    }
    Stop-LiongardTranscript
}
