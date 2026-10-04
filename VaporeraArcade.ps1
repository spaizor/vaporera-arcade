# =====================================================================
#  Vaporera Arcade  -  Anadir juegos de otras plataformas a Steam
#
#  Detecta los juegos instalados (Xbox/Game Pass, Ubisoft, Epic, GOG,
#  apps de la Store y programas ejecutados hace poco), descarga las
#  caratulas oficiales y escribe el acceso directo en shortcuts.vdf.
#
#  Uso:  .\VaporeraArcade.ps1   (o el acceso directo que crea CrearAccesoDirecto.ps1)
# =====================================================================
$ErrorActionPreference = 'Stop'

# Version de la aplicacion. Sale en el titulo de la ventana, junto al nombre de la cabecera, en
# la primera linea del registro y en el historial del README.md: los cuatro tienen que ir
# sincronizados. El XAML es una cadena literal y no interpola: la ventana la pone por codigo.
$AppVersion = '1.1'

$Raiz = Split-Path -Parent $MyInvocation.MyCommand.Path
$TempDir = Join-Path $env:TEMP 'VaporeraArcade'

# El registro va en %LOCALAPPDATA%, igual que config.json: instalada en Program Files la
# aplicacion no puede escribir en su propia carpeta. La ruta se calcula aqui a mano porque
# lib\Config.ps1 (Get-ConfigRuta) todavia no esta cargado.
$DatosDir = $Raiz
if ($env:LOCALAPPDATA) { $DatosDir = Join-Path $env:LOCALAPPDATA 'VaporeraArcade' }
$LogFile = Join-Path $DatosDir 'vaporera-arcade.log'

# El registro y el aviso de errores van antes de cargar lib\: tienen que funcionar aunque falle eso
function Write-Registro {
    param([string]$Texto)
    $linea = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Texto
    try {
        $dir = Split-Path $LogFile -Parent
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        Add-Content -LiteralPath $LogFile -Value $linea -Encoding UTF8
    } catch { }
}

# Se llama una vez al arrancar. Pasado el limite, el registro actual pasa a ser el .log.1
# (pisando el anterior) y se empieza uno nuevo: nunca ocupan mas del doble del limite entre
# los dos y el .1 conserva lo ultimo por si hace falta para un informe. Devuelve si ha rotado.
function Invoke-RotarRegistro {
    param([long]$MaxBytes = 1MB)
    try {
        $f = Get-Item -LiteralPath $LogFile -ErrorAction Stop
        if ($f.Length -lt $MaxBytes) { return $false }
        Move-Item -LiteralPath $LogFile -Destination "$LogFile.1" -Force -ErrorAction Stop
        return $true
    } catch { return $false }
}

# Guarda un error con su detalle tecnico (fichero y linea) para poder diagnosticarlo
function Write-RegistroError {
    param([string]$Contexto, $Fallo)
    Write-Registro "ERROR en $Contexto : $($Fallo.Exception.Message)"
    $pos = $Fallo.InvocationInfo.PositionMessage
    if ($pos) { foreach ($l in ($pos -split "`r?`n")) { if ($l.Trim()) { Write-Registro "    $($l.Trim())" } } }
    if ($Fallo.Exception.InnerException) { Write-Registro "    causa: $($Fallo.Exception.InnerException.Message)" }
}

function Show-AvisoError {
    param([string]$Texto)
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show($Texto, 'Vaporera Arcade - Error', 'OK', 'Error')
    } catch {
        # si ni siquiera carga Windows Forms, el cuadro basico de Windows
        try { [void](New-Object -ComObject WScript.Shell).Popup($Texto, 0, 'Vaporera Arcade - Error', 16) } catch { }
    }
}

# Cualquier error sin controlar (una lib que no carga, el XAML, Add-Type...) acaba aqui.
# Lanzado desde el acceso directo la ventana de PowerShell va oculta: sin esto, la aplicacion
# no aparece y no se ve por que.
trap {
    $fallo = $_
    Write-RegistroError -Contexto 'error sin controlar' -Fallo $fallo
    # la causa raiz es mas corta (con el XAML roto, el mensaje de fuera incluye el XAML entero)
    $lineas = @($fallo.Exception.GetBaseException().Message -split "`r?`n")
    $resumen = ($lineas | Select-Object -First 8) -join "`r`n"
    if ($lineas.Count -gt 8) { $resumen += "`r`n(...)" }
    $texto = "Vaporera Arcade $AppVersion se ha cerrado por un error inesperado:`r`n`r`n$resumen"
    if ($fallo.InvocationInfo -and $fallo.InvocationInfo.ScriptName) {
        $texto += "`r`n`r`n($(Split-Path $fallo.InvocationInfo.ScriptName -Leaf), línea $($fallo.InvocationInfo.ScriptLineNumber))"
    }
    $texto += "`r`n`r`nDetalle en el registro:`r`n$LogFile"
    Show-AvisoError $texto
    exit 1
}

# Primera linea del registro en cada arranque. Es lo que hay que pedir en un informe de fallo:
# sin la version, un log ajeno no dice de que codigo viene.
$registroRotado = Invoke-RotarRegistro
Write-Registro "=== Vaporera Arcade $AppVersion | PowerShell $($PSVersionTable.PSVersion) | Windows $([Environment]::OSVersion.Version) ==="
if ($registroRotado) { Write-Registro "El registro anterior pasaba de 1 MB: se ha movido a $(Split-Path $LogFile -Leaf).1" }

. (Join-Path $Raiz 'lib\Config.ps1')
. (Join-Path $Raiz 'lib\Vdf.ps1')
. (Join-Path $Raiz 'lib\Fuentes.ps1')
. (Join-Path $Raiz 'lib\Caratulas.ps1')
. (Join-Path $Raiz 'lib\SteamCtl.ps1')
. (Join-Path $Raiz 'lib\Tareas.ps1')
. (Join-Path $Raiz 'lib\Mando.ps1')

# Lo que necesita New-CaratulasSteam en el runspace de "Preparar caratulas", que empieza vacio:
# Config (la clave de SteamGridDB) y Fuentes (Get-LogoAppStore)
$LibPreparar = @('Config.ps1', 'Fuentes.ps1', 'Caratulas.ps1') | ForEach-Object { Join-Path $Raiz "lib\$_" }

# Busqueda de texto sin comodines: con -like un '[' en el filtro da error
function Test-Contiene {
    param([string]$Texto, [string]$Buscado)
    return ($Texto.IndexOf($Buscado, [StringComparison]::OrdinalIgnoreCase) -ge 0)
}

# =====================================================================
#  Nucleo: caratulas, anadir y quitar
# =====================================================================

# Las imagenes que Steam no puede dejar de tener: sin ellas el juego sale en blanco
$ImagenesClave = [ordered]@{ p = 'portada'; cap = 'cápsula'; hero = 'cabecera' }

# Deja las imagenes en config\grid\: copia las que preparo la vista previa o, si no llega
# ninguna, las genera al vuelo. Devuelve Ok (estan las tres imprescindibles), la ruta del _icon.png (la que
# va al campo 'icon' del VDF) y las que falten.
function Invoke-Caratulas {
    param(
        [Parameter(Mandatory)]$Juego,
        [Parameter(Mandatory)][string]$Nombre,
        [Parameter(Mandatory)][uint32]$AppId,
        [Parameter(Mandatory)]$Steam,
        [hashtable]$CaratulasListas = $null,
        [string]$OrigenArte = 'Automatico',
        [scriptblock]$Log = $null
    )
    function Registrar($m) { if ($Log) { & $Log $m | Out-Null } else { Write-Registro $m } }

    # las que hayan quedado de verdad en config\grid\, para saber si se puede decir que esta listo
    function Get-Informe($Rutas, $Icono) {
        $faltan = @()
        foreach ($k in $ImagenesClave.Keys) {
            if (-not $Rutas[$k] -or -not (Test-Path -LiteralPath $Rutas[$k])) { $faltan += $ImagenesClave[$k] }
        }
        return [pscustomobject]@{ Ok = ($faltan.Count -eq 0); Icono = $Icono; Faltan = $faltan }
    }

    if (-not $CaratulasListas -or -not $CaratulasListas.Count) {
        $c = New-CaratulasSteam -Juego $Juego -AppId $AppId -GridDir $Steam.GridDir -NombreFinal $Nombre `
                -OrigenArte $OrigenArte -Log $Log
        Registrar "Carátulas: $($c.Origen)"
        return (Get-Informe -Rutas $c.Rutas -Icono $c.Rutas['icon'])
    }

    # en un PC recien estrenado config\grid\ todavia no existe: hay que crearla
    if (-not (Test-Path -LiteralPath $Steam.GridDir)) {
        [void](New-Item -ItemType Directory -Path $Steam.GridDir -Force)
        Registrar "Creada la carpeta config\grid\ (no existía)."
    }
    $copiadas = 0
    $puestas = @{}
    $finales = @{}
    foreach ($k in $CaratulasListas.Keys) {
        $origenImg = $CaratulasListas[$k]
        if (-not (Test-Path -LiteralPath $origenImg)) { Registrar "  falta la imagen '$k', me la salto."; continue }
        $hoja = Split-Path $origenImg -Leaf
        $destino = Join-Path $Steam.GridDir $hoja
        try {
            Copy-Item -LiteralPath $origenImg -Destination $destino -Force
            $copiadas++; $puestas[$hoja] = $true; $finales[$k] = $destino
        }
        catch { Registrar "  no he podido copiar '$k': $($_.Exception.Message)" }
    }
    # lo que esta vez no se ha generado (un _logo.png que no valia, por ejemplo) se quita:
    # si no, Steam seguiria usando el de un intento anterior
    foreach ($n in @("${AppId}p.png", "${AppId}.png", "${AppId}_hero.png", "${AppId}_logo.png", "${AppId}_icon.png")) {
        if ($puestas.ContainsKey($n)) { continue }
        $viejo = Join-Path $Steam.GridDir $n
        if (Test-Path -LiteralPath $viejo) {
            Remove-Item -LiteralPath $viejo -Force -ErrorAction SilentlyContinue
            Registrar "  quitada la imagen antigua $n"
        }
    }
    Registrar "Carátulas copiadas a config\grid\ ($copiadas de $($CaratulasListas.Count) imágenes)."
    return (Get-Informe -Rutas $finales -Icono $finales['icon'])
}

function Invoke-AnadirJuego {
    param(
        [Parameter(Mandatory)]$Juego,
        [Parameter(Mandatory)][string]$Nombre,
        [Parameter(Mandatory)]$Steam,
        [switch]$Reemplazar,
        [switch]$AbrirBigPicture,
        [switch]$NoReabrirSteam,
        [hashtable]$CaratulasListas = $null,
        [ValidateSet('Automatico','Store','SteamGridDB','Local')][string]$OrigenArte = 'Automatico',
        [scriptblock]$Log = $null
    )
    # si hay $Log, el propio bloque ya escribe en el fichero: asi no se duplican lineas
    function Registrar($m) { if ($Log) { & $Log $m | Out-Null } else { Write-Registro $m } }

    $appId = Get-SteamShortcutAppId -ExeQuoted ('"' + $Juego.Exe + '"') -AppName $Nombre
    Registrar "=== $Nombre ==="
    Registrar "Origen : $($Juego.Fuente)"
    Registrar "Exe    : $($Juego.Exe)"
    if ($Juego.LaunchOptions) { Registrar "Opciones: $($Juego.LaunchOptions)" }
    Registrar "AppId  : $appId"

    # el duplicado se mira antes de cerrar Steam: si no hay nada que escribir, no se cierra
    if (-not $Reemplazar) {
        $dup = Test-ShortcutDuplicado -RutaVdf $Steam.Shortcuts -Nombre $Nombre -Exe $Juego.Exe -LaunchOptions $Juego.LaunchOptions
        if ($null -ne $dup) {
            Registrar "Ya existe un acceso directo igual (entrada $dup). No se ha tocado nada."
            return [pscustomobject]@{ Ok = $false; AppId = $appId; Motivo = 'duplicado'; CaratulasOk = $false }
        }
    }

    $estabaAbierto = Test-SteamCorriendo
    if (-not (Stop-SteamYEsperar -SteamExe $Steam.Exe -Log $Log)) {
        Registrar 'ABORTADO: Steam no se ha cerrado. Ciérralo a mano y repite.'
        return [pscustomobject]@{ Ok = $false; AppId = $appId; Motivo = 'steam-abierto'; CaratulasOk = $false }
    }

    # a partir de aqui Steam esta cerrado: pase lo que pase, se vuelve a abrir en el finally
    $escrito = $false
    try {
        # Otra vez, ahora con Steam cerrado: al salir reescribe shortcuts.vdf y lo leido antes
        # puede haber cambiado. Tiene que ir antes de copiar las imagenes: con un duplicado del
        # mismo appid, copiarlas machacaria las del acceso directo que ya existe.
        if (-not $Reemplazar) {
            $dup = Test-ShortcutDuplicado -RutaVdf $Steam.Shortcuts -Nombre $Nombre -Exe $Juego.Exe -LaunchOptions $Juego.LaunchOptions
            if ($null -ne $dup) {
                Registrar "Ya existe un acceso directo igual (entrada $dup). No se ha tocado nada."
                return [pscustomobject]@{ Ok = $false; AppId = $appId; Motivo = 'duplicado'; CaratulasOk = $false }
            }
        }

        $bak = Backup-Shortcuts -Ruta $Steam.Shortcuts -Log $Log
        if ($bak) { Registrar "Copia de seguridad: $(Split-Path $bak -Leaf)" }

        # Las caratulas van ANTES de escribir el VDF: Steam no busca el icono por el nombre del
        # fichero, lo saca del campo 'icon' de la entrada, y hasta que no estan generadas no se
        # sabe si hay _icon.png. Si fallan se anade el juego igual: sin caratula se ve, sin
        # acceso directo no.
        $icono = $Juego.Icono
        $arte = $null
        try {
            $arte = Invoke-Caratulas -Juego $Juego -Nombre $Nombre -AppId $appId -Steam $Steam `
                        -CaratulasListas $CaratulasListas -OrigenArte $OrigenArte -Log $Log
            if ($arte.Icono -and (Test-Path -LiteralPath $arte.Icono)) { $icono = $arte.Icono }
        } catch {
            Registrar "Las carátulas han fallado: $($_.Exception.Message). Sigo con el acceso directo."
            Write-RegistroError -Contexto 'generar carátulas' -Fallo $_
        }
        $arteOk = [bool]($arte -and $arte.Ok)

        $r = Add-SteamShortcut -RutaVdf $Steam.Shortcuts -Nombre $Nombre -Exe $Juego.Exe `
                -StartDir $Juego.StartDir -Icono $icono -LaunchOptions $Juego.LaunchOptions `
                -Reemplazar:$Reemplazar -Log $Log
        if (-not $r.Ok) {
            # con la comprobacion de arriba no deberia pasar; si pasa, las imagenes recien
            # copiadas no son de nadie (salvo que el duplicado tenga el mismo appid)
            Registrar "Ya existe un acceso directo igual (entrada $($r.Indice)). No se ha tocado nada."
            [void](Remove-CaratulasHuerfanas -RutaVdf $Steam.Shortcuts -GridDir $Steam.GridDir -AppId $appId -Log $Log)
            return [pscustomobject]@{ Ok = $false; AppId = $appId; Motivo = 'duplicado'; CaratulasOk = $false }
        }
        $escrito = $true

        # al reemplazar una entrada de otro appid, sus imagenes ya no las usa nadie
        if ($null -ne $r.AppIdAnterior -and $r.AppIdAnterior -ne $appId) {
            [void](Remove-CaratulasHuerfanas -RutaVdf $Steam.Shortcuts -GridDir $Steam.GridDir -AppId $r.AppIdAnterior -Log $Log)
        }

        if ($arteOk) {
            Registrar "LISTO. '$Nombre' ya está en la biblioteca."
        } else {
            # el acceso directo esta, que es lo que importa, pero sin decir que todo ha ido bien
            $queFalta = if ($arte -and $arte.Faltan.Count) { "falta " + ($arte.Faltan -join ', ') } else { 'no hay carátulas' }
            Registrar "'$Nombre' ya está en la biblioteca, pero las carátulas no están completas ($queFalta)."
            Registrar 'Steam lo mostrará sin imagen. Puedes volver a intentarlo con "Reemplazar si ya existe".'
        }
        return [pscustomobject]@{ Ok = $true; AppId = $appId; Motivo = ''; CaratulasOk = $arteOk }
    } catch {
        if ($escrito) { Registrar 'El acceso directo ya está escrito, pero algo ha fallado después (ver el error).' }
        else {
            Registrar 'Algo ha fallado antes de terminar de escribir.'
            # las imagenes ya copiadas se quedarian sin acceso directo (si al reemplazar sigue
            # la entrada vieja con el mismo appid, son suyas y no se tocan)
            [void](Remove-CaratulasHuerfanas -RutaVdf $Steam.Shortcuts -GridDir $Steam.GridDir -AppId $appId -Log $Log)
        }
        # el aviso de la copia de seguridad, siempre que exista: antes solo salia en una rama
        if ($bak) { Registrar "Si shortcuts.vdf quedara mal, restaura la copia: $bak" }
        throw
    } finally {
        # tras escribir se abre siempre (el usuario querra verlo); si no, solo si estaba abierto
        if (-not $NoReabrirSteam -and ($escrito -or $estabaAbierto)) {
            Start-Steam -SteamExe $Steam.Exe -BigPicture:$AbrirBigPicture -Log $Log
        }
    }
}

# Quita de shortcuts.vdf el acceso directo que corresponde a $Juego (el mismo criterio que la
# marca 'YA EN STEAM': nombre igual, o exe con las mismas opciones) y sus imagenes de
# config\grid\. La confirmacion es cosa de quien llama.
function Invoke-QuitarJuego {
    param(
        [Parameter(Mandatory)]$Juego,
        [Parameter(Mandatory)]$Steam,
        [switch]$AbrirBigPicture,
        [switch]$NoReabrirSteam,
        [scriptblock]$Log = $null
    )
    function Registrar($m) { if ($Log) { & $Log $m | Out-Null } else { Write-Registro $m } }

    $estabaAbierto = Test-SteamCorriendo
    if (-not (Stop-SteamYEsperar -SteamExe $Steam.Exe -Log $Log)) {
        Registrar 'ABORTADO: Steam no se ha cerrado. Ciérralo a mano y repite.'
        return [pscustomobject]@{ Ok = $false; Motivo = 'steam-abierto' }
    }

    $bak = $null
    try {
        # se busca con Steam ya cerrado: al salir reescribe el fichero y las claves pueden cambiar
        $existentes = @(Get-ShortcutsExistentes -Ruta $Steam.Shortcuts)
        $indice = Find-ShortcutDuplicado -Existentes $existentes -Nombre $Juego.Nombre -Exe $Juego.Exe -LaunchOptions $Juego.LaunchOptions
        if ($null -eq $indice) {
            Registrar "No hay ningún acceso directo de '$($Juego.Nombre)' en Steam. No se ha tocado nada."
            return [pscustomobject]@{ Ok = $false; Motivo = 'no-esta' }
        }
        $entrada = $existentes | Where-Object { $_.Indice -eq $indice } | Select-Object -First 1
        Registrar "=== Quitar $($entrada.Nombre) ==="

        $bak = Backup-Shortcuts -Ruta $Steam.Shortcuts -Log $Log
        if ($bak) { Registrar "Copia de seguridad: $(Split-Path $bak -Leaf)" }

        $quitados = @(Remove-SteamShortcut -RutaVdf $Steam.Shortcuts -Indice $indice)
        foreach ($a in $quitados) {
            [void](Remove-CaratulasHuerfanas -RutaVdf $Steam.Shortcuts -GridDir $Steam.GridDir -AppId $a -Log $Log)
        }
        Registrar "LISTO. '$($entrada.Nombre)' ya no está en la biblioteca."
        return [pscustomobject]@{ Ok = $true; Motivo = '' }
    } catch {
        if ($bak) { Registrar "Si shortcuts.vdf quedara mal, restaura la copia: $bak" }
        throw
    } finally {
        # aqui no se abre si no estaba abierto: al quitar no hay nada nuevo que ir a ver
        if (-not $NoReabrirSteam -and $estabaAbierto) {
            Start-Steam -SteamExe $Steam.Exe -BigPicture:$AbrirBigPicture -Log $Log
        }
    }
}

# --- varios juegos con un solo reinicio de Steam ------------------------
# Las mismas reglas que con uno (cerrar Steam, volver a mirar con el cerrado, copia de
# seguridad, reabrir), pero Steam se cierra una vez y shortcuts.vdf se escribe una vez con
# todos los cambios, hechos en memoria por Invoke-CambiosShortcuts. Un juego que no se puede
# hacer no tumba a los demas: sale en el resumen.

# "1 juego" o "3 juegos"
function Get-CuentaJuegos { param([int]$N) if ($N -eq 1) { return '1 juego' } return "$N juegos" }

# Por que no se ha hecho un cambio, para el resumen
function Get-TextoMotivo {
    param($Resultado)
    switch ($Resultado.Motivo) {
        'no-esta'   { return 'no estaba en Steam' }
        'duplicado' { return 'ya estaba en Steam' }
        'repetido'  { return 'repetido entre los marcados' }
        default     { return "error: $($Resultado.Motivo)" }
    }
}

# El detalle de lo que no se ha hecho y una linea con la cuenta: "3 añadidos, 1 ya estaba..."
function Write-ResumenLote {
    param([object[]]$Resultados, [string]$Hecho, [scriptblock]$Log = $null)
    function Registrar($m) { if ($Log) { & $Log $m | Out-Null } else { Write-Registro $m } }
    $grupos = [ordered]@{}
    foreach ($r in @($Resultados)) {
        if ($r.Ok) { continue }
        $t = Get-TextoMotivo $r
        Registrar "  - $($r.Nombre): $t"
        if ($t.StartsWith('error')) { $t = 'con error' }
        if (-not $grupos.Contains($t)) { $grupos[$t] = 0 }
        $grupos[$t]++
    }
    $partes = @("$(@($Resultados | Where-Object { $_.Ok }).Count) $Hecho")
    foreach ($k in $grupos.Keys) { $partes += "$($grupos[$k]) $k" }
    Registrar ("Resumen: " + ($partes -join ', ') + '.')
}

# Quita de Steam los juegos de la lista (los de la marca 'YA EN STEAM') y sus imagenes.
# Devuelve un resultado por juego (Invoke-CambiosShortcuts), o $null si Steam no se cierra.
# La confirmacion es cosa de quien llama.
function Invoke-QuitarJuegos {
    param(
        [Parameter(Mandatory)][object[]]$Juegos,
        [Parameter(Mandatory)]$Steam,
        [switch]$AbrirBigPicture,
        [switch]$NoReabrirSteam,
        [scriptblock]$Log = $null
    )
    function Registrar($m) { if ($Log) { & $Log $m | Out-Null } else { Write-Registro $m } }
    Registrar "=== Quitar $(Get-CuentaJuegos @($Juegos).Count) ==="

    $estabaAbierto = Test-SteamCorriendo
    if (-not (Stop-SteamYEsperar -SteamExe $Steam.Exe -Log $Log)) {
        Registrar 'ABORTADO: Steam no se ha cerrado. Ciérralo a mano y repite.'
        return $null
    }
    $bak = $null
    try {
        # con Steam ya cerrado: al salir reescribe el fichero y las claves pueden cambiar
        $root = Read-ShortcutsOVacio -Ruta $Steam.Shortcuts
        $res = @(Invoke-CambiosShortcuts -Root $root -Bajas $Juegos)
        $hechos = @($res | Where-Object { $_.Ok })
        if ($hechos.Count) {
            $bak = Backup-Shortcuts -Ruta $Steam.Shortcuts -Log $Log
            if ($bak) { Registrar "Copia de seguridad: $(Split-Path $bak -Leaf)" }
            Write-BinaryVdf -Root $root -Path $Steam.Shortcuts
            foreach ($r in $hechos) {
                Registrar "  quitado: $($r.NombreEnSteam)"
                foreach ($a in @($r.Quitados)) {
                    [void](Remove-CaratulasHuerfanas -RutaVdf $Steam.Shortcuts -GridDir $Steam.GridDir -AppId $a -Log $Log)
                }
            }
        } else {
            Registrar 'No había nada que quitar: no se ha tocado shortcuts.vdf.'
        }
        Write-ResumenLote -Resultados $res -Hecho 'quitados' -Log $Log
        return $res
    } catch {
        if ($bak) { Registrar "Si shortcuts.vdf quedara mal, restaura la copia: $bak" }
        throw
    } finally {
        # como con uno: al quitar, Steam se abre solo si estaba abierto
        if (-not $NoReabrirSteam -and $estabaAbierto) {
            Start-Steam -SteamExe $Steam.Exe -BigPicture:$AbrirBigPicture -Log $Log
        }
    }
}

# Anade varios juegos. $Lote: objetos con Juego, Nombre y Rutas (las imagenes ya preparadas,
# como las de la vista previa; vacio si no se pudieron preparar: el juego se anade sin ellas,
# que prepararlas ahora seria con Steam cerrado). Devuelve un resultado por juego
# (Invoke-CambiosShortcuts, con CaratulasOk), o $null si Steam no se cierra.
function Invoke-AnadirJuegos {
    param(
        [Parameter(Mandatory)][object[]]$Lote,
        [Parameter(Mandatory)]$Steam,
        [switch]$Reemplazar,
        [switch]$AbrirBigPicture,
        [switch]$NoReabrirSteam,
        [scriptblock]$Log = $null
    )
    function Registrar($m) { if ($Log) { & $Log $m | Out-Null } else { Write-Registro $m } }
    $altas = @(foreach ($x in @($Lote)) {
        [pscustomobject]@{ Nombre = $x.Nombre; Exe = $x.Juego.Exe; StartDir = $x.Juego.StartDir
                           Icono = $x.Juego.Icono; LaunchOptions = $x.Juego.LaunchOptions; Lote = $x }
    })
    Registrar "=== Añadir $(Get-CuentaJuegos $altas.Count) ==="

    # Antes de cerrar Steam, en una copia de lo leido: si no se puede anadir ninguno (ya estan
    # todos), no se cierra
    $prueba = @(Invoke-CambiosShortcuts -Root (Read-ShortcutsOVacio -Ruta $Steam.Shortcuts) -Altas $altas -Reemplazar:$Reemplazar)
    if (-not @($prueba | Where-Object { $_.Ok }).Count) {
        Registrar 'No hay nada que añadir: no se ha tocado Steam.'
        Write-ResumenLote -Resultados $prueba -Hecho 'añadidos' -Log $Log
        return $prueba
    }

    $estabaAbierto = Test-SteamCorriendo
    if (-not (Stop-SteamYEsperar -SteamExe $Steam.Exe -Log $Log)) {
        Registrar 'ABORTADO: Steam no se ha cerrado. Ciérralo a mano y repite.'
        return $null
    }
    $bak = $null
    $escrito = $false
    $copiados = @()
    try {
        # Otra vez con Steam cerrado, y antes de copiar ninguna imagen: con un duplicado del
        # mismo appid, copiarlas machacaria las del acceso directo que ya existe
        $root = Read-ShortcutsOVacio -Ruta $Steam.Shortcuts
        $res = @(Invoke-CambiosShortcuts -Root $root -Altas $altas -Reemplazar:$Reemplazar)
        $hechos = @($res | Where-Object { $_.Ok })
        foreach ($r in $res) { $r | Add-Member -NotePropertyName CaratulasOk -NotePropertyValue $false -Force }
        if (-not $hechos.Count) {
            Registrar 'Con Steam cerrado ya no queda nada que añadir: no se ha tocado shortcuts.vdf.'
            Write-ResumenLote -Resultados $res -Hecho 'añadidos' -Log $Log
            return $res
        }
        $bak = Backup-Shortcuts -Ruta $Steam.Shortcuts -Log $Log
        if ($bak) { Registrar "Copia de seguridad: $(Split-Path $bak -Leaf)" }

        # Las imagenes antes de escribir: el campo 'icon' de cada entrada apunta a su _icon.png
        foreach ($r in $hechos) {
            $x = $r.Elemento.Lote
            if (-not $x.Rutas -or -not $x.Rutas.Count) {
                Registrar "  $($r.Nombre): sin carátulas (no se han podido preparar); se añade igual."
                continue
            }
            try {
                Registrar "  $($r.Nombre):"
                $arte = Invoke-Caratulas -Juego $x.Juego -Nombre $r.Nombre -AppId $r.AppId -Steam $Steam `
                            -CaratulasListas $x.Rutas -Log $Log
                $copiados += $r.AppId
                if ($arte.Icono -and (Test-Path -LiteralPath $arte.Icono)) { $root['shortcuts'][$r.Clave]['icon'] = $arte.Icono }
                $r.CaratulasOk = [bool]$arte.Ok
                if (-not $arte.Ok) { Registrar "    faltan carátulas: $($arte.Faltan -join ', ')" }
            } catch {
                Registrar "  $($r.Nombre): las carátulas han fallado ($($_.Exception.Message)); se añade igual."
                Write-RegistroError -Contexto 'carátulas de varios' -Fallo $_
            }
        }

        Write-BinaryVdf -Root $root -Path $Steam.Shortcuts
        $escrito = $true
        foreach ($r in $hechos) {
            Registrar "  añadido: $($r.Nombre)"
            # al reemplazar una entrada de otro appid, sus imagenes ya no las usa nadie
            if ($null -ne $r.AppIdAnterior -and $r.AppIdAnterior -ne $r.AppId) {
                [void](Remove-CaratulasHuerfanas -RutaVdf $Steam.Shortcuts -GridDir $Steam.GridDir -AppId $r.AppIdAnterior -Log $Log)
            }
        }
        $sinArte = @($hechos | Where-Object { -not $_.CaratulasOk }).Count
        if ($sinArte) { Registrar "$sinArte se han añadido con las carátulas incompletas: Steam los mostrará sin imagen." }
        Write-ResumenLote -Resultados $res -Hecho 'añadidos' -Log $Log
        return $res
    } catch {
        if ($escrito) { Registrar 'shortcuts.vdf ya está escrito, pero algo ha fallado después (ver el error).' }
        else {
            Registrar 'Algo ha fallado antes de escribir shortcuts.vdf: no se ha añadido ninguno.'
            # las imagenes ya copiadas se quedarian sin acceso directo
            foreach ($a in $copiados) {
                [void](Remove-CaratulasHuerfanas -RutaVdf $Steam.Shortcuts -GridDir $Steam.GridDir -AppId $a -Log $Log)
            }
        }
        if ($bak) { Registrar "Si shortcuts.vdf quedara mal, restaura la copia: $bak" }
        throw
    } finally {
        if (-not $NoReabrirSteam -and ($escrito -or $estabaAbierto)) {
            Start-Steam -SteamExe $Steam.Exe -BigPicture:$AbrirBigPicture -Log $Log
        }
    }
}

# =====================================================================
#  GUI (WPF)
# =====================================================================
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Drawing

# El de la ventana, la de Ajustes y la barra de tareas; sin el sale el de PowerShell. Si falta
# o no se puede leer se queda ese: no es motivo para no arrancar. Del .ico WPF coge solo el
# tamano que necesita en cada sitio. Lo genera docs\CrearIcono.ps1.
$script:IconoVentana = $null
$icoApp = Join-Path $Raiz 'docs\VaporeraArcade.ico'
if (Test-Path -LiteralPath $icoApp) {
    try { $script:IconoVentana = [Windows.Media.Imaging.BitmapFrame]::Create((New-Object Uri($icoApp))) }
    catch { Write-Registro "No he podido cargar el icono de la ventana: $($_.Exception.Message)" }
}

# El recuadro del foco de teclado, el mismo en todas las ventanas: sus estilos lo piden como
# {DynamicResource Foco} y Add-EstiloFoco se lo da al cargar cada una. WPF solo lo pinta
# cuando se llega con el teclado. Va por dentro del control (Margin 0) para que no lo corte el
# borde de un ScrollViewer.
$script:EstiloFoco = [Windows.Markup.XamlReader]::Parse(@'
<Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
  <Setter Property="Control.Template">
    <Setter.Value>
      <ControlTemplate>
        <Rectangle Stroke="#FFF0F2F5" StrokeThickness="2" SnapsToDevicePixels="True"/>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
'@)
function Add-EstiloFoco {
    param([Parameter(Mandatory)][Windows.Window]$Ventana)
    $Ventana.Resources['Foco'] = $script:EstiloFoco
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Vaporera Arcade" Height="800" Width="1120"
        MinHeight="480" MinWidth="820"
        WindowStartupLocation="CenterScreen" Background="#FF15171B"
        FocusManager.FocusedElement="{Binding ElementName=LstJuegos}">
  <!-- El recuadro del foco de teclado (Foco) lo anade Add-EstiloFoco despues de cargar: el de
       serie es una linea de puntos negra que con este fondo no se ve. -->
  <Window.Resources>
    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="#FFE6E8EC"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#FFB9BEC7"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="Margin" Value="0,4,14,4"/>
      <Setter Property="FocusVisualStyle" Value="{DynamicResource Foco}"/>
    </Style>
    <Style TargetType="ListBoxItem">
      <Setter Property="FocusVisualStyle" Value="{DynamicResource Foco}"/>
    </Style>
    <!-- El ComboBox necesita plantilla propia: el tema de Windows pinta su cuadro de blanco
         pase lo que pase en Background, y el texto claro encima no se lee. -->
    <Style TargetType="ComboBox">
      <Setter Property="Background" Value="#FF1E2127"/>
      <Setter Property="Foreground" Value="#FFE6E8EC"/>
      <Setter Property="BorderBrush" Value="#FF3A3F49"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="Height" Value="30"/>
      <Setter Property="FocusVisualStyle" Value="{DynamicResource Foco}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                      BorderThickness="1" SnapsToDevicePixels="True"/>
              <ToggleButton Focusable="False" ClickMode="Press" Background="Transparent"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border Background="Transparent">
                      <Path HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,10,0"
                            Data="M 0 0 L 4 4 L 8 0 Z" Fill="#FFB9BEC7"/>
                    </Border>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter Margin="8,0,26,0" VerticalAlignment="Center" HorizontalAlignment="Left"
                                IsHitTestVisible="False" TextElement.Foreground="{TemplateBinding Foreground}"
                                Content="{TemplateBinding SelectionBoxItem}"
                                ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"/>
              <Popup IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom" Focusable="False"
                     AllowsTransparency="True" PopupAnimation="None">
                <Border Background="#FF1E2127" BorderBrush="#FF3A3F49" BorderThickness="1"
                        MinWidth="{TemplateBinding ActualWidth}">
                  <ScrollViewer MaxHeight="{TemplateBinding MaxDropDownHeight}">
                    <ItemsPresenter/>
                  </ScrollViewer>
                </Border>
              </Popup>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ComboBoxItem">
      <Setter Property="Background" Value="#FF1E2127"/>
      <Setter Property="Foreground" Value="#FFE6E8EC"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="Padding" Value="8,6"/>
      <!-- con el teclado ya se ve cual es por IsHighlighted -->
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <!-- sin esto, el elemento bajo el raton sale con el azul claro del sistema -->
            <Border Name="Bd" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}"
                    SnapsToDevicePixels="True">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#FF2E3440"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#FF262A31"/>
      <Setter Property="Foreground" Value="#FFE6E8EC"/>
      <Setter Property="BorderBrush" Value="#FF3A3F49"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="FocusVisualStyle" Value="{DynamicResource Foco}"/>
    </Style>
    <!-- Los botones del modo sencillo: grandes y con plantilla propia, que el tema de Windows
         pinta de blanco el boton desactivado -->
    <Style x:Key="Grande" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="FontSize" Value="17"/>
      <Setter Property="Padding" Value="22,10"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" Padding="{TemplateBinding Padding}"
                    SnapsToDevicePixels="True">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="#FF8A909B"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Opacity" Value="0.35"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <!-- Los huecos de la vista previa: botones (para el teclado) que se ven como un recuadro -->
    <Style x:Key="Hueco" TargetType="Button">
      <Setter Property="Background" Value="#FF111316"/>
      <Setter Property="BorderBrush" Value="#FF3A3F49"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="HorizontalAlignment" Value="Left"/>
      <Setter Property="FocusVisualStyle" Value="{DynamicResource Foco}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" SnapsToDevicePixels="True">
              <ContentPresenter/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid Margin="14">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="96"/>
    </Grid.RowDefinitions>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="380"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <!-- cabecera -->
    <Grid Grid.Row="0" Grid.ColumnSpan="2" Margin="0,0,0,10">
      <StackPanel>
        <StackPanel Orientation="Horizontal">
          <TextBlock Text="Vaporera Arcade" FontSize="20" FontWeight="SemiBold" Foreground="#FFDC1E23"/>
          <TextBlock Name="TxtVersion" FontSize="11" Foreground="#FF6E747E" Margin="7,0,0,3"
                     VerticalAlignment="Bottom"/>
        </StackPanel>
        <TextBlock Name="TxtSteam" Text="" FontSize="11" Foreground="#FF8A909B" Margin="0,2,0,0"/>
      </StackPanel>
      <!-- La propia Vaporera en Steam, para abrirla desde Big Picture con el mando: el boton
           solo sale si no esta (o esta con otra ruta), segun Update-Botones -->
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
        <Button Name="BtnVaporeraSteam" Content="Añadir Vaporera a Steam" Padding="10,3" Visibility="Collapsed"
                ToolTip="Añade esta aplicación a la biblioteca de Steam, con sus carátulas, para abrirla desde Big Picture"/>
        <Button Name="BtnBigPicture" Content="Big Picture" Padding="10,3"
                ToolTip="Abre Steam en Big Picture y cierra la Vaporera"/>
        <Button Name="BtnAjustes" Content="Ajustes..." Padding="10,3"/>
        <!-- cambia entre el modo avanzado (todo) y el sencillo (PanelSencillo): Set-ModoSencillo -->
        <Button Name="BtnModo" Content="Modo sencillo" Padding="10,3" Margin="0"/>
      </StackPanel>
    </Grid>

    <!-- lista -->
    <Grid Name="PanelLista" Grid.Row="1" Grid.Column="0" Margin="0,0,14,0">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <TextBlock Grid.Row="0" Text="Buscar por nombre" FontSize="11" Foreground="#FF8A909B" Margin="0,0,0,3"/>
      <TextBox Name="TxtBuscar" Grid.Row="1" Height="30" FontSize="14" Padding="6,4"
               Background="#FF1E2127" Foreground="#FFE6E8EC" BorderBrush="#FF3A3F49"
               VerticalContentAlignment="Center"/>
      <WrapPanel Grid.Row="2" Margin="0,8,0,8">
        <CheckBox Name="ChkRecientes" Content="Programas recientes"/>
        <CheckBox Name="ChkApps" Content="Apps de la Store"/>
        <Button Name="BtnRefrescar" Content="Refrescar" Padding="10,3"/>
        <Button Name="BtnExaminar" Content="Examinar .exe..." Padding="10,3"/>
      </WrapPanel>
      <ListBox Name="LstJuegos" Grid.Row="3" Background="#FF1E2127" BorderBrush="#FF3A3F49"
               Foreground="#FFE6E8EC" ScrollViewer.HorizontalScrollBarVisibility="Disabled">
        <!-- La casilla escribe en la propiedad Marcado del juego (binding de ida y vuelta con un
             pscustomobject: funciona). Marcar no selecciona: la vista previa es del seleccionado.
             Sin foco propio: con el teclado se marca con Espacio sobre el juego (PreviewKeyDown),
             y el tabulador no se para en cada casilla. -->
        <ListBox.ItemTemplate>
          <DataTemplate>
            <DockPanel Margin="2,4">
              <CheckBox DockPanel.Dock="Left" IsChecked="{Binding Marcado, Mode=TwoWay}" VerticalAlignment="Center"
                        Margin="0,0,8,0" Focusable="False"
                        ToolTip="Marcar para añadir o quitar varios juegos de una vez (Espacio)"/>
              <StackPanel>
                <TextBlock Text="{Binding Nombre}" FontSize="14"/>
                <TextBlock FontSize="11" Foreground="#FF8A909B">
                  <Run Text="{Binding Fuente, Mode=OneWay}"/><Run Text="   "/><Run Text="{Binding Marca, Mode=OneWay}"/>
                </TextBlock>
              </StackPanel>
            </DockPanel>
          </DataTemplate>
        </ListBox.ItemTemplate>
      </ListBox>
      <!-- varios juegos con un solo reinicio de Steam -->
      <StackPanel Grid.Row="4" Margin="0,8,0,0">
        <TextBlock Name="TxtMarcados" FontSize="11" Foreground="#FF8A909B" TextWrapping="Wrap" Margin="0,0,0,6"/>
        <WrapPanel>
          <Button Name="BtnAnadirMarcados" Content="Añadir marcados" Padding="10,3" IsEnabled="False"/>
          <Button Name="BtnQuitarMarcados" Content="Quitar marcados" Padding="10,3" IsEnabled="False"/>
          <Button Name="BtnDesmarcar" Content="Desmarcar" Padding="10,3" IsEnabled="False"/>
        </WrapPanel>
      </StackPanel>
    </Grid>

    <!-- detalle -->
    <!-- sin foco: seria una parada invisible del tabulador; con el foco dentro se desplaza igual -->
    <ScrollViewer Name="PanelDetalle" Grid.Row="1" Grid.Column="1" VerticalScrollBarVisibility="Auto" Focusable="False">
    <StackPanel>
      <TextBlock Text="Nombre en la biblioteca" FontSize="11" Foreground="#FF8A909B"/>
      <TextBox Name="TxtNombre" Height="30" FontSize="15" Padding="6,4" Margin="0,3,0,10"
               Background="#FF1E2127" Foreground="#FFE6E8EC" BorderBrush="#FF3A3F49"
               VerticalContentAlignment="Center"/>
      <TextBlock Text="Ejecutable" FontSize="11" Foreground="#FF8A909B"/>
      <TextBox Name="TxtExe" Height="28" Margin="0,3,0,10" IsReadOnly="True" IsTabStop="False"
               Background="#FF1A1D22" Foreground="#FFB9BEC7" BorderBrush="#FF2A2E36"/>
      <TextBlock Text="Opciones de lanzamiento" FontSize="11" Foreground="#FF8A909B"/>
      <TextBox Name="TxtOpciones" Height="28" Margin="0,3,0,10"
               Background="#FF1E2127" Foreground="#FFE6E8EC" BorderBrush="#FF3A3F49"/>
      <TextBlock Name="TxtDetalle" FontSize="11" Foreground="#FF8A909B" TextWrapping="Wrap" Margin="0,0,0,12"/>

      <!-- A la derecha, solo si el juego tiene uno elegido a mano en la galeria (guardado en
           config.json): con el no se busca por el nombre. Los margenes negativos del boton son
           para que la fila no crezca: la vista previa de debajo cabe justa en la ventana. -->
      <DockPanel>
        <TextBlock DockPanel.Dock="Left" Text="Origen de las carátulas" FontSize="11" Foreground="#FF8A909B"
                   VerticalAlignment="Center"/>
        <Button Name="BtnOlvidar" DockPanel.Dock="Right" Content="Olvidar" FontSize="11" Padding="8,0"
                Margin="8,-3,0,-3" VerticalAlignment="Center" Visibility="Collapsed"
                ToolTip="Olvida el juego elegido a mano: las carátulas se vuelven a buscar por el nombre"/>
        <TextBlock Name="TxtElegido" FontSize="11" Foreground="#FF8A909B" Margin="12,0,0,0"
                   TextAlignment="Right" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
      </DockPanel>
      <ComboBox Name="CmbOrigenArte" Margin="0,3,0,12" SelectedIndex="0">
        <ComboBoxItem Tag="Automatico"  Content="Automático: Store, luego SteamGridDB, luego las del juego"/>
        <ComboBoxItem Tag="Store"       Content="Solo Microsoft Store"/>
        <ComboBoxItem Tag="SteamGridDB" Content="Solo SteamGridDB"/>
        <ComboBoxItem Tag="Local"       Content="Solo imágenes del propio juego"/>
      </ComboBox>

      <WrapPanel Margin="0,0,0,12">
        <Button Name="BtnPreparar" Content="1. Preparar carátulas" Background="#FF2E3440"/>
        <Button Name="BtnAnadir" Content="2. Añadir a Steam" IsEnabled="False" Background="#FF7A1418"/>
        <Button Name="BtnQuitar" Content="Quitar de Steam" IsEnabled="False"/>
      </WrapPanel>
      <!-- solo mientras se preparan las caratulas; lo que va haciendo sale en el registro -->
      <ProgressBar Name="PrgPreparar" Height="3" Margin="0,-6,0,9" IsIndeterminate="True"
                   Visibility="Collapsed" Background="#FF1E2127" Foreground="#FFDC1E23" BorderThickness="0"/>

      <TextBlock Name="TxtOrigenArte" FontSize="11" Foreground="#FF8A909B" Margin="0,0,0,6" TextWrapping="Wrap"/>
      <!-- Con las caratulas preparadas, cada imagen (menos el icono, que sale de ellas) se pulsa
           (o se elige con el teclado) para cambiarla en la galeria. El Tag es el hueco: p, cap,
           hero o logo. Sin nada preparado estan desactivados (Update-Botones). -->
      <WrapPanel>
        <StackPanel Margin="0,0,14,10">
          <TextBlock Text="Portada 600x900" FontSize="10" Foreground="#FF6E747E"/>
          <Button Name="BtnPortada" Tag="p" AutomationProperties.Name="Portada" Style="{StaticResource Hueco}" Margin="0,3,0,0" IsEnabled="False">
            <Image Name="ImgPortada" Width="140" Height="210" Stretch="UniformToFill"/>
          </Button>
        </StackPanel>
        <StackPanel Margin="0,0,14,10">
          <TextBlock Text="Cápsula 460x215" FontSize="10" Foreground="#FF6E747E"/>
          <Button Name="BtnCapsula" Tag="cap" AutomationProperties.Name="Cápsula" Style="{StaticResource Hueco}" Margin="0,3,0,10" IsEnabled="False">
            <Image Name="ImgCapsula" Width="195" Height="91" Stretch="UniformToFill"/>
          </Button>
          <TextBlock Text="Hero 1920x620" FontSize="10" Foreground="#FF6E747E"/>
          <Button Name="BtnHero" Tag="hero" AutomationProperties.Name="Hero" Style="{StaticResource Hueco}" Margin="0,3,0,0" IsEnabled="False">
            <Image Name="ImgHero" Width="280" Height="90" Stretch="UniformToFill"/>
          </Button>
        </StackPanel>
        <StackPanel Margin="0,0,0,10">
          <TextBlock Text="Logo" FontSize="10" Foreground="#FF6E747E"/>
          <Button Name="BtnLogo" Tag="logo" AutomationProperties.Name="Logo" Style="{StaticResource Hueco}" Margin="0,3,0,10" IsEnabled="False">
            <Image Name="ImgLogo" Width="150" Height="70" Margin="6" Stretch="Uniform"/>
          </Button>
          <TextBlock Text="Icono" FontSize="10" Foreground="#FF6E747E"/>
          <Border BorderBrush="#FF3A3F49" BorderThickness="1" Margin="0,3,0,0" Background="#FF111316"
                  HorizontalAlignment="Left">
            <Image Name="ImgIcono" Width="48" Height="48" Margin="4" Stretch="Uniform"/>
          </Border>
        </StackPanel>
      </WrapPanel>
    </StackPanel>
    </ScrollViewer>

    <!-- registro -->
    <Grid Name="PanelRegistro" Grid.Row="2" Grid.ColumnSpan="2" Margin="0,12,0,0">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>
      <WrapPanel Grid.Row="0">
        <CheckBox Name="ChkBigPicture" Content="Reabrir Steam en Big Picture" IsChecked="True"/>
        <CheckBox Name="ChkReemplazar" Content="Reemplazar si ya existe"/>
      </WrapPanel>
      <TextBox Name="TxtLog" Grid.Row="1" Margin="0,6,0,0" IsReadOnly="True" FontFamily="Consolas"
               FontSize="11" Background="#FF111316" Foreground="#FF9CD1A0" BorderBrush="#FF2A2E36"
               VerticalScrollBarVisibility="Auto" TextWrapping="NoWrap"/>
    </Grid>

    <!-- Modo sencillo: en lugar de la lista, el detalle y el registro (que se ocultan), solo los
         juegos de las tiendas, en grande, y anadir o quitar los marcados. Lo demas (origen de las
         caratulas, Big Picture, reemplazar) sale de lo puesto en el modo avanzado. Los mismos
         objetos que LstJuegos: las marcas son las mismas en los dos modos. -->
    <Grid Name="PanelSencillo" Grid.Row="1" Grid.RowSpan="2" Grid.ColumnSpan="2" Visibility="Collapsed">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <TextBlock Grid.Row="0" FontSize="14" Foreground="#FFB9BEC7" TextWrapping="Wrap" Margin="0,0,0,8"
                 Text="Marca los juegos (A o X con el mando, Espacio o Enter con el teclado) y pulsa «Añadir marcados». Para todo lo demás, el modo avanzado."/>
      <ListBox Name="LstSencillo" Grid.Row="1" Background="#FF1E2127" BorderBrush="#FF3A3F49"
               Foreground="#FFE6E8EC" ScrollViewer.HorizontalScrollBarVisibility="Disabled">
        <ListBox.ItemTemplate>
          <DataTemplate>
            <DockPanel Margin="6,8">
              <CheckBox DockPanel.Dock="Left" IsChecked="{Binding Marcado, Mode=TwoWay}" VerticalAlignment="Center"
                        Margin="0,0,16,0" Focusable="False">
                <CheckBox.LayoutTransform>
                  <ScaleTransform ScaleX="1.6" ScaleY="1.6"/>
                </CheckBox.LayoutTransform>
              </CheckBox>
              <StackPanel>
                <TextBlock Text="{Binding Nombre}" FontSize="20"/>
                <TextBlock FontSize="13" Foreground="#FF8A909B">
                  <Run Text="{Binding Fuente, Mode=OneWay}"/><Run Text="   "/><Run Text="{Binding Marca, Mode=OneWay}"/>
                </TextBlock>
              </StackPanel>
            </DockPanel>
          </DataTemplate>
        </ListBox.ItemTemplate>
      </ListBox>
      <StackPanel Grid.Row="2" Margin="0,12,0,0">
        <ProgressBar Name="PrgSencillo" Height="3" Margin="0,0,0,9" IsIndeterminate="True"
                     Visibility="Collapsed" Background="#FF1E2127" Foreground="#FFDC1E23" BorderThickness="0"/>
        <WrapPanel>
          <!-- mientras se preparan las caratulas es el de cancelar (Get-BotonTarea) -->
          <Button Name="BtnAnadirSencillo" Content="Añadir marcados" Style="{StaticResource Grande}" IsEnabled="False"
                  Background="#FF7A1418"/>
          <Button Name="BtnQuitarSencillo" Content="Quitar marcados" Style="{StaticResource Grande}" IsEnabled="False"/>
        </WrapPanel>
        <!-- la ultima linea del registro, y debajo el aviso si algo ha ido mal (Set-AvisoSencillo) -->
        <TextBlock Name="TxtEstadoSencillo" FontSize="13" Foreground="#FF9CD1A0" TextTrimming="CharacterEllipsis"
                   Margin="0,10,0,0" MinHeight="17"/>
        <TextBlock Name="TxtAvisoSencillo" FontSize="13" Foreground="#FFE0B060" TextWrapping="Wrap"
                   Margin="0,4,0,0"/>
      </StackPanel>
    </Grid>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$win = [Windows.Markup.XamlReader]::Load($reader)
Add-EstiloFoco $win
# Con 668 de alto la vista previa se cortaba (el hero y el icono, bajo la barra). Mas alta,
# pero sin salirse de la pantalla: un portatil de 1080p al 125 % deja ~820 utiles
$areaUtil = [System.Windows.SystemParameters]::WorkArea
if ($win.Height -gt $areaUtil.Height) { $win.Height = $areaUtil.Height }
if ($win.Width -gt $areaUtil.Width) { $win.Width = $areaUtil.Width }

$ctl = @{}
foreach ($n in @('TxtVersion','TxtSteam','BtnVaporeraSteam','BtnBigPicture','BtnAjustes','TxtBuscar','ChkRecientes','ChkApps','BtnRefrescar','BtnExaminar','LstJuegos',
                 'TxtNombre','TxtExe','TxtOpciones','TxtDetalle','TxtElegido','BtnOlvidar','CmbOrigenArte',
                 'BtnPreparar','BtnAnadir','BtnQuitar','PrgPreparar','TxtOrigenArte',
                 'ImgPortada','ImgCapsula','ImgHero','ImgLogo','ImgIcono','BtnPortada','BtnCapsula','BtnHero','BtnLogo',
                 'ChkBigPicture','ChkReemplazar','TxtLog','TxtMarcados','BtnAnadirMarcados','BtnQuitarMarcados','BtnDesmarcar',
                 'BtnModo','PanelLista','PanelDetalle','PanelRegistro','PanelSencillo','LstSencillo','BtnAnadirSencillo',
                 'BtnQuitarSencillo','PrgSencillo','TxtEstadoSencillo','TxtAvisoSencillo')) {
    $ctl[$n] = $win.FindName($n)
}

$script:Steam = Get-SteamInfo
$script:Todos = @()        # lo que se ve en la lista: los de 'Examinar' y detras lo detectado
$script:Detectados = @()   # lo que devolvio la ultima busqueda
$script:Manuales = @()     # los elegidos con 'Examinar .exe...', que la busqueda no encuentra
$script:Preparado = $null
$script:CambiandoJuego = $false   # true mientras la seleccion rellena los cuadros de texto
$script:Ocupado = $false          # true mientras hay una operacion larga en marcha
$script:OcupadoBoton = $null      # el boton que ha cambiado de texto y el que tenia antes
$script:FocoAntes = $null         # el control con el foco al empezar la operacion larga (Restore-Foco)
$script:Tarea = $null             # la preparacion en segundo plano que tiene la ventana ocupada
# Todas las de segundo plano sin recoger: la de arriba y las canceladas que aun no han acabado
$script:Tareas = New-Object System.Collections.ArrayList
$script:DentroDeTareas = $false   # Update-Tareas en marcha: que no se meta otro tic
$script:Galeria = $null           # la ventana de elegir imagen, mientras esta abierta
$script:Visibles = New-Object System.Collections.ArrayList   # los de la lista con el filtro de ahora
$script:Lote = $null              # los juegos de "Anadir marcados" mientras se preparan
# La propia Vaporera en shortcuts.vdf (Get-EstadoVaporera): 'esta', 'falta', 'cambiada' (con
# otra ruta) o '' sin Steam. La pone Update-Todos y la mira Update-Botones.
$script:VaporeraEnSteam = ''
# El modo sencillo (Set-ModoSencillo): se guarda en config.json y se arranca en el ultimo usado
$script:Sencillo = $false
# Por que se cierra la ventana al acabar la operacion ('' si no se cierra): lo pide la operacion
# (Complete-CambioSteam) y lo hace Exit-Ocupado (ocupada, Add_Closing no la deja cerrarse)
$script:CerrarAlAcabar = ''
# Los juegos elegidos a mano en la galeria, lo guardado en config.json: se lee aqui y solo
# cambia al guardar uno (Save-Elegido) o al olvidarlo (Invoke-Olvidar). Si no se puede leer,
# se arranca igual, sin ninguno.
$script:Elegidos = @()
try { $script:Elegidos = @(Get-JuegosElegidos) }
catch { Write-Registro "No he podido leer los juegos elegidos a mano: $($_.Exception.Message)" }

# Escribe en el registro y en la ventana SIN bombear mensajes. Es lo que se usa donde no se
# puede dejar que WPF atienda nada en medio: el tic del reloj de las tareas y el cierre.
function Write-LogVentana {
    param([string]$Texto)
    Write-Registro $Texto
    $ctl.TxtLog.AppendText($Texto + "`r`n")
    $ctl.TxtLog.ScrollToEnd()
    # el modo sencillo no tiene registro: ensena la ultima linea
    if ($Texto.Trim()) { $ctl.TxtEstadoSencillo.Text = $Texto.Trim() }
}

function Add-Log {
    param([string]$Texto)
    Write-LogVentana $Texto
    Update-Interfaz
}
$LogGui = { param($m) Add-Log $m }

function Update-Interfaz {
    $frame = New-Object Windows.Threading.DispatcherFrame
    [void][Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
        [Windows.Threading.DispatcherPriority]::Background, [action]{ $frame.Continue = $false })
    [Windows.Threading.Dispatcher]::PushFrame($frame)
}

# Lo que se desactiva mientras dura una operacion larga. El cuadro del registro NO esta en la
# lista: es lo unico que el usuario mira mientras espera, y desactivado se lee gris.
$ControlesInteractivos = @('BtnVaporeraSteam','BtnBigPicture','BtnAjustes','TxtBuscar','ChkRecientes','ChkApps','BtnRefrescar','BtnExaminar',
                           'LstJuegos','TxtNombre','TxtOpciones','BtnOlvidar','CmbOrigenArte','BtnPreparar','BtnAnadir',
                           'BtnQuitar','ChkBigPicture','ChkReemplazar','BtnAnadirMarcados','BtnQuitarMarcados',
                           'BtnDesmarcar','BtnPortada','BtnCapsula','BtnHero','BtnLogo',
                           'BtnModo','LstSencillo','BtnAnadirSencillo','BtnQuitarSencillo')

# El boton que hace de "Cancelar" mientras hay una tarea en segundo plano: el de preparar o, en
# el modo sencillo (donde no se ve), el de anadir. El modo no cambia con la ventana ocupada.
function Get-BotonTarea {
    if ($script:Sencillo) { return 'BtnAnadirSencillo' }
    return 'BtnPreparar'
}

# Un solo sitio decide que botones estan vivos. Antes lo hacia cada evento por su cuenta y no
# se puede combinar con Invoke-Ocupado, que al terminar reactiva todo a la vez.
function Update-Botones {
    # En plena operacion todo esta desactivado; Exit-Ocupado lo vuelve a llamar al terminar.
    # La excepcion: mientras se preparan las caratulas en segundo plano, el boton de preparar
    # (o el de anadir, en el modo sencillo) es el de cancelar.
    if ($script:Ocupado) {
        $cancelar = $ctl[(Get-BotonTarea)]
        $cancelar.IsEnabled = ($null -ne $script:Tarea)
        # Al apagarse todo, el foco se ha perdido (el de preparar se apaga y se vuelve a
        # encender). Va al de cancelar, lo unico que se puede pulsar: sin foco, el teclado no
        # llegaria a el.
        if ($script:Tarea -and $win.IsActive -and -not (Test-ControlUsable ([Windows.Input.Keyboard]::FocusedElement))) {
            [void]$cancelar.Focus()
        }
        return
    }
    $ctl.BtnPreparar.IsEnabled = [bool]$script:Steam
    $ctl.BtnAnadir.IsEnabled   = ([bool]$script:Steam -and $null -ne $script:Preparado)
    # solo tiene sentido con un juego que ya tenga acceso directo (la marca 'YA EN STEAM')
    $sel = $ctl.LstJuegos.SelectedItem
    $ctl.BtnQuitar.IsEnabled   = ([bool]$script:Steam -and $null -ne $sel -and [bool]$sel.YaEnSteam)
    # los huecos de la vista previa abren la galeria, que necesita algo preparado
    foreach ($h in $HuecosVista.Values) { $ctl[$h.Boton].IsEnabled = ($null -ne $script:Preparado) }
    $ctl.BtnBigPicture.IsEnabled = [bool]$script:Steam
    # la propia Vaporera: el boton solo sale si falta en Steam o esta con otra ruta
    $ctl.BtnVaporeraSteam.IsEnabled = [bool]$script:Steam
    if ($script:VaporeraEnSteam -eq 'falta') {
        $ctl.BtnVaporeraSteam.Content = 'Añadir Vaporera a Steam'
        $ctl.BtnVaporeraSteam.Visibility = 'Visible'
    } elseif ($script:VaporeraEnSteam -eq 'cambiada') {
        $ctl.BtnVaporeraSteam.Content = 'Actualizar Vaporera en Steam'
        $ctl.BtnVaporeraSteam.Visibility = 'Visible'
    } else {
        $ctl.BtnVaporeraSteam.Visibility = 'Collapsed'
    }

    # los marcados: la cuenta va en el boton y en la linea de encima
    $marc = @(Get-Marcados)
    $enSteam = @($marc | Where-Object { $_.YaEnSteam }).Count
    $ctl.BtnAnadirMarcados.Content = $(if ($marc.Count) { "Añadir ($($marc.Count))" } else { 'Añadir marcados' })
    $ctl.BtnQuitarMarcados.Content = $(if ($enSteam) { "Quitar ($enSteam)" } else { 'Quitar marcados' })
    $ctl.BtnAnadirMarcados.IsEnabled = ([bool]$script:Steam -and $marc.Count -gt 0)
    $ctl.BtnQuitarMarcados.IsEnabled = ([bool]$script:Steam -and $enSteam -gt 0)
    $ctl.BtnDesmarcar.IsEnabled      = ($marc.Count -gt 0)
    # los del modo sencillo (Get-Marcados ya cuenta solo los juegos de las tiendas)
    $ctl.BtnAnadirSencillo.Content = $(if ($marc.Count) { "Añadir marcados ($($marc.Count))" } else { 'Añadir marcados' })
    $ctl.BtnQuitarSencillo.Content = $(if ($enSteam) { "Quitar marcados ($enSteam)" } else { 'Quitar marcados' })
    $ctl.BtnAnadirSencillo.IsEnabled = $ctl.BtnAnadirMarcados.IsEnabled
    $ctl.BtnQuitarSencillo.IsEnabled = $ctl.BtnQuitarMarcados.IsEnabled
    if (-not $marc.Count) {
        $ctl.TxtMarcados.Text = 'Marca las casillas para añadir o quitar varios juegos cerrando Steam una sola vez.'
    } else {
        $texto = "$($marc.Count) marcados"
        if ($enSteam) { $texto += ", $enSteam ya en Steam" }
        $ocultos = @($marc | Where-Object { -not $script:Visibles.Contains($_) }).Count
        if ($ocultos) { $texto += " ($ocultos no se ven con el filtro)" }
        $ctl.TxtMarcados.Text = "$texto."
    }
    Update-Elegido
}

# Los marcados con los que se trabaja. En el modo sencillo, solo los juegos de las tiendas: un
# programa reciente marcado en el avanzado no se ve alli y no se tiene que anadir sin saberlo
# (sigue marcado para cuando se vuelva al avanzado).
function Get-Marcados {
    return @($script:Todos | Where-Object { $_ -and $_.Marcado -and (-not $script:Sencillo -or (Test-EsJuego $_)) })
}

# Lo que sale en el modo sencillo: los juegos de las tiendas. Ni las apps de la Store, ni los
# programas recientes, ni los elegidos con "Examinar .exe...": para eso esta el avanzado.
$FuentesJuego = @('Xbox / Game Pass', 'Epic Games', 'GOG', 'Ubisoft Connect')
function Test-EsJuego {
    param($Juego)
    return ($FuentesJuego -contains [string]$Juego.Fuente)
}

# El binding de un pscustomobject no avisa de los cambios hechos por codigo (ni de los hechos en
# la otra lista): Items.Refresh vuelve a pintar las casillas sin perder la seleccion
function Update-Casillas {
    $ctl.LstJuegos.Items.Refresh()
    $ctl.LstSencillo.Items.Refresh()
}

function Clear-Marcados {
    foreach ($j in @($script:Todos)) { if ($j -and $j.Marcado) { $j.Marcado = $false } }
    Update-Casillas
    Update-Botones
}

# Marca la ventana como ocupada y desactiva los controles. Devuelve $false si ya lo estaba
# (nunca anidado). $Boton cambia de texto mientras dure, para que se vea que esta trabajando.
# Cada Enter-Ocupado que devuelva $true necesita su Exit-Ocupado: lo normal es Invoke-Ocupado,
# que los empareja; por separado solo cuando lo largo sigue en segundo plano (Start-Preparar).
function Enter-Ocupado {
    param([string]$Boton = '', [string]$TextoOcupado = '')
    if ($script:Ocupado) { return $false }
    $script:Ocupado = $true
    $script:FocoAntes = [Windows.Input.FocusManager]::GetFocusedElement($win)
    $script:OcupadoBoton = $null
    if ($Boton -and $TextoOcupado) {
        $script:OcupadoBoton = @{ Nombre = $Boton; Texto = $ctl[$Boton].Content }
        $ctl[$Boton].Content = $TextoOcupado
    }
    foreach ($n in $ControlesInteractivos) { $ctl[$n].IsEnabled = $false }
    # el aviso de lo que fallo la vez anterior ya no viene a cuento
    Set-AvisoSencillo ''
    Update-Botones
    return $true
}

function Exit-Ocupado {
    # el orden importa: la marca primero, para no dejarla puesta si algo falla al reactivar
    $script:Ocupado = $false
    if ($script:OcupadoBoton) {
        $ctl[$script:OcupadoBoton.Nombre].Content = $script:OcupadoBoton.Texto
        $script:OcupadoBoton = $null
    }
    foreach ($n in $ControlesInteractivos) { $ctl[$n].IsEnabled = $true }
    Update-Botones
    Restore-Foco
    # Despues de soltar la ventana, y en diferido: el Close tiene que llegar cuando ya no hay
    # nada en marcha, o Add_Closing lo cancela
    if ($script:CerrarAlAcabar) {
        [void]$win.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Background, [action]{
            $motivo = $script:CerrarAlAcabar
            $script:CerrarAlAcabar = ''
            if ($script:Ocupado -or -not $motivo) { return }
            Write-Registro $motivo
            $win.Close()
        })
    }
}

# --- el modo sencillo --------------------------------------------------
# Sin registro a la vista, lo que ha ido mal se dice aqui (y el detalle, en el registro del
# modo avanzado). Se borra al empezar la siguiente operacion (Enter-Ocupado).
function Set-AvisoSencillo {
    param([string]$Texto)
    $ctl.TxtAvisoSencillo.Text = $Texto
}

# Que se hace al acabar de anadir o quitar. Si ha ido bien, la Vaporera se cierra:
#  - siempre que Steam se haya vuelto a abrir en Big Picture (en los dos modos): la taparia y
#    con el mando no se podria volver a ella. $BigPicture lo dice quien llama: al anadir Steam
#    se reabre siempre; al quitar, solo si estaba abierto.
#  - en el modo sencillo, ademas, tras anadir ($Anadir), aunque no sea en Big Picture.
# Si no ha ido bien se queda abierta para leer que ha pasado: en el sencillo, con $Aviso debajo
# de los botones (en el avanzado ya esta el registro).
function Complete-CambioSteam {
    param([bool]$Bien, [bool]$BigPicture = $false, [switch]$Anadir, [string]$Aviso = '')
    if ($Bien) {
        if ($BigPicture) { $script:CerrarAlAcabar = 'Steam se ha vuelto a abrir en Big Picture: cierro la Vaporera.' }
        elseif ($script:Sencillo -and $Anadir) { $script:CerrarAlAcabar = 'Modo sencillo: añadido sin problemas, cierro la Vaporera.' }
        return
    }
    if ($script:Sencillo -and $Aviso) { Set-AvisoSencillo "$Aviso El detalle está en el registro del modo avanzado." }
}

# Cambia de modo. El sencillo oculta la lista, el detalle y el registro (siguen ahi, con lo
# puesto, que es lo que usa al anadir) y ensena PanelSencillo. $Guardar lo apunta en config.json
# para arrancar asi la proxima vez.
function Set-ModoSencillo {
    param([bool]$Sencillo, [switch]$Guardar)
    $script:Sencillo = $Sencillo
    $avanzado = $(if ($Sencillo) { 'Collapsed' } else { 'Visible' })
    foreach ($n in @('PanelLista', 'PanelDetalle', 'PanelRegistro', 'BtnAjustes')) { $ctl[$n].Visibility = $avanzado }
    $ctl.PanelSencillo.Visibility = $(if ($Sencillo) { 'Visible' } else { 'Collapsed' })
    if ($Sencillo) {
        $ctl.BtnModo.Content = 'Modo avanzado'
        $ctl.BtnModo.ToolTip = 'Vuelve a la ventana completa: elegir carátulas, cambiar el nombre, otros programas...'
    } else {
        $ctl.BtnModo.Content = 'Modo sencillo'
        $ctl.BtnModo.ToolTip = 'Solo los juegos, en grande, para marcarlos y añadirlos o quitarlos (pensado para el mando)'
    }
    Set-AvisoSencillo ''
    # las marcas hechas en la otra lista
    Update-Casillas
    Update-Botones
    if ($Guardar) {
        try { Set-ConfigValor -Nombre 'ModoSencillo' -Valor $Sencillo }
        catch { Write-RegistroError -Contexto 'guardar el modo' -Fallo $_ }
    }
    # el foco estaba en lo que se acaba de ocultar (o en el boton del modo): a la lista
    $win.UpdateLayout()
    $destino = Get-FocoLista
    [Windows.Input.FocusManager]::SetFocusedElement($win, $destino)
    if ($win.IsActive) { [void]$destino.Focus() }
}

# Desactivar el control que tiene el foco se lo quita, y al reactivarlo nadie se lo devuelve:
# sin esto, tras cada operacion larga el teclado empezaria otra vez por arriba. Vuelve al que
# lo tenia antes o, si ya no se puede (el boton de anadir se apaga al terminar), a la lista.
# Si mientras tanto el usuario lo ha puesto en el registro (sigue activo), se queda alli.
# Con la ventana detras (Steam en Big Picture) se deja apuntado para cuando vuelva delante.
function Restore-Foco {
    $antes = $script:FocoAntes
    $script:FocoAntes = $null
    $ahora = [Windows.Input.FocusManager]::GetFocusedElement($win)
    # en el de preparar (o el de anadir, en sencillo) lo ha dejado Update-Botones, para
    # cancelar: eso no cuenta
    if ((Test-ControlUsable $ahora) -and $ahora -ne $antes -and $ahora -ne $ctl[(Get-BotonTarea)]) { return }
    $destino = $antes
    if (-not (Test-ControlUsable $destino)) { $destino = Get-FocoLista }
    [Windows.Input.FocusManager]::SetFocusedElement($win, $destino)
    if ($win.IsActive) { [void]$destino.Focus() }
}

# Donde va el foco cuando no hay otro sitio: el juego seleccionado o, sin el, la lista (la del
# modo en el que se este)
function Get-FocoLista {
    $lista = $(if ($script:Sencillo) { $ctl.LstSencillo } else { $ctl.LstJuegos })
    $sel = $lista.SelectedItem
    if ($null -ne $sel) {
        $c = $lista.ItemContainerGenerator.ContainerFromItem($sel)
        if (Test-ControlUsable $c) { return $c }
    }
    return $lista
}

# Un control de la ventana principal que puede recibir el foco ahora mismo
function Test-ControlUsable {
    param($Control)
    if ($Control -isnot [Windows.UIElement] -or $Control -eq $win) { return $false }
    if (-not ($Control.IsEnabled -and $Control.IsVisible -and $Control.Focusable)) { return $false }
    return ([Windows.Window]::GetWindow($Control) -eq $win)
}

# Envoltorio de toda operacion larga lanzada desde un evento. Add-Log llama a Update-Interfaz,
# que es una bomba de mensajes: sin esto WPF atiende clics en Refrescar, Examinar, las casillas
# o la lista DENTRO de la escritura del VDF, con Steam cerrado y el fichero a medio escribir.
function Invoke-Ocupado {
    param(
        [Parameter(Mandatory)][scriptblock]$Accion,
        [string]$Boton = '',
        [string]$TextoOcupado = ''
    )
    if (-not (Enter-Ocupado -Boton $Boton -TextoOcupado $TextoOcupado)) { return }
    try { & $Accion }
    finally { Exit-Ocupado }
}

function Get-ImagenSegura {
    param([string]$Ruta)
    if (-not $Ruta -or -not (Test-Path -LiteralPath $Ruta)) { return $null }
    $bi = New-Object Windows.Media.Imaging.BitmapImage
    $bi.BeginInit()
    $bi.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bi.CreateOptions = [Windows.Media.Imaging.BitmapCreateOptions]::IgnoreImageCache
    $bi.UriSource = New-Object Uri($Ruta)
    $bi.EndInit()
    return $bi
}

function Update-Lista {
    $filtro = $ctl.TxtBuscar.Text.Trim()
    $vista = $script:Todos
    if ($filtro) { $vista = $vista | Where-Object { (Test-Contiene $_.Nombre $filtro) -or (Test-Contiene $_.Exe $filtro) } }
    $ctl.LstJuegos.ItemsSource = @($vista)
    # la del modo sencillo no tiene busqueda: todos los juegos de las tiendas
    $ctl.LstSencillo.ItemsSource = @($script:Todos | Where-Object { $_ -and (Test-EsJuego $_) })
    # para avisar de los marcados que el filtro esconde
    $script:Visibles = New-Object System.Collections.ArrayList
    foreach ($j in @($vista)) { if ($j) { [void]$script:Visibles.Add($j) } }
    Update-Botones
}

# Rehace la lista y la marca 'YA EN STEAM' con el mismo criterio que usa la escritura del
# VDF (Find-ShortcutDuplicado): nombre igual, o exe con las mismas opciones.
function Update-Todos {
    $existentes = @()
    if ($script:Steam) { $existentes = @(Get-ShortcutsExistentes -Ruta $script:Steam.Shortcuts) }
    $script:VaporeraEnSteam = ''
    if ($script:Steam) { $script:VaporeraEnSteam = Get-EstadoVaporera $existentes }
    foreach ($j in (@($script:Manuales) + @($script:Detectados))) {
        $dup = Find-ShortcutDuplicado -Existentes $existentes -Nombre $j.Nombre -Exe $j.Exe -LaunchOptions $j.LaunchOptions
        $j.YaEnSteam = ($null -ne $dup)
        $marca = if ($j.YaEnSteam) { 'YA EN STEAM' } else { '' }
        $j | Add-Member -NotePropertyName Marca -NotePropertyValue $marca -Force
        # la casilla de la lista; sin -Force, que no se pierda la de uno ya marcado
        if ($null -eq $j.PSObject.Properties['Marcado']) {
            $j | Add-Member -NotePropertyName Marcado -NotePropertyValue $false
        }
    }
    # los de 'Examinar' van delante: el usuario los acaba de elegir y no salen de la busqueda
    $script:Todos = @($script:Manuales) +
                    @($script:Detectados | Sort-Object @{Expression={$_.YaEnSteam}}, @{Expression={$_.Fuente}}, @{Expression={$_.Nombre}})
    Update-Lista
}

function Update-Deteccion {
  try {
    # la busqueda crea los objetos de nuevo: las casillas marcadas se recuperan por exe y opciones
    $marcados = @{}
    # todos, tambien los que el modo sencillo no ensena (Get-Marcados se los saltaria)
    foreach ($j in @($script:Todos | Where-Object { $_ -and $_.Marcado })) { $marcados["$($j.Exe)|$($j.LaunchOptions)"] = $true }
    $ctl.LstJuegos.ItemsSource = $null
    $ctl.LstSencillo.ItemsSource = $null
    Add-Log 'Buscando juegos instalados...'
    $script:Detectados = @(Get-TodosLosJuegos -IncluirRecientes:([bool]$ctl.ChkRecientes.IsChecked) `
                                              -IncluirApps:([bool]$ctl.ChkApps.IsChecked) -Log $LogGui)
    foreach ($j in $script:Detectados) {
        if ($marcados.ContainsKey("$($j.Exe)|$($j.LaunchOptions)")) {
            $j | Add-Member -NotePropertyName Marcado -NotePropertyValue $true -Force
        }
    }
    Update-Todos
    $texto = "Detectados {0} títulos ({1} ya están en Steam)." -f
                @($script:Detectados).Count, (@($script:Detectados | Where-Object YaEnSteam)).Count
    if (@($script:Manuales).Count) { $texto += " Y {0} elegidos a mano." -f @($script:Manuales).Count }
    Add-Log $texto
  } catch {
    Add-Log "ERROR detectando juegos: $($_.Exception.Message)"
    Write-RegistroError -Contexto 'detectar juegos' -Fallo $_
  }
}

# Los huecos de la vista previa: su imagen, su boton (el recuadro que se pulsa) y como se llaman
$HuecosVista = [ordered]@{
    p    = @{ Img = 'ImgPortada'; Boton = 'BtnPortada'; Nombre = 'portada' }
    cap  = @{ Img = 'ImgCapsula'; Boton = 'BtnCapsula'; Nombre = 'cápsula' }
    hero = @{ Img = 'ImgHero';    Boton = 'BtnHero';    Nombre = 'hero' }
    logo = @{ Img = 'ImgLogo';    Boton = 'BtnLogo';    Nombre = 'logo' }
}

# Pinta la vista previa con lo que haya en $script:Preparado (o la vacia si no hay nada).
# Los recuadros solo parecen pulsables cuando hay algo preparado.
function Update-VistaPrevia {
    $p = $script:Preparado
    foreach ($k in $HuecosVista.Keys) {
        $h = $HuecosVista[$k]
        $ruta = $null
        if ($p) { $ruta = $p.Rutas[$k] }
        $ctl[$h.Img].Source = Get-ImagenSegura $ruta
        if ($p) {
            $ctl[$h.Boton].Cursor = [Windows.Input.Cursors]::Hand
            $ctl[$h.Boton].ToolTip = "Pulsa para elegir otra imagen de $($h.Nombre)"
        } else {
            $ctl[$h.Boton].Cursor = $null
            $ctl[$h.Boton].ToolTip = $null
        }
    }
    $icono = $null
    if ($p) { $icono = $p.Rutas['icon'] }
    $ctl.ImgIcono.Source = Get-ImagenSegura $icono
}

function Clear-Preview {
    $script:Preparado = $null
    Update-Botones
    Update-VistaPrevia
    $ctl.TxtOrigenArte.Text = ''
}

# --- el juego elegido a mano, recordado --------------------------------
# El juego escogido en la galeria ("Elegir otro juego...") se guarda en config.json
# (lib\Config.ps1) y la proxima vez que se preparan las caratulas de ese juego se usa sin buscar
# por el nombre. Encima del desplegable del origen sale cual es, con el boton de olvidarlo.

# El origen del desplegable
function Get-OrigenArte {
    $origenArte = [string]$ctl.CmbOrigenArte.SelectedItem.Tag
    if (-not $origenArte) { $origenArte = 'Automatico' }
    return $origenArte
}

# El juego del que se habla: el de la vista previa (Refrescar deja la lista sin seleccion y lo
# preparado sigue ahi) o, sin nada preparado, el seleccionado
function Get-JuegoActual {
    if ($script:Preparado) { return $script:Preparado.Juego }
    return $ctl.LstJuegos.SelectedItem
}

# El elegido a mano que hay guardado para $Juego, o $null. El juego se reconoce por su exe y
# por las opciones con las que se detecto, no por las del cuadro de texto, que se editan.
function Get-ElegidoGuardado {
    param($Juego)
    if (-not $Juego) { return $null }
    return (Find-JuegoElegido -Lista $script:Elegidos -Exe $Juego.Exe -Opciones ([string]$Juego.OpcionesOrigen))
}

# Con que juego hay que preparar las caratulas de $Juego: con el elegido guardado, si el
# origen lo deja. Devuelve Elegido ($null si no hay o no vale) y Aviso, lo que hay que decir
# en el registro ('' si no hay nada guardado).
function Get-ElegidoParaPreparar {
    param($Juego, [string]$OrigenArte)
    $e = Get-ElegidoGuardado $Juego
    if (-not $e) { return [pscustomobject]@{ Elegido = $null; Aviso = '' } }
    if (Test-ElegidoConOrigen -Fuente $e.Fuente -OrigenArte $OrigenArte) {
        return [pscustomobject]@{
            Elegido = $e
            Aviso   = "  con el juego elegido a mano que hay guardado: '$($e.Titulo)' ($($e.Fuente)). No se busca por el nombre; para volver a hacerlo, «Olvidar»."
        }
    }
    return [pscustomobject]@{
        Elegido = $null
        Aviso   = "  hay un juego elegido a mano ('$($e.Titulo)', $($e.Fuente)), pero no se usa: el origen está en «$($ctl.CmbOrigenArte.SelectedItem.Content)»."
    }
}

# Los dos parametros de New-CaratulasSteam para el juego elegido a mano (vacios si no hay)
function Get-IdsElegido {
    param($Elegido)
    $ids = @{ StoreIdElegido = ''; SgdbIdElegido = '' }
    if ($Elegido) {
        if ($Elegido.Fuente -eq 'SteamGridDB') { $ids.SgdbIdElegido = [string]$Elegido.Id }
        else { $ids.StoreIdElegido = [string]$Elegido.Id }
    }
    return $ids
}

# Guarda en config.json el juego elegido a mano para $Juego. Devuelve lo que hay que anadir al
# registro: si no se puede guardar, la eleccion vale igual para esta preparacion.
function Save-Elegido {
    param($Juego, $Elegido)
    try {
        $script:Elegidos = @(Set-JuegoElegido -Exe $Juego.Exe -Opciones ([string]$Juego.OpcionesOrigen) `
                                -Fuente $Elegido.Fuente -Id ([string]$Elegido.Id) -Titulo ([string]$Elegido.Titulo))
        return 'Queda guardado para las próximas veces.'
    } catch {
        Write-RegistroError -Contexto 'guardar el juego elegido' -Fallo $_
        return "No he podido guardarlo ($($_.Exception.Message)): solo vale para esta vez."
    }
}

# La linea de encima del desplegable del origen: el elegido a mano del juego de ahora y el
# boton de olvidarlo. Avisa si con el origen del desplegable no se va a usar.
function Update-Elegido {
    $e = Get-ElegidoGuardado (Get-JuegoActual)
    if (-not $e) {
        $ctl.TxtElegido.Text = ''
        $ctl.TxtElegido.ToolTip = $null
        $ctl.BtnOlvidar.Visibility = 'Collapsed'
        return
    }
    $texto = "Elegido a mano: «$($e.Titulo)» ($($e.Fuente))"
    $ayuda = 'Las carátulas de este juego salen del que elegiste en la galería, sin buscar por el nombre.'
    if (-not (Test-ElegidoConOrigen -Fuente $e.Fuente -OrigenArte (Get-OrigenArte))) {
        $texto += ', no se usa con este origen'
        $ayuda = 'Con el origen de abajo no se usa el juego que elegiste en la galería. Con «Automático», sí.'
    }
    $ctl.TxtElegido.Text = $texto
    # entero, por si la linea no cabe y sale cortada
    $ctl.TxtElegido.ToolTip = "$texto.`r`n$ayuda"
    $ctl.BtnOlvidar.Visibility = 'Visible'
}

# "Olvidar": quita de config.json el elegido a mano del juego de ahora, y sus caratulas se
# vuelven a buscar por el nombre. Lo que haya en la vista previa, si salio de el, ya no vale.
function Invoke-Olvidar {
    $j = Get-JuegoActual
    $e = Get-ElegidoGuardado $j
    if (-not $e) { return }
    try {
        $script:Elegidos = @(Remove-JuegoElegido -Exe $j.Exe -Opciones ([string]$j.OpcionesOrigen))
    } catch {
        Add-Log "ERROR olvidando el juego elegido a mano: $($_.Exception.Message)"
        Write-RegistroError -Contexto 'olvidar el juego elegido' -Fallo $_
        return
    }
    $nombre = $j.Nombre
    $rehacer = $false
    if ($script:Preparado) {
        $nombre = $script:Preparado.Nombre
        if ($script:Preparado.Elegido) { Clear-Preview; $rehacer = $true }
    }
    $texto = "Olvidado el juego elegido a mano («$($e.Titulo)»): las carátulas de '$nombre' se vuelven a buscar por el nombre."
    if ($rehacer) { $texto += ' Hay que prepararlas otra vez.' }
    Add-Log $texto
}

# Ventana de ajustes: por ahora solo la clave de SteamGridDB
function Show-Ajustes {
    [xml]$xamlAjustes = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Ajustes" Width="520" SizeToContent="Height" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner" ShowInTaskbar="False" Background="#FF15171B"
        FocusManager.FocusedElement="{Binding ElementName=TxtClave}">
  <Window.Resources>
    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="#FFE6E8EC"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#FF262A31"/>
      <Setter Property="Foreground" Value="#FFE6E8EC"/>
      <Setter Property="BorderBrush" Value="#FF3A3F49"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="Margin" Value="8,0,0,0"/>
      <Setter Property="FocusVisualStyle" Value="{DynamicResource Foco}"/>
    </Style>
  </Window.Resources>
  <StackPanel Margin="16">
    <TextBlock Text="SteamGridDB" FontSize="15" FontWeight="SemiBold"/>
    <TextBlock TextWrapping="Wrap" FontSize="11" Foreground="#FF8A909B" Margin="0,4,0,12">
      Opcional. Se usa para las carátulas de los juegos que no están en la Microsoft Store.
      La clave es gratuita: <Hyperlink Name="LnkSgdb" NavigateUri="https://www.steamgriddb.com/profile/preferences/api"
      Foreground="#FF6FA8FF">consíguela en tu perfil de SteamGridDB</Hyperlink>.
    </TextBlock>
    <TextBlock Text="Clave de API" FontSize="11" Foreground="#FF8A909B"/>
    <TextBox Name="TxtClave" Height="28" Margin="0,3,0,8" Padding="4,0" FontFamily="Consolas"
             Background="#FF1E2127" Foreground="#FFE6E8EC" BorderBrush="#FF3A3F49"
             VerticalContentAlignment="Center"/>
    <TextBlock Name="TxtEstado" FontSize="11" TextWrapping="Wrap" MinHeight="15" Margin="0,0,0,14"
               Foreground="#FF8A909B"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
      <Button Name="BtnProbar" Content="Probar"/>
      <Button Name="BtnGuardar" Content="Guardar" Background="#FF7A1418" IsDefault="True"/>
      <Button Name="BtnCancelar" Content="Cancelar" IsCancel="True"/>
    </StackPanel>
  </StackPanel>
</Window>
'@
    $dlg = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xamlAjustes))
    Add-EstiloFoco $dlg
    $dlg.Owner = $win
    if ($script:IconoVentana) { $dlg.Icon = $script:IconoVentana }
    $txtClave  = $dlg.FindName('TxtClave')
    $txtEstado = $dlg.FindName('TxtEstado')
    $brocha    = New-Object Windows.Media.BrushConverter

    $claveAntes = [string](Get-SgdbClave)
    $txtClave.Text = $claveAntes

    $dlg.FindName('LnkSgdb').Add_RequestNavigate({ Start-Process $_.Uri.AbsoluteUri })
    $dlg.FindName('BtnProbar').Add_Click({
        $clave = $txtClave.Text.Trim()
        if (-not $clave) { $txtEstado.Text = 'Escribe una clave para probarla.'; return }
        $txtEstado.Foreground = $brocha.ConvertFromString('#FF8A909B')
        $txtEstado.Text = 'Probando...'
        Update-Interfaz
        $r = Test-SgdbClave -Clave $clave
        $txtEstado.Foreground = $brocha.ConvertFromString($(if ($r.Ok) { '#FF9CD1A0' } else { '#FFE07A7A' }))
        $txtEstado.Text = $r.Mensaje
    })
    $dlg.FindName('BtnGuardar').Add_Click({ $dlg.DialogResult = $true })

    if (-not $dlg.ShowDialog()) { return }
    $clave = $txtClave.Text.Trim()
    if ($clave -eq $claveAntes) { return }
    try {
        Set-ConfigValor -Nombre 'SgdbClave' -Valor $clave
        if ($clave) { Add-Log 'Clave de SteamGridDB guardada.' } else { Add-Log 'Clave de SteamGridDB borrada.' }
    } catch {
        Add-Log "ERROR guardando los ajustes: $($_.Exception.Message)"
        Write-RegistroError -Contexto 'guardar ajustes' -Fallo $_
    }
}

# --- eventos ---------------------------------------------------------
$ctl.BtnAjustes.Add_Click({ Invoke-Ocupado { Show-Ajustes } })
$ctl.TxtBuscar.Add_TextChanged({ Update-Lista })
$ctl.BtnRefrescar.Add_Click({ Invoke-Ocupado { Update-Deteccion } })
$ctl.ChkRecientes.Add_Click({ Invoke-Ocupado { Update-Deteccion } })
$ctl.ChkApps.Add_Click({ Invoke-Ocupado { Update-Deteccion } })

$ctl.LstJuegos.Add_SelectionChanged({
    $j = $ctl.LstJuegos.SelectedItem
    # sin seleccion (el filtro de busqueda la quita) el boton de quitar se tiene que apagar
    if (-not $j) { Update-Botones; return }
    # rellenar TxtNombre dispara su TextChanged: sin esta marca avisaria de un cambio de nombre
    # que no ha hecho el usuario, solo por elegir otro juego de la lista
    $script:CambiandoJuego = $true
    try {
        $ctl.TxtNombre.Text   = $j.Nombre
        $ctl.TxtExe.Text      = $j.Exe
        $ctl.TxtOpciones.Text = $j.LaunchOptions
        $ctl.TxtDetalle.Text  = $j.Detalle + $(if ($j.YaEnSteam) { "  |  OJO: ya hay un acceso directo con este nombre." } else { '' })
    } finally { $script:CambiandoJuego = $false }
    Clear-Preview
})

$ctl.BtnExaminar.Add_Click({
    if ($script:Ocupado) { return }
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Ejecutables (*.exe)|*.exe'
    if ($dlg.ShowDialog() -eq 'OK') {
        $exe = $dlg.FileName
        $j = New-Juego -Nombre ([IO.Path]::GetFileNameWithoutExtension($exe)) -Fuente 'Manual' `
             -Exe $exe -StartDir ((Split-Path $exe -Parent) + '\') -Icono $exe `
             -Carpeta (Split-Path $exe -Parent) -Detalle 'Elegido a mano'
        $j | Add-Member -NotePropertyName Marca -NotePropertyValue '' -Force
        # aparte de lo detectado: si no, Refrescar (o anadir un juego) se los llevaba por delante
        $script:Manuales = @($j) + @($script:Manuales | Where-Object { $_.Exe -ne $exe })
        # con un filtro puesto el juego recien elegido podria no salir en la lista
        if ($ctl.TxtBuscar.Text) { $ctl.TxtBuscar.Text = '' }
        Update-Todos
        $ctl.LstJuegos.SelectedIndex = 0
        Add-Log "Añadido a la lista a mano: $($j.Nombre)"
    }
})

$ctl.TxtNombre.Add_TextChanged({
    if ($script:CambiandoJuego) { return }
    if ($script:Preparado) { Clear-Preview; Add-Log 'El nombre ha cambiado: hay que preparar las carátulas otra vez.' }
})

$ctl.BtnOlvidar.Add_Click({ Invoke-Ocupado { Invoke-Olvidar } })
# el elegido a mano puede no valer con el origen nuevo: la linea de encima lo dice
$ctl.CmbOrigenArte.Add_SelectionChanged({ Update-Elegido })

# --- trabajo en segundo plano ------------------------------------------
# Las tareas de lib\Tareas.ps1 corren en otro runspace; este reloj, en el hilo de la UI, pasa
# al registro lo que van contando y recoge las que acaban. Solo anda mientras haya alguna.
$script:Reloj = New-Object Windows.Threading.DispatcherTimer
$script:Reloj.Interval = [TimeSpan]::FromMilliseconds(100)
$script:Reloj.Add_Tick({ Update-Tareas })

# La barra de "trabajando" de la tarea en segundo plano: una en cada modo
function Set-Progreso {
    param([bool]$Visible)
    $v = $(if ($Visible) { 'Visible' } else { 'Collapsed' })
    $ctl.PrgPreparar.Visibility = $v
    $ctl.PrgSencillo.Visibility = $v
}

function Update-Tareas {
    # Lo que llama AlTerminar puede bombear mensajes (Add-Log) y con ello colar otro tic aqui
    # dentro, que recogeria la misma tarea dos veces
    if ($script:DentroDeTareas) { return }
    $script:DentroDeTareas = $true
    try {
        foreach ($t in @($script:Tareas)) {
            # antes de vaciar la cola: si acaba entre medias, su ultima linea se quedaria fuera
            $acabada = $t.Handle.IsCompleted
            $lineas = @(Get-TareaLineas $t)
            $avisos = @(Get-TareaAvisos $t)
            # lo que cuente una tarea cancelada ya no viene a cuento
            if (-not $t.Cancelada) {
                foreach ($l in $lineas) { Write-LogVentana $l }
                if ($t.Datos.AlAvisar) { foreach ($a in $avisos) { & $t.Datos.AlAvisar $t $a } }
            }
            if (-not $acabada) { continue }
            $script:Tareas.Remove($t)
            $salida = Complete-TareaFondo $t
            if (-not $salida.Cancelada -and $t.Datos.AlTerminar) { & $t.Datos.AlTerminar $t $salida }
        }
    } catch {
        Write-LogVentana "ERROR recogiendo una tarea en segundo plano: $($_.Exception.Message)"
        Write-RegistroError -Contexto 'recoger tarea' -Fallo $_
    } finally {
        $script:DentroDeTareas = $false
        if (-not $script:Tareas.Count) { $script:Reloj.Stop() }
    }
}

# "1. Preparar caratulas". Lo largo (buscar, descargar y componer las imagenes) va en segundo
# plano: la ventana sigue respondiendo y el boton pasa a ser el de cancelar. Todo lo demas se
# queda desactivado hasta que acabe, igual que con Invoke-Ocupado.
# $Elegido es el juego escogido a mano en la galeria (un resultado de Get-CandidatosJuego):
# con el no se busca por el nombre, manda sobre el origen elegido en la lista y se guarda para
# las proximas veces. Sin $Elegido se usa el guardado, si lo hay y el origen lo deja.
function Start-Preparar {
    param($Elegido = $null)
    if (-not (Enter-Ocupado -Boton 'BtnPreparar' -TextoOcupado 'Cancelar')) { return }
    $lanzada = $false
    try {
        $deLaGaleria = [bool]$Elegido
        if ($Elegido -and $script:Preparado) {
            # El juego es el de la galeria, no el de la lista: Refrescar deja la lista sin
            # seleccion y lo preparado sigue ahi (y antes esto se quedaba en 'Elige un juego')
            $j = $script:Preparado.Juego
            $nombre = $script:Preparado.Nombre
        } else {
            $j = $ctl.LstJuegos.SelectedItem
            if (-not $j) { Add-Log 'Elige un juego de la lista.'; return }
            $nombre = $ctl.TxtNombre.Text.Trim()
            if (-not $nombre) { Add-Log 'El nombre no puede estar vacío.'; return }
            $j.LaunchOptions = $ctl.TxtOpciones.Text
        }

        # lo preparado antes para este juego se borra aqui abajo: que no quede a mano para anadir
        Clear-Preview
        $appId = Get-SteamShortcutAppId -ExeQuoted ('"' + $j.Exe + '"') -AppName $nombre
        $origenArte = Get-OrigenArte
        $avisoElegido = ''
        if ($deLaGaleria) {
            $origenArte = 'Automatico'
        } else {
            $guardado = Get-ElegidoParaPreparar -Juego $j -OrigenArte $origenArte
            $Elegido = $guardado.Elegido
            $avisoElegido = $guardado.Aviso
        }
        $ids = Get-IdsElegido $Elegido
        # Cada preparacion en su carpeta: una cancelada sigue hasta que vuelve la descarga en
        # curso y podria escribir encima de la siguiente del mismo appid. Las de antes de este
        # appid ya no valen (la de una cancelada, si aun escribe, se poda en Remove-TempViejo).
        foreach ($d in @(Get-ChildItem -LiteralPath $TempDir -Directory -ErrorAction SilentlyContinue)) {
            if ($d.Name -eq "$appId" -or $d.Name.StartsWith("$appId-")) {
                Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        $destino = Join-Path $TempDir ('{0}-{1}' -f $appId, (Get-Date -Format 'HHmmssfff'))

        Add-Log "Preparando carátulas de '$nombre' (AppId $appId). Puedes cancelarlo con el mismo botón."
        if ($deLaGaleria) {
            # Se guarda ya, y no al acabar: si la preparacion falla o se cancela, lo elegido
            # sigue valiendo para el siguiente intento
            $avisoElegido = "  con el juego elegido a mano: '$($Elegido.Titulo)' ($($Elegido.Fuente)). " + (Save-Elegido -Juego $j -Elegido $Elegido)
            Update-Elegido
        }
        if ($avisoElegido) { Add-Log $avisoElegido }
        # una copia del juego: el otro hilo no tiene por que compartir el objeto de la lista
        $script:Tarea = Start-TareaFondo -Lib $LibPreparar -Parametros @{
                Juego = $j.PSObject.Copy(); AppId = $appId; Destino = $destino; Nombre = $nombre; OrigenArte = $origenArte
                StoreIdElegido = $ids.StoreIdElegido; SgdbIdElegido = $ids.SgdbIdElegido
            } -Datos @{ Juego = $j; Nombre = $nombre; AppId = $appId; Carpeta = $destino; Elegido = $Elegido
                        TextoCancelado = 'Cancelado: no se ha preparado nada.'
                        AlTerminar = { param($t, $s) Complete-Preparar $t $s } } `
            -Cuerpo {
                param($Juego, $AppId, $Destino, $Nombre, $OrigenArte, $StoreIdElegido, $SgdbIdElegido, $Log)
                New-CaratulasSteam -Juego $Juego -AppId $AppId -GridDir $Destino -NombreFinal $Nombre `
                    -OrigenArte $OrigenArte -StoreIdElegido $StoreIdElegido -SgdbIdElegido $SgdbIdElegido -Log $Log
            }
        [void]$script:Tareas.Add($script:Tarea)
        $script:Reloj.Start()
        $lanzada = $true
        Set-Progreso $true
        Update-Botones      # ahora que hay tarea, el boton de cancelar se enciende
    } catch {
        Add-Log "ERROR preparando carátulas: $($_.Exception.Message)"
        Write-RegistroError -Contexto 'preparar carátulas' -Fallo $_
    } finally {
        if (-not $lanzada) { Exit-Ocupado }
    }
}

# Llega desde Update-Tareas cuando la preparacion acaba sin cancelar
function Complete-Preparar {
    param([hashtable]$Tarea, $Salida)
    $script:Tarea = $null
    Set-Progreso $false
    try {
        if ($Salida.Fallo) {
            Write-LogVentana "ERROR preparando carátulas: $($Salida.Fallo.Exception.Message)"
            Write-RegistroError -Contexto 'preparar carátulas' -Fallo $Salida.Fallo
            return
        }
        $c = $Salida.Resultado
        $d = $Tarea.Datos
        # StoreId, SgdbId e IconoDe son para la galeria: no repetir busquedas y saber cuando
        # rehacer el icono. Alternativas guarda lo ya buscado de cada hueco. Busqueda es con que
        # se busca en SteamGridDB (el titulo del juego elegido a mano, si lo hay). Elegido es el
        # juego elegido a mano del que han salido ($null si se ha buscado por el nombre).
        $busqueda = [string]$c.Busqueda
        if (-not $busqueda) { $busqueda = $d.Nombre }
        $script:Preparado = @{ Juego = $d.Juego; Nombre = $d.Nombre; AppId = $d.AppId; Rutas = $c.Rutas
                               Carpeta = $d.Carpeta; StoreId = [string]$c.StoreId; SgdbId = [string]$c.SgdbId
                               IconoDe = [string]$c.IconoDe; Alternativas = @{}; Busqueda = $busqueda
                               Elegido = $d.Elegido }
        Update-VistaPrevia
        $texto = "Carátulas: $($c.Origen)"
        if ($d.Elegido) { $texto += ", del juego elegido a mano («$($d.Elegido.Titulo)»)" }
        $ctl.TxtOrigenArte.Text = "$texto. Pulsa una imagen para elegir otra."
        Write-LogVentana 'Listas. Si te gustan, pulsa "2. Añadir a Steam". Si no, pulsa la imagen que quieras cambiar.'
    } catch {
        Write-LogVentana "ERROR preparando carátulas: $($_.Exception.Message)"
        Write-RegistroError -Contexto 'preparar carátulas' -Fallo $_
    } finally {
        Exit-Ocupado
    }
}

# El boton de cancelar (BtnPreparar mientras hay $script:Tarea: preparar o cambiar una imagen
# de la galeria). La ventana queda libre al momento; la tarea para en cuanto vuelva lo que este
# haciendo (una descarga no se puede cortar) y Update-Tareas la recoge sin mas. Cada tarea
# trae en Datos lo que hay que decir y, si hace falta, que hacer al cancelarla.
# Sin bombear mensajes: se llama tambien desde el cierre de la ventana.
function Stop-TareaVentana {
    $t = $script:Tarea
    if (-not $t) { return }
    $script:Tarea = $null
    foreach ($l in @(Get-TareaLineas $t)) { Write-LogVentana $l }
    Stop-TareaFondo $t
    Set-Progreso $false
    Write-LogVentana $t.Datos.TextoCancelado
    if ($t.Datos.AlCancelar) { & $t.Datos.AlCancelar $t }
    Exit-Ocupado
}

$ctl.BtnPreparar.Add_Click({ if ($script:Tarea) { Stop-TareaVentana } else { Start-Preparar } })

# --- galeria: elegir otra imagen para un hueco -------------------------
# Con las caratulas preparadas, pulsar una imagen de la vista previa abre una ventana con la
# actual y las demas que hay en la Store y en SteamGridDB. La busqueda y las miniaturas van en
# segundo plano y aparecen segun llegan; lo encontrado se guarda en $script:Preparado para no
# repetirlo al volver a abrir el mismo hueco. Elegir una la descarga entera y la deja con las
# medidas de Steam en la carpeta de lo preparado (Set-CaratulaRanura), tambien en segundo plano.

# Como se ven las miniaturas en la galeria (ancho, alto)
$MiniGaleria = @{ p = @(120, 180); cap = @(230, 107); hero = @(300, 97); logo = @(200, 90) }
$Brochas = New-Object Windows.Media.BrushConverter

# Donde deja Save-Miniaturas la de la opcion $Indice (la busqueda y la galeria la calculan igual)
function Get-RutaMiniatura {
    param([hashtable]$Preparado, [string]$Ranura, [int]$Indice)
    return (Join-Path (Join-Path $Preparado.Carpeta 'alternativas') ('{0}-{1}.img' -f $Ranura, $Indice))
}

# Una miniatura puede venir rota (o ser un formato que WPF no lee): se queda en blanco
function Get-ImagenMiniatura {
    param([string]$Ruta)
    try { return (Get-ImagenSegura $Ruta) } catch { return $null }
}

function Get-TextoAlternativa {
    param($Alternativa)
    $partes = @($Alternativa.Origen)
    if ($Alternativa.Detalle) { $partes += $Alternativa.Detalle }
    if ($Alternativa.Ancho -gt 0) { $partes += ('{0}x{1}' -f $Alternativa.Ancho, $Alternativa.Alto) }
    return ($partes -join ' · ')
}

# Anade una opcion a la galeria. $Indice -1 es la imagen actual (elegirla no cambia nada).
function Add-OpcionGaleria {
    param([int]$Indice, [string]$Texto, [string]$Ruta = '')
    $g = $script:Galeria
    $med = $MiniGaleria[$g.Ranura]
    $img = New-Object Windows.Controls.Image
    $img.Width = $med[0]; $img.Height = $med[1]
    $img.Stretch = $(if ($g.Ranura -eq 'logo') { 'Uniform' } else { 'UniformToFill' })
    if ($Ruta) { $img.Source = Get-ImagenMiniatura $Ruta }
    $marco = New-Object Windows.Controls.Border
    $marco.Background = $Brochas.ConvertFromString('#FF111316')
    $marco.Child = $img
    $txt = New-Object Windows.Controls.TextBlock
    $txt.Text = $Texto
    $txt.FontSize = 10
    $txt.Foreground = $Brochas.ConvertFromString($(if ($Indice -lt 0) { '#FFE6E8EC' } else { '#FF8A909B' }))
    $txt.Margin = New-Object Windows.Thickness(0, 4, 0, 0)
    $txt.Width = $med[0]
    $txt.TextTrimming = 'CharacterEllipsis'
    $pila = New-Object Windows.Controls.StackPanel
    [void]$pila.Children.Add($marco)
    [void]$pila.Children.Add($txt)
    $b = New-Object Windows.Controls.Button
    $b.Style = $g.Ventana.FindResource('Opcion')
    $b.Content = $pila
    $b.Tag = $Indice
    $b.ToolTip = $Texto
    $b.Add_Click({ param($s, $e) $script:Galeria.Eleccion = [int]$s.Tag; $script:Galeria.Ventana.Close() })
    [void]$g.Panel.Children.Add($b)
    if ($Indice -ge 0) { $g.Imagenes[$Indice] = $img }
}

# Pone en la galeria la lista de opciones y las miniaturas que ya esten bajadas
function Show-ListaGaleria {
    param([object[]]$Lista)
    $g = $script:Galeria
    $g.Lista = @($Lista)
    for ($i = 0; $i -lt $g.Lista.Count; $i++) {
        $mini = Get-RutaMiniatura -Preparado $g.Preparado -Ranura $g.Ranura -Indice $i
        if (-not (Test-Path -LiteralPath $mini)) { $mini = '' }
        Add-OpcionGaleria -Indice $i -Texto (Get-TextoAlternativa $g.Lista[$i]) -Ruta $mini
    }
    if ($g.Lista.Count) {
        $g.Estado.Text = "$($g.Lista.Count) opciones. Pulsa la que quieras usar."
    } else {
        $sinClave = -not (Get-SgdbClave)
        $g.Estado.Text = 'No he encontrado otras imágenes para este hueco. Puedes cargar una tuya o, si es otro juego, elegir el bueno.' +
            $(if ($sinClave) { ' Con una clave de SteamGridDB (en Ajustes) suele haber muchas más.' } else { '' })
    }
}

# Llega desde Update-Tareas con cada aviso de la busqueda: primero la lista y luego cada
# miniatura segun se baja. Si la galeria ya no es la de esta tarea, no hay nada que pintar.
function Receive-AvisoGaleria {
    param([hashtable]$Tarea, $Aviso)
    $g = $script:Galeria
    if (-not $g -or $g.Tarea -ne $Tarea) { return }
    if ($Aviso.Tipo -eq 'Lista') {
        Show-ListaGaleria @($Aviso.Lista)
        if ($g.Lista.Count) { $g.Estado.Text = "$($g.Lista.Count) opciones; las miniaturas van llegando. Pulsa la que quieras usar." }
    } elseif ($Aviso.Tipo -eq 'Mini') {
        $img = $g.Imagenes[[int]$Aviso.Indice]
        if ($img) { $img.Source = Get-ImagenMiniatura ([string]$Aviso.Ruta) }
    }
}

# Fin de la busqueda: se guarda lo encontrado para la proxima vez (en lo preparado de cuando
# se lanzo, que es de quien son las miniaturas)
function Complete-Galeria {
    param([hashtable]$Tarea, $Salida)
    $d = $Tarea.Datos
    $g = $script:Galeria
    $mia = ($g -and $g.Tarea -eq $Tarea)
    if ($mia) { $g.Tarea = $null; $g.Progreso.Visibility = 'Collapsed' }
    if ($Salida.Fallo) {
        Write-LogVentana "ERROR buscando otras imágenes: $($Salida.Fallo.Exception.Message)"
        Write-RegistroError -Contexto 'galería de carátulas' -Fallo $Salida.Fallo
        if ($mia) { $g.Estado.Text = 'La búsqueda ha fallado (el detalle está en el registro).' }
        return
    }
    $r = $Salida.Resultado
    $d.Preparado.Alternativas[$d.Ranura] = @{ Lista = @($r.Lista) }
    if ($r.SgdbId) { $d.Preparado.SgdbId = [string]$r.SgdbId }
    if ($mia -and $g.Lista.Count) { $g.Estado.Text = "$($g.Lista.Count) opciones. Pulsa la que quieras usar." }
    Write-LogVentana "  $(@($r.Lista).Count) opciones para $($HuecosVista[$d.Ranura].Nombre)."
}

# --- elegir el juego bueno ----------------------------------------------
# Cuando la busqueda por el nombre acierta con otro juego (o con ninguno, como 'ACValhalla'),
# desde la galeria se abre esta ventana: busca en la Store y en SteamGridDB con lo que se
# escriba y deja elegir. Devuelve el elegido (un resultado de Get-CandidatosJuego) o $null, y
# quien la abre prepara otra vez todas las caratulas con el y lo guarda para las proximas veces
# (Start-Preparar). El nombre en Steam no cambia.
$script:ElegirJuego = $null   # la ventana, mientras esta abierta

function Start-BuscarJuego {
    $e = $script:ElegirJuego
    if (-not $e) { return }
    $texto = $e.Busqueda.Text.Trim()
    if (-not $texto) { $e.Estado.Text = 'Escribe el nombre del juego.'; return }
    # la busqueda anterior, si no ha acabado, ya no viene a cuento
    if ($e.Tarea) { Stop-TareaFondo $e.Tarea; $e.Tarea = $null }
    $e.Lista.ItemsSource = $null
    $e.Estado.Text = "Buscando «$texto» en la Store y en SteamGridDB..."
    $e.Progreso.Visibility = 'Visible'
    # sin Add-Log: bombearia mensajes en medio del evento
    Write-LogVentana "Buscando juegos que se llamen '$texto'..."
    $t = Start-TareaFondo -Lib $LibPreparar -Parametros @{ Nombre = $texto } `
        -Datos @{ AlTerminar = { param($t, $s) Complete-BuscarJuego $t $s } } `
        -Cuerpo {
            param($Nombre, $Log)
            Get-CandidatosJuego -Nombre $Nombre -Log $Log
        }
    $e.Tarea = $t
    [void]$script:Tareas.Add($t)
    $script:Reloj.Start()
}

# Llega desde Update-Tareas al acabar la busqueda. Si la ventana ya no esta, o se ha lanzado
# otra busqueda despues, no hay nada que pintar.
function Complete-BuscarJuego {
    param([hashtable]$Tarea, $Salida)
    $e = $script:ElegirJuego
    if (-not $e -or $e.Tarea -ne $Tarea) { return }
    $e.Tarea = $null
    $e.Progreso.Visibility = 'Collapsed'
    if ($Salida.Fallo) {
        Write-RegistroError -Contexto 'buscar juego' -Fallo $Salida.Fallo
        $e.Estado.Text = 'La búsqueda ha fallado (el detalle está en el registro).'
        return
    }
    $p = $e.Preparado
    $filas = @()
    foreach ($c in @($Salida.Resultado)) {
        if (-not $c) { continue }
        $partes = @($c.Fuente)
        if ($c.Detalle) { $partes += $c.Detalle }
        $partes += ('{0} % de parecido' -f [int][Math]::Round([double]$c.Parecido * 100))
        $idActual = $(if ($c.Fuente -eq 'SteamGridDB') { $p.SgdbId } else { $p.StoreId })
        if ($idActual -and [string]$c.Id -eq $idActual) { $partes += 'EL DE AHORA' }
        $filas += [pscustomobject]@{ Titulo = $c.Titulo; Linea = ($partes -join ' · '); Candidato = $c }
    }
    $e.Lista.ItemsSource = $filas
    if ($filas.Count) {
        $e.Estado.Text = "$($filas.Count) resultados. Elige el juego bueno y pulsa «Usar este juego»."
    } else {
        $e.Estado.Text = 'No he encontrado nada. Prueba con otro nombre (con el título en inglés suele haber más).' +
            $(if (-not (Get-SgdbClave)) { ' Con una clave de SteamGridDB (en Ajustes) se busca también allí.' } else { '' })
    }
    Write-LogVentana "  $($filas.Count) resultados."
}

function Show-ElegirJuego {
    param([Parameter(Mandatory)]$Duenio, [Parameter(Mandatory)][hashtable]$Preparado)
    if ($script:ElegirJuego) { return $null }
    [xml]$xamlElegir = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="640" Height="540" MinWidth="460" MinHeight="360"
        WindowStartupLocation="CenterOwner" ShowInTaskbar="False" Background="#FF15171B">
  <Window.Resources>
    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="#FFE6E8EC"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#FF262A31"/>
      <Setter Property="Foreground" Value="#FFE6E8EC"/>
      <Setter Property="BorderBrush" Value="#FF3A3F49"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FocusVisualStyle" Value="{DynamicResource Foco}"/>
    </Style>
    <Style TargetType="ListBoxItem">
      <Setter Property="FocusVisualStyle" Value="{DynamicResource Foco}"/>
    </Style>
  </Window.Resources>
  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <TextBlock Name="TxtTitulo" FontSize="15" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
    <TextBlock Grid.Row="1" FontSize="11" Foreground="#FF8A909B" Margin="0,4,0,10" TextWrapping="Wrap"
               Text="Si las carátulas son de otro juego, búscalo y elige el bueno: se preparan otra vez todas con él, y se recuerda para las próximas veces. El nombre en Steam no cambia."/>
    <Grid Grid.Row="2">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBox Name="TxtBusqueda" Height="30" FontSize="14" Padding="6,4" VerticalContentAlignment="Center"
               Background="#FF1E2127" Foreground="#FFE6E8EC" BorderBrush="#FF3A3F49"/>
      <Button Name="BtnBuscar" Grid.Column="1" Content="Buscar" IsDefault="True" Margin="8,0,0,0" Padding="14,4"/>
    </Grid>
    <TextBlock Name="TxtEstado" Grid.Row="3" FontSize="11" Foreground="#FF8A909B" Margin="0,8,0,4" TextWrapping="Wrap"/>
    <ProgressBar Name="PrgBuscar" Grid.Row="4" Height="3" Margin="0,0,0,6" IsIndeterminate="True"
                 Visibility="Collapsed" Background="#FF1E2127" Foreground="#FFDC1E23" BorderThickness="0"/>
    <ListBox Name="LstCandidatos" Grid.Row="5" Background="#FF1E2127" BorderBrush="#FF3A3F49"
             Foreground="#FFE6E8EC" ScrollViewer.HorizontalScrollBarVisibility="Disabled">
      <ListBox.ItemTemplate>
        <DataTemplate>
          <StackPanel Margin="2,4">
            <TextBlock Text="{Binding Titulo}" FontSize="14" TextTrimming="CharacterEllipsis"/>
            <TextBlock Text="{Binding Linea}" FontSize="11" Foreground="#FF8A909B" TextTrimming="CharacterEllipsis"/>
          </StackPanel>
        </DataTemplate>
      </ListBox.ItemTemplate>
    </ListBox>
    <StackPanel Grid.Row="6" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
      <!-- siempre activo: desactivado, el tema lo pinta casi blanco -->
      <Button Name="BtnUsar" Content="Usar este juego" Background="#FF7A1418" Margin="0,0,8,0"/>
      <Button Name="BtnCancelarJuego" Content="Cancelar" IsCancel="True"/>
    </StackPanel>
  </Grid>
</Window>
'@
    $dlg = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xamlElegir))
    Add-EstiloFoco $dlg
    $dlg.Owner = $Duenio
    if ($script:IconoVentana) { $dlg.Icon = $script:IconoVentana }
    $dlg.Title = "Elegir el juego - $($Preparado.Nombre)"
    $dlg.FindName('TxtTitulo').Text = "¿De qué juego son las carátulas de «$($Preparado.Nombre)»?"
    $script:ElegirJuego = @{
        Ventana = $dlg; Busqueda = $dlg.FindName('TxtBusqueda'); Lista = $dlg.FindName('LstCandidatos')
        Estado = $dlg.FindName('TxtEstado'); Progreso = $dlg.FindName('PrgBuscar'); Usar = $dlg.FindName('BtnUsar')
        Preparado = $Preparado; Tarea = $null; Eleccion = $null
    }
    $script:ElegirJuego.Busqueda.Text = $Preparado.Busqueda
    $dlg.FindName('BtnBuscar').Add_Click({ Start-BuscarJuego })
    $usar = {
        $sel = $script:ElegirJuego.Lista.SelectedItem
        if (-not $sel) { $script:ElegirJuego.Estado.Text = 'Elige primero un juego de la lista.'; return }
        $script:ElegirJuego.Eleccion = $sel.Candidato
        $script:ElegirJuego.Ventana.Close()
    }
    $script:ElegirJuego.Usar.Add_Click($usar)
    $script:ElegirJuego.Lista.Add_MouseDoubleClick($usar)
    # Enter en la lista usa el juego que tiene el foco; sin esto lo cogeria "Buscar" (IsDefault)
    $script:ElegirJuego.Lista.Add_PreviewKeyDown({
        param($s, $e)
        if ($e.Key -ne 'Return') { return }
        $item = [Windows.Controls.ItemsControl]::ContainerFromElement($s, $e.OriginalSource)
        if ($item) { $item.IsSelected = $true }
        $e.Handled = $true
        & $usar
    })
    $dlg.Add_ContentRendered({
        $script:ElegirJuego.Busqueda.Focus() | Out-Null
        $script:ElegirJuego.Busqueda.SelectAll()
    })
    try {
        Start-BuscarJuego
        [void]$dlg.ShowDialog()
    } finally {
        if ($script:ElegirJuego.Tarea) {
            Stop-TareaFondo $script:ElegirJuego.Tarea
            Write-LogVentana '  búsqueda cancelada al cerrar la ventana.'
        }
        $eleccion = $script:ElegirJuego.Eleccion
        $script:ElegirJuego = $null
    }
    return $eleccion
}

function Show-Galeria {
    param([string]$Ranura)
    $p = $script:Preparado
    if (-not $p -or $script:Ocupado -or $script:Galeria) { return }
    [xml]$xamlGaleria = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="980" Height="680" MinWidth="560" MinHeight="400"
        WindowStartupLocation="CenterOwner" ShowInTaskbar="False" Background="#FF15171B">
  <Window.Resources>
    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="#FFE6E8EC"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#FF262A31"/>
      <Setter Property="Foreground" Value="#FFE6E8EC"/>
      <Setter Property="BorderBrush" Value="#FF3A3F49"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FocusVisualStyle" Value="{DynamicResource Foco}"/>
    </Style>
    <!-- cada opcion: sin la plantilla del tema, que al pasar el raton pinta el fondo de azul claro -->
    <Style x:Key="Opcion" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{DynamicResource Foco}"/>
      <Setter Property="Margin" Value="0,0,10,10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Name="Bd" Background="#FF1E2127" BorderBrush="#FF3A3F49" BorderThickness="1" Padding="6">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="#FFDC1E23"/>
                <Setter TargetName="Bd" Property="Background" Value="#FF2E3440"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <TextBlock Name="TxtTitulo" FontSize="15" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
    <TextBlock Name="TxtEstado" Grid.Row="1" FontSize="11" Foreground="#FF8A909B" Margin="0,4,0,6" TextWrapping="Wrap"/>
    <ProgressBar Name="PrgGaleria" Grid.Row="2" Height="3" Margin="0,0,0,10" IsIndeterminate="True"
                 Background="#FF1E2127" Foreground="#FFDC1E23" BorderThickness="0"/>
    <ScrollViewer Grid.Row="3" Focusable="False" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
      <WrapPanel Name="PnlOpciones"/>
    </ScrollViewer>
    <Grid Grid.Row="4" Margin="0,10,0,0">
      <Button Name="BtnOtroJuego" Content="Elegir otro juego..." HorizontalAlignment="Left"
              ToolTip="Si las imágenes son de otro juego: búscalo, elige el bueno y se preparan otra vez todas. El elegido se recuerda"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button Name="BtnCargar" Content="Cargar imagen..." Margin="0,0,8,0"
                ToolTip="Usar una imagen tuya (PNG, JPG, BMP o GIF). Se recorta a la medida del hueco."/>
        <Button Name="BtnCerrar" Content="Cancelar" IsCancel="True"/>
      </StackPanel>
    </Grid>
  </Grid>
</Window>
'@
    $dlg = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xamlGaleria))
    Add-EstiloFoco $dlg
    $dlg.Owner = $win
    if ($script:IconoVentana) { $dlg.Icon = $script:IconoVentana }
    $nombreHueco = $HuecosVista[$Ranura].Nombre
    $dlg.Title = "Elegir $nombreHueco - $($p.Nombre)"
    $dlg.FindName('TxtTitulo').Text = "Otra imagen de $nombreHueco para «$($p.Nombre)»"
    # Eleccion es una de la lista; Fichero, una imagen del disco; Juego, el juego bueno
    $script:Galeria = @{
        Ventana = $dlg; Panel = $dlg.FindName('PnlOpciones'); Estado = $dlg.FindName('TxtEstado')
        Progreso = $dlg.FindName('PrgGaleria'); Ranura = $Ranura; Preparado = $p
        Lista = @(); Imagenes = @{}; Eleccion = $null; Fichero = $null; Juego = $null; Tarea = $null
    }
    $dlg.FindName('BtnCargar').Add_Click({
        $f = New-Object Microsoft.Win32.OpenFileDialog
        $f.Title = 'Elegir una imagen'
        $f.Filter = 'Imágenes (*.png;*.jpg;*.jpeg;*.bmp;*.gif)|*.png;*.jpg;*.jpeg;*.bmp;*.gif|Todos los ficheros (*.*)|*.*'
        if ($f.ShowDialog($script:Galeria.Ventana)) {
            $script:Galeria.Fichero = $f.FileName
            $script:Galeria.Ventana.Close()
        }
    })
    $dlg.FindName('BtnOtroJuego').Add_Click({
        $c = Show-ElegirJuego -Duenio $script:Galeria.Ventana -Preparado $script:Galeria.Preparado
        if ($c) {
            $script:Galeria.Juego = $c
            $script:Galeria.Ventana.Close()
        }
    })
    # el foco empieza en la imagen actual: con el teclado (o el mando) se llega a las demas con
    # las flechas, y Escape cierra sin cambiar nada
    $dlg.Add_ContentRendered({
        $c = $script:Galeria.Panel.Children
        if ($c.Count) { [void]$c[0].Focus() }
    })
    try {
        $actual = $p.Rutas[$Ranura]
        Add-OpcionGaleria -Indice -1 -Texto $(if ($actual) { 'La actual' } else { 'Sin logo (la actual)' }) -Ruta $actual

        $cache = $p.Alternativas[$Ranura]
        if ($cache) {
            $script:Galeria.Progreso.Visibility = 'Collapsed'
            Show-ListaGaleria $cache.Lista
        } else {
            $script:Galeria.Estado.Text = 'Buscando en la Store y en SteamGridDB...'
            Add-Log "Buscando más imágenes de $nombreHueco para '$($p.Nombre)'..."
            $t = Start-TareaFondo -Lib $LibPreparar -Parametros @{
                    Ranura = $Ranura; Nombre = $p.Busqueda; StoreId = $p.StoreId; SgdbId = $p.SgdbId
                    Carpeta = (Join-Path $p.Carpeta 'alternativas')
                } -Datos @{ Preparado = $p; Ranura = $Ranura
                            AlAvisar   = { param($t, $a) Receive-AvisoGaleria $t $a }
                            AlTerminar = { param($t, $s) Complete-Galeria $t $s } } `
                -Cuerpo {
                    param($Ranura, $Nombre, $StoreId, $SgdbId, $Carpeta, $Log, $Aviso)
                    $r = Get-Alternativas -Ranura $Ranura -Nombre $Nombre -StoreId $StoreId -SgdbId $SgdbId -Log $Log
                    & $Aviso ([pscustomobject]@{ Tipo = 'Lista'; Lista = $r.Lista }) | Out-Null
                    Save-Miniaturas -Lista $r.Lista -Carpeta $Carpeta -Prefijo $Ranura -Aviso $Aviso
                    $r
                }
            $script:Galeria.Tarea = $t
            [void]$script:Tareas.Add($t)
            $script:Reloj.Start()
        }
        [void]$dlg.ShowDialog()
    } finally {
        # cerrada sin esperar a que acabe: lo que quede ya no se va a ver
        if ($script:Galeria.Tarea) {
            Stop-TareaFondo $script:Galeria.Tarea
            Write-LogVentana '  búsqueda cancelada al cerrar la galería.'
        }
        $eleccion = $script:Galeria.Eleccion
        $lista = $script:Galeria.Lista
        $fichero = $script:Galeria.Fichero
        $juego = $script:Galeria.Juego
        $script:Galeria = $null
    }
    if ($fichero) {
        $alt = New-Alternativa -Origen 'Imagen propia' -Detalle ([IO.Path]::GetFileName($fichero)) -Url $fichero
        Start-AplicarAlternativa -Ranura $Ranura -Alternativa $alt
    } elseif ($juego) {
        $idActual = $(if ($juego.Fuente -eq 'SteamGridDB') { $p.SgdbId } else { $p.StoreId })
        if ($idActual -and [string]$juego.Id -eq $idActual) {
            Add-Log "'$($juego.Titulo)' ya es el juego del que salen las carátulas: no cambio nada."
        } else {
            Start-Preparar -Elegido $juego
        }
    } elseif ($null -ne $eleccion -and $eleccion -ge 0 -and $eleccion -lt $lista.Count) {
        Start-AplicarAlternativa -Ranura $Ranura -Alternativa $lista[$eleccion]
    }
}

# Descarga la elegida y la pone en su hueco. Se cancela con el mismo boton que preparar: hay
# imagenes rotas en SteamGridDB que tardan ~30 s en llegar vacias.
function Start-AplicarAlternativa {
    param([string]$Ranura, $Alternativa)
    $p = $script:Preparado
    if (-not $p) { return }
    if (-not (Enter-Ocupado -Boton 'BtnPreparar' -TextoOcupado 'Cancelar')) { return }
    $lanzada = $false
    try {
        $accion = $(if ($Alternativa.Url -match '^https?://') { 'Descargando...' } else { 'Cargando...' })
        Add-Log "Nueva imagen de $($HuecosVista[$Ranura].Nombre): $(Get-TextoAlternativa $Alternativa). $accion"
        $script:Tarea = Start-TareaFondo -Lib $LibPreparar -Parametros @{
                Ranura = $Ranura; Origen = $Alternativa.Url; GridDir = $p.Carpeta; AppId = $p.AppId; IconoDe = $p.IconoDe
            } -Datos @{ Preparado = $p; Alternativa = $Alternativa
                        TextoCancelado = 'Cancelado: la imagen se queda como estaba.'
                        # se vuelve a pintar lo que haya en disco, por si justo acabo de escribir
                        AlCancelar = { param($t) if ($t.Datos.Preparado -eq $script:Preparado) { Update-VistaPrevia } }
                        AlTerminar = { param($t, $s) Complete-AplicarAlternativa $t $s } } `
            -Cuerpo {
                param($Ranura, $Origen, $GridDir, $AppId, $IconoDe, $Log)
                Set-CaratulaRanura -Ranura $Ranura -Origen $Origen -GridDir $GridDir -AppId $AppId -IconoDe $IconoDe -Log $Log
            }
        [void]$script:Tareas.Add($script:Tarea)
        $script:Reloj.Start()
        $lanzada = $true
        Set-Progreso $true
        Update-Botones      # ahora que hay tarea, el boton de cancelar se enciende
    } catch {
        Add-Log "ERROR cambiando la imagen: $($_.Exception.Message)"
        Write-RegistroError -Contexto 'cambiar imagen' -Fallo $_
    } finally {
        if (-not $lanzada) { Exit-Ocupado }
    }
}

function Complete-AplicarAlternativa {
    param([hashtable]$Tarea, $Salida)
    $script:Tarea = $null
    Set-Progreso $false
    try {
        if ($Salida.Fallo) {
            Write-LogVentana "No he podido usar esa imagen: $($Salida.Fallo.Exception.Message) Elige otra."
            Write-RegistroError -Contexto 'cambiar imagen' -Fallo $Salida.Fallo
            return
        }
        $r = $Salida.Resultado
        $p = $Tarea.Datos.Preparado
        $p.Rutas[$r.Ranura] = $r.Ruta
        if ($r.Icono) { $p.Rutas['icon'] = $r.Icono }
        $p.IconoDe = $r.IconoDe
        if ($p -eq $script:Preparado) {
            Update-VistaPrevia
            $ctl.TxtOrigenArte.Text = 'Carátulas: elegidas en parte a mano. Pulsa una imagen para elegir otra.'
        }
        Write-LogVentana "Hecho: nueva imagen de $($HuecosVista[$r.Ranura].Nombre). Se usará al pulsar ""2. Añadir a Steam""."
    } catch {
        Write-LogVentana "ERROR cambiando la imagen: $($_.Exception.Message)"
        Write-RegistroError -Contexto 'cambiar imagen' -Fallo $_
    } finally {
        Exit-Ocupado
    }
}

foreach ($k in $HuecosVista.Keys) {
    $ctl[$HuecosVista[$k].Boton].Add_Click({ param($s, $e) Show-Galeria -Ranura ([string]$s.Tag) })
}

function Invoke-Anadir {
    if (-not $script:Preparado) { return }
    if (-not $script:Steam) { Add-Log (Get-SteamMotivo); return }
    try {
        $p = $script:Preparado
        $p.Juego.LaunchOptions = $ctl.TxtOpciones.Text
        $r = Invoke-AnadirJuego -Juego $p.Juego -Nombre $p.Nombre -Steam $script:Steam `
                -Reemplazar:([bool]$ctl.ChkReemplazar.IsChecked) -AbrirBigPicture:([bool]$ctl.ChkBigPicture.IsChecked) `
                -CaratulasListas $p.Rutas -Log $LogGui
        # si no ha ido bien, $script:Preparado sigue puesto y Update-Botones deja el boton vivo
        if ($r.Ok) { Clear-Preview; Update-Deteccion }
        # anadido, Steam se ha reabierto siempre: si es en Big Picture, la Vaporera se cierra
        if ($r.Ok -and $r.CaratulasOk) { Complete-CambioSteam -Bien $true -BigPicture ([bool]$ctl.ChkBigPicture.IsChecked) -Anadir }
    } catch {
        Add-Log "ERROR: $($_.Exception.Message)"
        Write-RegistroError -Contexto 'añadir a Steam' -Fallo $_
    }
}
$ctl.BtnAnadir.Add_Click({ Invoke-Ocupado -Boton 'BtnAnadir' -TextoOcupado 'Añadiendo…' -Accion { Invoke-Anadir } })

function Invoke-Quitar {
    $j = $ctl.LstJuegos.SelectedItem
    if (-not $j -or -not $j.YaEnSteam) { return }
    if (-not $script:Steam) { Add-Log (Get-SteamMotivo); return }
    # El nombre que sale en la pregunta es el del acceso directo, no el detectado: si se anadio
    # con otro nombre (casa por el exe), es ese el que el usuario reconoce en su biblioteca.
    $dup = Test-ShortcutDuplicado -RutaVdf $script:Steam.Shortcuts -Nombre $j.Nombre -Exe $j.Exe -LaunchOptions $j.LaunchOptions
    $entrada = Get-ShortcutsExistentes -Ruta $script:Steam.Shortcuts | Where-Object { $_.Indice -eq $dup } | Select-Object -First 1
    $nombre = if ($entrada) { $entrada.Nombre } else { $j.Nombre }
    $texto = "¿Quitar «$nombre» de la biblioteca de Steam?`r`n`r`n" +
             "Se borran el acceso directo y sus carátulas. El juego no se desinstala.`r`n" +
             "Si Steam está abierto se cerrará un momento; antes se hace copia de shortcuts.vdf."
    $resp = [Windows.MessageBox]::Show($win, $texto, 'Quitar de Steam', 'YesNo', 'Question', 'No')
    if ($resp -ne 'Yes') { return }
    try {
        # Steam solo se reabre (y en Big Picture, si esta marcado) si estaba abierto
        $bigPicture = ([bool]$ctl.ChkBigPicture.IsChecked -and (Test-SteamCorriendo))
        $r = Invoke-QuitarJuego -Juego $j -Steam $script:Steam -AbrirBigPicture:([bool]$ctl.ChkBigPicture.IsChecked) -Log $LogGui
        if ($r.Ok) { Clear-Preview; Update-Deteccion; Complete-CambioSteam -Bien $true -BigPicture $bigPicture }
    } catch {
        Add-Log "ERROR: $($_.Exception.Message)"
        Write-RegistroError -Contexto 'quitar de Steam' -Fallo $_
    }
}
$ctl.BtnQuitar.Add_Click({ Invoke-Ocupado -Boton 'BtnQuitar' -TextoOcupado 'Quitando…' -Accion { Invoke-Quitar } })

# --- varios juegos: "Añadir (N)", "Quitar (N)" y "Desmarcar" ------------
# Marcar un juego no lo selecciona. Al anadir, las caratulas de todos se preparan antes en
# segundo plano (como "1. Preparar", y se cancela con ese mismo boton) y solo entonces se
# cierra Steam, una vez. El seleccionado va con el nombre y las opciones de los cuadros de
# texto, y el que tenga la vista previa preparada, con esas imagenes (lo elegido en la galeria).
# Los demas se preparan con su juego elegido a mano, si tienen uno guardado.

# La casilla ya ha escrito en Marcado cuando llega el Click: solo falta la cuenta
foreach ($listaJuegos in @($ctl.LstJuegos, $ctl.LstSencillo)) {
    $listaJuegos.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [Windows.RoutedEventHandler]{
        param($s, $e)
        if ($e.OriginalSource -is [Windows.Controls.CheckBox]) { Update-Botones }
    })
}

# El primer descendiente de $Raiz (en el arbol visual) que sea de $Tipo, o $null
function Find-Descendiente {
    param($Raiz, [type]$Tipo)
    for ($i = 0; $i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($Raiz); $i++) {
        $h = [Windows.Media.VisualTreeHelper]::GetChild($Raiz, $i)
        if ($h -is $Tipo) { return $h }
        $r = Find-Descendiente $h $Tipo
        if ($r) { return $r }
    }
    return $null
}

# Con el teclado: Espacio marca o desmarca el juego que tiene el foco (las casillas no lo
# cogen) y Enter lo selecciona. Hace falta Enter porque el foco puede estar en un juego sin
# seleccionar (tras Refrescar, o al entrar con el tabulador) y Espacio ya no selecciona.
# En la lista del modo sencillo no hay nada que seleccionar: Enter (A en el mando) tambien marca.
function Invoke-TeclaLista {
    param($s, $e)
    if ($e.Key -ne 'Space' -and $e.Key -ne 'Return') { return }
    # con el enum: comparado con el texto 'None' sale distinto siempre
    if ([Windows.Input.Keyboard]::Modifiers -ne [Windows.Input.ModifierKeys]::None) { return }
    $item = [Windows.Controls.ItemsControl]::ContainerFromElement($s, $e.OriginalSource)
    if (-not $item -and $null -ne $s.SelectedItem) { $item = $s.ItemContainerGenerator.ContainerFromItem($s.SelectedItem) }
    if (-not $item) { return }
    $e.Handled = $true
    if ($e.Key -eq 'Return' -and $s -eq $ctl.LstJuegos) { $item.IsSelected = $true; return }
    # por la casilla, para que el binding lo escriba en Marcado y se vea
    $chk = Find-Descendiente $item ([Windows.Controls.CheckBox])
    if (-not $chk) { return }
    $chk.IsChecked = -not [bool]$chk.IsChecked
    Update-Botones
}
$ctl.LstJuegos.Add_PreviewKeyDown({ param($s, $e) Invoke-TeclaLista $s $e })
$ctl.LstSencillo.Add_PreviewKeyDown({ param($s, $e) Invoke-TeclaLista $s $e })

# Los nombres para las preguntas, sin pasarse de largo
function Get-ListaNombres {
    param([object[]]$Juegos, [int]$Max = 12)
    $todos = @($Juegos)
    $lineas = @($todos | Select-Object -First $Max | ForEach-Object { "  • $($_.Nombre)" })
    if ($todos.Count -gt $Max) { $lineas += "  … y $($todos.Count - $Max) más" }
    return ($lineas -join "`r`n")
}

function Start-AnadirMarcados {
    if ($script:Ocupado) { return }
    $marcados = @(Get-Marcados)
    if (-not $marcados.Count) { return }
    if (-not $script:Steam) { Add-Log (Get-SteamMotivo); return }
    $reemplazar = [bool]$ctl.ChkReemplazar.IsChecked
    $yaEstan = @($marcados | Where-Object { $_.YaEnSteam }).Count
    $texto = "¿Añadir $(Get-CuentaJuegos $marcados.Count) a Steam?`r`n`r`n$(Get-ListaNombres $marcados)`r`n`r`n" +
             "Primero se preparan las carátulas de cada uno (se puede cancelar). Después Steam se " +
             "cerrará una sola vez para añadirlos todos; antes se hace copia de shortcuts.vdf."
    if ($yaEstan -eq 1) {
        $texto += "`r`n`r`n1 ya está en Steam y " + $(if ($reemplazar) { 'se reemplazará.' } else { 'se saltará (marca «Reemplazar si ya existe» para sustituirlo).' })
    } elseif ($yaEstan) {
        $texto += "`r`n`r`n$yaEstan ya están en Steam y " + $(if ($reemplazar) { 'se reemplazarán.' } else { 'se saltarán (marca «Reemplazar si ya existe» para sustituirlos).' })
    }
    $resp = [Windows.MessageBox]::Show($win, $texto, 'Añadir a Steam', 'YesNo', 'Question', 'No')
    if ($resp -ne 'Yes') { return }

    if (-not (Enter-Ocupado -Boton (Get-BotonTarea) -TextoOcupado 'Cancelar')) { return }
    $lanzada = $false
    try {
        $sel = $ctl.LstJuegos.SelectedItem
        $origenArte = Get-OrigenArte
        $hora = Get-Date -Format 'HHmmssfff'
        $lote = @()
        $pendientes = @()
        for ($i = 0; $i -lt $marcados.Count; $i++) {
            $j = $marcados[$i]
            # una copia: al seleccionado se le ponen las opciones del cuadro sin tocar la lista
            $juego = $j.PSObject.Copy()
            $nombre = $j.Nombre
            if ([object]::ReferenceEquals($j, $sel)) {
                $t = $ctl.TxtNombre.Text.Trim()
                if ($t) { $nombre = $t }
                $juego.LaunchOptions = $ctl.TxtOpciones.Text
            }
            $x = [pscustomobject]@{ Item = $j; Juego = $juego; Nombre = $nombre; Rutas = $null }
            $p = $script:Preparado
            if ($p -and [object]::ReferenceEquals($p.Juego, $j) -and $p.Nombre -eq $nombre) {
                $x.Rutas = $p.Rutas
            } elseif ($j.YaEnSteam -and -not $reemplazar) {
                # se va a saltar (Invoke-AnadirJuegos lo vuelve a mirar): no hace falta prepararlo
            } else {
                $appId = Get-SteamShortcutAppId -ExeQuoted ('"' + $juego.Exe + '"') -AppName $nombre
                # el juego elegido a mano que tenga guardado, igual que en "1. Preparar"
                $guardado = Get-ElegidoParaPreparar -Juego $j -OrigenArte $origenArte
                $ids = Get-IdsElegido $guardado.Elegido
                $pendientes += @{ Indice = $i; Juego = $juego; Nombre = $nombre; AppId = $appId
                                  Destino = (Join-Path $TempDir ('{0}-{1}' -f $appId, $hora))
                                  StoreIdElegido = $ids.StoreIdElegido; SgdbIdElegido = $ids.SgdbIdElegido
                                  AvisoElegido = $guardado.Aviso }
            }
            $lote += $x
        }
        $script:Lote = $lote
        if (-not $pendientes.Count) {
            $lanzada = $true      # Invoke-FinAnadirMarcados hace el Exit-Ocupado
            Invoke-FinAnadirMarcados
            return
        }
        Add-Log "Preparando las carátulas de $(Get-CuentaJuegos $pendientes.Count) antes de cerrar Steam. Puedes cancelarlo con el botón «Cancelar»."
        $script:Tarea = Start-TareaFondo -Lib $LibPreparar -Parametros @{ Pendientes = $pendientes; OrigenArte = $origenArte } `
            -Datos @{ TextoCancelado = 'Cancelado: no se ha añadido nada ni se ha tocado Steam.'
                      AlCancelar = { param($t) $script:Lote = $null }
                      AlTerminar = { param($t, $s) Complete-PrepararMarcados $t $s } } `
            -Cuerpo {
                param($Pendientes, $OrigenArte, $Log)
                # uno que falle no para a los demas: se anadira sin caratulas
                $total = @($Pendientes).Count
                $n = 0
                $salida = New-Object System.Collections.Generic.List[object]
                foreach ($p in @($Pendientes)) {
                    $n++
                    & $Log "[$n/$total] $($p.Nombre)" | Out-Null
                    if ($p.AvisoElegido) { & $Log $p.AvisoElegido | Out-Null }
                    try {
                        $c = New-CaratulasSteam -Juego $p.Juego -AppId $p.AppId -GridDir $p.Destino -NombreFinal $p.Nombre `
                                 -OrigenArte $OrigenArte -StoreIdElegido $p.StoreIdElegido -SgdbIdElegido $p.SgdbIdElegido -Log $Log
                        $salida.Add([pscustomobject]@{ Indice = $p.Indice; Rutas = $c.Rutas })
                    } catch {
                        & $Log "  no se han podido preparar: $($_.Exception.Message)" | Out-Null
                        $salida.Add([pscustomobject]@{ Indice = $p.Indice; Rutas = $null })
                    }
                }
                $salida.ToArray()
            }
        [void]$script:Tareas.Add($script:Tarea)
        $script:Reloj.Start()
        $lanzada = $true
        Set-Progreso $true
        Update-Botones      # ahora que hay tarea, el boton de cancelar se enciende
    } catch {
        Add-Log "ERROR preparando los marcados: $($_.Exception.Message)"
        Write-RegistroError -Contexto 'preparar marcados' -Fallo $_
        Complete-CambioSteam -Bien $false -Aviso 'No se ha podido añadir nada.'
    } finally {
        if (-not $lanzada) { $script:Lote = $null; Exit-Ocupado }
    }
}

# Llega desde Update-Tareas al acabar de preparar. Lo de Steam no se hace aqui dentro: tarda
# (cerrarlo, hasta 40 s) y va con Add-Log, que bombea mensajes en pleno tic del reloj.
function Complete-PrepararMarcados {
    param([hashtable]$Tarea, $Salida)
    $script:Tarea = $null
    Set-Progreso $false
    if ($Salida.Fallo) {
        Write-LogVentana "ERROR preparando las carátulas: $($Salida.Fallo.Exception.Message) No se ha añadido nada."
        Write-RegistroError -Contexto 'preparar marcados' -Fallo $Salida.Fallo
        $script:Lote = $null
        Complete-CambioSteam -Bien $false -Aviso 'No se ha podido añadir nada.'
        Exit-Ocupado
        return
    }
    foreach ($r in @($Salida.Resultado)) {
        if ($r -and $r.Rutas) { $script:Lote[[int]$r.Indice].Rutas = $r.Rutas }
    }
    [void]$win.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Background, [action]{ Invoke-FinAnadirMarcados })
}

# Con las caratulas listas: cerrar Steam una vez y anadirlos todos. Sigue ocupado desde
# Start-AnadirMarcados y lo deja libre al terminar.
function Invoke-FinAnadirMarcados {
    $lote = $script:Lote
    $script:Lote = $null
    try {
        if (-not $lote) { return }
        $ctl[(Get-BotonTarea)].Content = 'Añadiendo…'   # Exit-Ocupado le devuelve su texto
        # el mismo Reemplazar con el que se decidio que preparar (la casilla ya no se puede tocar)
        $res = Invoke-AnadirJuegos -Lote $lote -Steam $script:Steam -Reemplazar:([bool]$ctl.ChkReemplazar.IsChecked) `
                   -AbrirBigPicture:([bool]$ctl.ChkBigPicture.IsChecked) -Log $LogGui
        if (-not $res) {
            Complete-CambioSteam -Bien $false -Aviso 'No se ha añadido nada: Steam no se ha cerrado.'
            return
        }
        # se desmarcan los que ya estan en Steam; los que han fallado siguen marcados
        foreach ($r in $res) {
            if ($r.Ok -or $r.Motivo -eq 'duplicado' -or $r.Motivo -eq 'repetido') { $r.Elemento.Lote.Item.Marcado = $false }
        }
        $hechos = @($res | Where-Object { $_.Ok })
        if ($hechos.Count) { Clear-Preview; Update-Deteccion }
        else { Update-Casillas }
        # Bien: alguno anadido, con sus caratulas, y ninguno con error (que ya estuviera no lo
        # es). Si no se ha anadido ninguno, Steam no se ha tocado y no hace falta cerrarse.
        $fallos = @($res | Where-Object { -not $_.Ok -and $_.Motivo -ne 'duplicado' -and $_.Motivo -ne 'repetido' }).Count
        $sinArte = @($hechos | Where-Object { -not $_.CaratulasOk }).Count
        if ($fallos) {
            $t = $(if ($fallos -eq 1) { '1 juego no se ha podido añadir.' } else { "$fallos juegos no se han podido añadir." })
            Complete-CambioSteam -Bien $false -Aviso $t
        } elseif ($sinArte) {
            $t = $(if ($sinArte -eq 1) { '1 juego se ha añadido' } else { "$sinArte juegos se han añadido" })
            Complete-CambioSteam -Bien $false -Aviso "$t con las carátulas incompletas."
        } elseif ($hechos.Count) {
            Complete-CambioSteam -Bien $true -BigPicture ([bool]$ctl.ChkBigPicture.IsChecked) -Anadir
        }
    } catch {
        Add-Log "ERROR: $($_.Exception.Message)"
        Write-RegistroError -Contexto 'añadir varios a Steam' -Fallo $_
        Complete-CambioSteam -Bien $false -Aviso 'Algo ha fallado al añadir.'
    } finally {
        Exit-Ocupado
    }
}

function Invoke-QuitarMarcados {
    $marcados = @(Get-Marcados | Where-Object { $_.YaEnSteam })
    if (-not $marcados.Count) { return }
    if (-not $script:Steam) { Add-Log (Get-SteamMotivo); return }
    $texto = "¿Quitar $(Get-CuentaJuegos $marcados.Count) de la biblioteca de Steam?`r`n`r`n$(Get-ListaNombres $marcados)`r`n`r`n" +
             "Se borran sus accesos directos y sus carátulas. Los juegos no se desinstalan.`r`n" +
             "Si Steam está abierto se cerrará un momento, una sola vez; antes se hace copia de shortcuts.vdf."
    $otros = @(Get-Marcados).Count - $marcados.Count
    if ($otros) { $texto += "`r`n`r`nLos $otros marcados que no están en Steam no se tocan." }
    $resp = [Windows.MessageBox]::Show($win, $texto, 'Quitar de Steam', 'YesNo', 'Question', 'No')
    if ($resp -ne 'Yes') { return }
    try {
        # al quitar, Steam solo se reabre (y en Big Picture, si esta marcado) si estaba abierto
        $bigPicture = ([bool]$ctl.ChkBigPicture.IsChecked -and (Test-SteamCorriendo))
        $res = Invoke-QuitarJuegos -Juegos $marcados -Steam $script:Steam -AbrirBigPicture:([bool]$ctl.ChkBigPicture.IsChecked) -Log $LogGui
        if (-not $res) {
            Complete-CambioSteam -Bien $false -Aviso 'No se ha quitado nada: Steam no se ha cerrado.'
            return
        }
        foreach ($r in $res) { if ($r.Ok -or $r.Motivo -eq 'no-esta') { $r.Elemento.Marcado = $false } }
        $hechos = @($res | Where-Object { $_.Ok }).Count
        if ($hechos) { Clear-Preview; Update-Deteccion }
        else { Update-Casillas }
        $fallos = @($res | Where-Object { -not $_.Ok -and $_.Motivo -ne 'no-esta' }).Count
        if ($fallos) {
            $t = $(if ($fallos -eq 1) { '1 juego no se ha podido quitar.' } else { "$fallos juegos no se han podido quitar." })
            Complete-CambioSteam -Bien $false -Aviso $t
        } elseif ($hechos) {
            Complete-CambioSteam -Bien $true -BigPicture $bigPicture
        }
    } catch {
        Add-Log "ERROR: $($_.Exception.Message)"
        Write-RegistroError -Contexto 'quitar varios de Steam' -Fallo $_
        Complete-CambioSteam -Bien $false -Aviso 'Algo ha fallado al quitar.'
    }
}

$ctl.BtnAnadirMarcados.Add_Click({ Start-AnadirMarcados })
$ctl.BtnQuitarMarcados.Add_Click({ Invoke-Ocupado -Boton 'BtnQuitarMarcados' -TextoOcupado 'Quitando…' -Accion { Invoke-QuitarMarcados } })
$ctl.BtnDesmarcar.Add_Click({ if (-not $script:Ocupado) { Clear-Marcados } })
# En el modo sencillo, el de anadir es tambien el de cancelar mientras se preparan las caratulas
$ctl.BtnAnadirSencillo.Add_Click({ if ($script:Tarea) { Stop-TareaVentana } else { Start-AnadirMarcados } })
$ctl.BtnQuitarSencillo.Add_Click({ Invoke-Ocupado -Boton 'BtnQuitarSencillo' -TextoOcupado 'Quitando…' -Accion { Invoke-QuitarMarcados } })
$ctl.BtnModo.Add_Click({ if (-not $script:Ocupado) { Set-ModoSencillo (-not $script:Sencillo) -Guardar } })

# --- la propia Vaporera en Steam y "Big Picture" ---------------------------
# Para abrirla desde Big Picture con el mando. No esta en ninguna tienda: sus caratulas son las
# de docs\steam\ (las dibuja docs\CrearIcono.ps1), sin preparar ni buscar nada.

# La Vaporera como juego: se lanza como el acceso directo de CrearAccesoDirecto.ps1
function Get-JuegoVaporera {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $opciones = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + (Join-Path $Raiz 'VaporeraArcade.ps1') + '"'
    return (New-Juego -Nombre 'Vaporera Arcade' -Fuente 'Vaporera Arcade' -Exe $ps -StartDir ($Raiz.TrimEnd('\') + '\') `
                -LaunchOptions $opciones -Icono (Join-Path $Raiz 'docs\VaporeraArcade.ico') -Carpeta $Raiz -Detalle 'Esta aplicación')
}

# 'esta' si hay una entrada que la lanza tal cual (aunque se haya renombrado en Steam),
# 'cambiada' si hay una con su nombre pero otra ruta (la carpeta se ha movido: se reemplaza) y
# 'falta' si no hay ninguna
function Get-EstadoVaporera {
    param($Existentes)
    $j = Get-JuegoVaporera
    $porNombre = $false
    foreach ($e in @($Existentes)) {
        if (-not $e) { continue }
        if ([string]$e.Exe -eq $j.Exe -and [string]$e.LaunchOptions -eq $j.LaunchOptions) { return 'esta' }
        if ([string]$e.Nombre -eq $j.Nombre) { $porNombre = $true }
    }
    if ($porNombre) { return 'cambiada' }
    return 'falta'
}

# Las caratulas de docs\steam\ copiadas a una carpeta de %TEMP% con los nombres que espera
# Invoke-Caratulas (<appid>p.png...). $null si falta alguna de las imprescindibles: entonces
# se componen como las de cualquier juego sin tienda.
function Get-CaratulasVaporera {
    param([uint32]$AppId)
    $origen = Join-Path $Raiz 'docs\steam'
    $nombres = [ordered]@{ p = 'portada.png'; cap = 'capsula.png'; hero = 'hero.png'; logo = 'logo.png'; icon = 'icono.png' }
    $destinos = @{ p = "${AppId}p.png"; cap = "${AppId}.png"; hero = "${AppId}_hero.png"; logo = "${AppId}_logo.png"; icon = "${AppId}_icon.png" }
    foreach ($k in $ImagenesClave.Keys) {
        if (-not (Test-Path -LiteralPath (Join-Path $origen $nombres[$k]))) { return $null }
    }
    $dir = Join-Path $TempDir ('{0}-{1}' -f $AppId, (Get-Date -Format 'HHmmssfff'))
    [void](New-Item -ItemType Directory -Path $dir -Force)
    $rutas = @{}
    foreach ($k in $nombres.Keys) {
        $f = Join-Path $origen $nombres[$k]
        if (-not (Test-Path -LiteralPath $f)) { continue }
        $rutas[$k] = Join-Path $dir $destinos[$k]
        Copy-Item -LiteralPath $f -Destination $rutas[$k] -Force
    }
    return $rutas
}

function Invoke-AnadirVaporera {
    if (-not $script:Steam) { Add-Log (Get-SteamMotivo); return }
    try {
        $j = Get-JuegoVaporera
        $reemplazar = ($script:VaporeraEnSteam -eq 'cambiada')
        if ($reemplazar) { Add-Log 'La Vaporera ya estaba en Steam con otra ruta: la actualizo.' }
        $appId = Get-SteamShortcutAppId -ExeQuoted ('"' + $j.Exe + '"') -AppName $j.Nombre
        $rutas = Get-CaratulasVaporera -AppId $appId
        if (-not $rutas) { Add-Log 'Faltan las carátulas de docs\steam\: las compongo con el icono.' }
        $r = Invoke-AnadirJuego -Juego $j -Nombre $j.Nombre -Steam $script:Steam -Reemplazar:$reemplazar `
                -AbrirBigPicture:([bool]$ctl.ChkBigPicture.IsChecked) -CaratulasListas $rutas -OrigenArte 'Local' -Log $LogGui
        if ($r.Ok) { Update-Deteccion }
        if ($r.Ok -and $r.CaratulasOk) { Complete-CambioSteam -Bien $true -BigPicture ([bool]$ctl.ChkBigPicture.IsChecked) -Anadir }
        elseif ($r.Ok) { Complete-CambioSteam -Bien $false -Aviso 'La Vaporera se ha añadido con las carátulas incompletas.' }
        else { Complete-CambioSteam -Bien $false -Aviso 'No se ha podido añadir la Vaporera.' }
    } catch {
        Add-Log "ERROR añadiendo la Vaporera a Steam: $($_.Exception.Message)"
        Write-RegistroError -Contexto 'añadir la Vaporera a Steam' -Fallo $_
        Complete-CambioSteam -Bien $false -Aviso 'No se ha podido añadir la Vaporera.'
    }
}
$ctl.BtnVaporeraSteam.Add_Click({ Invoke-Ocupado -Boton 'BtnVaporeraSteam' -TextoOcupado 'Añadiendo…' -Accion { Invoke-AnadirVaporera } })

# "Big Picture": abre Steam en Big Picture (lo arranca si estaba cerrado) y cierra la Vaporera,
# como al salir de un juego. Ocupada, el boton esta apagado.
$ctl.BtnBigPicture.Add_Click({
    if ($script:Ocupado -or -not $script:Steam) { return }
    try {
        if (Test-SteamCorriendo) { Start-Process 'steam://open/bigpicture' }
        else { Start-Steam -SteamExe $script:Steam.Exe -BigPicture }
    } catch {
        Add-Log "No he podido abrir Big Picture: $($_.Exception.Message)"
        Write-RegistroError -Contexto 'abrir Big Picture' -Fallo $_
        return
    }
    Write-Registro 'Big Picture abierto: cierro la Vaporera.'
    $win.Close()
})

# Si a la Vaporera la ha lanzado Steam (desde la biblioteca o Big Picture). Lo mira el cierre.
# Se pregunta despues de pintar la ventana: la primera consulta a WMI tarda.
$script:DesdeSteam = $false
function Test-AbiertaDesdeSteam {
    try {
        $padre = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop).ParentProcessId
        $p = Get-Process -Id $padre -ErrorAction Stop
        return ($p.ProcessName -eq 'steam')
    } catch { return $false }
}

# --- el mando -----------------------------------------------------------
# lib\Mando.ps1 dice que botones se acaban de pulsar y aqui cada uno se convierte en la tecla
# que hace lo mismo. Solo con una ventana de la aplicacion delante (tambien la galeria, un
# MessageBox o el dialogo de abrir fichero). Se lee con un reloj propio: $script:Reloj solo
# corre mientras hay tareas.
$script:RelojMando = $null
$script:MandosAntes = 0     # para avisar en el registro al conectar o desconectar uno

# boton -> tecla virtual. A va aparte (Get-TeclaA) y LB es Mayus+Tab.
$TeclasMando = @{
    0x0001 = 0x26   # cruceta o stick arriba -> flecha arriba
    0x0002 = 0x28   # abajo
    0x0004 = 0x25   # izquierda
    0x0008 = 0x27   # derecha
    0x2000 = 0x1B   # B -> Escape: cierra la ventana o el desplegable
    0x4000 = 0x20   # X -> Espacio: marca el juego en la lista
    0x0100 = 0x09   # LB -> Mayus+Tab: el control anterior
    0x0200 = 0x09   # RB -> Tab: el siguiente
}

# A es "pulsar lo que tiene el foco": Enter, salvo en una casilla (Espacio, Enter no la marca)
# y en el desplegable cerrado (F4 lo abre; abierto, Enter elige). En un MessageBox o en el
# dialogo de abrir fichero, que no son de WPF, siempre Enter.
function Get-TeclaA {
    if ([Windows.Interop.HwndSource]::FromHwnd([VaporeraArcade.Mando]::Ventana)) {
        $f = [Windows.Input.Keyboard]::FocusedElement
        if ($f -is [Windows.Controls.Primitives.ToggleButton]) { return 0x20 }
        if ($f -is [Windows.Controls.ComboBox] -and -not $f.IsDropDownOpen) { return 0x73 }
    }
    return 0x0D
}

function Invoke-TicMando {
    try {
        foreach ($b in [VaporeraArcade.Mando]::Tic()) {
            if ($b -eq [VaporeraArcade.Mando]::A) { [VaporeraArcade.Mando]::Pulsar((Get-TeclaA), $false) }
            elseif ($TeclasMando.ContainsKey($b)) { [VaporeraArcade.Mando]::Pulsar($TeclasMando[$b], ($b -eq [VaporeraArcade.Mando]::LB)) }
        }
        # Mandos solo cambia con la ventana delante, que es cuando el aviso se lee. Sin
        # Add-Log: bombearia mensajes dentro del tic.
        $n = [VaporeraArcade.Mando]::Mandos
        if ([VaporeraArcade.Mando]::Ventana -ne [IntPtr]::Zero -and $n -ne $script:MandosAntes) {
            if ($n -and -not $script:MandosAntes) { Write-LogVentana 'Mando conectado: A pulsa, B cierra, X marca, la cruceta mueve y LB/RB saltan de un control a otro.' }
            elseif (-not $n) { Write-LogVentana 'Mando desconectado.' }
            $script:MandosAntes = $n
        }
    } catch {
        # un fallo aqui se repetiria en cada tic: se para y la aplicacion sigue sin mando
        $script:RelojMando.Stop()
        Write-RegistroError -Contexto 'leer el mando' -Fallo $_
        Write-LogVentana 'El mando ha dejado de funcionar (el detalle está en el registro). Lo demás sigue igual.'
    }
}

# Se llama con la ventana ya en marcha: compilar el C# tarda un poco y no tiene que retrasar
# que aparezca. Si no se puede (antivirus, modo restringido), la aplicacion sigue sin mando.
function Start-Mando {
    try { Initialize-Mando }
    catch {
        Write-Registro "Sin mando: no he podido cargar la lectura de XInput ($($_.Exception.Message)). Lo demás funciona igual."
        return
    }
    $script:RelojMando = New-Object Windows.Threading.DispatcherTimer
    $script:RelojMando.Interval = [TimeSpan]::FromMilliseconds(40)
    $script:RelojMando.Add_Tick({ Invoke-TicMando })
    $script:RelojMando.Start()
}

# "Preparar caratulas" deja cada juego en %TEMP%\VaporeraArcade\<appid>-<hora>\ (~1,6 MB) y
# solo se borra al volver a preparar el mismo appid: lo preparado y no anadido, o lo de un
# nombre que luego se cambio, se quedaba ahi para siempre. Lo preparado no sobrevive a la
# sesion, pero no se borra todo: con dos ventanas abiertas, la segunda se llevaria lo que acaba
# de preparar la primera. Solo carpetas con nombre de appid (hasta la 0.8 sin la hora), por si
# alguien deja algo mas ahi.
function Remove-TempViejo {
    param([int]$Horas = 24)
    if (-not (Test-Path -LiteralPath $TempDir)) { return }
    $limite = (Get-Date).AddHours(-$Horas)
    $n = 0
    foreach ($d in @(Get-ChildItem -LiteralPath $TempDir -Directory -ErrorAction SilentlyContinue)) {
        if ($d.Name -notmatch '^\d+(-\d+)?$' -or $d.LastWriteTime -gt $limite) { continue }
        try { Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction Stop; $n++ } catch { }
    }
    if ($n) { Write-Registro "Borradas $n carpetas de carátulas preparadas hace más de $Horas horas en $TempDir." }
}

# --- arranque --------------------------------------------------------
Remove-TempViejo
$win.Title = "Vaporera Arcade $AppVersion"
if ($script:IconoVentana) { $win.Icon = $script:IconoVentana }
$ctl.TxtVersion.Text = "v$AppVersion"
if ($script:Steam) {
    $ctl.TxtSteam.Text = "Perfil $($script:Steam.UserId)  ~  $($script:Steam.Shortcuts)"
    # con varias cuentas en el mismo PC conviene dejar claro en cual se va a escribir
    if ($script:Steam.Perfiles -gt 1) {
        Write-Registro "Hay $($script:Steam.Perfiles) perfiles de Steam; se usa el $($script:Steam.UserId) ($($script:Steam.ComoElegido))."
    }
} else {
    $ctl.TxtSteam.Text = Get-SteamMotivo
}
# en el ultimo modo usado (Set-ModoSencillo tambien llama a Update-Botones)
$modoGuardado = $false
try { $modoGuardado = ((Get-Config)['ModoSencillo'] -eq $true) }
catch { Write-Registro "No he podido leer el modo guardado: $($_.Exception.Message)" }
Set-ModoSencillo $modoGuardado
if ($modoGuardado) { Write-Registro 'Arranca en el modo sencillo.' }

# Con una operacion en marcha Steam esta cerrado y el VDF puede estar a medio escribir, asi que
# la X de la ventana tampoco vale: Update-Interfaz deja que WPF la atienda ahi en medio.
# Preparar caratulas es otra cosa: solo escribe en %TEMP%, se cancela y se cierra.
# Aqui nada de Add-Log: llamaria a Update-Interfaz estando ya dentro de una.
# Abierta desde Steam, Steam la trata como un juego en marcha y al cerrarse le pide que se
# cierre: pasa siempre que anade o quita, porque es la propia Vaporera la que cierra Steam. Se
# queda (Steam tarda unos 10 s mas y se cierra igual) y lo explica.
$win.Add_Closing({
    if ($script:Tarea) { Stop-TareaVentana; return }
    if ($script:Ocupado) {
        $_.Cancel = $true
        if ($script:DesdeSteam) { Write-LogVentana 'Steam pide cerrar la Vaporera al cerrarse (la abriste desde Steam): sigue abierta hasta terminar.' }
        else { Write-LogVentana 'Espera a que termine la operación en curso.' }
    }
})

# Si la ventana sale detras (o se vuelve a ella desde Big Picture), al ponerla delante WPF no
# siempre le da el foco a nadie, y el teclado no hace nada hasta pulsar el tabulador. Despues
# de que WPF haga lo suyo: si no ha puesto el foco en ningun sitio, al que lo tenia o a la lista.
$win.Add_Activated({
    [void]$win.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Input, [action]{
        if ($script:Ocupado -or -not $win.IsActive -or [Windows.Input.Keyboard]::FocusedElement) { return }
        $f = [Windows.Input.FocusManager]::GetFocusedElement($win)
        if (-not (Test-ControlUsable $f)) { $f = Get-FocoLista }
        [void]$f.Focus()
    })
})
$win.Add_ContentRendered({
    Invoke-Ocupado { Update-Deteccion }
    Start-Mando
    $script:DesdeSteam = Test-AbiertaDesdeSteam
    if ($script:DesdeSteam) { Write-Registro 'Abierta desde Steam.' }
})
[void]$win.ShowDialog()
