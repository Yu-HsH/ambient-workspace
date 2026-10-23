# Shared lifecycle helpers. No UI, installation, pairing values or network requests here.
function Format-AmbientSafeError([System.Management.Automation.ErrorRecord]$Record) {
    # Never emit Message, source text, raw stack traces, request values or absolute paths.
    $types=[Collections.Generic.List[string]]::new()
    $exception=$Record.Exception
    while ($null -ne $exception -and $types.Count -lt 8) {
        $types.Add(($exception.GetType().FullName+'('+ $exception.HResult +')'))
        $exception=$exception.InnerException
    }
    $file='unknown';$line=0;$function='unknown'
    $allowed='^(YouTube-Color-Bridge|Bridge-Http|Frame-Metrics|Start-AmbientDesktop|Lifecycle)\.ps1$'
    $candidate=[IO.Path]::GetFileName($Record.InvocationInfo.ScriptName)
    if ([regex]::IsMatch($candidate,$allowed)) {
        $file=$candidate;$line=$Record.InvocationInfo.ScriptLineNumber;$function='<ScriptBlock>'
    }
    foreach ($frame in ($Record.ScriptStackTrace -split '\r?\n')) {
        if ($frame -match '^at ([A-Za-z][A-Za-z0-9-]*|<ScriptBlock>), (.+): line ([0-9]+)$') {
            $candidate=[IO.Path]::GetFileName($matches[2])
            if ([regex]::IsMatch($candidate,$allowed)) {
                $file=$candidate;$function=$matches[1];$line=[int]$matches[3];break
            }
        }
    }
    return ('file='+$file+' line='+$line+' function='+$function+' exceptions='+($types -join ' -> '))
}
function Write-AmbientDesktopLog([string]$Path,[string]$Message) {
    # Best effort only: logging must never interrupt a Desktop/Dispatcher action.
    $stream=$null; $mutex=$null; $owned=$false
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { return }
        $fullPath=[IO.Path]::GetFullPath($Path)
        # This helper may rotate only the Desktop diagnostic log, never settings/pairing/control.
        if ([IO.Path]::GetFileName($fullPath) -ine 'diagnostic-log.txt') { return }
        $backup=$fullPath+'.1'; $limit=1048576
        $encoding=[Text.UTF8Encoding]::new($true)
        # Callers use safe exception metadata. Also redact the pairing format defensively.
        $safe=[regex]::Replace($Message,'(?i)(?<![0-9a-f])[0-9a-f]{64}(?![0-9a-f])','[redacted]')
        $entry=$encoding.GetBytes($safe+[Environment]::NewLine)
        if ($entry.Length -gt $limit-$encoding.GetPreamble().Length) { return }
        $sha=[Security.Cryptography.SHA256]::Create()
        try { $key=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($fullPath.ToUpperInvariant()))).Replace('-','') }
        finally { $sha.Dispose() }
        $mutex=[Threading.Mutex]::new($false,('Local\AmbientWorkspace.DesktopLog.'+$key))
        try { $owned=$mutex.WaitOne(100) } catch [Threading.AbandonedMutexException] { $owned=$true }
        if (-not $owned) { return }
        foreach ($file in @($fullPath,$backup)) {
            if ([IO.File]::Exists($file) -and ([IO.File]::GetAttributes($file) -band [IO.FileAttributes]::ReparsePoint)) { return }
        }
        $stream=[IO.File]::Open($fullPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
        if ($stream.Length -gt 0 -and ($stream.Length -ge $limit -or $stream.Length+$entry.Length -gt $limit)) {
            $stream.Dispose(); $stream=$null
            # Rename/replace atomically. Never pre-delete a log or its previous backup.
            if ([IO.File]::Exists($backup)) { [IO.File]::Replace($fullPath,$backup,[NullString]::Value,$true) }
            else { [IO.File]::Move($fullPath,$backup) }
            $stream=[IO.File]::Open($fullPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
        }
        [void]$stream.Seek(0,[IO.SeekOrigin]::End)
        if ($stream.Length -eq 0) { $preamble=$encoding.GetPreamble(); $stream.Write($preamble,0,$preamble.Length) }
        $stream.Write($entry,0,$entry.Length)
    } catch {
        # Locked files, denied access and failed rotation leave application state untouched.
    } finally {
        if ($null -ne $stream) { try { $stream.Dispose() } catch {} }
        if ($null -ne $mutex) {
            if ($owned) { try { $mutex.ReleaseMutex() } catch {} }
            try { $mutex.Dispose() } catch {}
        }
    }
}
function Enter-AmbientInstance([string]$Name) {
    $mutex = [Threading.Mutex]::new($false, $Name)
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) {
            $instanceError=[InvalidOperationException]::new('Ambient Workspace is already running. Exit the existing instance from its tray first.')
            $instanceError.Data['AmbientAlreadyRunning']=$true
            throw $instanceError
        }
        return [pscustomobject]@{ mutex=$mutex; owned=$true }
    } catch { $mutex.Dispose(); throw }
}
function Exit-AmbientInstance($Lease) {
    if ($null -ne $Lease -and $Lease.owned) {
        $Lease.owned = $false
        try { $Lease.mutex.ReleaseMutex() } finally { $Lease.mutex.Dispose() }
    }
}
function Remove-AmbientRuntimeFiles([string]$Directory, [int]$MaxAgeSeconds=0, [switch]$IncludeSnapshots) {
    $cutoff = [DateTime]::UtcNow.AddSeconds(-$MaxAgeSeconds)
    Get-ChildItem -LiteralPath $Directory -File -ErrorAction SilentlyContinue | Where-Object {
        $frame = $_.Name -match '^bridge-frame-[a-zA-Z0-9-]+\.jpg(\.tmp)?$'
        $snapshot = $IncludeSnapshots -and $_.Name -match '^bridge-(colors\.json|video\.(jpg|json)|metrics\.json)(\.tmp)?$'
        ($frame -or $snapshot) -and ($MaxAgeSeconds -eq 0 -or $_.LastWriteTimeUtc -lt $cutoff)
    } | ForEach-Object { try { [IO.File]::Delete($_.FullName) } catch {} }
}
function Ensure-AmbientBridge($State, [string]$Runner, [int]$Port, [int]$ParentId, [long]$ParentStartTicks, [string]$PowerShellPath, [bool]$PerformanceMetrics=$false, [ValidateSet(0,5,10)][int]$ExperimentalVideoFps=0) {
    if ($State.stopping) { return }
    if ($null -ne $State.process) {
        if (-not $State.process.HasExited) {
            if (([DateTime]::UtcNow - $State.startedUtc).TotalSeconds -gt 30) { $State.failures=0 }
            return
        }
        $State.process.Dispose(); $State.process=$null
        $State.status='retrying; check bridge-log.txt or port availability'
    }
    if ([DateTime]::UtcNow -lt $State.nextStartUtc) { return }
    $State.failures++
    $delay = [Math]::Min(30, [Math]::Pow(2, [Math]::Min(5,$State.failures)))
    $State.nextStartUtc=[DateTime]::UtcNow.AddSeconds($delay)
    try {
        # Pairing secrets are read from a local file, never command-line arguments.
        $arguments=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"'+$Runner+'"'),'-Port',([string]$Port),'-ParentProcessId',([string]$ParentId),'-ParentStartTicks',([string]$ParentStartTicks))
        if ($PerformanceMetrics) { $arguments+='-PerformanceMetrics' }
        if ($ExperimentalVideoFps -gt 0) { $arguments+=@('-ExperimentalVideoFps',([string]$ExperimentalVideoFps)) }
        $State.process=Start-Process -FilePath $PowerShellPath -ArgumentList $arguments -WindowStyle Hidden -PassThru
        $State.startedUtc=[DateTime]::UtcNow; $State.status='waiting for colors'
    } catch { $State.status='start failed; retrying (check PowerShell and bridge files)' }
}
function Stop-AmbientBridge($State) {
    $State.stopping=$true
    if ($null -ne $State.process) {
        try {
            if (-not $State.process.HasExited) { $State.process.Kill(); [void]$State.process.WaitForExit(1500) }
        } finally { $State.process.Dispose(); $State.process=$null }
    }
}
function Invoke-AmbientCleanup([scriptblock[]]$Actions) {
    # One disposed/failed resource must not prevent the remaining resources from closing.
    foreach ($action in $Actions) { try { & $action } catch {} }
}
function Save-AmbientSettings($Config,[string]$ConfigPath) {
    $temporary=$ConfigPath+'.tmp'
    try {
        $serialized=$Config | ConvertTo-Json -Depth 12
        [IO.File]::WriteAllText($temporary,$serialized,[Text.UTF8Encoding]::new($true))
        if ([IO.File]::Exists($ConfigPath)) { [IO.File]::Replace($temporary,$ConfigPath,($ConfigPath+'.bak'),$true) }
        else { [IO.File]::Move($temporary,$ConfigPath) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}
