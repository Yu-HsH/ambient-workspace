param([ValidateSet('Install','Repair','Remove','Inspect','Recover')][string]$Action='Install',[string[]]$ExtensionId=@(),[string]$HostName='org.ambientworkspace.bridge',[string]$RecoveryJournal='',[switch]$Gui)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);$OutputEncoding=[Console]::OutputEncoding
try {
    . (Join-Path $PSScriptRoot 'File-Security.ps1')
    Assert-AmbientInstallSecurity $PSScriptRoot
    foreach($name in @('Control-Channel.ps1','Native-Mailbox.ps1','Native-Registration.ps1','Native-Profiles.ps1')){. (Join-Path $PSScriptRoot $name)}
    if($Gui){foreach($name in @('Chrome-Profile-Migration.ps1','Native-Migration.ps1','Native-Setup.ps1')){. (Join-Path $PSScriptRoot $name)};Show-AmbientNativeSetup $PSScriptRoot $HostName;exit 0}
    $ExtensionId=@($ExtensionId|ForEach-Object{$_.Split(',')}|ForEach-Object{$_.Trim()}|Where-Object{$_})
    $result=Invoke-AmbientNativeRegistration $PSScriptRoot $Action $ExtensionId $HostName $RecoveryJournal
    $result|ConvertTo-Json -Compress -Depth 5
}catch {
    $message=[string]$_.Exception.Message
    $code=if($message -match 'NATIVE_[A-Z_]+'){$matches[0]}elseif($_.Exception.Data.Contains('AmbientFileSecurity')){'NATIVE_FILE_SECURITY'}else{'NATIVE_REGISTRATION_FAILED'}
    if($Gui){Add-Type -AssemblyName PresentationFramework;[void][Windows.MessageBox]::Show(('Chrome 연결 등록을 시작하지 못했습니다. 개인 폴더와 파일 권한을 확인하세요.'+"`n"+$code),'Ambient Workspace')}
    else{Write-Error ('Native host task failed: '+$code)}
    exit 1
}
