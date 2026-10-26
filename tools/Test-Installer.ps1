# Creates only a new owned test root; all settings/keys/Native names are synthetic.
param([string]$FixtureRoot='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Desktop'){throw 'Use Windows PowerShell 5.1 -STA.'}
$root=Split-Path $PSScriptRoot
. (Join-Path $root 'Installer/Install-AmbientWorkspace.ps1')
. (Join-Path $root 'Desktop_Companion/File-Security.ps1')
if(-not $FixtureRoot){$FixtureRoot=Join-Path $env:USERPROFILE ('AmbientWorkspace-Installer-Test-'+[Guid]::NewGuid().ToString('N').Substring(0,8))}
$fixture=[IO.Path]::GetFullPath($FixtureRoot)
New-InstallPrivateDirectory $fixture
Write-Output ('NEW SYNTHETIC LAB: '+$fixture)
foreach($name in @('test-installer.ps1','test-native-registration.ps1')) {
    & powershell.exe -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File (Join-Path $root ('tests/'+$name)) -FixtureParent $fixture
    if($LASTEXITCODE -ne 0){throw ('Failed '+$name+'; fixtures retained for review')}
}
& powershell.exe -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File (Join-Path $root 'tools/Test-Orca.ps1')
if($LASTEXITCODE -ne 0){throw 'Desktop/Orca regression failed'}
Write-Output ('PASS installer, Native rollback and Desktop/Orca regression. Synthetic fixtures retained: '+$fixture)
