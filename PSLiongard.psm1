$Private = @(Get-ChildItem -Path "$PSScriptRoot\Private\*.ps1" -ErrorAction SilentlyContinue)
$Public  = @(Get-ChildItem -Path "$PSScriptRoot\Public\*.ps1"  -ErrorAction SilentlyContinue)

foreach ($file in ($Private + $Public)) {
    . $file.FullName
}

Export-ModuleMember -Function $Public.BaseName
