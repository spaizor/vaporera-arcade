# =====================================================================
#  Vdf.ps1 - Lector / escritor de VDF binario (shortcuts.vdf de Steam)
#  Parte de Vaporera Arcade
# =====================================================================
#  Formato: secuencia de entradas dentro de mapas.
#    0x00 <clave> 0x00 ...entradas... 0x08   -> mapa anidado
#    0x01 <clave> 0x00 <valor> 0x00          -> cadena UTF-8
#    0x02 <clave> 0x00 <int32 LE>            -> entero
#    0x08                                    -> fin de mapa
#  El documento entero es un mapa; tras cerrarlo hay un 0x08 extra.
# =====================================================================

function Read-VdfString {
    param([System.IO.BinaryReader]$Reader)
    $bytes = New-Object System.Collections.Generic.List[byte]
    while ($true) {
        $b = $Reader.ReadByte()
        if ($b -eq 0) { break }
        [void]$bytes.Add($b)
    }
    return [System.Text.Encoding]::UTF8.GetString($bytes.ToArray())
}

function Read-VdfMap {
    param([System.IO.BinaryReader]$Reader)
    $map = [ordered]@{}
    while ($Reader.BaseStream.Position -lt $Reader.BaseStream.Length) {
        $type = $Reader.ReadByte()
        if ($type -eq 8) { break }
        $key = Read-VdfString -Reader $Reader
        switch ($type) {
            0 { $map[$key] = Read-VdfMap -Reader $Reader }
            1 { $map[$key] = Read-VdfString -Reader $Reader }
            2 { $map[$key] = $Reader.ReadInt32() }
            3 { $map[$key] = $Reader.ReadSingle() }
            7 { $map[$key] = $Reader.ReadUInt64() }
            default { throw "Tipo VDF desconocido 0x$('{0:x2}' -f $type) en offset $($Reader.BaseStream.Position)" }
        }
    }
    return $map
}

function Read-BinaryVdf {
    param([Parameter(Mandatory)][string]$Path)
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $br = New-Object System.IO.BinaryReader($fs)
        $root = Read-VdfMap -Reader $br
    } finally { $fs.Dispose() }
    return $root
}

function Write-VdfString {
    param([System.IO.BinaryWriter]$Writer, [string]$Value)
    if ($null -eq $Value) { $Value = '' }
    $b = [System.Text.Encoding]::UTF8.GetBytes($Value)
    if ($b.Length -gt 0) { $Writer.Write($b, 0, $b.Length) }
    $Writer.Write([byte]0)
}

function Write-VdfMap {
    param([System.IO.BinaryWriter]$Writer, $Map)
    foreach ($key in @($Map.Keys)) {
        $value = $Map[$key]
        if ($value -is [System.Collections.IDictionary]) {
            $Writer.Write([byte]0); Write-VdfString -Writer $Writer -Value $key
            Write-VdfMap -Writer $Writer -Map $value
            $Writer.Write([byte]8)
        }
        elseif ($value -is [int] -or $value -is [uint32]) {
            $Writer.Write([byte]2); Write-VdfString -Writer $Writer -Value $key
            if ($value -is [uint32]) { $Writer.Write([System.BitConverter]::GetBytes([uint32]$value), 0, 4) }
            else { $Writer.Write([int]$value) }
        }
        elseif ($value -is [uint64]) {
            $Writer.Write([byte]7); Write-VdfString -Writer $Writer -Value $key
            $Writer.Write([uint64]$value)
        }
        elseif ($value -is [single]) {
            $Writer.Write([byte]3); Write-VdfString -Writer $Writer -Value $key
            $Writer.Write([single]$value)
        }
        else {
            $Writer.Write([byte]1); Write-VdfString -Writer $Writer -Value $key
            Write-VdfString -Writer $Writer -Value ([string]$value)
        }
    }
}

# Escribe el VDF sin tocar el original hasta el final. Escribir encima con WriteAllBytes deja
# el fichero truncado si algo falla a medias (disco lleno, antivirus, apagon), y el usuario
# pierde TODOS sus accesos directos ajenos a Steam. Aqui se escribe al lado y se cambia de
# sitio al final: File::Replace es indivisible y conserva los permisos del fichero original.
# Solo con rutas absolutas (las de Get-SteamInfo): .NET no usa el directorio actual de PS.
function Write-BinaryVdf {
    param([Parameter(Mandatory)]$Root, [Parameter(Mandatory)][string]$Path)
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    try {
        Write-VdfMap -Writer $bw -Map $Root
        $bw.Write([byte]8)      # cierre del documento
        $bw.Flush()
        $bytes = $ms.ToArray()
    } finally { $bw.Dispose(); $ms.Dispose() }

    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllBytes($tmp, $bytes)
    if (Test-Path -LiteralPath $Path) {
        # si Replace no puede (sistema de ficheros raro, permisos), al menos los bytes buenos
        # ya estan en disco: el renombrado a pelo deja una ventana minuscula, no un truncado
        try { [System.IO.File]::Replace($tmp, $Path, $null) }
        catch { Move-Item -LiteralPath $tmp -Destination $Path -Force }
    } else {
        Move-Item -LiteralPath $tmp -Destination $Path
    }
}

# ---------------------------------------------------------------------
#  AppId de un acceso directo: CRC32(exe_entrecomillado + nombre) | 0x80000000
#  En PS 5.1 hay que trabajar en UInt64 y enmascarar (0xFFFFFFFF se lee
#  como Int32 = -1).
# ---------------------------------------------------------------------
$script:Crc32Table = $null

# OJO PS 5.1: toda la aritmetica va en UInt64 con mascara de 32 bits.
# 0xFFFFFFFF se interpreta como Int32 (-1) y revienta el cast a UInt32.
$script:Crc32Mask = [uint64]4294967295      # 0xFFFFFFFF
$script:Crc32Poly = [uint64]3988292384      # 0xEDB88320

function Get-Crc32Table {
    if ($null -ne $script:Crc32Table) { return $script:Crc32Table }
    $mask = $script:Crc32Mask
    $table = New-Object 'uint64[]' 256
    for ($i = 0; $i -lt 256; $i++) {
        $c = [uint64]$i
        for ($k = 0; $k -lt 8; $k++) {
            if (($c -band [uint64]1) -ne 0) { $c = ($script:Crc32Poly -bxor ($c -shr 1)) -band $mask }
            else                            { $c = ($c -shr 1) -band $mask }
        }
        $table[$i] = $c
    }
    $script:Crc32Table = $table
    return ,$table
}

function Get-Crc32 {
    param([byte[]]$Bytes)
    $table = Get-Crc32Table
    $mask = $script:Crc32Mask
    $crc = $mask
    foreach ($b in $Bytes) {
        $idx = [int](($crc -bxor [uint64]$b) -band [uint64]255)
        $crc = ($table[$idx] -bxor ($crc -shr 8)) -band $mask
    }
    return [uint64](($crc -bxor $mask) -band $mask)
}

function Get-SteamShortcutAppId {
    param([Parameter(Mandatory)][string]$ExeQuoted, [Parameter(Mandatory)][string]$AppName)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($ExeQuoted + $AppName)
    $crc = Get-Crc32 -Bytes $bytes
    return [uint32]($crc -bor [uint64]2147483648)   # 0x80000000
}

# El campo "appid" del vdf guarda ese mismo numero como Int32 con signo.
function ConvertTo-VdfAppId {
    param([uint32]$AppId)
    return [System.BitConverter]::ToInt32([System.BitConverter]::GetBytes([uint32]$AppId), 0)
}
