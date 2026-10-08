# =====================================================================
#  SteamCtl.ps1 - Localizar Steam, cerrarlo/abrirlo y escribir shortcuts.vdf
# =====================================================================

# Por que Get-SteamInfo devuelve $null. "No encuentro Steam" a secas confunde cuando el
# problema es que esta instalado pero sin ninguna sesion iniciada, que es lo que pasa en un
# PC recien montado.
$script:SteamMotivo = ''
function Get-SteamMotivo {
    if ($script:SteamMotivo) { return $script:SteamMotivo }
    return 'No encuentro la instalación de Steam.'
}

# El ultimo que inicio sesion, segun loginusers.vdf. Las versiones nuevas de Steam ya no
# escriben MostRecent (comprobado en la 2026): hay que caer al Timestamp mas alto.
# El nombre de la carpeta de userdata es el id de cuenta de 32 bits, no el SteamID64.
function Get-SteamCuentaDeLoginUsers {
    param([string]$Ruta)
    if (-not (Test-Path -LiteralPath $Ruta)) { return $null }
    try {
        $txt = Get-Content -LiteralPath $Ruta -Raw -Encoding UTF8
        $re  = [regex]'"(7656\d{13})"\s*\{(?:[^{}]|\{[^{}]*\})*?\}'
        $mejor = $null; $mejorSello = [int64]-1
        foreach ($m in $re.Matches($txt)) {
            $cuenta = [string]([uint64]$m.Groups[1].Value - 76561197960265728)
            if ($m.Value -match '"MostRecent"\s*"1"') { return $cuenta }
            $sello = [int64]0
            if ($m.Value -match '"Timestamp"\s*"(\d+)"') { $sello = [int64]$matches[1] }
            if ($sello -gt $mejorSello) { $mejorSello = $sello; $mejor = $cuenta }
        }
        return $mejor
    } catch { return $null }
}

# El identificador de cuenta del usuario que de verdad esta usando Steam en este PC. Antes se
# cogia el perfil con el localconfig.vdf mas reciente, que con dos cuentas puede ser la
# equivocada y anadir los juegos a la de otro.
function Get-SteamCuentaActiva {
    param([string]$Dir)
    # 1) sesion iniciada ahora mismo. Es un DWORD: en PS 5.1 llega como Int32 y una cuenta
    #    por encima de 2^31 saldria negativa, de ahi el rodeo por los bytes.
    try {
        $ap = Get-ItemProperty 'HKCU:\Software\Valve\Steam\ActiveProcess' -ErrorAction Stop
        if ($null -ne $ap.ActiveUser) {
            $id = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$ap.ActiveUser), 0)
            if ($id -ne 0) { return [string]$id }
        }
    } catch { }
    # 2) el ultimo que inicio sesion
    return (Get-SteamCuentaDeLoginUsers -Ruta (Join-Path $Dir 'config\loginusers.vdf'))
}

# -RutaSteam salta la busqueda en el registro. Solo lo usan las pruebas, para poder comprobar
# las ramas de error sin tocar la instalacion de verdad. No se llama -Dir porque PS no
# distingue mayusculas y $Dir y $dir serian la misma variable.
function Get-SteamInfo {
    param([string]$RutaSteam = '')
    $script:SteamMotivo = ''
    $dir = $RutaSteam
    if (-not $dir) {
        $k = Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue
        if ($k -and $k.SteamPath) { $dir = ($k.SteamPath -replace '/','\') }
        if (-not $dir -or -not (Test-Path -LiteralPath $dir)) {
            foreach ($c in @((Join-Path ${env:ProgramFiles(x86)} 'Steam'), (Join-Path $env:ProgramFiles 'Steam'))) {
                if (Test-Path -LiteralPath $c) { $dir = $c; break }
            }
        }
    }
    if (-not $dir) {
        $script:SteamMotivo = 'No encuentro la instalación de Steam.'
        return $null
    }

    # El registro conserva la ruta aunque se haya desinstalado Steam. Sin esta comprobacion la
    # aplicacion cree que lo ha encontrado, da por cerrado lo que no esta abierto y falla mas
    # tarde, al escribir o al volver a abrirlo.
    $exe = Join-Path $dir 'steam.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        $script:SteamMotivo = "Encuentro la carpeta de Steam en $dir, pero no el steam.exe. ¿Se ha desinstalado?"
        return $null
    }

    $userdata = Join-Path $dir 'userdata'
    $perfiles = @()
    if (Test-Path -LiteralPath $userdata) {
        $perfiles = @(Get-ChildItem -LiteralPath $userdata -Directory -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -match '^\d+$' -and $_.Name -ne '0' })
    }
    if ($perfiles.Count -eq 0) {
        $script:SteamMotivo = 'Steam está instalado, pero todavía no hay ningún perfil. Ábrelo, inicia sesión una vez y vuelve a intentarlo.'
        return $null
    }

    $cuenta = Get-SteamCuentaActiva -Dir $dir
    $perfil = $null; $comoElegido = ''
    if ($cuenta) { $perfil = $perfiles | Where-Object { $_.Name -eq $cuenta } | Select-Object -First 1 }
    if ($perfil) {
        $comoElegido = 'sesión iniciada'
    } else {
        # de reserva, lo de antes: el perfil tocado mas recientemente
        $perfil = $perfiles | Sort-Object {
            $c = Join-Path $_.FullName 'config\localconfig.vdf'
            if (Test-Path -LiteralPath $c) { (Get-Item -LiteralPath $c).LastWriteTime } else { [datetime]::MinValue }
        } -Descending | Select-Object -First 1
        $comoElegido = 'el más reciente'
    }

    $config = Join-Path $perfil.FullName 'config'
    [pscustomobject]@{
        Dir         = $dir
        Exe         = $exe
        UserId      = $perfil.Name
        ConfigDir   = $config
        Shortcuts   = Join-Path $config 'shortcuts.vdf'
        GridDir     = Join-Path $config 'grid'
        Perfiles    = $perfiles.Count
        ComoElegido = $comoElegido
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

# La entrada que hay que quitar para un juego. Casan las mismas que en Find-ShortcutDuplicado,
# pero se prefiere la mas exacta: la de su nombre, exe y opciones, luego la de su exe y
# opciones y por ultimo la de su nombre. Con dos entradas del mismo nombre (una vieja que ya
# no arranca y la buena), la vieja sale en la lista por su cuenta y quitarla no se puede llevar
# la buena por ir antes en el fichero. Devuelve la clave, o $null.
function Find-ShortcutParaQuitar {
    param($Existentes, [string]$Nombre, [string]$Exe, [string]$LaunchOptions = '')
    $porExe = $null
    $porNombre = $null
    foreach ($e in @($Existentes)) {
        if (-not $e) { continue }
        $mismoNombre = ([string]$e.Nombre) -eq $Nombre
        $mismoExe    = (([string]$e.Exe) -eq $Exe) -and (([string]$e.LaunchOptions) -eq $LaunchOptions)
        if ($mismoNombre -and $mismoExe) { return $e.Indice }
        if ($mismoExe -and $null -eq $porExe) { $porExe = $e.Indice }
        if ($mismoNombre -and $null -eq $porNombre) { $porNombre = $e.Indice }
    }
    if ($null -ne $porExe) { return $porExe }
    return $porNombre
}

# Lo mismo leyendo shortcuts.vdf. Es seguro con Steam abierto: solo lee.
function Test-ShortcutDuplicado {
    param([Parameter(Mandatory)][string]$RutaVdf, [string]$Nombre, [string]$Exe, [string]$LaunchOptions = '')
    return (Find-ShortcutDuplicado -Existentes (Get-ShortcutsExistentes -Ruta $RutaVdf) `
                -Nombre $Nombre -Exe $Exe -LaunchOptions $LaunchOptions)
}

# ---------------------------------------------------------------------
#  Lo que hay en Steam frente a lo detectado
# ---------------------------------------------------------------------

# La entrada de Steam que le toca a un juego de la lista y como esta:
#  'en-steam'  una que lo lanza tal cual (exe y opciones), aunque se llame distinto; o una con
#              su nombre y su exe (las opciones se editaron al anadirlo)
#  'cambiado'  una con su nombre pero otro exe: el juego se ha movido o una actualizacion le ha
#              cambiado el ejecutable, y la de Steam ya no lo arranca
#  ''          ninguna
# Casa con lo mismo que Find-ShortcutDuplicado (nombre, o exe con opciones): lo que no es ''
# es lo que la escritura toma por duplicado. Devuelve Estado y Entrada (de ConvertTo-ShortcutInfo).
function Get-EstadoEnSteam {
    param($Existentes, [string]$Nombre, [string]$Exe, [string]$LaunchOptions = '')
    $porNombre = $null
    foreach ($e in @($Existentes)) {
        if (-not $e) { continue }
        if (([string]$e.Exe) -eq $Exe -and ([string]$e.LaunchOptions) -eq $LaunchOptions) {
            return [pscustomobject]@{ Estado = 'en-steam'; Entrada = $e }
        }
        if ($null -eq $porNombre -and ([string]$e.Nombre) -eq $Nombre) { $porNombre = $e }
    }
    if ($null -eq $porNombre) { return [pscustomobject]@{ Estado = ''; Entrada = $null } }
    $estado = $(if (([string]$porNombre.Exe) -eq $Exe) { 'en-steam' } else { 'cambiado' })
    return [pscustomobject]@{ Estado = $estado; Entrada = $porNombre }
}

# Las entradas de Steam que no le tocan a ningun juego de $Juegos (la de cada uno la dice
# Get-EstadoEnSteam). $Excluir: objetos con Nombre, Exe y LaunchOptions cuyas entradas no se
# devuelven aunque no le toquen a nadie (la propia Vaporera, que tiene su boton).
function Get-EntradasSinJuego {
    param($Existentes, [object[]]$Juegos = @(), [object[]]$Excluir = @())
    $suyas = @{}
    foreach ($j in @($Juegos)) {
        if (-not $j) { continue }
        $r = Get-EstadoEnSteam -Existentes $Existentes -Nombre $j.Nombre -Exe $j.Exe -LaunchOptions ([string]$j.LaunchOptions)
        if ($r.Entrada) { $suyas[[string]$r.Entrada.Indice] = $true }
    }
    $lista = @()
    foreach ($e in @($Existentes)) {
        if (-not $e -or $suyas.ContainsKey([string]$e.Indice)) { continue }
        $fuera = $false
        foreach ($x in @($Excluir)) {
            if (-not $x) { continue }
            if (([string]$e.Nombre) -eq $x.Nombre -or
                (([string]$e.Exe) -eq $x.Exe -and ([string]$e.LaunchOptions) -eq [string]$x.LaunchOptions)) { $fuera = $true; break }
        }
        if (-not $fuera) { $lista += $e }
    }
    return $lista
}

# Si una entrada que no le toca a ningun juego detectado es de uno que ya no esta: su exe no
# existe, o se lanza por la URI de una tienda que la busqueda mira siempre (Epic, Ubisoft) y no
# lo ha encontrado. Lo demas (un programa anadido a mano, una app de la Store con su casilla
# quitada) puede seguir ahi. $Unidades: las raices que se pueden mirar sin miedo (las fijas,
# Get-UnidadesFijas); en una de red desconectada Test-Path tarda segundos, asi que con un exe
# fuera de ellas no se sabe y se devuelve $false.
function Test-EntradaNoInstalada {
    param([Parameter(Mandatory)]$Entrada, [string[]]$Unidades = @())
    if (([string]$Entrada.LaunchOptions) -match '^(uplay|com\.epicgames\.launcher)://') { return $true }
    $exe = [string]$Entrada.Exe
    if (-not $exe) { return $false }
    $enFija = $false
    foreach ($u in @($Unidades)) { if ($u -and $exe.StartsWith($u, [StringComparison]::OrdinalIgnoreCase)) { $enFija = $true; break } }
    if (-not $enFija) { return $false }
    try { return (-not (Test-Path -LiteralPath $exe -PathType Leaf)) } catch { return $false }
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

    $info = @(ConvertTo-ShortcutInfo -Shortcuts $sc)
    $existente = Find-ShortcutDuplicado -Existentes $info -Nombre $Nombre -Exe $Exe -LaunchOptions $LaunchOptions
    # El appid de la entrada con la que choca. Al reemplazar puede no ser el nuevo (casa por
    # nombre con otro exe, o por exe con otro nombre) y entonces sus imagenes de config\grid\
    # se quedan huerfanas: quien llama las limpia con Remove-CaratulasHuerfanas.
    $appIdAnterior = $null
    if ($existente -ne $null) {
        $appIdAnterior = ($info | Where-Object { $_.Indice -eq $existente } | Select-Object -First 1).AppId
    }
    if ($existente -ne $null -and -not $Reemplazar) {
        return [pscustomobject]@{ Ok = $false; Motivo = 'duplicado'; Indice = $existente; AppId = $appId; AppIdAnterior = $appIdAnterior }
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
    return [pscustomobject]@{ Ok = $true; Motivo = ''; Indice = $existente; AppId = $appId; AppIdAnterior = $appIdAnterior }
}

# Quita las entradas con ese nombre, o la de esa clave (-Indice, la que devuelve
# Find-ShortcutDuplicado). Steam DEBE estar cerrado. Devuelve los appid quitados (vacio si no
# habia ninguna), para poder limpiar despues sus imagenes con Remove-CaratulasHuerfanas.
# Las claves se renumeran 0..n-1, como las deja Steam.
function Remove-SteamShortcut {
    param([Parameter(Mandatory)][string]$RutaVdf, [string]$Nombre = '', [string]$Indice = '')
    if (-not $Nombre -and -not $Indice) { throw 'Remove-SteamShortcut necesita -Nombre o -Indice.' }
    $quitados = @()
    if (-not (Test-Path -LiteralPath $RutaVdf)) { return $quitados }
    $root = Read-BinaryVdf -Path $RutaVdf
    $sc = $root['shortcuts']
    if (-not $sc) { return $quitados }
    $nuevo = [ordered]@{}
    $i = 0
    foreach ($k in @($sc.Keys)) {
        $sobra = if ($Indice) { ([string]$k) -eq $Indice } else { ([string]$sc[$k]['AppName']) -eq $Nombre }
        if ($sobra) {
            $quitados += [uint32][System.BitConverter]::ToUInt32([System.BitConverter]::GetBytes([int]$sc[$k]['appid']), 0)
            continue
        }
        $nuevo["$i"] = $sc[$k]; $i++
    }
    if ($quitados.Count) { $root['shortcuts'] = $nuevo; Write-BinaryVdf -Root $root -Path $RutaVdf }
    return $quitados
}

# ---------------------------------------------------------------------
#  Varios cambios de una vez, en memoria. Steam lee shortcuts.vdf solo al arrancar y lo
#  sobrescribe al salir: para N juegos se cierra una vez, se aplican todos aqui sobre lo leido
#  y quien llama escribe una sola vez (Write-BinaryVdf). Aqui no se toca el disco.
# ---------------------------------------------------------------------

# El resultado de un cambio, con todo lo que puede necesitar quien llama
function New-ResultadoCambio {
    param([string]$Tipo, $Elemento)
    return [pscustomobject]@{
        Tipo = $Tipo; Nombre = [string]$Elemento.Nombre; Ok = $false; Motivo = ''
        AppId = [uint32]0; AppIdAnterior = $null; Quitados = @(); NombreEnSteam = ''; Clave = ''
        Elemento = $Elemento
    }
}

# $Root es lo que devuelve Read-BinaryVdf y se modifica. $Bajas: objetos con Nombre, Exe y
# LaunchOptions (los de la lista); de cada uno se quita la entrada con la que casa, con el mismo
# criterio que la marca 'YA EN STEAM' y prefiriendo la mas exacta (Find-ShortcutParaQuitar).
# $Altas: objetos con Nombre, Exe, StartDir, Icono, LaunchOptions y, si se quiere reemplazar
# solo esa, Reemplazar. Primero las bajas, que renumeran las claves 0..n-1 como
# Steam, y luego las altas. Cada cambio va por su cuenta: el que no se puede hacer, o falla, se
# anota y los demas siguen. Devuelve un resultado por cambio, en el orden recibido: Ok, Motivo
# ('no-esta', 'duplicado', 'repetido' entre los propios elegidos, o el mensaje del error),
# AppId (el de la entrada nueva), AppIdAnterior (el de la reemplazada), Quitados (appid de la
# baja), NombreEnSteam (el de la entrada quitada), Clave (la entrada escrita, para retocarla
# despues: el icono) y Elemento (lo recibido).
function Invoke-CambiosShortcuts {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Root,
        [object[]]$Bajas = @(),
        [object[]]$Altas = @(),
        [switch]$Reemplazar
    )
    if (-not $Root['shortcuts']) { $Root['shortcuts'] = [ordered]@{} }
    $sc = $Root['shortcuts']
    $resultados = New-Object System.Collections.Generic.List[object]

    $quitar = @{}
    foreach ($b in @($Bajas)) {
        if (-not $b) { continue }
        $r = New-ResultadoCambio -Tipo 'Baja' -Elemento $b
        try {
            # las ya quitadas en este lote no cuentan: dos marcados que casan con la misma
            # entrada no la quitan "dos veces"
            $restantes = @(ConvertTo-ShortcutInfo -Shortcuts $sc | Where-Object { -not $quitar.ContainsKey([string]$_.Indice) })
            $clave = Find-ShortcutParaQuitar -Existentes $restantes -Nombre $b.Nombre -Exe $b.Exe -LaunchOptions ([string]$b.LaunchOptions)
            if ($null -eq $clave) { $r.Motivo = 'no-esta' }
            else {
                $info = $restantes | Where-Object { $_.Indice -eq $clave } | Select-Object -First 1
                $quitar[[string]$clave] = $true
                $r.Ok = $true; $r.Quitados = @($info.AppId); $r.NombreEnSteam = $info.Nombre; $r.Clave = [string]$clave
            }
        } catch { $r.Motivo = $_.Exception.Message }
        $resultados.Add($r)
    }
    if ($quitar.Count) {
        $nuevo = [ordered]@{}
        $i = 0
        foreach ($k in @($sc.Keys)) {
            if ($quitar.ContainsKey([string]$k)) { continue }
            $nuevo["$i"] = $sc[$k]; $i++
        }
        $Root['shortcuts'] = $nuevo
        $sc = $nuevo
    }

    $hechas = @()   # las altas ya hechas en este lote, para ver los repetidos
    foreach ($a in @($Altas)) {
        if (-not $a) { continue }
        $r = New-ResultadoCambio -Tipo 'Alta' -Elemento $a
        try {
            $opciones = [string]$a.LaunchOptions
            $r.AppId = Get-SteamShortcutAppId -ExeQuoted ('"' + $a.Exe + '"') -AppName $a.Nombre
            if ($null -ne (Find-ShortcutDuplicado -Existentes $hechas -Nombre $a.Nombre -Exe $a.Exe -LaunchOptions $opciones)) {
                $r.Motivo = 'repetido'
            } else {
                $info = @(ConvertTo-ShortcutInfo -Shortcuts $sc)
                $clave = Find-ShortcutDuplicado -Existentes $info -Nombre $a.Nombre -Exe $a.Exe -LaunchOptions $opciones
                # cada alta puede pedir el suyo: la de un juego que ha cambiado de exe se
                # actualiza aunque no se haya pedido reemplazar todos
                if ($null -ne $clave -and -not ($Reemplazar -or [bool]$a.Reemplazar)) {
                    $r.Motivo = 'duplicado'; $r.Clave = [string]$clave
                } else {
                    $entrada = New-EntradaShortcut -AppId $r.AppId -Nombre $a.Nombre -Exe $a.Exe -StartDir $a.StartDir `
                                   -Icono ([string]$a.Icono) -LaunchOptions $opciones
                    if ($null -ne $clave) {
                        # las claves son texto: con un entero el [ordered] indexa por posicion
                        $r.AppIdAnterior = ($info | Where-Object { $_.Indice -eq $clave } | Select-Object -First 1).AppId
                        $sc[[string]$clave] = $entrada
                        $r.Clave = [string]$clave
                    } else {
                        $siguiente = 0
                        foreach ($k in @($sc.Keys)) { $n = 0; if ([int]::TryParse($k, [ref]$n) -and $n -ge $siguiente) { $siguiente = $n + 1 } }
                        $sc["$siguiente"] = $entrada
                        $r.Clave = "$siguiente"
                    }
                    $r.Ok = $true
                    $hechas += [pscustomobject]@{ Indice = $r.Clave; Nombre = $a.Nombre; Exe = $a.Exe; LaunchOptions = $opciones }
                }
            }
        } catch { $r.Motivo = $_.Exception.Message }
        $resultados.Add($r)
    }
    return $resultados.ToArray()
}

# Lee shortcuts.vdf o, si todavia no existe (nunca se ha anadido nada), uno vacio
function Read-ShortcutsOVacio {
    param([Parameter(Mandatory)][string]$Ruta)
    if (Test-Path -LiteralPath $Ruta) { $root = Read-BinaryVdf -Path $Ruta }
    else { $root = [ordered]@{} }
    if (-not $root['shortcuts']) { $root['shortcuts'] = [ordered]@{} }
    return $root
}

# Borra de config\grid\ las imagenes de un appid que ya no usa ninguna entrada de
# shortcuts.vdf: las de un juego quitado, las del appid viejo al reemplazar o las copiadas
# para un acceso directo que al final no se escribio.
# Solo borra si ha podido leer el VDF y el appid no esta en el: si una entrada lo sigue usando,
# las imagenes son suyas. Los appid de los accesos directos llevan el bit alto puesto y los de
# los juegos de Steam no, asi que no se pueden llevar por delante las de un juego de la tienda.
# No lanza nunca (se llama desde los catch). Devuelve cuantos ficheros ha borrado.
function Remove-CaratulasHuerfanas {
    param(
        [Parameter(Mandatory)][string]$RutaVdf,
        [Parameter(Mandatory)][string]$GridDir,
        [uint32]$AppId = 0,
        [scriptblock]$Log = $null
    )
    function Registrar($m) { if ($Log) { & $Log $m | Out-Null } }
    if ($AppId -eq 0 -or -not (Test-Path -LiteralPath $GridDir)) { return 0 }
    try {
        $enUso = @(Get-ShortcutsExistentes -Ruta $RutaVdf | Where-Object { $_.AppId -eq $AppId })
        if ($enUso.Count) { return 0 }
    } catch {
        Registrar "No he podido leer shortcuts.vdf para limpiar las imágenes de $AppId; las dejo."
        return 0
    }
    # lo que genera esta aplicacion y lo que puede poner el propio Steam al cambiar una imagen
    # a mano (tambien en .jpg), mas el .json con la posicion del logo
    $nombres = @("${AppId}.json")
    foreach ($suf in @('', 'p', '_hero', '_logo', '_icon')) {
        foreach ($ext in @('png', 'jpg', 'jpeg')) { $nombres += "${AppId}${suf}.$ext" }
    }
    $n = 0
    foreach ($f in $nombres) {
        $ruta = Join-Path $GridDir $f
        if (-not (Test-Path -LiteralPath $ruta)) { continue }
        try { Remove-Item -LiteralPath $ruta -Force -ErrorAction Stop; $n++ }
        catch { Registrar "  no he podido borrar $f : $($_.Exception.Message)" }
    }
    if ($n) { Registrar "Borradas $n imágenes que ya no usaba ningún acceso directo (appid $AppId)." }
    return $n
}
