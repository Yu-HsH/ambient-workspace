# Copies only a closed extension-local DB into a NEW private helper profile.
# No original Chrome preferences, cookies, history, program files or key files are changed.
function Get-AmbientChromeDatabaseSnapshot([string]$Directory) {
    Assert-AmbientInstallSecurity $Directory
    if(@([IO.Directory]::GetDirectories($Directory)).Count){throw 'NATIVE_PROFILE_DATABASE_LAYOUT'}
    $files=@([IO.Directory]::GetFiles($Directory));if($files.Count -lt 1 -or $files.Count -gt 1024){throw 'NATIVE_PROFILE_DATABASE_LAYOUT'}
    $total=[long]0;$entries=@()
    foreach($path in $files) {
        $name=[IO.Path]::GetFileName($path)
        if($name -cnotmatch '^(?:CURRENT|LOCK|LOG(?:\.old)?|MANIFEST-[0-9]+|OPTIONS-[0-9]+|[0-9]+\.(?:log|ldb|sst))$'){throw 'NATIVE_PROFILE_DATABASE_LAYOUT'}
        $info=[IO.FileInfo]::new($path);$total+=$info.Length
        if($total -gt 67108864){throw 'NATIVE_PROFILE_DATABASE_TOO_LARGE'}
        $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $hash=[Security.Cryptography.SHA256]::Create()
        try{$digest=([BitConverter]::ToString($hash.ComputeHash($stream))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose();$stream.Dispose()}
        $entries+=@{name=$name;bytes=$info.Length;sha256=$digest}
    }
    if(-not [IO.File]::Exists((Join-Path $Directory 'CURRENT')) -or [IO.File]::ReadAllText((Join-Path $Directory 'CURRENT')).Trim() -cnotmatch '^MANIFEST-[0-9]+$'){throw 'NATIVE_PROFILE_DATABASE_LAYOUT'}
    return @{entries=@($entries|Sort-Object name);totalBytes=$total}
}
function New-AmbientPrivateMigrationWorkspace([string]$ProductDirectory) {
    Assert-AmbientInstallSecurity $ProductDirectory
    $parent=[IO.Directory]::GetParent([IO.Path]::GetFullPath($ProductDirectory)).FullName
    $workspace=Join-Path $parent ('migration-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
    $security=[Security.AccessControl.DirectorySecurity]::new();$security.SetAccessRuleProtection($true,$false)
    $current=[Security.Principal.WindowsIdentity]::GetCurrent().User;$security.SetOwner($current)
    foreach($sid in @($current,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'),[Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))){$security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
    # Apply the private descriptor at atomic creation, never SetAccessControl on
    # a possibly pre-existing path. A collision is a failure, including races.
    if(-not ('AmbientMigrationDirectory' -as [type])){
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class AmbientMigrationDirectory {
    [StructLayout(LayoutKind.Sequential)] struct Attributes {
        public int length; public IntPtr descriptor; [MarshalAs(UnmanagedType.Bool)] public bool inherit;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    [return:MarshalAs(UnmanagedType.Bool)] static extern bool CreateDirectoryW(string path, ref Attributes attributes);
    public static void Create(string path, byte[] descriptor) {
        GCHandle pinned=GCHandle.Alloc(descriptor,GCHandleType.Pinned);
        try {
            Attributes attributes=new Attributes { length=Marshal.SizeOf(typeof(Attributes)), descriptor=pinned.AddrOfPinnedObject(), inherit=false };
            if(!CreateDirectoryW(path,ref attributes))throw new Win32Exception(Marshal.GetLastWin32Error(),"NATIVE_MIGRATION_DIRECTORY_CREATE_FAILED");
        } finally { pinned.Free(); }
    }
}
'@
    }
    [AmbientMigrationDirectory]::Create($workspace,$security.GetSecurityDescriptorBinaryForm())
    Test-AmbientPathAcl $workspace 'Private'
    return $workspace
}
function Prepare-AmbientChromeProfileMigration([string]$ProductDirectory,[string]$SourceProfileDirectory,[string]$OldExtensionId) {
    Assert-AmbientInstallSecurity $ProductDirectory
    if($OldExtensionId -cnotmatch '^[a-p]{32}$'){throw 'NATIVE_EXTENSION_IDS_INVALID'}
    $database=Join-Path ([IO.Path]::GetFullPath($SourceProfileDirectory)) ('Local Extension Settings/'+$OldExtensionId)
    Assert-AmbientInstallSecurity $database
    # Probe only this DB, not unrelated browsers/accounts. No writer/lock is held
    # during copying, and the original bytes are never modified by this tool.
    $lock=Join-Path $database 'LOCK'
    if([IO.File]::Exists($lock)){
        $probe=$null;try{$probe=[IO.File]::Open($lock,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)}
        catch{throw 'NATIVE_CHROME_MUST_BE_CLOSED'}finally{if($null -ne $probe){$probe.Dispose()}}
    }
    $before=Get-AmbientChromeDatabaseSnapshot $database
    $identity=Get-AmbientNativeIdentity $ProductDirectory
    $workspace=New-AmbientPrivateMigrationWorkspace $ProductDirectory
    $hostRoot=Join-Path $workspace 'host';$extension=Join-Path $workspace 'Browser_Extension';$browserData=Join-Path $workspace 'chrome-profile'
    foreach($folder in @($hostRoot,$extension)){[void][IO.Directory]::CreateDirectory($folder)}
    foreach($name in @('File-Security.ps1','Control-Channel.ps1','Native-Mailbox.ps1','Native-Framing.ps1','Native-Registration.ps1','Native-Profiles.ps1','NativeHost.cs','NativeHost.ps1')){[IO.File]::Copy((Join-Path $ProductDirectory $name),(Join-Path $hostRoot $name),$false)}
    [IO.File]::Copy((Join-Path ([IO.Directory]::GetParent([IO.Path]::GetFullPath($ProductDirectory)).FullName) 'Browser_Extension/identity.public.json'),(Join-Path $extension 'identity.public.json'),$false)
    $hostName='org.ambientworkspace.migration_'+[Guid]::NewGuid().ToString('N')
    $manifest=@{manifest_version=3;name='Ambient Workspace private profile helper';version='1.0';key=$identity.publicKey;permissions=@('storage','nativeMessaging');background=@{service_worker='helper.js'};action=@{default_popup='helper.html'}}
    Write-AmbientNativeJson (Join-Path $extension 'manifest.json') $manifest 32768
    $script=[IO.File]::ReadAllText((Join-Path $ProductDirectory 'Native-Profile-Helper.js'))
    [IO.File]::WriteAllText((Join-Path $extension 'helper.js'),$script.Replace('__HOST__',$hostName),[Text.UTF8Encoding]::new($false))
    [IO.File]::Copy((Join-Path $ProductDirectory 'Native-Profile-Helper.html'),(Join-Path $extension 'helper.html'),$false)
    [IO.File]::Copy((Join-Path $ProductDirectory 'Native-Profile-Helper-Page.js'),(Join-Path $extension 'helper-page.js'),$false)
    $destination=Join-Path $browserData ('Default/Local Extension Settings/'+$identity.extensionId)
    [void][IO.Directory]::CreateDirectory($destination)
    foreach($entry in $before.entries){if($entry.name -cne 'LOCK'){
        $target=Join-Path $destination $entry.name
        [IO.File]::Copy((Join-Path $database $entry.name),$target,$false)
        if((Get-AmbientNativeHash ([IO.File]::ReadAllBytes($target))) -cne $entry.sha256){throw 'NATIVE_PROFILE_SOURCE_CHANGED'}
    }}
    $after=Get-AmbientChromeDatabaseSnapshot $database
    if(($before|ConvertTo-Json -Compress -Depth 4) -cne ($after|ConvertTo-Json -Compress -Depth 4)){throw 'NATIVE_PROFILE_SOURCE_CHANGED'}
    $marker=@{schemaVersion=1;workspace=$workspace;productDirectory=[IO.Path]::GetFullPath($ProductDirectory);hostDirectory=$hostRoot;helperExtension=$extension;browserData=$browserData;hostName=$hostName;stableExtensionId=$identity.extensionId;sourceUnchanged=$true;sourceBytes=$before.totalBytes;stage='prepared';backupId=''}
    Write-AmbientNativeJson (Join-Path $workspace 'migration.json') $marker 32768
    try{$null=Invoke-AmbientNativeRegistration $hostRoot 'Install' @($identity.extensionId) $hostName}
    catch{try{$null=Invoke-AmbientNativeRegistration $hostRoot 'Remove' @() $hostName}catch{};throw}
    Assert-AmbientInstallSecurity $hostRoot
    return $marker
}
function Get-AmbientChromeMigrationMarker($Migration) {
    $workspace=[IO.Path]::GetFullPath($Migration.workspace)
    # Inspect exactly the inputs used here. Chrome adds sandbox capability ACEs
    # to its own cache/network directories; they are not registration/backup
    # inputs and must not make removal of our temporary registration impossible.
    # No generic ACL rule or trusted SID list is relaxed.
    Test-AmbientPathAcl $workspace 'Private'
    $parent=[IO.Directory]::GetParent($workspace)
    while($null -ne $parent){Test-AmbientPathAcl $parent.FullName 'Ancestor';$parent=$parent.Parent}
    $markerPath=Join-Path $workspace 'migration.json';Test-AmbientPathAcl $markerPath 'Private'
    $marker=Read-AmbientNativeJson $markerPath 32768
    if($marker.schemaVersion -ne 1 -or $marker.workspace -cne $workspace -or $marker.sourceUnchanged -isnot [bool] -or -not $marker.sourceUnchanged -or $marker.hostName -cnotmatch '^org\.ambientworkspace\.migration_[a-f0-9]{32}$' -or
        $marker.hostDirectory -cne (Join-Path $workspace 'host') -or $marker.helperExtension -cne (Join-Path $workspace 'Browser_Extension') -or $marker.browserData -cne (Join-Path $workspace 'chrome-profile')){throw 'NATIVE_MIGRATION_INVALID'}
    Assert-AmbientInstallSecurity $marker.productDirectory
    Assert-AmbientInstallSecurity $marker.hostDirectory
    Test-AmbientPathAcl $marker.browserData 'Private'
    $identity=Get-AmbientNativeIdentity $marker.productDirectory
    if($marker.stableExtensionId -cne $identity.extensionId -or (Get-AmbientNativeIdentity $marker.hostDirectory).extensionId -cne $identity.extensionId){throw 'NATIVE_MIGRATION_INVALID'}
    return $marker
}
function Complete-AmbientChromeProfileMigration($Migration) {
    $marker=Get-AmbientChromeMigrationMarker $Migration
    $workspace=$marker.workspace
    $origin='chrome-extension://'+$marker.stableExtensionId+'/'
    $backups=Get-AmbientNativeProfileBackups $marker.hostDirectory $origin
    if($backups.backups.Count -lt 1 -or $backups.backups[0].fieldCount -lt 1){throw 'NATIVE_MIGRATION_NOT_COMPLETE'}
    $id=if($marker.backupId){$marker.backupId}else{$backups.backups[0].backupId}
    $source=Read-AmbientNativeProfileBackup $marker.hostDirectory $id $origin
    $targetFile=Join-Path (Join-Path $marker.productDirectory 'native-profile-backups') ($id+'.json')
    if([IO.File]::Exists($targetFile)){
        $target=Read-AmbientNativeProfileBackup $marker.productDirectory $id $origin
        if($target.dataSha256 -cne $source.dataSha256 -or $target.sourceOrigin -cne $source.sourceOrigin){throw 'NATIVE_PROFILE_BACKUP_CONFLICT'}
        $copied=@{backupId=$id;fieldCount=$target.fieldCount}
    }else{$copied=Copy-AmbientNativeProfileBackup $marker.hostDirectory $marker.productDirectory $id}
    $marker.backupId=$copied.backupId;$marker.stage='backupCopied'
    Write-AmbientNativeJson (Join-Path $workspace 'migration.json') $marker 32768 -Replace
    $null=Invoke-AmbientNativeRegistration $marker.hostDirectory 'Remove' @() $marker.hostName
    $marker.stage='completed'
    Write-AmbientNativeJson (Join-Path $workspace 'migration.json') $marker 32768 -Replace
    return @{ok=$true;backupId=$copied.backupId;fieldCount=$copied.fieldCount;sourceUnchanged=$marker.sourceUnchanged;temporaryRegistrationRemoved=$true}
}
function Remove-AmbientChromeMigrationRegistration($Migration) {
    $marker=Get-AmbientChromeMigrationMarker $Migration
    $null=Invoke-AmbientNativeRegistration $marker.hostDirectory 'Remove' @() $marker.hostName
    return @{temporaryRegistrationRemoved=$true;originalDataChanged=$false;workspacePreserved=$true}
}
