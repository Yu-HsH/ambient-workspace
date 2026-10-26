# Read-only observation of real foreground HWND -> PID -> ProcessName -> window rect.
# Does not launch apps, render an overlay, change focus, save settings or read pairing.
param(
    [ValidateRange(1,300)][int]$Seconds=30,
    [string]$ConfigPath=''
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
. (Join-Path $root 'Desktop_Companion/Control-State.ps1')
if (-not $ConfigPath) {
    $ConfigPath=Join-Path $root 'Desktop_Companion/settings.json'
    if (-not (Test-Path -LiteralPath $ConfigPath)) { $ConfigPath=Join-Path $root 'Desktop_Companion/settings.defaults.json' }
}
$config=ConvertTo-AmbientControlConfig (Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json)
$targets=@($config.targets | ForEach-Object { ([string]$_).ToLowerInvariant() })
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class AmbientForegroundProbe {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint id);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT rect);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attribute, out RECT rect, int size);
}
'@
$checkMs=[Math]::Min(450,[Math]::Max(250,[Math]::Min(2000,[int]$config.windowCheckMilliseconds)))
Write-Host 'Observe eligibility only; separately verify real RGB/video output. No files are written.'
$last=''
$watch=[Diagnostics.Stopwatch]::StartNew()
while ($watch.Elapsed.TotalSeconds -lt $Seconds) {
    $foreground=[AmbientForegroundProbe]::GetForegroundWindow()
    $name='(none)'; $eligible=$false; $supported=$false; $minimized=$false
    $bounds='unavailable'; [uint32]$foregroundProcessId=0
    if ($foreground -ne [IntPtr]::Zero) {
        try {
            [void][AmbientForegroundProbe]::GetWindowThreadProcessId($foreground,[ref]$foregroundProcessId)
            if ($foregroundProcessId -gt 0) {
                $process=[Diagnostics.Process]::GetProcessById([int]$foregroundProcessId)
                try { $name=$process.ProcessName.ToLowerInvariant() } finally { $process.Dispose() }
                $supported=$targets -contains $name
                $minimized=[AmbientForegroundProbe]::IsIconic($foreground)
                $rect=[AmbientForegroundProbe+RECT]::new()
                $result=[AmbientForegroundProbe]::DwmGetWindowAttribute($foreground,9,[ref]$rect,[Runtime.InteropServices.Marshal]::SizeOf([type][AmbientForegroundProbe+RECT]))
                $hasRect=$true
                if ($result -ne 0) { $hasRect=[AmbientForegroundProbe]::GetWindowRect($foreground,[ref]$rect) }
                if ($hasRect) {
                    $bounds=('{0},{1} {2},{3}' -f $rect.Left,$rect.Top,$rect.Right,$rect.Bottom)
                    $eligible=$supported -and -not $minimized -and ($rect.Right -gt $rect.Left+200) -and ($rect.Bottom -gt $rect.Top+150)
                }
            }
        } catch { $name='(lookup unavailable)'; $eligible=$false }
    }
    $outputAllowed=-not $config.control.globalPaused -and $config.desktopOutput.enabled -and ($config.desktopOutput.rgbEnabled -or $config.desktopOutput.videoEnabled)
    $line=('process={0} hwnd=0x{1:X} pid={2} supported={3} minimized={4} eligible={5} outputAllowed={6} rect={7}' -f $name,$foreground.ToInt64(),$foregroundProcessId,$supported,$minimized,$eligible,$outputAllowed,$bounds)
    if ($line -cne $last) { Write-Output ((Get-Date -Format 'HH:mm:ss')+' '+$line); $last=$line }
    Start-Sleep -Milliseconds $checkMs
}
