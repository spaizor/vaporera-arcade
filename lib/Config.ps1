# =====================================================================
#  Config.ps1 - Ajustes del usuario
#
#  Se guardan en %LOCALAPPDATA%\VaporeraArcade\config.json, fuera de la
#  carpeta de la aplicacion: asi funciona aunque este instalada en una
#  ruta sin permiso de escritura y la clave nunca acaba en el repositorio.
#  Lo que hay: la clave de SteamGridDB ('SgdbClave') y los juegos elegidos
#  a mano para las caratulas ('JuegosElegidos', mas abajo).
# =====================================================================

function Get-ConfigRuta {
    return (Join-Path (Join-Path $env:LOCALAPPDATA 'VaporeraArcade') 'config.json')
}

# Devuelve los ajustes como hashtable (vacia si no hay fichero o esta roto). Solo el primer
# nivel: lo anidado llega como lo deja ConvertFrom-Json, pscustomobject y listas.
function Get-Config {
    $cfg = @{}
    $f = Get-ConfigRuta
    if (Test-Path -LiteralPath $f) {
        try {
            $obj = [IO.File]::ReadAllText($f) | ConvertFrom-Json
            foreach ($p in $obj.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
        } catch { }
    }
    return $cfg
}

# Guarda un ajuste. Un valor vacio ($null, '' o una lista sin nada) lo borra.
function Set-ConfigValor {
    param([Parameter(Mandatory)][string]$Nombre, $Valor)
    $cfg = Get-Config
    # No vale mirar [string]$Valor: una lista con un solo pscustomobject da '' y se borraria
    $vacio = ($null -eq $Valor) -or ($Valor -is [string] -and $Valor -eq '') -or
             ($Valor -is [System.Collections.ICollection] -and $Valor.Count -eq 0)
    if ($vacio) { $cfg.Remove($Nombre) } else { $cfg[$Nombre] = $Valor }
    $f = Get-ConfigRuta
    $dir = Split-Path $f -Parent
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    # -Depth: por defecto ConvertTo-Json corta a dos niveles y lo de mas adentro lo escribe
    # como texto ('System.Collections.Hashtable')
    $json = New-Object PSObject -Property $cfg | ConvertTo-Json -Depth 8
    # Al lado y cambiado de sitio al final, como shortcuts.vdf: escribiendo encima, un corte a
    # medias deja el fichero truncado, que se lee como vacio, y con el se pierden la clave y lo
    # elegido a mano. NullString y no $null: PS lo pasa como '' y Replace lo rechaza.
    $tmp = "$f.tmp"
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $f) {
        try { [IO.File]::Replace($tmp, $f, [NullString]::Value) }
        catch { Move-Item -LiteralPath $tmp -Destination $f -Force }
    } else {
        Move-Item -LiteralPath $tmp -Destination $f
    }
}

# ---------------------------------------------------------------------
#  Juegos elegidos a mano en la galeria ("Elegir otro juego...")
#
#  Se guardan para que la eleccion siga ahi al cerrar el programa: la proxima vez que se
#  preparan las caratulas de ese juego se usa el elegido, sin buscar por el nombre. En
#  config.json van en 'JuegosElegidos', una lista con un elemento por juego:
#    Exe, Opciones       el juego del PC: su exe y las opciones de lanzamiento con las que se
#                        detecto (OpcionesOrigen de New-Juego). No vale el appid, que cambia con
#                        el nombre; ni el exe solo, que los juegos de Epic y de Ubisoft comparten
#                        (el del lanzador) y se distinguen por las opciones; ni las opciones del
#                        cuadro de texto, que se pueden editar.
#    Fuente, Id, Titulo  el elegido: un resultado de Get-CandidatosJuego
#  Una lista y no una tabla con el juego de clave: ConvertFrom-Json no admite dos claves que
#  solo cambien en las mayusculas, y una ruta se puede escribir de las dos formas.
# ---------------------------------------------------------------------

# La lista guardada (usar @(...) al recogerla). Get-Config la devuelve como pscustomobject, y
# si el fichero se ha tocado a mano puede traer cualquier cosa: lo que no este entero, fuera.
function Get-JuegosElegidos {
    $lista = @()
    foreach ($e in @((Get-Config)['JuegosElegidos'])) {
        if (-not $e -or -not $e.Exe -or -not $e.Fuente -or -not $e.Id) { continue }
        $lista += [pscustomobject]@{
            Exe = [string]$e.Exe; Opciones = [string]$e.Opciones
            Fuente = [string]$e.Fuente; Id = [string]$e.Id; Titulo = [string]$e.Titulo
        }
    }
    return $lista
}

# El elegido de ese juego dentro de $Lista (la de Get-JuegosElegidos), o $null. Sin
# distinguir mayusculas, como las rutas de Windows.
function Find-JuegoElegido {
    param([object[]]$Lista, [string]$Exe, [string]$Opciones = '')
    foreach ($e in @($Lista)) {
        if ($e -and ([string]$e.Exe) -eq $Exe -and ([string]$e.Opciones) -eq $Opciones) { return $e }
    }
    return $null
}

# Guarda el elegido de un juego, en lugar del que tuviera. Devuelve la lista como queda.
function Set-JuegoElegido {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [string]$Opciones = '',
        [Parameter(Mandatory)][string]$Fuente,
        [Parameter(Mandatory)][string]$Id,
        [string]$Titulo = ''
    )
    $lista = @(Get-JuegosElegidos | Where-Object { -not ($_.Exe -eq $Exe -and $_.Opciones -eq $Opciones) })
    $lista += [pscustomobject]@{ Exe = $Exe; Opciones = $Opciones; Fuente = $Fuente; Id = $Id; Titulo = $Titulo }
    Set-ConfigValor -Nombre 'JuegosElegidos' -Valor $lista
    return $lista
}

# Olvida el elegido de un juego: se vuelve a buscar por el nombre. Devuelve la lista como
# queda; si no habia ninguno, no escribe nada.
function Remove-JuegoElegido {
    param([Parameter(Mandatory)][string]$Exe, [string]$Opciones = '')
    $antes = @(Get-JuegosElegidos)
    $lista = @($antes | Where-Object { -not ($_.Exe -eq $Exe -and $_.Opciones -eq $Opciones) })
    if ($lista.Count -ne $antes.Count) { Set-ConfigValor -Nombre 'JuegosElegidos' -Valor $lista }
    return $lista
}
