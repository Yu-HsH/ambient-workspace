# Only new private fixtures and a new random HKCU test leaf; no product registration.
param([Parameter(Mandatory=$true)][string]$FixtureParent)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$source=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../Desktop_Companion'))
$fixture=Join-Path ([IO.Path]::GetFullPath($FixtureParent)) ('r-'+[Guid]::NewGuid().ToString('N').Substring(0,8));[void][IO.Directory]::CreateDirectory($fixture)
$directories=@();foreach($part in @('a','b','c')){
    $folder=Join-Path $fixture $part;[void][IO.Directory]::CreateDirectory($folder)
    foreach($name in @('File-Security.ps1','Control-Channel.ps1','Native-Mailbox.ps1','Native-Registration.ps1','Native-Profiles.ps1','NativeHost.cs','NativeHost.ps1','Native-Framing.ps1')){[IO.File]::Copy((Join-Path $source $name),(Join-Path $folder $name),$false)}
    [IO.File]::WriteAllText((Join-Path $folder 'bridge-pairing.txt'),'SYNTHETIC_PRESERVE_KEY')
    [IO.File]::WriteAllText((Join-Path $folder 'settings.json'),'SYNTHETIC_PRESERVE_SETTINGS')
    $directories+=$folder
}
foreach($name in @('File-Security.ps1','Control-Channel.ps1','Native-Mailbox.ps1','Native-Registration.ps1')){. (Join-Path $directories[0] $name)}
$hostName='org.ambientworkspace.lab_'+[Guid]::NewGuid().ToString('N');$ids=@(('a'*32));$cases=[Collections.Generic.List[string]]::new();$lastRoot=$directories[0]
function Assert-True($Value,[string]$Message){if(-not $Value){throw $Message}}
function Check([string]$Name,[scriptblock]$Action){&$Action;$cases.Add($Name);Write-Output ('PASS '+$Name)}
function Throws([scriptblock]$Action){$refused=$false;try{&$Action|Out-Null}catch{$refused=$true};Assert-True $refused 'Expected refusal'}
function Get-TestKey {
    $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser,[Microsoft.Win32.RegistryView]::Registry64)
    try{return $base.OpenSubKey(('Software\Google\Chrome\NativeMessagingHosts\'+$hostName),[Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,[Security.AccessControl.RegistryRights]::FullControl)}finally{$base.Dispose()}
}
function Restore-TestAcl($Key,$Before) {
    # Retrieved RegistrySecurity has no modified flags. Rehydrate Access to make
    # the explicit restoration effective; only this newly-created test leaf.
    $restored=[Security.AccessControl.RegistrySecurity]::new()
    $restored.SetSecurityDescriptorSddlForm($Before.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access),[Security.AccessControl.AccessControlSections]::Access)
    $Key.SetAccessControl($restored)
}
try {
    Check 'read-only inspect reports absent and does not create registration or binary' {
        $result=Invoke-AmbientNativeRegistration $directories[0] 'Inspect' @() $hostName
        Assert-True (-not $result.registered -and -not $result.binaryPresent -and $result.communication -ceq 'NOT_TESTED') 'Absent state mislabeled'
    }
    Check 'invalid extension ID fails before journal or binary generation' {
        Throws {Invoke-AmbientNativeRegistration $directories[0] 'Install' @('invalid') $hostName}
        Assert-True (-not [IO.Directory]::Exists((Join-Path $directories[0] 'native-registration-backups'))) 'Invalid ID wrote files'
    }
    Check 'normal-user install builds host and verifies current-user registry views' {
        $result=Invoke-AmbientNativeRegistration $directories[0] 'Install' $ids $hostName
        Assert-True ($result.registered -and $result.privateAcl -and $result.registryAcl -and -not $result.personalDataChanged -and $result.communication -ceq 'NOT_TESTED') 'Install not verified'
        $manifest=Read-AmbientNativeJson (Join-Path $directories[0] 'native-host.json')
        Assert-True ($manifest.name -ceq $hostName -and $manifest.type -ceq 'stdio' -and $manifest.allowed_origins.Count -eq 1) 'Bad native manifest'
    }
    Check 'idempotent install reuses verified binary bytes' {
        $before=Get-AmbientNativeHash ([IO.File]::ReadAllBytes((Join-Path $directories[0] 'AmbientNativeHost.exe')))
        $null=Invoke-AmbientNativeRegistration $directories[0] 'Install' $ids $hostName
        $after=Get-AmbientNativeHash ([IO.File]::ReadAllBytes((Join-Path $directories[0] 'AmbientNativeHost.exe')))
        Assert-True ($before -ceq $after) 'Verified binary rebuilt unnecessarily'
    }
    Check 'another installation conflicts without implicit registry overwrite' {
        Throws {Invoke-AmbientNativeRegistration $directories[1] 'Install' $ids $hostName}
        Assert-True (-not [IO.File]::Exists((Join-Path $directories[1] 'native-host.json'))) 'Conflict modified second installation'
        Assert-True (Invoke-AmbientNativeRegistration $directories[0] 'Inspect' @() $hostName).registered 'Previous registration lost'
    }
    Check 'explicit relocation repair preserves old files and registers new private path' {
        $null=Invoke-AmbientNativeRegistration $directories[1] 'Repair' $ids $hostName;$script:lastRoot=$directories[1]
        Assert-True (Invoke-AmbientNativeRegistration $directories[1] 'Inspect' @() $hostName).registered 'Move not registered'
        Assert-True ([IO.File]::Exists((Join-Path $directories[0] 'native-host.json'))) 'Old installation deleted'
    }
    Check 'compiler failure rolls back and preserves previous working registration' {
        [IO.File]::AppendAllText((Join-Path $directories[2] 'NativeHost.cs'),"`nnot valid C sharp;")
        Throws {Invoke-AmbientNativeRegistration $directories[2] 'Repair' $ids $hostName}
        Assert-True (Invoke-AmbientNativeRegistration $directories[1] 'Inspect' @() $hostName).registered 'Failed build changed registration'
        Assert-True (-not [IO.File]::Exists((Join-Path $directories[2] 'AmbientNativeHost.exe'))) 'Failed build left a host'
        [IO.File]::Copy((Join-Path $source 'NativeHost.cs'),(Join-Path $directories[2] 'NativeHost.cs'),$true)
    }
    Check 'denied write after preparation restores files and retains previous registry value' {
        $key=Get-TestKey;$originalAcl=$key.GetAccessControl()
        try {
            $denied=$key.GetAccessControl();$denied.AddAccessRule([Security.AccessControl.RegistryAccessRule]::new([Security.Principal.WindowsIdentity]::GetCurrent().User,[Security.AccessControl.RegistryRights]::SetValue,[Security.AccessControl.InheritanceFlags]::None,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Deny));$key.SetAccessControl($denied)
            Throws {Invoke-AmbientNativeRegistration $directories[2] 'Repair' $ids $hostName}
            Assert-True (-not [IO.File]::Exists((Join-Path $directories[2] 'AmbientNativeHost.exe')) -and -not [IO.File]::Exists((Join-Path $directories[2] 'native-host.json'))) 'Prepared files were not restored'
            Assert-True (Invoke-AmbientNativeRegistration $directories[1] 'Inspect' @() $hostName).registered 'Previous registration changed after denial'
        }finally{Restore-TestAcl $key $originalAcl;$key.Dispose()}
    }
    Check 'unsafe write grant on the owned test key is refused and never repaired automatically' {
        $key=Get-TestKey;$originalAcl=$key.GetAccessControl()
        try {
            $unsafe=$key.GetAccessControl();$unsafe.AddAccessRule([Security.AccessControl.RegistryAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-11'),[Security.AccessControl.RegistryRights]::SetValue,[Security.AccessControl.InheritanceFlags]::None,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow));$key.SetAccessControl($unsafe)
            Throws {Invoke-AmbientNativeRegistration $directories[1] 'Inspect' @() $hostName}
            $still=$key.GetAccessControl().GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])|Where-Object{$_.IdentityReference.Value -ceq 'S-1-5-11'}
            Assert-True ($null -ne $still) 'Product silently repaired registry ACL'
        }finally{Restore-TestAcl $key $originalAcl;$key.Dispose()}
    }
    Check 'prepared crash journal restores only its planned metadata and preserves data' {
        $backup=Join-Path $directories[2] 'native-registration-backups'
        $journalPath=@([IO.Directory]::GetFiles($backup,'*.json')|Sort-Object {[IO.File]::GetLastWriteTimeUtc($_)})[-1]
        $loaded=Read-AmbientNativeJson $journalPath 1048576
        $planned=@{};foreach($property in $loaded.planned.PSObject.Properties){$planned[$property.Name]=$property.Value}
        $bytes=[Text.Encoding]::UTF8.GetBytes('SYNTHETIC_PREPARED_METADATA');$planned['native-host-origins.txt']=Get-AmbientNativeHash $bytes
        $loaded.phase='prepared';$loaded.planned=$planned
        Write-AmbientNativeJson $journalPath $loaded 1048576 -Replace
        Write-AmbientNativeBytes (Join-Path $directories[2] 'native-host-origins.txt') $bytes
        $recovered=Invoke-AmbientNativeRegistration $directories[2] 'Recover' @() $hostName $journalPath
        Assert-True ($recovered.recovered -and -not [IO.File]::Exists((Join-Path $directories[2] 'native-host-origins.txt'))) 'Crash journal did not restore planned file'
        Assert-True (Invoke-AmbientNativeRegistration $directories[1] 'Inspect' @() $hostName).registered 'Recovery changed previous registration'
    }
    Check 'recovery refuses journal outside selected private installation' {
        $other=Join-Path $directories[0] 'native-registration-backups'
        $journalPath=@([IO.Directory]::GetFiles($other,'*.json'))[0]
        Throws {Invoke-AmbientNativeRegistration $directories[2] 'Recover' @() $hostName $journalPath}
    }
    Check 'uninstall removes only registration and keeps binary/settings/key/backups' {
        $result=Invoke-AmbientNativeRegistration $directories[1] 'Remove' @() $hostName
        Assert-True ($result.removed -and -not $result.registered) 'Removal not verified'
        Assert-True ([IO.File]::Exists((Join-Path $directories[1] 'AmbientNativeHost.exe')) -and [IO.Directory]::Exists((Join-Path $directories[1] 'native-registration-backups'))) 'Removal deleted preserved files'
    }
    Check 'all synthetic personal data is unchanged and unique test leaf is absent' {
        foreach($folder in $directories){Assert-True ([IO.File]::ReadAllText((Join-Path $folder 'bridge-pairing.txt')) -ceq 'SYNTHETIC_PRESERVE_KEY' -and [IO.File]::ReadAllText((Join-Path $folder 'settings.json')) -ceq 'SYNTHETIC_PRESERVE_SETTINGS') 'Personal fixture changed'}
        Assert-True (@(Get-AmbientNativeRegistryState $hostName|Where-Object exists).Count -eq 0) 'Test leaf remains'
    }
    $result=@{result='PASS';cases=$cases.ToArray();count=$cases.Count;directory=$fixture;realSecondAccount=$false;syntheticOnly=$true;actualProductRegistrationChanged=$false}
    Write-AmbientNativeJson (Join-Path $fixture 'summary.json') $result
    Write-Output ('Native registration '+$cases.Count+'/'+$cases.Count+' PASS')
}finally {
    try{if(@(Get-AmbientNativeRegistryState $hostName|Where-Object exists).Count){$null=Invoke-AmbientNativeRegistration $lastRoot 'Remove' @() $hostName}}catch{Write-Output 'TEST REGISTRATION CLEANUP NEEDS REVIEW';throw}
}
