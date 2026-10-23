# Optional read-only preflight. Run from a trusted extracted distribution.
param([string]$Directory=$PSScriptRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
try {
    . (Join-Path $PSScriptRoot 'File-Security.ps1')
    Assert-AmbientInstallSecurity $Directory
    Write-Output 'PASS: local file ACL preflight. No settings, pairing, logs or permissions were changed.'
    exit 0
} catch {
    $reason='ACL_UNAVAILABLE';$cause=$_.Exception
    while ($null -ne $cause) {
        if ($cause.Data.Contains('AmbientFileSecurity')) { $reason=[string]$cause.Data['AmbientFileSecurity'];break }
        $cause=$cause.InnerException
    }
    Write-Output ('FAIL SECURITY: '+$reason+'. See docs/WINDOWS_PORTABLE_GUIDE.md. Do not run as administrator or grant Everyone access.')
    exit 1
}
