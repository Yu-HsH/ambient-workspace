# Private, registered Chrome host client. No HTTP and no automatic Desktop start.
param([Parameter(Mandatory=$true)][string]$CallerOrigin)
Set-StrictMode -Version Latest;$ErrorActionPreference='Stop'
$inputStream=$null;$outputStream=$null
try {
    . (Join-Path $PSScriptRoot 'File-Security.ps1')
    Assert-AmbientInstallSecurity $PSScriptRoot
    if($CallerOrigin -cnotmatch '^chrome-extension://[a-p]{32}/$'){exit 2}
    $allowed=@([IO.File]::ReadAllLines((Join-Path $PSScriptRoot 'native-host-origins.txt')))
    if($allowed.Count -lt 1 -or $allowed.Count -gt 8 -or $allowed -cnotcontains $CallerOrigin){exit 2}
    foreach($origin in $allowed){if($origin -cnotmatch '^chrome-extension://[a-p]{32}/$'){exit 2}}
    foreach($name in @('Control-Channel.ps1','Native-Mailbox.ps1','Native-Framing.ps1','Native-Registration.ps1','Native-Profiles.ps1')){. (Join-Path $PSScriptRoot $name)}
    $paths=Get-AmbientNativePaths $PSScriptRoot
    $inputStream=[Console]::OpenStandardInput();$outputStream=[Console]::OpenStandardOutput()
    while($true) {
        $envelope=Read-AmbientNativeFrame $inputStream
        if($null -eq $envelope){break}
        if($envelope.PSObject.Properties.Name -cnotcontains 'id' -or -not (Test-AmbientNativeId $envelope.id)){exit 4}
        $id=$envelope.id
        try {
            if($envelope.PSObject.Properties.Name -cnotcontains 'packet' -or $envelope.packet -isnot [pscustomobject]){throw [IO.InvalidDataException]::new('Invalid packet')}
            $packet=$envelope.packet
            Assert-AmbientNativeJsonDepth $packet
            if($packet.PSObject.Properties.Name -cnotcontains 'type' -or $packet.type -isnot [string]){throw [IO.InvalidDataException]::new('Invalid packet')}
            $packetBytes=[Text.Encoding]::UTF8.GetByteCount(($packet|ConvertTo-Json -Compress -Depth 16))
            $profileOperation=$packet.type -cin @('native.profile.export','native.profile.list','native.profile.read')
            if($packetBytes -gt $(if($profileOperation){400000}else{170000})){throw [IO.InvalidDataException]::new('Packet too large')}
            if($packet.type -clike 'control.*' -and $packetBytes -gt 4096){throw [IO.InvalidDataException]::new('Control packet too large')}
            if($packet.type -ceq 'native.status') {
                $identity=Get-AmbientNativeIdentity $PSScriptRoot
                $result=@{ok=$true;protocolVersion=2;transport='native';bridgeAvailable=($null -ne (Get-AmbientNativeEndpoint $paths));stableExtensionId=$identity.extensionId}
            } elseif($packet.type -ceq 'native.profile.export') {
                $result=New-AmbientNativeProfileBackup $PSScriptRoot $packet.data $CallerOrigin
            } elseif($packet.type -ceq 'native.profile.list') {
                $result=Get-AmbientNativeProfileBackups $PSScriptRoot $CallerOrigin
            } elseif($packet.type -ceq 'native.profile.read') {
                $backup=Read-AmbientNativeProfileBackup $PSScriptRoot $packet.backupId $CallerOrigin
                $result=@{ok=$true;data=$backup.data;backupId=$backup.id}
            } else {
                if($packet.PSObject.Properties.Name -cnotcontains 'token' -or $packet.token -isnot [string] -or $packet.token -cnotmatch '^[a-f0-9]{64}$') {
                    Write-AmbientNativeFrame $outputStream @{id=$id;transport='pairingRequired'};continue
                }
                $keyPath=Join-Path $PSScriptRoot 'bridge-pairing.txt'
                if(-not [IO.File]::Exists($keyPath)) {Write-AmbientNativeFrame $outputStream @{id=$id;transport='bridgeUnavailable'};continue}
                $key=[IO.File]::ReadAllText($keyPath).Trim()
                if($key -cnotmatch '^[a-f0-9]{64}$' -or $packet.token -cne $key) {Write-AmbientNativeFrame $outputStream @{id=$id;transport='pairingRejected'};continue}
                # The secret traverses only OS-owned inherited stdio after Chrome
                # launches its registered host. It never enters the disk queue.
                $clean=[ordered]@{}
                foreach($property in $packet.PSObject.Properties){if($property.Name -ine 'token'){$clean[$property.Name]=$property.Value}}
                $key=$null
                $result=Invoke-AmbientNativeMailbox $paths ([pscustomobject]$clean) ($CallerOrigin.TrimEnd('/'))
            }
            Write-AmbientNativeFrame $outputStream @{id=$id;transport='ok';result=$result}
        } catch {
            # Classify the actual cause, including wrapped PS invocation errors.
            # Keep fixed wire codes; never expose exception text or packet data.
            $cause=$_.Exception;while($null -ne $cause.InnerException){$cause=$cause.InnerException}
            $failure=if($cause -is [TimeoutException]){'timeout'}elseif($cause -is [IO.InvalidDataException]){'invalid'}else{'bridgeUnavailable'}
            Write-AmbientNativeFrame $outputStream @{id=$id;transport=$failure}
        }
    }
} catch {exit 5}
finally {if($null -ne $inputStream){$inputStream.Dispose()};if($null -ne $outputStream){$outputStream.Dispose()}}
