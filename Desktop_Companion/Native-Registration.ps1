# User-only Native Messaging registration. No pairing/settings migration or ACL repair.
function Get-AmbientNativeHash([byte[]]$Bytes) {
    $hash=[Security.Cryptography.SHA256]::Create()
    try{return ([BitConverter]::ToString($hash.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}
}
function Write-AmbientNativeBytes([string]$Path,[byte[]]$Bytes) {
    $temporary=$Path+'.'+[Guid]::NewGuid().ToString('N').Substring(0,8)+'.tmp';$created=$false;$stream=$null
    try {
        $stream=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);$created=$true
        $stream.Write($Bytes,0,$Bytes.Length);$stream.Flush();$stream.Dispose();$stream=$null
        if([IO.File]::Exists($Path)){[IO.File]::Replace($temporary,$Path,[NullString]::Value)}else{[IO.File]::Move($temporary,$Path)}
    }finally{if($null -ne $stream){$stream.Dispose()};if($created -and [IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
}
function Assert-AmbientNativeRegistryAcl($Key) {
    $security=$Key.GetAccessControl();$raw=[Security.AccessControl.RawSecurityDescriptor]::new($security.GetSecurityDescriptorBinaryForm(),0)
    $current=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $trusted=@($current,'S-1-5-18','S-1-5-32-544')
    if($null -eq $raw.DiscretionaryAcl -or -not $security.AreAccessRulesCanonical -or $trusted -cnotcontains $security.GetOwner([Security.Principal.SecurityIdentifier]).Value){throw 'NATIVE_REGISTRY_SECURITY'}
    foreach($rule in $security.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
        if($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or $trusted -ccontains $rule.IdentityReference.Value){continue}
        if($rule.IdentityReference.Value -ceq 'S-1-3-0' -and ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)){continue}
        $rights=[BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$rule.RegistryRights),0)
        # SET_VALUE, CREATE_SUB_KEY/LINK, DELETE, WRITE_DAC/OWNER, GENERIC_WRITE/ALL.
        if(($rights -band [uint32]0x500D0026) -ne 0){throw 'NATIVE_REGISTRY_SECURITY'}
    }
}
function Get-AmbientNativeRegistryState([string]$HostName) {
    if($HostName -cnotmatch '^org\.ambientworkspace\.(?:bridge|lab_[a-f0-9]{32}|migration_[a-f0-9]{32})$'){throw 'NATIVE_HOST_NAME_INVALID'}
    $subkey='Software\Google\Chrome\NativeMessagingHosts\'+$HostName;$result=@()
    foreach($view in @([Microsoft.Win32.RegistryView]::Registry32,[Microsoft.Win32.RegistryView]::Registry64)) {
        $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser,$view)
        try {
            Assert-AmbientNativeRegistryAcl $base
            foreach($ancestor in @('Software','Software\Google','Software\Google\Chrome','Software\Google\Chrome\NativeMessagingHosts')){
                $key=$base.OpenSubKey($ancestor,$false);try{if($null -ne $key){Assert-AmbientNativeRegistryAcl $key}}finally{if($null -ne $key){$key.Dispose()}}
            }
            $key=$base.OpenSubKey($subkey,$false)
            try {
                if($null -eq $key){$result+=@{view=[string]$view;exists=$false;value='';kind='';sddl='';extra=$false}}
                else {
                    Assert-AmbientNativeRegistryAcl $key
                    $names=@($key.GetValueNames());$extra=($key.SubKeyCount -gt 0 -or $names.Count -ne 1 -or $names[0] -cne '')
                    $value=[string]$key.GetValue('','',[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                    $kind=if($names -ccontains ''){[string]$key.GetValueKind('')}else{''}
                    $result+=@{view=[string]$view;exists=$true;value=$value;kind=$kind;sddl=$key.GetAccessControl().GetSecurityDescriptorSddlForm('Owner,Group,Access');extra=$extra}
                }
            }finally{if($null -ne $key){$key.Dispose()}}
        }catch [Security.SecurityException]{throw 'NATIVE_REGISTRY_ACCESS_DENIED'}catch [UnauthorizedAccessException]{throw 'NATIVE_REGISTRY_ACCESS_DENIED'}finally{$base.Dispose()}
    }
    return $result
}
function Save-AmbientNativeJournal($Context) {
    Write-AmbientNativeJson $Context.path $Context.value 1048576 -Replace
}
function Set-AmbientNativePlannedFile($Context,[string]$Name,[byte[]]$Bytes) {
    $Context.value.planned[$Name]=Get-AmbientNativeHash $Bytes;Save-AmbientNativeJournal $Context
    Write-AmbientNativeBytes (Join-Path $Context.value.root $Name) $Bytes
}
function Restore-AmbientNativeRegistration($Context) {
    $journal=$Context.value;$errors=@();$allowed=@('AmbientNativeHost.exe','native-host.json','native-host-origins.txt','native-host-build.json','native-host-registration.json')
    foreach($before in $journal.registry) {
        $base=$null;$key=$null
        try {
            $state=@(Get-AmbientNativeRegistryState $journal.hostName)|Where-Object view -CEQ $before.view
            if($state.extra -or ($state.exists -and $state.value -cne $journal.manifest -and $state.value -cne $before.value)){throw 'NATIVE_REGISTRY_CHANGED'}
            if($before.exists -and $state.exists -and $state.value -ceq $before.value -and $state.kind -ceq $before.kind){continue}
            $view=[Microsoft.Win32.RegistryView][Enum]::Parse([Microsoft.Win32.RegistryView],[string]$before.view)
            $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser,$view)
            $subkey='Software\Google\Chrome\NativeMessagingHosts\'+$journal.hostName
            if($before.exists) {
                $wasAbsent=-not $state.exists;$key=$base.CreateSubKey($subkey);$key.SetValue('',$before.value,[Microsoft.Win32.RegistryValueKind]::String)
                if($wasAbsent -and $before.sddl){$security=[Security.AccessControl.RegistrySecurity]::new();$security.SetSecurityDescriptorSddlForm($before.sddl);$key.SetAccessControl($security)}
            }elseif($state.exists){$base.DeleteSubKey($subkey,$false)}
        }catch{$errors+='registry'}finally{if($null -ne $key){$key.Dispose()};if($null -ne $base){$base.Dispose()}}
    }
    foreach($before in $journal.files) {
        try {
            if($allowed -cnotcontains $before.name){throw 'NATIVE_RECOVERY_PATH_INVALID'}
            $path=Join-Path $journal.root $before.name
            if([IO.File]::Exists($path)) {
                $actual=Get-AmbientNativeHash ([IO.File]::ReadAllBytes($path));$old=if($before.exists){Get-AmbientNativeHash ([Convert]::FromBase64String($before.content))}else{''}
                if($actual -cne $old -and (-not $journal.planned.ContainsKey($before.name) -or $actual -cne $journal.planned[$before.name])){throw 'NATIVE_RECOVERY_FILE_CHANGED'}
                if($actual -ceq $old){continue}
            }
            if($before.exists){Write-AmbientNativeBytes $path ([Convert]::FromBase64String($before.content))}
            elseif([IO.File]::Exists($path)){[IO.File]::Delete($path)}
        }catch{$errors+='file'}
    }
    $journal.phase=if($errors.Count){'recoveryRequired'}else{'rolledBack'}
    try{Save-AmbientNativeJournal $Context}catch{$errors+='journal'}
    if($errors.Count){throw 'NATIVE_ROLLBACK_INCOMPLETE'}
}
function Invoke-AmbientNativeRegistration([string]$Directory,[ValidateSet('Install','Repair','Remove','Inspect','Recover')][string]$Action,[string[]]$ExtensionIds=@(),[string]$HostName='org.ambientworkspace.bridge',[string]$RecoveryJournal='') {
    Assert-AmbientInstallSecurity $Directory
    $paths=Get-AmbientNativePaths $Directory;$root=$paths.root
    $states=@(Get-AmbientNativeRegistryState $HostName)
    $manifest=Join-Path $root 'native-host.json';$exe=Join-Path $root 'AmbientNativeHost.exe'
    if($Action -eq 'Inspect') {
        $matches=@($states|Where-Object{$_.exists -and $_.kind -ceq 'String' -and -not $_.extra -and [string]::Equals($_.value,$manifest,[StringComparison]::OrdinalIgnoreCase)})
        return @{registered=($matches.Count -eq 2);privateAcl=$true;registryAcl=$true;binaryPresent=[IO.File]::Exists($exe);communication='NOT_TESTED'}
    }
    if($Action -eq 'Recover') {
        $journalPath=[IO.Path]::GetFullPath($RecoveryJournal)
        $backupRoot=(Join-Path $root 'native-registration-backups')+'\'
        if(-not $journalPath.StartsWith($backupRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($journalPath) -cnotmatch '^[a-f0-9]{32}\.json$'){throw 'NATIVE_RECOVERY_PATH_INVALID'}
        $loaded=Read-AmbientNativeJson $journalPath 1048576
        if($loaded.root -cne $root -or $loaded.hostName -cne $HostName -or $loaded.phase -notin @('prepared','recoveryRequired')){throw 'NATIVE_RECOVERY_INVALID'}
        $planned=@{};foreach($property in $loaded.planned.PSObject.Properties){$planned[$property.Name]=$property.Value}
        $value=@{root=$loaded.root;hostName=$loaded.hostName;manifest=$loaded.manifest;phase=$loaded.phase;registry=$loaded.registry;files=$loaded.files;planned=$planned}
        Restore-AmbientNativeRegistration @{path=$journalPath;value=$value}
        return @{recovered=$true;personalDataChanged=$false}
    }
    foreach($state in $states){if($state.exists -and ($state.extra -or $state.kind -cne 'String' -or (-not [string]::Equals($state.value,$manifest,[StringComparison]::OrdinalIgnoreCase) -and $Action -cne 'Repair'))){throw 'NATIVE_REGISTRATION_CONFLICT'}}
    if($Action -ne 'Remove') {
        if($ExtensionIds.Count -lt 1 -or $ExtensionIds.Count -gt 8 -or @($ExtensionIds|Select-Object -Unique).Count -ne $ExtensionIds.Count){throw 'NATIVE_EXTENSION_IDS_INVALID'}
        foreach($id in $ExtensionIds){if($id -cnotmatch '^[a-p]{32}$'){throw 'NATIVE_EXTENSION_IDS_INVALID'}}
        if($HostName -ceq 'org.ambientworkspace.bridge') {
            $identity=Get-AmbientNativeIdentity $root
            if(@($ExtensionIds|Where-Object{$_ -cne $identity.extensionId}).Count){throw 'NATIVE_LEGACY_MIGRATION_REQUIRED'}
        }
    }
    $files=@();foreach($name in @('AmbientNativeHost.exe','native-host.json','native-host-origins.txt','native-host-build.json','native-host-registration.json')){
        $path=Join-Path $root $name;$exists=[IO.File]::Exists($path);$files+=@{name=$name;exists=$exists;content=$(if($exists){[Convert]::ToBase64String([IO.File]::ReadAllBytes($path))}else{''})}
    }
    $backup=Join-Path $root 'native-registration-backups';[void][IO.Directory]::CreateDirectory($backup)
    $context=@{path=(Join-Path $backup ([Guid]::NewGuid().ToString('N')+'.json'));value=@{root=$root;hostName=$HostName;manifest=$manifest;phase='prepared';registry=$states;files=$files;planned=@{}}}
    Save-AmbientNativeJournal $context
    try {
        if($Action -ne 'Remove') {
            $source=Join-Path $root 'NativeHost.cs';$sourceHash=Get-AmbientNativeHash ([IO.File]::ReadAllBytes($source));$reuse=$false
            $buildPath=Join-Path $root 'native-host-build.json'
            if([IO.File]::Exists($exe) -and [IO.File]::Exists($buildPath)) {
                $build=Read-AmbientNativeJson $buildPath 32768
                $reuse=($build.sourceSha256 -ceq $sourceHash -and $build.binarySha256 -ceq (Get-AmbientNativeHash ([IO.File]::ReadAllBytes($exe))))
            }
            if(-not $reuse) {
                if([IO.File]::Exists($exe) -and $Action -cne 'Repair'){throw 'NATIVE_HOST_BINARY_UNVERIFIED'}
                $compiler=Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
                if(-not [IO.File]::Exists($compiler)){throw 'NATIVE_FRAMEWORK_COMPILER_UNAVAILABLE'}
                $temporary=$exe+'.'+[Guid]::NewGuid().ToString('N').Substring(0,8)+'.tmp'
                try {
                    $compilerOutput=@(& $compiler '/nologo' '/target:exe' '/optimize+' ('/out:'+$temporary) $source 2>&1)
                    if($LASTEXITCODE -ne 0 -or -not [IO.File]::Exists($temporary)){throw 'NATIVE_HOST_BUILD_FAILED'}
                    $bytes=[IO.File]::ReadAllBytes($temporary);$binaryHash=Get-AmbientNativeHash $bytes
                    Set-AmbientNativePlannedFile $context 'AmbientNativeHost.exe' $bytes
                    $metadata=@{sourceSha256=$sourceHash;binarySha256=$binaryHash}|ConvertTo-Json -Compress
                    Set-AmbientNativePlannedFile $context 'native-host-build.json' ([Text.Encoding]::UTF8.GetBytes($metadata))
                }finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
            }
            $origins=@($ExtensionIds|Sort-Object|ForEach-Object{'chrome-extension://'+$_+'/'})
            Set-AmbientNativePlannedFile $context 'native-host-origins.txt' ([Text.Encoding]::UTF8.GetBytes(($origins -join [Environment]::NewLine)))
            $hostManifest=@{name=$HostName;description='Ambient Workspace private native bridge';path=$exe;type='stdio';allowed_origins=$origins}|ConvertTo-Json -Compress
            Set-AmbientNativePlannedFile $context 'native-host.json' ([Text.Encoding]::UTF8.GetBytes($hostManifest))
            $marker=@{product='AmbientWorkspace';protocolVersion=2;hostName=$HostName;desktopPath=$root}|ConvertTo-Json -Compress
            Set-AmbientNativePlannedFile $context 'native-host-registration.json' ([Text.Encoding]::UTF8.GetBytes($marker))
            Assert-AmbientInstallSecurity $root
        }
        foreach($view in @([Microsoft.Win32.RegistryView]::Registry32,[Microsoft.Win32.RegistryView]::Registry64)) {
            $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser,$view);$key=$null
            try {
                $subkey='Software\Google\Chrome\NativeMessagingHosts\'+$HostName
                if($Action -eq 'Remove'){$base.DeleteSubKey($subkey,$false)}
                else{$key=$base.CreateSubKey($subkey);$key.SetValue('',$manifest,[Microsoft.Win32.RegistryValueKind]::String)}
            }finally{if($null -ne $key){$key.Dispose()};$base.Dispose()}
        }
        $after=@(Get-AmbientNativeRegistryState $HostName)
        if($Action -eq 'Remove'){if(@($after|Where-Object exists).Count){throw 'NATIVE_REGISTRATION_VERIFY_FAILED'}}
        elseif(@($after|Where-Object{-not $_.exists -or $_.kind -cne 'String' -or $_.extra -or -not [string]::Equals($_.value,$manifest,[StringComparison]::OrdinalIgnoreCase)}).Count){throw 'NATIVE_REGISTRATION_VERIFY_FAILED'}
        $context.value.phase='committed';Save-AmbientNativeJournal $context
        return @{registered=($Action -ne 'Remove');removed=($Action -eq 'Remove');privateAcl=$true;registryAcl=$true;personalDataChanged=$false;communication='NOT_TESTED';journal=$context.path}
    }catch {
        $failure=$_
        Restore-AmbientNativeRegistration $context
        throw $failure
    }
}
