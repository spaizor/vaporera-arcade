# =====================================================================
#  Caratulas.ps1 - Generacion de las imagenes de la biblioteca de Steam
#
#  Prioridad de origen:
#    1. Catalogo publico de la Microsoft Store (sin API key) via StoreId
#       -> Poster 1440x2160, SuperHeroArt 3840x2160, TitledHeroArt, Logo
#    2. SteamGridDB, si el usuario ha puesto su clave en Ajustes (config.json)
#    3. Assets locales del propio juego (splash + logo), compuestos
#
#  Nombres que espera Steam en config\grid\:
#    <appid>p.png      600x900    <- la que manda en Big Picture
#    <appid>.png       460x215
#    <appid>_hero.png  1920x620
#    <appid>_logo.png  logo con transparencia
#    <appid>_icon.png  icono de la lista. Steam NO lo busca por el nombre: solo lo usa si
#                      el campo 'icon' de la entrada del VDF apunta a el (Invoke-AnadirJuego)
# =====================================================================

Add-Type -AssemblyName System.Drawing

function Initialize-Tls {
    # Antes esto asignaba Tls12 a secas y se cargaba lo que hubiera. Windows 11 arranca en
    # SystemDefault, que deja elegir al sistema y ya incluye TLS 1.2 y 1.3: sustituirlo por
    # Tls12 deja al proceso SIN TLS 1.3. Y un '-bor' tampoco salva el caso, porque
    # SystemDefault vale 0 en el enum (comprobado) y '0 -bor Tls12' vuelve a dar Tls12.
    # Asi que solo se toca cuando el proceso trae protocolos viejos configurados a mano
    # (Windows 8.1 o una directiva: SSL3|Tls) y falta TLS 1.2, y entonces se SUMA.
    try {
        $actual = [Net.ServicePointManager]::SecurityProtocol
        if ($actual -ne [Net.SecurityProtocolType]::SystemDefault -and
            -not ($actual -band [Net.SecurityProtocolType]::Tls12)) {
            [Net.ServicePointManager]::SecurityProtocol = $actual -bor [Net.SecurityProtocolType]::Tls12
        }
    } catch { }
}

# ---------------------------------------------------------------------
#  Comparacion de titulos
#
#  Las busquedas por nombre devuelven cualquier cosa y antes se cogia el
#  primer resultado a ciegas: buscar 'obs64' traia la caratula de otro
#  programa, y hasta buscando 'Sea of Thieves' el primer resultado es
#  'Sea of Thieves: X Edition'. Se compara el titulo con el nombre y se
#  descarta lo que no cuadre.
# ---------------------------------------------------------------------

# Parecido minimo para dar por bueno un resultado (0 a 1)
$MinParecidoTitulo = 0.72

# Deja el titulo en minusculas, sin acentos, sin simbolos y sin la coletilla de la edicion
function Get-TituloNormalizado {
    param([string]$Texto)
    if (-not $Texto) { return '' }
    $t = $Texto.ToLowerInvariant()
    # sin acentos: 'pokemon' y 'pokémon' tienen que dar lo mismo
    $t = -join ([char[]]($t.Normalize([Text.NormalizationForm]::FormD)) | Where-Object {
            [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne [Globalization.UnicodeCategory]::NonSpacingMark })
    $t = $t -replace '&', ' and '
    $t = $t -replace '[^a-z0-9]+', ' '   # puntuacion, (tm), (r), dos puntos...
    $t = $t.Trim()
    # 'Forza Horizon 5' y 'Forza Horizon 5 Deluxe Edition' son el mismo juego.
    # El catalogo responde en el idioma del mercado, asi que hay que quitar tambien la
    # coletilla en espanol, que ademas va al reves: 'Forza Horizon 5 Edición Premium'.
    $ed   = 'standard|deluxe|ultimate|complete|definitive|premium|gold|goty|game of the year|anniversary|remastered|enhanced|legendary|collectors|collector|digital'
    $edEs = 'estandar|deluxe|premium|definitiva|completa|especial|oro|coleccionista|aniversario|legendaria|digital|ultimate|de lujo|anticipada|juego del ano|del ano'
    for ($i = 0; $i -lt 3; $i++) {
        $t = $t -replace "\s+($ed)(\s+(edition|bundle|pack))?$", ''
        $t = $t -replace "\s+edicion(\s+($edEs))?$", ''
        $t = $t -replace '\s+(edition|bundle|for windows|windows edition|pc|hd)$', ''
    }
    $t = ($t -replace '\s+', ' ').Trim()
    # si al normalizar no queda nada (un titulo en japones, por ejemplo) mejor el original:
    # dos cadenas vacias se pareceran entre si y darian por bueno cualquier resultado
    if (-not $t) { return $Texto.ToLowerInvariant().Trim() }
    return $t
}

# Distancia de Levenshtein (dos filas, que los titulos son cortos)
function Get-DistanciaEdicion {
    param([string]$A, [string]$B)
    $n = $A.Length; $m = $B.Length
    if ($n -eq 0) { return $m }
    if ($m -eq 0) { return $n }
    $prev = New-Object 'int[]' ($m + 1)
    $act  = New-Object 'int[]' ($m + 1)
    for ($j = 0; $j -le $m; $j++) { $prev[$j] = $j }
    for ($i = 1; $i -le $n; $i++) {
        $act[0] = $i
        for ($j = 1; $j -le $m; $j++) {
            $coste = 1
            if ($A[$i - 1] -ceq $B[$j - 1]) { $coste = 0 }
            $act[$j] = [Math]::Min([Math]::Min($act[$j - 1] + 1, $prev[$j] + 1), $prev[$j - 1] + $coste)
        }
        $tmp = $prev; $prev = $act; $act = $tmp
    }
    return $prev[$m]
}

# 0 = no tienen nada que ver, 1 = es el mismo titulo
function Get-ParecidoTitulo {
    param([string]$Buscado, [string]$Candidato)
    $a = Get-TituloNormalizado $Buscado
    $b = Get-TituloNormalizado $Candidato
    if (-not $a -or -not $b) { return 0 }
    if ($a -eq $b) { return 1 }
    # el numero de la saga manda: 'Forza Horizon 5' y 'Forza Horizon 6' se diferencian en una
    # letra y la distancia sola los daba por el mismo juego (0,93). Si los dos titulos llevan
    # numero y no es el mismo, son juegos distintos. Si solo lo lleva uno ('Sea of Thieves' y
    # 'Sea of Thieves: 2026 Edition') suele ser la edicion: que decida la distancia.
    $na = @([regex]::Matches($a, '\d+') | ForEach-Object { $_.Value })
    $nb = @([regex]::Matches($b, '\d+') | ForEach-Object { $_.Value })
    if ($na.Count -and $nb.Count -and (($na -join ' ') -ne ($nb -join ' '))) { return 0 }
    $max = [Math]::Max($a.Length, $b.Length)
    $p = 1 - ((Get-DistanciaEdicion -A $a -B $b) / $max)
    if ($p -lt 0) { $p = 0 }
    return [Math]::Round($p, 3)
}

# ---------------------------------------------------------------------
#  Microsoft Store
# ---------------------------------------------------------------------
function Get-StoreImagenes {
    param([Parameter(Mandatory)][string]$StoreId)
    Initialize-Tls
    $url = "https://displaycatalog.mp.microsoft.com/v7.0/products/$StoreId" +
           "?market=ES&languages=es-ES,en-US&fieldsTemplate=Details"
    try {
        $r = Invoke-RestMethod -Uri $url -Headers @{ 'MS-CV' = 'VaporeraArcade.1' } -TimeoutSec 25
    } catch { return $null }
    if (-not $r.Product) { return $null }

    $imgs = @{}
    foreach ($lp in $r.Product.LocalizedProperties) {
        foreach ($im in $lp.Images) {
            $u = $im.Uri
            if ($u -like '//*') { $u = 'https:' + $u }
            $k = $im.ImagePurpose
            # nos quedamos con la mayor de cada tipo
            if (-not $imgs.ContainsKey($k) -or ($im.Width * $im.Height) -gt $imgs[$k].Pixeles) {
                $imgs[$k] = [pscustomobject]@{ Uri = $u; Ancho = $im.Width; Alto = $im.Height; Pixeles = $im.Width * $im.Height }
            }
        }
    }
    $titulo = ''
    if ($r.Product.LocalizedProperties -and $r.Product.LocalizedProperties[0].ProductTitle) {
        $titulo = $r.Product.LocalizedProperties[0].ProductTitle
    }
    return [pscustomobject]@{ Titulo = $titulo; Imagenes = $imgs }
}

# Resultados de la busqueda con su parecido, de mas a menos.
# Devuelve la lista entera a proposito: la vista previa tiene que poder
# ofrecer los demas candidatos cuando el elegido no sea el que toca.
function Get-StoreCandidatos {
    param([Parameter(Mandatory)][string]$Nombre)
    Initialize-Tls
    $q = [uri]::EscapeDataString($Nombre)
    $url = "https://storeedgefd.dsx.mp.microsoft.com/v9.0/search?query=$q&market=ES&locale=es-ES&deviceFamily=Windows.Desktop"
    $lista = @()
    try {
        $r = Invoke-RestMethod -Uri $url -TimeoutSec 20
        foreach ($res in $r.Payload.SearchResults) {
            if (-not $res.ProductId) { continue }
            $lista += [pscustomobject]@{
                Id       = $res.ProductId
                Titulo   = [string]$res.Title
                EsJuego  = ($res.ProductFamilyName -eq 'Games')
                Parecido = (Get-ParecidoTitulo -Buscado $Nombre -Candidato ([string]$res.Title))
            }
        }
    } catch { }
    # a igual parecido, antes un juego que una aplicacion
    return @($lista | Sort-Object @{ Expression = 'Parecido'; Descending = $true }, @{ Expression = 'EsJuego'; Descending = $true })
}

function Find-StoreId {
    param(
        [Parameter(Mandatory)][string]$Nombre,
        [double]$MinParecido = $MinParecidoTitulo,
        [scriptblock]$Log = $null
    )
    function Registrar($m) { if ($Log) { & $Log $m | Out-Null } }
    $cand = Get-StoreCandidatos -Nombre $Nombre
    if (-not $cand.Count) { return $null }
    $mejor = $cand[0]
    if ($mejor.Parecido -lt $MinParecido) {
        Registrar "  lo más parecido en la Store es '$($mejor.Titulo)': no se parece bastante a '$Nombre', lo descarto"
        return $null
    }
    if ($mejor.Parecido -lt 1) { Registrar "  la Store lo llama '$($mejor.Titulo)'" }
    return $mejor.Id
}

# ---------------------------------------------------------------------
#  SteamGridDB (opcional: clave en config.json, se pone desde Ajustes)
# ---------------------------------------------------------------------
function Get-SgdbClave {
    $clave = (Get-Config)['SgdbClave']
    if ($clave) { return [string]$clave }
    # la primera version la leia de sgdb.key junto a la app: se pasa a config.json
    $f = Join-Path $PSScriptRoot '..\sgdb.key'
    if (Test-Path -LiteralPath $f) {
        $txt = Get-Content -LiteralPath $f -Raw
        if ($txt -and $txt.Trim()) {
            $clave = $txt.Trim()
            try {
                Set-ConfigValor -Nombre 'SgdbClave' -Valor $clave
                Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
            } catch { }
            return $clave
        }
    }
    return $null
}

# Hace una busqueda de prueba para saber si la clave vale
function Test-SgdbClave {
    param([Parameter(Mandatory)][string]$Clave)
    Initialize-Tls
    try {
        [void](Invoke-RestMethod -Uri 'https://www.steamgriddb.com/api/v2/search/autocomplete/portal' `
                -Headers @{ Authorization = "Bearer $Clave" } -TimeoutSec 20)
        return [pscustomobject]@{ Ok = $true; Mensaje = 'La clave funciona.' }
    } catch {
        $resp = $_.Exception.Response
        if ($resp -and [int]$resp.StatusCode -eq 401) {
            return [pscustomobject]@{ Ok = $false; Mensaje = 'SteamGridDB rechaza la clave. Revisa que esté bien copiada.' }
        }
        return [pscustomobject]@{ Ok = $false; Mensaje = "No se ha podido comprobar: $($_.Exception.Message)" }
    }
}

# Resultados de SteamGridDB con su parecido, de mas a menos (misma idea que en la Store)
function Get-SgdbCandidatos {
    param([Parameter(Mandatory)][string]$Nombre, [hashtable]$Cabeceras)
    $lista = @()
    $b = Invoke-RestMethod -Uri "https://www.steamgriddb.com/api/v2/search/autocomplete/$([uri]::EscapeDataString($Nombre))" -Headers $Cabeceras -TimeoutSec 20
    foreach ($res in $b.data) {
        if (-not $res.id) { continue }
        $lista += [pscustomobject]@{
            Id       = $res.id
            Titulo   = [string]$res.name
            Parecido = (Get-ParecidoTitulo -Buscado $Nombre -Candidato ([string]$res.name))
        }
    }
    return @($lista | Sort-Object Parecido -Descending)
}

function Get-SgdbImagenes {
    param(
        [Parameter(Mandatory)][string]$Nombre,
        [double]$MinParecido = $MinParecidoTitulo,
        [scriptblock]$Log = $null
    )
    function Registrar($m) { if ($Log) { & $Log $m | Out-Null } }
    $clave = Get-SgdbClave
    if (-not $clave) { Registrar '  sin clave de SteamGridDB (se pone en Ajustes), me lo salto'; return $null }
    Initialize-Tls
    $h = @{ Authorization = "Bearer $clave" }
    try {
        $cand = Get-SgdbCandidatos -Nombre $Nombre -Cabeceras $h
        if (-not $cand.Count) { Registrar "  SteamGridDB no conoce '$Nombre'"; return $null }
        $mejor = $cand[0]
        if ($mejor.Parecido -lt $MinParecido) {
            Registrar "  lo más parecido en SteamGridDB es '$($mejor.Titulo)': no se parece bastante a '$Nombre', lo descarto"
            return $null
        }
        if ($mejor.Parecido -lt 1) { Registrar "  SteamGridDB lo llama '$($mejor.Titulo)'" }
        $id = $mejor.Id
        $res = @{}
        $g = Invoke-RestMethod -Uri "https://www.steamgriddb.com/api/v2/grids/game/${id}?dimensions=600x900" -Headers $h -TimeoutSec 20
        if ($g.data.Count) { $res['Poster'] = $g.data[0].url }
        $g2 = Invoke-RestMethod -Uri "https://www.steamgriddb.com/api/v2/grids/game/${id}?dimensions=460x215" -Headers $h -TimeoutSec 20
        if ($g2.data.Count) { $res['Capsule'] = $g2.data[0].url }
        $hr = Invoke-RestMethod -Uri "https://www.steamgriddb.com/api/v2/heroes/game/$id" -Headers $h -TimeoutSec 20
        if ($hr.data.Count) { $res['Hero'] = $hr.data[0].url }
        $lg = Invoke-RestMethod -Uri "https://www.steamgriddb.com/api/v2/logos/game/$id" -Headers $h -TimeoutSec 20
        if ($lg.data.Count) { $res['Logo'] = $lg.data[0].url }
        return $res
    } catch {
        Registrar "  SteamGridDB ha fallado: $($_.Exception.Message)"
        return $null
    }
}

# ---------------------------------------------------------------------
#  Utilidades de imagen
# ---------------------------------------------------------------------
function Get-BitmapDesdeUrl {
    param([Parameter(Mandatory)][string]$Url)
    Initialize-Tls
    $wc = $null
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('User-Agent','Mozilla/5.0')
        $bytes = $wc.DownloadData($Url)
        # el MemoryStream NO se libera: el bitmap lo necesita vivo mientras exista
        $ms = New-Object System.IO.MemoryStream(,$bytes)
        return [System.Drawing.Bitmap]::FromStream($ms)
    } catch { return $null }
    finally { if ($wc) { $wc.Dispose() } }
}

function Get-BitmapDesdeArchivo {
    param([Parameter(Mandatory)][string]$Ruta)
    try {
        if ($Ruta -match '\.exe$') {
            $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($Ruta)
            if (-not $ico) { return $null }
            # ToBitmap hace una copia: el Icon (un HICON de GDI) se puede soltar ya
            try { return $ico.ToBitmap() } finally { $ico.Dispose() }
        }
        $bytes = [System.IO.File]::ReadAllBytes($Ruta)
        $ms = New-Object System.IO.MemoryStream(,$bytes)
        return [System.Drawing.Bitmap]::FromStream($ms)
    } catch { return $null }
}

# Recorta al centro para llenar el lienzo sin deformar (cover)
function New-ImagenCover {
    param([System.Drawing.Bitmap]$Origen, [int]$Ancho, [int]$Alto)
    $dst = New-Object System.Drawing.Bitmap($Ancho, $Alto)
    $g = [System.Drawing.Graphics]::FromImage($dst)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality

    $escala = [Math]::Max($Ancho / $Origen.Width, $Alto / $Origen.Height)
    $w = [int][Math]::Ceiling($Origen.Width * $escala)
    $h = [int][Math]::Ceiling($Origen.Height * $escala)
    $x = [int](($Ancho - $w) / 2)
    $y = [int](($Alto  - $h) / 2)
    $g.DrawImage($Origen, $x, $y, $w, $h)
    $g.Dispose()
    return $dst
}

# Encaja la imagen entera en un cuadrado sin deformarla, con el hueco transparente.
# 'New-Object Bitmap($origen, 256, 256)' estiraba los logos apaisados.
function New-IconoCuadrado {
    param([System.Drawing.Bitmap]$Origen, [int]$Lado = 256)
    $dst = New-Object System.Drawing.Bitmap -ArgumentList $Lado, $Lado, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($dst)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)

    $esc = [Math]::Min($Lado / $Origen.Width, $Lado / $Origen.Height)
    $w = [int][Math]::Round($Origen.Width * $esc)
    $h = [int][Math]::Round($Origen.Height * $esc)
    $g.DrawImage($Origen, [int](($Lado - $w) / 2), [int](($Lado - $h) / 2), $w, $h)
    $g.Dispose()
    return $dst
}

# Un logo de verdad es apaisado o tiene el fondo transparente. El 'Logo' del catalogo de la
# Store es una baldosa cuadrada y opaca (el mosaico del menu Inicio): como _logo.png encima
# del hero se ve el recuadro con su fondo y queda fatal.
function Test-EsLogo {
    param([System.Drawing.Bitmap]$Bitmap)
    if (-not $Bitmap) { return $false }
    if (($Bitmap.Width / $Bitmap.Height) -ge 1.3) { return $true }
    if (-not [System.Drawing.Image]::IsAlphaPixelFormat($Bitmap.PixelFormat)) { return $false }
    $x = $Bitmap.Width - 1; $y = $Bitmap.Height - 1
    foreach ($esquina in @(@(0, 0), @($x, 0), @(0, $y), @($x, $y))) {
        if ($Bitmap.GetPixel($esquina[0], $esquina[1]).A -gt 32) { return $false }
    }
    return $true
}

# Compone una caratula a partir de un fondo + logo (plan B sin internet)
function New-CaratulaCompuesta {
    param(
        [System.Drawing.Bitmap]$Fondo, [System.Drawing.Bitmap]$Logo,
        [int]$Ancho, [int]$Alto, [string]$Texto = ''
    )
    if ($Fondo) { $dst = New-ImagenCover -Origen $Fondo -Ancho $Ancho -Alto $Alto }
    else {
        $dst = New-Object System.Drawing.Bitmap($Ancho, $Alto)
        $g0 = [System.Drawing.Graphics]::FromImage($dst)
        $g0.Clear([System.Drawing.Color]::FromArgb(255, 22, 24, 28))
        $g0.Dispose()
    }
    $g = [System.Drawing.Graphics]::FromImage($dst)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit

    if ($Fondo) {
        $velo = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(105, 0, 0, 0))
        $g.FillRectangle($velo, 0, 0, $Ancho, $Alto)
        $velo.Dispose()
    }
    if ($Logo) {
        $maxW = [int]($Ancho * 0.72); $maxH = [int]($Alto * 0.42)
        $esc = [Math]::Min($maxW / $Logo.Width, $maxH / $Logo.Height)
        $lw = [int]($Logo.Width * $esc); $lh = [int]($Logo.Height * $esc)
        $g.DrawImage($Logo, [int](($Ancho - $lw)/2), [int](($Alto - $lh)/2), $lw, $lh)
    }
    elseif ($Texto) {
        $tam = [Math]::Max(14, [int]($Ancho / 11))
        $fuente = New-Object System.Drawing.Font('Segoe UI', $tam, [System.Drawing.FontStyle]::Bold)
        $fmt = New-Object System.Drawing.StringFormat
        $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
        # las medidas, en variables: 'New-Object RectangleF(($Ancho*0.08)+3, 3, ...)' hace que
        # PS 5.1 lea el resto de argumentos como un array y lo sume al primero (op_Addition)
        $rx = [single]($Ancho * 0.08)
        $rw = [single]($Ancho * 0.84)
        $rh = [single]$Alto
        $rect = New-Object System.Drawing.RectangleF($rx, [single]0, $rw, $rh)
        $sombra = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(200,0,0,0))
        $rect2 = New-Object System.Drawing.RectangleF(($rx + 3), [single]3, $rw, $rh)
        $g.DrawString($Texto, $fuente, $sombra, $rect2, $fmt)
        $blanco = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
        $g.DrawString($Texto, $fuente, $blanco, $rect, $fmt)
        $sombra.Dispose(); $blanco.Dispose(); $fuente.Dispose()
    }
    $g.Dispose()
    return $dst
}

function Save-Png {
    param([System.Drawing.Bitmap]$Bitmap, [string]$Ruta)
    $dir = Split-Path $Ruta -Parent
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $Bitmap.Save($Ruta, [System.Drawing.Imaging.ImageFormat]::Png)
}

# ---------------------------------------------------------------------
#  Busca los mejores assets locales del juego
# ---------------------------------------------------------------------
function Get-AssetsLocales {
    param([string]$Carpeta, [string]$Icono)
    # LogoDelExe: el icono que saca ExtractAssociatedIcon es de 32x32. Vale para componer una
    # caratula, pero no para generar un _icon.png de 256 (sale borroso) ni un _logo.png.
    $r = @{ Fondo = $null; Logo = $null; LogoDelExe = $false }
    if ($Carpeta -and (Test-Path -LiteralPath $Carpeta)) {
        $pngs = Get-ChildItem -LiteralPath $Carpeta -Filter *.png -ErrorAction SilentlyContinue
        $splash = $pngs | Where-Object { $_.Name -match 'splash|hero|background|key_?art' } |
                  Sort-Object Length -Descending | Select-Object -First 1
        if (-not $splash) { $splash = $pngs | Where-Object { $_.Length -gt 300000 } | Sort-Object Length -Descending | Select-Object -First 1 }
        if ($splash) { $r.Fondo = Get-BitmapDesdeArchivo -Ruta $splash.FullName }

        $logo = $pngs | Where-Object { $_.Name -match '480x480|logo' -and $_.Name -notmatch '44x44|store_?logo_?100' } |
                Sort-Object Length -Descending | Select-Object -First 1
        if ($logo) { $r.Logo = Get-BitmapDesdeArchivo -Ruta $logo.FullName }
    }
    if (-not $r.Logo -and $Icono -and (Test-Path -LiteralPath $Icono)) {
        $r.Logo = Get-BitmapDesdeArchivo -Ruta $Icono
        if ($r.Logo) { $r.LogoDelExe = [bool]($Icono -match '\.exe$') }
    }
    return $r
}

# ---------------------------------------------------------------------
#  Genera las 5 imagenes. Devuelve el informe de que origen se uso.
# ---------------------------------------------------------------------
function New-CaratulasSteam {
    param(
        [Parameter(Mandatory)]$Juego,
        [Parameter(Mandatory)][uint32]$AppId,
        [Parameter(Mandatory)][string]$GridDir,
        [string]$NombreFinal = '',
        [ValidateSet('Automatico','Store','SteamGridDB','Local')][string]$OrigenArte = 'Automatico',
        [scriptblock]$Log = $null
    )
    function Registrar($m) { if ($Log) { & $Log $m | Out-Null } }
    if (-not $NombreFinal) { $NombreFinal = $Juego.Nombre }
    if (-not (Test-Path -LiteralPath $GridDir)) { [void](New-Item -ItemType Directory -Path $GridDir -Force) }
    # ojo: $OrigenArte (lo que pide el usuario) y $origen (de donde han salido) son variables
    # distintas, pero PowerShell no distingue mayusculas: no renombrar una y dejar la otra
    if ($OrigenArte -ne 'Automatico') { Registrar "Origen de las carátulas forzado a: $OrigenArte" }

    $origen = 'assets locales'
    $poster = $null; $hero = $null; $capsule = $null; $logo = $null

    # 1) Microsoft Store
    $storeId = $null
    if ($OrigenArte -eq 'Automatico' -or $OrigenArte -eq 'Store') {
        $storeId = $Juego.StoreId
        if (-not $storeId) {
            Registrar "Buscando '$NombreFinal' en el catálogo de la Store..."
            $storeId = Find-StoreId -Nombre $NombreFinal -Log $Log
            if ($storeId) { Registrar "  encontrado StoreId $storeId" }
        }
    }
    if ($storeId) {
        Registrar "Descargando carátulas oficiales de la Store ($storeId)..."
        $cat = Get-StoreImagenes -StoreId $storeId
        if ($cat) {
            $im = $cat.Imagenes
            if ($im['Poster'])        { $poster  = Get-BitmapDesdeUrl $im['Poster'].Uri }
            if (-not $poster -and $im['BrandedKeyArt']) { $poster = Get-BitmapDesdeUrl $im['BrandedKeyArt'].Uri }
            # TitledHeroArt es la capsula y, si no hay SuperHeroArt, tambien el hero: se baja
            # una sola vez y se reutiliza el mismo bitmap (antes se descargaba dos veces)
            if ($im['TitledHeroArt']) { $capsule = Get-BitmapDesdeUrl $im['TitledHeroArt'].Uri }
            if ($im['SuperHeroArt'])  { $hero    = Get-BitmapDesdeUrl $im['SuperHeroArt'].Uri }
            if (-not $hero)           { $hero    = $capsule }
            if ($im['Logo'])          { $logo    = Get-BitmapDesdeUrl $im['Logo'].Uri }
            if (-not $logo -and $im['BoxArt']) { $logo = Get-BitmapDesdeUrl $im['BoxArt'].Uri }
            if ($poster -or $hero) { $origen = 'Microsoft Store (oficial)' }
        } else { Registrar '  el catálogo no ha respondido' }
    }

    # 2) SteamGridDB
    if (-not $poster -and ($OrigenArte -eq 'Automatico' -or $OrigenArte -eq 'SteamGridDB')) {
        Registrar "Buscando '$NombreFinal' en SteamGridDB..."
        $sg = Get-SgdbImagenes -Nombre $NombreFinal -Log $Log
        if ($sg) {
            if ($sg['Poster'])  { $poster  = Get-BitmapDesdeUrl $sg['Poster'] }
            if ($sg['Hero'])    { $hero    = Get-BitmapDesdeUrl $sg['Hero'] }
            if ($sg['Capsule']) { $capsule = Get-BitmapDesdeUrl $sg['Capsule'] }
            if ($sg['Logo'])    { $logo    = Get-BitmapDesdeUrl $sg['Logo'] }
            if ($poster) { $origen = 'SteamGridDB' }
        }
    }

    # 3) Assets locales
    # Las apps de la Store no traen Icono de la deteccion: su logo se busca aqui, en el paquete
    # instalado, y solo para la que se prepara. Sin el, si el catalogo no la encuentra, la
    # caratula es el nombre sobre fondo oscuro. Get-LogoAppStore vive en Fuentes.ps1: esta lib
    # se puede cargar suelta, de ahi el Get-Command.
    $iconoLocal = $Juego.Icono
    $prefijoApp = 'shell:AppsFolder\'
    if (-not $iconoLocal -and $Juego.LaunchOptions -and $Juego.LaunchOptions.StartsWith($prefijoApp) -and
        (Get-Command Get-LogoAppStore -ErrorAction SilentlyContinue)) {
        $iconoLocal = Get-LogoAppStore -Aumid $Juego.LaunchOptions.Substring($prefijoApp.Length)
        if ($iconoLocal) { Registrar "  logo de la app: $(Split-Path $iconoLocal -Leaf)" }
    }
    $loc = Get-AssetsLocales -Carpeta $Juego.Carpeta -Icono $iconoLocal
    $logoDelExe = $false
    if (-not $logo) { $logo = $loc.Logo; $logoDelExe = [bool]$loc.LogoDelExe }
    $fondoLocal = $loc.Fondo
    if (-not $poster) { Registrar 'Componiendo carátulas con los assets locales del juego...' }

    $rutas = @{}
    # p.png 600x900
    $fondoPortada = $fondoLocal; if (-not $fondoPortada) { $fondoPortada = $hero }
    if ($poster) { $b = New-ImagenCover -Origen $poster -Ancho 600 -Alto 900 }
    else         { $b = New-CaratulaCompuesta -Fondo $fondoPortada -Logo $logo -Ancho 600 -Alto 900 -Texto $NombreFinal }
    $rutas['p'] = Join-Path $GridDir "${AppId}p.png"; Save-Png -Bitmap $b -Ruta $rutas['p']; $b.Dispose()

    # .png 460x215
    $baseCap = $capsule; if (-not $baseCap) { $baseCap = $hero }
    if ($baseCap) { $b = New-ImagenCover -Origen $baseCap -Ancho 460 -Alto 215 }
    else          { $b = New-CaratulaCompuesta -Fondo $fondoLocal -Logo $logo -Ancho 460 -Alto 215 -Texto $NombreFinal }
    $rutas['cap'] = Join-Path $GridDir "${AppId}.png"; Save-Png -Bitmap $b -Ruta $rutas['cap']; $b.Dispose()

    # _hero.png 1920x620
    $baseHero = $hero; if (-not $baseHero) { $baseHero = $fondoLocal }
    if ($baseHero) { $b = New-ImagenCover -Origen $baseHero -Ancho 1920 -Alto 620 }
    else           { $b = New-CaratulaCompuesta -Fondo $null -Logo $null -Ancho 1920 -Alto 620 }
    $rutas['hero'] = Join-Path $GridDir "${AppId}_hero.png"; Save-Png -Bitmap $b -Ruta $rutas['hero']; $b.Dispose()

    # _logo.png: solo con un logo de verdad, que va suelto encima del hero
    if ($logo -and -not $logoDelExe -and (Test-EsLogo -Bitmap $logo)) {
        $rutas['logo'] = Join-Path $GridDir "${AppId}_logo.png"; Save-Png -Bitmap $logo -Ruta $rutas['logo']
    } else {
        # el de un intento anterior valdria de todas formas: fuera
        $logoViejo = Join-Path $GridDir "${AppId}_logo.png"
        if (Test-Path -LiteralPath $logoViejo) { Remove-Item -LiteralPath $logoViejo -Force -ErrorAction SilentlyContinue }
        if ($logo -and -not $logoDelExe) { Registrar '  la imagen del logo lleva fondo: la uso de icono, pero no como logo suelto' }
    }

    # _icon.png: cuadrado y sin deformar. Del logo si lo hay (la baldosa de la Store, que no
    # vale de logo, aqui va perfecta) y si no, recortando la portada al centro.
    $baseIcono = $null
    if ($logo -and -not $logoDelExe) { $baseIcono = $logo }
    $ic = $null
    if ($baseIcono)   { $ic = New-IconoCuadrado -Origen $baseIcono -Lado 256 }
    elseif ($poster)  { $ic = New-ImagenCover -Origen $poster  -Ancho 256 -Alto 256 }
    elseif ($capsule) { $ic = New-ImagenCover -Origen $capsule -Ancho 256 -Alto 256 }
    if ($ic) {
        $rutas['icon'] = Join-Path $GridDir "${AppId}_icon.png"; Save-Png -Bitmap $ic -Ruta $rutas['icon']; $ic.Dispose()
    }

    # $hero y $capsule pueden ser el mismo bitmap (TitledHeroArt): no repetir el Dispose
    $sueltos = New-Object System.Collections.ArrayList
    foreach ($bm in @($poster, $hero, $capsule, $logo, $fondoLocal)) {
        if ($bm -and -not $sueltos.Contains($bm)) { [void]$sueltos.Add($bm); $bm.Dispose() }
    }
    Registrar "Carátulas generadas desde: $origen"
    return [pscustomobject]@{ Origen = $origen; Rutas = $rutas; StoreId = $storeId }
}
