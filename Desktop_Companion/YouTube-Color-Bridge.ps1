# Native Messaging private mailbox RGB/JPEG receiver. No TCP listener or HTTP fallback.
param([int]$Port=38941,[int]$ParentProcessId=0,[long]$ParentStartTicks=0,[switch]$PerformanceMetrics,[ValidateSet(0,5,10)][int]$ExperimentalVideoFps=0)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'File-Security.ps1')
Assert-AmbientInstallSecurity $PSScriptRoot
. (Join-Path $PSScriptRoot 'Lifecycle.ps1')
. (Join-Path $PSScriptRoot 'Native-Mailbox.ps1')
. (Join-Path $PSScriptRoot 'Control-Channel.ps1')
$instanceLease = Enter-AmbientInstance ('Local\AmbientWorkspace.Bridge.' + $Port)
$nativePaths = Initialize-AmbientNativeMailbox $PSScriptRoot
$snapshotPath = Join-Path $PSScriptRoot 'bridge-colors.json'
$framePath = Join-Path $PSScriptRoot 'bridge-video.jpg'
$frameMetaPath = Join-Path $PSScriptRoot 'bridge-video.json'
$lastCleanup = [DateTime]::MinValue
$logPath = Join-Path $PSScriptRoot 'bridge-log.txt'
$pipeline=$null;$browserMetrics=$null;$nextMetricsUtc=[DateTime]::MinValue
$metricsPath=Join-Path $PSScriptRoot 'bridge-metrics.json'
if ($PerformanceMetrics) { . (Join-Path $PSScriptRoot 'Frame-Metrics.ps1');$pipeline=New-AmbientPipeline -Names @('received','receiveGap','saved','saveGap','request','requestError') }
$selfProcess=[Diagnostics.Process]::GetCurrentProcess()
try { $startTicks=$selfProcess.StartTime.ToUniversalTime().Ticks } finally { $selfProcess.Dispose() }
function Log([string]$line) {
    try {
        if ([IO.File]::Exists($logPath) -and (Get-Item -LiteralPath $logPath).Length -gt 1048576) { [IO.File]::WriteAllText($logPath,'') }
        Add-Content -LiteralPath $logPath -Value ((Get-Date -Format 'HH:mm:ss') + ' | ' + $line) -Encoding UTF8
    } catch {}
}
$nativeEndpoint=$null
try {
    Remove-AmbientRuntimeFiles $PSScriptRoot -IncludeSnapshots
    Remove-AmbientNativeOrphans $nativePaths
    $lastCleanup=[DateTime]::UtcNow
    $nativeEndpoint=New-AmbientNativeEndpoint $nativePaths
    Log 'Native Bridge ready'
    while ($true) {
        if ($ParentProcessId -gt 0) {
            try {
                $parent=[Diagnostics.Process]::GetProcessById($ParentProcessId)
                try { if ($ParentStartTicks -gt 0 -and $parent.StartTime.ToUniversalTime().Ticks -ne $ParentStartTicks) { break } }
                finally { $parent.Dispose() }
            } catch { break }
        }
        if (([DateTime]::UtcNow - $lastCleanup).TotalSeconds -ge 3) {
            Remove-AmbientRuntimeFiles $PSScriptRoot -MaxAgeSeconds 12
            Remove-AmbientNativeOrphans $nativePaths
            $lastCleanup=[DateTime]::UtcNow
        }
        if ($PerformanceMetrics -and [DateTime]::UtcNow -ge $nextMetricsUtc) {
            $nextMetricsUtc=[DateTime]::UtcNow.AddSeconds(2)
            try { Write-AmbientBridgeMetrics $metricsPath $pipeline $browserMetrics $PID $startTicks } catch { Log ('Metrics error: '+(Format-AmbientSafeError $_)) }
        }
        $clock=[Diagnostics.Stopwatch]::StartNew()
        $job=Receive-AmbientNativeMailbox $nativePaths $nativeEndpoint
        if ($null -eq $job) { Start-Sleep -Milliseconds $(if($ExperimentalVideoFps -eq 10){20}else{110}); continue }
        $status='200 OK';$response='{"ok":false}';$packetFailure='invalid';$readMs=$clock.Elapsed.TotalMilliseconds
        try {
            $origin=$job.origin;$packet=$job.packet
            if ($packet.PSObject.Properties.Name -cnotcontains 'type' -or $packet.type -isnot [string]) { throw [IO.InvalidDataException]::new('Invalid packet') }
            if ((Get-AmbientControlNow) -ge $job.expiresAt) { throw [TimeoutException]::new('Native request expired') }
            $packetJson=$packet|ConvertTo-Json -Compress -Depth 12
            $response = if($PerformanceMetrics -or $ExperimentalVideoFps -gt 0){@{ok=$true;diagnostics=[bool]$PerformanceMetrics;experimentalVideoFps=$ExperimentalVideoFps}|ConvertTo-Json -Compress}else{'{"ok":true}'}
            if ([string]$packet.type -eq 'colors' -and $packet.colors.Count -eq 2) {
                $valid = $true; $hex = @()
                foreach ($side in $packet.colors) {
                    if ($side.Count -ne 3) { $valid=$false;break }
                    $components = @()
                    foreach ($part in $side) {
                        if ($part -isnot [int] -and $part -isnot [long]) { $valid=$false;break }
                        if ($part -lt 0 -or $part -gt 255) { $valid=$false;break }
                        $components += [int]$part
                    }
                    if (-not $valid) { break }
                    $hex += ('#{0:X2}{1:X2}{2:X2}' -f $components[0],$components[1],$components[2])
                }
                if ($valid -and $hex.Count -eq 2) {
                    $state = @{ utc=[DateTime]::UtcNow.ToString('o'); left=$hex[0];right=$hex[1] } | ConvertTo-Json -Compress
                    $tmp = $snapshotPath+'.tmp'
                    try {
                        [System.IO.File]::WriteAllText($tmp,$state,[System.Text.UTF8Encoding]::new($false))
                        # PS 5.1 coerces $null to an empty string here; pass a real .NET null backup name.
                        if ([IO.File]::Exists($snapshotPath)) { [IO.File]::Replace($tmp,$snapshotPath,[NullString]::Value) }
                        else { [IO.File]::Move($tmp,$snapshotPath) }
                    } finally { if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) } }
                } else { $status='400 Bad Request'; $response='{"ok":false}' }
            } elseif ([string]$packet.type -eq 'frame') {
                if ($PerformanceMetrics) {
                    Add-AmbientStage $pipeline 'received' $readMs
                    Add-AmbientGap $pipeline 'receiveGap'
                    if ($packet.PSObject.Properties.Name -contains 'diagnostics') { $browserMetrics=ConvertTo-AmbientBrowserMetrics $packet.diagnostics } else { $browserMetrics=$null }
                }
                $saveAt=$clock.Elapsed.TotalMilliseconds
                $encoded = [string]$packet.jpeg
                if ($encoded.Length -gt 0 -and $encoded.Length -le 120000 -and $encoded -match '^[A-Za-z0-9+/=]+$') {
                    $data = [Convert]::FromBase64String($encoded)
                    if ($data.Length -ge 120 -and $data.Length -le 90000 -and $data[0] -eq 255 -and $data[1] -eq 216 -and $data[2] -eq 255) {
                        # Avoid replacing the same JPG: Windows Explorer, preview tools and WPF can hold a file handle.
                        # Each capture gets a unique, immutable file. The viewer chooses the newest frame.
                        $newName = 'bridge-frame-' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmssfff') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8) + '.jpg'
                        $newFrame = Join-Path $PSScriptRoot $newName
                        $tmpFrame = $newFrame + '.tmp'
                        try {
                            [System.IO.File]::WriteAllBytes($tmpFrame, $data)
                            [System.IO.File]::Move($tmpFrame, $newFrame)
                            if ($PerformanceMetrics) { Add-AmbientStage $pipeline 'saved' ($clock.Elapsed.TotalMilliseconds-$saveAt);Add-AmbientGap $pipeline 'saveGap' }
                        } finally { if ([IO.File]::Exists($tmpFrame)) { [IO.File]::Delete($tmpFrame) } }
                    } else { $status='400 Bad Request' }
                } else { $status='400 Bad Request' }
            } elseif ([string]$packet.type -clike 'control.*') {
                $response=if ([Text.Encoding]::UTF8.GetByteCount($packetJson) -gt 4096) { '{"ok":false,"status":"invalid"}' }
                    else { Invoke-AmbientBridgeControl $packet $PSScriptRoot $origin | ConvertTo-Json -Compress -Depth 8 }
            } elseif ([string]$packet.type -ne 'ping') { $status='400 Bad Request' }
        } catch {
            $status='400 Bad Request';$response='{"ok":false}'
            $cause=$_.Exception;while($null -ne $cause.InnerException){$cause=$cause.InnerException}
            if(($cause -is [IO.IOException] -and $cause -isnot [IO.InvalidDataException]) -or $cause -is [UnauthorizedAccessException]){$packetFailure='writeFailed'}
            Log ('Packet processing error: '+(Format-AmbientSafeError $_))
        }
        try {
            if ($status -ne '200 OK') { $response=@{ok=$false;status=$packetFailure}|ConvertTo-Json -Compress }
            Complete-AmbientNativeMailbox $nativePaths $nativeEndpoint $job ($response|ConvertFrom-Json)
        } catch { Log ('Native reply error: '+(Format-AmbientSafeError $_)) }
        finally {
            if ($PerformanceMetrics) {
                Add-AmbientStage $pipeline 'request' $clock.Elapsed.TotalMilliseconds
                if ($status -ne '200 OK') { Add-AmbientStage $pipeline 'requestError' }
            }
            $clock.Stop()
        }
    }
} catch { Log ('FATAL native Bridge error: '+(Format-AmbientSafeError $_)) }
finally {
    if ($null -ne $nativeEndpoint) {
        $current=Get-AmbientNativeEndpoint $nativePaths
        if ($null -ne $current -and $current.instanceId -ceq $nativeEndpoint.instanceId) { try { [IO.File]::Delete($nativePaths.endpoint) } catch {} }
    }
    if ($lastCleanup -ne [DateTime]::MinValue) { Remove-AmbientRuntimeFiles $PSScriptRoot -IncludeSnapshots }
    if ($PerformanceMetrics) { foreach($file in @($metricsPath,($metricsPath+'.tmp'))) { try { if([IO.File]::Exists($file)){[IO.File]::Delete($file)} } catch {} } }
    Exit-AmbientInstance $instanceLease
    Log 'Native Bridge stopped'
}
