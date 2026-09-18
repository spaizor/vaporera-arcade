# =====================================================================
#  SteamCtl.ps1 - Localizar Steam, cerrarlo/abrirlo y escribir shortcuts.vdf
# =====================================================================

function Get-SteamInfo {
    $k = Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue
    $dir = $null
    if ($k -and $k.SteamPath) { $dir = ($k.SteamPath -replace '/','\') }
    if (-not $dir -or -not (Test-Path -LiteralPath $dir)) {
        foreach ($c in @((Join-Path ${env:ProgramFiles(x86)} 'Steam'), (Join-Path $env:ProgramFiles 'Steam'))) {
            if (Test-Path -LiteralPath $c) { $dir = $c; break }
        }
    }
    if (-not $dir) { return $null }

    $exe = Join-Path $dir 'steam.exe'
    $userdata = Join-Path $dir 'userdata'
    $perfiles = @()
    if (Test-Path -LiteralPath $userdata) {
        $perfiles = Get-ChildItem -LiteralPath $userdata -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match '^\d+$' -and $_.Name -ne '0' }
    }
    # si hay varios perfiles nos quedamos con el de config mas reciente
    $perfil = $perfiles | Sort-Object {
        $c = Join-Path $_.FullName 'config\localconfig.vdf'
        if (Test-Path -LiteralPath $c) { (Get-Item -LiteralPath $c).LastWriteTime } else { [datetime]::MinValue }
    } -Descending | Select-Object -First 1
    if (-not $perfil) { return $null }

    $config = Join-Path $perfil.FullName 'config'
    [pscustomobject]@{
        Dir       = $dir
        Exe       = $exe
        UserId    = $perfil.Name
        ConfigDir = $config
        Shortcuts = Join-Path $config 'shortcuts.vdf'
        GridDir   = Join-Path $config 'grid'
    }
}

function Test-SteamCorriendo { return [bool](Get-Process steam -ErrorAction SilentlyContinue) }

function Stop-SteamYEsperar {
    param([string]$SteamExe, [int]$SegundosMax = 40, [scriptblock]$Log = $null)
    function Registrar($m) { if ($Log) { & $Log $m | Out-Null } }
    if (-not (Test-SteamCorriendo)) { Registrar 'Steam no estaba abierto.'; return $true }
    Registrar 'Cerrando Steam (steam.exe -shutdown)...'
    try { Start-Process -FilePath $SteamExe -ArgumentList '-shutdown' -WindowStyle Hidden } catch { }
    $t = 0
    while ((Test-SteamCorriendo) -and $t -lt $SegundosMax) { Start-Sleep -Seconds 1; $t++ }
    if (Test-SteamCorriendo) { Registrar "Steam sigue abierto tras $SegundosMax s."; return $false }
    Start-Sleep -Milliseconds 800      # margen para que suelte el fichero
    Registrar "Steam cerrado en $t s."
    return $true
}

function Start-Steam {
    param([string]$SteamExe, [switch]$BigPicture, [scriptblock]$Log = $null)
    function Registrar($m) { if ($Log) { & $Log $m | Out-Null } }
    Registrar ('Abriendo Steam' + $(if ($BigPicture) { ' en Big Picture' } else { '' }) + '...')
    if ($BigPicture) { Start-Process -FilePath $SteamExe -ArgumentList '-bigpicture' }
    else             { Start-Process -FilePath $SteamExe }
}

# Se crea una copia por cada escritura: sin podar, config\ acaba llena de .bak-*
function Remove-BackupsViejos {
    param([string]$Ruta, [int]$Conservar = 10, [scriptblock]$Log = $null)
    $dir    = Split-Path $Ruta -Parent
    $nombre = Split-Path $Ruta -Leaf
    try {
        # se ordena por nombre, no por fecha: Copy-Item conserva la del fichero original
        $viejos = @(Get-ChildItem -LiteralPath $dir -Filter "$nombre.bak-*" -File -ErrorAction Stop |
                    Sort-Object Name -Descending | Select-Object -Skip $Conservar)
        foreach ($f in $viejos) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
        if ($viejos.Count -and $Log) {
            & $Log "Copias de seguridad antiguas borradas: $($viejos.Count) (se conservan las $Conservar últimas)." | Out-Null
        }
    } catch { }
}

function Backup-Shortcuts {
    param([string]$Ruta, [int]$Conservar = 10, [scriptblock]$Log = $null)
    if (-not (Test-Path -LiteralPath $Ruta)) { return $null }
    $bak = "$Ruta.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item -LiteralPath $Ruta -Destination $bak -Force
    Remove-BackupsViejos -Ruta $Ruta -Conservar $Conservar -Log $Log
    return $bak
}

# ---------------------------------------------------------------------
#  Entrada nueva en shortcuts.vdf, con la misma forma que las que ya hay
# ---------------------------------------------------------------------
function New-EntradaShortcut {
    param(
        [uint32]$AppId, [string]$Nombre, [string]$Exe, [string]$StartDir,
        [string]$Icono = '', [string]$LaunchOptions = ''
    )
    $e = [ordered]@{}
    $e['appid']               = ConvertTo-VdfAppId -AppId $AppId
    $e['AppName']             = $Nombre
    $e['Exe']                 = '"' + $Exe + '"'
    $e['StartDir']            = '"' + $StartDir + '"'
    $e['icon']                = $Icono
    $e['ShortcutPath']        = ''
    $e['LaunchOptions']       = $LaunchOptions
    $e['IsHidden']            = [int]0
    $e['AllowDesktopConfig']  = [int]1
    $e['AllowOverlay']        = [int]1
    $e['OpenVR']              = [int]0
    $e['Devkit']              = [int]0
    $e['DevkitGameID']        = ''
    $e['DevkitOverrideAppID'] = [int]0
    $e['LastPlayTime']        = [int]0
    $e['FlatpakAppID']        = ''
    $e['sortas']              = ''
    $tags = [ordered]@{}
    $tags['0'] = 'Installed locally'
    $e['tags'] = $tags
    return $e
}

# El nodo 'shortcuts' del VDF en objetos comparables
function ConvertTo-ShortcutInfo {
    param($Shortcuts)
    $lista = @()
    if (-not $Shortcuts) { return $lista }
    foreach ($k in @($Shortcuts.Keys)) {
        $e = $Shortcuts[$k]
        $lista += [pscustomobject]@{
            Indice = $k
            Nombre = [string]$e['AppName']
            Exe    = ([string]$e['Exe']).Trim('"')
            AppId  = [uint32][System.BitConverter]::ToUInt32([System.BitConverter]::GetBytes([int]$e['appid']), 0)
            LaunchOptions = [string]$e['LaunchOptions']
        }
    }
    return $lista
}

function Get-ShortcutsExistentes {
    param([string]$Ruta)
    if (-not (Test-Path -LiteralPath $Ruta)) { return @() }
    $root = Read-BinaryVdf -Path $Ruta
    return (ConvertTo-ShortcutInfo -Shortcuts $root['shortcuts'])
}

# UNICO criterio de duplicado de la aplicacion: mismo nombre, o el mismo exe con las mismas
# opciones. Lo usan la marca 'YA EN STEAM' de la lista y la escritura del VDF, que antes
# miraban cosas distintas (la lista solo el nombre) y se contradecian.
# Devuelve la clave de la entrada que choca, o $null.
function Find-ShortcutDuplicado {
    param($Existentes, [string]$Nombre, [string]$Exe, [string]$LaunchOptions = '')
    foreach ($e in @($Existentes)) {
        if (-not $e) { continue }
        $mismoNombre = ([string]$e.Nombre) -eq $Nombre
        $mismoExe    = (([string]$e.Exe) -eq $Exe) -and (([string]$e.LaunchOptions) -eq $LaunchOptions)
        if ($mismoNombre -or $mismoExe) { return $e.Indice }
    }
    return $null
}

# Lo mismo leyendo shortcuts.vdf. Es seguro con Steam abierto: solo lee.
function Test-ShortcutDuplicado {
    param([Parameter(Mandatory)][string]$RutaVdf, [string]$Nombre, [string]$Exe, [string]$LaunchOptions = '')
    return (Find-ShortcutDuplicado -Existentes (Get-ShortcutsExistentes -Ruta $RutaVdf) `
                -Nombre $Nombre -Exe $Exe -LaunchOptions $LaunchOptions)
}

# ---------------------------------------------------------------------
#  Anade (o reemplaza) un acceso directo. Steam DEBE estar cerrado.
# ---------------------------------------------------------------------
function Add-SteamShortcut {
    param(
        [Parameter(Mandatory)][string]$RutaVdf,
        [Parameter(Mandatory)][string]$Nombre,
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string]$StartDir,
        [string]$Icono = '', [string]$LaunchOptions = '',
        [switch]$Reemplazar,
        [scriptblock]$Log = $null
    )
    function Registrar($m) { if ($Log) { & $Log $m | Out-Null } }

    $appId = Get-SteamShortcutAppId -ExeQuoted ('"' + $Exe + '"') -AppName $Nombre

    if (Test-Path -LiteralPath $RutaVdf) { $root = Read-BinaryVdf -Path $RutaVdf }
    else { $root = [ordered]@{}; $root['shortcuts'] = [ordered]@{} }
    if (-not $root['shortcuts']) { $root['shortcuts'] = [ordered]@{} }
    $sc = $root['shortcuts']

    $existente = Find-ShortcutDuplicado -Existentes (ConvertTo-ShortcutInfo -Shortcuts $sc) `
                    -Nombre $Nombre -Exe $Exe -LaunchOptions $LaunchOptions
    if ($existente -ne $null -and -not $Reemplazar) {
        return [pscustomobject]@{ Ok = $false; Motivo = 'duplicado'; Indice = $existente; AppId = $appId }
    }

    $entrada = New-EntradaShortcut -AppId $appId -Nombre $Nombre -Exe $Exe -StartDir $StartDir -Icono $Icono -LaunchOptions $LaunchOptions

    if ($existente -ne $null) {
        $sc[$existente] = $entrada
        Registrar "Reemplazada la entrada $existente."
    } else {
        $siguiente = 0
        foreach ($k in @($sc.Keys)) { $n = 0; if ([int]::TryParse($k, [ref]$n) -and $n -ge $siguiente) { $siguiente = $n + 1 } }
        $sc["$siguiente"] = $entrada
        Registrar "Añadida como entrada $siguiente."
    }

    Write-BinaryVdf -Root $root -Path $RutaVdf
    return [pscustomobject]@{ Ok = $true; Motivo = ''; Indice = $existente; AppId = $appId }
}

function Remove-SteamShortcut {
    param([Parameter(Mandatory)][string]$RutaVdf, [Parameter(Mandatory)][string]$Nombre)
    if (-not (Test-Path -LiteralPath $RutaVdf)) { return $false }
    $root = Read-BinaryVdf -Path $RutaVdf
    $sc = $root['shortcuts']
    if (-not $sc) { return $false }
    $nuevo = [ordered]@{}
    $i = 0; $borrado = $false
    foreach ($k in @($sc.Keys)) {
        if (([string]$sc[$k]['AppName']) -eq $Nombre) { $borrado = $true; continue }
        $nuevo["$i"] = $sc[$k]; $i++
    }
    if ($borrado) { $root['shortcuts'] = $nuevo; Write-BinaryVdf -Root $root -Path $RutaVdf }
    return $borrado
}
