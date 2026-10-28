# Local review package only. Does not publish, sign, grant trust or read personal files.
param([Parameter(Mandatory=$true)][string]$OutputPath,[string]$SourceRoot='',[string]$Version='1.0.0-rc.2-dev',[switch]$IncludeStandaloneHelper)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Desktop'){throw 'Use Windows PowerShell 5.1.'}
if(-not $SourceRoot){$SourceRoot=Split-Path $PSScriptRoot}
. (Join-Path $PSScriptRoot '../Installer/Install-AmbientWorkspace.ps1')
Add-Type -AssemblyName System.IO.Compression
$source=[IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
$output=[IO.Path]::GetFullPath($OutputPath)
$bootstrap=$output+'.installer.ps1'
foreach($path in @($output,($output+'.sha256'),($output+'.review.json'))){if([IO.File]::Exists($path)){throw 'Review output already exists; refusing overwrite.'}}
if($IncludeStandaloneHelper){foreach($path in @($bootstrap,($bootstrap+'.sha256'))){if([IO.File]::Exists($path)){throw 'Standalone helper output exists.'}}}
if($Version -cnotmatch '^[A-Za-z0-9._-]{1,40}$'){throw 'Invalid package version'}
$paths=Get-Content -LiteralPath (Join-Path $source 'Installer/product-files.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$files=@{};$records=@()
foreach($relative in $paths) {
    if(-not (Test-InstallRelativePath $relative) -or $files.ContainsKey($relative)){throw 'Invalid/duplicate product allowlist'}
    $path=[IO.Path]::GetFullPath((Join-Path $source $relative))
    if(-not $path.StartsWith($source+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Path escaped source'}
    $ancestor=$path
    while($ancestor -and $ancestor -ne $source){if([IO.File]::GetAttributes($ancestor) -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse point in release source'};$ancestor=[IO.Path]::GetDirectoryName($ancestor)}
    $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{$files[$relative]=Read-InstallStream $stream 5242880}finally{$stream.Dispose()}
    $records+=@{path=$relative;bytes=$files[$relative].Length;sha256=(Get-InstallHash $files[$relative])}
}
Assert-InstallIdentity $files
$manifest=@{schemaVersion=1;product='AmbientWorkspace';version=$Version;extensionId=$script:InstallerId;reviewOnly=$true;archiveFileName=[IO.Path]::GetFileName($output);files=$records}
$files['INSTALL-MANIFEST.json']=[Text.Encoding]::UTF8.GetBytes(($manifest|ConvertTo-Json -Depth 6))
$stream=[IO.File]::Open($output,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try {
    $zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
    try {foreach($name in ($files.Keys|Sort-Object)){$entry=$zip.CreateEntry($name);$entryStream=$entry.Open();try{$bytes=$files[$name];$entryStream.Write($bytes,0,$bytes.Length)}finally{$entryStream.Dispose()}}} finally {$zip.Dispose()}
} finally {$stream.Dispose()}
$hash=(Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant()
$null=Open-AmbientInstallPackage $output $hash
Write-InstallFile ($output+'.sha256') ([Text.Encoding]::UTF8.GetBytes(($hash+'  '+[IO.Path]::GetFileName($output))))
$bootstrapHash=Get-InstallHash $files['Installer/Install-AmbientWorkspace.ps1']
if($IncludeStandaloneHelper){
    Write-InstallFile $bootstrap $files['Installer/Install-AmbientWorkspace.ps1']
    Write-InstallFile ($bootstrap+'.sha256') ([Text.Encoding]::UTF8.GetBytes(($bootstrapHash+'  '+[IO.Path]::GetFileName($bootstrap))))
}
$review=@{schemaVersion=1;reviewOnly=$true;version=$Version;archiveFileName=[IO.Path]::GetFileName($output);sha256=$hash;bytes=([IO.FileInfo]$output).Length;files=$records.Count+1;helperSha256=$bootstrapHash;publisherSignature='UNSIGNED';releasePublished=$false}
Write-InstallFile ($output+'.review.json') ([Text.Encoding]::UTF8.GetBytes(($review|ConvertTo-Json)))
Write-Output ('REVIEW ONLY: '+$output)
Write-Output ('SHA256: '+$hash)
Write-Output ('Bundled entry: Install.bat; helper SHA256: '+$bootstrapHash)
Write-Output 'This local hash is for review/tests, not proof of an official download or publisher signature.'
