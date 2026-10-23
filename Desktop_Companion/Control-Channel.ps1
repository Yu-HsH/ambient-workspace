# Desktop-owned snapshots and Bridge-owned single request slot. No renderer/Chrome calls.
function Get-AmbientIntegrationPresentation($Client,$Control,[string]$InstanceId,[long]$Now=(Get-AmbientControlNow)) {
    $parts=@{desktop='applied';web='waiting';youtube='waiting';capture='waiting'}
    $status='waiting'
    # A capture-free, entirely OFF/absent Chrome uses the existing one-minute MV3 alarm.
    # It has no active output to acknowledge at the one-second capture cadence.
    $freshness=5000
    if ($null -ne $Client -and @(@('web','youtube','capture') | Where-Object { $Client.parts.$_ -cnotin @('off','notRequired') }).Count -eq 0) { $freshness=75000 }
    if (-not $Control.config.desktopOutput.enabled -or (-not $Control.config.desktopOutput.rgbEnabled -and -not $Control.config.desktopOutput.videoEnabled)) { $parts.desktop='off' }
    if ($Control.savePending) { $status='saveFailed' }
    elseif ($null -ne $Client -and $Client.instanceId -ceq $InstanceId -and $Client.revision -eq $Control.revision -and $Now-$Client.utcMs -gt $freshness) { $status='error' }
    elseif ($null -ne $Client -and $Client.instanceId -ceq $InstanceId -and $Client.revision -eq $Control.revision -and $Client.globalPaused -eq $Control.config.control.globalPaused -and $Now-$Client.utcMs -ge 0 -and $Now-$Client.utcMs -le $freshness) {
        foreach ($key in @('web','youtube','capture')) { $parts[$key]=[string]$Client.parts.$key }
        $pending=@($parts.Values | Where-Object { $_ -cnotin @('applied','off','notRequired') }).Count
        $status=if ($pending) { 'partial' } else { 'complete' }
    }
    $phase=if ($Control.config.control.globalPaused) { '일시정지' } else { '재개' }
    $title=switch ($status) { 'complete' { '전체 '+$phase+' 적용 완료' }; 'partial' { '일부 적용 · Chrome 확인 중' }; 'saveFailed' { '저장 실패 · 현재 상태 확인 필요' }; 'error' { 'Chrome 통신 끊김 · 전체 적용 여부 미확인' }; default { 'Desktop 적용 · Chrome 적용 확인 대기' } }
    return @{status=$status;title=$title;parts=$parts;phase=$phase}
}
function Get-AmbientControlPaths([string]$Directory) {
    $root=[IO.Path]::GetFullPath($Directory)
    return @{request=(Join-Path $root 'control-request.json');state=(Join-Path $root 'control-state.json');health=(Join-Path $root 'control-health.json');lease=(Join-Path $root 'control-lease.json');client=(Join-Path $root 'control-client.json')}
}
function Get-AmbientControlNow { return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
function Read-AmbientControlJson([string]$Path) {
    # Windows replacement can briefly report not-found/sharing at the reader boundary.
    # Retry only those transient reads, for at most 20ms. Never replay a command.
    for ($attempt=0; $attempt -lt 3; $attempt++) {
        $stream=$null
        try {
            $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            if ($stream.Length -gt 32768) { throw [IO.InvalidDataException]::new('Control file too large') }
            $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8)
            try { return ($reader.ReadToEnd() | ConvertFrom-Json) } finally { $reader.Dispose() }
        } catch {
            $cause=$_.Exception
            while ($null -ne $cause.InnerException) { $cause=$cause.InnerException }
            if ($cause -is [IO.FileNotFoundException]) { if ($attempt -eq 2) { return $null } }
            elseif ($cause -isnot [IO.IOException] -or ($cause.HResult -band 65535) -notin @(32,33) -or $attempt -eq 2) { throw }
        } finally { if ($null -ne $stream) { $stream.Dispose() } }
        Start-Sleep -Milliseconds 10
    }
}
function Write-AmbientControlJson([string]$Path,$Value) {
    $temporary=$Path+'.tmp'
    try {
        $json=$Value | ConvertTo-Json -Depth 8 -Compress
        if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 32768) { throw [IO.InvalidDataException]::new('Control file too large') }
        [IO.File]::WriteAllText($temporary,$json,[Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary,$Path,[NullString]::Value) }
        else { [IO.File]::Move($temporary,$Path) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}
function Read-AmbientPublishedControl($Paths) {
    # State and health are individually atomic, not a two-file transaction.
    # A healthy old health record can precede the next state record. Retry only
    # that version/instance gap, within 20ms; never hide a failed publication.
    for ($attempt=0; $attempt -lt 3; $attempt++) {
        $health=Read-AmbientControlJson $Paths.health
        $state=Read-AmbientControlJson $Paths.state
        if ($null -eq $health -or $null -eq $state -or -not $health.healthy -or
            ($state.instanceId -ceq $health.instanceId -and $state.version -eq $health.version)) {
            return @{health=$health;state=$state}
        }
        if ($attempt -lt 2) { Start-Sleep -Milliseconds 10 }
    }
    return @{health=$health;state=$state}
}
function Test-AmbientControlInteger($Value) { return ($Value -is [int] -or $Value -is [long]) }
function Test-AmbientControlCommand($Command) {
    if ($null -eq $Command -or $Command -isnot [pscustomobject]) { return $false }
    foreach ($key in @('requestId','expectedInstanceId','expectedRevision','globalPaused','expiresAt')) {
        if ($Command.PSObject.Properties.Name -cnotcontains $key) { return $false }
    }
    return ($Command.requestId -is [string] -and $Command.requestId -cmatch '^[a-f0-9]{32}$' -and
        $Command.expectedInstanceId -is [string] -and $Command.expectedInstanceId -cmatch '^[a-f0-9]{32}$' -and
        (Test-AmbientControlInteger $Command.expectedRevision) -and $Command.expectedRevision -ge 0 -and
        $Command.globalPaused -is [bool] -and (Test-AmbientControlInteger $Command.expiresAt))
}
function Test-AmbientControlSameCommand($A,$B) {
    return ($A.requestId -ceq $B.requestId -and $A.expectedInstanceId -ceq $B.expectedInstanceId -and
        $A.expectedRevision -eq $B.expectedRevision -and $A.globalPaused -eq $B.globalPaused)
}
function Test-AmbientControlOwner($State) {
    $process=$null
    try {
        $process=[Diagnostics.Process]::GetProcessById($State.ownerPid)
        return ($process.StartTime.ToUniversalTime().Ticks -eq $State.ownerStartTicks)
    } catch { return $false } finally { if ($process) { $process.Dispose() } }
}
function Get-AmbientControlAuthority([string]$Origin,$State,$Packet,[string]$Path) {
    # Bridge's instance mutex serializes lease and mailbox writes. No early takeover/release:
    # each accepted command expires no later than its granting lease, including across restart.
    $now=Get-AmbientControlNow
    $lease=Read-AmbientControlJson $Path
    $active=($null -ne $lease -and $lease.instanceId -ceq $State.instanceId -and $lease.expiresAt -gt $now)
    $hasProfile=$Packet.PSObject.Properties.Name -ccontains 'profileId'
    $hasLease=$Packet.PSObject.Properties.Name -ccontains 'leaseId'
    if (($hasProfile -and ($Packet.profileId -isnot [string] -or $Packet.profileId -cnotmatch '^[a-f0-9]{32}$')) -or
        ($hasLease -and ($Packet.leaseId -isnot [string] -or $Packet.leaseId -cnotmatch '^[a-f0-9]{32}$'))) { return @{allowed=$false;status='invalid'} }
    if (-not $hasProfile) {
        if ($Packet.type -cin @('control.set','control.applied') -or $hasLease) { return @{allowed=$false;status='leaseRequired'} }
        return @{allowed=$true;lease=$null}
    }
    if ($active) {
        if ($lease.origin -cne $Origin -or $lease.profileId -cne $Packet.profileId -or -not $hasLease -or $lease.leaseId -cne $Packet.leaseId) {
            return @{allowed=$false;status='leaseConflict'}
        }
    } elseif ($Packet.type -ceq 'control.hello') {
        $lease=[pscustomobject]@{instanceId=$State.instanceId;origin=$Origin;profileId=$Packet.profileId;leaseId=[Guid]::NewGuid().ToString('N');expiresAt=[long]0}
    } else { return @{allowed=$false;status='leaseExpired'} }
    # Renew only authenticated hello/query, never a write command.
    if ($Packet.type -cin @('control.hello','control.query')) {
        $lease.expiresAt=$now+90000
        Write-AmbientControlJson $Path $lease
    }
    return @{allowed=$true;lease=@{leaseId=$lease.leaseId;expiresAt=$lease.expiresAt;instanceId=$lease.instanceId}}
}
function Invoke-AmbientBridgeControl($Packet,[string]$Directory,[string]$Origin) {
    # Called only after the unchanged Bridge Origin/token authentication.
    try {
        if ($Packet.type -isnot [string] -or [Text.Encoding]::UTF8.GetByteCount(($Packet | ConvertTo-Json -Compress -Depth 8)) -gt 4096) {
            return @{ok=$false;status='invalid'}
        }
        $allowed=switch -CaseSensitive ($Packet.type) {
            'control.hello' { @('token','type','profileId','leaseId') }
            'control.query' { @('token','type','profileId','leaseId') }
            'control.set' { @('token','type','profileId','leaseId','requestId','expectedInstanceId','expectedRevision','globalPaused','ttlMs') }
            'control.applied' { @('token','type','profileId','leaseId','instanceId','revision','globalPaused','parts') }
            default { return @{ok=$false;status='unsupported'} }
        }
        if (@($Packet.PSObject.Properties.Name | Where-Object { $_ -cnotin $allowed }).Count) { return @{ok=$false;status='invalid'} }
        $paths=Get-AmbientControlPaths $Directory
        $published=Read-AmbientPublishedControl $paths
        $health=$published.health
        $state=$published.state
        if ($null -eq $state -or $null -eq $health) { return @{ok=$false;status='unavailable'} }
        if ($state.PSObject.Properties.Name -cnotcontains 'ownerPid' -or -not (Test-AmbientControlOwner $state)) { return @{ok=$false;status='ownerUnavailable'} }
        if ((Get-AmbientControlNow)-$state.utcMs -gt 3000 -or (Get-AmbientControlNow)-$health.utcMs -gt 3000) { return @{ok=$false;status='stale'} }
        if (-not $health.healthy -or $state.instanceId -cne $health.instanceId -or $state.version -ne $health.version) {
            return @{ok=$false;status='snapshotUnavailable'}
        }
        if ($Origin -cnotmatch '^chrome-extension://[a-p]{32}$') { return @{ok=$false;status='authorityConflict'} }
        $authority=Get-AmbientControlAuthority $Origin $state $Packet $paths.lease
        if (-not $authority.allowed) { return @{ok=$false;status=$authority.status;state=$state} }
        $reply=@{ok=$true;status='snapshot';state=$state;lease=$authority.lease}
        switch -CaseSensitive ($Packet.type) {
            'control.hello' {
                $reply.protocolVersion=1; $reply.capabilities=@('desktop-pause-control','profile-lease','integration-status')
                $reply.controlScope='desktop-effects'; $reply.profileLeaseSupported=$true
                return $reply
            }
            'control.query' { return $reply }
            'control.applied' {
                foreach ($key in @('instanceId','revision','globalPaused','parts')) {
                    if ($Packet.PSObject.Properties.Name -cnotcontains $key) { return @{ok=$false;status='invalid'} }
                }
                if ($Packet.instanceId -isnot [string] -or -not (Test-AmbientControlInteger $Packet.revision) -or $Packet.globalPaused -isnot [bool] -or $Packet.parts -isnot [pscustomobject]) { return @{ok=$false;status='invalid'} }
                if ($Packet.instanceId -cne $state.instanceId -or $Packet.revision -ne $state.revision -or $Packet.globalPaused -ne $state.globalPaused) { return @{ok=$false;status='conflict'} }
                if (@($Packet.parts.PSObject.Properties).Count -ne 4) { return @{ok=$false;status='invalid'} }
                $parts=@{}
                foreach ($key in @('desktop','web','youtube','capture')) {
                    if ($Packet.parts.PSObject.Properties.Name -cnotcontains $key -or $Packet.parts.$key -isnot [string] -or $Packet.parts.$key -cnotin @('applied','off','notRequired','waiting')) { return @{ok=$false;status='invalid'} }
                    $parts[$key]=$Packet.parts.$key
                }
                Write-AmbientControlJson $paths.client @{instanceId=$state.instanceId;revision=$state.revision;globalPaused=$state.globalPaused;parts=$parts;utcMs=(Get-AmbientControlNow);leaseId=$authority.lease.leaseId}
                return @{ok=$true;status='clientApplied'}
            }
            'control.set' {
                foreach ($key in @('requestId','expectedInstanceId','expectedRevision','globalPaused','ttlMs')) {
                    if ($Packet.PSObject.Properties.Name -cnotcontains $key) { return @{ok=$false;status='invalid'} }
                }
                $command=[pscustomobject]@{requestId=$Packet.requestId;expectedInstanceId=$Packet.expectedInstanceId;expectedRevision=$Packet.expectedRevision;globalPaused=$Packet.globalPaused;expiresAt=[long]0}
                if (-not (Test-AmbientControlCommand $command) -or -not (Test-AmbientControlInteger $Packet.ttlMs) -or $Packet.ttlMs -lt 50 -or $Packet.ttlMs -gt 2000) {
                    return @{ok=$false;status='invalid'}
                }
                if ($command.expectedInstanceId -cne $state.instanceId) { return @{ok=$false;status='instanceChanged';state=$state} }
                $prior=@($state.results | Where-Object requestId -CEQ $command.requestId)
                if ($prior.Count) {
                    if (-not (Test-AmbientControlSameCommand $command $prior[0])) { return @{ok=$false;status='idReuse'} }
                    return @{ok=$true;status='ack';ack=$prior[0];state=$state}
                }
                $pending=Read-AmbientControlJson $paths.request
                if ($null -ne $pending) {
                    if (-not (Test-AmbientControlCommand $pending)) { return @{ok=$false;status='invalidMailbox'} }
                    if ($pending.expectedInstanceId -ceq $state.instanceId -and @($state.results | Where-Object requestId -CEQ $pending.requestId).Count -eq 0) {
                        if ($pending.requestId -ceq $command.requestId) {
                            if (-not (Test-AmbientControlSameCommand $command $pending)) { return @{ok=$false;status='idReuse'} }
                            return @{ok=$true;status='accepted';requestId=$command.requestId;state=$state}
                        }
                        return @{ok=$false;status='busy';state=$state}
                    }
                }
                if ($command.expectedRevision -ne $state.revision) { return @{ok=$false;status='conflict';state=$state} }
                $command.expiresAt=[Math]::Min(((Get-AmbientControlNow)+$Packet.ttlMs),$authority.lease.expiresAt)
                Write-AmbientControlJson $paths.request $command
                return @{ok=$true;status='accepted';requestId=$command.requestId;state=$state}
            }
        }
    } catch { return @{ok=$false;status='ioError'} }
}

function New-AmbientControlSnapshot($Runtime,$Control) {
    return @{
        protocolVersion=1;instanceId=$Runtime.instanceId;ownerPid=$PID;ownerStartTicks=$Runtime.ownerStartTicks
        revision=$Control.revision;globalPaused=$Control.config.control.globalPaused;persisted=(-not $Control.savePending)
        desktopOutput=@{enabled=$Control.config.desktopOutput.enabled;rgbEnabled=$Control.config.desktopOutput.rgbEnabled;videoEnabled=$Control.config.desktopOutput.videoEnabled}
        results=@($Runtime.results);version=[long]0;utcMs=[long]0
    }
}
function Sync-AmbientControlSnapshot($Runtime,$Control) {
    if ($null -eq $Runtime) { return }
    $snapshot=New-AmbientControlSnapshot $Runtime $Control
    [Threading.Monitor]::Enter($Runtime.shared.SyncRoot)
    try {
        $Runtime.shared.version++; $snapshot.version=$Runtime.shared.version
        $Runtime.shared.desired=$snapshot
    } finally { [Threading.Monitor]::Exit($Runtime.shared.SyncRoot) }
}
function Start-AmbientControlChannel([string]$Directory,$Control) {
    $paths=Get-AmbientControlPaths $Directory
    # Called only by the Desktop instance lease owner, before its Bridge launch.
    foreach ($path in $paths.Values) { foreach ($file in @($path,($path+'.tmp'))) { try { if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) } } catch {} } }
    $self=[Diagnostics.Process]::GetCurrentProcess()
    try { $ticks=$self.StartTime.ToUniversalTime().Ticks } finally { $self.Dispose() }
    $runtime=[pscustomobject]@{instanceId=[Guid]::NewGuid().ToString('N');ownerStartTicks=$ticks;results=@();shared=[hashtable]::Synchronized(@{stopping=$false;pending=$null;client=$null;desired=$null;version=[long]0});worker=$null;job=$null}
    Sync-AmbientControlSnapshot $runtime $Control
    $worker=[PowerShell]::Create()
    [void]$worker.AddScript({
        param($Module,$Paths,$Shared)
        Set-StrictMode -Version Latest
        $ErrorActionPreference='Stop'
        . $Module
        $published=[long]-1; $nextHeartbeat=[long]0
        while (-not $Shared.stopping) {
            $now=Get-AmbientControlNow
            try {
                $desired=$Shared.desired
                if ($desired.version -ne $published -or $now -ge $nextHeartbeat) {
                    $snapshot=$desired.Clone(); $snapshot.utcMs=$now
                    try {
                        Write-AmbientControlJson $Paths.state $snapshot
                        Write-AmbientControlJson $Paths.health @{instanceId=$snapshot.instanceId;version=$snapshot.version;healthy=$true;utcMs=$now}
                        $published=$snapshot.version; $nextHeartbeat=$now+500
                    } catch {
                        try { Write-AmbientControlJson $Paths.health @{instanceId=$snapshot.instanceId;version=$snapshot.version;healthy=$false;utcMs=$now} } catch {}
                        $nextHeartbeat=0
                    }
                }
                $request=Read-AmbientControlJson $Paths.request
                try {
                    $client=Read-AmbientControlJson $Paths.client
                    $lease=Read-AmbientControlJson $Paths.lease
                    if ($null -ne $client -and $null -ne $lease -and $client.leaseId -ceq $lease.leaseId -and $lease.expiresAt -gt $now -and $client.instanceId -ceq $desired.instanceId -and $client.revision -eq $desired.revision -and $client.globalPaused -eq $desired.globalPaused) { $Shared.client=$client }
                    else { $Shared.client=$null }
                } catch { $Shared.client=$null }
                if ($null -ne $request -and (Test-AmbientControlCommand $request)) {
                    [Threading.Monitor]::Enter($Shared.SyncRoot)
                    try {
                        if ($null -eq $Shared.pending -and @($Shared.desired.results | Where-Object requestId -CEQ $request.requestId).Count -eq 0) { $Shared.pending=$request }
                    } finally { [Threading.Monitor]::Exit($Shared.SyncRoot) }
                }
            } catch { }
            Start-Sleep -Milliseconds 100
        }
    }).AddArgument((Join-Path $PSScriptRoot 'Control-Channel.ps1')).AddArgument($paths).AddArgument($runtime.shared)
    try { $runtime.job=$worker.BeginInvoke(); $runtime.worker=$worker; return $runtime }
    catch { $worker.Dispose(); throw }
}
function Complete-AmbientControlRequest($Runtime,$Control,$Request,[string]$Outcome) {
    $Runtime.results=@($Runtime.results | Select-Object -Last 15)+@([pscustomobject]@{
        requestId=$Request.requestId;expectedInstanceId=$Request.expectedInstanceId;expectedRevision=$Request.expectedRevision;globalPaused=$Request.globalPaused
        instanceId=$Runtime.instanceId;revision=$Control.revision;outcome=$Outcome;effectivePaused=$Control.config.control.globalPaused;persisted=(-not $Control.savePending)
    })
    Sync-AmbientControlSnapshot $Runtime $Control
    $Runtime.shared.pending=$null
}
function Stop-AmbientControlChannel($Runtime,[string]$Directory) {
    if ($null -eq $Runtime) { return }
    $Runtime.shared.stopping=$true
    try {
        if (-not $Runtime.job.AsyncWaitHandle.WaitOne(1500)) { $Runtime.worker.Stop() }
        [void]$Runtime.worker.EndInvoke($Runtime.job)
    } finally {
        $Runtime.worker.Dispose()
        # The Desktop lease is still held and its owned Bridge has already stopped.
        $paths=Get-AmbientControlPaths $Directory
        foreach ($path in $paths.Values) { foreach ($file in @($path,($path+'.tmp'))) { try { if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) } } catch {} } }
    }
}
