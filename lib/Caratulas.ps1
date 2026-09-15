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
#    <appid>_icon.png  icono de la lista
# =====================================================================

Add-Type -AssemblyName System.Drawing

function Initialize-Tls {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
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

function Find-StoreId {
    param([Parameter(Mandatory)][string]$Nombre)
    Initialize-Tls
    $q = [uri]::EscapeDataString($Nombre)
    $url = "https://storeedgefd.dsx.mp.microsoft.com/v9.0/search?query=$q&market=ES&locale=es-ES&deviceFamily=Windows.Desktop"
    try {
        $r = Invoke-RestMethod -Uri $url -TimeoutSec 20
        foreach ($grupo in $r.Payload.SearchResults) {
            if ($grupo.ProductId) { return $grupo.ProductId }
        }
    } catch { }
    return $null
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

function Get-SgdbImagenes {
    param([Parameter(Mandatory)][string]$Nombre, [scriptblock]$Log = $null)
    function Registrar($m) { if ($Log) { & $Log $m } }
    $clave = Get-SgdbClave
    if (-not $clave) { Registrar '  sin clave de SteamGridDB (se pone en Ajustes), me lo salto'; return $null }
    Initialize-Tls
    $h = @{ Authorization = "Bearer $clave" }
    try {
        $b = Invoke-RestMethod -Uri "https://www.steamgriddb.com/api/v2/search/autocomplete/$([uri]::EscapeDataString($Nombre))" -Headers $h -TimeoutSec 20
        if (-not $b.data -or $b.data.Count -eq 0) { Registrar "  SteamGridDB no conoce '$Nombre'"; return $null }
        $id = $b.data[0].id
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
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('User-Agent','Mozilla/5.0')
        $bytes = $wc.DownloadData($Url)
        $ms = New-Object System.IO.MemoryStream(,$bytes)
        return [System.Drawing.Bitmap]::FromStream($ms)
    } catch { return $null }
}

function Get-BitmapDesdeArchivo {
    param([Parameter(Mandatory)][string]$Ruta)
    try {
        if ($Ruta -match '\.exe$') {
            $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($Ruta)
            if ($ico) { return $ico.ToBitmap() }
            return $null
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
        $rect = New-Object System.Drawing.RectangleF(($Ancho*0.08), 0, ($Ancho*0.84), $Alto)
        $sombra = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(200,0,0,0))
        $rect2 = New-Object System.Drawing.RectangleF(($Ancho*0.08)+3, 3, ($Ancho*0.84), $Alto)
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
    $r = @{ Fondo = $null; Logo = $null }
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
    if (-not $r.Logo -and $Icono -and (Test-Path -LiteralPath $Icono)) { $r.Logo = Get-BitmapDesdeArchivo -Ruta $Icono }
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
        [scriptblock]$Log = $null
    )
    function Registrar($m) { if ($Log) { & $Log $m } }
    if (-not $NombreFinal) { $NombreFinal = $Juego.Nombre }
    if (-not (Test-Path -LiteralPath $GridDir)) { [void](New-Item -ItemType Directory -Path $GridDir -Force) }

    $origen = 'assets locales'
    $poster = $null; $hero = $null; $capsule = $null; $logo = $null

    # 1) Microsoft Store
    $storeId = $Juego.StoreId
    if (-not $storeId) {
        Registrar "Buscando '$NombreFinal' en el catálogo de la Store..."
        $storeId = Find-StoreId -Nombre $NombreFinal
        if ($storeId) { Registrar "  encontrado StoreId $storeId" }
    }
    if ($storeId) {
        Registrar "Descargando carátulas oficiales de la Store ($storeId)..."
        $cat = Get-StoreImagenes -StoreId $storeId
        if ($cat) {
            $im = $cat.Imagenes
            if ($im['Poster'])        { $poster  = Get-BitmapDesdeUrl $im['Poster'].Uri }
            if (-not $poster -and $im['BrandedKeyArt']) { $poster = Get-BitmapDesdeUrl $im['BrandedKeyArt'].Uri }
            if ($im['SuperHeroArt'])  { $hero    = Get-BitmapDesdeUrl $im['SuperHeroArt'].Uri }
            if (-not $hero -and $im['TitledHeroArt']) { $hero = Get-BitmapDesdeUrl $im['TitledHeroArt'].Uri }
            if ($im['TitledHeroArt']) { $capsule = Get-BitmapDesdeUrl $im['TitledHeroArt'].Uri }
            if ($im['Logo'])          { $logo    = Get-BitmapDesdeUrl $im['Logo'].Uri }
            if (-not $logo -and $im['BoxArt']) { $logo = Get-BitmapDesdeUrl $im['BoxArt'].Uri }
            if ($poster -or $hero) { $origen = 'Microsoft Store (oficial)' }
        } else { Registrar '  el catálogo no ha respondido' }
    }

    # 2) SteamGridDB
    if (-not $poster) {
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
    $loc = Get-AssetsLocales -Carpeta $Juego.Carpeta -Icono $Juego.Icono
    if (-not $logo) { $logo = $loc.Logo }
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

    # _logo.png y _icon.png
    if ($logo) {
        $rutas['logo'] = Join-Path $GridDir "${AppId}_logo.png"; Save-Png -Bitmap $logo -Ruta $rutas['logo']
        $ic = New-Object System.Drawing.Bitmap($logo, 256, 256)
        $rutas['icon'] = Join-Path $GridDir "${AppId}_icon.png"; Save-Png -Bitmap $ic -Ruta $rutas['icon']; $ic.Dispose()
    }

    foreach ($bm in @($poster, $hero, $capsule, $logo, $fondoLocal)) { if ($bm) { $bm.Dispose() } }
    Registrar "Carátulas generadas desde: $origen"
    return [pscustomobject]@{ Origen = $origen; Rutas = $rutas; StoreId = $storeId }
}
