# Runs real WPF event handlers against new private synthetic installs only.
param([Parameter(Mandatory=$true)][string]$FixtureParent,[switch]$RenderPreviews)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Desktop'){throw 'Use Windows PowerShell 5.1 -STA'}
$root=Split-Path $PSScriptRoot
$lab=Join-Path $FixtureParent ('wizard-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($lab)
$helper=Join-Path $lab 'Install-AmbientWorkspace.ps1'
[IO.File]::Copy((Join-Path $root 'Installer/Install-AmbientWorkspace.ps1'),$helper,$false)
. $helper
$zipPath=Join-Path $lab 'onboarding-review.zip'
& powershell.exe -NoProfile -NonInteractive -File (Join-Path $root 'tools/New-InstallPackage.ps1') -OutputPath $zipPath
if($LASTEXITCODE -ne 0){throw 'Package failed'}
$hash=(Get-FileHash $zipPath).Hash
$package=Open-AmbientInstallPackage $zipPath $hash
Initialize-InstallPolicy $package
# No product Desktop is launched and no Native registration operation is called.
$mutexName='Local\AmbientWorkspace.WizardLab.'+[Guid]::NewGuid().ToString('N')
Set-Item Function:Enter-InstallDesktopLease -Value ([ScriptBlock]::Create((Get-Command Enter-InstallDesktopLease).ScriptBlock.ToString().Replace('Local\AmbientWorkspace.Desktop',$mutexName)))
Add-Type -AssemblyName System.IO.Compression.FileSystem
$extracted=Join-Path $lab 'onboarding-review'
[IO.Compression.ZipFile]::ExtractToDirectory($zipPath,$extracted)
$cases=[Collections.Generic.List[string]]::new()
$windows=[Collections.Generic.List[object]]::new()
function Assert-True($Value,[string]$Message){if(-not $Value){throw $Message}}
function Check([string]$Name,[scriptblock]$Action){& $Action;$cases.Add($Name);Write-Output ('PASS '+$Name)}
function Click($Control){$Control.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}
function New-Wizard {
    $state=New-AmbientInstallWizard $extracted
    $windows.Add($state.window)
    $state.controls.Destination.Text=Join-Path $lab 'app'
    return $state
}
try {
    Check 'complete extraction and original ZIP discovery; hints do not supply trust' {
        Assert-InstallExtractedLayout $extracted
        $script:first=New-Wizard
        Assert-True ($first.controls.ZipPath.Text -ceq $zipPath) 'ZIP was not found'
        Assert-True (-not $first.controls.SourceConsent.IsChecked -and -not $first.controls.ExpectedHash.Text) 'Trust was inferred'
        $incomplete=Join-Path $lab 'partial';[void][IO.Directory]::CreateDirectory($incomplete)
        $rejected=$false;try{Assert-InstallExtractedLayout $incomplete}catch{$rejected=(Get-InstallErrorCode $_) -eq 'INSTALL_EXTRACT_ALL'}
        Assert-True $rejected 'Partial extraction not refused'
        # A manifest filename is an untrusted hint, not a path traversal instruction.
        [IO.File]::WriteAllText((Join-Path $incomplete 'INSTALL-MANIFEST.json'),'{"archiveFileName":"../onboarding-review.zip"}')
        Assert-True (-not (Get-InstallPackageHint $incomplete)) 'Traversal hint was followed'
    }
    Check 'UI source approval, invalid hash and retry before writes' {
        Click $first.controls.Next
        Assert-True ($first.step -eq 1 -and $first.controls.ErrorCode.Text.Contains('INSTALL_SOURCE_APPROVAL_REQUIRED')) 'Missing approval was ignored'
        $first.controls.SourceConsent.IsChecked=$true
        Click $first.controls.Next
        Assert-True ($first.controls.ErrorCode.Text.Contains('INSTALL_EXPECTED_HASH_REQUIRED')) 'Invalid hash lost user guidance'
        $first.controls.ExpectedHash.Text='0'*64;Click $first.controls.Next
        Assert-True ($first.controls.ErrorCode.Text.Contains('INSTALL_ZIP_HASH') -and -not [IO.Directory]::Exists($first.controls.Destination.Text)) 'Hash failure wrote destination'
        Assert-True ($first.controls.Next.IsEnabled -and $first.controls.Page1.IsEnabled) 'Retry UI stayed disabled'
        $first.controls.ExpectedHash.Text=$hash;Click $first.controls.Next
        Assert-True ($first.step -eq 2 -and $first.result.installationMode -eq 'DesktopChrome') ('Fresh install failed: '+$first.controls.ErrorCode.Text)
    }
    Check 'real batch entry refuses partially extracted ZIP before loading helper' {
        $partial=Join-Path $lab 'batch-partial';[void][IO.Directory]::CreateDirectory((Join-Path $partial 'Installer'))
        $entry=Join-Path $partial 'Install.bat';[IO.File]::Copy((Join-Path $root 'Install.bat'),$entry)
        $sentinel=Join-Path $partial 'unexpected-helper-execution'
        [IO.File]::WriteAllText((Join-Path $partial 'Installer/Install-AmbientWorkspace.ps1'),'throw "Partial helper should never run"')
        $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$env:ComSpec;$info.Arguments='/d /c ""'+$entry+'" <nul"'
        $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        $process=[Diagnostics.Process]::Start($info)
        try{$output=$process.StandardOutput.ReadToEnd();$errorOutput=$process.StandardError.ReadToEnd();$process.WaitForExit();Assert-True ($process.ExitCode -eq 1 -and $output.Contains('INSTALL_EXTRACT_ALL') -and -not $errorOutput.Contains('Partial helper')) 'Partial batch did not stop before helper'}finally{$process.Dispose()}
    }
    Check 'extension confirmation is manual; Windows registration and actual auth stay separate' {
        Click $first.controls.Next
        Assert-True ($first.step -eq 2 -and $first.controls.ErrorCode.Text.Contains('INSTALL_EXTENSION_NOT_CONFIRMED')) 'Extension was silently assumed installed'
        $first.controls.ExtensionConfirmed.IsChecked=$true;Click $first.controls.Next
        Assert-True ($first.step -eq 3 -and $first.controls.NativeProgress.Text.Contains('아직 확인하지 않음')) 'Registration was assumed'
        Click $first.controls.Next
        Assert-True ($first.step -eq 4 -and $first.result.authentication -eq 'NOT_TESTED') 'Skip was reported as authenticated'
        Assert-True ($first.controls.LaunchPath.Text -eq (Join-Path $first.result.desktop 'Start.bat')) 'Wrong launch path'
    }
    Check 'Chrome-only installs no Desktop and skips registration/pairing' {
        $script:chrome=New-Wizard
        $chrome.controls.UpdateMode.IsChecked=$true;$chrome.controls.MigrationConsent.IsChecked=$true
        $chrome.controls.ChromeMode.IsChecked=$true
        Assert-True (-not $chrome.controls.UpdateMode.IsChecked -and -not $chrome.controls.MigrationConsent.IsChecked -and -not $chrome.controls.UpdateMode.IsEnabled) 'Migration consent leaked into Chrome-only'
        $chrome.controls.SourceConsent.IsChecked=$true;$chrome.controls.ExpectedHash.Text=$hash
        $lease=(Get-Command Enter-InstallDesktopLease).ScriptBlock
        try{Set-Item Function:Enter-InstallDesktopLease -Value {throw 'Chrome-only must not touch Desktop mutex'};Click $chrome.controls.Next}
        finally{Set-Item Function:Enter-InstallDesktopLease -Value $lease}
        Assert-True ($chrome.step -eq 2 -and -not $chrome.result.desktop) ('Chrome-only failed: '+$chrome.controls.ErrorCode.Text)
        Assert-True (-not [IO.Directory]::Exists((Join-Path $chrome.result.directory 'Desktop_Companion')) -and -not [IO.Directory]::Exists((Join-Path $chrome.result.directory 'Installer'))) 'Desktop was installed'
        Assert-AmbientInstallSecurity $chrome.result.extension
        Assert-AmbientInstallerCompleted $chrome.result.directory
        $chrome.controls.ExtensionConfirmed.IsChecked=$true;Click $chrome.controls.Next
        Assert-True ($chrome.step -eq 4 -and $chrome.controls.LaunchPath.Text -eq $chrome.result.extension) 'Chrome-only did not bypass Native step'
    }
    Check 'update approval before old-file reads and preserves synthetic bytes' {
        $old=Join-Path $lab 'old';$oldDesktop=Join-Path $old 'Desktop_Companion';[void][IO.Directory]::CreateDirectory($oldDesktop)
        [IO.File]::Copy((Join-Path $root 'Desktop_Companion/settings.defaults.json'),(Join-Path $oldDesktop 'settings.json'))
        [IO.File]::WriteAllText((Join-Path $oldDesktop 'bridge-pairing.txt'),('e'*64))
        $keyHash=(Get-FileHash (Join-Path $oldDesktop 'bridge-pairing.txt')).Hash
        $upgrade=New-Wizard;$upgrade.controls.SourceConsent.IsChecked=$true;$upgrade.controls.ExpectedHash.Text=$hash
        $upgrade.controls.UpdateMode.IsChecked=$true;$upgrade.controls.OldPath.Text=$old
        $held=[IO.File]::Open((Join-Path $oldDesktop 'bridge-pairing.txt'),'Open','Read','None')
        try{Click $upgrade.controls.Next;Assert-True ($upgrade.controls.ErrorCode.Text.Contains('INSTALL_MIGRATION_APPROVAL_REQUIRED')) 'Read before migration consent'}finally{$held.Dispose()}
        $upgrade.controls.MigrationConsent.IsChecked=$true;Click $upgrade.controls.Next
        Assert-True ($upgrade.step -eq 2 -and $upgrade.result.migrated) ('Update failed: '+$upgrade.controls.ErrorCode.Text)
        Assert-True ((Get-FileHash (Join-Path $upgrade.result.desktop 'bridge-pairing.txt')).Hash -ceq $keyHash) 'Key bytes not preserved'
        Assert-True ((Get-FileHash (Join-Path $oldDesktop 'bridge-pairing.txt')).Hash -ceq $keyHash) 'Old key changed'
    }
    Check 'cancel before install writes nothing; after install retains valid files' {
        $cancel=New-Wizard;$cancel.controls.Destination.Text=Join-Path $lab 'never-created';Click $cancel.controls.Cancel
        Assert-True ($cancel.cancelled -and -not [IO.Directory]::Exists($cancel.controls.Destination.Text)) 'Cancel created files'
        Click $chrome.controls.Cancel
        Assert-True ($chrome.cancelled -and [IO.File]::Exists((Join-Path $chrome.result.directory 'INSTALL-COMPLETE.json'))) 'Cancel destroyed completed install'
    }
    Check 'Native setup fills only validated public identity without registration' {
        foreach($name in @('Native-Mailbox.ps1','Native-Registration.ps1','Native-Profiles.ps1','Native-Setup.ps1')){. (Join-Path $first.result.desktop $name)}
        $native=Show-AmbientNativeSetup $first.result.desktop -PassThru
        $windows.Add($native.window)
        Assert-True ($native.controls.ExtensionIdText.Text -ceq $script:InstallerId) 'Public identity missing'
        Assert-True (-not [IO.File]::Exists((Join-Path $first.result.desktop 'native-host.json'))) 'Inspecting UI wrote host'
    }
    if($RenderPreviews) {
        # Render the actual WPF tree using synthetic public paths; no desktop screenshot.
        $previewRoot=Join-Path $root 'artifacts/onboarding-previews';[void][IO.Directory]::CreateDirectory($previewRoot)
        $preview=New-Wizard
        $preview.controls.ZipPath.Text='C:\Users\Example\Downloads\AmbientWorkspace-rc2-review.zip'
        $preview.controls.Destination.Text='C:\Users\Example\AppData\Local\AmbientWorkspace'
        $preview.controls.ExpectedHash.Text=''
        $preview.controls.ExtensionPath.Text='C:\Users\Example\AppData\Local\AmbientWorkspace\rc2-review\Browser_Extension'
        $preview.controls.InstalledPath.Text='C:\Users\Example\AppData\Local\AmbientWorkspace\rc2-review'
        $preview.controls.LaunchPath.Text='C:\Users\Example\AppData\Local\AmbientWorkspace\rc2-review\Desktop_Companion\Start.bat'
        $preview.controls.CompletionText.Text='파일 설치 완료 · 실제 연결은 Chrome 팝업에서 직접 확인하세요.'
        $surface=[Windows.Controls.Border]::new()
        $surface.Background=[Windows.Media.BrushConverter]::new().ConvertFromString('#101724')
        $surface.Resources=$preview.window.Resources
        $surface.SetValue([Windows.Controls.Control]::ForegroundProperty,$preview.window.Foreground)
        $surface.SetValue([Windows.Controls.Control]::FontFamilyProperty,$preview.window.FontFamily)
        $surface.SetValue([Windows.Controls.Control]::FontSizeProperty,$preview.window.FontSize)
        $content=$preview.window.Content;$preview.window.Content=$null;$surface.Child=$content
        foreach($i in 1..4) {
            foreach($p in 1..4){$preview.controls['Page'+$p].Visibility=if($p -eq $i){'Visible'}else{'Collapsed'}}
            $preview.controls.Heading.Text=@('','설치 시작','Chrome 확장 설치','Windows 연결','설치 완료')[$i]
            $preview.controls.Next.Content=@('','확인 후 설치','다음','나중에 연결 · 마치기','닫기')[$i]
            $surface.Measure([Windows.Size]::new(800,800));$surface.Arrange([Windows.Rect]::new(0,0,800,800));$surface.UpdateLayout()
            $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new(800,800,96,96,[Windows.Media.PixelFormats]::Pbgra32)
            $bitmap.Render($surface)
            $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
            $stream=[IO.File]::Create((Join-Path $previewRoot ('setup-'+$i+'.png')))
            try{$encoder.Save($stream)}finally{$stream.Dispose()}
        }
        Write-Output ('Synthetic WPF previews: '+$previewRoot)
    }
} finally {foreach($window in $windows){$window.Close()}}
@{count=$cases.Count;cases=$cases.ToArray();syntheticOnly=$true;actualChrome='NOT_TESTED';actualDownloadedZip='NOT_TESTED'}|ConvertTo-Json -Depth 4|Set-Content (Join-Path $lab 'summary.json') -Encoding UTF8
Write-Output ('Wizard '+$cases.Count+'/'+$cases.Count+' PASS; fixtures: '+$lab)
