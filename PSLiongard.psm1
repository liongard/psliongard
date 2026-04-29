$agentServiceName    = "roaragent.exe"
$liongardInstallPath = "C:\Program Files (x86)\LiongardInc"
$uninstallPaths      = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)

$Private = @(Get-ChildItem -Path "$PSScriptRoot\Private\*.ps1" -ErrorAction SilentlyContinue)
$Public  = @(Get-ChildItem -Path "$PSScriptRoot\Public\*.ps1"  -ErrorAction SilentlyContinue)

foreach ($file in ($Private + $Public)) {
    . $file.FullName
}

Export-ModuleMember -Function $Public.BaseName
