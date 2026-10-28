# Standalone bootstrap. Never imports code from the extracted source directory.
param(
    [string]$PackagePath='', [string]$ExpectedSha256='', [string]$DestinationRoot='',
    [switch]$SourceVerified, [string]$ExistingInstall='', [switch]$ApproveMigration,
    [switch]$Interactive, [switch]$Console,
    [ValidateSet('DesktopChrome','ChromeOnly')][string]$InstallMode='DesktopChrome'
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$script:InstallerScriptPath=$PSCommandPath
$script:InstallerId='ncbcjbbidoaallpikijfbjdmijjljhoe'

function Stop-AmbientInstall([string]$Code) { throw [InvalidOperationException]::new($Code) }
function Get-InstallHash([byte[]]$Bytes) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
}
function Read-InstallStream($Stream,[int]$Maximum) {
    $memory=[IO.MemoryStream]::new(); $buffer=New-Object byte[] 65536
    try {
        while(($count=$Stream.Read($buffer,0,$buffer.Length)) -gt 0) {
            if($memory.Length+$count -gt $Maximum){Stop-AmbientInstall 'INSTALL_SIZE_LIMIT'}
            $memory.Write($buffer,0,$count)
        }
        return ,$memory.ToArray()
    } finally { $memory.Dispose() }
}
function Test-InstallRelativePath([string]$Path) {
    if($Path -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -or $Path.Contains('//')){return $false}
    foreach($part in $Path.Split('/')) {
        if($part -in @('.','..','') -or $part.EndsWith('.') -or $part -match '^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(\.|$)'){return $false}
    }
    if($Path -match '(^|/)(settings\.json.*|bridge-pairing\.txt|control-[^.]+\.json.*|bridge-.*|native-mailbox|native-host.*|native-bridge.*|native-registration-backups|native-profile-backups|AmbientNativeHost\.exe.*|.*-log\.txt.*|\.git|\.env.*)(/|$)'){return $false}
    return ($Path -match '^(Desktop_Companion/[^/]+\.(ps1|xaml|cs|bat|json|js|html)|Browser_Extension/(manifest\.json|identity\.public\.json|source/[^/]+\.(js|html|css)|icons/[^/]+\.(svg|png))|docs/([A-Za-z0-9._-]+\.md|images/[A-Za-z0-9._-]+\.png)|licenses/[^/]+\.txt|Installer/(Install-AmbientWorkspace\.ps1|product-files\.json)|Install\.bat|README\.md|CHANGELOG\.md|LICENSE|COPYRIGHT\.md|THIRD_PARTY_NOTICES\.md)$')
}
function Assert-InstallIdentity($Files) {
    try {
        $identity=[Text.Encoding]::UTF8.GetString($Files['Browser_Extension/identity.public.json']).TrimStart([char]0xFEFF) | ConvertFrom-Json
        $manifest=[Text.Encoding]::UTF8.GetString($Files['Browser_Extension/manifest.json']).TrimStart([char]0xFEFF) | ConvertFrom-Json
        $digest=Get-InstallHash ([Convert]::FromBase64String($identity.publicKey))
        $id=-join ($digest.Substring(0,32).ToCharArray() | ForEach-Object { [char](97+[Convert]::ToInt32([string]$_,16)) })
        if($id -cne $script:InstallerId -or $identity.extensionId -cne $id -or $manifest.key -cne $identity.publicKey -or $manifest.permissions -cnotcontains 'nativeMessaging'){throw 'identity'}
    } catch { Stop-AmbientInstall 'INSTALL_EXTENSION_ID' }
}
function Open-AmbientInstallPackage([string]$Path,[string]$ExpectedHash) {
    if($ExpectedHash -notmatch '^[a-fA-F0-9]{64}$'){Stop-AmbientInstall 'INSTALL_EXPECTED_HASH_REQUIRED'}
    Add-Type -AssemblyName System.IO.Compression
    $source=$null; $memory=$null; $zip=$null
    try {
        # No source executable is loaded. A locked, bounded memory snapshot is the input.
        $source=[IO.File]::Open([IO.Path]::GetFullPath($Path),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $raw=Read-InstallStream $source 33554432
        if((Get-InstallHash $raw) -cne $ExpectedHash.ToLowerInvariant()){Stop-AmbientInstall 'INSTALL_ZIP_HASH'}
        $memory=[IO.MemoryStream]::new($raw,$false)
        $zip=[IO.Compression.ZipArchive]::new($memory,[IO.Compression.ZipArchiveMode]::Read,$true)
        if($zip.Entries.Count -lt 2 -or $zip.Entries.Count -gt 256){Stop-AmbientInstall 'INSTALL_ARCHIVE_LAYOUT'}
        $files=@{}; $total=0L
        foreach($entry in $zip.Entries) {
            $name=$entry.FullName
            if(($name -cne 'INSTALL-MANIFEST.json' -and -not (Test-InstallRelativePath $name)) -or $files.ContainsKey($name) -or (($entry.ExternalAttributes -shr 16) -band 61440) -eq 40960 -or ($entry.ExternalAttributes -band 1024)){Stop-AmbientInstall 'INSTALL_ARCHIVE_PATH'}
            if($entry.Length -gt 5242880 -or ($total+=$entry.Length) -gt 33554432){Stop-AmbientInstall 'INSTALL_SIZE_LIMIT'}
            $stream=$entry.Open(); try{$files[$name]=Read-InstallStream $stream 5242880}finally{$stream.Dispose()}
        }
        if(-not $files.ContainsKey('INSTALL-MANIFEST.json')){Stop-AmbientInstall 'INSTALL_MANIFEST_REQUIRED'}
        $record=[Text.Encoding]::UTF8.GetString($files['INSTALL-MANIFEST.json']).TrimStart([char]0xFEFF) | ConvertFrom-Json
        if($record.schemaVersion -ne 1 -or $record.product -cne 'AmbientWorkspace' -or $record.version -cnotmatch '^[A-Za-z0-9._-]{1,40}$' -or $record.extensionId -cne $script:InstallerId -or @($record.files).Count -ne $files.Count-1){Stop-AmbientInstall 'INSTALL_MANIFEST_INVALID'}
        $seen=@{}
        foreach($item in $record.files) {
            if(-not (Test-InstallRelativePath $item.path) -or $seen.ContainsKey($item.path) -or -not $files.ContainsKey($item.path) -or $item.sha256 -cnotmatch '^[a-f0-9]{64}$' -or $item.bytes -ne $files[$item.path].Length -or (Get-InstallHash $files[$item.path]) -cne $item.sha256){Stop-AmbientInstall 'INSTALL_FILE_HASH'}
            $seen[$item.path]=$true
        }
        foreach($required in @('Desktop_Companion/File-Security.ps1','Desktop_Companion/Test-FileSecurity.ps1','Desktop_Companion/Start.bat','Desktop_Companion/Launch-AmbientDesktop.ps1','Desktop_Companion/Control-State.ps1','Desktop_Companion/Native-Registration.ps1','Desktop_Companion/Register-NativeHost.ps1','Browser_Extension/manifest.json','Browser_Extension/identity.public.json','LICENSE','THIRD_PARTY_NOTICES.md')) {
            if(-not $files.ContainsKey($required)){Stop-AmbientInstall 'INSTALL_PRODUCT_INCOMPLETE'}
        }
        if(-not $files.ContainsKey('Installer/product-files.json')){Stop-AmbientInstall 'INSTALL_PRODUCT_INCOMPLETE'}
        $allowlist=[Text.Encoding]::UTF8.GetString($files['Installer/product-files.json']).TrimStart([char]0xFEFF)|ConvertFrom-Json
        $allowed=@{}
        foreach($name in $allowlist){if(-not (Test-InstallRelativePath $name) -or $allowed.ContainsKey($name) -or -not $files.ContainsKey($name)){Stop-AmbientInstall 'INSTALL_PRODUCT_ALLOWLIST'};$allowed[$name]=$true}
        if($allowed.Count -ne $files.Count-1){Stop-AmbientInstall 'INSTALL_PRODUCT_ALLOWLIST'}
        Assert-InstallIdentity $files
        return [pscustomobject]@{files=$files;manifest=$record;zipHash=(Get-InstallHash $raw)}
    } finally { if($zip){$zip.Dispose()}; if($memory){$memory.Dispose()}; if($source){$source.Dispose()} }
}
function Initialize-InstallPolicy($Package) {
    # Integrity relative to the independently obtained hash, NOT publisher authentication.
    . ([ScriptBlock]::Create([Text.Encoding]::UTF8.GetString($Package.files['Desktop_Companion/File-Security.ps1']).TrimStart([char]0xFEFF)))
    # Export into this script's scope, without trusting a neighboring extracted file.
    foreach($name in @('Stop-AmbientFileSecurity','Test-AmbientPathAcl','Assert-AmbientInstallSecurity')) {
        Set-Item -LiteralPath ('Function:script:'+$name) -Value (Get-Item ('Function:'+$name)).ScriptBlock
    }
}
function Assert-InstallAncestors([string]$Path) {
    $entry=[IO.DirectoryInfo]::new($Path)
    while($null -ne $entry) {
        if([IO.Directory]::Exists($entry.FullName)){Test-AmbientPathAcl $entry.FullName 'Ancestor'}
        $entry=$entry.Parent
    }
}
function Assert-InstallHelper($Package) {
    try {
        Test-AmbientPathAcl $script:InstallerScriptPath 'Product'
        Assert-InstallAncestors ([IO.Path]::GetDirectoryName($script:InstallerScriptPath))
    } catch {Stop-AmbientInstall 'INSTALL_HELPER_LOCATION'}
    if(-not $Package.files.ContainsKey('Installer/Install-AmbientWorkspace.ps1') -or (Get-InstallHash ([IO.File]::ReadAllBytes($script:InstallerScriptPath))) -cne (Get-InstallHash $Package.files['Installer/Install-AmbientWorkspace.ps1'])){Stop-AmbientInstall 'INSTALL_HELPER_HASH'}
}
function New-InstallPrivateDirectory([string]$Path) {
    if([IO.Directory]::Exists($Path) -or [IO.File]::Exists($Path)){Stop-AmbientInstall 'INSTALL_FOLDER_EXISTS'}
    if(-not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($Path))){Stop-AmbientInstall 'INSTALL_PARENT_MISSING'}
    Assert-InstallAncestors ([IO.Path]::GetDirectoryName($Path))
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    try{$sid=$identity.User}finally{$identity.Dispose()}
    $acl=[Security.AccessControl.DirectorySecurity]::new(); $acl.SetOwner($sid); $acl.SetAccessRuleProtection($true,$false)
    $inheritance=[Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    foreach($account in @($sid.Value,'S-1-5-18','S-1-5-32-544')) {
        $rule=[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($account),[Security.AccessControl.FileSystemRights]::FullControl,$inheritance,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)
        [void]$acl.AddAccessRule($rule)
    }
    # CreateDirectoryW fails atomically if another actor created the path first.
    # Unlike Directory.CreateDirectory's idempotent API, it cannot reuse an existing folder.
    if(-not ('AmbientInstallDirectory' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class AmbientInstallDirectory {
    [StructLayout(LayoutKind.Sequential)] struct SECURITY_ATTRIBUTES {
        public int Length; public IntPtr Descriptor; [MarshalAs(UnmanagedType.Bool)] public bool Inherit;
    }
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
    static extern bool CreateDirectory(string path,ref SECURITY_ATTRIBUTES attributes);
    public static int Create(string path,byte[] descriptor) {
        var pinned=GCHandle.Alloc(descriptor,GCHandleType.Pinned);
        try {
            var attributes=new SECURITY_ATTRIBUTES {Length=Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES)),Descriptor=pinned.AddrOfPinnedObject(),Inherit=false};
            return CreateDirectory(path,ref attributes) ? 0 : Marshal.GetLastWin32Error();
        } finally {pinned.Free();}
    }
}
'@
    }
    $result=[AmbientInstallDirectory]::Create($Path,$acl.GetSecurityDescriptorBinaryForm())
    if($result -eq 183){Stop-AmbientInstall 'INSTALL_FOLDER_EXISTS'}
    if($result -ne 0){Stop-AmbientInstall 'INSTALL_FOLDER_ACCESS'}
    Test-AmbientPathAcl $Path 'Private'
}
function Enter-InstallDesktopLease {
    # Hold the same mutex for the complete installation to prevent a startup race.
    $mutex=[Threading.Mutex]::new($false,'Local\AmbientWorkspace.Desktop');$owned=$false
    try { try{$owned=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}; if(-not $owned){Stop-AmbientInstall 'INSTALL_DESKTOP_RUNNING'}; return $mutex }
    catch{$mutex.Dispose();throw}
}
function Get-InstallFreeBytes([string]$Path) { return [IO.DriveInfo]::new([IO.Path]::GetPathRoot($Path)).AvailableFreeSpace }
function Test-InstallLaunchPrerequisites([string]$Directory) {
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Directory 'Launch-AmbientDesktop.ps1'),[ref]$tokens,[ref]$errors)
    if($errors.Count){Stop-AmbientInstall 'INSTALL_PRODUCT_INCOMPLETE'}
    $function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-AmbientPortablePrerequisites'},$true)
    if($null -eq $function){Stop-AmbientInstall 'INSTALL_PRODUCT_INCOMPLETE'}
    . ([ScriptBlock]::Create($function.Extent.Text))
    Test-AmbientPortablePrerequisites $Directory
}
function Write-InstallFile([string]$Path,[byte[]]$Bytes) {
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($Bytes,0,$Bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
}
function Assert-InstalledProduct([string]$Directory,$Package) {
    foreach($item in $Package.manifest.files) {
        $path=Join-Path $Directory $item.path
        if((Get-InstallHash ([IO.File]::ReadAllBytes($path))) -cne $item.sha256){Stop-AmbientInstall 'INSTALL_COPIED_HASH'}
    }
    if((Get-InstallHash ([IO.File]::ReadAllBytes((Join-Path $Directory 'INSTALL-MANIFEST.json')))) -cne (Get-InstallHash $Package.files['INSTALL-MANIFEST.json'])){Stop-AmbientInstall 'INSTALL_COPIED_HASH'}
}
function Get-InstallErrorCode($Record) {
    $cause=$Record.Exception
    while($null -ne $cause) {
        if($cause.Data.Contains('AmbientFileSecurity')){return ('INSTALL_ACL_'+$cause.Data['AmbientFileSecurity'])}
        if($cause.Message -cmatch '^(INSTALL_[A-Z_]+|NATIVE_[A-Z_]+)$'){return $cause.Message}
        if($cause -is [IO.IOException] -and ($cause.HResult -band 65535) -in @(39,112)){return 'INSTALL_DISK_FULL'}
        $cause=$cause.InnerException
    }
    return 'INSTALL_IO_OR_POLICY'
}
function Get-InstallErrorHelp([string]$Code) {
    switch -Wildcard ($Code) {
        'INSTALL_DESKTOP_RUNNING' {return 'Desktop이 실행 중입니다. 트레이에서 Desktop 앱 종료를 선택한 뒤 다시 설치하세요. 강제 종료하지 않습니다.'}
        'INSTALL_EXTRACT_ALL' {return 'ZIP 안에서 실행했거나 일부 파일만 풀었습니다. ZIP을 마우스 오른쪽 버튼으로 눌러 모두 압축 풀기를 선택한 뒤 풀린 폴더의 Install.bat을 실행하세요. 원본 ZIP도 보관하세요.'}
        'INSTALL_PACKAGE_MISSING' {return '다운로드한 원본 ZIP을 찾지 못했습니다. ZIP 선택으로 압축 해제 전의 Windows 설치 ZIP을 선택하세요. Source code (zip)은 사용할 수 없습니다.'}
        'INSTALL_MANIFEST_*' {return '새 설치 마법사용 Windows ZIP이 아닙니다. Source code (zip) 또는 공개 rc.1 ZIP 대신 해당 버전의 새 Windows 설치 ZIP을 선택하세요.'}
        'INSTALL_PRODUCT_*' {return '설치에 필요한 제품 파일이 없거나 허용 목록과 다릅니다. 이 ZIP을 실행하지 말고 공식 출처의 같은 버전 Windows 설치 ZIP을 다시 확인하세요.'}
        'INSTALL_CHROME_NOT_FOUND' {return 'Chrome 실행 위치를 찾지 못했습니다. Chrome 주소창에 chrome://extensions를 직접 입력하세요.'}
        'INSTALL_CHROME_ONLY_MIGRATION' {return 'Chrome만 사용에서는 Desktop 개인 파일을 읽거나 이전하지 않습니다. 업데이트하려면 Windows 앱도 사용을 선택하세요. Chrome 확장 설정은 기존 프로필에 유지됩니다.'}
        'INSTALL_EXTENSION_NOT_CONFIRMED' {return 'Chrome에서 개발자 모드를 켜고 복사한 Browser_Extension 폴더를 로드하세요. 확장 목록의 Ambient Workspace를 확인한 뒤 확인란을 선택하세요.'}
        'INSTALL_POWERSHELL_REQUIRED' {return 'Windows PowerShell 5.1과 WPF가 필요합니다. Install.bat을 사용하세요. 조직 정책으로 차단됐다면 정책을 바꾸지 말고 관리자에게 문의하세요.'}
        'INSTALL_NTFS_REQUIRED' {return '개인 계정의 로컬 NTFS 드라이브가 필요합니다. 네트워크·공유·이동식 드라이브 대신 기본 설치 위치를 사용하세요.'}
        'INSTALL_*HASH*' {return '파일 무결성 검사에 실패했습니다. 원본을 실행하지 말고 공식 Release의 ZIP과 별도로 확인한 SHA-256으로 다시 시도하세요.'}
        'INSTALL_ACL_*' {return '폴더 접근 권한을 안전하다고 확인하지 못했습니다. 기존 권한을 고치지 말고 사용자 폴더 바로 아래의 새 앱 전용 위치를 선택하세요.'}
        'INSTALL_FOLDER_EXISTS' {return '같은 위치가 이미 존재합니다. 기존 파일은 보존했습니다. 다른 새 설치 폴더를 선택하세요.'}
        'INSTALL_SOURCE_APPROVAL_REQUIRED' {return '공식 출처와 SHA-256 확인이 필요합니다. ZIP 옆의 출처 불명 해시 파일만으로 승인하지 마세요.'}
        'INSTALL_HELPER_LOCATION' {return '설치 도우미 자체를 다른 계정이 바꿀 수 있는 위치입니다. 공식 출처와 해시로 확인한 도우미를 사용자 폴더 안의 개인 위치에 다시 받아 실행하세요. 원본 폴더 권한은 고치지 않습니다.'}
        'INSTALL_STA_REQUIRED' {return 'Windows PowerShell 5.1의 -STA 옵션 또는 Install.bat으로 다시 실행하세요.'}
        'INSTALL_FOLDER_ACCESS' {return '폴더 접근 권한 문제로 새 앱 폴더를 만들 수 없습니다. 다른 새 개인 위치를 선택하세요. 기존 권한은 자동 수정하지 않습니다.'}
        'INSTALL_PARENT_MISSING' {return '선택한 앱 폴더의 상위 폴더가 없습니다. 이미 존재하는 개인 폴더 바로 아래의 새 앱 폴더를 선택하세요.'}
        'INSTALL_DESTINATION_*' {return '기존 설치 안에 설치하거나 덮어쓸 수 없습니다. 기존 설치와 별도의 새 앱 관리 폴더를 선택하세요.'}
        'INSTALL_EXPECTED_HASH_REQUIRED' {return '공식 출처에서 별도로 확인한 64자리 ZIP SHA-256을 입력하세요. 출처 불명의 해시 파일을 자동으로 신뢰하지 않습니다.'}
        'INSTALL_AUTH_*' {return '실제 인증을 확인하지 못했습니다. 현재 설치의 Desktop을 실행하고 등록 경로를 확인하세요. 키를 재발급하거나 Chrome 프로필을 초기화하지 마세요.'}
        'NATIVE_PATH_TOO_LONG' {return 'Native 메시징 파일 경로가 너무 깁니다. 더 짧은 새 개인 앱 폴더를 선택하세요.'}
        'INSTALL_MIGRATION_APPROVAL_REQUIRED' {return '기존 설정·백업·키를 읽고 복사하려면 별도 데이터 이전 승인이 필요합니다.'}
        'INSTALL_DISK_FULL' {return '설치 공간이 부족합니다. 불완전한 새 설치 폴더는 실행하지 말고 충분한 공간의 새 위치로 다시 설치하세요.'}
        default {return '설치를 완료하지 못했습니다. 새 불완전 폴더는 실행하지 마세요. 기존 설치·설정·키·등록은 그대로 두고 오류 코드와 설치 안내를 확인하세요.'}
    }
}
function Select-InstallModePackage($Package,[ValidateSet('DesktopChrome','ChromeOnly')][string]$Mode) {
    if($Mode -eq 'DesktopChrome'){return $Package}
    # Only a verified in-memory package is filtered. Never re-read extracted product files.
    $record=[Text.Encoding]::UTF8.GetString($Package.files['INSTALL-MANIFEST.json']).TrimStart([char]0xFEFF) | ConvertFrom-Json
    $files=@{};$selected=@()
    foreach($item in $record.files) {
        if($item.path -match '^(Desktop_Companion/|Installer/|Install\.bat$)'){continue}
        $files[$item.path]=$Package.files[$item.path];$selected+=$item
    }
    $record.files=$selected
    $record | Add-Member -NotePropertyName installationMode -NotePropertyValue 'ChromeOnly'
    $files['INSTALL-MANIFEST.json']=[Text.Encoding]::UTF8.GetBytes(($record|ConvertTo-Json -Depth 6))
    return [pscustomobject]@{files=$files;manifest=$record;zipHash=$Package.zipHash}
}
function Assert-InstallModeSecurity([string]$Directory,[string]$Mode) {
    $product=if($Mode -eq 'ChromeOnly'){'Browser_Extension'}else{'Desktop_Companion'}
    Assert-AmbientInstallSecurity (Join-Path $Directory $product)
    if($Mode -ne 'ChromeOnly'){Test-InstallLaunchPrerequisites (Join-Path $Directory $product)}
}
function Install-AmbientWorkspace([string]$PackagePath,[string]$ExpectedSha256,[string]$DestinationRoot,[switch]$SourceVerified,[string]$ExistingInstall='',[switch]$ApproveMigration,[ValidateSet('DesktopChrome','ChromeOnly')][string]$InstallMode='DesktopChrome') {
    if($PSVersionTable.PSEdition -ne 'Desktop' -or $ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage'){Stop-AmbientInstall 'INSTALL_POWERSHELL_REQUIRED'}
    if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){Stop-AmbientInstall 'INSTALL_STA_REQUIRED'}
    if(-not $SourceVerified){Stop-AmbientInstall 'INSTALL_SOURCE_APPROVAL_REQUIRED'}
    if($InstallMode -eq 'ChromeOnly' -and ($ExistingInstall -or $ApproveMigration)){Stop-AmbientInstall 'INSTALL_CHROME_ONLY_MIGRATION'}
    if($ExistingInstall -and -not $ApproveMigration){Stop-AmbientInstall 'INSTALL_MIGRATION_APPROVAL_REQUIRED'}
    Write-Host '파일 무결성 확인 중…'
    $package=Open-AmbientInstallPackage $PackagePath $ExpectedSha256
    if($package.manifest.reviewOnly){Write-Host '검토용 테스트 패키지입니다. 정식 버전이 아니며 실제 환경의 동작 검증이 진행 중입니다.'}
    Initialize-InstallPolicy $package
    Assert-InstallHelper $package
    $package=Select-InstallModePackage $package $InstallMode
    if(-not $DestinationRoot){$DestinationRoot=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'AmbientWorkspace'}
    $root=[IO.Path]::GetFullPath($DestinationRoot).TrimEnd('\')
    if($root.StartsWith('\\') -or $root -eq [IO.Path]::GetPathRoot($root).TrimEnd('\')){Stop-AmbientInstall 'INSTALL_DESTINATION_INVALID'}
    $drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($root))
    if($drive.DriveType -ne 'Fixed' -or $drive.DriveFormat -cne 'NTFS'){Stop-AmbientInstall 'INSTALL_NTFS_REQUIRED'}
    Write-Host '안전한 설치 위치 확인 중…'
    Assert-InstallAncestors ([IO.Path]::GetDirectoryName($root))
    if([IO.Directory]::Exists($root)){Test-AmbientPathAcl $root 'Private'}
    if([IO.Directory]::Exists((Join-Path $root 'Desktop_Companion')) -or [IO.File]::Exists((Join-Path $root 'Start.bat'))){Stop-AmbientInstall 'INSTALL_DESTINATION_EXISTING_PRODUCT'}
    $lease=$null; $personal=@(); $stage=''; $published=$false
    try {
        if($InstallMode -ne 'ChromeOnly'){$lease=Enter-InstallDesktopLease}
        # No old data contents are read before the explicit approval and Desktop lease.
        if($ExistingInstall) {
            $old=[IO.Path]::GetFullPath($ExistingInstall).TrimEnd('\')
            if([IO.Path]::GetFileName($old) -cne 'Desktop_Companion'){$old=Join-Path $old 'Desktop_Companion'}
            $oldRoot=[IO.Path]::GetDirectoryName($old)
            if([string]::Equals($root,$oldRoot,[StringComparison]::OrdinalIgnoreCase) -or $root.StartsWith($oldRoot+'\',[StringComparison]::OrdinalIgnoreCase)){Stop-AmbientInstall 'INSTALL_DESTINATION_OVERLAP'}
            try{Assert-AmbientInstallSecurity $old;Write-Host '기존 설치 위치의 접근 권한 검사 통과'}
            catch{Write-Host '기존 설치 위치의 접근 권한은 안전하다고 확인하지 못했습니다. 승인한 개인 파일만 복사하고 이전 위치의 노출 위험은 남습니다.'}
            foreach($name in @('settings.json','settings.json.bak','bridge-pairing.txt')) {
                $path=Join-Path $old $name
                if(-not [IO.File]::Exists($path)){continue}
                # Metadata-only warnings about the old ACL do not confer trust in its code.
                $parent=[IO.DirectoryInfo]::new($old)
                while($null -ne $parent){if([IO.File]::GetAttributes($parent.FullName) -band [IO.FileAttributes]::ReparsePoint){Stop-AmbientInstall 'INSTALL_MIGRATION_REPARSE'};$parent=$parent.Parent}
                if([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::ReparsePoint){Stop-AmbientInstall 'INSTALL_MIGRATION_REPARSE'}
                $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
                try{$bytes=Read-InstallStream $stream 1048576}catch{$stream.Dispose();throw}
                $personal+=@{name=$name;stream=$stream;bytes=$bytes;hash=(Get-InstallHash $bytes)}
            }
            if(-not @($personal | Where-Object name -CEQ 'settings.json').Count -or -not @($personal | Where-Object name -CEQ 'bridge-pairing.txt').Count){Stop-AmbientInstall 'INSTALL_MIGRATION_INCOMPLETE'}
            # Validate in memory, preserving the original bytes rather than normalizing files.
            . ([ScriptBlock]::Create([Text.Encoding]::UTF8.GetString($package.files['Desktop_Companion/Hotkey-Config.ps1']).TrimStart([char]0xFEFF)))
            $controlText=[Text.Encoding]::UTF8.GetString($package.files['Desktop_Companion/Control-State.ps1']).TrimStart([char]0xFEFF)
            $controlText=$controlText -replace '(?m)^\. \(Join-Path \$PSScriptRoot ''Hotkey-Config.ps1''\)\r?$',''
            . ([ScriptBlock]::Create($controlText))
            $settings=@($personal | Where-Object name -CEQ 'settings.json')[0]
            $null=ConvertTo-AmbientControlConfig ([Text.Encoding]::UTF8.GetString($settings.bytes).TrimStart([char]0xFEFF) | ConvertFrom-Json)
            $key=@($personal | Where-Object name -CEQ 'bridge-pairing.txt')[0]
            if([Text.Encoding]::UTF8.GetString($key.bytes).TrimStart([char]0xFEFF).Trim() -cnotmatch '^[a-f0-9]{64}$'){Stop-AmbientInstall 'INSTALL_MIGRATION_KEY_INVALID'}
        }
        $needed=16777216L;foreach($bytes in $package.files.Values){$needed+=$bytes.Length};foreach($item in $personal){$needed+=$item.bytes.Length}
        if((Get-InstallFreeBytes $root) -lt $needed){Stop-AmbientInstall 'INSTALL_DISK_FULL'}
        if(-not [IO.Directory]::Exists($root)){New-InstallPrivateDirectory $root}
        # Each attempt owns a new folder. No old installation is ever overwritten or removed.
        $stage=Join-Path $root ('.pending-'+[Guid]::NewGuid().ToString('N'))
        New-InstallPrivateDirectory $stage
        Write-Host '개인 전용 설치 폴더 준비 완료'
        foreach($name in $package.files.Keys) {
            $path=Join-Path $stage $name
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
            Write-InstallFile $path $package.files[$name]
        }
        Assert-InstalledProduct $stage $package
        foreach($item in $personal) {
            $target=Join-Path $stage ('Desktop_Companion/'+$item.name)
            Write-InstallFile $target $item.bytes
            $item.stream.Position=0
            if((Get-InstallHash (Read-InstallStream $item.stream 1048576)) -cne $item.hash -or (Get-InstallHash ([IO.File]::ReadAllBytes($target))) -cne $item.hash){Stop-AmbientInstall 'INSTALL_MIGRATION_HASH'}
        }
        Assert-InstallModeSecurity $stage $InstallMode
        if($InstallMode -ne 'ChromeOnly'){
            $aclOutput=@(& (Join-Path $PSHOME 'powershell.exe') -NoProfile -NonInteractive -File (Join-Path $stage 'Desktop_Companion/Test-FileSecurity.ps1'))
            if($LASTEXITCODE -ne 0){Stop-AmbientInstall 'INSTALL_FINAL_ACL'}
            Write-Host ($aclOutput -join "`n")
        }
        Assert-InstalledProduct $stage $package
        # A completion marker is only written after all verification. Failed stages remain private.
        $name=$package.manifest.version+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8)
        $final=Join-Path $root $name
        if([IO.Directory]::Exists($final)){Stop-AmbientInstall 'INSTALL_FOLDER_EXISTS'}
        if([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($stage)) -cne $root -or [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($final)) -cne $root -or [IO.Path]::GetFileName($stage) -cnotmatch '^\.pending-[a-f0-9]{32}$'){Stop-AmbientInstall 'INSTALL_DESTINATION_INVALID'}
        [IO.Directory]::Move($stage,$final);$stage=$final
        Assert-InstallModeSecurity $final $InstallMode
        Assert-InstalledProduct $final $package
        Write-InstallFile (Join-Path $final 'INSTALL-COMPLETE.json') ([Text.Encoding]::UTF8.GetBytes((@{schemaVersion=1;zipSha256=$package.zipHash;installationMode=$InstallMode;authentication='NOT_TESTED';migrated=[bool]$ExistingInstall}|ConvertTo-Json -Compress)))
        $published=$true
        Write-Host '파일 무결성 검사 통과 · 설치 완료'
        return [pscustomobject]@{directory=$final;desktop=$(if($InstallMode -eq 'ChromeOnly'){''}else{Join-Path $final 'Desktop_Companion'});extension=(Join-Path $final 'Browser_Extension');migrated=[bool]$ExistingInstall;installationMode=$InstallMode;authentication='NOT_TESTED'}
    } catch {
        if($stage -and -not $published){Write-Host ('설치를 완료하지 못한 새 폴더: '+$stage+' · 실행하지 마세요. 원본은 보존했습니다.')}
        throw
    } finally {
        foreach($item in $personal){$item.stream.Dispose();$item.bytes=$null}
        if($lease){$lease.ReleaseMutex();$lease.Dispose()}
    }
}
function Get-AmbientInstallerNativeState([string]$Directory) {
    Assert-AmbientInstallSecurity $Directory
    Assert-AmbientInstallerCompleted (Split-Path $Directory)
    foreach($name in @('Native-Mailbox.ps1','Native-Registration.ps1')){. (Join-Path $Directory $name)}
    $states=@(Get-AmbientNativeRegistryState 'org.ambientworkspace.bridge')
    $expected=Join-Path $Directory 'native-host.json'
    $same=@($states | Where-Object {$_.exists -and -not $_.extra -and $_.kind -ceq 'String' -and [string]::Equals($_.value,$expected,[StringComparison]::OrdinalIgnoreCase)})
    $hostValid=$false
    if($same.Count -eq 2) {
        try {
            $hostManifest=Read-AmbientNativeJson $expected 32768
            $exe=Join-Path $Directory 'AmbientNativeHost.exe'
            $hostValid=$hostManifest.name -ceq 'org.ambientworkspace.bridge' -and $hostManifest.type -ceq 'stdio' -and
                [string]::Equals([IO.Path]::GetFullPath($hostManifest.path),$exe,[StringComparison]::OrdinalIgnoreCase) -and
                @($hostManifest.allowed_origins).Count -eq 1 -and $hostManifest.allowed_origins -ccontains ('chrome-extension://'+$script:InstallerId+'/') -and
                [IO.File]::Exists($exe) -and [IO.File]::Exists((Join-Path $Directory 'native-host-build.json'))
        } catch {$hostValid=$false}
    }
    return [pscustomobject]@{status=$(if($hostValid){'registered'}elseif(@($states|Where-Object exists).Count){'reregisterRequired'}else{'installRequired'});paths=@($states|Where-Object exists|ForEach-Object{$_.value});authentication='NOT_TESTED'}
}
function Assert-AmbientInstallerCompleted([string]$Root) {
    if(-not [IO.File]::Exists((Join-Path $Root 'INSTALL-COMPLETE.json'))){Stop-AmbientInstall 'INSTALL_NOT_COMPLETE'}
    $manifest=Get-Content -LiteralPath (Join-Path $Root 'INSTALL-MANIFEST.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if($manifest.schemaVersion -ne 1 -or $manifest.product -cne 'AmbientWorkspace'){Stop-AmbientInstall 'INSTALL_MANIFEST_INVALID'}
    foreach($item in $manifest.files) {
        if(-not (Test-InstallRelativePath $item.path) -or (Get-InstallHash ([IO.File]::ReadAllBytes((Join-Path $Root $item.path)))) -cne $item.sha256){Stop-AmbientInstall 'INSTALL_COPIED_HASH'}
    }
}
function Read-InstallPipeBytes($Stream,[int]$Count,$Deadline) {
    $buffer=New-Object byte[] $Count; $offset=0
    while($offset -lt $Count) {
        $remaining=[int][Math]::Max(1,($Deadline-[DateTime]::UtcNow).TotalMilliseconds)
        $task=$Stream.ReadAsync($buffer,$offset,$Count-$offset)
        if(-not $task.Wait($remaining)){Stop-AmbientInstall 'INSTALL_AUTH_TIMEOUT'}
        $read=$task.Result
        if($read -le 0){Stop-AmbientInstall 'INSTALL_AUTH_EOF'}
        $offset+=$read
    }
    return ,$buffer
}
function Test-AmbientInstallerAuthentication([string]$Directory,[switch]$ApproveKeyRead) {
    if(-not $ApproveKeyRead){Stop-AmbientInstall 'INSTALL_AUTH_APPROVAL_REQUIRED'}
    if((Get-AmbientInstallerNativeState $Directory).status -cne 'registered'){Stop-AmbientInstall 'INSTALL_NATIVE_NOT_REGISTERED'}
    . (Join-Path $Directory 'Native-Framing.ps1')
    $build=Get-Content -LiteralPath (Join-Path $Directory 'native-host-build.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $exe=Join-Path $Directory 'AmbientNativeHost.exe'
    if($build.sourceSha256 -cne (Get-InstallHash ([IO.File]::ReadAllBytes((Join-Path $Directory 'NativeHost.cs')))) -or $build.binarySha256 -cne (Get-InstallHash ([IO.File]::ReadAllBytes($exe)))){Stop-AmbientInstall 'INSTALL_NATIVE_BINARY_HASH'}
    $key=[IO.File]::ReadAllText((Join-Path $Directory 'bridge-pairing.txt')).TrimStart([char]0xFEFF).Trim()
    if($key -cnotmatch '^[a-f0-9]{64}$'){Stop-AmbientInstall 'INSTALL_MIGRATION_KEY_INVALID'}
    $process=$null
    try {
        $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$exe
        $info.Arguments='chrome-extension://'+$script:InstallerId+'/'
        $info.WorkingDirectory=$Directory;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
        $info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        $process=[Diagnostics.Process]::Start($info);$null=$process.StandardError.ReadToEndAsync()
        $id=[Guid]::NewGuid().ToString('N')
        Write-AmbientNativeFrame $process.StandardInput.BaseStream @{id=$id;packet=@{type='control.hello';token=$key}}
        $key=$null
        $deadline=[DateTime]::UtcNow.AddSeconds(5)
        $header=Read-InstallPipeBytes $process.StandardOutput.BaseStream 4 $deadline
        $length=[BitConverter]::ToUInt32($header,0)
        if($length -lt 1 -or $length -gt 524288){Stop-AmbientInstall 'INSTALL_AUTH_FRAME'}
        $reply=[Text.UTF8Encoding]::new($false,$true).GetString((Read-InstallPipeBytes $process.StandardOutput.BaseStream ([int]$length) $deadline)) | ConvertFrom-Json
        if($reply.id -cne $id -or $reply.transport -cne 'ok' -or -not $reply.result.ok -or $reply.result.status -cne 'snapshot'){Stop-AmbientInstall 'INSTALL_AUTH_NOT_CONFIRMED'}
        # A real, authenticated Host -> private mailbox -> running Desktop round trip.
        # No profileId is sent: never creates/renews a Chrome profile lease.
        return [pscustomobject]@{hostAuthentication='authenticated';chromeProfile='NOT_TESTED'}
    } finally {
        $key=$null
        if($process){try{$process.StandardInput.Close();$null=$process.WaitForExit(2000)}finally{$process.Dispose()}}
    }
}
function Open-AmbientInstallerNativeSetup([string]$Directory,[switch]$ApproveRegistration) {
    if(-not $ApproveRegistration){Stop-AmbientInstall 'INSTALL_NATIVE_APPROVAL_REQUIRED'}
    $null=Get-AmbientInstallerNativeState $Directory
    # Existing GUI makes the final Install/Repair choice and retains its rollback journal.
    & (Join-Path $PSHOME 'powershell.exe') -NoProfile -STA -File (Join-Path $Directory 'Register-NativeHost.ps1') -Gui
    if($LASTEXITCODE -ne 0){Stop-AmbientInstall 'INSTALL_NATIVE_SETUP_FAILED'}
    return (Get-AmbientInstallerNativeState $Directory)
}
function Get-InstallPackageHint([string]$ExtractedRoot) {
    # A filename hint only; it never grants trust or supplies an expected hash.
    $candidates=@((Join-Path (Split-Path $ExtractedRoot) ((Split-Path $ExtractedRoot -Leaf)+'.zip')))
    $manifestPath=Join-Path $ExtractedRoot 'INSTALL-MANIFEST.json'
    if([IO.File]::Exists($manifestPath)) {
        try {
            $stream=[IO.File]::OpenRead($manifestPath)
            try{$record=[Text.Encoding]::UTF8.GetString((Read-InstallStream $stream 262144)).TrimStart([char]0xFEFF)|ConvertFrom-Json}finally{$stream.Dispose()}
            if($record.PSObject.Properties['archiveFileName'] -and $record.archiveFileName -cmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,120}\.zip$') {
                $candidates+=Join-Path (Split-Path $ExtractedRoot) $record.archiveFileName
                $candidates+=Join-Path $ExtractedRoot $record.archiveFileName
            }
        } catch { return '' }
    }
    foreach($path in $candidates){if([IO.File]::Exists($path)){return $path}}
    return ''
}
function Assert-InstallExtractedLayout([string]$Root) {
    foreach($name in @('Install.bat','INSTALL-MANIFEST.json','Installer/Install-AmbientWorkspace.ps1','Browser_Extension/manifest.json','Desktop_Companion/Start.bat')) {
        if(-not [IO.File]::Exists((Join-Path $Root $name))){Stop-AmbientInstall 'INSTALL_EXTRACT_ALL'}
    }
}
function Open-InstallChromeExtensions {
    foreach($parent in @([Environment]::GetFolderPath('ProgramFiles'),[Environment]::GetFolderPath('ProgramFilesX86'),[Environment]::GetFolderPath('LocalApplicationData'))) {
        $chrome=Join-Path $parent 'Google/Chrome/Application/chrome.exe'
        if([IO.File]::Exists($chrome)){Start-Process -FilePath $chrome -ArgumentList 'chrome://extensions/' ;return}
    }
    Stop-AmbientInstall 'INSTALL_CHROME_NOT_FOUND'
}
function Start-InstalledAmbientDesktop([string]$Directory) {
    Assert-AmbientInstallerCompleted (Split-Path $Directory)
    Assert-AmbientInstallSecurity $Directory
    Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -WindowStyle Hidden -ArgumentList ('-NoProfile -NonInteractive -STA -File "'+(Join-Path $Directory 'Launch-AmbientDesktop.ps1')+'"')
    # Starting a process is not proof of readiness or authentication. Chrome checks both.
}
function New-AmbientInstallWizard([string]$ExtractedRoot) {
    if($PSVersionTable.PSEdition -ne 'Desktop' -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){Stop-AmbientInstall 'INSTALL_POWERSHELL_REQUIRED'}
    Add-Type -AssemblyName PresentationFramework,System.Windows.Forms
    # Embedded UI: no neighboring XAML or script is executed before package verification.
    $xaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Ambient Workspace · 설치 시작" Width="800" Height="800" MinWidth="640" MinHeight="560" WindowStartupLocation="CenterScreen" Background="#101724" Foreground="#EFF5FF" FontFamily="Segoe UI, Malgun Gothic" FontSize="14">
  <Window.Resources>
    <Style TargetType="TextBlock"><Setter Property="TextWrapping" Value="Wrap"/><Setter Property="Margin" Value="0,0,0,10"/></Style>
    <Style TargetType="TextBox"><Setter Property="Background" Value="#1E2C40"/><Setter Property="Foreground" Value="#EFF5FF"/><Setter Property="BorderBrush" Value="#526581"/><Setter Property="Padding" Value="9"/><Setter Property="Margin" Value="0,0,0,10"/></Style>
    <Style TargetType="Button"><Setter Property="Padding" Value="16,10"/><Setter Property="Margin" Value="0,0,8,8"/><Setter Property="Background" Value="#D6E7FF"/><Setter Property="Foreground" Value="#112139"/><Setter Property="BorderThickness" Value="0"/></Style>
    <Style TargetType="CheckBox"><Setter Property="Margin" Value="0,5,0,12"/><Setter Property="Foreground" Value="#EFF5FF"/></Style>
    <Style TargetType="RadioButton"><Setter Property="Margin" Value="0,5,18,12"/><Setter Property="Foreground" Value="#EFF5FF"/></Style>
  </Window.Resources>
  <Grid Margin="28">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <StackPanel Grid.Row="0">
      <TextBlock Text="AMBIENT WORKSPACE / RC.2 REVIEW" Foreground="#91B6F8" FontSize="12"/>
      <TextBlock x:Name="Heading" Text="설치 시작" FontSize="28" FontWeight="SemiBold"/>
      <TextBlock x:Name="StepLabel" Text="1 설치 시작  →  2 Chrome 확장 설치  →  3 Windows 연결  →  4 설치 완료" Foreground="#B9C9DF"/>
    </StackPanel>
    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="0,12,0,12">
      <Grid>
        <StackPanel x:Name="Page1">
          <TextBlock Text="ZIP 전체를 모두 압축 풀기한 뒤 실행하세요. 원본 ZIP은 검증에 필요하니 보관하세요."/>
          <TextBlock Text="다운로드한 Windows 설치 ZIP" FontWeight="SemiBold"/>
          <DockPanel><Button x:Name="BrowseZip" Content="ZIP 선택" DockPanel.Dock="Right"/><TextBox x:Name="ZipPath" IsReadOnly="True" AutomationProperties.Name="원본 ZIP 경로"/></DockPanel>
          <TextBlock Text="공식 Release 본문에서 복사한 ZIP SHA-256" FontWeight="SemiBold"/>
          <TextBox x:Name="ExpectedHash" MaxLength="64" AutomationProperties.Name="별도로 게시된 SHA-256"/>
          <TextBlock Text="ZIP 안의 체크섬을 자동으로 신뢰하지 않습니다. 이 비교는 파일 일치 확인이며 배포자 전자서명이 아닙니다. 로컬 검토 ZIP은 별도 검토 기록의 해시를 사용합니다." Foreground="#B9C9DF" FontSize="12"/>
          <CheckBox x:Name="SourceConsent"><TextBlock Text="공식 다운로드 출처와 별도로 게시된 해시를 확인했습니다."/></CheckBox>
          <WrapPanel><RadioButton x:Name="DesktopMode" GroupName="Mode" Content="Windows 앱도 사용" IsChecked="True"/><RadioButton x:Name="ChromeMode" GroupName="Mode" Content="Chrome만 사용"/></WrapPanel>
          <TextBlock Text="Chrome만 사용: 확장과 안내 문서만 설치합니다. Desktop 실행·등록·페어링 없이 웹 효과를 쓸 수 있습니다." Foreground="#B9C9DF" FontSize="12"/>
          <CheckBox x:Name="UpdateMode" Content="기존 Desktop에서 업데이트 · 설정과 키 보존"/>
          <StackPanel x:Name="MigrationPanel" Visibility="Collapsed">
            <DockPanel><Button x:Name="BrowseOld" Content="기존 폴더 선택" DockPanel.Dock="Right"/><TextBox x:Name="OldPath" IsReadOnly="True" AutomationProperties.Name="기존 설치 폴더"/></DockPanel>
            <CheckBox x:Name="MigrationConsent"><TextBlock Text="기존 settings.json · settings.json.bak · bridge-pairing.txt 읽기와 새 폴더로 복사를 승인합니다. 원본은 보존합니다."/></CheckBox>
          </StackPanel>
          <Expander Header="설치 위치 · 고급" Foreground="#EFF5FF" Margin="0,0,0,12"><StackPanel Margin="0,12,0,0"><TextBox x:Name="Destination" AutomationProperties.Name="새 설치 관리 폴더"/><TextBlock Text="현재 사용자 전용 로컬 NTFS 폴더에 버전별 새 폴더를 만듭니다. 기존 설치를 덮어쓰거나 기존 폴더 권한을 고치지 않습니다."/></StackPanel></Expander>
        </StackPanel>
        <StackPanel x:Name="Page2" Visibility="Collapsed">
          <TextBlock Text="Chrome에서 한 번만 직접 추가하세요" FontSize="21" FontWeight="SemiBold"/>
          <TextBlock Text="1. Chrome 확장 관리 열기를 누르세요. 열리지 않으면 Chrome 주소창에 chrome://extensions를 입력하세요."/>
          <Button x:Name="OpenChrome" Content="Chrome 확장 관리 열기" HorizontalAlignment="Left"/>
          <TextBlock Text="2. 오른쪽 위 개발자 모드를 켜고 압축해제된 확장 프로그램을 로드합니다 버튼을 누르세요. Chrome 버전에 따라 띄어쓰기는 다를 수 있습니다."/>
          <TextBlock Text="3. 폴더 위치 복사를 누르고 폴더 선택 창의 주소창에 붙여넣으세요. 아래 Browser_Extension 폴더 자체를 선택합니다. source 또는 상위 폴더가 아닙니다."/>
          <TextBox x:Name="ExtensionPath" IsReadOnly="True" AutomationProperties.Name="Chrome에 추가할 Browser_Extension 폴더"/>
          <Button x:Name="CopyExtension" Content="폴더 위치 복사" HorizontalAlignment="Left"/>
          <CheckBox x:Name="ExtensionConfirmed"><TextBlock Text="Chrome 확장 목록에 Ambient Workspace가 보입니다. (직접 확인)"/></CheckBox>
          <TextBlock Text="업데이트라면 같은 고정 ID의 기존 확장이 새 설치 폴더를 사용하는지 확인하세요. 확장을 삭제하거나 Chrome 프로필을 초기화하지 마세요. 설치된 폴더는 이동·삭제하지 마세요." Foreground="#B9C9DF"/>
          <TextBlock Text="Chrome Web Store에는 아직 게시되지 않았습니다. 자동 설치나 Chrome 보안 정책 우회는 하지 않습니다." Foreground="#B9C9DF"/>
        </StackPanel>
        <StackPanel x:Name="Page3" Visibility="Collapsed">
          <TextBlock Text="Windows 앱까지 연결할 때만 진행하세요" FontSize="21" FontWeight="SemiBold"/>
          <TextBlock Text="1. Desktop 실행을 누르세요. 이미 다른 버전이 실행 중이면 그 트레이에서 Desktop 앱 종료를 선택한 뒤 다시 누르세요."/>
          <Button x:Name="StartDesktop" Content="Desktop 실행" HorizontalAlignment="Left"/>
          <TextBlock Text="2. 연결 등록 열기로 기존 등록 화면을 여세요. 처음 등록 또는 이 폴더로 재등록 버튼을 누를 때 현재 사용자 레지스트리가 변경됩니다. 아래 버튼만으로 등록되지는 않습니다."/>
          <Button x:Name="OpenNative" Content="연결 등록 열기" HorizontalAlignment="Left"/>
          <TextBlock x:Name="NativeProgress" Text="Windows 연결 경로: 아직 확인하지 않음" Foreground="#91B6F8"/>
          <TextBlock Text="3. Chrome 팝업 → 연결 설정 → Windows 연결을 누르세요. 연결 경로·Desktop 실행·기존 인증을 순서대로 검사합니다. 최초 인증 안내가 나올 때만 Desktop 설정 → 연결의 페어링 코드 복사로 기존 코드를 붙여넣고 코드 저장 · 연결 검사를 누르세요."/>
          <TextBlock Text="실제 Desktop 인증: Chrome 팝업에서 확인 / YouTube 캡처: 사용자가 별도 승인" Foreground="#91B6F8"/>
          <TextBlock Text="페어링 키는 설치 화면에서 읽거나 새로 만들지 않습니다. Windows 연결은 기존 rc.2 팝업을 그대로 사용합니다. 지금 연결하지 않아도 웹 효과는 사용할 수 있습니다." Foreground="#B9C9DF"/>
        </StackPanel>
        <StackPanel x:Name="Page4" Visibility="Collapsed">
          <TextBlock Text="파일 설치가 완료되었습니다" FontSize="23" FontWeight="SemiBold"/>
          <TextBlock x:Name="CompletionText"/>
          <TextBlock Text="실제 설치 폴더" FontWeight="SemiBold"/><TextBox x:Name="InstalledPath" IsReadOnly="True"/>
          <TextBlock x:Name="LaunchLabel" Text="다음 실행 파일" FontWeight="SemiBold"/><TextBox x:Name="LaunchPath" IsReadOnly="True"/>
          <Button x:Name="CopyLaunch" Content="실행 위치 복사" HorizontalAlignment="Left"/>
          <TextBlock Text="바로 시작하기" FontSize="20" FontWeight="SemiBold" Margin="0,18,0,10"/>
          <TextBlock Text="그라데이션: ChatGPT · Claude · Gemini · Notion 탭을 새로고침하세요. YouTube 연결 없이 웹 배경을 사용할 수 있습니다."/>
          <TextBlock Text="영상 배경: YouTube 영상 로딩을 마치고 팝업의 YouTube 연결을 누르세요. 공유 선택창이 나오면 해당 YouTube 탭만 직접 승인하세요."/>
          <TextBlock Text="Windows 출력: 실제 Windows 연결 확인 뒤 Windows로 전송을 켜세요. 영상도 원하면 흐릿한 영상도 전송과 Desktop의 영상 사용을 확인하세요."/>
          <TextBlock Text="Chrome 효과 일시정지/재개는 Desktop 없이 동작합니다. 캡처를 끝내려면 취소·해제를 누르세요." Foreground="#B9C9DF"/>
        </StackPanel>
      </Grid>
    </ScrollViewer>
    <Border Grid.Row="2" Background="#1B293D" Padding="14" Margin="0,0,0,16" CornerRadius="6"><StackPanel><TextBlock x:Name="UserStatus" Text="지원 환경과 파일을 확인한 뒤 새 개인 폴더에 설치합니다." Margin="0"/><TextBlock x:Name="ErrorCode" Foreground="#FFBFAC" FontFamily="Consolas" FontSize="12" Margin="0,7,0,0"/></StackPanel></Border>
    <DockPanel Grid.Row="3" LastChildFill="False"><Button x:Name="Cancel" Content="취소" DockPanel.Dock="Left"/><Button x:Name="Next" Content="확인 후 설치" DockPanel.Dock="Right" Margin="0,0,0,8"/><Button x:Name="Back" Content="이전" DockPanel.Dock="Right" IsEnabled="False"/></DockPanel>
  </Grid>
</Window>
'@
    $reader=[Xml.XmlNodeReader]::new([xml]$xaml)
    try{$window=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Close()}
    $window.MaxHeight=[Math]::Max(560,[Windows.SystemParameters]::WorkArea.Height-24)
    $window.Height=[Math]::Min($window.Height,$window.MaxHeight)
    $controls=@{}
    foreach($name in @('Heading','StepLabel','Page1','Page2','Page3','Page4','ZipPath','BrowseZip','ExpectedHash','SourceConsent','DesktopMode','ChromeMode','UpdateMode','MigrationPanel','OldPath','BrowseOld','MigrationConsent','Destination','OpenChrome','ExtensionPath','CopyExtension','ExtensionConfirmed','StartDesktop','OpenNative','NativeProgress','CompletionText','InstalledPath','LaunchLabel','LaunchPath','CopyLaunch','UserStatus','ErrorCode','Cancel','Next','Back')){$controls[$name]=$window.FindName($name)}
    $state=[pscustomobject]@{window=$window;controls=$controls;step=1;result=$null;busy=$false;cancelled=$false;finished=$false}
    $controls.ZipPath.Text=Get-InstallPackageHint $ExtractedRoot
    $controls.Destination.Text=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'AmbientWorkspace'
    $render={
        foreach($i in 1..4){$state.controls['Page'+$i].Visibility=if($i -eq $state.step){'Visible'}else{'Collapsed'}}
        $state.controls.Heading.Text=@('','설치 시작','Chrome 확장 설치','Windows 연결','설치 완료')[$state.step]
        $state.controls.Next.Content=@('','확인 후 설치','다음','나중에 연결 · 마치기','닫기')[$state.step]
        $state.controls.Back.IsEnabled=$state.step -gt 2
        $state.controls.Cancel.Content=if($state.step -eq 1){'취소'}else{'닫기 · 나중에 계속'}
        $state.controls.ErrorCode.Text=''
    }.GetNewClosure()
    $run={param([scriptblock]$Action)
        if($state.busy){return}
        $state.controls.ErrorCode.Text=''
        try{& $Action}catch{$code=Get-InstallErrorCode $_;$state.controls.UserStatus.Text=Get-InstallErrorHelp $code;$state.controls.ErrorCode.Text='원인 코드: '+$code}
    }.GetNewClosure()
    $controls.BrowseZip.Add_Click({&$run {
        $dialog=[Microsoft.Win32.OpenFileDialog]::new();$dialog.Title='다운로드한 원본 Windows 설치 ZIP 선택';$dialog.Filter='Windows 설치 ZIP (*.zip)|*.zip'
        if($dialog.ShowDialog($state.window)){$state.controls.ZipPath.Text=$dialog.FileName}
    }}.GetNewClosure())
    $controls.BrowseOld.Add_Click({&$run {
        $dialog=[Windows.Forms.FolderBrowserDialog]::new();$dialog.Description='기존 설치 루트 또는 Desktop_Companion 폴더 선택';$dialog.ShowNewFolderButton=$false
        try{if($dialog.ShowDialog() -eq 'OK'){$state.controls.OldPath.Text=$dialog.SelectedPath}}finally{$dialog.Dispose()}
    }}.GetNewClosure())
    $controls.UpdateMode.Add_Checked({$state.controls.MigrationPanel.Visibility='Visible'}.GetNewClosure())
    $controls.UpdateMode.Add_Unchecked({$state.controls.MigrationPanel.Visibility='Collapsed';$state.controls.MigrationConsent.IsChecked=$false}.GetNewClosure())
    $controls.ChromeMode.Add_Checked({$state.controls.UpdateMode.IsChecked=$false;$state.controls.UpdateMode.IsEnabled=$false}.GetNewClosure())
    $controls.DesktopMode.Add_Checked({$state.controls.UpdateMode.IsEnabled=$true}.GetNewClosure())
    $controls.OpenChrome.Add_Click({&$run {Open-InstallChromeExtensions;$state.controls.UserStatus.Text='Chrome에서 개발자 모드를 켜고 아래 폴더를 직접 선택하세요.'}}.GetNewClosure())
    $controls.CopyExtension.Add_Click({&$run {[Windows.Clipboard]::SetText($state.result.extension);$state.controls.UserStatus.Text='확장 폴더 위치를 복사했습니다. Chrome 폴더 선택 창의 주소창에 붙여넣으세요.'}}.GetNewClosure())
    $controls.CopyLaunch.Add_Click({&$run {[Windows.Clipboard]::SetText($state.controls.LaunchPath.Text);$state.controls.UserStatus.Text='실행 위치를 복사했습니다.'}}.GetNewClosure())
    $controls.StartDesktop.Add_Click({&$run {Start-InstalledAmbientDesktop $state.result.desktop;$state.controls.UserStatus.Text='Desktop 실행을 요청했습니다. 트레이 아이콘과 Chrome Windows 연결에서 실제 실행을 확인하세요.'}}.GetNewClosure())
    $controls.OpenNative.Add_Click({&$run {
        $native=Open-AmbientInstallerNativeSetup $state.result.desktop -ApproveRegistration
        $labels=@{registered='현재 설치로 등록됨 · 실제 인증은 Chrome에서 확인';reregisterRequired='다른 위치가 등록됨 · 이 폴더로 재등록 필요';installRequired='아직 등록되지 않음'}
        $state.controls.NativeProgress.Text='Windows 연결 경로: '+$labels[$native.status]
        $state.controls.UserStatus.Text='등록과 실제 인증은 별도입니다. Chrome 팝업의 Windows 연결을 누르세요.'
    }}.GetNewClosure())
    $controls.Next.Add_Click({&$run {
        switch($state.step) {
            1 {
                if(-not $state.controls.SourceConsent.IsChecked){Stop-AmbientInstall 'INSTALL_SOURCE_APPROVAL_REQUIRED'}
                if(-not [IO.File]::Exists($state.controls.ZipPath.Text)){Stop-AmbientInstall 'INSTALL_PACKAGE_MISSING'}
                $mode=if($state.controls.ChromeMode.IsChecked){'ChromeOnly'}else{'DesktopChrome'}
                $old='';$approved=$false
                if($state.controls.UpdateMode.IsChecked){
                    $old=$state.controls.OldPath.Text;$approved=[bool]$state.controls.MigrationConsent.IsChecked
                    if(-not $old -or -not $approved){Stop-AmbientInstall 'INSTALL_MIGRATION_APPROVAL_REQUIRED'}
                }
                $state.busy=$true;$state.controls.Next.IsEnabled=$false;$state.controls.Page1.IsEnabled=$false
                $state.controls.UserStatus.Text='해시 · 지원 환경 · 개인 폴더 권한을 확인하고 설치 중입니다. 완료될 때까지 기다려 주세요.'
                [void]$state.window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Render)
                try{$state.result=Install-AmbientWorkspace $state.controls.ZipPath.Text $state.controls.ExpectedHash.Text.Trim() $state.controls.Destination.Text -SourceVerified -ExistingInstall $old -ApproveMigration:$approved -InstallMode $mode}
                finally{$state.busy=$false;$state.controls.Next.IsEnabled=$true;$state.controls.Page1.IsEnabled=$true}
                $state.controls.ExtensionPath.Text=$state.result.extension
                $state.controls.InstalledPath.Text=$state.result.directory
                $state.controls.LaunchPath.Text=if($mode -eq 'ChromeOnly'){$state.result.extension}else{Join-Path $state.result.desktop 'Start.bat'}
                $state.controls.LaunchLabel.Text=if($mode -eq 'ChromeOnly'){'Chrome에 추가할 폴더 (Desktop 없음)'}else{'다음에 Desktop을 실행할 파일'}
                $state.controls.CompletionText.Text=if($mode -eq 'ChromeOnly'){'Chrome 확장과 문서만 설치했습니다. Desktop·등록·페어링 없이 웹 효과를 시작하세요.'}else{'파일·해시·ACL 검사를 통과했습니다. Windows 연결의 실제 인증과 YouTube 캡처는 Chrome 팝업에서 직접 확인하세요.'}
                $state.step=2;&$render
                $state.controls.UserStatus.Text='파일 설치 완료. 이제 Chrome에서 확장을 직접 추가하세요.'
            }
            2 {
                if(-not $state.controls.ExtensionConfirmed.IsChecked){Stop-AmbientInstall 'INSTALL_EXTENSION_NOT_CONFIRMED'}
                $state.step=if($state.result.installationMode -eq 'ChromeOnly'){4}else{3};&$render
                $state.controls.UserStatus.Text=if($state.step -eq 4){'파일 설치 완료 · Chrome 확장 추가는 사용자 확인입니다. 웹 탭에서 효과를 확인하세요.'}else{'Windows 연결은 선택 사항입니다. Desktop 실행·등록·실제 인증을 순서대로 진행하세요.'}
            }
            3 {$state.step=4;&$render;$state.controls.UserStatus.Text='파일 설치 완료 · 실제 Desktop 인증과 YouTube 연결 상태는 Chrome에서 확인하세요.'}
            4 {$state.finished=$true;$state.window.Close()}
        }
    }}.GetNewClosure())
    $controls.Back.Add_Click({if($state.step -gt 2){$state.step=if($state.result.installationMode -eq 'ChromeOnly'){2}else{$state.step-1};&$render}}.GetNewClosure())
    $controls.Cancel.Add_Click({if(-not $state.busy){$state.window.Close()}}.GetNewClosure())
    $window.Add_Closing({param($sender,$eventArgs)
        if($state.busy){$eventArgs.Cancel=$true;$state.controls.UserStatus.Text='파일 검증과 설치가 끝난 뒤 닫을 수 있습니다. 기존 설치는 보존합니다.'}
        elseif(-not $state.finished){$state.cancelled=$true}
    }.GetNewClosure())
    return $state
}
function Invoke-AmbientGraphicalInstallWizard {
    $root=Split-Path (Split-Path $script:InstallerScriptPath)
    Assert-InstallExtractedLayout $root
    $state=New-AmbientInstallWizard $root
    [void]$state.window.ShowDialog()
}
function Invoke-AmbientInstallWizard {
    Write-Host 'Ambient Workspace 안전한 설치 도우미 (rc.2 개발용)'
    Write-Host '공식 출처에서 확인한 ZIP과 SHA-256이 필요합니다. 기존 폴더 권한·키·Chrome 프로필은 자동 변경하지 않습니다.'
    $zip=(Read-Host '다운로드한 공식 ZIP의 전체 경로').Trim().Trim('"')
    $hash=(Read-Host '공식 Release에서 별도로 확인한 ZIP SHA-256').Trim()
    if((Read-Host '출처와 해시를 확인했습니까? 확인했다면 설치 입력') -cne '설치'){return}
    $suggested=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'AmbientWorkspace'
    Write-Host ('기본 위치: '+$suggested+' · 상위 경로가 차단되면 '+(Join-Path $env:USERPROFILE 'AmbientWorkspace')+' 등 새 개인 위치를 선택하세요.')
    $destination=(Read-Host '설치 위치 (Enter: 기본 위치)').Trim().Trim('"');if(-not $destination){$destination=$suggested}
    $old='';$approved=$false
    if((Read-Host '기존 설정·백업·페어링 키를 복사하려면 이전 입력 (Enter: 신규 설치)') -ceq '이전') {
        $old=(Read-Host '기존 설치 루트 또는 Desktop_Companion 경로').Trim().Trim('"')
        Write-Host '기존 개인 파일은 읽고 복사만 합니다. 원본은 삭제하지 않으며 이전 위치의 노출 위험은 남습니다.'
        $approved=(Read-Host '이 세 파일을 읽고 복사하도록 승인하면 복사 입력') -ceq '복사'
        if(-not $approved){return}
    }
    $result=Install-AmbientWorkspace $zip $hash $destination -SourceVerified -ExistingInstall $old -ApproveMigration:$approved
    Write-Host ('Windows 실행: '+(Join-Path $result.desktop 'Start.bat'))
    Write-Host ('Chrome 확장 위치: '+$result.extension)
    try {
        $native=Get-AmbientInstallerNativeState $result.desktop
        $labels=@{installRequired='Chrome 연결 등록 필요';reregisterRequired='새 설치 위치로 Chrome 연결 재등록 필요';registered='현재 폴더 등록 확인 · 인증은 별도 검사'}
        Write-Host ($labels[$native.status]+' ['+$native.status+']');foreach($path in $native.paths){Write-Host ('기존 등록: '+$path)}
        if((Read-Host '등록 안내창을 열려면 등록 입력 (Enter: 나중에)') -ceq '등록'){$native=Open-AmbientInstallerNativeSetup $result.desktop -ApproveRegistration;Write-Host ('등록 상태: '+$native.status)}
    } catch {Write-Host ('Chrome 연결 미완료: '+(Get-InstallErrorCode $_))}
    Write-Host 'Desktop을 먼저 실행하면 기존 키로 Host 인증을 검사할 수 있습니다. 키는 메모리와 표준 입출력에서만 사용하며 재발급하지 않습니다.'
    if((Read-Host '현재 설치의 키를 읽어 실제 Host 인증을 검사하려면 인증 입력 (Enter: 나중에)') -ceq '인증') {
        try{$auth=Test-AmbientInstallerAuthentication $result.desktop -ApproveKeyRead;Write-Host ('Host 인증: '+$auth.hostAuthentication)}catch{Write-Host ('Host 인증 미확인: '+(Get-InstallErrorCode $_))}
    }
    Write-Host 'Windows 연결 마무리: 등록한 폴더의 Start.bat으로 Desktop을 실행하고 Chrome 팝업에서 Windows 연결을 누르세요. 저장된 인증을 먼저 확인하며 최초 연결일 때만 기존 코드를 입력합니다. 확장 삭제·설정·키 초기화는 필요하지 않습니다.'
}
if($MyInvocation.InvocationName -ne '.') {
    try {
        if($Console){Invoke-AmbientInstallWizard}
        elseif($Interactive -or -not $PackagePath){Invoke-AmbientGraphicalInstallWizard}
        else{Install-AmbientWorkspace $PackagePath $ExpectedSha256 $DestinationRoot -SourceVerified:$SourceVerified -ExistingInstall $ExistingInstall -ApproveMigration:$ApproveMigration -InstallMode $InstallMode}
    } catch {
        $code=Get-InstallErrorCode $_
        Write-Host ('설치할 수 없음: '+$code+"`n"+(Get-InstallErrorHelp $code))
        exit 1
    }
}
