# Read-only local installation boundary. Never repairs ACLs or reads file contents.
function Stop-AmbientFileSecurity([string]$Reason,[bool]$ObjectGone=$false) {
    $failure=[UnauthorizedAccessException]::new('SECURITY '+$Reason)
    $failure.Data['AmbientFileSecurity']=$Reason
    $failure.Data['AmbientAclObjectGone']=$ObjectGone
    throw $failure
}
function Test-AmbientPathAcl([string]$Path,[ValidateSet('Private','Product','Ancestor')][string]$Scope='Private') {
    try {
        if ([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::ReparsePoint) { Stop-AmbientFileSecurity 'REPARSE' }
        # Use the Windows .NET ACL API directly. Module auto-loading can differ
        # when Windows PowerShell is spawned through Node/PowerShell 7.
        $sections=[Security.AccessControl.AccessControlSections]::Access -bor [Security.AccessControl.AccessControlSections]::Owner
        $acl=if ([IO.Directory]::Exists($Path)) { [IO.Directory]::GetAccessControl($Path,$sections) } else { [IO.File]::GetAccessControl($Path,$sections) }
        if (-not $acl.AreAccessRulesCanonical) { Stop-AmbientFileSecurity 'ACL_UNKNOWN' }
        $current=[Security.Principal.WindowsIdentity]::GetCurrent()
        try { $userSid=$current.User.Value } finally { $current.Dispose() }
        $trusted=@($userSid,'S-1-5-18','S-1-5-32-544',
            'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
        if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trusted) { Stop-AmbientFileSecurity 'OWNER' }
        $raw=[Security.AccessControl.RawSecurityDescriptor]::new($acl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access))
        if ($null -eq $raw.DiscretionaryAcl) { Stop-AmbientFileSecurity 'ACL_UNKNOWN' }
        # Masks include generic rights. Ancestor creation alone does not allow
        # replacing an existing protected child; DELETE/DELETE_CHILD/DAC/OWNER do.
        $writeMask=[long]0x500D0156
        $ancestorMask=[long]0x500D0040
        $privateMask=[long]0xD00D0157
        $mask=switch ($Scope) { 'Private' {$privateMask}; 'Product' {$writeMask}; 'Ancestor' {$ancestorMask} }
        foreach ($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
            if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or $rule.IdentityReference.Value -in $trusted) { continue }
            $inheritOnly=($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0
            if ($Scope -eq 'Ancestor' -and $inheritOnly) { continue }
            # CREATOR OWNER is replaced by the creator SID on child inheritance.
            if ($inheritOnly -and $rule.IdentityReference.Value -eq 'S-1-3-0') { continue }
            $rights=([long]$rule.FileSystemRights -band [long]4294967295)
            if ($rights -band $mask) { Stop-AmbientFileSecurity $(if($Scope -eq 'Private'){'DATA_ACL'}else{'PRODUCT_ACL'}) }
        }
    } catch {
        if ($_.Exception.Data.Contains('AmbientFileSecurity')) { throw }
        $cause=$_.Exception
        while ($null -ne $cause.InnerException) { $cause=$cause.InnerException }
        Stop-AmbientFileSecurity 'ACL_UNAVAILABLE' ($cause -is [IO.FileNotFoundException])
    }
}
function Assert-AmbientInstallSecurity([string]$Directory,[string]$ConfigPath='') {
    try {
        $root=[IO.Path]::GetFullPath($Directory).TrimEnd('\')
        if ($root.StartsWith('\\')) { Stop-AmbientFileSecurity 'LOCAL_VOLUME' }
        $drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($root))
        if ($drive.DriveType -ne [IO.DriveType]::Fixed -or $drive.DriveFormat -notin @('NTFS','ReFS')) { Stop-AmbientFileSecurity 'LOCAL_VOLUME' }
        # Explicit stack: inspect junctions before enumerating their children.
        $pending=[Collections.Generic.Stack[string]]::new(); $pending.Push($root)
        while ($pending.Count) {
            $path=$pending.Pop()
            try { Test-AmbientPathAcl $path 'Private' } catch {
                # A listed atomic-write temporary may be renamed/deleted before
                # metadata is opened. It is no longer an input. Only an actual
                # FileNotFound from this optional child may be skipped; root,
                # access denied, unknown ACL and extant unsafe ACEs still fail.
                if ($path -ne $root -and $_.Exception.Data['AmbientAclObjectGone'] -eq $true) { continue }
                throw
            }
            if ([IO.Directory]::Exists($path)) {
                foreach ($child in [IO.Directory]::GetFileSystemEntries($path)) { $pending.Push($child) }
            }
        }
        $parent=[IO.Directory]::GetParent($root)
        while ($null -ne $parent) { Test-AmbientPathAcl $parent.FullName 'Ancestor'; $parent=$parent.Parent }
        # Extension sources are public code, but another account must not modify
        # the loaded extension and obtain its paired trusted-context privileges.
        $extension=Join-Path (Split-Path $root) 'Browser_Extension'
        if ([IO.Directory]::Exists($extension)) {
            $pending.Push($extension)
            while ($pending.Count) {
                $path=$pending.Pop(); Test-AmbientPathAcl $path 'Product'
                if ([IO.Directory]::Exists($path)) {
                    foreach ($child in [IO.Directory]::GetFileSystemEntries($path)) { $pending.Push($child) }
                }
            }
        }
        if ($ConfigPath) {
            $config=[IO.Path]::GetFullPath($ConfigPath)
            if (-not $config.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)) {
                Assert-AmbientInstallSecurity ([IO.Path]::GetDirectoryName($config))
            }
        }
    } catch {
        if ($_.Exception.Data.Contains('AmbientFileSecurity')) { throw }
        Stop-AmbientFileSecurity 'ACL_UNAVAILABLE'
    }
}
