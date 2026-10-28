# Real product commands, tray handlers and WPF objects, with a simulated foreground HWND.
# No production settings, real foreground window, tray icon, app loop or bridge is used.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop' -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Use Windows PowerShell 5.1 -STA' }
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms,System.Drawing
$base=Split-Path $PSScriptRoot
. (Join-Path $base 'Desktop_Companion/Lifecycle.ps1')
. (Join-Path $base 'Desktop_Companion/Frame-Metrics.ps1')
. (Join-Path $base 'Desktop_Companion/Control-State.ps1')
. (Join-Path $base 'Desktop_Companion/Global-Hotkey.ps1')
. (Join-Path $base 'Desktop_Companion/Control-Channel.ps1')
$controlRuntime=$null
. (Join-Path $base 'Desktop_Companion/Settings-Window.ps1')
function Assert-True($Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Open-TestTrayMenu {
    # Raise the real Opening event without showing a menu or touching the user's desktop.
    $opening=$menu.GetType().GetMethod('OnOpening',([Reflection.BindingFlags]::Instance -bor [Reflection.BindingFlags]::NonPublic))
    [void]$opening.Invoke($menu,@([ComponentModel.CancelEventArgs]::new()))
}
$tokens=$null; $parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $base 'Desktop_Companion/Start-AmbientDesktop.ps1'),[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count) { throw 'Desktop parse failed' }
function Get-Assignment([string]$Name,[string]$Pattern='.') {
    return $ast.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq $Name -and $n.Right.Extent.Text -match $Pattern},$true)
}
foreach ($name in @('Apply-DesktopLocalControl','Get-DesktopTrayReception','Update-DesktopTrayStatus','Update-DesktopControlMenu','Set-DesktopLocalControl','Request-DesktopDiagnostic','Clear-VideoFrames','Show-VideoFrame','Try-UpdateYoutubeVideo','Try-UpdateYoutubeColors','Set-VideoCoverage','Set-GlowMotion','Animate-Glow','Resize-Lights','Set-CenterMask','Resolve-PaletteColors','Update-Lights','Set-GlowBrush','Set-EdgeBrush')) {
    $node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    if ($null -eq $node) { throw ('Missing product function: '+$name) }
    . ([ScriptBlock]::Create($node.Extent.Text))
}
# Replace only notification rendering in this test process; save failures are still real.
$notices=[pscustomobject]@{count=0}
function Show-DesktopControlSaveError { $notices.count++ }
# Only the foreground/JPEG consumer is under test here; do not launch a listener.
function Ensure-AmbientBridge { }
Add-Type -TypeDefinition @'
using System;
public static class AmbientNative {
    public struct RECT { public int Left, Top, Right, Bottom; }
    public static bool Supported = true;
    public static bool Iconic = false, ValidRect = true, DwmFail = false;
    public static string ProcessName = System.Diagnostics.Process.GetCurrentProcess().ProcessName;
    public static int Handle = 1, Left = 10, PlacedLeft = 0, PlacedWidth = 0, PlacedHeight = 0;
    public static IntPtr PidHandle, RectHandle;
    public static IntPtr GetForegroundWindow() { return Supported ? new IntPtr(Handle) : IntPtr.Zero; }
    public static bool IsIconic(IntPtr h) { return Iconic; }
    public static uint GetWindowThreadProcessId(IntPtr h, out uint id) { PidHandle=h; id=4242; return 1; }
    public static int DwmGetWindowAttribute(IntPtr h,int a,out RECT r,int size) { GetWindowRect(h,out r); return DwmFail ? 1 : 0; }
    public static bool GetWindowRect(IntPtr h,out RECT r) { RectHandle=h; r=new RECT {Left=Left,Top=10,Right=ValidRect ? Left+800 : Left+100,Bottom=550}; return true; }
    public static bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int height,uint flags) { PlacedLeft=x; PlacedWidth=w; PlacedHeight=height; return true; }
}
'@
# Replace only the OS process lookup in the extracted callback, alongside the native
# HWND fixture above. Target matching, rect/opacity, output gating and WPF are real.
function Get-TestForegroundProcess([int]$ProcessId) {
    Assert-True ($ProcessId -eq 4242) 'Process lookup must use the PID resolved from the foreground HWND'
    $process=[pscustomobject]@{ProcessName=[AmbientNative]::ProcessName}
    $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value { }
    return $process
}
$artifacts=Join-Path $base 'artifacts'; [void][IO.Directory]::CreateDirectory($artifacts)
$sandbox=Join-Path $artifacts ('desktop-control-test-'+[Guid]::NewGuid().ToString('N')); [void][IO.Directory]::CreateDirectory($sandbox)
$menu=$null; $template=$null; $videoRelease=$null; $releaseTick=$null; $renderReady=$false
$videoPoll=$null; $videoTick=$null
try {
    $config=Get-Content (Join-Path $base 'Desktop_Companion/settings.defaults.json') -Raw | ConvertFrom-Json
    $configPath=Join-Path $sandbox 'settings.json'
    Save-AmbientSettings $config $configPath
    $localControl=New-AmbientLocalControl $config $configPath
    $runtime=[pscustomobject]@{palette=$config.palette;strength=$config.strength;colors=@(Resolve-PaletteColors $config.palette);spread=$config.spread;protection=$config.centerProtection;motion=$config.motion;seconds=$config.animationSeconds}
    $bridgeState=[pscustomobject]@{baseColors=@($runtime.colors);active=$false;lastPacket=''}
    $bridgeRuntime=[pscustomobject]@{status='disabled'}
    $bridgeEnabled=$true; $metricsRuntime=[pscustomobject]@{enabled=$true;nextUtc=[DateTime]::MaxValue}
    $bridgeRunner='unused-test-listener'; $bridgePort=0; $parentStartTicks=0; $ExperimentalVideoFps=0
    $bridgeSnapshotPath=Join-Path $sandbox 'bridge-colors.json'; $bridgeStaleSeconds=7; $bridgeBlend=0.35
    $bridgeDirectory=$sandbox; $logPath=Join-Path $sandbox 'diagnostic-log.txt'; $debugBorderEnabled=$false
    $perAppMultiplier=@{}; $targets=@((Get-Process -Id $PID).ProcessName.ToLowerInvariant())
    [xml]$xml=Get-Content (Join-Path $base 'Desktop_Companion/Overlay.xaml') -Raw -Encoding UTF8
    $reader=[Xml.XmlNodeReader]::new($xml)
    try { $template=[Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Dispose() }
    $surface=$template.FindName('AmbientSurface'); $debugBorder=$template.FindName('DebugBorder')
    $left=$template.FindName('GlowLeft'); $right=$template.FindName('GlowRight'); $bottom=$template.FindName('GlowBottom')
    $edgeLeft=$template.FindName('EdgeLeft'); $edgeRight=$template.FindName('EdgeRight'); $edgeBottom=$template.FindName('EdgeBottom')
    $videoWash=$template.FindName('VideoWash'); $videoWashPrev=$template.FindName('VideoWashPrev')
    $videoWashPrev.OpacityMask=$videoWash.OpacityMask
    $window=[pscustomobject]@{Visibility=[Windows.Visibility]::Hidden;ActualWidth=800;ActualHeight=540;showCount=0;hideCount=0}
    $window | Add-Member -MemberType ScriptMethod -Name Show -Value { $this.Visibility=[Windows.Visibility]::Visible; $this.showCount++ }
    $window | Add-Member -MemberType ScriptMethod -Name Hide -Value { $this.Visibility=[Windows.Visibility]::Hidden; $this.hideCount++ }
    . ([ScriptBlock]::Create((Get-Assignment '$state').Extent.Text))
    $defaultsStart=(Get-Assignment '$coverageDefault').Extent.StartOffset
    $defaultsEnd=(Get-Assignment '$videoState' 'pscustomobject').Extent.EndOffset
    . ([ScriptBlock]::Create($ast.Extent.Text.Substring($defaultsStart,$defaultsEnd-$defaultsStart)))
    . ([ScriptBlock]::Create((Get-Assignment '$videoRelease' 'New-Object').Extent.Text))
    . ([ScriptBlock]::Create((Get-Assignment '$releaseTick' 'EventHandler').Extent.Text))
    $videoRelease.Add_Tick($releaseTick)
    $renderReady=$true
    # Build the real menus and closures, but never create/show NotifyIcon or SettingsWindow.
    $menuStart=(Get-Assignment '$menu' 'New-Object').Extent.StartOffset
    $menuEnd=(Get-Assignment '$tray.ContextMenuStrip').Extent.StartOffset
    . ([ScriptBlock]::Create($ast.Extent.Text.Substring($menuStart,$menuEnd-$menuStart)))
    $windowTickCode=(Get-Assignment '$windowTick' 'EventHandler').Extent.Text
    $processQuery='[Diagnostics.Process]::GetProcessById([int]$targetProcessId)'
    Assert-True (($windowTickCode.Split(@($processQuery),[StringSplitOptions]::None)).Count -eq 2) 'Exactly one OS process lookup must be replaced in the foreground fixture'
    . ([ScriptBlock]::Create($windowTickCode.Replace($processQuery,'(Get-TestForegroundProcess ([int]$targetProcessId))')))
    Apply-DesktopLocalControl; Update-DesktopControlMenu
    $windowTick.Invoke($null,[EventArgs]::Empty)
    Assert-True ($state.lastError -eq '' -and $window.Visibility -eq [Windows.Visibility]::Visible) 'Default foreground logic must still show supported Desktop effects'
    Assert-True ($desktopToggle.Checked -and $rgbToggle.Checked -and $videoToggle.Checked) 'Initial menus must match the combined default'
    Write-Output 'PASS actual product menus and foreground callback preserve the default combined output'
    $fakeNow=[long]1000000
    $clientFixture=[pscustomobject]@{instanceId='fixture';revision=$localControl.revision;globalPaused=$localControl.config.control.globalPaused;utcMs=($fakeNow-6000);parts=[pscustomobject]@{desktop='applied';web='off';youtube='notRequired';capture='notRequired'}}
    Assert-True ((Get-AmbientIntegrationPresentation $clientFixture $localControl 'fixture' $fakeNow).status -eq 'complete') 'Idle OFF/absent Chrome must fit the existing one-minute alarm without a false error'
    $clientFixture.parts.web='applied'
    Assert-True ((Get-AmbientIntegrationPresentation $clientFixture $localControl 'fixture' $fakeNow).status -eq 'error') 'Active output reports must expire at five seconds'
    $clientFixture.utcMs=$fakeNow;$clientFixture.parts.web='waiting'
    Assert-True ((Get-AmbientIntegrationPresentation $clientFixture $localControl 'fixture' $fakeNow).status -eq 'partial') 'A pending renderer cannot imply whole completion'
    $clientFixture.revision++
    Assert-True ((Get-AmbientIntegrationPresentation $clientFixture $localControl 'fixture' $fakeNow).status -eq 'waiting') 'An old report cannot acknowledge the current Desktop state'
    Write-Output 'PASS integration OFF scope, active expiry, partial apply and revision matching'
    $clientFixture.revision=$localControl.revision;$clientFixture.parts.web='independent'
    $separate=Get-AmbientIntegrationPresentation $clientFixture $localControl 'fixture' $fakeNow
    Assert-True ($separate.status -eq 'independent' -and $separate.title -like '*Chrome 별도 제어*') 'A different Chrome pause phase must not claim whole completion or wait forever'
    $clientFixture.utcMs=$fakeNow-6000
    Assert-True ((Get-AmbientIntegrationPresentation $clientFixture $localControl 'fixture' $fakeNow).status -eq 'error') 'Separate Chrome state must still expire and cannot bypass freshness'
    Write-Output 'PASS independent Chrome/Windows pause presentation and unchanged freshness boundary'


    $labels=@($menu.Items | Where-Object { $_ -is [Windows.Forms.ToolStripMenuItem] } | ForEach-Object { $_.Text })
    $expected=@('통합 효과 일시정지','Desktop 효과 전체 사용','RGB 조명 사용','흐릿한 영상 사용','빠른 세기 조절','현재 수신·표시 상태','설정 열기…','영상 상세 설정 (임시)','연결·진단','Desktop 앱 종료')
    Assert-True (($labels -join '|') -ceq ($expected -join '|')) 'The native top-level order and Korean scope labels must match UI-3'
    Assert-True ($menu -is [Windows.Forms.ContextMenuStrip] -and $menu.Items[$menu.Items.Count-2] -is [Windows.Forms.ToolStripSeparator]) 'Exit must remain separated in the native ContextMenuStrip'
    Assert-True ($transitionMenu.OwnerItem -eq $videoDetailsMenu -and $coverageMenu.OwnerItem -eq $videoDetailsMenu -and -not $videoDetailsNote.Enabled) 'Legacy video details must remain reachable in the temporary submenu'
    foreach ($item in @($copyKey,$test,$brightTest,$statsItem,$bridgeMenuStatus)) { Assert-True ($item.OwnerItem -eq $diagnosticsMenu) 'Connection and diagnostics must be grouped without dropping commands' }
    foreach ($item in @($rgbReceiveStatus,$videoReceiveStatus,$desktopDisplayStatus,$saveMenuStatus,$statusTime)) { Assert-True (-not $item.Enabled -and $item.OwnerItem -eq $statusMenu) 'Status rows must be read-only' }
    $launches=[pscustomobject]@{count=0}
    function Show-SettingsWindow { $launches.count++ }
    $settingsItem.PerformClick(); $settingsItem.PerformClick()
    Assert-True ($launches.count -eq 2) 'Settings clicks must still route to the existing window command'
    Write-Output 'PASS UI-3 native menu order, Korean labels, temporary detail access and settings launch route'

    $beforeRead=[IO.File]::ReadAllText($configPath); $revision=$localControl.revision
    $fixture=Join-Path $sandbox 'bridge-frame-tray-fixture.jpg'
    [IO.File]::WriteAllBytes($fixture,(New-Object byte[] 200))
    [IO.File]::WriteAllText($bridgeSnapshotPath,(@{utc=[DateTime]::UtcNow.ToString('o');left='#804020';right='#204080'} | ConvertTo-Json -Compress))
    # Reception must be independent of consumer flags; no image decoding is performed by the menu.
    $received=Get-DesktopTrayReception
    Assert-True ($received.rgbFresh -and $received.videoFresh -and -not $bridgeState.active -and -not $videoState.active) 'Fresh local metadata must be detected even when the consumers are inactive'
    Open-TestTrayMenu
    Assert-True ($rgbReceiveStatus.Text -like '*최근 색상 수신 확인*' -and $videoReceiveStatus.Text -like '*표시와 별개*' -and $desktopDisplayStatus.Text -like '*기본 팔레트*' -and $statusTime.Text -like '*다시 열면 갱신*') 'Opening must refresh reception separately from actual display'
    Assert-True ($localControl.revision -eq $revision -and [IO.File]::ReadAllText($configPath) -ceq $beforeRead -and -not $bridgeState.active -and -not $videoState.active) 'Reading/opening the menu must not persist settings, consume a frame or activate an effect'
    [IO.File]::SetLastWriteTimeUtc($fixture,[DateTime]::UtcNow.AddSeconds(-5))
    [IO.File]::WriteAllText($bridgeSnapshotPath,(@{utc=[DateTime]::UtcNow.AddSeconds(-8).ToString('o');left='#804020';right='#204080'} | ConvertTo-Json -Compress))
    Open-TestTrayMenu
    Assert-True ($rgbReceiveStatus.Text -like '*만료*' -and $videoReceiveStatus.Text -like '*만료*') 'Reopening must expire old reception rather than claim an ongoing connection'
    [IO.File]::WriteAllText($bridgeSnapshotPath,'{"utc":"invalid"}')
    [IO.File]::Delete($fixture)
    Open-TestTrayMenu
    Assert-True ($rgbReceiveStatus.Text -like '*확인 불가*' -and $videoReceiveStatus.Text -eq '영상 수신: 수신 대기') 'Malformed or missing metadata must leave the menu usable with honest status'
    $bridgeEnabled=$false; Open-TestTrayMenu
    Assert-True ($rgbReceiveStatus.Text -like '*Bridge 사용 안 함*' -and $videoReceiveStatus.Text -like '*Bridge 사용 안 함*' -and $bridgeMenuStatus.Text -eq 'Bridge: 사용 안 함') 'Disabled Bridge must be reported without implying connected outputs'
    $bridgeEnabled=$true
    foreach ($bridgePhase in @('retrying; check bridge-log.txt or port availability','start failed; retrying (check PowerShell and bridge files)')) {
        $bridgeRuntime.status=$bridgePhase; Open-TestTrayMenu
        Assert-True ($bridgeMenuStatus.Text -like '*연결 재시도 중*') 'Supervisor retries must use a Korean diagnostic label'
    }
    $bridgeRuntime.status='waiting for colors'
    [IO.File]::Delete($bridgeSnapshotPath)
    Write-Output 'PASS UI-3 read-only reception snapshots, expiry, missing/malformed input, Bridge disabled/retry and menu reopen'

    foreach ($choice in @('soft','balanced','vivid','balanced')) {
        $intensityItems[$choice].PerformClick()
        Assert-True ($localControl.config.desktopOutput.intensity -eq $choice -and @($intensityItems.Values | Where-Object Checked).Count -eq 1) 'Every quick intensity choice must keep exactly one persisted selection'
    }
    foreach ($choice in @('narrow','balanced','wide','follow')) {
        $coverageItems[$choice].PerformClick()
        Assert-True ($videoState.coverage -eq $choice -and @($coverageItems.Values | Where-Object Checked).Count -eq 1) 'Every temporary coverage choice must still apply and retain one selection'
    }
    foreach ($choice in @('instant','cinematic','brief')) {
        $transitionItems[$choice].PerformClick()
        Assert-True ($videoState.transitionStyle -eq $choice -and @($transitionItems.Values | Where-Object Checked).Count -eq 1) 'Every temporary transition choice must still apply and retain one selection'
    }
    Write-Output 'PASS UI-3 all quick intensity, coverage and transition choices retain the common persistence path'

    $rgbToggle.PerformClick()
    Assert-True (-not $localControl.config.desktopOutput.rgbEnabled -and $localControl.config.desktopOutput.videoEnabled -and $videoState.enabled) 'RGB click must leave video enabled'
    Assert-True ($surface.Visibility -eq [Windows.Visibility]::Collapsed -and -not $rgbToggle.Checked -and $videoToggle.Checked) 'RGB click must hide only its WPF plane and sync menu state'
    $videoToggle.PerformClick(); $windowTick.Invoke($null,[EventArgs]::Empty)
    Assert-True ($window.Visibility -eq [Windows.Visibility]::Hidden -and -not $videoState.enabled) 'Both outputs off must hide the overlay'
    Open-TestTrayMenu
    Assert-True ($desktopDisplayStatus.Text -eq 'Desktop 표시: RGB·영상 모두 꺼짐') 'Both disabled outputs must be distinguished from a connection failure'
    $rgbToggle.PerformClick(); $windowTick.Invoke($null,[EventArgs]::Empty)
    Assert-True ($surface.Visibility -eq [Windows.Visibility]::Visible -and -not $videoState.enabled -and $window.Visibility -eq [Windows.Visibility]::Visible) 'RGB-only must work independently'
    Open-TestTrayMenu
    Assert-True ($desktopDisplayStatus.Text -like '*RGB 조명*' -and $desktopDisplayStatus.Text -notlike '*흐릿한 영상*') 'RGB-only display status must not claim video'
    $videoToggle.PerformClick()
    $pixels=New-Object byte[] 16
    $image=[Windows.Media.Imaging.BitmapSource]::Create(2,2,96,96,[Windows.Media.PixelFormats]::Bgra32,$null,$pixels,8); $image.Freeze()
    Show-VideoFrame $image; $videoState.active=$true; $windowTick.Invoke($null,[EventArgs]::Empty)
    Assert-True ([Math]::Abs($left.Opacity-($runtime.strength/0.88*0.32)) -lt 0.001) 'Combined video must retain the existing RGB 0.32 brightness factor'
    Open-TestTrayMenu
    Assert-True ($desktopDisplayStatus.Text -like '*RGB 조명*흐릿한 영상*표시 중*') 'Combined display status must describe both actual planes'
    Write-Output 'PASS real tray clicks support RGB-only, video-only, both and neither without replacing the combination'

    [void](Set-DesktopLocalControl @{motion=$true})
    Show-VideoFrame $image; Show-VideoFrame $image; $videoState.active=$true
    Assert-True ($videoRelease.IsEnabled -and $left.RenderTransform.HasAnimatedProperties) 'Fixture must have live transition and motion clocks before pause'
    $toggle.PerformClick()
    Assert-True ($localControl.config.control.globalPaused -and $window.Visibility -eq [Windows.Visibility]::Hidden -and -not $videoState.enabled) 'Pause click must immediately gate Desktop output'
    Assert-True ($null -eq $videoWash.Source -and $null -eq $videoWashPrev.Source -and -not $videoRelease.IsEnabled -and -not $left.RenderTransform.HasAnimatedProperties) 'Pause must release WPF frames and animation clocks'
    Assert-True ($rgbToggle.Checked -and $videoToggle.Checked -and $toggle.Text -eq '통합 효과 재개') 'Pause must retain output preferences in the menu'
    Assert-True ($desktopDisplayStatus.Text -eq 'Desktop 표시: Desktop 효과 일시정지') 'Pause must take priority over reception in display status'
    $shows=$window.showCount; $windowTick.Invoke($null,[EventArgs]::Empty)
    Assert-True ($window.showCount -eq $shows) 'A persisted paused foreground tick must not show the overlay'
    Assert-True (-not (Request-DesktopDiagnostic 'border') -and -not (Request-DesktopDiagnostic 'bright') -and $localControl.config.control.globalPaused) 'Diagnostics must not unpause Desktop effects'
    [void](Set-DesktopLocalControl @{palette='forest';coverage='wide';transitionStyle='instant'})
    Assert-True ($localControl.config.control.globalPaused -and -not $videoState.enabled -and $window.Visibility -eq [Windows.Visibility]::Hidden) 'Appearance changes during pause must not resume any output'
    $toggle.PerformClick(); $windowTick.Invoke($null,[EventArgs]::Empty)
    Assert-True (-not $localControl.config.control.globalPaused -and $videoState.enabled -and $left.RenderTransform.HasAnimatedProperties) 'Resume must restore allowed motion/video settings'
    Show-VideoFrame $image
    $hides=$window.hideCount; $revision=$localControl.revision
    [void](Set-DesktopLocalControl @{globalPaused=$false})
    Assert-True ($window.hideCount -eq $hides -and $localControl.revision -eq $revision -and [object]::ReferenceEquals($videoWash.Source,$image)) 'Duplicate command must not clear images or replay view changes'
    Write-Output 'PASS pause/resume clears resources, preserves preferences and blocks diagnostic bypass/duplicate replay'

    $desktopToggle.PerformClick(); $toggle.PerformClick(); $toggle.PerformClick(); $windowTick.Invoke($null,[EventArgs]::Empty)
    Assert-True (-not $desktopToggle.Checked -and $window.Visibility -eq [Windows.Visibility]::Hidden) 'Pause/resume must retain a disabled Desktop master'
    Open-TestTrayMenu
    Assert-True ($desktopDisplayStatus.Text -eq 'Desktop 표시: Desktop 효과 전체 꺼짐') 'Disabled master must remain distinct from pause and connection failure'
    $desktopToggle.PerformClick()
    $intensityItems['vivid'].PerformClick(); $coverageItems['narrow'].PerformClick(); $transitionItems['cinematic'].PerformClick()
    Assert-True ($localControl.config.desktopOutput.intensity -eq 'vivid' -and $videoState.coverage -eq 'narrow' -and $videoState.transitionMs -eq 310) 'Existing intensity/coverage/transition clicks must use the common command path'
    $restored=New-AmbientLocalControl (Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json) $configPath
    Assert-True ($restored.config.desktopOutput.intensity -eq 'vivid' -and $restored.config.desktopVideo.coverage -eq 'narrow') 'Actual tray changes must survive a settings reload'
    Write-Output 'PASS Desktop master, existing tray choices, menu synchronization and restart persistence'

    $held=[IO.File]::Open(($configPath+'.tmp'),[IO.FileMode]::Create,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $heldDiagnostic=$null
    try {
        $heldDiagnostic=[IO.File]::Open($logPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $before=[IO.File]::ReadAllText($configPath)
        $videoToggle.PerformClick()
        Assert-True ($videoToggle.Checked -and $videoState.enabled -and $localControl.config.desktopOutput.videoEnabled) 'A failed tray save must preserve actual and checked video state'
        $toggle.PerformClick()
        Assert-True ($localControl.savePending -and $localControl.config.control.globalPaused -and $toggle.Text -like '*저장 안 됨*' -and $window.Visibility -eq [Windows.Visibility]::Hidden) 'Failed pause save must stay paused and explicitly show unsaved state'
        Assert-True ($saveMenuStatus.Text -like '*저장 안 됨*' -and $desktopDisplayStatus.Text -like '*일시정지*') 'Unsaved pause must be explicit in the status submenu too'
        Assert-True ($notices.count -eq 2 -and [IO.File]::ReadAllText($configPath) -ceq $before) 'Each real save failure must notify without replacing the settings file'
    } finally { if ($null -ne $heldDiagnostic) { $heldDiagnostic.Dispose() }; $held.Dispose() }
    [void](Set-DesktopLocalControl @{globalPaused=$true})
    Assert-True (-not $localControl.savePending -and $toggle.Text -eq '통합 효과 재개') 'Successful pause retry must clear the unsaved menu state'
    Write-Output 'PASS real tray save failure with locked diagnostic log, unchanged checks, unsaved pause notification and retry'

    # Exercise the real JPEG decoder and production poll callback, rather than only assigning a bitmap.
    $encoder=[Windows.Media.Imaging.JpegBitmapEncoder]::new()
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($image))
    $memory=[IO.MemoryStream]::new()
    try { $encoder.Save($memory); $jpeg=$memory.ToArray() } finally { $memory.Dispose() }
    $producer=[pscustomobject]@{count=0;latest=''}
    function Publish-TestJpeg {
        $path=Join-Path $sandbox ('bridge-frame-control-'+[Guid]::NewGuid().ToString('N')+'.jpg')
        [IO.File]::WriteAllBytes($path,$jpeg)
        # Keep exactly the latest synthetic immutable frame, without timestamp tie ambiguity.
        if ($producer.latest) { [IO.File]::Delete($producer.latest) }
        $producer.latest=$path; $producer.count++
    }
    $pollStart=(Get-Assignment '$videoPoll' 'New-Object').Extent.StartOffset
    $pollEnd=$ast.Find({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Extent.Text -eq '$videoPoll.Add_Tick($videoTick)'},$true).Extent.EndOffset
    . ([ScriptBlock]::Create($ast.Extent.Text.Substring($pollStart,$pollEnd-$pollStart)))
    [void](Set-DesktopLocalControl @{globalPaused=$false;desktopEnabled=$true;motion=$false;transitionStyle='instant'})
    $probe=$videoState.pipeline
    foreach ($rgb in @($true,$false)) {
        foreach ($video in @($true,$false)) {
            [void](Set-DesktopLocalControl @{rgbEnabled=$rgb;videoEnabled=$video})
            $before=$probe.stages.uniqueFrame.count
            $hiddenBefore=$probe.stages.hidden.count; $staleBefore=$probe.stages.stale.count
            for ($i=0;$i -lt 3;$i++) {
                Publish-TestJpeg
                $windowTick.Invoke($null,[EventArgs]::Empty)
                $videoTick.Invoke($null,[EventArgs]::Empty)
                Assert-True (($surface.Visibility -eq [Windows.Visibility]::Visible) -eq $rgb) 'Video polling must not change the independent RGB plane gate'
                if ($video) {
                    Assert-True ($videoState.active -and $videoWash.Source.IsFrozen -and $videoWash.Visibility -eq [Windows.Visibility]::Visible) 'Each fresh JPEG must keep the enabled video plane active'
                } else { Assert-True ($null -eq $videoWash.Source -and -not $videoState.active) 'Disabled video must not decode a fresh JPEG' }
            }
            Assert-True (($probe.stages.uniqueFrame.count-$before) -eq $(if($video){3}else{0})) 'Only video-enabled combinations may advance uniqueFrame'
            Assert-True ($probe.stages.hidden.count -eq $hiddenBefore -and $probe.stages.stale.count -eq $staleBefore) 'Fresh supported video must not be classified as hidden or stale'
            Assert-True (($window.Visibility -eq [Windows.Visibility]::Visible) -eq ($rgb -or $video)) 'All four output combinations must preserve the foreground window contract'
        }
    }
    Write-Output 'PASS fresh JPEG continuity across all four RGB/video combinations with real poll callback and uniqueFrame counters'

    [void](Set-DesktopLocalControl @{rgbEnabled=$false;videoEnabled=$true})
    Publish-TestJpeg; $windowTick.Invoke($null,[EventArgs]::Empty); $videoTick.Invoke($null,[EventArgs]::Empty)
    $uniqueBefore=$probe.stages.uniqueFrame.count; $staleBefore=$probe.stages.stale.count; $hiddenBefore=$probe.stages.hidden.count
    [IO.File]::SetLastWriteTimeUtc($producer.latest,[DateTime]::UtcNow.AddSeconds(-5))
    $videoTick.Invoke($null,[EventArgs]::Empty); $windowTick.Invoke($null,[EventArgs]::Empty)
    Assert-True ($probe.stages.stale.count -eq $staleBefore+1 -and $probe.stages.hidden.count -eq $hiddenBefore -and $probe.stages.uniqueFrame.count -eq $uniqueBefore) 'A stopped producer must be classified as stale, not a hidden window or a new frame'
    Assert-True ($null -eq $videoWash.Source -and $null -eq $videoWashPrev.Source -and $surface.Visibility -eq [Windows.Visibility]::Collapsed) 'Video expiry must release both frames without enabling RGB'
    Publish-TestJpeg; $videoTick.Invoke($null,[EventArgs]::Empty)
    Assert-True ($videoState.active -and $probe.stages.uniqueFrame.count -eq $uniqueBefore+1 -and $surface.Visibility -eq [Windows.Visibility]::Collapsed) 'Fresh input must restore video-only without enabling RGB'
    Write-Output 'PASS producer stop/stale classification, RGB-off expiry and automatic video-only recovery'

    [void](Set-DesktopLocalControl @{rgbEnabled=$true})
    [IO.File]::WriteAllText($bridgeSnapshotPath,(@{utc=[DateTime]::UtcNow.ToString('o');left='#804020';right='#204080'} | ConvertTo-Json -Compress))
    $windowTick.Invoke($null,[EventArgs]::Empty)
    Assert-True $bridgeState.active 'Fixture must apply a fresh RGB snapshot before testing fallback'
    [IO.File]::WriteAllText($bridgeSnapshotPath,(@{utc=[DateTime]::UtcNow.AddSeconds(-8).ToString('o');left='#804020';right='#204080'} | ConvertTo-Json -Compress))
    [IO.File]::SetLastWriteTimeUtc($producer.latest,[DateTime]::UtcNow.AddSeconds(-5))
    $videoTick.Invoke($null,[EventArgs]::Empty); $windowTick.Invoke($null,[EventArgs]::Empty)
    Assert-True (-not $bridgeState.active -and $runtime.colors[0] -eq $bridgeState.baseColors[0] -and $surface.Visibility -eq [Windows.Visibility]::Visible -and -not $videoState.active) 'Expired colors/video may show the base palette only while RGB is enabled'
    [void](Set-DesktopLocalControl @{rgbEnabled=$false})
    $windowTick.Invoke($null,[EventArgs]::Empty); $videoTick.Invoke($null,[EventArgs]::Empty)
    Assert-True ($surface.Visibility -eq [Windows.Visibility]::Collapsed) 'Fallback and repeated ticks must never re-enable an RGB-off plane'
    Write-Output 'PASS RGB-on base-palette fallback and RGB-off fallback suppression'

    Publish-TestJpeg; $videoTick.Invoke($null,[EventArgs]::Empty)
    $uniqueBefore=$probe.stages.uniqueFrame.count; $hiddenBefore=$probe.stages.hidden.count
    [AmbientNative]::Supported=$false; $windowTick.Invoke($null,[EventArgs]::Empty)
    $producedBefore=$producer.count; Publish-TestJpeg; $videoTick.Invoke($null,[EventArgs]::Empty)
    Assert-True ($producer.count -eq $producedBefore+1 -and $probe.stages.uniqueFrame.count -eq $uniqueBefore -and $probe.stages.hidden.count -eq $hiddenBefore+1) 'A producer can keep saving JPEG while a hidden viewer stops consuming them'
    Open-TestTrayMenu
    Assert-True ($videoReceiveStatus.Text -like '*최근 영상 수신 확인*' -and $desktopDisplayStatus.Text -eq 'Desktop 표시: 대상 앱 대기') 'Receiving video must remain separate from an unsupported foreground app'
    [AmbientNative]::Supported=$true; $windowTick.Invoke($null,[EventArgs]::Empty); $videoTick.Invoke($null,[EventArgs]::Empty)
    Assert-True ($videoState.active -and $probe.stages.uniqueFrame.count -eq $uniqueBefore+1 -and $surface.Visibility -eq [Windows.Visibility]::Collapsed) 'Returning to a supported foreground must restore video-only'
    Open-TestTrayMenu
    Assert-True ($desktopDisplayStatus.Text -eq 'Desktop 표시: 흐릿한 영상 표시 중') 'Video-only display status must never imply RGB was re-enabled'
    [void](Set-DesktopLocalControl @{globalPaused=$true})
    $uniqueBefore=$probe.stages.uniqueFrame.count; Publish-TestJpeg; $videoTick.Invoke($null,[EventArgs]::Empty)
    Assert-True ($probe.stages.uniqueFrame.count -eq $uniqueBefore -and $null -eq $videoWash.Source -and -not $localControl.config.desktopOutput.rgbEnabled -and $localControl.config.desktopOutput.videoEnabled) 'Pause must stop decoding while preserving video-only preferences'
    [IO.File]::WriteAllText($bridgeSnapshotPath,(@{utc=[DateTime]::UtcNow.ToString('o');left='#804020';right='#204080'} | ConvertTo-Json -Compress))
    Open-TestTrayMenu
    Assert-True ($rgbReceiveStatus.Text -like '*최근 색상 수신 확인*' -and $videoReceiveStatus.Text -like '*최근 영상 수신 확인*' -and $desktopDisplayStatus.Text -eq 'Desktop 표시: Desktop 효과 일시정지' -and -not $rgbToggle.Checked) 'Paused output must still report independent reception without changing RGB-off preference'
    [void](Set-DesktopLocalControl @{globalPaused=$false})
    $windowTick.Invoke($null,[EventArgs]::Empty); $videoTick.Invoke($null,[EventArgs]::Empty)
    $restored=New-AmbientLocalControl (Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json) $configPath
    Assert-True ($videoState.active -and -not $restored.config.desktopOutput.rgbEnabled -and $restored.config.desktopOutput.videoEnabled -and -not $restored.config.control.globalPaused) 'Resume and settings reload must preserve video-only'
    Write-Output 'PASS separate hidden/producer counters, video-only pause/resume and saved preference restoration'
    . (Join-Path $PSScriptRoot 'orca-window-cases.ps1')
    . (Join-Path $PSScriptRoot 'settings-window-cases.ps1')
    Assert-True ($state.PSObject.Properties.Name -notcontains 'paused') 'The independent legacy pause flag must be removed'
    Assert-True ($state.lastError -eq '') 'The production foreground callback must have no swallowed errors'
    Assert-True ($videoState.lastError -eq '') 'The production JPEG consumer must have no swallowed errors'
} finally {
    if ($videoPoll) { $videoPoll.Stop(); if ($videoTick) { $videoPoll.Remove_Tick($videoTick) } }
    if ($videoRelease) { $videoRelease.Stop(); if ($releaseTick) { $videoRelease.Remove_Tick($releaseTick) } }
    if ($renderReady) { Clear-VideoFrames }
    if ($null -ne $template) { Set-GlowMotion $false 75; $template.Close() }
    if ($menu) { $menu.Dispose() }
    $resolved=[IO.Path]::GetFullPath($sandbox)
    if ([IO.Path]::GetDirectoryName($resolved) -ne [IO.Path]::GetFullPath($artifacts) -or [IO.Path]::GetFileName($resolved) -notlike 'desktop-control-test-*') { throw 'Unsafe Desktop control test cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
