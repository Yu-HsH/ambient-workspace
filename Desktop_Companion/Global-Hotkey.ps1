# One message-only HWND on the existing WPF Dispatcher; independent of settings/overlay.
$hotkeyHost=[pscustomobject]@{engine=$null;handler=$null;requested='';status='disabled';error=''}

function Initialize-AmbientHotkeyNative {
    if ('AmbientWorkspace.GlobalHotkey' -as [type]) { return }
    Add-Type -ReferencedAssemblies @('System.dll',[Windows.Threading.Dispatcher].Assembly.Location,[Windows.Interop.HwndSource].Assembly.Location) -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Interop;
using System.Windows.Threading;
namespace AmbientWorkspace {
    public sealed class GlobalHotkey : IDisposable {
        [DllImport("user32.dll", SetLastError=true)]
        private static extern bool RegisterHotKey(IntPtr hwnd, int id, uint modifiers, uint key);
        [DllImport("user32.dll", SetLastError=true)]
        private static extern bool UnregisterHotKey(IntPtr hwnd, int id);
        private readonly HwndSource source;
        private readonly HwndSourceHook hook;
        private readonly Stopwatch clock = Stopwatch.StartNew();
        private int id = 0x4100, generation;
        private uint modifiers, key;
        private bool pending, disposed;
        private long last = -500;
        public bool Registered { get; private set; }
        public int ErrorCode { get; private set; }
        public bool DeliveryFailed { get; private set; }
        public event EventHandler Pressed;
        public GlobalHotkey() {
            var parameters = new HwndSourceParameters("Ambient Workspace Hotkey");
            parameters.ParentWindow = new IntPtr(-3); // HWND_MESSAGE, never visible/focusable
            parameters.WindowStyle = 0;
            source = new HwndSource(parameters);
            hook = Receive;
            source.AddHook(hook);
        }
        public bool Clear() {
            source.Dispatcher.VerifyAccess();
            if (Registered && !UnregisterHotKey(source.Handle, id)) {
                ErrorCode = Marshal.GetLastWin32Error(); return false;
            }
            Registered = false; generation++; pending = false; ErrorCode = 0; DeliveryFailed = false;
            return true;
        }
        public bool Register(uint nextModifiers, uint nextKey) {
            source.Dispatcher.VerifyAccess();
            if (disposed) throw new ObjectDisposedException("GlobalHotkey");
            if (!Clear()) return false;
            // A fresh id also rejects already queued messages for an old binding.
            id = id >= 0xBFFF ? 0x4100 : id + 1;
            modifiers = nextModifiers; key = nextKey;
            Registered = RegisterHotKey(source.Handle, id, modifiers | 0x4000, key); // MOD_NOREPEAT
            ErrorCode = Registered ? 0 : Marshal.GetLastWin32Error();
            return Registered;
        }
        private IntPtr Receive(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled) {
            if (message != 0x0312 || !Registered || wParam.ToInt32() != id) return IntPtr.Zero;
            handled = true;
            long data = lParam.ToInt64();
            if (((uint)data & 0xF) != modifiers || ((uint)(data >> 16) & 0xFFFF) != key) return IntPtr.Zero;
            if (pending || clock.ElapsedMilliseconds - last < 400) return IntPtr.Zero;
            last = clock.ElapsedMilliseconds; pending = true;
            int acceptedGeneration = generation;
            // Leave the native window procedure before settings I/O or WPF changes.
            source.Dispatcher.BeginInvoke(DispatcherPriority.Background, new Action(delegate {
                if (disposed || acceptedGeneration != generation || !Registered) return;
                try { var handler = Pressed; if (handler != null) handler(this, EventArgs.Empty); }
                catch { DeliveryFailed = true; }
                finally { pending = false; }
            }));
            return IntPtr.Zero;
        }
        public void Dispose() {
            if (disposed) return;
            source.Dispatcher.VerifyAccess();
            try { Clear(); }
            finally { disposed = true; generation++; source.RemoveHook(hook); source.Dispose(); Pressed = null; }
        }
    }
}
'@
}

function Sync-DesktopGlobalHotkey([switch]$Retry) {
    $preference=Get-AmbientHotkeyPreferences $localControl.config
    $signature=($preference | Select-Object enabled,combination,error | ConvertTo-Json -Compress)
    if (-not $Retry -and $hotkeyHost.requested -ceq $signature) { return }
    $hotkeyHost.requested=$signature; $hotkeyHost.error=''
    try {
        if ($null -ne $hotkeyHost.engine -and -not $hotkeyHost.engine.Clear()) { throw ('기존 단축키를 해제하지 못했습니다. 오류 '+$hotkeyHost.engine.ErrorCode) }
        if ($preference.error) { throw $preference.error }
        if (-not $preference.enabled) { $hotkeyHost.status='disabled'; return }
        if ($null -eq $hotkeyHost.engine) {
            Initialize-AmbientHotkeyNative
            $hotkeyHost.engine=New-Object AmbientWorkspace.GlobalHotkey
            $hotkeyHost.handler=[EventHandler]{
                try {
                    [void](Set-DesktopLocalControl @{globalPaused=(-not $localControl.config.control.globalPaused)})
                } catch {
                    $hotkeyHost.error='단축키 동작을 적용하지 못했습니다. 트레이에서 상태를 확인하세요.'
                    Write-AmbientDesktopLog $logPath ('HOTKEY APPLY ERROR: '+(Format-AmbientSafeError $_))
                }
            }
            $hotkeyHost.engine.add_Pressed($hotkeyHost.handler)
        }
        $parsed=$preference.parsed
        if (-not $hotkeyHost.engine.Register($parsed.modifiers,$parsed.virtualKey)) {
            $code=$hotkeyHost.engine.ErrorCode
            if ($code -eq 1409) { throw '다른 프로그램 또는 Windows에서 사용 중인 조합입니다. 다른 조합을 지정하거나 충돌 앱을 닫고 다시 등록하세요. (1409)' }
            throw ('Windows 단축키 등록 실패 · 오류 '+$code+' · 다른 조합을 지정하거나 다시 등록하세요.')
        }
        $hotkeyHost.status='registered'
    } catch { $hotkeyHost.status='error'; $hotkeyHost.error=$_.Exception.Message }
}

function Get-DesktopHotkeyStatus {
    $preference=Get-AmbientHotkeyPreferences $localControl.config
    if ($hotkeyHost.error) { return '단축키 오류: '+$hotkeyHost.error }
    if ($hotkeyHost.status -eq 'registered' -and $null -ne $hotkeyHost.engine -and $hotkeyHost.engine.Registered) {
        if ($hotkeyHost.engine.DeliveryFailed) { return '단축키 처리 오류 · 트레이에서 상태를 확인한 뒤 다시 등록하세요.' }
        return '등록됨 · '+$preference.parsed.combination+' · Desktop 실행 중 사용 가능'
    }
    return '비활성 · 전역 단축키를 등록하지 않았습니다.'
}

function Stop-DesktopGlobalHotkey {
    if ($null -ne $hotkeyHost.engine) {
        try { $hotkeyHost.engine.remove_Pressed($hotkeyHost.handler); $hotkeyHost.engine.Dispose() }
        finally { $hotkeyHost.engine=$null; $hotkeyHost.handler=$null; $hotkeyHost.status='disabled'; $hotkeyHost.requested='' }
    }
}
