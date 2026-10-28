# Ambient Workspace Desktop 1.0.0-rc.1 — independent video protection and coverage controls, Windows PowerShell 5.1, STA required.
# This script receives opt-in video frames through the private native mailbox.
param([string]$ConfigPath = (Join-Path $PSScriptRoot 'settings.json'),[switch]$PerformanceMetrics,[ValidateSet(0,5,10)][int]$ExperimentalVideoFps=0,[switch]$PortableLaunch)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSEdition -ne 'Desktop') {
    throw 'Use Windows PowerShell 5.1 (powershell.exe), not PowerShell 7.'
}
if ([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA) {
    throw 'Start this script with powershell.exe -STA.'
}

. (Join-Path $PSScriptRoot 'File-Security.ps1')
Assert-AmbientInstallSecurity $PSScriptRoot $ConfigPath
. (Join-Path $PSScriptRoot 'Native-Mailbox.ps1')
$null=Get-AmbientNativePaths $PSScriptRoot
. (Join-Path $PSScriptRoot 'Lifecycle.ps1')
. (Join-Path $PSScriptRoot 'Control-State.ps1')
. (Join-Path $PSScriptRoot 'Global-Hotkey.ps1')
. (Join-Path $PSScriptRoot 'Control-Channel.ps1')
. (Join-Path $PSScriptRoot 'Settings-Window.ps1')
. (Join-Path $PSScriptRoot 'Frame-Metrics.ps1')
$instanceLease = Enter-AmbientInstance 'Local\AmbientWorkspace.Desktop'
$timer=$null; $videoPoll=$null; $videoRelease=$null; $tray=$null; $menu=$null
$window=$null; $videoWash=$null; $videoWashPrev=$null; $videoState=$null
$windowTick=$null; $videoTick=$null; $releaseTick=$null
$controlRuntime=$null; $controlTimer=$null; $controlTick=$null
$left=$null; $right=$null; $bottom=$null
$metricsRuntime=[pscustomobject]@{enabled=[bool]$PerformanceMetrics;path=(Join-Path $PSScriptRoot 'desktop-metrics.json');nextUtc=[DateTime]::MinValue}
$bridgeRuntime=[pscustomobject]@{ process=$null; stopping=$false; failures=0; nextStartUtc=[DateTime]::MinValue; startedUtc=[DateTime]::MinValue; status='disabled' }
try {
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

# Foreground/overlay interop; global key registration lives in Global-Hotkey.ps1.
$nativeSource = @'
using System;
using System.Runtime.InteropServices;
public static class AmbientNative {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll", SetLastError=true)] public static extern int GetWindowLong(IntPtr hWnd, int index);
    [DllImport("user32.dll", SetLastError=true)] public static extern int SetWindowLong(IntPtr hWnd, int index, int value);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hWnd, int attribute, out RECT rect, int cbSize);
}
'@
Add-Type -TypeDefinition $nativeSource -Language CSharp -ReferencedAssemblies 'System.dll'

$showPortableGuide=$PortableLaunch -and -not (Test-Path -LiteralPath $ConfigPath)
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    $defaultConfigPath=Join-Path $PSScriptRoot 'settings.json'
    if ([IO.Path]::GetFullPath($ConfigPath) -ne [IO.Path]::GetFullPath($defaultConfigPath)) { throw "Missing settings file: $ConfigPath" }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'settings.defaults.json') -Destination $ConfigPath
}
$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$localControl = New-AmbientLocalControl $config $ConfigPath
$config = $localControl.config
$logPath = Join-Path $PSScriptRoot 'diagnostic-log.txt'
Write-AmbientDesktopLog $logPath ('Ambient Workspace Desktop diagnostic launch: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
$debugBorderEnabled = ($config.PSObject.Properties.Name -contains 'debugBorder' -and $config.debugBorder -eq $true)
$targets = @($config.targets | ForEach-Object { ([string]$_).ToLowerInvariant() })
$palette = [string]$config.palette
$strength = [Math]::Max(0.08, [Math]::Min(0.85, [double]$config.strength))
$perAppMultiplier = @{}
if ($config.PSObject.Properties.Name -contains 'appMultipliers') {
    foreach ($entry in $config.appMultipliers.PSObject.Properties) {
        $perAppMultiplier[$entry.Name.ToLowerInvariant()] = [Math]::Max(0.5, [Math]::Min(1.5, [double]$entry.Value))
    }
}
$spread = if (($config.PSObject.Properties.Name -contains 'spread') -and ([string]$config.spread).ToLowerInvariant() -eq 'compact') { 'compact' } else { 'wide' }
$seconds = [Math]::Max(15, [Math]::Min(180, [double]$config.animationSeconds))
$checkMs = [Math]::Max(250, [Math]::Min(2000, [int]$config.windowCheckMilliseconds))
$motion = [bool]$config.motion
$protection = if ($config.PSObject.Properties.Name -contains 'centerProtection') { [string]$config.centerProtection } else { 'balanced' }

function Resolve-PaletteColors([string]$name) {
    switch ($name.ToLowerInvariant()) {
        'forest' { return @('#4EAD91', '#7CA97C', '#C8B76B') }
        'sunset' { return @('#E5A05D', '#C77AAD', '#8D78D8') }
        'ocean'  { return @('#5989D9', '#49B0C1', '#4A77CE') }
        'aurora' { return @('#79A6F2', '#5FCBA3', '#A079E5') }
        default  { return @('#7F86F4', '#6FC4BB', '#AA79D6') }
    }
}
$runtime = [pscustomobject]@{
    palette = $palette; colors = @(Resolve-PaletteColors $palette); strength = $strength
    spread = $spread; protection = $protection; motion = $motion; seconds = $seconds
}


# Optional, local-only YouTube color bridge. The browser companion sends RGB values,
# plus opt-in low-resolution JPEG, never audio, URLs, transcripts or page text.
$bridgeDirectory = $PSScriptRoot
$bridgeKeyPath = Join-Path $bridgeDirectory 'bridge-pairing.txt'
$bridgeSnapshotPath = Join-Path $bridgeDirectory 'bridge-colors.json'
$bridgeFramePath = Join-Path $bridgeDirectory 'bridge-video.jpg'
$bridgeFrameMetaPath = Join-Path $bridgeDirectory 'bridge-video.json'
$bridgeLogPath = Join-Path $bridgeDirectory 'bridge-log.txt'
$bridgeConfig = if ($config.PSObject.Properties.Name -contains 'youtubeBridge') { $config.youtubeBridge } else { $null }
$bridgePort = if ($bridgeConfig -and $bridgeConfig.port) { [int]$bridgeConfig.port } else { 38941 }
$bridgeEnabled = ($null -ne $bridgeConfig -and $bridgeConfig.enabled -eq $true)
$bridgeStaleSeconds = if ($bridgeConfig -and $bridgeConfig.staleSeconds) { [int]$bridgeConfig.staleSeconds } else { 7 }
$bridgeBlend = if ($bridgeConfig -and $bridgeConfig.blend) { [double]$bridgeConfig.blend } else { 0.35 }
$bridgeRunner = Join-Path $bridgeDirectory 'YouTube-Color-Bridge.ps1'
if ($bridgeEnabled) { $controlRuntime=Start-AmbientControlChannel $bridgeDirectory $localControl }
$parentProcess=[Diagnostics.Process]::GetCurrentProcess()
try { $parentStartTicks=$parentProcess.StartTime.ToUniversalTime().Ticks } finally { $parentProcess.Dispose() }
if ($bridgeEnabled) {
    try {
        if (-not [System.IO.File]::Exists($bridgeKeyPath)) {
            $bytes = New-Object byte[] 32
            $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
            try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
            $secret = ([BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
            [System.IO.File]::WriteAllText($bridgeKeyPath, $secret, [System.Text.UTF8Encoding]::new($false))
        }
        # Never pass the pairing token in command-line arguments or log files.
        $bridgeRunner = Join-Path $bridgeDirectory 'YouTube-Color-Bridge.ps1'
        Ensure-AmbientBridge $bridgeRuntime $bridgeRunner $bridgePort $PID $parentStartTicks (Join-Path $PSHOME 'powershell.exe') -PerformanceMetrics $metricsRuntime.enabled -ExperimentalVideoFps $ExperimentalVideoFps
    } catch {
        Write-AmbientDesktopLog $logPath ('BRIDGE START ERROR: '+(Format-AmbientSafeError $_))
    }
}
$bridgeState = [pscustomobject]@{ baseColors = @($runtime.colors); lastPacket = ''; active = $false }
function Try-UpdateYoutubeColors {
    if (-not $bridgeEnabled -or -not [System.IO.File]::Exists($bridgeSnapshotPath)) {
        if ($bridgeState.active) {
            $runtime.colors = @($bridgeState.baseColors)
            Update-Lights 0.88
            $bridgeState.active = $false
        }
        return
    }
    try {
        $raw = [System.IO.File]::ReadAllText($bridgeSnapshotPath)
        $packet = $raw | ConvertFrom-Json
        $age = ([DateTime]::UtcNow - [DateTime]::Parse([string]$packet.utc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)).TotalSeconds
        if ($age -ge 0 -and $age -le $bridgeStaleSeconds) {
            if ($raw -ne $bridgeState.lastPacket) {
                $bridgeState.lastPacket = $raw
                $incoming = @([string]$packet.left, [string]$packet.right)
                if ($incoming.Count -eq 2 -and $incoming[0] -match '^#[0-9a-fA-F]{6}$' -and $incoming[1] -match '^#[0-9a-fA-F]{6}$') {
                    $previous = @($runtime.colors)
                    $mixed = @()
                    for ($side = 0; $side -lt 2; $side++) {
                        $a = [System.Drawing.ColorTranslator]::FromHtml($previous[$side])
                        $b = [System.Drawing.ColorTranslator]::FromHtml($incoming[$side])
                        $ratio = [Math]::Max(0.05, [Math]::Min(0.95, $bridgeBlend))
                        $r = [int][Math]::Round($a.R*(1-$ratio)+$b.R*$ratio)
                        $g = [int][Math]::Round($a.G*(1-$ratio)+$b.G*$ratio)
                        $bl = [int][Math]::Round($a.B*(1-$ratio)+$b.B*$ratio)
                        $mixed += ('#{0:X2}{1:X2}{2:X2}' -f $r,$g,$bl)
                    }
                    $runtime.colors = @($mixed[0],$mixed[1],$bridgeState.baseColors[2])
                    Update-Lights 0.88
                    $bridgeState.active = $true
                }
            }
            return
        }
        if ($bridgeState.active) {
            $runtime.colors = @($bridgeState.baseColors)
            Update-Lights 0.88
            $bridgeState.active = $false
            $bridgeState.lastPacket = ''
        }
    } catch { # Incomplete atomic rename / temporary file issues recover on the next timer tick.
    }
}

[xml]$xaml = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Overlay.xaml') -Raw -Encoding UTF8
$reader = New-Object System.Xml.XmlNodeReader($xaml)
try { $window = [System.Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Dispose() }
$surface = $window.FindName('AmbientSurface')
$left = $window.FindName('GlowLeft')
$right = $window.FindName('GlowRight')
$bottom = $window.FindName('GlowBottom')
$debugBorder = $window.FindName('DebugBorder')
$edgeLeft = $window.FindName('EdgeLeft')
$edgeRight = $window.FindName('EdgeRight')
$edgeBottom = $window.FindName('EdgeBottom')
$videoWash = $window.FindName('VideoWash')
$videoWashPrev = $window.FindName('VideoWashPrev')
# Reuse one mask across both image planes so transitions cannot cause bright text flashes.
$videoWashPrev.OpacityMask = $videoWash.OpacityMask
$coverageDefault = 'follow'
if ($config.PSObject.Properties.Name -contains 'desktopVideo') {
    if ($null -ne $config.desktopVideo -and $config.desktopVideo.PSObject.Properties.Name -contains 'coverage' -and [string]$config.desktopVideo.coverage -in @('follow','narrow','balanced','wide')) {
        $coverageDefault = [string]$config.desktopVideo.coverage
    }
}
# Legacy 'smooth' is mapped to the brief transition, rather than the old 310ms slideshow fade.
$smoothDefault = $true
if ($config.PSObject.Properties.Name -contains 'desktopVideo' -and $null -ne $config.desktopVideo -and $config.desktopVideo.PSObject.Properties.Name -contains 'smooth') { $smoothDefault = [bool]$config.desktopVideo.smooth }
$styleDefault = if ($smoothDefault) { 'brief' } else { 'instant' }
if ($config.PSObject.Properties.Name -contains 'desktopVideo' -and $null -ne $config.desktopVideo -and $config.desktopVideo.PSObject.Properties.Name -contains 'transitionStyle') {
    $styleCandidate = [string]$config.desktopVideo.transitionStyle
    if ($styleCandidate -in @('instant','brief','cinematic')) { $styleDefault=$styleCandidate }
}
$videoState = [pscustomobject]@{
    enabled=$true; lastStamp=''; active=$false; coverage=$coverageDefault
    smooth=($styleDefault -ne 'instant'); transitionStyle=$styleDefault
    transitionMs=$(if ($styleDefault -eq 'cinematic') { 310 } else { 95 })
    lastError=''; frameCount=0; lastFrameUtc=[DateTime]::MinValue
    frameTimes=[System.Collections.Generic.Queue[DateTime]]::new()
    lastCountedStamp=''; pipeline=$(if($metricsRuntime.enabled){New-AmbientPipeline -Names @('poll','pollGap','scan','read','decode','apply','applyGap','sourceAssignment','uniqueFrame','redisplay','fileAge','hidden','disabled','stale','unchanged','loadError','transitionFallback')}else{$null})
}
# A single reusable timer releases the previous bitmap and animation clocks after a fade.
$videoRelease=New-Object System.Windows.Threading.DispatcherTimer
$releaseTick=[EventHandler]({
    $videoRelease.Stop()
    $property=[System.Windows.UIElement]::OpacityProperty
    $videoWash.BeginAnimation($property,$null)
    $videoWashPrev.BeginAnimation($property,$null)
    $videoWashPrev.Source=$null
    $videoWashPrev.Visibility=[System.Windows.Visibility]::Collapsed
}.GetNewClosure())
$videoRelease.Add_Tick($releaseTick)
function Clear-VideoFrames {
    $videoRelease.Stop()
    foreach ($img in @($videoWash, $videoWashPrev)) {
        $img.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
        $img.Source = $null
        $img.Visibility = [System.Windows.Visibility]::Collapsed
    }
    $videoState.active=$false
    $videoState.lastStamp=''
    $videoState.frameTimes.Clear()
    $videoState.lastFrameUtc=[DateTime]::MinValue
    if ($null -ne $state) { $state.lastOpacity=-1.0 }
}
function Show-VideoFrame($newBitmap) {
    $videoRelease.Stop()
    $targetOpacity = 0.58
    $property = [System.Windows.UIElement]::OpacityProperty
    # WPF performs the blend without a Python/web timer or additional JPEG decode.
    if ($videoState.smooth -and $null -ne $videoWash.Source) {
        $videoWashPrev.BeginAnimation($property, $null)
        $videoWashPrev.Source = $videoWash.Source
        $videoWashPrev.Opacity = 0.0
        $videoWashPrev.Visibility = [System.Windows.Visibility]::Visible
        $videoWash.BeginAnimation($property, $null)
        $videoWash.Source = $newBitmap
        Add-AmbientStage $videoState.pipeline 'sourceAssignment'
        $videoWash.Opacity = $targetOpacity
        $videoWash.Visibility = [System.Windows.Visibility]::Visible
        $duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds($videoState.transitionMs))
        $fadeIn = [System.Windows.Media.Animation.DoubleAnimation]::new()
        $fadeIn.From = 0.0; $fadeIn.To = $targetOpacity; $fadeIn.Duration = $duration
        $fadeIn.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::Stop
        $fadeOut = [System.Windows.Media.Animation.DoubleAnimation]::new()
        $fadeOut.From = $targetOpacity; $fadeOut.To = 0.0; $fadeOut.Duration = $duration
        $fadeOut.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::Stop
        $videoWash.BeginAnimation($property, $fadeIn)
        $videoWashPrev.BeginAnimation($property, $fadeOut)
        $videoRelease.Interval=[TimeSpan]::FromMilliseconds($videoState.transitionMs+20)
        $videoRelease.Start()
    } else {
        $videoWash.BeginAnimation($property, $null)
        $videoWashPrev.BeginAnimation($property, $null)
        $videoWashPrev.Source=$null
        $videoWashPrev.Visibility=[System.Windows.Visibility]::Collapsed
        $videoWash.Source = $newBitmap
        Add-AmbientStage $videoState.pipeline 'sourceAssignment'
        $videoWash.Opacity = $targetOpacity
        $videoWash.Visibility = [System.Windows.Visibility]::Visible
    }
}
function Set-VideoCoverage([string]$level) {
    # 'follow' ties the video mask to Light/Balanced/Strong center-protection setting.
    if ($level -eq 'follow') {
        $level = switch ($runtime.protection) {
            'light' { 'wide' }
            'strong' { 'narrow' }
            default { 'balanced' }
        }
    }
    # Separate from RGB layer's CenterProtection. Keep the center transparent.
    $stops = $videoWash.OpacityMask.GradientStops
    switch ($level) {
        'narrow'   { $offsets = @(0.40, 0.67, 0.91) }
        'balanced' { $offsets = @(0.32, 0.56, 0.82) }
        default    { $offsets = @(0.24, 0.47, 0.76) }
    }
    for ($i=1; $i -le 3; $i++) { $stops[$i].Offset = [double]$offsets[$i - 1] }
}
Set-VideoCoverage $videoState.coverage
# Video decoding is local-only: read an atomic JPEG snapshot into a frozen WPF BitmapImage.
function Try-UpdateYoutubeVideo {
    $probe=$videoState.pipeline
    if ($null -ne $probe) {
        $pollMs=$probe.clock.Elapsed.TotalMilliseconds
        if ($probe.lastPollMs -ge 0) { Add-AmbientStage $probe 'pollGap' ($pollMs-$probe.lastPollMs) }
        $probe.lastPollMs=$pollMs;Add-AmbientStage $probe 'poll'
    }
    if (-not $videoState.enabled -or -not $bridgeEnabled) {
        Add-AmbientStage $probe 'disabled'
        if ($videoState.active) { Clear-VideoFrames }
        return
    }
    if ($window.Visibility -ne [System.Windows.Visibility]::Visible) { Add-AmbientStage $probe 'hidden';return }
    try {
        $stageAt=if($probe){$probe.clock.Elapsed.TotalMilliseconds}else{0}
        # Pick the latest immutable frame, rather than relying on an overwriteable JPG/JSON pair.
        $frames = @(Get-ChildItem -LiteralPath $bridgeDirectory -Filter 'bridge-frame-*.jpg' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
        if($probe){Add-AmbientStage $probe 'scan' ($probe.clock.Elapsed.TotalMilliseconds-$stageAt)}
        if ($frames.Count -eq 0) {
            if ($videoState.active) { Clear-VideoFrames }
            return
        }
        $latest = $frames[0]
        $age = ([DateTime]::UtcNow - $latest.LastWriteTimeUtc).TotalSeconds
        if ($age -lt -3 -or $age -gt 4) {
            Add-AmbientStage $probe 'stale'
            if ($videoState.active) { Clear-VideoFrames }
            return
        }
        if ($latest.Name -eq $videoState.lastStamp) { Add-AmbientStage $probe 'unchanged';return }
        $stageAt=if($probe){$probe.clock.Elapsed.TotalMilliseconds}else{0}
        $bytes = [IO.File]::ReadAllBytes($latest.FullName)
        if($probe){Add-AmbientStage $probe 'read' ($probe.clock.Elapsed.TotalMilliseconds-$stageAt)}
        if ($bytes.Length -gt 90000 -or $bytes.Length -lt 120) { return }
        $ms = [IO.MemoryStream]::new($bytes,$false)
        try {
            $stageAt=if($probe){$probe.clock.Elapsed.TotalMilliseconds}else{0}
            $image = [System.Windows.Media.Imaging.BitmapImage]::new()
            $image.BeginInit()
            $image.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $image.StreamSource = $ms
            $image.EndInit()
            $image.Freeze()
            if($probe){Add-AmbientStage $probe 'decode' ($probe.clock.Elapsed.TotalMilliseconds-$stageAt)}
            $stageAt=if($probe){$probe.clock.Elapsed.TotalMilliseconds}else{0}
            try { Show-VideoFrame $image } catch {
                # If an older WPF composition driver rejects the animation, keep static frames working.
                $videoState.smooth=$false
                Add-AmbientStage $probe 'transitionFallback'
                Show-VideoFrame $image
                if ($null -ne $logPath) { Write-AmbientDesktopLog $logPath ('Video transition unsupported: ' + (Format-AmbientSafeError $_)) }
            }
            if($probe){Add-AmbientStage $probe 'apply' ($probe.clock.Elapsed.TotalMilliseconds-$stageAt);Add-AmbientStage $probe 'fileAge' ([Math]::Max(0,([DateTime]::UtcNow-$latest.LastWriteTimeUtc).TotalMilliseconds))}
            # Clearing the overlay permits redisplay of the same JPEG, not a new arrival.
            if ($latest.Name -ne $videoState.lastCountedStamp) { Add-AmbientStage $probe 'uniqueFrame';$videoState.lastCountedStamp=$latest.Name }
            else { Add-AmbientStage $probe 'redisplay' }
            $videoState.lastStamp = $latest.Name
            $videoState.active = $true
            Add-AmbientGap $probe 'applyGap'
            $nowUtc = [DateTime]::UtcNow
            $videoState.lastFrameUtc = $nowUtc
            $videoState.frameCount++
            $videoState.frameTimes.Enqueue($nowUtc)
            while ($videoState.frameTimes.Count -gt 0 -and ($nowUtc - $videoState.frameTimes.Peek()).TotalSeconds -gt 10) {
                [void]$videoState.frameTimes.Dequeue()
            }
        } finally { $ms.Dispose() }
    } catch {
        Add-AmbientStage $probe 'loadError'
        $reason = $_.Exception.Message
        if ($reason -ne $videoState.lastError) {
            $videoState.lastError=$reason
            Write-AmbientDesktopLog $logPath ('Video frame error: ' + (Format-AmbientSafeError $_))
        }
    }
}

# The pink border is OFF by default. A dedicated tray test can enable it temporarily.
if ($debugBorderEnabled) { $debugBorder.Visibility = [System.Windows.Visibility]::Visible }


function Set-GlowBrush($ellipse, [string]$colorHex, [double]$alpha) {
    $rgb = [System.Windows.Media.ColorConverter]::ConvertFromString($colorHex)
    $visible = [System.Windows.Media.Color]::FromArgb([byte]([Math]::Round(255 * $alpha)), $rgb.R, $rgb.G, $rgb.B)
    $empty = [System.Windows.Media.Color]::FromArgb(0, $rgb.R, $rgb.G, $rgb.B)
    $brush = New-Object System.Windows.Media.RadialGradientBrush
    $brush.GradientOrigin = [System.Windows.Point]::new(0.5, 0.5)
    $brush.Center = [System.Windows.Point]::new(0.5, 0.5)
    $brush.RadiusX = 0.5
    $brush.RadiusY = 0.5
    [void]$brush.GradientStops.Add(([System.Windows.Media.GradientStop]::new($visible, 0.0)))
    [void]$brush.GradientStops.Add(([System.Windows.Media.GradientStop]::new($visible, 0.10)))
    [void]$brush.GradientStops.Add(([System.Windows.Media.GradientStop]::new($empty, 1.0)))
    $ellipse.Fill = $brush
}
# Stronger, clearly visible edge washes. These have a second falloff toward the
# center (plus the existing oval opacity mask), so the editor content stays clear.
function Set-EdgeBrush($shape, [string]$colorHex, [double]$alpha, [string]$direction) {
    $rgb = [System.Windows.Media.ColorConverter]::ConvertFromString($colorHex)
    $a = [Math]::Max(0, [Math]::Min(1, $alpha))
    $bright = [System.Windows.Media.Color]::FromArgb([byte]([Math]::Round(255*$a)), $rgb.R, $rgb.G, $rgb.B)
    $mid = [System.Windows.Media.Color]::FromArgb([byte]([Math]::Round(255*$a*0.46)), $rgb.R, $rgb.G, $rgb.B)
    $clear = [System.Windows.Media.Color]::FromArgb(0, $rgb.R, $rgb.G, $rgb.B)
    $brush = New-Object System.Windows.Media.LinearGradientBrush
    if ($direction -eq 'right') { $brush.StartPoint = [System.Windows.Point]::new(1,0); $brush.EndPoint = [System.Windows.Point]::new(0,0) }
    elseif ($direction -eq 'bottom') { $brush.StartPoint = [System.Windows.Point]::new(0,1); $brush.EndPoint = [System.Windows.Point]::new(0,0) }
    else { $brush.StartPoint = [System.Windows.Point]::new(0,0); $brush.EndPoint = [System.Windows.Point]::new(1,0) }
    [void]$brush.GradientStops.Add(([System.Windows.Media.GradientStop]::new($bright, 0.0)))
    [void]$brush.GradientStops.Add(([System.Windows.Media.GradientStop]::new($mid, 0.30)))
    [void]$brush.GradientStops.Add(([System.Windows.Media.GradientStop]::new($clear, 1.0)))
    $shape.Fill = $brush
}
function Update-Lights([double]$intensity) {
    # Intensity above 0.5 is intended for short visual tests; everyday values
    # should remain lower for readability and lower perceived distraction.
    $value = [Math]::Max(0.05, [Math]::Min(0.93, $intensity))
    Set-GlowBrush $left $runtime.colors[0] ($value * 0.98)
    Set-GlowBrush $right $runtime.colors[1] ($value * 0.98)
    Set-GlowBrush $bottom $runtime.colors[2] ($value * 0.65)
    Set-EdgeBrush $edgeLeft $runtime.colors[0] ($value * 0.70) 'left'
    Set-EdgeBrush $edgeRight $runtime.colors[1] ($value * 0.70) 'right'
    Set-EdgeBrush $edgeBottom $runtime.colors[2] ($value * 0.40) 'bottom'
}
# Render brushes once. Strong test only changes shape opacity, avoiding repeated
# brush allocations and function-scope issues in PowerShell event callbacks.
Update-Lights 0.88
# The active app determines default brightness, with a tray override. Use one
# cached geometry/brush set and only change shape opacity when needed.
foreach ($shape in @($left, $right, $bottom, $edgeLeft, $edgeRight, $edgeBottom)) {
    $shape.Opacity = [Math]::Min(1.0, ($strength / 0.88))
}

function Resize-Lights {

    $w = [Math]::Max(400, [double]$window.ActualWidth)
    $h = [Math]::Max(300, [double]$window.ActualHeight)
    $videoWash.Width=$w; $videoWash.Height=$h
    $videoWashPrev.Width=$w; $videoWashPrev.Height=$h
    # Full-height side washes spread light across the edges rather than concentrating at corners.
    # Compact mode provides an easy rollback in settings.json if the glow feels too broad.
    $sideWidth = if ($runtime.spread -eq 'wide') { 0.46 } else { 0.34 }
    $glowWidth = if ($runtime.spread -eq 'wide') { 0.80 } else { 0.66 }
    $glowHeight = if ($runtime.spread -eq 'wide') { 1.42 } else { 1.18 }
    $left.Width = $w * $glowWidth; $left.Height = $h * $glowHeight
    $right.Width = $w * $glowWidth; $right.Height = $h * $glowHeight
    $bottom.Width = $w * 0.88; $bottom.Height = $h * 0.92
    $edgeLeft.Width = $w * $sideWidth; $edgeLeft.Height = $h
    $edgeRight.Width = $w * $sideWidth; $edgeRight.Height = $h
    $edgeBottom.Width = $w; $edgeBottom.Height = $h * 0.35
    [System.Windows.Controls.Canvas]::SetLeft($edgeLeft, 0)
    [System.Windows.Controls.Canvas]::SetTop($edgeLeft, 0)
    [System.Windows.Controls.Canvas]::SetLeft($edgeRight, $w * (1 - $sideWidth))
    [System.Windows.Controls.Canvas]::SetTop($edgeRight, 0)
    [System.Windows.Controls.Canvas]::SetLeft($edgeBottom, 0)
    [System.Windows.Controls.Canvas]::SetTop($edgeBottom, $h * 0.65)
    [System.Windows.Controls.Canvas]::SetLeft($left, $w * (0.16 - $glowWidth / 2))
    [System.Windows.Controls.Canvas]::SetTop($left, $h * (0.50 - $glowHeight / 2))
    [System.Windows.Controls.Canvas]::SetLeft($right, $w * (0.84 - $glowWidth / 2))
    [System.Windows.Controls.Canvas]::SetTop($right, $h * (0.50 - $glowHeight / 2))
    [System.Windows.Controls.Canvas]::SetLeft($bottom, $w * 0.06)
    [System.Windows.Controls.Canvas]::SetTop($bottom, $h * 0.40)
}
$window.Add_SizeChanged({ Resize-Lights }.GetNewClosure())

function Set-CenterMask([string]$level) {
    # Stops 1..3 control how abruptly the masked center transitions to the glow.
    $stops = $surface.OpacityMask.GradientStops
    switch ($level) {
        'strong' { $offsets = @(0.51, 0.77, 0.93) }
        'light' { $offsets = @(0.30, 0.56, 0.80) }
        default { $offsets = @(0.43, 0.68, 0.88) }
    }
    for ($i = 1; $i -le 3; $i++) { $stops[$i].Offset = [double]$offsets[$i - 1] }
}
Set-CenterMask $runtime.protection
Set-VideoCoverage $videoState.coverage

function Animate-Glow($shape, [double]$fromX, [double]$toX, [double]$fromY, [double]$toY, [double]$period) {
    $transform = New-Object System.Windows.Media.TranslateTransform
    $shape.RenderTransform = $transform
    $duration = [System.Windows.Duration]::new([TimeSpan]::FromSeconds($period))
    $repeat = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $ax = New-Object System.Windows.Media.Animation.DoubleAnimation
    $ax.From = $fromX; $ax.To = $toX; $ax.Duration = $duration
    $ax.AutoReverse = $true; $ax.RepeatBehavior = $repeat
    $ay = New-Object System.Windows.Media.Animation.DoubleAnimation
    $ay.From = $fromY; $ay.To = $toY; $ay.Duration = $duration
    $ay.AutoReverse = $true; $ay.RepeatBehavior = $repeat
    $transform.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $ax)
    $transform.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $ay)
}
function Set-GlowMotion([bool]$enabled, [double]$period) {
    if ($enabled) {
        Animate-Glow $left  -18  28   24  -24 $period
        Animate-Glow $right  24 -18  -22   28 ($period * 1.19)
        Animate-Glow $bottom -20  24   12  -16 ($period * 1.43)
    } else {
        foreach ($shape in @($left, $right, $bottom)) {
            $transform = $shape.RenderTransform
            if ($null -ne $transform -and $transform -is [System.Windows.Media.TranslateTransform]) {
                $transform.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $null)
                $transform.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $null)
                $transform.X = 0; $transform.Y = 0
            }
        }
    }
}
$state = [pscustomobject]@{ overlayHandle = [IntPtr]::Zero; lastRect = ''; previousVisible = $false; lastStatus = ''; lastError = ''; selfTestUntil = [DateTime]::MinValue; brightUntil = [DateTime]::MinValue; motionAllowed = $null; lastOpacity = -1.0 }

function Apply-DesktopLocalControl {
    $values = $localControl.config
    $nextSpread = if ($null -ne $values.PSObject.Properties['spread'] -and [string]$values.spread -eq 'compact') { 'compact' } else { 'wide' }
    $nextProtection = if ($null -ne $values.PSObject.Properties['centerProtection']) { [string]$values.centerProtection } else { 'balanced' }
    $paletteChanged = ($runtime.palette -ne [string]$values.palette)
    $geometryChanged = ($runtime.spread -ne $nextSpread -or $runtime.protection -ne $nextProtection)
    $nextSeconds = [Math]::Max(15, [Math]::Min(180, [double]$values.animationSeconds))
    $motionChanged = ($runtime.motion -ne [bool]$values.motion -or $runtime.seconds -ne $nextSeconds)
    $runtime.palette = [string]$values.palette
    $runtime.strength = [Math]::Max(0.08, [Math]::Min(0.85, [double]$values.strength))
    $runtime.spread = $nextSpread
    $runtime.protection = $nextProtection
    $runtime.motion = [bool]$values.motion
    $runtime.seconds = $nextSeconds
    if ($paletteChanged) {
        $runtime.colors = @(Resolve-PaletteColors $runtime.palette)
        $bridgeState.baseColors = @($runtime.colors)
        if ($bridgeState.active) { $bridgeState.lastPacket = ''; Try-UpdateYoutubeColors }
        else { Update-Lights 0.88 }
    }
    if ($geometryChanged) { Set-CenterMask $runtime.protection; Resize-Lights }
    $videoState.coverage = [string]$values.desktopVideo.coverage
    Set-VideoCoverage $videoState.coverage
    $styleChoice = [string]$values.desktopVideo.transitionStyle
    if ($videoState.transitionStyle -ne $styleChoice) {
        $videoState.transitionStyle = $styleChoice
        $videoState.smooth = ($styleChoice -ne 'instant')
        $videoState.transitionMs = if ($styleChoice -eq 'cinematic') { 310 } else { 95 }
    }
    $active = (-not $values.control.globalPaused -and $values.desktopOutput.enabled)
    $videoState.enabled = ($active -and $values.desktopOutput.videoEnabled)
    if (-not $videoState.enabled) { Clear-VideoFrames }
    $rgbAllowed = ($active -and $values.desktopOutput.rgbEnabled)
    $surface.Visibility = if ($rgbAllowed) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    $motionAllowed = ($rgbAllowed -and $runtime.motion)
    if ($motionChanged -or $state.motionAllowed -ne $motionAllowed) { Set-GlowMotion $motionAllowed $runtime.seconds }
    $state.motionAllowed = $motionAllowed
    $state.lastOpacity = -1.0
    if (-not $active -or (-not $values.desktopOutput.rgbEnabled -and -not $values.desktopOutput.videoEnabled)) {
        $window.Hide()
        $state.previousVisible = $false
        $state.selfTestUntil = [DateTime]::MinValue
        $state.brightUntil = [DateTime]::MinValue
    }
}

function Get-DesktopTrayReception {
    # Read only when opening/updating the menu, never on the rendering timers.
    # Consumer active flags cannot describe reception while an output is OFF.
    $result = [pscustomobject]@{ rgbFresh=$false; videoFresh=$false; rgb='수신 대기'; video='수신 대기' }
    if (-not $bridgeEnabled) { $result.rgb='Bridge 사용 안 함'; $result.video='Bridge 사용 안 함'; return $result }
    $now = [DateTime]::UtcNow
    try {
        if ([IO.File]::Exists($bridgeSnapshotPath)) {
            $packet = [IO.File]::ReadAllText($bridgeSnapshotPath) | ConvertFrom-Json
            $age = ($now - [DateTime]::Parse([string]$packet.utc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)).TotalSeconds
            if ([string]$packet.left -notmatch '^#[0-9a-fA-F]{6}$' -or [string]$packet.right -notmatch '^#[0-9a-fA-F]{6}$') { throw 'Invalid colors' }
            $result.rgbFresh = ($age -ge 0 -and $age -le $bridgeStaleSeconds)
            $result.rgb = if ($result.rgbFresh) { '최근 색상 수신 확인' } else { '수신 대기 · 색상 만료' }
        }
    } catch { $result.rgb='수신 확인 불가 · 다시 열어 확인' }
    try {
        $frames = @(Get-ChildItem -LiteralPath $bridgeDirectory -Filter 'bridge-frame-*.jpg' -File -ErrorAction Stop | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
        if ($frames.Count -gt 0) {
            $age = ($now - $frames[0].LastWriteTimeUtc).TotalSeconds
            $result.videoFresh = ($age -ge -3 -and $age -le 4 -and $frames[0].Length -ge 120 -and $frames[0].Length -le 90000)
            $result.video = if ($result.videoFresh) { '최근 영상 수신 확인 · 표시와 별개' } else { '수신 대기 · 영상 만료/확인 불가' }
        }
    } catch { $result.video='수신 확인 불가 · 다시 열어 확인' }
    return $result
}

function Update-DesktopTrayStatus {
    $received = Get-DesktopTrayReception
    $rgbReceiveStatus.Text = 'RGB 수신: ' + $received.rgb
    $videoReceiveStatus.Text = '영상 수신: ' + $received.video
    $values = $localControl.config
    $client=if ($null -ne $controlRuntime) { $controlRuntime.shared.client } else { $null }
    $instance=if ($null -ne $controlRuntime) { $controlRuntime.instanceId } else { '' }
    $integration=Get-AmbientIntegrationPresentation $client $localControl $instance
    $integrationMenuStatus.Text=$integration.title
    $integrationLabels=@{web='웹 배경';youtube='YouTube 조명';capture='캡처 처리'}
    foreach ($key in @('web','youtube','capture')) {
        $description=switch ($integration.parts[$key]) { 'independent' { 'Chrome에서 별도 일시정지·재개' }; 'applied' { $integration.phase+' 적용 확인' }; 'off' { '사용자 설정 OFF · 유지됨' }; 'notRequired' { if ($key -eq 'capture') { '캡처 연결 없음' } else { '열린 대상 없음' } }; default { '확인 대기' } }
        $integrationRows[$key].Text=$integrationLabels[$key]+': '+$description
    }
    $display = if ($values.control.globalPaused) { 'Desktop 효과 일시정지' }
        elseif (-not $values.desktopOutput.enabled) { 'Desktop 효과 전체 꺼짐' }
        elseif (-not $values.desktopOutput.rgbEnabled -and -not $values.desktopOutput.videoEnabled) { 'RGB·영상 모두 꺼짐' }
        elseif ($window.Visibility -ne [Windows.Visibility]::Visible) { '대상 앱 대기' }
        else {
            $planes = @()
            if ($values.desktopOutput.rgbEnabled -and $surface.Visibility -eq [Windows.Visibility]::Visible) {
                $planes += if ($bridgeState.active -and $received.rgbFresh) { 'RGB 조명' } else { 'RGB 조명 (기본 팔레트)' }
            }
            if ($values.desktopOutput.videoEnabled -and $videoState.active -and $null -ne $videoWash.Source -and $videoWash.Visibility -eq [Windows.Visibility]::Visible) { $planes += '흐릿한 영상' }
            if ($planes.Count) { ($planes -join ' + ') + ' 표시 중' } else { '영상 수신 대기' }
        }
    $desktopDisplayStatus.Text = 'Desktop 표시: ' + $display
    $saveMenuStatus.Text = if ($localControl.savePending) { '설정: 저장 안 됨 · 현재 일시정지 유지' } else { '설정: 저장된 상태' }
    $statusTime.Text = '메뉴 확인 시점: ' + (Get-Date -Format 'HH:mm:ss') + ' · 다시 열면 갱신'
    $bridgeMenuStatus.Text = if (-not $bridgeEnabled) { 'Bridge: 사용 안 함' }
        elseif ($bridgeRuntime.status -like '*failed*' -or $bridgeRuntime.status -like '*retrying*') { 'Bridge: 연결 재시도 중 · 진단 로그 확인' }
        elseif ($received.rgbFresh -or $received.videoFresh) { 'Bridge: 최근 로컬 수신 확인' }
        else { 'Bridge: 로컬 수신 대기' }
}

function Update-DesktopControlMenu {
    $values = $localControl.config
    $scope=if ($bridgeEnabled) { '통합 효과' } else { 'Desktop 효과' }
    $toggle.Text = if ($values.control.globalPaused) { $scope+' 재개' } else { $scope+' 일시정지' }
    if ($localControl.savePending) { $toggle.Text += ' (저장 안 됨)' }
    $desktopToggle.Checked = $values.desktopOutput.enabled
    $rgbToggle.Checked = $values.desktopOutput.rgbEnabled
    $videoToggle.Checked = $values.desktopOutput.videoEnabled
    foreach ($key in $intensityItems.Keys) { $intensityItems[$key].Checked = ($key -eq $values.desktopOutput.intensity) }
    foreach ($key in $transitionItems.Keys) { $transitionItems[$key].Checked = ($key -eq $values.desktopVideo.transitionStyle) }
    foreach ($key in $coverageItems.Keys) { $coverageItems[$key].Checked = ($key -eq $values.desktopVideo.coverage) }
    Update-DesktopTrayStatus
}

function Show-DesktopControlSaveError {
    Write-AmbientDesktopLog $logPath ('LOCAL SETTINGS SAVE ERROR: '+$localControl.lastSaveError)
    $message = if ($localControl.savePending) {
        'Desktop 효과는 일시정지했지만 설정을 저장하지 못했습니다. 다시 시작하면 마지막 저장 상태로 돌아갑니다. 설정 파일 접근 문제를 해결한 뒤 다시 시도해 주세요.'
    } else { '설정을 저장하지 못해 이전 Desktop 설정을 유지합니다. 설정 파일 접근 문제를 확인한 뒤 다시 시도해 주세요.' }
    [void][System.Windows.MessageBox]::Show($message, 'Ambient Workspace')
}

function Set-DesktopLocalControl([hashtable]$Changes,[switch]$Remote) {
    $result = Set-AmbientLocalControl $localControl $Changes
    if ($result.changed) { Apply-DesktopLocalControl }
    Sync-DesktopGlobalHotkey
    Sync-AmbientControlSnapshot $controlRuntime $localControl
    Update-DesktopControlMenu
    Sync-DesktopSettings
    if ($null -ne $settingsHost.session) { Update-DesktopSettingsStatus }
    if (-not $result.persisted) {
        if ($Remote) { Write-AmbientDesktopLog $logPath ('REMOTE SETTINGS SAVE ERROR: '+$localControl.lastSaveError) }
        else { Show-DesktopControlSaveError }
    }
    return $result
}

function Invoke-DesktopControlTick {
    # Dedicated Background Dispatcher timer: only memory and the existing local apply/save path.
    # All mailbox/snapshot disk I/O lives in Control-Channel's background runspace.
    $request=$controlRuntime.shared.pending
    if ($null -eq $request) { return }
    $outcome='applied'
    if ($request.expectedInstanceId -cne $controlRuntime.instanceId) { $outcome='instanceChanged' }
    elseif ($request.expiresAt -lt (Get-AmbientControlNow)) { $outcome='expired' }
    elseif ($request.expectedRevision -ne $localControl.revision) { $outcome='conflict' }
    else {
        try {
            $result=Set-DesktopLocalControl @{globalPaused=$request.globalPaused} -Remote
            if (-not $result.persisted) { $outcome='saveFailed' }
        } catch { $outcome='applyFailed' }
    }
    Complete-AmbientControlRequest $controlRuntime $localControl $request $outcome
}

function Request-DesktopDiagnostic([ValidateSet('border','bright')][string]$Kind) {
    $values = $localControl.config
    if ($values.control.globalPaused -or -not $values.desktopOutput.enabled -or
        (-not $values.desktopOutput.rgbEnabled -and -not $values.desktopOutput.videoEnabled) -or
        ($Kind -eq 'bright' -and -not $values.desktopOutput.rgbEnabled)) { return $false }
    if ($Kind -eq 'border') { $state.selfTestUntil = (Get-Date).AddSeconds(10) }
    else { $state.brightUntil = (Get-Date).AddSeconds(10) }
    return $true
}

$window.Add_SourceInitialized({
    $interop = [System.Windows.Interop.WindowInteropHelper]::new($window)
    $state.overlayHandle = $interop.Handle
    # WS_EX_TRANSPARENT (mouse passthrough), TOOLWINDOW (no Alt+Tab), NOACTIVATE.
    $existing = [AmbientNative]::GetWindowLong($state.overlayHandle, -20)
    $newStyle = $existing -bor 0x00000020 -bor 0x00000080 -bor 0x08000000
    [void][AmbientNative]::SetWindowLong($state.overlayHandle, -20, $newStyle)
}.GetNewClosure())

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds([Math]::Min($checkMs,450))
$windowTick=[EventHandler]({
    try {
        if ($bridgeEnabled) { Ensure-AmbientBridge $bridgeRuntime $bridgeRunner $bridgePort $PID $parentStartTicks (Join-Path $PSHOME 'powershell.exe') $metricsRuntime.enabled $ExperimentalVideoFps }
        if ($surface.Visibility -eq [Windows.Visibility]::Visible) { Try-UpdateYoutubeColors }
        if ($metricsRuntime.enabled -and [DateTime]::UtcNow -ge $metricsRuntime.nextUtc) {
            $metricsRuntime.nextUtc=[DateTime]::UtcNow.AddSeconds(2)
            try { Write-AmbientFrameMetrics $metricsRuntime.path $videoState $PID $parentStartTicks }
            catch { Write-AmbientDesktopLog $logPath ((Get-Date -Format 'HH:mm:ss')+' | METRICS ERROR: '+(Format-AmbientSafeError $_)) }
        }
        # Video frames use a faster, independent 120ms poll below.
        $foreground = [AmbientNative]::GetForegroundWindow()
        $visible = $false
        $rect = [AmbientNative+RECT]::new()
        $status = 'no supported app in foreground'
        $procName = '(unknown)'
        $inSelfTest = ((Get-Date) -lt $state.selfTestUntil)
        $brightActive = ((Get-Date) -lt $state.brightUntil)
        if ($debugBorderEnabled -or $inSelfTest) { $debugBorder.Visibility = [System.Windows.Visibility]::Visible }
        else { $debugBorder.Visibility = [System.Windows.Visibility]::Collapsed }

        if (-not $localControl.config.control.globalPaused -and $localControl.config.desktopOutput.enabled -and
            ($localControl.config.desktopOutput.rgbEnabled -or $localControl.config.desktopOutput.videoEnabled) -and
            $foreground -ne [IntPtr]::Zero -and -not [AmbientNative]::IsIconic($foreground)) {
            [uint32]$targetProcessId = 0
            [void][AmbientNative]::GetWindowThreadProcessId($foreground, [ref]$targetProcessId)
            if ($targetProcessId -gt 0) {
                $proc = [Diagnostics.Process]::GetProcessById([int]$targetProcessId)
                try { $procName = $proc.ProcessName.ToLowerInvariant() } finally { $proc.Dispose() }
                if ($targets -contains $procName -or $inSelfTest) {
                    $status = ('target detected: ' + $procName)
                    $dwm = [AmbientNative]::DwmGetWindowAttribute($foreground, 9, [ref]$rect, [Runtime.InteropServices.Marshal]::SizeOf([type][AmbientNative+RECT]))
                    if ($dwm -ne 0) { [void][AmbientNative]::GetWindowRect($foreground, [ref]$rect) }
                    $visible = ($rect.Right -gt ($rect.Left + 200) -and $rect.Bottom -gt ($rect.Top + 150))
                    if (-not $visible) { $status += ' (invalid window rect)' }
                    if ($visible) { $status = ('overlay ON for ' + $procName + ' | rect ' + $rect.Left + ',' + $rect.Top + ' ' + $rect.Right + ',' + $rect.Bottom) }
                }
            }
        }
        if ($visible) {
            $appStrength = $runtime.strength
            if ($perAppMultiplier.ContainsKey($procName)) { $appStrength *= [double]$perAppMultiplier[$procName] }
            $factor = switch ($localControl.config.desktopOutput.intensity) {
                'soft' { 0.62 }
                'vivid' { 1.35 }
                default { 1.0 }
            }
            $opacity = if ($brightActive) { 1.0 } else { [Math]::Max(0.06, [Math]::Min(0.98, ($appStrength * $factor / 0.88))) }
            $rgbOpacity = if ($videoState.active) { $opacity * 0.32 } else { $opacity }
            if ([Math]::Abs($rgbOpacity - $state.lastOpacity) -gt 0.005) {
                # In video mode, lower the RGB wash so the moving image is actually distinguishable.
                foreach ($shape in @($left, $right, $bottom, $edgeLeft, $edgeRight, $edgeBottom)) { $shape.Opacity = $rgbOpacity }
                $state.lastOpacity = $rgbOpacity
            }
            if ($window.Visibility -ne [System.Windows.Visibility]::Visible) { $window.Show() }
            # The pink border is OFF by default; it is managed by the tray test.
            $key = "{0},{1},{2},{3}" -f $rect.Left, $rect.Top, $rect.Right, $rect.Bottom
            if ($key -ne $state.lastRect -or -not $state.previousVisible) {
                # HWND_TOPMOST=-1, SWP_NOACTIVATE=0x10 | SWP_SHOWWINDOW=0x40
                $setPosOk = [AmbientNative]::SetWindowPos($state.overlayHandle, [IntPtr](-1), $rect.Left, $rect.Top, ($rect.Right - $rect.Left), ($rect.Bottom - $rect.Top), 0x50)
                if (-not $setPosOk) { $status += ' | SetWindowPos FAILED' }
                $state.lastRect = $key
            }
        } elseif ($window.Visibility -eq [System.Windows.Visibility]::Visible) {
            Clear-VideoFrames
            $window.Hide()
        }
        $state.previousVisible = $visible
        if ($state.lastStatus -ne $status) {
            $state.lastStatus = $status
            Write-AmbientDesktopLog $logPath ((Get-Date -Format 'HH:mm:ss') + ' | ' + $status)
        }
    } catch {
        # Report the first occurrence of each distinct error; do not silently discard failures.
        $errorMessage = $_.Exception.Message
        if ($errorMessage -ne $state.lastError) {
            $state.lastError = $errorMessage
            Write-AmbientDesktopLog $logPath ((Get-Date -Format 'HH:mm:ss') + ' | ERROR: ' + (Format-AmbientSafeError $_))
        }
        if ($window.Visibility -eq [System.Windows.Visibility]::Visible) { $window.Hide() }
        $state.previousVisible = $false
    }
}.GetNewClosure())


$timer.Add_Tick($windowTick)
# The original foreground/window timer ran at 450ms, discarding most 4FPS frames.
# Keep the window tracker slow, while reading the newest immutable JPEG at 120ms.
$videoPoll = New-Object System.Windows.Threading.DispatcherTimer
$videoPoll.Interval = [TimeSpan]::FromMilliseconds(120)
if ($ExperimentalVideoFps -eq 10) { $videoPoll.Interval = [TimeSpan]::FromMilliseconds(50) }
$videoTick=[EventHandler]({ Try-UpdateYoutubeVideo }.GetNewClosure())
$videoPoll.Add_Tick($videoTick)

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = [System.Drawing.SystemIcons]::Application
$tray.Text = 'Ambient Workspace Desktop v1.0.0-rc.2-dev'
$tray.Visible = $true
$tray.add_DoubleClick({ Show-SettingsWindow }.GetNewClosure())
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$toggle = $menu.Items.Add('Desktop 효과 일시정지')
$desktopToggle = [System.Windows.Forms.ToolStripMenuItem]::new('Desktop 효과 전체 사용')
[void]$menu.Items.Add($desktopToggle)
$desktopToggle.add_Click({ [void](Set-DesktopLocalControl @{desktopEnabled=(-not $localControl.config.desktopOutput.enabled)}) }.GetNewClosure())
$rgbToggle = [System.Windows.Forms.ToolStripMenuItem]::new('RGB 조명 사용')
[void]$menu.Items.Add($rgbToggle)
$rgbToggle.add_Click({ [void](Set-DesktopLocalControl @{rgbEnabled=(-not $localControl.config.desktopOutput.rgbEnabled)}) }.GetNewClosure())
$videoToggle = [System.Windows.Forms.ToolStripMenuItem]::new('흐릿한 영상 사용')
[void]$menu.Items.Add($videoToggle)
$videoToggle.add_Click({
    [void](Set-DesktopLocalControl @{videoEnabled=(-not $localControl.config.desktopOutput.videoEnabled)})
}.GetNewClosure())
$intensityMenu = [System.Windows.Forms.ToolStripMenuItem]::new('빠른 세기 조절')
[void]$menu.Items.Add($intensityMenu)
$intensityItems = @{}
foreach ($mode in @(@{ key='soft'; label='은은하게' }, @{ key='balanced'; label='기본' }, @{ key='vivid'; label='강하게' })) {
    $choice = [string]$mode.key
    $item = [System.Windows.Forms.ToolStripMenuItem]::new([string]$mode.label)
    $item.Checked = ($choice -eq 'balanced')
    $intensityItems[$choice] = $item
    [void]$intensityMenu.DropDownItems.Add($item)
    $item.add_Click({
        [void](Set-DesktopLocalControl @{intensity=$choice})
    }.GetNewClosure())
}
[void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
$statusMenu = [System.Windows.Forms.ToolStripMenuItem]::new('현재 수신·표시 상태')
[void]$menu.Items.Add($statusMenu)
$rgbReceiveStatus = $statusMenu.DropDownItems.Add('RGB 수신: 확인 대기')
$videoReceiveStatus = $statusMenu.DropDownItems.Add('영상 수신: 확인 대기')
$desktopDisplayStatus = $statusMenu.DropDownItems.Add('Desktop 표시: 확인 대기')
$saveMenuStatus = $statusMenu.DropDownItems.Add('설정: 확인 대기')
$integrationMenuStatus = $statusMenu.DropDownItems.Add('Desktop 적용 · Chrome 확인 대기')
$integrationMenuStatus.Enabled=$false
$integrationRows=@{}
foreach ($key in @('web','youtube','capture')) { $integrationRows[$key]=$statusMenu.DropDownItems.Add('확인 대기');$integrationRows[$key].Enabled=$false }
$statusTime = $statusMenu.DropDownItems.Add('메뉴를 열면 상태를 확인합니다')
foreach ($statusItem in @($rgbReceiveStatus,$videoReceiveStatus,$desktopDisplayStatus,$saveMenuStatus,$statusTime)) { $statusItem.Enabled=$false }
[void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
$settingsItem = $menu.Items.Add('설정 열기…')
$settingsItem.add_Click({ Show-SettingsWindow }.GetNewClosure())
# Keep the detail shortcuts until UI-4 receives Windows user acceptance.
$videoDetailsMenu = [System.Windows.Forms.ToolStripMenuItem]::new('영상 상세 설정 (임시)')
[void]$menu.Items.Add($videoDetailsMenu)
$videoDetailsNote = $videoDetailsMenu.DropDownItems.Add('설정창의 흐릿한 영상에서도 조절합니다')
$videoDetailsNote.Enabled=$false
# Video transitions are a *visual* choice. Long fades can look like a slideshow at 2-4FPS.
$transitionMenu = [System.Windows.Forms.ToolStripMenuItem]::new('영상 전환')
[void]$videoDetailsMenu.DropDownItems.Add($transitionMenu)
$transitionItems = @{}
foreach ($entry in @(
    @{key='instant';label='즉시 (전환 없음)'},
    @{key='brief';label='짧게 (95ms · 권장)'},
    @{key='cinematic';label='천천히 (310ms)'})) {
    $styleChoice = [string]$entry.key
    $styleItem = [System.Windows.Forms.ToolStripMenuItem]::new([string]$entry.label)
    $styleItem.Checked = ($styleChoice -eq $videoState.transitionStyle)
    $transitionItems[$styleChoice] = $styleItem
    [void]$transitionMenu.DropDownItems.Add($styleItem)
    $styleItem.add_Click({
        [void](Set-DesktopLocalControl @{transitionStyle=$styleChoice})
    }.GetNewClosure())
}
# Real Windows observation: Source updates are distinct from monitor refresh FPS.
$diagnosticsMenu = [System.Windows.Forms.ToolStripMenuItem]::new('연결·진단')
[void]$menu.Items.Add($diagnosticsMenu)
$bridgeMenuStatus = $diagnosticsMenu.DropDownItems.Add('Bridge: 로컬 수신 대기')
$bridgeMenuStatus.Enabled = $false
$copyKey = $diagnosticsMenu.DropDownItems.Add('페어링 코드 복사')
[void]$diagnosticsMenu.DropDownItems.Add([System.Windows.Forms.ToolStripSeparator]::new())
$test = $diagnosticsMenu.DropDownItems.Add('테두리 진단 · 10초')
$brightTest = $diagnosticsMenu.DropDownItems.Add('RGB 밝기 진단 · 10초')
$statsItem = $diagnosticsMenu.DropDownItems.Add('영상 프레임 통계 · 최근 10초')
$statsItem.add_Click({
    $items = @($videoState.frameTimes.ToArray())
    $fresh = @($items | Where-Object { ([DateTime]::UtcNow - $_).TotalSeconds -le 10 })
    $fps = [Math]::Round($fresh.Count/10.0,2)
    $lastAge = if ($videoState.lastFrameUtc -eq [DateTime]::MinValue) { '수신 기록 없음' } else { [Math]::Round(([DateTime]::UtcNow - $videoState.lastFrameUtc).TotalSeconds, 1).ToString() + '초 전' }
    $transitionLabel = switch ($videoState.transitionStyle) { 'instant' { '즉시' } 'cinematic' { '천천히 (310ms)' } default { '짧게 (95ms)' } }
    $lines = @('최근 10초 영상 Source 갱신 수: ' + $fresh.Count,
               'Source 갱신률 (10초 기준): ' + $fps + ' FPS',
               '마지막 프레임: ' + $lastAge,
               '영상 전환: ' + $transitionLabel,
               '모니터 표시 FPS와는 다릅니다.',
               $(if($ExperimentalVideoFps -gt 0){'실험 목표: '+$ExperimentalVideoFps+' FPS (저장하지 않음)'}else{'Quality 영상 상한은 4 FPS이며 실제 갱신률은 Chrome·Windows 상태에 따라 달라집니다.'}))
    [System.Windows.Forms.MessageBox]::Show(($lines -join [Environment]::NewLine),'Ambient Workspace · Desktop 영상 진단') | Out-Null
}.GetNewClosure())

# Coverage is independent of the RGB center protection, and is persisted locally.
$coverageMenu = [System.Windows.Forms.ToolStripMenuItem]::new('영상 범위')
[void]$videoDetailsMenu.DropDownItems.Add($coverageMenu)
$coverageItems = @{}
foreach ($entry in @(
    @{key='follow';label='중앙 보호 설정 따름'},
    @{key='narrow';label='좁게 (가독성 우선)'},
    @{key='balanced';label='기본'},
    @{key='wide';label='넓게 (영상 강조)'})) {
    $coverageChoice = [string]$entry.key
    $coverageItem = [System.Windows.Forms.ToolStripMenuItem]::new([string]$entry.label)
    $coverageItem.Checked = ($coverageChoice -eq $videoState.coverage)
    $coverageItems[$coverageChoice] = $coverageItem
    [void]$coverageMenu.DropDownItems.Add($coverageItem)
    $coverageItem.add_Click({
        [void](Set-DesktopLocalControl @{coverage=$coverageChoice})
    }.GetNewClosure())
}
$copyKey.Enabled = $bridgeEnabled
$copyKey.add_Click({
    try {
        $code = [System.IO.File]::ReadAllText($bridgeKeyPath).Trim()
        [System.Windows.Forms.Clipboard]::SetText($code)
        [System.Windows.Forms.MessageBox]::Show('페어링 코드를 복사했습니다. Chrome 확장의 연결 설정에 붙여넣어 주세요. 코드는 다른 사람에게 공유하지 마세요.', 'Ambient Workspace') | Out-Null
    } catch { [System.Windows.Forms.MessageBox]::Show('페어링 코드를 복사하지 못했습니다. Desktop 연결 상태를 확인한 뒤 다시 시도해 주세요.', 'Ambient Workspace') | Out-Null }
}.GetNewClosure())
[void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
$exit = $menu.Items.Add('Desktop 앱 종료')
$test.add_Click({
    if (-not (Request-DesktopDiagnostic 'border')) { [void][System.Windows.MessageBox]::Show('Desktop 효과를 재개하고 전체 사용 및 RGB 또는 영상을 켠 뒤 진단해 주세요.', 'Ambient Workspace') }
}.GetNewClosure())
$brightTest.add_Click({
    if (-not (Request-DesktopDiagnostic 'bright')) { [void][System.Windows.MessageBox]::Show('Desktop 효과를 재개하고 전체 사용 및 RGB 조명을 켠 뒤 진단해 주세요.', 'Ambient Workspace') }
}.GetNewClosure())
$toggle.add_Click({
    [void](Set-DesktopLocalControl @{globalPaused=(-not $localControl.config.control.globalPaused)})
}.GetNewClosure())
$exit.add_Click({
    # The outer finally also covers initialization failures and programmatic shutdown.
    if ($null -ne $settingsHost.session) { $settingsHost.session.discardOnClose=$true }
    [System.Windows.Application]::Current.Shutdown()
}.GetNewClosure())
$menu.add_Opening({ Update-DesktopControlMenu }.GetNewClosure())
$tray.ContextMenuStrip = $menu
Apply-DesktopLocalControl
Update-DesktopControlMenu

$app = New-Object System.Windows.Application
$app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
Sync-DesktopGlobalHotkey
if ($null -ne $controlRuntime) {
    $controlTimer=[Windows.Threading.DispatcherTimer]::new([Windows.Threading.DispatcherPriority]::Background)
    $controlTimer.Interval=[TimeSpan]::FromMilliseconds(100)
    $controlTick=[EventHandler]({ Invoke-DesktopControlTick }.GetNewClosure())
    $controlTimer.Add_Tick($controlTick)
    $controlTimer.Start()
}
$timer.Start()
$videoPoll.Start()
if ($PortableLaunch) {
    $tray.BalloonTipTitle='Ambient Workspace 실행 중'
    $tray.BalloonTipText='설정은 트레이 아이콘을 두 번 클릭하세요. 종료는 오른쪽 클릭 → Desktop 앱 종료입니다.'
    $tray.ShowBalloonTip(5000)
    if ($showPortableGuide) {
        Show-SettingsWindow
        if ($null -ne $settingsHost.session) { $settingsHost.session.controls.SettingsTabs.SelectedIndex=4 }
    }
}
# Do not auto-show the overlay on startup when persisted output/pause gates are off.
# The existing foreground tick shows it only when a supported target is active.
[void]$app.Run()
} finally {
    try {
        Invoke-AmbientCleanup @(
            { Stop-DesktopGlobalHotkey },
            { if ($controlTimer) { $controlTimer.Stop(); if ($controlTick) { $controlTimer.Remove_Tick($controlTick) } } },
            { if ($timer) { $timer.Stop(); if ($windowTick) { $timer.Remove_Tick($windowTick) } } },
            { if ($videoPoll) { $videoPoll.Stop(); if ($videoTick) { $videoPoll.Remove_Tick($videoTick) } } },
            { if ($videoRelease) { $videoRelease.Stop(); if ($releaseTick) { $videoRelease.Remove_Tick($releaseTick) } } },
            { if ($videoWash -and $videoWashPrev -and $videoState) { Clear-VideoFrames } },
            { if ($left -and $right -and $bottom) { Set-GlowMotion $false 75 } },
            { if ($null -ne $settingsHost.session) { $settingsHost.session.discardOnClose=$true; $settingsHost.session.window.Close() } },
            { if ($window) { $window.Close() } },
            { if ($tray) { $tray.Visible=$false; $tray.Dispose() } },
            { if ($menu) { $menu.Dispose() } },
            { if ($metricsRuntime.enabled) { foreach($file in @($metricsRuntime.path,($metricsRuntime.path+'.tmp'))) { if([IO.File]::Exists($file)){[IO.File]::Delete($file)} } } },
            { Stop-AmbientBridge $bridgeRuntime },
            { Stop-AmbientControlChannel $controlRuntime $PSScriptRoot },
            { Remove-AmbientRuntimeFiles $PSScriptRoot -IncludeSnapshots }
        )
    } finally { Exit-AmbientInstance $instanceLease }
}
