# Standalone bootstrap. Never imports code from the extracted source directory.
param(
    [string]$PackagePath='', [string]$ExpectedSha256='', [string]$DestinationRoot='',
    [switch]$SourceVerified, [string]$ExistingInstall='', [switch]$ApproveMigration,
    [switch]$Interactive
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
    return ($Path -match '^(Desktop_Companion/[^/]+\.(ps1|xaml|cs|bat|json|js|html)|Browser_Extension/(manifest\.json|identity\.public\.json|source/[^/]+\.(js|html|css)|icons/[^/]+\.(svg|png))|docs/[A-Za-z0-9._-]+\.md|licenses/[^/]+\.txt|Installer/(Install-AmbientWorkspace\.ps1|product-files\.json)|Install\.bat|README\.md|CHANGELOG\.md|LICENSE|COPYRIGHT\.md|THIRD_PARTY_NOTICES\.md)$')
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
        Assert-InstallIdentity $files
        return [pscustomobject]@{files=$files;manifest=$record;zipHash=(Get-InstallHash $raw)}
    } finally { if($zip){$zip.Dispose()}; if($memory){$memory.Dispose()}; if($source){$source.Dispose()} }
}
function Initialize-InstallPolicy($Package) {
    # The policy bytes have already been authenticated by the independently obtained ZIP hash.
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
function Install-AmbientWorkspace([string]$PackagePath,[string]$ExpectedSha256,[string]$DestinationRoot,[switch]$SourceVerified,[string]$ExistingInstall='',[switch]$ApproveMigration) {
    if($PSVersionTable.PSEdition -ne 'Desktop' -or $ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage'){Stop-AmbientInstall 'INSTALL_POWERSHELL_REQUIRED'}
    if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){Stop-AmbientInstall 'INSTALL_STA_REQUIRED'}
    if(-not $SourceVerified){Stop-AmbientInstall 'INSTALL_SOURCE_APPROVAL_REQUIRED'}
    if($ExistingInstall -and -not $ApproveMigration){Stop-AmbientInstall 'INSTALL_MIGRATION_APPROVAL_REQUIRED'}
    Write-Host '파일 무결성 확인 중…'
    $package=Open-AmbientInstallPackage $PackagePath $ExpectedSha256
    if($package.manifest.reviewOnly){Write-Host '개발 검토용 패키지입니다. 공개 배포물로 승인된 것이 아닙니다.'}
    Initialize-InstallPolicy $package
    Assert-InstallHelper $package
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
        $lease=Enter-InstallDesktopLease
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
        Assert-AmbientInstallSecurity (Join-Path $stage 'Desktop_Companion')
        Test-InstallLaunchPrerequisites (Join-Path $stage 'Desktop_Companion')
        $aclOutput=@(& (Join-Path $PSHOME 'powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $stage 'Desktop_Companion/Test-FileSecurity.ps1'))
        if($LASTEXITCODE -ne 0){Stop-AmbientInstall 'INSTALL_FINAL_ACL'}
        Write-Host ($aclOutput -join "`n")
        Assert-InstalledProduct $stage $package
        # A completion marker is only written after all verification. Failed stages remain private.
        $name=$package.manifest.version+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8)
        $final=Join-Path $root $name
        if([IO.Directory]::Exists($final)){Stop-AmbientInstall 'INSTALL_FOLDER_EXISTS'}
        if([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($stage)) -cne $root -or [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($final)) -cne $root -or [IO.Path]::GetFileName($stage) -cnotmatch '^\.pending-[a-f0-9]{32}$'){Stop-AmbientInstall 'INSTALL_DESTINATION_INVALID'}
        [IO.Directory]::Move($stage,$final);$stage=$final
        Assert-AmbientInstallSecurity (Join-Path $final 'Desktop_Companion')
        Test-InstallLaunchPrerequisites (Join-Path $final 'Desktop_Companion')
        Assert-InstalledProduct $final $package
        Write-InstallFile (Join-Path $final 'INSTALL-COMPLETE.json') ([Text.Encoding]::UTF8.GetBytes((@{schemaVersion=1;zipSha256=$package.zipHash;authentication='NOT_TESTED';migrated=[bool]$ExistingInstall}|ConvertTo-Json -Compress)))
        $published=$true
        Write-Host '파일 무결성 검사 통과 · 설치 완료'
        return [pscustomobject]@{directory=$final;desktop=(Join-Path $final 'Desktop_Companion');extension=(Join-Path $final 'Browser_Extension');migrated=[bool]$ExistingInstall;authentication='NOT_TESTED'}
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
    & (Join-Path $PSHOME 'powershell.exe') -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $Directory 'Register-NativeHost.ps1') -Gui
    if($LASTEXITCODE -ne 0){Stop-AmbientInstall 'INSTALL_NATIVE_SETUP_FAILED'}
    return (Get-AmbientInstallerNativeState $Directory)
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
    Write-Host 'Chrome 프로필의 연결은 별도입니다. 기존 확장을 삭제하지 말고 고정 ID와 새 확장 경로를 확인한 뒤 팝업의 코드 저장 · 연결 검사 결과를 확인하세요.'
}
if($MyInvocation.InvocationName -ne '.') {
    try {
        if($Interactive -or -not $PackagePath){Invoke-AmbientInstallWizard}
        else{Install-AmbientWorkspace $PackagePath $ExpectedSha256 $DestinationRoot -SourceVerified:$SourceVerified -ExistingInstall $ExistingInstall -ApproveMigration:$ApproveMigration}
    } catch {
        $code=Get-InstallErrorCode $_
        Write-Host ('설치할 수 없음: '+$code+"`n"+(Get-InstallErrorHelp $code))
        exit 1
    }
}
