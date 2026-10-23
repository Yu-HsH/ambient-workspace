# Explicit private Chrome-local backups. No original profile/file deletion.
function Get-AmbientNativeIdentity([string]$Directory) {
    $file=Join-Path ([IO.Directory]::GetParent([IO.Path]::GetFullPath($Directory)).FullName) 'Browser_Extension/identity.public.json'
    try {
        $identity=Read-AmbientNativeJson $file 32768
        if($identity.schemaVersion -ne 1 -or $identity.publicKey -isnot [string] -or $identity.publicKey.Length -gt 4096 -or $identity.extensionId -cnotmatch '^[a-p]{32}$'){throw 'invalid'}
        $der=[Convert]::FromBase64String($identity.publicKey);$digest=Get-AmbientNativeHash $der;$id='';$alphabet='abcdefghijklmnop'
        foreach($character in $digest.Substring(0,32).ToCharArray()){$id+=$alphabet[[Convert]::ToInt32([string]$character,16)]}
        if($id -cne $identity.extensionId){throw 'invalid'}
        return $identity
    }catch{throw [IO.InvalidDataException]::new('NATIVE_IDENTITY_INVALID')}
}
function Get-AmbientNativeProfileDataBytes($Snapshot) {
    if($Snapshot -isnot [pscustomobject]){throw [IO.InvalidDataException]::new('NATIVE_PROFILE_INVALID')}
    Assert-AmbientNativeJsonDepth $Snapshot 3
    $bytes=[Text.UTF8Encoding]::new($false,$true).GetBytes(($Snapshot|ConvertTo-Json -Compress -Depth 16))
    if($bytes.Length -gt 262144){throw [IO.InvalidDataException]::new('NATIVE_PROFILE_TOO_LARGE')}
    return ,$bytes
}
function New-AmbientNativeProfileBackup([string]$Directory,$Snapshot,[string]$CallerOrigin) {
    Assert-AmbientInstallSecurity $Directory
    if($CallerOrigin -cnotmatch '^chrome-extension://[a-p]{32}/$'){throw [IO.InvalidDataException]::new('NATIVE_PROFILE_ORIGIN_INVALID')}
    $identity=Get-AmbientNativeIdentity $Directory;$bytes=Get-AmbientNativeProfileDataBytes $Snapshot
    $backupRoot=Join-Path $Directory 'native-profile-backups';[void][IO.Directory]::CreateDirectory($backupRoot)
    if(@([IO.Directory]::GetFiles($backupRoot,'*.json')).Count -ge 128){throw [IO.InvalidDataException]::new('NATIVE_PROFILE_BACKUP_LIMIT')}
    $id=[Guid]::NewGuid().ToString('N')
    $record=@{schemaVersion=1;id=$id;sourceOrigin=$CallerOrigin;targetOrigin=('chrome-extension://'+$identity.extensionId+'/');utc=[DateTime]::UtcNow.ToString('o');fieldCount=@($Snapshot.PSObject.Properties).Count;dataSha256=(Get-AmbientNativeHash $bytes);data=$Snapshot;complete=$true}
    Write-AmbientNativeJson (Join-Path $backupRoot ($id+'.json')) $record 524288
    Assert-AmbientInstallSecurity $Directory
    return @{ok=$true;backupId=$id;utc=$record.utc;fieldCount=$record.fieldCount;hasPairing=($Snapshot.PSObject.Properties.Name -ccontains 'desktopPairingCode' -and $Snapshot.desktopPairingCode -is [string] -and $Snapshot.desktopPairingCode -cmatch '^[a-f0-9]{64}$')}
}
function Read-AmbientNativeProfileBackup([string]$Directory,[string]$Id,[string]$CallerOrigin) {
    Assert-AmbientInstallSecurity $Directory
    if(-not (Test-AmbientNativeId $Id)){throw [IO.InvalidDataException]::new('NATIVE_PROFILE_ID_INVALID')}
    $identity=Get-AmbientNativeIdentity $Directory
    $record=Read-AmbientNativeJson (Join-Path (Join-Path $Directory 'native-profile-backups') ($Id+'.json')) 524288
    if($record -isnot [pscustomobject] -or $record.schemaVersion -ne 1 -or $record.id -cne $Id -or $record.complete -isnot [bool] -or $record.complete -ne $true -or
        $record.sourceOrigin -cnotmatch '^chrome-extension://[a-p]{32}/$' -or $record.targetOrigin -cne ('chrome-extension://'+$identity.extensionId+'/') -or
        ($CallerOrigin -cne $record.sourceOrigin -and $CallerOrigin -cne $record.targetOrigin)){throw [IO.InvalidDataException]::new('NATIVE_PROFILE_BACKUP_INVALID')}
    $bytes=Get-AmbientNativeProfileDataBytes $record.data
    if($record.dataSha256 -cne (Get-AmbientNativeHash $bytes) -or $record.fieldCount -ne @($record.data.PSObject.Properties).Count){throw [IO.InvalidDataException]::new('NATIVE_PROFILE_BACKUP_INVALID')}
    return $record
}
function Copy-AmbientNativeProfileBackup([string]$SourceDirectory,[string]$TargetDirectory,[string]$Id) {
    Assert-AmbientInstallSecurity $TargetDirectory
    $sourceIdentity=Get-AmbientNativeIdentity $SourceDirectory;$targetIdentity=Get-AmbientNativeIdentity $TargetDirectory
    if($sourceIdentity.extensionId -cne $targetIdentity.extensionId){throw [IO.InvalidDataException]::new('NATIVE_PROFILE_IDENTITY_MISMATCH')}
    $record=Read-AmbientNativeProfileBackup $SourceDirectory $Id ('chrome-extension://'+$sourceIdentity.extensionId+'/')
    $target=Join-Path $TargetDirectory 'native-profile-backups';[void][IO.Directory]::CreateDirectory($target)
    if(@([IO.Directory]::GetFiles($target,'*.json')).Count -ge 128){throw [IO.InvalidDataException]::new('NATIVE_PROFILE_BACKUP_LIMIT')}
    Write-AmbientNativeJson (Join-Path $target ($Id+'.json')) $record 524288
    Assert-AmbientInstallSecurity $TargetDirectory
    return @{ok=$true;backupId=$record.id;fieldCount=$record.fieldCount;originalPreserved=$true}
}
function Get-AmbientNativeProfileBackups([string]$Directory,[string]$CallerOrigin) {
    Assert-AmbientInstallSecurity $Directory
    $root=Join-Path $Directory 'native-profile-backups';$metadata=@()
    if([IO.Directory]::Exists($root)) {
        foreach($file in [IO.Directory]::GetFiles($root,'*.json')) {
            $name=[IO.Path]::GetFileNameWithoutExtension($file)
            if(-not (Test-AmbientNativeId $name)){continue}
            $record=Read-AmbientNativeProfileBackup $Directory $name $CallerOrigin
            $metadata+=@{backupId=$record.id;utc=$record.utc;fieldCount=$record.fieldCount;hasPairing=($record.data.PSObject.Properties.Name -ccontains 'desktopPairingCode' -and $record.data.desktopPairingCode -is [string] -and $record.data.desktopPairingCode -cmatch '^[a-f0-9]{64}$')}
        }
    }
    return @{ok=$true;backups=@($metadata|Sort-Object utc -Descending|Select-Object -First 20)}
}
