# Chrome Native Messaging: native-endian uint32 byte count, strict UTF-8 JSON.
function Read-AmbientNativeBytes($Stream,[int]$Count,[switch]$AllowEof) {
    $bytes=New-Object byte[] $Count;$offset=0
    while($offset -lt $Count){$read=$Stream.Read($bytes,$offset,$Count-$offset);if($read -eq 0){if($AllowEof -and $offset -eq 0){return $null};throw [IO.EndOfStreamException]::new('Native message interrupted')};$offset+=$read}
    return ,$bytes
}
function Read-AmbientNativeFrame($Stream,[int]$MaximumBytes=524288) {
    $header=Read-AmbientNativeBytes $Stream 4 -AllowEof
    if($null -eq $header){return $null}
    $length=[BitConverter]::ToUInt32($header,0)
    if($length -eq 0 -or $length -gt $MaximumBytes){throw [IO.InvalidDataException]::new('Native frame size invalid')}
    $bytes=Read-AmbientNativeBytes $Stream ([int]$length)
    $text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)
    # PS 5.1 can enumerate [] into no function output, or unwrap [object].
    # Reject a non-object envelope before that conversion can resemble EOF.
    if(-not $text.TrimStart().StartsWith('{',[StringComparison]::Ordinal)){throw [IO.InvalidDataException]::new('Native envelope invalid')}
    try{$value=$text|ConvertFrom-Json}catch{throw [IO.InvalidDataException]::new('Native JSON invalid')}
    if($value -isnot [pscustomobject]){throw [IO.InvalidDataException]::new('Native envelope invalid')}
    return $value
}
function Write-AmbientNativeFrame($Stream,$Value,[int]$MaximumBytes=524288) {
    Assert-AmbientNativeJsonDepth $Value
    $bytes=[Text.UTF8Encoding]::new($false,$true).GetBytes(($Value|ConvertTo-Json -Compress -Depth 16 -WarningAction Stop))
    if($bytes.Length -eq 0 -or $bytes.Length -gt $MaximumBytes){throw [IO.InvalidDataException]::new('Native response size invalid')}
    $header=[BitConverter]::GetBytes([uint32]$bytes.Length)
    $Stream.Write($header,0,4);$Stream.Write($bytes,0,$bytes.Length);$Stream.Flush()
}
