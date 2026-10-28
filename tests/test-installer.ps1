# Synthetic files and newly-owned NTFS fixtures only; never reads operational settings.
param([Parameter(Mandatory=$true)][string]$FixtureParent)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
if($PSVersionTable.PSEdition -ne 'Desktop'){throw 'Use Windows PowerShell 5.1'}
$lab=Join-Path ([IO.Path]::GetFullPath($FixtureParent)) ('installer-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($lab)
$helper=Join-Path $lab 'Install-AmbientWorkspace.ps1'
[IO.File]::Copy((Join-Path $root 'Installer/Install-AmbientWorkspace.ps1'),$helper,$false)
. $helper
$review=Join-Path $lab 'review.zip'
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root 'tools/New-InstallPackage.ps1') -OutputPath $review
if($LASTEXITCODE -ne 0){throw 'Review package build failed'}
$hash=(Get-FileHash -LiteralPath $review -Algorithm SHA256).Hash
$package=Open-AmbientInstallPackage $review $hash
Initialize-InstallPolicy $package
Test-AmbientPathAcl $lab 'Private';Assert-InstallAncestors $lab
$cases=[Collections.Generic.List[string]]::new()
function Assert-True($Value,[string]$Message){if(-not $Value){throw $Message}}
function Check([string]$Name,[scriptblock]$Action){& $Action;$cases.Add($Name);Write-Output ('PASS '+$Name)}
function Reject([scriptblock]$Action,[string]$Code='') {
    $caught=$false
    try{& $Action|Out-Null}catch{$caught=$true;if($Code){Assert-True ((Get-InstallErrorCode $_) -eq $Code) ('Expected '+$Code+' got '+(Get-InstallErrorCode $_))}}
    Assert-True $caught ('Expected refusal '+$Code)
}
function New-LabFolder([string]$Name){$path=Join-Path $lab $Name;[void][IO.Directory]::CreateDirectory($path);return $path}
function Grant-LabAccess([string]$Path){
    Assert-True ($Path.StartsWith($lab+'\',[StringComparison]::OrdinalIgnoreCase)) 'ACL fixture escaped owned lab'
    $acl=[IO.Directory]::GetAccessControl($Path)
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-11'),'Modify','ContainerInherit,ObjectInherit','None','Allow'))
    [IO.Directory]::SetAccessControl($Path,$acl)
}
# Keep the real mutex implementation but isolate its name from any user's Desktop.
$mutexName='Local\AmbientWorkspace.InstallLab.'+[Guid]::NewGuid().ToString('N')
$leaseCode=(Get-Command Enter-InstallDesktopLease).ScriptBlock.ToString().Replace('Local\AmbientWorkspace.Desktop',$mutexName)
Set-Item Function:Enter-InstallDesktopLease -Value ([ScriptBlock]::Create($leaseCode))
$destination=Join-Path $lab 'app'
$first=$null;$upgraded=$null
$old=New-LabFolder 'old';$oldDesktop=Join-Path $old 'Desktop_Companion';[void][IO.Directory]::CreateDirectory($oldDesktop)
$settings=[IO.File]::ReadAllBytes((Join-Path $root 'Desktop_Companion/settings.defaults.json'))
[IO.File]::WriteAllBytes((Join-Path $oldDesktop 'settings.json'),$settings)
[IO.File]::WriteAllText((Join-Path $oldDesktop 'settings.json.bak'),'SYNTHETIC_BACKUP_BYTES')
[IO.File]::WriteAllText((Join-Path $oldDesktop 'bridge-pairing.txt'),('a'*64))
$oldHashes=@{};foreach($name in @('settings.json','settings.json.bak','bridge-pairing.txt')){$oldHashes[$name]=(Get-FileHash (Join-Path $oldDesktop $name)).Hash}
function Assert-OldPreserved {foreach($name in $oldHashes.Keys){Assert-True ((Get-FileHash (Join-Path $oldDesktop $name)).Hash -ceq $oldHashes[$name]) 'Original synthetic personal file changed'}}
Check 'official-source and migration approvals precede any old-data reads' {
    Reject {Install-AmbientWorkspace $review $hash $destination} 'INSTALL_SOURCE_APPROVAL_REQUIRED'
    $held=[IO.File]::Open((Join-Path $oldDesktop 'bridge-pairing.txt'),'Open','Read','None')
    try{Reject {Install-AmbientWorkspace $review $hash $destination -SourceVerified -ExistingInstall $old} 'INSTALL_MIGRATION_APPROVAL_REQUIRED'}finally{$held.Dispose()}
    Assert-OldPreserved
}
Check 'new personal NTFS install, ACL PASS, no old install, no invented pairing key' {
    $script:first=Install-AmbientWorkspace $review $hash $destination -SourceVerified
    Assert-AmbientInstallSecurity $first.desktop
    Assert-True ([IO.File]::Exists((Join-Path $first.directory 'INSTALL-COMPLETE.json'))) 'Completion marker missing'
    Assert-True (-not [IO.File]::Exists((Join-Path $first.desktop 'settings.json')) -and -not [IO.File]::Exists((Join-Path $first.desktop 'bridge-pairing.txt'))) 'Installer initialized settings or pairing'
    Assert-InstallIdentity $package.files
}
Check 'existing folder ACL cannot be replaced and old installation cannot be a destination' {
    $sddl=[IO.Directory]::GetAccessControl($old).Sddl
    Reject {New-InstallPrivateDirectory $old} 'INSTALL_FOLDER_EXISTS'
    $descriptor=[IO.Directory]::GetAccessControl($lab).GetSecurityDescriptorBinaryForm()
    Assert-True ([AmbientInstallDirectory]::Create($old,$descriptor) -eq 183) 'Atomic create reused an existing directory'
    Assert-True ([IO.Directory]::GetAccessControl($old).Sddl -ceq $sddl) 'Existing folder ACL was replaced'
    Reject {Install-AmbientWorkspace $review $hash $old -SourceVerified} 'INSTALL_DESTINATION_EXISTING_PRODUCT'
    Reject {Install-AmbientWorkspace $review $hash (Join-Path $old 'nested') -SourceVerified -ExistingInstall $old -ApproveMigration} 'INSTALL_DESTINATION_OVERLAP'
}
Check 'existing private root upgrade preserves original, copied settings/backup/key and Orca' {
    $script:upgraded=Install-AmbientWorkspace $review $hash $destination -SourceVerified -ExistingInstall $old -ApproveMigration
    Assert-OldPreserved
    foreach($name in $oldHashes.Keys){Assert-True ((Get-FileHash (Join-Path $upgraded.desktop $name)).Hash -ceq $oldHashes[$name]) 'Copied synthetic data hash mismatch'}
    $saved=Get-Content (Join-Path $upgraded.desktop 'settings.json') -Raw -Encoding UTF8|ConvertFrom-Json
    Assert-True ($saved.targets -contains 'orca' -and $saved.appMultipliers.orca -eq 1.0) 'Orca lost'
}
Check 'inherited unsafe source ZIP allowed only as authenticated immutable data; helper there is refused' {
    $unsafe=New-LabFolder 'unsafe';Grant-LabAccess $unsafe
    $unsafeZip=Join-Path $unsafe 'review.zip';[IO.File]::Copy($review,$unsafeZip,$false)
    $unsafeHelper=Join-Path $unsafe 'helper.ps1';[IO.File]::Copy($helper,$unsafeHelper,$false)
    Reject {Test-AmbientPathAcl $unsafe 'Private'} 'INSTALL_ACL_DATA_ACL'
    $savedHelper=$script:InstallerScriptPath
    try{$script:InstallerScriptPath=$unsafeHelper;Reject {Install-AmbientWorkspace $unsafeZip $hash $destination -SourceVerified} 'INSTALL_HELPER_LOCATION'}finally{$script:InstallerScriptPath=$savedHelper}
    $installed=Install-AmbientWorkspace $unsafeZip $hash $destination -SourceVerified
    Assert-AmbientInstallSecurity $installed.desktop
    $sddl=[IO.Directory]::GetAccessControl($unsafe).Sddl
    Reject {Install-AmbientWorkspace $review $hash $unsafe -SourceVerified} 'INSTALL_ACL_DATA_ACL'
    Assert-True ([IO.Directory]::GetAccessControl($unsafe).Sddl -ceq $sddl) 'Existing unsafe ACL was changed'
}
Check 'ZIP hash mismatch, active source writer and unlisted archive path are refused' {
    Reject {Open-AmbientInstallPackage $review ('0'*64)} 'INSTALL_ZIP_HASH'
    $held=[IO.File]::Open($review,'Open','ReadWrite','ReadWrite')
    try{Reject {Open-AmbientInstallPackage $review $hash}}finally{$held.Dispose()}
    $bad=Join-Path $lab 'traversal.zip';$fs=[IO.File]::Create($bad);$zip=[IO.Compression.ZipArchive]::new($fs,[IO.Compression.ZipArchiveMode]::Create)
    try{foreach($name in @('../outside.ps1','INSTALL-MANIFEST.json')){$e=$zip.CreateEntry($name);$s=$e.Open();try{$s.WriteByte(1)}finally{$s.Dispose()}}}finally{$zip.Dispose();$fs.Dispose()}
    Reject {Open-AmbientInstallPackage $bad (Get-FileHash $bad).Hash} 'INSTALL_ARCHIVE_PATH'
}
function New-TamperedPackage([string]$Name,[string]$EntryName,[byte[]]$Replacement,[switch]$RehashManifest) {
    $files=@{};foreach($key in $package.files.Keys){$files[$key]=$package.files[$key]};$files[$EntryName]=$Replacement
    if($RehashManifest){$m=[Text.Encoding]::UTF8.GetString($files['INSTALL-MANIFEST.json'])|ConvertFrom-Json;foreach($item in $m.files){if($item.path -ceq $EntryName){$item.sha256=Get-InstallHash $Replacement;$item.bytes=$Replacement.Length}};$files['INSTALL-MANIFEST.json']=[Text.Encoding]::UTF8.GetBytes(($m|ConvertTo-Json -Depth 6))}
    $path=Join-Path $lab $Name;$fs=[IO.File]::Create($path);$zip=[IO.Compression.ZipArchive]::new($fs,[IO.Compression.ZipArchiveMode]::Create)
    try{foreach($key in $files.Keys){$entry=$zip.CreateEntry($key);$stream=$entry.Open();try{$bytes=$files[$key];$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}}}finally{$zip.Dispose();$fs.Dispose()}
    return $path
}
Check 'file-manifest mismatch and changed Chrome fixed identity are refused' {
    $bad=New-TamperedPackage 'tamper.zip' 'README.md' ([Text.Encoding]::UTF8.GetBytes('tampered'))
    Reject {Open-AmbientInstallPackage $bad (Get-FileHash $bad).Hash} 'INSTALL_FILE_HASH'
    $manifest=[Text.Encoding]::UTF8.GetString($package.files['Browser_Extension/manifest.json'])|ConvertFrom-Json;$manifest.key='INVALID_KEY'
    $bad=New-TamperedPackage 'identity.zip' 'Browser_Extension/manifest.json' ([Text.Encoding]::UTF8.GetBytes(($manifest|ConvertTo-Json -Depth 12))) -RehashManifest
    Reject {Open-AmbientInstallPackage $bad (Get-FileHash $bad).Hash} 'INSTALL_EXTENSION_ID'
}
Check 'internally rehashed product allowlist cannot omit archive entries' {
    $bad=New-TamperedPackage 'allowlist.zip' 'Installer/product-files.json' ([Text.Encoding]::UTF8.GetBytes('["README.md"]')) -RehashManifest
    Reject {Open-AmbientInstallPackage $bad (Get-FileHash $bad).Hash} 'INSTALL_PRODUCT_ALLOWLIST'
    foreach($name in @('Desktop_Companion/settings.json','Desktop_Companion/bridge-pairing.txt','Browser_Extension/source/../../outside.js','docs/images/../private.png','docs/images/unknown.exe')) {
        Assert-True (-not (Test-InstallRelativePath $name)) ('Private or traversal entry accepted: '+$name)
    }
}
$originalWrite=(Get-Command Write-InstallFile).ScriptBlock
$originalFree=(Get-Command Get-InstallFreeBytes).ScriptBlock
Check 'disk-full preflight, copy failure and interruption preserve old files and leave no completed install' {
    try{Set-Item Function:Get-InstallFreeBytes -Value {param($Path) return 0L};Reject {Install-AmbientWorkspace $review $hash $destination -SourceVerified -ExistingInstall $old -ApproveMigration} 'INSTALL_DISK_FULL'}finally{Set-Item Function:Get-InstallFreeBytes -Value $originalFree}
    foreach($failure in @('copy','cancel')) {
        $script:injectedFailure=$failure
        try {
            Set-Item Function:Write-InstallFile -Value {param($Path,$Bytes) if([IO.Path]::GetFileName($Path) -eq 'Overlay.xaml'){if($injectedFailure -eq 'cancel'){throw [OperationCanceledException]::new('synthetic')}else{throw [IO.IOException]::new('synthetic')}};& $originalWrite $Path $Bytes}
            Reject {Install-AmbientWorkspace $review $hash $destination -SourceVerified -ExistingInstall $old -ApproveMigration}
        } finally {Set-Item Function:Write-InstallFile -Value $originalWrite}
        Assert-OldPreserved
    }
    foreach($folder in [IO.Directory]::GetDirectories($destination,'.pending-*')){Assert-True (-not [IO.File]::Exists((Join-Path $folder 'INSTALL-COMPLETE.json'))) 'A failed attempt was marked complete'}
}
Check 'post-copy mutation is detected and approved old files stay locked during copy' {
    try {
        Set-Item Function:Write-InstallFile -Value {param($Path,$Bytes) & $originalWrite $Path $Bytes;if([IO.Path]::GetFileName($Path) -eq 'Overlay.xaml'){[IO.File]::WriteAllText($Path,'SYNTHETIC_CORRUPTION')}}
        Reject {Install-AmbientWorkspace $review $hash $destination -SourceVerified -ExistingInstall $old -ApproveMigration} 'INSTALL_COPIED_HASH'
    } finally {Set-Item Function:Write-InstallFile -Value $originalWrite}
    $script:lockProbed=$false
    try {
        Set-Item Function:Write-InstallFile -Value {param($Path,$Bytes) if(-not $lockProbed){$script:lockProbed=$true;Reject {$s=[IO.File]::Open((Join-Path $oldDesktop 'bridge-pairing.txt'),'Open','Write','ReadWrite');$s.Dispose()}};& $originalWrite $Path $Bytes}
        $null=Install-AmbientWorkspace $review $hash $destination -SourceVerified -ExistingInstall $old -ApproveMigration
    } finally {Set-Item Function:Write-InstallFile -Value $originalWrite}
    Assert-True $lockProbed 'Old-file lock was not exercised';Assert-OldPreserved
}
Check 'running Desktop mutex requests exit without forcing any process' {
    $ready=Join-Path $lab 'mutex-ready';$release=Join-Path $lab 'mutex-release'
    $code='$m=[Threading.Mutex]::new($true,'''+$mutexName+''');[IO.File]::WriteAllText('''+$ready+''',''ready'');try{$end=[DateTime]::UtcNow.AddSeconds(15);while(-not [IO.File]::Exists('''+$release+''') -and [DateTime]::UtcNow -lt $end){Start-Sleep -Milliseconds 100}}finally{$m.ReleaseMutex();$m.Dispose()}'
    $process=Start-Process (Join-Path $PSHOME 'powershell.exe') -ArgumentList @('-NoProfile','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))) -WindowStyle Hidden -PassThru
    try{$end=[DateTime]::UtcNow.AddSeconds(5);while(-not [IO.File]::Exists($ready) -and [DateTime]::UtcNow -lt $end){Start-Sleep -Milliseconds 50};Assert-True ([IO.File]::Exists($ready)) 'Mutex fixture did not start';Reject {Install-AmbientWorkspace $review $hash $destination -SourceVerified} 'INSTALL_DESKTOP_RUNNING'}finally{[IO.File]::WriteAllText($release,'release');$null=$process.WaitForExit(5000);$process.Dispose()}
}
Check 'Native registration and key-read operations require separate approvals' {
    Reject {Open-AmbientInstallerNativeSetup 'not-read-before-consent'} 'INSTALL_NATIVE_APPROVAL_REQUIRED'
    Reject {Test-AmbientInstallerAuthentication 'not-read-before-consent'} 'INSTALL_AUTH_APPROVAL_REQUIRED'
    Assert-OldPreserved
}
$nativeHost='org.ambientworkspace.lab_'+[Guid]::NewGuid().ToString('N')
$originalNativeState=(Get-Command Get-AmbientInstallerNativeState).ScriptBlock
Set-Item Function:Get-AmbientInstallerNativeState -Value ([ScriptBlock]::Create($originalNativeState.ToString().Replace('org.ambientworkspace.bridge',$nativeHost)))
$nativeDesktop=$upgraded.desktop;$channel=$null;$mailWorker=$null;$mailJob=$null;$shared=[hashtable]::Synchronized(@{stop=$false;ready=$false})
try {
    foreach($name in @('File-Security.ps1','Native-Mailbox.ps1','Native-Registration.ps1','Native-Framing.ps1','Control-Channel.ps1','Control-State.ps1')){. (Join-Path $nativeDesktop $name)}
    Check 'new helper reports absent/conflicting/registered Native paths in an isolated HKCU namespace' {
        Assert-True ((Get-AmbientInstallerNativeState $nativeDesktop).status -eq 'installRequired') 'Absent lab registration mislabeled'
        $null=Invoke-AmbientNativeRegistration $nativeDesktop 'Install' @($script:InstallerId) $nativeHost
        Assert-True ((Get-AmbientInstallerNativeState $nativeDesktop).status -eq 'registered') 'Lab registration not observed'
        Assert-True ((Get-AmbientInstallerNativeState $first.desktop).status -eq 'reregisterRequired') 'Conflicting location mislabeled'
        Reject {Invoke-AmbientNativeRegistration $first.desktop 'Install' @($script:InstallerId) $nativeHost} 'NATIVE_REGISTRATION_CONFLICT'
    }
    Check 'matching registry path with a wrong Host binary target still requires repair' {
        $path=Join-Path $nativeDesktop 'native-host.json';$before=[IO.File]::ReadAllBytes($path)
        try {
            $record=[Text.Encoding]::UTF8.GetString($before)|ConvertFrom-Json;$record.path=Join-Path $first.desktop 'AmbientNativeHost.exe'
            [IO.File]::WriteAllText($path,($record|ConvertTo-Json -Compress))
            Assert-True ((Get-AmbientInstallerNativeState $nativeDesktop).status -eq 'reregisterRequired') 'Wrong executable target was reported as registered'
        } finally {[IO.File]::WriteAllBytes($path,$before)}
    }
    Check 'real Host/key/private-mailbox/control-state authentication succeeds without a Chrome profile lease' {
        $control=New-AmbientLocalControl (Get-Content (Join-Path $nativeDesktop 'settings.json') -Raw -Encoding UTF8|ConvertFrom-Json) (Join-Path $nativeDesktop 'settings.json')
        $script:channel=Start-AmbientControlChannel $nativeDesktop $control
        $script:mailWorker=[PowerShell]::Create()
        [void]$mailWorker.AddScript({
            param($Directory,$Shared)
            $ErrorActionPreference='Stop';Set-StrictMode -Version Latest
            foreach($name in @('File-Security.ps1','Native-Mailbox.ps1','Control-Channel.ps1')){. (Join-Path $Directory $name)}
            $paths=Initialize-AmbientNativeMailbox $Directory;$endpoint=New-AmbientNativeEndpoint $paths
            $Shared.ready=$true
            while(-not $Shared.stop) {
                $job=Receive-AmbientNativeMailbox $paths $endpoint
                if($null -ne $job){$reply=Invoke-AmbientBridgeControl $job.packet $Directory $job.origin;Complete-AmbientNativeMailbox $paths $endpoint $job $reply}
                Start-Sleep -Milliseconds 30
            }
        }).AddArgument($nativeDesktop).AddArgument($shared)
        $script:mailJob=$mailWorker.BeginInvoke()
        $end=[DateTime]::UtcNow.AddSeconds(5);while(-not $shared.ready -and [DateTime]::UtcNow -lt $end){Start-Sleep -Milliseconds 30}
        Assert-True $shared.ready 'Isolated mailbox worker failed to start'
        $auth=Test-AmbientInstallerAuthentication $nativeDesktop -ApproveKeyRead
        Assert-True ($auth.hostAuthentication -eq 'authenticated' -and $auth.chromeProfile -eq 'NOT_TESTED') 'Host proof mislabeled as Chrome proof'
        Assert-True (-not [IO.File]::Exists((Join-Path $nativeDesktop 'control-lease.json'))) 'Probe created a Chrome profile lease'
        # Exercise the new report value behind the same existing origin/profile lease.
        $testOrigin='chrome-extension://'+$script:InstallerId
        $hello=Invoke-AmbientBridgeControl ([pscustomobject]@{type='control.hello';profileId=('c'*32)}) $nativeDesktop $testOrigin
        Assert-True ($hello.ok -and $hello.capabilities -ccontains 'independent-chrome-pause') 'Independent Chrome capability missing'
        $report=[pscustomobject]@{type='control.applied';profileId=('c'*32);leaseId=$hello.lease.leaseId;instanceId=$hello.state.instanceId;revision=$hello.state.revision;globalPaused=$hello.state.globalPaused;parts=[pscustomobject]@{desktop='applied';web='independent';youtube='notRequired';capture='notRequired'}}
        Assert-True (Invoke-AmbientBridgeControl $report $nativeDesktop $testOrigin).ok 'Independent Chrome report rejected'
        $report.parts.desktop='independent'
        Assert-True ((Invoke-AmbientBridgeControl $report $nativeDesktop $testOrigin).status -eq 'invalid') 'Desktop must never bypass its applied check with independent'
        $report.parts.desktop='applied';$report.leaseId='d'*32
        Assert-True ((Invoke-AmbientBridgeControl $report $nativeDesktop $testOrigin).status -eq 'leaseConflict') 'Independent reports bypassed profile lease authentication'
        [IO.File]::Delete((Join-Path $nativeDesktop 'control-lease.json'))
        Assert-OldPreserved
    }
    Check 'wrong synthetic token is rejected by the real Host without changing keys' {
        $keyPath=Join-Path $nativeDesktop 'bridge-pairing.txt';$keyHash=(Get-FileHash $keyPath).Hash
        $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=Join-Path $nativeDesktop 'AmbientNativeHost.exe';$info.Arguments='chrome-extension://'+$script:InstallerId+'/'
        $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        $probe=[Diagnostics.Process]::Start($info)
        try {
            $null=$probe.StandardError.ReadToEndAsync()
            Write-AmbientNativeFrame $probe.StandardInput.BaseStream @{id=[Guid]::NewGuid().ToString('N');packet=@{type='control.hello';token=('b'*64)}}
            $deadline=[DateTime]::UtcNow.AddSeconds(5);$header=Read-InstallPipeBytes $probe.StandardOutput.BaseStream 4 $deadline;$length=[BitConverter]::ToUInt32($header,0)
            Assert-True ($length -gt 0 -and $length -lt 524288) 'Invalid test reply length'
            $reply=[Text.Encoding]::UTF8.GetString((Read-InstallPipeBytes $probe.StandardOutput.BaseStream ([int]$length) $deadline))|ConvertFrom-Json
            Assert-True ($reply.transport -ceq 'pairingRejected') 'Wrong synthetic token was accepted'
        } finally {$probe.StandardInput.Close();$null=$probe.WaitForExit(2000);$probe.Dispose()}
        Assert-True ((Get-FileHash $keyPath).Hash -ceq $keyHash) 'Host changed the key';Assert-OldPreserved
    }
    Check 'offline Desktop is never reported as authenticated and keys/code remain unchanged' {
        $keyPath=Join-Path $nativeDesktop 'bridge-pairing.txt';$keyBytes=[IO.File]::ReadAllBytes($keyPath)
        $framing=Join-Path $nativeDesktop 'Native-Framing.ps1'
        $framingBytes=[IO.File]::ReadAllBytes($framing)
        $shared.stop=$true;$null=$mailWorker.EndInvoke($mailJob);$mailWorker.Dispose();$script:mailWorker=$null
        Stop-AmbientControlChannel $channel $nativeDesktop;$script:channel=$null
        Reject {Test-AmbientInstallerAuthentication $nativeDesktop -ApproveKeyRead}
        Assert-True ((Get-InstallHash ([IO.File]::ReadAllBytes($keyPath))) -ceq (Get-InstallHash $keyBytes) -and (Get-InstallHash ([IO.File]::ReadAllBytes($framing))) -ceq (Get-InstallHash $framingBytes)) 'Authentication failure changed key or code'
        Assert-OldPreserved
    }
    Check 'moving only the owned test install requires explicit Native relocation repair' {
        $moved=Join-Path $destination ('moved-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
        Assert-True ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($upgraded.directory)) -eq $destination -and [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($moved)) -eq $destination) 'Unsafe test move target'
        [IO.Directory]::Move($upgraded.directory,$moved);$script:nativeDesktop=Join-Path $moved 'Desktop_Companion'
        Assert-True ((Get-AmbientInstallerNativeState $nativeDesktop).status -eq 'reregisterRequired') 'Moved install was implicitly registered'
        $null=Invoke-AmbientNativeRegistration $nativeDesktop 'Repair' @($script:InstallerId) $nativeHost
        Assert-True ((Get-AmbientInstallerNativeState $nativeDesktop).status -eq 'registered') 'Explicit lab relocation failed'
        Assert-OldPreserved
    }
} finally {
    $shared.stop=$true
    if($mailWorker){$null=$mailWorker.EndInvoke($mailJob);$mailWorker.Dispose()}
    if($channel){Stop-AmbientControlChannel $channel $nativeDesktop}
    if(@(Get-AmbientNativeRegistryState $nativeHost|Where-Object exists).Count){$null=Invoke-AmbientNativeRegistration $nativeDesktop 'Remove' @() $nativeHost}
    Set-Item Function:Get-AmbientInstallerNativeState -Value $originalNativeState
}
@{cases=$cases.ToArray();count=$cases.Count;syntheticOnly=$true;actualDiskExhaustion=$false;realChromeAuthentication='NOT_TESTED';nativeRegistryNamespace=$nativeHost}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $lab 'summary.json') -Encoding UTF8
Write-Output ('Installer '+$cases.Count+'/'+$cases.Count+' PASS; fixtures: '+$lab)
