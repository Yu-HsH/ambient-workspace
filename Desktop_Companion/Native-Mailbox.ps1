# Private file IPC behind Chrome Native Messaging. No listener or HTTP fallback.
# Callers must load File-Security.ps1 and Control-Channel.ps1 before initialization.
function Get-AmbientNativePaths([string]$Directory) {
    $root=[IO.Path]::GetFullPath($Directory)
    $mailbox=Join-Path $root 'native-mailbox'
    $paths=@{root=$root;mailbox=$mailbox;requests=(Join-Path $mailbox 'requests');responses=(Join-Path $mailbox 'responses');endpoint=(Join-Path $root 'native-bridge.json')}
    # PS 5.1/.NET legacy MAX_PATH also applies to atomic temporary filenames.
    # Refuse before writing instead of failing midway or assuming long-path policy.
    if((Join-Path $paths.responses (('a'*32)+'.response.json.'+('b'*8)+'.tmp')).Length -gt 259){throw [IO.PathTooLongException]::new('NATIVE_PATH_TOO_LONG')}
    return $paths
}
function Initialize-AmbientNativeMailbox([string]$Directory) {
    Assert-AmbientInstallSecurity $Directory
    $paths=Get-AmbientNativePaths $Directory
    foreach($folder in @($paths.mailbox,$paths.requests,$paths.responses)) { [void][IO.Directory]::CreateDirectory($folder) }
    # Verify actual inherited permissions; never repair/replace existing ACLs.
    Assert-AmbientInstallSecurity $Directory
    return $paths
}
function Write-AmbientNativeJson([string]$Path,$Value,[int]$MaximumBytes=180000,[switch]$Replace) {
    Assert-AmbientNativeJsonDepth $Value
    $bytes=[Text.UTF8Encoding]::new($false,$true).GetBytes(($Value|ConvertTo-Json -Compress -Depth 16 -WarningAction Stop))
    if($bytes.Length -gt $MaximumBytes){throw [IO.InvalidDataException]::new('Native message too large')}
    # A short temp suffix keeps private Portable paths within PS 5.1 MAX_PATH.
    # CreateNew prevents collision/overwrite; the full request correlation ID is 128 bits.
    $temporary=$Path+'.'+[Guid]::NewGuid().ToString('N').Substring(0,8)+'.tmp';$created=$false;$stream=$null
    try {
        $stream=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);$created=$true
        $stream.Write($bytes,0,$bytes.Length);$stream.Flush();$stream.Dispose();$stream=$null
        if($Replace -and [IO.File]::Exists($Path)){[IO.File]::Replace($temporary,$Path,[NullString]::Value)}else{[IO.File]::Move($temporary,$Path)}
    } finally {
        if($null -ne $stream){$stream.Dispose()}
        if($created -and [IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}
    }
}
function Assert-AmbientNativeJsonDepth($Value,[int]$Depth=0) {
    if($Depth -gt 12){throw [IO.InvalidDataException]::new('Native message too deep')}
    if($Value -is [Collections.IDictionary]){foreach($key in $Value.Keys){Assert-AmbientNativeJsonDepth $Value[$key] ($Depth+1)}}
    elseif($Value -is [pscustomobject]){foreach($property in $Value.PSObject.Properties){Assert-AmbientNativeJsonDepth $property.Value ($Depth+1)}}
    elseif($Value -is [Collections.IList]){foreach($item in $Value){Assert-AmbientNativeJsonDepth $item ($Depth+1)}}
}
function Read-AmbientNativeJson([string]$Path,[int]$MaximumBytes=180000) {
    $stream=$null
    try {
        $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::Read -bor [IO.FileShare]::Delete))
        if($stream.Length -le 0 -or $stream.Length -gt $MaximumBytes){throw [IO.InvalidDataException]::new('Native message size invalid')}
        $reader=[IO.StreamReader]::new($stream,[Text.UTF8Encoding]::new($false,$true),$false)
        try {return ($reader.ReadToEnd()|ConvertFrom-Json)}finally{$reader.Dispose()}
    } finally {if($null -ne $stream){$stream.Dispose()}}
}
function Test-AmbientNativeId($Value) {return ($Value -is [string] -and $Value -cmatch '^[a-f0-9]{32}$')}
function New-AmbientNativeEndpoint($Paths) {
    $process=[Diagnostics.Process]::GetCurrentProcess()
    try {$endpoint=@{protocolVersion=2;instanceId=[Guid]::NewGuid().ToString('N');ownerPid=$PID;ownerStartTicks=$process.StartTime.ToUniversalTime().Ticks}}
    finally {$process.Dispose()}
    Write-AmbientNativeJson $Paths.endpoint $endpoint 32768 -Replace
    return $endpoint
}
function Get-AmbientNativeEndpoint($Paths) {
    try {
        $endpoint=Read-AmbientNativeJson $Paths.endpoint 32768
        if($null -eq $endpoint -or $endpoint -is [Array] -or $endpoint.protocolVersion -ne 2 -or
            -not (Test-AmbientNativeId $endpoint.instanceId) -or -not (Test-AmbientControlOwner $endpoint)) {return $null}
        return $endpoint
    } catch {return $null}
}
function Invoke-AmbientNativeMailbox($Paths,$Packet,[string]$Origin,[ValidateRange(100,1000)][int]$TimeoutMilliseconds=1000) {
    if($Origin -cnotmatch '^chrome-extension://[a-p]{32}$' -or $Packet -isnot [pscustomobject]){throw [IO.InvalidDataException]::new('Native request invalid')}
    # Pairing is checked inside the authenticated native host. Never duplicate
    # the pairing secret in the transient disk mailbox.
    if($Packet.PSObject.Properties.Name -contains 'token'){throw [IO.InvalidDataException]::new('Native mailbox must not contain a pairing token')}
    $endpoint=Get-AmbientNativeEndpoint $Paths
    if($null -eq $endpoint){throw [IO.IOException]::new('Native Bridge unavailable')}
    if(@([IO.Directory]::GetFiles($Paths.requests,'*.request.json')).Count -ge 8){throw [IO.IOException]::new('Native Bridge busy')}
    $id=[Guid]::NewGuid().ToString('N');$request=Join-Path $Paths.requests ($id+'.request.json');$response=Join-Path $Paths.responses ($id+'.response.json')
    $watch=[Diagnostics.Stopwatch]::StartNew();$published=$false
    try {
        Write-AmbientNativeJson $request @{protocolVersion=2;id=$id;bridgeInstanceId=$endpoint.instanceId;expiresAt=((Get-AmbientControlNow)+$TimeoutMilliseconds);origin=$Origin;packet=$Packet}
        $published=$true
        while($watch.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
            if([IO.File]::Exists($response)) {
                $reply=Read-AmbientNativeJson $response 32768
                if($reply -isnot [pscustomobject] -or $reply.protocolVersion -ne 2 -or $reply.id -cne $id -or $reply.bridgeInstanceId -cne $endpoint.instanceId -or $reply.result -isnot [pscustomobject]){throw [IO.InvalidDataException]::new('Native response invalid')}
                if($watch.ElapsedMilliseconds -ge $TimeoutMilliseconds){throw [TimeoutException]::new('Native Bridge request timed out')}
                return $reply.result
            }
            Start-Sleep -Milliseconds 10
        }
        throw [TimeoutException]::new('Native Bridge request timed out')
    } finally {
        # These names were generated by this call under the verified private root.
        # No retry of the command: a lost reply can mean the command was applied.
        if($published){foreach($file in @($request,$response)){try{if([IO.File]::Exists($file)){[IO.File]::Delete($file)}}catch{}}}
    }
}
function Receive-AmbientNativeMailbox($Paths,$Endpoint) {
    foreach($path in @([IO.Directory]::GetFiles($Paths.requests,'*.request.json')|Sort-Object)) {
        $name=[IO.Path]::GetFileName($path)
        if($name -cnotmatch '^([a-f0-9]{32})\.request\.json$'){continue}
        $id=$matches[1]
        try {
            $job=Read-AmbientNativeJson $path
            $now=Get-AmbientControlNow
            if($job -isnot [pscustomobject] -or $job.protocolVersion -ne 2 -or $job.id -cne $id -or $job.bridgeInstanceId -cne $Endpoint.instanceId -or
                ($job.expiresAt -isnot [long] -and $job.expiresAt -isnot [int]) -or $job.expiresAt -le $now -or $job.expiresAt-$now -gt 1000 -or
                $job.origin -cnotmatch '^chrome-extension://[a-p]{32}$' -or $job.packet -isnot [pscustomobject] -or
                $job.packet.PSObject.Properties.Name -contains 'token'){throw [IO.InvalidDataException]::new('Native mailbox request invalid')}
            return @{id=$id;packet=$job.packet;origin=$job.origin;path=$path;expiresAt=$job.expiresAt}
        } catch [IO.IOException] {continue}
        catch {try{[IO.File]::Delete($path)}catch{}}
    }
    return $null
}
function Complete-AmbientNativeMailbox($Paths,$Endpoint,$Job,$Result) {
    if(-not (Test-AmbientNativeId $Job.id)){throw [IO.InvalidDataException]::new('Native mailbox ID invalid')}
    $expected=Join-Path $Paths.requests ($Job.id+'.request.json')
    if($Job.path -cne $expected){throw [IO.InvalidDataException]::new('Native mailbox path invalid')}
    try {Write-AmbientNativeJson (Join-Path $Paths.responses ($Job.id+'.response.json')) @{protocolVersion=2;id=$Job.id;bridgeInstanceId=$Endpoint.instanceId;result=$Result} 32768}
    finally {try{if([IO.File]::Exists($expected)){[IO.File]::Delete($expected)}}catch{}}
}
function Remove-AmbientNativeOrphans($Paths,[ValidateRange(0,3600)][int]$MaximumAgeSeconds=12) {
    foreach($folder in @($Paths.requests,$Paths.responses)) {
        if(-not [IO.Directory]::Exists($folder)){continue}
        foreach($path in [IO.Directory]::GetFiles($folder)) {
            if([IO.Path]::GetFileName($path) -cnotmatch '^[a-f0-9]{32}\.(?:request|response)\.json(?:\.(?:[a-f0-9]{8}|[a-f0-9]{32})\.tmp)?$'){continue}
            try{if(([DateTime]::UtcNow-[IO.File]::GetLastWriteTimeUtc($path)).TotalSeconds -gt $MaximumAgeSeconds){[IO.File]::Delete($path)}}catch{}
        }
    }
}
