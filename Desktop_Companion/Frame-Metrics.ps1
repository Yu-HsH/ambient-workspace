# Opt-in numeric telemetry. No image bytes, pairing, app titles or URLs.
function Write-AmbientFrameMetrics([string]$Path,$VideoState,[int]$ProcessId,[long]$ProcessStartTicks) {
    $now=[DateTime]::UtcNow
    $recent=@($VideoState.frameTimes.ToArray() | Where-Object { ($now-$_).TotalSeconds -le 10 })
    # A fixed window includes stalls after the last frame (the old event-span estimate did not).
    $fps=[Math]::Round($recent.Count/10.0,3)
    $sample=[ordered]@{
        schema=1; utc=$now.ToString('o'); processId=$ProcessId; processStartTicks=$ProcessStartTicks.ToString()
        sourceUpdatesTotal=$VideoState.frameCount; sourceUpdatesLast10Seconds=$recent.Count; estimatedDeliveredFps=$fps
        lastFrameUtc=$(if($VideoState.lastFrameUtc -eq [DateTime]::MinValue){$null}else{$VideoState.lastFrameUtc.ToString('o')})
        videoEnabled=$VideoState.enabled; videoActive=$VideoState.active
    }
    if ($VideoState.PSObject.Properties.Name -contains 'pipeline' -and $null -ne $VideoState.pipeline) { $sample.pipeline=Get-AmbientPipelineSnapshot $VideoState.pipeline }
    $temporary=$Path+'.tmp'
    try {
        [IO.File]::WriteAllText($temporary,($sample | ConvertTo-Json -Depth 8 -Compress),[Text.UTF8Encoding]::new($false))
        # Keep atomic replacement without a backup; PS 5.1 needs NullString instead of $null.
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary,$Path,[NullString]::Value) }
        else { [IO.File]::Move($temporary,$Path) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function New-AmbientPipeline([string[]]$Names=@()) {
    $stages=@{};foreach($name in $Names){$stages[$name]=@{count=0L;totalMs=0.0;maxMs=0.0}}
    return [pscustomobject]@{ clock=[Diagnostics.Stopwatch]::StartNew(); lastPollMs=-1.0; stages=$stages;marks=@{} }
}
function Add-AmbientGap($Pipeline,[string]$Name) {
    if ($null -eq $Pipeline) { return }
    $now=$Pipeline.clock.Elapsed.TotalMilliseconds
    if($Pipeline.marks.ContainsKey($Name)){Add-AmbientStage $Pipeline $Name ($now-$Pipeline.marks[$Name])}
    $Pipeline.marks[$Name]=$now
}
function Add-AmbientStage($Pipeline,[string]$Name,[double]$Milliseconds=0) {
    if ($null -eq $Pipeline) { return }
    if (-not $Pipeline.stages.ContainsKey($Name)) { $Pipeline.stages[$Name]=@{count=0L;totalMs=0.0;maxMs=0.0} }
    $entry=$Pipeline.stages[$Name];$entry.count++;$entry.totalMs+=$Milliseconds;$entry.maxMs=[Math]::Max($entry.maxMs,$Milliseconds)
}
function Get-AmbientPipelineSnapshot($Pipeline) {
    return @{elapsedMs=$Pipeline.clock.Elapsed.TotalMilliseconds;stages=$Pipeline.stages}
}
# Only allow bounded numbers and known enum values across the localhost diagnostics boundary.
function ConvertTo-AmbientBrowserMetrics($Value) {
    try {
        if ($Value.mode -notin @('eco','balanced','quality')) { return $null }
        $safe=@{mode=[string]$Value.mode;stages=@{}}
        if ($Value.PSObject.Properties.Name -contains 'targetFps') {
            if ($Value.targetFps -notin @(1,2,4,5,10) -or ($Value.targetFps -isnot [int] -and $Value.targetFps -isnot [long] -and $Value.targetFps -isnot [double])) { return $null }
            $safe.targetFps=$Value.targetFps
        }
        foreach($key in @('epoch','elapsedMs','utcMs','decodedFrames','droppedFrames')) {
            $number=$Value.$key
            if ($null -eq $number -and $key -in @('decodedFrames','droppedFrames')) { $safe[$key]=$null;continue }
            if (($number -isnot [int] -and $number -isnot [long] -and $number -isnot [double] -and $number -isnot [decimal]) -or [double]::IsNaN([double]$number) -or [double]::IsInfinity([double]$number) -or $number -lt 0 -or $number -gt 1e16) { return $null }
            $safe[$key]=$number
        }
        foreach($name in @('tick','tickGap','captureCopy','desktopCopy','desktopGap','jpeg','postAttempt','http','ack','frameError','busySkipped','webp','fanout','webError','captureNotReady','tickError')) {
            if ($Value.stages.PSObject.Properties.Name -notcontains $name) { continue }
            $safe.stages[$name]=@{}
            foreach($key in @('count','totalMs','maxMs')) {
                $number=$Value.stages.$name.$key
                if (($number -isnot [int] -and $number -isnot [long] -and $number -isnot [double] -and $number -isnot [decimal]) -or [double]::IsNaN([double]$number) -or [double]::IsInfinity([double]$number) -or $number -lt 0 -or $number -gt 1e16) { return $null }
                $safe.stages[$name][$key]=$number
            }
        }
        return $safe
    } catch { return $null }
}
function Write-AmbientBridgeMetrics([string]$Path,$Pipeline,$Browser,[int]$ProcessId,[long]$StartTicks) {
    $sample=@{schema=1;utc=[DateTime]::UtcNow.ToString('o');processId=$ProcessId;processStartTicks=$StartTicks.ToString();pipeline=(Get-AmbientPipelineSnapshot $Pipeline);browser=$Browser}
    $temporary=$Path+'.tmp'
    try {
        [IO.File]::WriteAllText($temporary,($sample | ConvertTo-Json -Depth 8 -Compress),[Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary,$Path,[NullString]::Value) }
        else { [IO.File]::Move($temporary,$Path) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}
