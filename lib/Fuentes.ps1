# =====================================================================
#  Fuentes.ps1 - Deteccion de juegos instalados por origen
#  Devuelve objetos con: Nombre, Fuente, Exe, StartDir, LaunchOptions,
#                        Icono, StoreId, Carpeta, Detalle
# =====================================================================

function New-Juego {
    param(
        [string]$Nombre, [string]$Fuente, [string]$Exe, [string]$StartDir,
        [string]$LaunchOptions = '', [string]$Icono = '', [string]$StoreId = '',
        [string]$Carpeta = '', [string]$Detalle = '', [datetime]$Fecha = [datetime]::MinValue
    )
    [pscustomobject]@{
        Nombre        = $Nombre
        Fuente        = $Fuente
        Exe           = $Exe
        StartDir      = $StartDir
        LaunchOptions = $LaunchOptions
        Icono         = $Icono
        StoreId       = $StoreId
        Carpeta       = $Carpeta
        Detalle       = $Detalle
        Fecha         = $Fecha
        YaEnSteam     = $false
        AppId         = [uint32]0
    }
}

# ---------------------------------------------------------------------
#  Xbox / Game Pass  ->  C:\XboxGames\<Juego>\Content\gamelaunchhelper.exe
# ---------------------------------------------------------------------
# Raices donde buscar juegos instalados. Get-PSDrive devuelve tambien unidades de red y
# lectores: un Test-Path sobre una unidad de red desconectada tarda segundos y la ventana se
# queda parada nada mas arrancar. Solo unidades fijas (Win32_LogicalDisk DriveType 3).
function Get-UnidadesFijas {
    try {
        return @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop |
                 ForEach-Object { $_.DeviceID + '\' })
    } catch {
        # de reserva: PSDrive sin DisplayRoot (las de red si lo tienen)
        return @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
                 Where-Object { -not $_.DisplayRoot } | ForEach-Object { $_.Root })
    }
}

# La carpeta de los juegos de Xbox no tiene por que ser <unidad>\XboxGames: el usuario la elige
# al instalar y la de verdad esta en el fichero .GamingRoot de la raiz de cada unidad.
# Formato (comprobado): 'RGBX' + un DWORD + la ruta en UTF-16LE terminada en nulo, normalmente
# relativa a la unidad ("XboxGames"), a veces absoluta.
function Get-RaizDeGamingRoot {
    param([string]$Unidad)
    $f = Join-Path $Unidad '.GamingRoot'
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try {
        $b = [IO.File]::ReadAllBytes($f)
        if ($b.Length -le 8) { return $null }
        if ([Text.Encoding]::ASCII.GetString($b, 0, 4) -ne 'RGBX') { return $null }
        $txt = [Text.Encoding]::Unicode.GetString($b, 8, $b.Length - 8)
        $ruta = ($txt -split "`0" | Where-Object { $_ } | Select-Object -First 1)
        if (-not $ruta) { return $null }
        if ($ruta -match '^[A-Za-z]:') { return $ruta }        # absoluta
        return (Join-Path $Unidad $ruta)                        # relativa a la unidad
    } catch { return $null }
}

# Las raices donde mirar: la del .GamingRoot de cada unidad fija y, siempre, la de por defecto.
function Get-RaicesXbox {
    $vistas = @{}
    $res = @()
    foreach ($unidad in (Get-UnidadesFijas)) {
        foreach ($cand in @((Get-RaizDeGamingRoot -Unidad $unidad), (Join-Path $unidad 'XboxGames'))) {
            if (-not $cand) { continue }
            $clave = $cand.TrimEnd('\').ToLower()
            if ($vistas.ContainsKey($clave)) { continue }
            $vistas[$clave] = $true
            if (Test-Path -LiteralPath $cand) { $res += $cand }
        }
    }
    return $res
}

function Get-JuegosXbox {
    $res = @()
    foreach ($raiz in (Get-RaicesXbox)) {
        foreach ($dir in Get-ChildItem -LiteralPath $raiz -Directory -ErrorAction SilentlyContinue) {
            if ($dir.Name -eq 'GameSave') { continue }
            $content = Join-Path $dir.FullName 'Content'
            $helper  = Join-Path $content 'gamelaunchhelper.exe'
            if (-not (Test-Path -LiteralPath $helper)) { continue }

            $nombre = $dir.Name; $storeId = ''; $icono = ''
            $cfg = Join-Path $content 'MicrosoftGame.config'
            if (Test-Path -LiteralPath $cfg) {
                try {
                    [xml]$x = Get-Content -LiteralPath $cfg -Raw -Encoding UTF8
                    # DefaultDisplayName puede venir como "ms-resource:AppTitle": es una
                    # referencia al catalogo de recursos del paquete, no un nombre. Resolverlo
                    # de verdad hace falta el paquete instalado; el nombre de la carpeta, que
                    # Windows saca del titulo real, es mejor que ensenar "ms-resource:...".
                    $nom = $x.Game.ShellVisuals.DefaultDisplayName
                    if ($nom -and $nom -notmatch '^ms-resource:') { $nombre = $nom }
                    if ($x.Game.StoreId) { $storeId = $x.Game.StoreId }
                    foreach ($cand in @($x.Game.ShellVisuals.Square480x480Logo, $x.Game.ShellVisuals.Square150x150Logo, $x.Game.ShellVisuals.StoreLogo)) {
                        if ($cand) {
                            $p = Join-Path $content $cand
                            if (Test-Path -LiteralPath $p) { $icono = $p; break }
                        }
                    }
                } catch { }
            }
            if (-not $icono) {
                foreach ($cand in @('Resources\Square480x480Logo.png','MediumLogo.png','Square150x150Logo.png','StoreLogo.png')) {
                    $p = Join-Path $content $cand
                    if (Test-Path -LiteralPath $p) { $icono = $p; break }
                }
            }
            $res += New-Juego -Nombre $nombre -Fuente 'Xbox / Game Pass' `
                    -Exe $helper -StartDir ($content + '\') -Icono $icono -StoreId $storeId `
                    -Carpeta $content -Detalle 'gamelaunchhelper.exe (lanzador oficial firmado)' `
                    -Fecha $dir.LastWriteTime
        }
    }
    return $res
}

# ---------------------------------------------------------------------
#  Ubisoft Connect  ->  UbisoftConnect.exe + uplay://launch/<id>/0
# ---------------------------------------------------------------------
# El nombre de verdad no esta en la clave de Ubisoft (solo guarda InstallDir e idioma) sino en
# la de desinstalacion que crea el lanzador, "Uplay Install <id>" (comprobado con Rayman
# Origins). La carpeta no sirve: hay juegos que se instalan en "ACValhalla" y similares.
# Se quitan los simbolos de marca, que algunos titulos traen (Rainbow Six(R) Siege) y en la
# biblioteca de Steam quedan feos. $Bases solo se cambia para probar.
function Get-NombreUbisoft {
    param(
        [string]$Id,
        [string[]]$Bases = @('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
                             'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
    )
    foreach ($base in $Bases) {
        $p = Get-ItemProperty -LiteralPath (Join-Path $base "Uplay Install $Id") -ErrorAction SilentlyContinue
        if (-not $p -or -not $p.DisplayName) { continue }
        $nom = ($p.DisplayName -replace '[\u2122\u00AE\u00A9]', '' -replace '\s{2,}', ' ').Trim()
        if ($nom) { return $nom }
    }
    return $null
}

# La misma clave trae en DisplayIcon un .ico que el lanzador deja en data\ (con 256x256 en el
# caso de Rayman Origins), mejor que el 32x32 que sale del exe. Viene con '/' y puede traer
# comillas y el ',<indice>' de los iconos dentro de un exe. $Bases solo se cambia para probar.
function Get-IconoUbisoft {
    param(
        [string]$Id,
        [string[]]$Bases = @('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
                             'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
    )
    foreach ($base in $Bases) {
        $p = Get-ItemProperty -LiteralPath (Join-Path $base "Uplay Install $Id") -ErrorAction SilentlyContinue
        if (-not $p -or -not $p.DisplayIcon) { continue }
        $ruta = ($p.DisplayIcon.Trim() -replace ',\s*-?\d+$', '').Trim().Trim('"') -replace '/', '\'
        if ($ruta -match '\.(ico|exe)$' -and (Test-Path -LiteralPath $ruta -PathType Leaf)) { return $ruta }
    }
    return $null
}

function Get-JuegosUbisoft {
    $res = @()
    $lk = 'HKLM:\SOFTWARE\WOW6432Node\Ubisoft\Launcher'
    if (-not (Test-Path $lk)) { return $res }
    $launcherDir = (Get-ItemProperty $lk -ErrorAction SilentlyContinue).InstallDir
    if (-not $launcherDir) { return $res }
    $launcherExe = Join-Path ($launcherDir -replace '/','\') 'UbisoftConnect.exe'
    if (-not (Test-Path -LiteralPath $launcherExe)) { return $res }
    $startDir = (Split-Path $launcherExe -Parent) + '\'

    foreach ($k in Get-ChildItem "$lk\Installs" -ErrorAction SilentlyContinue) {
        $id  = Split-Path $k.Name -Leaf
        $dir = (Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue).InstallDir
        if (-not $dir) { continue }
        $dir = $dir -replace '/','\'
        # El registro conserva la clave de juegos desinstalados y de los que estan en un disco
        # desconectado. Sin esta comprobacion, Get-Item devuelve $null, '-Fecha $null' no se
        # puede convertir a [datetime] y la excepcion se lleva por delante la deteccion de
        # TODOS los origenes: el usuario ve la lista vacia.
        $info = Get-Item -LiteralPath $dir -ErrorAction SilentlyContinue
        if (-not $info) { continue }
        # si no hay clave de desinstalacion, la carpeta, como antes
        $nombre = Get-NombreUbisoft -Id $id
        if (-not $nombre) { $nombre = Split-Path $dir.TrimEnd('\') -Leaf }
        # El icono, del .ico del registro. Si no lo hay, del exe mas grande del juego, que
        # solo se usa para eso. Con -Recurse a pelo esto recorre el juego entero: en uno de
        # 100 GB tarda minutos y congela la ventana. Dos niveles bastan (el ejecutable esta
        # en la raiz o en bin\, Binaries\...) y se descartan los instaladores y utilidades,
        # que si no ganan por tamano en algunos juegos.
        $icono = Get-IconoUbisoft -Id $id
        if (-not $icono) {
            $icono = ''
            $exeGrande = Get-ChildItem -LiteralPath $dir -Filter *.exe -Recurse -Depth 2 -File -ErrorAction SilentlyContinue |
                         Where-Object { $_.Name -notmatch '^(unins|setup|install|vcredist|vc_redist|dxsetup|dotnet|oalinst|UbisoftGameLauncher|UplayCrashReporter|.*[Cc]rash.*)' } |
                         Sort-Object Length -Descending | Select-Object -First 1
            if ($exeGrande) { $icono = $exeGrande.FullName }
        }
        $res += New-Juego -Nombre $nombre -Fuente 'Ubisoft Connect' `
                -Exe $launcherExe -StartDir $startDir -LaunchOptions "uplay://launch/$id/0" `
                -Icono $icono -Carpeta $dir -Detalle "URI de Ubisoft (el .exe directo no arranca por DRM)" `
                -Fecha $info.LastWriteTime
    }
    return $res
}

# ---------------------------------------------------------------------
#  Epic Games  ->  manifiestos .item
# ---------------------------------------------------------------------
# El exe del lanzador no esta en ninguna clave de instalacion: el registro de Epic solo guarda
# AppDataPath (comprobado). Sale del handler del protocolo, que es quien lo sabe siempre.
function Get-EpicLauncherExe {
    try {
        $cmd = (Get-ItemProperty 'Registry::HKEY_CLASSES_ROOT\com.epicgames.launcher\shell\open\command' -ErrorAction Stop).'(default)'
        if ($cmd -match '^"([^"]+)"') {
            if (Test-Path -LiteralPath $matches[1]) { return $matches[1] }
        }
    } catch { }
    foreach ($base in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
        if (-not $base) { continue }
        foreach ($bits in @('Win64','Win32')) {
            $c = Join-Path $base "Epic Games\Launcher\Portal\Binaries\$bits\EpicGamesLauncher.exe"
            if (Test-Path -LiteralPath $c) { return $c }
        }
    }
    return $null
}

# Un manifiesto .item no es siempre un juego: hay motores (Unreal Engine), plugins, DLC y
# descargas a medias. Lo que se cuela aqui acaba en la lista como si fuera un juego mas.
function Test-EpicEsJuego {
    param($Manifiesto)
    if ($Manifiesto.bIsIncompleteInstall) { return $false }
    # los DLC apuntan con MainGameAppName al juego del que cuelgan
    if ($Manifiesto.MainGameAppName -and $Manifiesto.MainGameAppName -ne $Manifiesto.AppName) { return $false }
    $cats = @()
    if ($Manifiesto.AppCategories) { $cats = @($Manifiesto.AppCategories) }
    # sin categorias no se puede decidir: se deja pasar, mas vale de mas que de menos
    if ($cats.Count -eq 0) { return $true }
    return ($cats -contains 'games')
}

function Get-JuegosEpic {
    $res = @()
    $man = Join-Path $env:ProgramData 'Epic\EpicGamesLauncher\Data\Manifests'
    if (-not (Test-Path -LiteralPath $man)) { return $res }
    $launcher = Get-EpicLauncherExe
    foreach ($f in Get-ChildItem -LiteralPath $man -Filter *.item -ErrorAction SilentlyContinue) {
        try { $j = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        if (-not $j.InstallLocation -or -not $j.LaunchExecutable) { continue }
        if (-not (Test-EpicEsJuego $j)) { continue }
        $exe = Join-Path $j.InstallLocation $j.LaunchExecutable
        if (-not (Test-Path -LiteralPath $exe)) { continue }

        if ($launcher -and $j.AppName) {
            # Por el lanzador, como Ubisoft: el .exe directo falla en los juegos que comprueban
            # la propiedad o necesitan los servicios online. El icono sigue saliendo del exe del
            # juego, que si no seria el del lanzador para todos.
            # La URI se monta concatenando: en "...apps/$id?action=..." PS leeria $id?action
            # como nombre de variable.
            $uri = 'com.epicgames.launcher://apps/' + $j.AppName + '?action=launch&silent=true'
            $res += New-Juego -Nombre $j.DisplayName -Fuente 'Epic Games' `
                    -Exe $launcher -StartDir ((Split-Path $launcher -Parent) + '\') `
                    -LaunchOptions $uri -Icono $exe `
                    -Carpeta $j.InstallLocation -Detalle 'URI de Epic (el .exe directo falla en los juegos con comprobación online)' `
                    -Fecha $f.LastWriteTime
        } else {
            $res += New-Juego -Nombre $j.DisplayName -Fuente 'Epic Games' `
                    -Exe $exe -StartDir ((Split-Path $exe -Parent) + '\') -Icono $exe `
                    -Carpeta $j.InstallLocation -Detalle 'Ejecutable directo del juego (no encuentro el lanzador de Epic)' `
                    -Fecha $f.LastWriteTime
        }
    }
    return $res
}

# ---------------------------------------------------------------------
#  GOG Galaxy
#
#  PENDIENTE DE PROBAR CON UN JUEGO DE VERDAD (22-09-2026). Es el unico origen que no se ha
#  verificado en una instalacion real: no hay GOG Galaxy en el PC de desarrollo, asi que esto
#  esta probado solo contra claves de registro sinteticas. Nadie ha visto todavia un juego de
#  GOG detectado, anadido y arrancado desde Steam.
#  Cuando haya con que probar, mirar las dos cosas que no se pueden resolver a ciegas:
#    - launchParam se copia TAL CUAL a LaunchOptions del VDF. Si GOG mete rutas entrecomilladas
#      o argumentos con espacios, hay que ver si Steam los pasa igual o hay que reescribirlos.
#    - Si workingDir es de fiar como carpeta de inicio del juego.
# ---------------------------------------------------------------------
function Get-JuegosGog {
    $res = @()
    foreach ($base in @('HKLM:\SOFTWARE\WOW6432Node\GOG.com\Games','HKLM:\SOFTWARE\GOG.com\Games')) {
        foreach ($k in Get-ChildItem $base -ErrorAction SilentlyContinue) {
            $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
            if (-not $p.path -or -not $p.exe) { continue }
            $exe = if (Test-Path -LiteralPath $p.exe) { $p.exe } else { Join-Path $p.path $p.exe }
            if (-not (Test-Path -LiteralPath $exe)) { continue }
            # GOG guarda junto al exe los argumentos con los que hay que lanzarlo
            # (launchParam) y su carpeta de trabajo (workingDir), y antes se ignoraban los
            # dos. Sin launchParam hay juegos que arrancan en la configuracion que no toca
            # (o no arrancan); sin workingDir, los que esperan estar en su carpeta no
            # encuentran sus datos. Los dos valores son opcionales: si no estan, se queda
            # como estaba, con la carpeta del propio exe.
            $trabajo = ''
            if ($p.workingDir) { $trabajo = ([string]$p.workingDir) -replace '/','\' }
            if (-not $trabajo -or -not (Test-Path -LiteralPath $trabajo)) { $trabajo = Split-Path $exe -Parent }
            # '$parametros' y no '$args': $args es una variable automatica de PowerShell
            # (los argumentos sin enlazar de la funcion) y no hay que pisarla.
            $parametros = ''
            if ($p.launchParam) { $parametros = ([string]$p.launchParam).Trim() }
            $res += New-Juego -Nombre $p.gameName -Fuente 'GOG' `
                    -Exe $exe -StartDir ($trabajo.TrimEnd('\') + '\') -LaunchOptions $parametros -Icono $exe `
                    -Carpeta $p.path -Detalle 'Ejecutable directo del juego'
        }
    }
    return $res
}

# ---------------------------------------------------------------------
#  Apps de la Store (UWP): sin .exe, van por explorer.exe + AUMID
# ---------------------------------------------------------------------
# Ancho de un PNG leyendo solo la cabecera (IHDR, bytes 16-19, big-endian), sin cargar la
# imagen: se miran decenas por app y System.Drawing no esta cargado en esta lib.
function Get-AnchoPng {
    param([string]$Ruta)
    $fs = $null
    try {
        $fs = [IO.File]::OpenRead($Ruta)
        $b = New-Object byte[] 24
        if ($fs.Read($b, 0, 24) -lt 24) { return 0 }
        if ($b[1] -ne 0x50 -or $b[2] -ne 0x4E -or $b[3] -ne 0x47) { return 0 }   # 'PNG'
        return (([int]$b[16] -shl 24) -bor ([int]$b[17] -shl 16) -bor ([int]$b[18] -shl 8) -bor [int]$b[19])
    } catch { return 0 }
    finally { if ($fs) { $fs.Dispose() } }
}

# Los ficheros de un logo del manifiesto: el manifiesto dice 'Assets\Logo.png' pero en disco
# estan 'Logo.scale-200.png', 'Logo.targetsize-256_altform-unplated.png'... (calificadores
# en cualquier orden) y a veces tambien el fichero tal cual. Fuera las variantes de alto
# contraste y las 'lightunplated', que son para fondo claro (negras sobre transparente).
function Get-VariantesLogo {
    param([string]$Carpeta, [string]$Relativa)
    if (-not $Relativa) { return @() }
    $ruta = Join-Path $Carpeta $Relativa
    $dir  = Split-Path $ruta -Parent
    $base = [IO.Path]::GetFileNameWithoutExtension($ruta)
    # GetFiles con el comodin y un foreach, no Get-ChildItem y el pipeline: con Get-ChildItem
    # la lista de apps tardaba un segundo mas (medido), y se repite al refrescar
    $res = @()
    try { $ficheros = [IO.Directory]::GetFiles($dir, $base + '*.png') } catch { return $res }
    $patron = '^' + [regex]::Escape($base) + '(\.[^\\]+)?\.png$'
    foreach ($f in $ficheros) {
        $n = [IO.Path]::GetFileName($f)
        if ($n -notmatch $patron -or $n -match 'contrast-|lightunplated') { continue }
        $res += [pscustomobject]@{ Ruta = $f; Ancho = (Get-AnchoPng $f); SinPlaca = [bool]($n -match 'altform-unplated') }
    }
    return $res
}

# El mejor logo de una app de la Store, para que las caratulas tengan algo propio cuando la
# busqueda en el catalogo falla (si no, solo el nombre sobre fondo oscuro).
# Primero el de la lista de apps (Square44x44Logo): es el icono que ensena Windows, sin margen
# y con la variante 'unplated' transparente. Pero en algunas apps solo esta a 44-88 px (Claude,
# Wolfenstein), y entonces vale mas la baldosa mas grande, aunque lleve margen.
# $Aumid es lo que va detras de 'shell:AppsFolder\': <familia del paquete>!<id de la app>.
# No lanza: si algo falla, devuelve '' y la caratula sale como antes.
function Get-LogoAppStore {
    param([string]$Aumid)
    try {
        $familia, $AppId = $Aumid -split '!', 2
        if (-not $AppId) { return '' }
        # la familia es <nombre>_<id del editor>, y el nombre no puede llevar '_'
        $nombrePaquete = $familia -replace '_[^_]*$', ''
        $paquete = Get-AppxPackage -Name $nombrePaquete -ErrorAction Stop |
                   Where-Object { $_.PackageFamilyName -eq $familia } | Select-Object -First 1
        if (-not $paquete -or -not $paquete.InstallLocation) { return '' }
        $Carpeta = $paquete.InstallLocation
        $man = Join-Path $Carpeta 'AppxManifest.xml'
        if (-not (Test-Path -LiteralPath $man)) { return '' }
        [xml]$x = Get-Content -LiteralPath $man -Raw -Encoding UTF8
        $app = @($x.Package.Applications.Application) | Where-Object { $_.Id -eq $AppId } | Select-Object -First 1
        if (-not $app -or -not $app.VisualElements) { return '' }
        $ve = $app.VisualElements

        $lista = @(Get-VariantesLogo $Carpeta $ve.Square44x44Logo | Where-Object { $_.Ancho -gt 0 } |
                   Sort-Object @{ Expression = 'Ancho'; Descending = $true }, @{ Expression = 'SinPlaca'; Descending = $true })
        if ($lista.Count -and $lista[0].Ancho -ge 128) { return $lista[0].Ruta }

        $todas = @($lista)
        $tile = $null
        if ($ve.DefaultTile) { $tile = $ve.DefaultTile.Square310x310Logo }
        foreach ($rel in @($ve.Square150x150Logo, $tile, $x.Package.Properties.Logo)) {
            $todas += @(Get-VariantesLogo $Carpeta $rel | Where-Object { $_.Ancho -gt 0 })
        }
        $mejor = $todas | Sort-Object Ancho -Descending | Select-Object -First 1
        if ($mejor) { return $mejor.Ruta }
    } catch { }
    return ''
}

function Get-AppsStore {
    $res = @()
    foreach ($a in (Get-StartApps -ErrorAction SilentlyContinue)) {
        if ($a.AppID -notmatch '!') { continue }          # solo AUMID de paquete
        if ($a.AppID -match '^Microsoft\.(Windows|BingWeather|ScreenSketch|MicrosoftEdge|Todos|People|Getstarted|WindowsStore|549981)') { continue }
        # Sin Icono a proposito: el logo del paquete lo busca New-CaratulasSteam al preparar
        # (Get-LogoAppStore). Buscarlo aqui para todas costaba medio segundo mas de ventana
        # parada en cada refresco (medido), para usar solo el de la app que se prepare.
        $res += New-Juego -Nombre $a.Name -Fuente 'App de la Store' `
                -Exe (Join-Path $env:SystemRoot 'explorer.exe') -StartDir ($env:SystemRoot + '\') `
                -LaunchOptions ('shell:AppsFolder\' + $a.AppID) `
                -Detalle 'UWP: Steam pierde el proceso (sin overlay ni horas)'
    }
    return $res
}

# ---------------------------------------------------------------------
#  Ultimos programas ejecutados (UserAssist de Windows)
# ---------------------------------------------------------------------
function ConvertFrom-Rot13 {
    param([string]$Texto)
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $Texto.ToCharArray()) {
        if     ($c -cmatch '[a-z]') { [void]$sb.Append([char]((([int]$c - 97 + 13) % 26) + 97)) }
        elseif ($c -cmatch '[A-Z]') { [void]$sb.Append([char]((([int]$c - 65 + 13) % 26) + 65)) }
        else                        { [void]$sb.Append($c) }
    }
    return $sb.ToString()
}

# UserAssist guarda las rutas con la carpeta inicial como GUID (KNOWNFOLDERID). Lo que no se
# sabe resolver se descarta mas abajo en silencio, asi que un GUID que falte o que apunte mal
# hace desaparecer programas de "Recientes" sin decir nada.
# Las carpetas del usuario se resuelven con GetFolderPath, no a mano desde %USERPROFILE%: con
# OneDrive, Escritorio y Documentos estan redirigidos y la ruta fija no existiria.
function Get-CarpetaEspecial {
    param([string]$Nombre)
    try { return [Environment]::GetFolderPath([Environment+SpecialFolder]::$Nombre) } catch { return '' }
}

$script:GuidCarpetas = @{
    '{6D809377-6AF0-444B-8957-A3773F02200E}' = (Get-CarpetaEspecial 'ProgramFiles')            # ProgramFilesX64
    '{905E63B6-C1BF-494E-B29C-65B732D3D21A}' = (Get-CarpetaEspecial 'ProgramFiles')            # ProgramFiles
    '{7C5A40EF-A0FB-4BFC-874A-C0F2E0B9FA8E}' = (Get-CarpetaEspecial 'ProgramFilesX86')
    '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}' = (Get-CarpetaEspecial 'System')                  # System32
    '{D65231B0-B2F1-4857-A4CE-A8E7C6EA7D27}' = (Get-CarpetaEspecial 'SystemX86')               # SysWOW64, no System32
    '{F38BF404-1D43-42F2-9305-67DE0B28FC23}' = (Get-CarpetaEspecial 'Windows')
    '{5E6C858F-0E22-4760-9AFE-EA3317B67173}' = (Get-CarpetaEspecial 'UserProfile')
    '{0762D272-C50A-4BB0-A382-697DCD729B80}' = (Split-Path (Get-CarpetaEspecial 'UserProfile') -Parent)  # C:\Users
    '{B4BFCC3A-DB2C-424C-B029-7FE99A87C641}' = (Get-CarpetaEspecial 'DesktopDirectory')
    '{C4AA340D-F20F-4863-AFEF-F87EF2E6BA25}' = (Get-CarpetaEspecial 'CommonDesktopDirectory')
    '{FDD39AD0-238F-46AF-ADB4-6C85480369C7}' = (Get-CarpetaEspecial 'MyDocuments')
    '{4BD8D571-6D19-48D3-BE97-422220080E43}' = (Get-CarpetaEspecial 'MyMusic')
    '{33E28130-4E1E-4676-835A-98395C3BC3BB}' = (Get-CarpetaEspecial 'MyPictures')
    '{18989B1D-99B5-455B-841C-AB7C74E4DDFC}' = (Get-CarpetaEspecial 'MyVideos')
    '{F1B32785-6FBA-4FCF-9D55-7B8E7F157091}' = (Get-CarpetaEspecial 'LocalApplicationData')
    '{3EB685DB-65F9-4CF6-A03A-E3EF65729F3D}' = (Get-CarpetaEspecial 'ApplicationData')
    '{625B53C3-AB48-4EC1-BA1F-A1EF4146FC19}' = (Get-CarpetaEspecial 'StartMenu')
    '{A77F5D77-2E2B-44C3-A6A2-ABA601054A51}' = (Get-CarpetaEspecial 'Programs')
    '{B97D20BB-F46A-4C97-BA10-5E3608430854}' = (Get-CarpetaEspecial 'Startup')
    '{A4115719-D62E-491D-AA7C-E74B8BE3B067}' = (Get-CarpetaEspecial 'CommonStartMenu')         # sin \Programs
    '{0139D44E-6AFE-49F2-8690-3DAFCAE6FFB8}' = (Get-CarpetaEspecial 'CommonPrograms')
    '{9E3995AB-1F9C-4F13-B827-48B24B6C7174}' = (Join-Path (Get-CarpetaEspecial 'ApplicationData') 'Microsoft\Internet Explorer\Quick Launch\User Pinned')
}

# Descargas no tiene SpecialFolder: se lee del registro, que tambien refleja la redireccion.
$script:RutaDescargas = ''
try {
    $usf = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction Stop
    $script:RutaDescargas = [Environment]::ExpandEnvironmentVariables($usf.'{374DE290-123F-4565-9164-39C4925E467B}')
} catch { }
if (-not $script:RutaDescargas) { $script:RutaDescargas = Join-Path (Get-CarpetaEspecial 'UserProfile') 'Downloads' }
$script:GuidCarpetas['{374DE290-123F-4565-9164-39C4925E467B}'] = $script:RutaDescargas

function Get-ProgramasRecientes {
    param([int]$Maximo = 60)
    $res = @()
    $base = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\UserAssist'
    $vistos = @{}
    foreach ($guid in Get-ChildItem $base -ErrorAction SilentlyContinue) {
        $count = Join-Path $guid.PSPath 'Count'
        $item = Get-Item $count -ErrorAction SilentlyContinue
        if (-not $item) { continue }
        foreach ($nombreVal in $item.GetValueNames()) {
            $ruta = ConvertFrom-Rot13 $nombreVal
            if ($ruta -notmatch '\.exe$') { continue }
            foreach ($g in @($script:GuidCarpetas.Keys)) {
                # sin el -and, un GUID que no se haya podido resolver dejaria una ruta relativa
                if ($script:GuidCarpetas[$g] -and $ruta.StartsWith($g, 'OrdinalIgnoreCase')) {
                    $ruta = $script:GuidCarpetas[$g] + $ruta.Substring($g.Length); break
                }
            }
            if ($ruta -match '^\{') { continue }
            if (-not (Test-Path -LiteralPath $ruta)) { continue }
            $hoja = Split-Path $ruta -Leaf
            if ($hoja -match '^(explorer|cmd|powershell|pwsh|regedit|mmc|notepad|taskmgr|control|rundll32|msedge|chrome|firefox|steam|steamwebhelper|EpicGamesLauncher|UbisoftConnect|GalaxyClient)\.exe$') { continue }
            if ($ruta -like "$env:SystemRoot\System32\*" -or $ruta -like "$env:SystemRoot\SysWOW64\*") { continue }
            if ($vistos.ContainsKey($ruta.ToLower())) { continue }

            $fecha = [datetime]::MinValue
            try {
                $datos = $item.GetValue($nombreVal)
                if ($datos -and $datos.Length -ge 68) {
                    $ft = [System.BitConverter]::ToInt64($datos, 60)
                    if ($ft -gt 0) { $fecha = [datetime]::FromFileTime($ft) }
                }
            } catch { }
            $vistos[$ruta.ToLower()] = $true
            $res += New-Juego -Nombre ([IO.Path]::GetFileNameWithoutExtension($ruta)) -Fuente 'Reciente' `
                    -Exe $ruta -StartDir ((Split-Path $ruta -Parent) + '\') -Icono $ruta `
                    -Carpeta (Split-Path $ruta -Parent) -Detalle "Ultima ejecucion: $(if($fecha -gt [datetime]::MinValue){$fecha.ToString('dd/MM/yyyy HH:mm')}else{'desconocida'})" `
                    -Fecha $fecha
        }
    }
    return ($res | Sort-Object Fecha -Descending | Select-Object -First $Maximo)
}

# ---------------------------------------------------------------------
#  Todo junto, cada origen aislado del resto
# ---------------------------------------------------------------------

# Deja constancia de un origen que ha fallado. Sin -Log intenta el registro de la aplicacion,
# que solo existe si esta lib se ha cargado desde VaporeraArcade.ps1 (se puede usar suelta).
function Write-AvisoFuente {
    param([string]$Texto, [scriptblock]$Log = $null)
    if ($Log) { & $Log $Texto | Out-Null; return }
    if (Get-Command Write-Registro -ErrorAction SilentlyContinue) { Write-Registro $Texto }
}

function Get-TodosLosJuegos {
    param([switch]$IncluirRecientes, [switch]$IncluirApps, [scriptblock]$Log = $null)
    # Cada origen va en su propio try: uno que falle (una clave del registro que apunta a un
    # disco desconectado, un manifiesto ilegible...) no puede dejar la lista entera vacia.
    $origenes = [ordered]@{
        'Xbox / Game Pass' = { Get-JuegosXbox }
        'Ubisoft Connect'  = { Get-JuegosUbisoft }
        'Epic Games'       = { Get-JuegosEpic }
        'GOG'              = { Get-JuegosGog }
    }
    if ($IncluirApps)      { $origenes['apps de la Store']   = { Get-AppsStore } }
    if ($IncluirRecientes) { $origenes['programas recientes'] = { Get-ProgramasRecientes } }

    $lista = @()
    foreach ($nombre in @($origenes.Keys)) {
        try { $lista += & $origenes[$nombre] }
        catch {
            Write-AvisoFuente -Log $Log -Texto "No he podido leer los juegos de $nombre : $($_.Exception.Message)"
        }
    }
    return $lista
}
