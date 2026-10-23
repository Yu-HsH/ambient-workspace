# Portable entry point. Runs the Desktop in this same Windows PowerShell process.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Show-AmbientLaunchNotice([string]$Text, [bool]$IsError=$true) {
    try {
        Add-Type -AssemblyName PresentationFramework
        $icon=if ($IsError) { [Windows.MessageBoxImage]::Error } else { [Windows.MessageBoxImage]::Information }
        [void][Windows.MessageBox]::Show($Text,'Ambient Workspace',[Windows.MessageBoxButton]::OK,$icon)
    } catch {
        # A console remains available even if WPF itself cannot load. Text is fixed, no secrets.
        Start-Process -FilePath $env:ComSpec -ArgumentList '/d /k echo Ambient Workspace startup failed. See Desktop_Companion/startup-log.txt and docs/WINDOWS_PORTABLE_GUIDE.md.'
    }
}

function Test-AmbientPortablePrerequisites([string]$Directory) {
    if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion -lt [version]'5.1' -or
        [Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA) {
        throw [InvalidOperationException]::new('RUNTIME')
    }
    if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
        throw [InvalidOperationException]::new('POLICY')
    }
    foreach ($name in @('Start-AmbientDesktop.ps1','Lifecycle.ps1','Control-State.ps1','Control-Channel.ps1',
        'Global-Hotkey.ps1','Hotkey-Config.ps1','Frame-Metrics.ps1','Settings-Window.ps1',
        'Overlay.xaml','Settings.xaml','settings.defaults.json','YouTube-Color-Bridge.ps1','File-Security.ps1','Native-Mailbox.ps1',
        'Native-Framing.ps1','NativeHost.ps1','NativeHost.cs','Native-Registration.ps1','Native-Profiles.ps1','Register-NativeHost.ps1',
        'Native-Setup.ps1','Native-Setup.xaml','Native-Migration.ps1','Native-Migration.xaml','Chrome-Profile-Migration.ps1',
        'Native-Profile-Helper.js','Native-Profile-Helper.html','Native-Profile-Helper-Page.js')) {
        if (-not [IO.File]::Exists((Join-Path $Directory $name))) { throw [IO.FileNotFoundException]::new('FILES') }
    }
    . (Join-Path $Directory 'File-Security.ps1')
    Assert-AmbientInstallSecurity $Directory
    . (Join-Path $Directory 'Native-Mailbox.ps1')
    $null=Get-AmbientNativePaths $Directory
    # Check actual create/delete permission without changing settings or pairing.
    $probe=Join-Path $Directory ('ambient-write-'+[Guid]::NewGuid().ToString('N')+'.tmp')
    try {
        $stream=[IO.File]::Open($probe,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $stream.Dispose()
    } catch { throw [UnauthorizedAccessException]::new('FOLDER') }
    finally { if ([IO.File]::Exists($probe)) { [IO.File]::Delete($probe) } }
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms,System.Drawing
}

function Get-AmbientLaunchFailure($Record,[string]$Stage) {
    $code=if ($Stage -eq 'desktop') { 'DESKTOP' } else { 'RUNTIME' }
    $exception=$Record.Exception
    while ($null -ne $exception) {
        if ($exception.Data.Contains('AmbientFileSecurity')) { $code='SECURITY'; break }
        if ($exception.Data.Contains('AmbientAlreadyRunning')) { $code='ALREADY_RUNNING'; break }
        if ($exception.Message -in @('RUNTIME','POLICY','FILES','FOLDER','NATIVE_PATH_TOO_LONG')) { $code=$exception.Message; break }
        $exception=$exception.InnerException
    }
    if ($code -eq 'DESKTOP') {
        $stack=[string]$Record.ScriptStackTrace
        if ($stack -match 'ConvertTo-AmbientControlConfig|New-AmbientLocalControl' -or
            $Record.FullyQualifiedErrorId -like '*ConvertFromJson*') { $code='SETTINGS' }
        elseif ($Record.CategoryInfo.Category -eq 'PermissionDenied') { $code='FOLDER' }
    }
    $text=switch ($code) {
        'ALREADY_RUNNING' { '이미 실행 중입니다. 작업 표시줄 오른쪽의 숨겨진 아이콘(∧)에서 Ambient Workspace를 찾아 설정을 여세요. 다른 폴더의 버전을 실행하려면 기존 트레이에서 Desktop 앱 종료를 선택하세요.' }
        'FILES' { 'Desktop 필수 파일이 없습니다. ZIP 전체를 새 폴더에 압축 해제한 뒤 Start.bat을 실행하세요. 기존 settings.json과 bridge-pairing.txt는 삭제하지 마세요.' }
        'NATIVE_PATH_TOO_LONG' { '설치 경로가 Windows PowerShell 5.1의 파일 경로 한도를 초과합니다. 신뢰 가능한 제품을 짧은 개인 전용 NTFS 폴더에 새로 풀고 실제 권한을 확인하세요. 종료 상태에서 기존 설정·페어링을 복사하고 Chrome 연결을 새 위치로 재등록하세요. 원본 파일은 삭제하지 마세요.' }
        'FOLDER' { '이 폴더에 파일을 저장할 수 없습니다. Desktop을 종료한 뒤 전체 폴더를 문서 등 직접 쓸 수 있는 로컬 폴더로 옮겨 실행하세요. 관리자 실행은 필요하지 않습니다.' }
        'SECURITY' { '설치 위치의 파일 권한을 안전하다고 확인하지 못했습니다. 다른 Windows 계정이 개인 데이터에 접근하거나 실행 파일을 바꿀 수 있는 위치에서는 실행하지 않습니다. 신뢰 가능한 제품을 개인 전용 로컬 NTFS 폴더에 새로 압축 해제하고 종료 상태에서 기존 설정·페어링을 복사하세요. 단순 이동은 기존 권한을 보존할 수 있습니다. 관리자 실행이나 모든 사용자 권한 허용으로 해결하지 마세요. docs/WINDOWS_PORTABLE_GUIDE.md의 SECURITY 항목을 확인하세요.' }
        'SETTINGS' { '설정 파일을 읽지 못했습니다. settings.json을 보존하고 종료 상태에서 직접 수정하거나 이전 백업을 확인하세요. 설정과 페어링은 자동 초기화하지 않습니다.' }
        'POLICY' { '조직의 PowerShell 보안 정책으로 실행할 수 없습니다. 정책을 변경하지 말고 관리자에게 문의하세요.' }
        'RUNTIME' { 'Windows PowerShell 5.1과 Windows 데스크톱의 WPF가 필요합니다. PowerShell 7 대신 Start.bat을 실행하세요. 조직 PC라면 관리자에게 실행 정책을 문의하세요.' }
        default { 'Desktop 실행 중 오류가 발생했습니다. 아래 로그와 사용자 안내의 오류 해결 항목을 확인하세요. 설정과 페어링 파일은 삭제하지 마세요.' }
    }
    return [pscustomobject]@{code=$code;text=$text;isError=($code -ne 'ALREADY_RUNNING')}
}

$stage='preflight'
try {
    Test-AmbientPortablePrerequisites $PSScriptRoot
    $stage='desktop'
    # Keep WPF GetNewClosure event callbacks in the entry point's script scope.
    . (Join-Path $PSScriptRoot 'Start-AmbientDesktop.ps1') -PortableLaunch
} catch {
    $failure=Get-AmbientLaunchFailure $_ $stage
    if (-not $failure.isError) { Show-AmbientLaunchNotice $failure.text $false; exit 0 }
    # Never record raw exception messages or source lines: malformed JSON can contain secrets.
    $logPath=Join-Path $PSScriptRoot 'startup-log.txt'
    $written=$false
    $detail=([DateTime]::UtcNow.ToString('o')+' code='+$failure.code+' stage='+$stage+
        ' type='+$_.Exception.GetType().FullName+' line='+$_.InvocationInfo.ScriptLineNumber)
    if (Get-Command Format-AmbientSafeError -ErrorAction SilentlyContinue) {
        $detail+=' '+(Format-AmbientSafeError $_)
    }
    # Unverified locations must not receive even an error log. Keep reason codes
    # fixed and never include paths, account names, ACLs or existing data values.
    if ($failure.code -eq 'SECURITY') {
        $cause=$_.Exception
        while ($null -ne $cause) {
            if ($cause.Data.Contains('AmbientFileSecurity')) { $failure.text+="`n검사 원인: "+$cause.Data['AmbientFileSecurity']; break }
            $cause=$cause.InnerException
        }
    } else {
        try { [IO.File]::WriteAllText($logPath,$detail,[Text.UTF8Encoding]::new($true)); $written=$true } catch {}
    }
    $logNote=if ($written) { "`n`n로그: "+$logPath } else { "`n`n로그를 저장하지 못했습니다. 오류 코드와 이 안내를 확인하세요." }
    Show-AmbientLaunchNotice ($failure.text+"`n`n오류 코드: "+$failure.code+$logNote)
    exit 1
}
