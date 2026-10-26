# Runs in the isolated WPF/foreground fixture from test-desktop-controls.ps1.
# Native HWND/PID and process lookup are simulated; the actual product callbacks,
# target normalization, WPF layers, JPEG decoder and settings save path execute.
$config=$localControl.config
$targetsStart=(Get-Assignment '$targets').Extent.StartOffset
$targetsEnd=(Get-Assignment '$spread').Extent.StartOffset
. ([ScriptBlock]::Create($ast.Extent.Text.Substring($targetsStart,$targetsEnd-$targetsStart)))
. ([ScriptBlock]::Create($windowTickCode.Replace($processQuery,'(Get-TestForegroundProcess ([int]$targetProcessId))')))
Assert-True ($targets -contains 'orca' -and $perAppMultiplier.orca -eq 1.0) 'Production startup normalization must include Orca at 1.0'
$baselineTargets=$localControl.config.targets -join '|'
$baselineMultipliers=$localControl.config.appMultipliers | ConvertTo-Json -Compress
[AmbientNative]::ProcessName='ORCA'
[AmbientNative]::Handle=101
foreach ($rgb in @($true,$false)) {
    foreach ($video in @($true,$false)) {
        [void](Set-DesktopLocalControl @{desktopEnabled=$true;globalPaused=$false;rgbEnabled=$rgb;videoEnabled=$video;intensity='balanced';transitionStyle='instant'})
        Clear-VideoFrames
        Publish-TestJpeg
        [IO.File]::WriteAllText($bridgeSnapshotPath,(@{utc=[DateTime]::UtcNow.ToString('o');left='#804020';right='#204080'} | ConvertTo-Json -Compress))
        $windowTick.Invoke($null,[EventArgs]::Empty)
        $videoTick.Invoke($null,[EventArgs]::Empty)
        $windowTick.Invoke($null,[EventArgs]::Empty)
        Assert-True (($window.Visibility -eq [Windows.Visibility]::Visible) -eq ($rgb -or $video)) 'Orca visibility must honor the independent RGB/video choices'
        Assert-True (($surface.Visibility -eq [Windows.Visibility]::Visible) -eq $rgb) 'Orca RGB layer must honor RGB OFF'
        Assert-True ($videoState.active -eq $video -and ($null -ne $videoWash.Source) -eq $video) 'Orca must decode a real synthetic JPEG only with video enabled'
        if ($rgb -or $video) {
            Assert-True ($state.lastStatus -like 'overlay ON for orca*' -and [AmbientNative]::PidHandle.ToInt32() -eq 101 -and [AmbientNative]::RectHandle.ToInt32() -eq 101) 'Orca matching and bounds must use the same actual foreground HWND fixture'
            Assert-True ([AmbientNative]::PlacedWidth -eq 800 -and [AmbientNative]::PlacedHeight -eq 540) 'Overlay bounds must match the foreground window rect'
        }
        if ($rgb) {
            $expectedOpacity=$runtime.strength/0.88 * $(if($video){0.32}else{1.0})
            Assert-True ($bridgeState.active -and [Math]::Abs($left.Opacity-$expectedOpacity) -lt 0.001) 'Orca must consume RGB colors with the default 1.0 app multiplier'
        }
        if (-not ($rgb -or $video)) { continue }
        # Repeat switching for every visible output combination, including video-only.
        foreach ($iteration in 1..3) {
            [AmbientNative]::ProcessName='unlisted-editor'
            $windowTick.Invoke($null,[EventArgs]::Empty)
            Assert-True ($window.Visibility -eq [Windows.Visibility]::Hidden -and $null -eq $videoWash.Source -and $null -eq $videoWashPrev.Source) 'An unsupported foreground app must hide the overlay and clear both video layers'
            [AmbientNative]::ProcessName='orca'
            Publish-TestJpeg
            $windowTick.Invoke($null,[EventArgs]::Empty); $videoTick.Invoke($null,[EventArgs]::Empty)
            Assert-True ($window.Visibility -eq [Windows.Visibility]::Visible -and $videoState.active -eq $video) 'Returning to Orca must restore each selected output combination'
        }
    }
}
Write-Output 'PASS Orca RGB-only/video-only/both/OFF, real JPEG decode, 1.0 opacity and repeated unsupported-app switching'

[void](Set-DesktopLocalControl @{rgbEnabled=$true;videoEnabled=$true})
foreach ($app in @('Code','Code - Insiders','Codex','ChatGPT','Claude','Cursor','orca')) {
    [AmbientNative]::ProcessName=$app
    Publish-TestJpeg
    $windowTick.Invoke($null,[EventArgs]::Empty); $videoTick.Invoke($null,[EventArgs]::Empty)
    $windowTick.Invoke($null,[EventArgs]::Empty)
    $expectedOpacity=[Math]::Min(0.98,($runtime.strength*$perAppMultiplier[$app.ToLowerInvariant()]/0.88))*0.32
    Assert-True ($state.lastStatus -like ('overlay ON for '+$app.ToLowerInvariant()+'*') -and $videoState.active -and [Math]::Abs($left.Opacity-$expectedOpacity) -lt 0.001) 'Switching supported apps must keep their original individual multipliers and video display'
}
# Same-process windows can have different HWNDs and rectangles.
[AmbientNative]::Handle=202; [AmbientNative]::Left=220; [AmbientNative]::DwmFail=$true
$windowTick.Invoke($null,[EventArgs]::Empty)
Assert-True ([AmbientNative]::RectHandle.ToInt32() -eq 202 -and [AmbientNative]::PlacedLeft -eq 220 -and $state.lastRect -eq '220,10,1020,550') 'A second Orca window must follow its foreground rect, including the GetWindowRect fallback'
foreach ($condition in @('Iconic','ValidRect','Supported')) {
    switch ($condition) {
        'Iconic' { [AmbientNative]::Iconic=$true }
        'ValidRect' { [AmbientNative]::ValidRect=$false }
        'Supported' { [AmbientNative]::Supported=$false }
    }
    $windowTick.Invoke($null,[EventArgs]::Empty)
    Assert-True ($window.Visibility -eq [Windows.Visibility]::Hidden -and $null -eq $videoWash.Source) 'Minimized, invalid or absent foreground windows must hide Orca effects'
    [AmbientNative]::Iconic=$false; [AmbientNative]::ValidRect=$true; [AmbientNative]::Supported=$true
    Publish-TestJpeg
    $windowTick.Invoke($null,[EventArgs]::Empty); $videoTick.Invoke($null,[EventArgs]::Empty)
    Assert-True ($window.Visibility -eq [Windows.Visibility]::Visible -and $videoState.active) 'Restoring an eligible Orca foreground window must resume display'
}
Assert-True (($localControl.config.targets -join '|') -ceq $baselineTargets -and ($localControl.config.appMultipliers | ConvertTo-Json -Compress) -ceq $baselineMultipliers) 'App switching must not alter targets or app multipliers'
Write-Output 'PASS Orca to/from VS Code/Codex/ChatGPT/Claude/Cursor, second-window HWND, fallback bounds, minimize/restore and no settings changes'

[void](Set-DesktopLocalControl @{globalPaused=$true})
$windowTick.Invoke($null,[EventArgs]::Empty)
Assert-True ($window.Visibility -eq [Windows.Visibility]::Hidden -and $localControl.config.desktopOutput.rgbEnabled -and $localControl.config.desktopOutput.videoEnabled) 'Orca pause must hide effects and preserve individual preferences'
[void](Set-DesktopLocalControl @{globalPaused=$false})
Publish-TestJpeg
$windowTick.Invoke($null,[EventArgs]::Empty); $videoTick.Invoke($null,[EventArgs]::Empty)
Assert-True ($videoState.active -and $window.Visibility -eq [Windows.Visibility]::Visible) 'Orca resume must restore effects'
Assert-True ($state.lastError -eq '' -and $videoState.lastError -eq '') 'Orca callback and JPEG decoder must not swallow errors'
[AmbientNative]::Handle=1; [AmbientNative]::Left=10; [AmbientNative]::DwmFail=$false
[AmbientNative]::ProcessName=(Get-Process -Id $PID).ProcessName
$targets=@([AmbientNative]::ProcessName.ToLowerInvariant()); $perAppMultiplier=@{}
. ([ScriptBlock]::Create($windowTickCode.Replace($processQuery,'(Get-TestForegroundProcess ([int]$targetProcessId))')))
Write-Output 'PASS Orca pause/resume preserves individual output preferences'
