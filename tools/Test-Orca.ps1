# Focused Desktop regression runner. No installation, capture or real app launch.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Use powershell.exe (Windows PowerShell 5.1).' }
$root=Split-Path $PSScriptRoot
$count=0
foreach ($directory in @('Desktop_Companion','Installer','tests','tools')) {
    Get-ChildItem -LiteralPath (Join-Path $root $directory) -Filter '*.ps1' -File | ForEach-Object {
        $tokens=$null; $parseErrors=$null
        [void][Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$parseErrors)
        if ($parseErrors.Count) { throw ('PowerShell syntax failed: '+$_.Name) }
        $count++
    }
}
Get-ChildItem -LiteralPath (Join-Path $root 'Desktop_Companion') -Filter '*.xaml' -File | ForEach-Object {
    [void][xml](Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8)
}
[void](Get-Content -LiteralPath (Join-Path $root 'Desktop_Companion/settings.defaults.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
Write-Output ('PASS PowerShell 5.1 syntax ('+$count+' files), XAML XML and default settings JSON')
foreach ($name in @('test-control-state.ps1','test-desktop-controls.ps1')) {
    & powershell.exe -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File (Join-Path $root ('tests/'+$name))
    if ($LASTEXITCODE -ne 0) { throw ('FAILED '+$name) }
}
Write-Output 'PASS both Desktop regression scripts (including Orca settings and window cases)'
