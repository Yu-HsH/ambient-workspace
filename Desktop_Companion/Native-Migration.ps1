function Show-AmbientChromeMigration([string]$Directory,[switch]$PassThru) {
    Assert-AmbientInstallSecurity $Directory
    Add-Type -AssemblyName PresentationFramework,System.Windows.Forms
    $reader=[Xml.XmlNodeReader]::new([xml][IO.File]::ReadAllText((Join-Path $Directory 'Native-Migration.xaml')))
    try{$window=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Close()}
    $window.MaxHeight=[Math]::Max(500,[Windows.SystemParameters]::WorkArea.Height-24);$window.Height=[Math]::Min($window.Height,$window.MaxHeight)
    $controls=@{};foreach($name in @('SourceProfileText','OldExtensionIdText','HelperFolderText','BrowseProfileButton','PrepareMigrationButton','ResumeMigrationButton','CopyHelperButton','OpenHelperChromeButton','CompleteMigrationButton','RemoveMigrationButton','CloseMigrationButton','MigrationStatusText')){$controls[$name]=$window.FindName($name)}
    $state=[pscustomobject]@{window=$window;controls=$controls;directory=$Directory;migration=$null;lastResult=$null;lastError='';busy=$false}
    $run={param([string]$Action)
        if($state.busy){return};$state.busy=$true;$state.lastError='';$state.lastResult=$null
        try{
            switch($Action){
                'Browse' {
                    $dialog=[Windows.Forms.FolderBrowserDialog]::new();$dialog.Description='기존 Chrome의 프로필 폴더를 선택하세요 (Default 또는 Profile 1 등).';$dialog.ShowNewFolderButton=$false
                    try{if($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK){$state.controls.SourceProfileText.Text=$dialog.SelectedPath}}finally{$dialog.Dispose()}
                }
                'Prepare' {
                    if($null -ne $state.migration){throw 'NATIVE_MIGRATION_ALREADY_PREPARED'}
                    $state.migration=Prepare-AmbientChromeProfileMigration $state.directory $state.controls.SourceProfileText.Text.Trim() $state.controls.OldExtensionIdText.Text.Trim()
                    $state.controls.HelperFolderText.Text=$state.migration.helperExtension
                    $state.controls.MigrationStatusText.Text='개인 복사본과 임시 연결 등록을 준비했습니다. 도우미 폴더를 복사하고 별도 Chrome에서 로드하세요. 창을 닫아도 준비 기록과 원본은 보존됩니다.'
                    $state.lastResult=@{prepared=$true;sourceUnchanged=$true}
                }
                'Resume' {
                    $dialog=[Windows.Forms.OpenFileDialog]::new();$dialog.Title='이전 준비 폴더의 migration.json 선택';$dialog.Filter='이전 준비 기록 (migration.json)|migration.json'
                    try{
                        if($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK){
                            $record=Read-AmbientNativeJson $dialog.FileName 32768
                            $state.migration=Get-AmbientChromeMigrationMarker $record
                            if($state.migration.productDirectory -cne [IO.Path]::GetFullPath($state.directory)){throw 'NATIVE_MIGRATION_PRODUCT_MISMATCH'}
                            $state.controls.HelperFolderText.Text=$state.migration.helperExtension;$state.controls.MigrationStatusText.Text='보존된 준비 기록을 열었습니다. 도우미 저장 또는 백업 확인을 계속하세요.'
                        }
                    }finally{$dialog.Dispose()}
                }
                'Copy' {if($null -eq $state.migration){throw 'NATIVE_MIGRATION_NOT_PREPARED'};[Windows.Clipboard]::SetText($state.migration.helperExtension);$state.controls.MigrationStatusText.Text='공개 도우미 폴더 경로를 복사했습니다. 페어링 값은 클립보드에 복사하지 않습니다.'}
                'Open' {
                    if($null -eq $state.migration){throw 'NATIVE_MIGRATION_NOT_PREPARED'}
                    $record=Get-AmbientChromeMigrationMarker $state.migration
                    $chrome=Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Google/Chrome/Application/chrome.exe'
                    if(-not [IO.File]::Exists($chrome)){$chrome=Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'Google/Chrome/Application/chrome.exe'}
                    if(-not [IO.File]::Exists($chrome)){throw 'NATIVE_CHROME_NOT_FOUND'}
                    # Interactive browser requested by this button. No debugging port,
                    # automation pipe, unsupported --load-extension or original profile.
                    $arguments='--user-data-dir="'+$record.browserData+'" --no-first-run --no-default-browser-check chrome://extensions'
                    [void](Start-Process -FilePath $chrome -ArgumentList $arguments -PassThru)
                    $state.controls.MigrationStatusText.Text='별도 Chrome에서 개발자 모드를 켜고 복사한 도우미 폴더를 로드하세요. 도우미 저장 완료 후 이 창에서 백업 확인을 누르세요.'
                }
                'Complete' {
                    if($null -eq $state.migration){throw 'NATIVE_MIGRATION_NOT_PREPARED'}
                    $state.lastResult=Complete-AmbientChromeProfileMigration $state.migration
                    $state.controls.MigrationStatusText.Text='개인 백업을 검증해 제품 폴더에 보존했고 임시 등록을 해제했습니다. 새 확장의 Windows 연결 → 백업 목록 읽기에서 선택해 복원하세요. 원본은 그대로입니다.'
                }
                'Remove' {
                    if($null -eq $state.migration){throw 'NATIVE_MIGRATION_NOT_PREPARED'}
                    $state.lastResult=Remove-AmbientChromeMigrationRegistration $state.migration
                    $state.controls.MigrationStatusText.Text='이 준비 작업의 임시 등록만 해제했습니다. 원본·복사본·백업은 보존했습니다. 도우미의 열린 연결은 별도 Chrome을 종료하면 끝납니다.'
                }
            }
        }catch{
            $message=[string]$_.Exception.Message;$code=if($message -match 'NATIVE_[A-Z_]+'){$matches[0]}elseif($_.Exception -is [IO.PathTooLongException]){'NATIVE_PATH_TOO_LONG'}elseif($_.Exception.Data.Contains('AmbientFileSecurity')){'NATIVE_FILE_SECURITY'}else{'NATIVE_MIGRATION_FAILED'}
            $state.lastError=$code
            $hint=switch($code){
                'NATIVE_CHROME_MUST_BE_CLOSED' {'기존 Chrome이 이 확장 데이터를 사용 중입니다. Chrome을 모두 종료한 뒤 복사본 준비를 다시 누르세요.'}
                'NATIVE_MIGRATION_NOT_COMPLETE' {'도우미가 개인 백업을 저장한 것을 확인하지 못했습니다. 임시 등록과 폴더 권한을 확인하고 도우미에서 다시 저장하세요.'}
                'NATIVE_MIGRATION_ALREADY_PREPARED' {'이미 준비했습니다. 현재 도우미로 계속하거나 창을 닫은 뒤 준비 기록을 여세요.'}
                'NATIVE_PATH_TOO_LONG' {'경로가 너무 깁니다. 신뢰 가능한 제품을 짧은 개인 NTFS 폴더에 새로 풀어 권한을 검증하세요. 원본은 삭제하지 마세요.'}
                'NATIVE_FILE_SECURITY' {'개인 폴더 또는 원본 프로필의 실제 권한 검증에 실패했습니다. 모든 사용자 허용이나 관리자 실행으로 우회하지 마세요.'}
                'NATIVE_EXTENSION_IDS_INVALID' {'예전 확장 ID 32자리를 확인하세요.'}
                default {'이전 작업을 완료하지 못했습니다. 원본·준비 기록을 보존하고 프로필 경로, 파일 잠금, 권한을 확인하세요.'}
            }
            $state.controls.MigrationStatusText.Text=$hint+"`n원인 코드: "+$code
        }finally{$state.busy=$false}
    }.GetNewClosure()
    foreach($pair in @(@('BrowseProfileButton','Browse'),@('PrepareMigrationButton','Prepare'),@('ResumeMigrationButton','Resume'),@('CopyHelperButton','Copy'),@('OpenHelperChromeButton','Open'),@('CompleteMigrationButton','Complete'),@('RemoveMigrationButton','Remove'))){$action=$pair[1];$handler={&$run $action}.GetNewClosure();$controls[$pair[0]].Add_Click($handler)}
    $controls.CloseMigrationButton.Add_Click({$state.window.Close()}.GetNewClosure())
    if($PassThru){return $state};[void]$window.ShowDialog()
}
