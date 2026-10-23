function Show-AmbientNativeSetup([string]$Directory,[string]$HostName='org.ambientworkspace.bridge',[switch]$PassThru) {
    Assert-AmbientInstallSecurity $Directory
    Add-Type -AssemblyName PresentationFramework
    $reader=[Xml.XmlNodeReader]::new([xml][IO.File]::ReadAllText((Join-Path $Directory 'Native-Setup.xaml')))
    try{$window=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Close()}
    $window.MaxHeight=[Math]::Max(500,[Windows.SystemParameters]::WorkArea.Height-24)
    $window.Height=[Math]::Min($window.Height,$window.MaxHeight)
    $controls=@{};foreach($name in @('FolderText','ExtensionIdText','InstallButton','RepairButton','InspectButton','RecoverButton','RemoveButton','MigrationButton','CloseButton','StatusText')){$controls[$name]=$window.FindName($name)}
    $controls.FolderText.Text=$Directory
    $originFile=Join-Path $Directory 'native-host-origins.txt'
    if([IO.File]::Exists($originFile)){
        $known=@([IO.File]::ReadAllLines($originFile)|Where-Object{$_ -cmatch '^chrome-extension://[a-p]{32}/$'}|ForEach-Object{$_.Substring(19,32)})
        $controls.ExtensionIdText.Text=$known -join ','
    }
    $state=[pscustomobject]@{window=$window;controls=$controls;directory=$Directory;hostName=$HostName;busy=$false;lastResult=$null;lastError=''}
    $invoke={param([string]$mode)
        if($state.busy){return}
        $state.busy=$true;$state.lastError='';$state.lastResult=$null
        foreach($name in @('InstallButton','RepairButton','InspectButton','RecoverButton','RemoveButton')){$state.controls[$name].IsEnabled=$false}
        $state.controls.StatusText.Text='확인 중입니다…'
        try {
            $ids=@($state.controls.ExtensionIdText.Text.Split(',')|ForEach-Object{$_.Trim()}|Where-Object{$_})
            $journal=''
            if($mode -eq 'Recover') {
                $backup=Join-Path $state.directory 'native-registration-backups';$pending=@()
                if([IO.Directory]::Exists($backup)){
                    foreach($path in [IO.Directory]::GetFiles($backup,'*.json')){
                        $record=Read-AmbientNativeJson $path 1048576
                        if($record.phase -in @('prepared','recoveryRequired') -and $record.hostName -ceq $state.hostName){$pending+=$path}
                    }
                }
                if(-not $pending.Count){throw 'NATIVE_RECOVERY_NOT_PENDING'}
                $journal=@($pending|Sort-Object {[IO.File]::GetLastWriteTimeUtc($_)})[-1]
            }
            $result=Invoke-AmbientNativeRegistration $state.directory $mode $ids $state.hostName $journal
            $state.lastResult=$result
            $state.controls.StatusText.Text=switch($mode){
                'Inspect' {if($result.registered -and $result.binaryPresent){'등록 정보가 현재 폴더와 일치합니다. Chrome 팝업에서 실제 연결을 확인하세요.'}else{'현재 폴더에 필요한 등록 또는 host 파일이 없습니다. ID를 확인하고 등록하세요.'}}
                'Remove' {'현재 사용자 등록을 해제했습니다. 이미 열린 연결은 Chrome을 종료하면 끝납니다. 설정·키·백업은 보존했습니다.'}
                'Recover' {'이 작업이 변경한 등록·host 파일을 이전 상태로 복구했습니다. Chrome을 다시 열어 확인하세요.'}
                default {'현재 사용자 등록을 저장했습니다. Chrome 팝업에서 페어링 코드와 실제 Desktop 연결을 확인하세요.'}
            }
        }catch {
            $message=[string]$_.Exception.Message;$code=if($message -match 'NATIVE_[A-Z_]+'){$matches[0]}elseif($_.Exception.Data.Contains('AmbientFileSecurity')){'NATIVE_FILE_SECURITY'}else{'NATIVE_REGISTRATION_FAILED'}
            $state.lastError=$code
            $hint=switch($code){
                'NATIVE_EXTENSION_IDS_INVALID' {'Chrome 팝업에서 복사한 32자리 확장 ID를 확인하세요.'}
                'NATIVE_LEGACY_MIGRATION_REQUIRED' {'이전 확장 ID는 직접 등록하지 않습니다. 이전 확장 설정 준비로 백업한 뒤 고정 ID의 새 확장에서 복원하세요.'}
                'NATIVE_PATH_TOO_LONG' {'경로가 너무 깁니다. 제품을 짧은 개인 NTFS 폴더에 새로 풀고 실제 권한을 확인하세요.'}
                'NATIVE_REGISTRATION_CONFLICT' {'다른 위치의 등록을 보존했습니다. 이 폴더를 사용할 경우 재등록을 선택하세요.'}
                'NATIVE_REGISTRY_ACCESS_DENIED' {'현재 사용자 레지스트리 접근이 차단됐습니다. 조직 정책을 확인하세요. 관리자 실행으로 우회하지 않습니다.'}
                'NATIVE_REGISTRY_SECURITY' {'연결 등록을 다른 계정이 바꿀 수 있거나 권한을 확인하지 못했습니다. 기존 권한은 자동 변경하지 않습니다.'}
                'NATIVE_FILE_SECURITY' {'신뢰할 수 있는 제품을 짧은 개인 NTFS 폴더에 풀고 실제 권한 검사를 통과해야 합니다.'}
                'NATIVE_FRAMEWORK_COMPILER_UNAVAILABLE' {'이 Windows 환경에서 기본 .NET 컴파일러를 찾지 못했습니다. 임의 SDK 설치나 관리자 실행을 요구하지 않습니다.'}
                'NATIVE_HOST_BINARY_UNVERIFIED' {'기존 host 파일을 덮어쓰지 않았습니다. Chrome을 종료하고 신뢰 가능한 제품으로 재등록하세요.'}
                'NATIVE_ROLLBACK_INCOMPLETE' {'일부 복구가 끝나지 않았습니다. Chrome을 종료한 뒤 실패 이전으로 복구를 선택하세요.'}
                'NATIVE_RECOVERY_NOT_PENDING' {'복구가 필요한 준비 기록이 없습니다. 기존 설정은 그대로입니다.'}
                default {'작업을 완료하지 못했습니다. Chrome을 종료하고 파일 잠금·폴더 권한을 확인하세요. 기존 키를 삭제하지 마세요.'}
            }
            $state.controls.StatusText.Text=$hint+"`n원인 코드: "+$code
        }finally{foreach($name in @('InstallButton','RepairButton','InspectButton','RecoverButton','RemoveButton')){$state.controls[$name].IsEnabled=$true};$state.busy=$false}
    }.GetNewClosure()
    foreach($pair in @(@('InstallButton','Install'),@('RepairButton','Repair'),@('InspectButton','Inspect'),@('RecoverButton','Recover'),@('RemoveButton','Remove'))){$mode=$pair[1];$handler={&$invoke $mode}.GetNewClosure();$controls[$pair[0]].Add_Click($handler)}
    $controls.MigrationButton.Add_Click({Show-AmbientChromeMigration $state.directory}.GetNewClosure())
    $controls.CloseButton.Add_Click({$state.window.Close()}.GetNewClosure())
    if($PassThru){return $state}
    [void]$window.ShowDialog()
}
