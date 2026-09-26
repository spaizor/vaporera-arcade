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
# La ficha del producto en el catalogo, o $null si no responde
function Get-StoreProducto {
    param([Parameter(Mandatory)][string]$StoreId)
    Initialize-Tls
    $url = "https://displaycatalog.mp.microsoft.com/v7.0/products/$StoreId" +
           "?market=ES&languages=es-ES,en-US&fieldsTemplate=Details"
    try {
        $r = Invoke-RestMethod -Uri $url -Headers @{ 'MS-CV' = 'VaporeraArcade.1' } -TimeoutSec 25
    } catch { return $null }
    return $r.Product
}

# Todas las imagenes de la ficha, sin repetir (cada idioma trae las suyas y suelen coincidir)
function Get-StoreListaImagenes {
    param($Producto)
    $lista = @()
    $vistas = @{}
    foreach ($lp in $Producto.LocalizedProperties) {
        foreach ($im in $lp.Images) {
            $u = [string]$im.Uri
            if (-not $u) { continue }
            if ($u.StartsWith('//')) { $u = 'https:' + $u }
            if ($vistas.ContainsKey($u)) { continue }
            $vistas[$u] = $true
            $lista += [pscustomobject]@{ Proposito = [string]$im.ImagePurpose; Uri = $u; Ancho = [int]$im.Width; Alto = [int]$im.Height }
        }
    }
    return $lista
}

function Get-StoreImagenes {
    param([Parameter(Mandatory)][string]$StoreId)
    $prod = Get-StoreProducto -StoreId $StoreId
    if (-not $prod) { return $null }
    $imgs = @{}
    foreach ($im in @(Get-StoreListaImagenes $prod)) {
        # nos quedamos con la mayor de cada tipo
        $k = $im.Proposito
        $px = $im.Ancho * $im.Alto
        if (-not $imgs.ContainsKey($k) -or $px -gt $imgs[$k].Pixeles) {
            $imgs[$k] = [pscustomobject]@{ Uri = $im.Uri; Ancho = $im.Ancho; Alto = $im.Alto; Pixeles = $px }
        }
    }
    $titulo = ''
    if ($prod.LocalizedProperties -and $prod.LocalizedProperties[0].ProductTitle) {
        $titulo = $prod.LocalizedProperties[0].ProductTitle
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

# El id del juego que mas se parece al nombre, o $null si ninguno se parece bastante
function Find-SgdbId {
    param(
        [Parameter(Mandatory)][string]$Nombre,
        [Parameter(Mandatory)][hashtable]$Cabeceras,
        [double]$MinParecido = $MinParecidoTitulo,
        [scriptblock]$Log = $null
    )
    function Registrar($m) { if ($Log) { & $Log $m | Out-Null } }
    $cand = Get-SgdbCandidatos -Nombre $Nombre -Cabeceras $Cabeceras
    if (-not $cand.Count) { Registrar "  SteamGridDB no conoce '$Nombre'"; return $null }
    $mejor = $cand[0]
    if ($mejor.Parecido -lt $MinParecido) {
        Registrar "  lo más parecido en SteamGridDB es '$($mejor.Titulo)': no se parece bastante a '$Nombre', lo descarto"
        return $null
    }
    if ($mejor.Parecido -lt 1) { Registrar "  SteamGridDB lo llama '$($mejor.Titulo)'" }
    return [string]$mejor.Id
}

# Que se le pide a SteamGridDB para cada hueco. La portada, solo 600x900: con 342x482 (la
# otra medida vertical) salian primero imagenes pequenas. Solo PNG/JPG sin animar: un WebP o
# un GIF animado no lo lee GDI+, y antes se cogia el primero fuera lo que fuera.
$SgdbRanuras = @{
    p    = 'grids/game/{0}?dimensions=600x900'
    cap  = 'grids/game/{0}?dimensions=460x215,920x430'
    hero = 'heroes/game/{0}'
    logo = 'logos/game/{0}'
}

# Una opcion de la galeria: de donde sale, la imagen entera y su miniatura
function New-Alternativa {
    param([string]$Origen, [string]$Detalle, [string]$Url, [string]$Miniatura, [int]$Ancho = 0, [int]$Alto = 0)
    if (-not $Miniatura) { $Miniatura = $Url }
    return [pscustomobject]@{ Origen = $Origen; Detalle = $Detalle; Url = $Url; Miniatura = $Miniatura; Ancho = $Ancho; Alto = $Alto }
}

# Las imagenes de SteamGridDB para un hueco (p, cap, hero, logo), en el orden de la web (por
# votos). Lanza si falla la red: quien llama decide que decir.
function Get-SgdbAlternativas {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('p','cap','hero','logo')][string]$Ranura,
        [Parameter(Mandatory)][hashtable]$Cabeceras
    )
    Initialize-Tls
    $ruta = $SgdbRanuras[$Ranura] -f $Id
    $sep = if ($ruta.Contains('?')) { '&' } else { '?' }
    $mimes = if ($Ranura -eq 'logo') { 'image/png' } else { 'image/png,image/jpeg' }
    $r = Invoke-RestMethod -Uri ('https://www.steamgriddb.com/api/v2/' + $ruta + $sep + 'mimes=' + $mimes + '&types=static') `
            -Headers $Cabeceras -TimeoutSec 20
    $lista = @()
    foreach ($d in @($r.data)) {
        if (-not $d -or -not $d.url) { continue }
        $autor = ''
        if ($d.author -and $d.author.name) { $autor = [string]$d.author.name }
        $lista += New-Alternativa -Origen 'SteamGridDB' -Detalle $autor -Url ([string]$d.url) `
                    -Miniatura ([string]$d.thumb) -Ancho ([int]$d.width) -Alto ([int]$d.height)
    }
    return $lista
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
        $id = Find-SgdbId -Nombre $Nombre -Cabeceras $h -MinParecido $MinParecido -Log $Log
        if (-not $id) { return $null }
        # el id va tambien: la galeria de la vista previa lo reutiliza para no buscar otra vez
        $res = @{ Id = $id }
        foreach ($par in @(@('Poster','p'), @('Capsule','cap'), @('Hero','hero'), @('Logo','logo'))) {
            $alt = @(Get-SgdbAlternativas -Id $id -Ranura $par[1] -Cabeceras $h)
            if ($alt.Count) { $res[$par[0]] = $alt[0].Url }
        }
        return $res
    } catch {
        Registrar "  SteamGridDB ha fallado: $($_.Exception.Message)"
        return $null
    }
}

# ---------------------------------------------------------------------
#  Utilidades de imagen
# ---------------------------------------------------------------------
# Los bytes de una URL. Lanza con un mensaje que se pueda ensenar: SteamGridDB tiene imagenes
# rotas que contestan 200 y, tras ~30 s, cero bytes (visto con una portada de Rayman Origins).
function Get-BytesDesdeUrl {
    param([Parameter(Mandatory)][string]$Url)
    Initialize-Tls
    $wc = New-Object System.Net.WebClient
    try {
        $wc.Headers.Add('User-Agent','Mozilla/5.0')
        try { $bytes = $wc.DownloadData($Url) }
        catch { throw "No he podido descargar la imagen ($($_.Exception.GetBaseException().Message))." }
        if (-not $bytes -or $bytes.Length -eq 0) { throw 'La web ha devuelto la imagen vacía: parece rota en su servidor.' }
        return ,$bytes
    } finally { $wc.Dispose() }
}

function Get-BitmapDesdeBytes {
    param([byte[]]$Bytes)
    # el MemoryStream NO se libera: el bitmap lo necesita vivo mientras exista
    $ms = New-Object System.IO.MemoryStream(,$Bytes)
    return [System.Drawing.Bitmap]::FromStream($ms)
}

function Get-BitmapDesdeUrl {
    param([Parameter(Mandatory)][string]$Url)
    try { return (Get-BitmapDesdeBytes (Get-BytesDesdeUrl $Url)) } catch { return $null }
}

# El fotograma mas grande de un .ico. GDI+ (FromStream) no elige el mas grande: con los de GOG
# (256 y 48 en PNG, 32 y 16 en BMP) carga el de 16, aunque el de 256 va el primero. Se lee el
# indice a mano: cabecera de 6 bytes (tipo 1 = icono y numero de imagenes) y 16 bytes por
# imagen (ancho, 0 = 256; tamano y posicion de sus datos). Un fotograma PNG se carga tal cual;
# uno BMP, envuelto en un .ico de una sola imagen, que GDI+ lee bien. $null si no es un .ico.
function Get-BitmapDesdeIco {
    param([byte[]]$Bytes)
    if (-not $Bytes -or $Bytes.Length -lt 22 -or [BitConverter]::ToUInt16($Bytes, 2) -ne 1) { return $null }
    $n = [BitConverter]::ToUInt16($Bytes, 4)
    $mejor = -1; $lado = 0
    for ($i = 0; $i -lt $n; $i++) {
        $o = 6 + 16 * $i
        if ($o + 16 -gt $Bytes.Length) { break }
        $w = [int]$Bytes[$o]; if ($w -eq 0) { $w = 256 }
        $tam = [uint64][BitConverter]::ToUInt32($Bytes, $o + 8)
        $pos = [uint64][BitConverter]::ToUInt32($Bytes, $o + 12)
        if ($tam -eq 0 -or $pos + $tam -gt [uint64]$Bytes.Length) { continue }   # entrada rota
        if ($w -gt $lado) { $lado = $w; $mejor = $o }
    }
    if ($mejor -lt 0) { return $null }
    $tam = [int][BitConverter]::ToUInt32($Bytes, $mejor + 8)
    $pos = [int][BitConverter]::ToUInt32($Bytes, $mejor + 12)
    $datos = New-Object byte[] $tam
    [Array]::Copy($Bytes, $pos, $datos, 0, $tam)
    if ($tam -ge 4 -and $datos[0] -eq 0x89 -and $datos[1] -eq 0x50 -and $datos[2] -eq 0x4E -and $datos[3] -eq 0x47) {
        $img = $datos
    } else {
        $img = New-Object byte[] (22 + $tam)
        $img[2] = 1; $img[4] = 1                               # tipo icono, una imagen
        [Array]::Copy($Bytes, $mejor, $img, 6, 12)            # su entrada, sin la posicion
        [Array]::Copy([BitConverter]::GetBytes([uint32]22), 0, $img, 18, 4)
        [Array]::Copy($datos, 0, $img, 22, $tam)
    }
    # el MemoryStream NO se libera: el bitmap lo necesita vivo mientras exista
    $ms = New-Object System.IO.MemoryStream(,$img)
    return [System.Drawing.Bitmap]::FromStream($ms)
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
        if ($Ruta -match '\.ico$') {
            $bm = Get-BitmapDesdeIco -Bytes $bytes
            if ($bm) { return $bm }
        }
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

# Texto blanco con sombra dentro del rectangulo. Si no cabe entero (un nombre largo partido en
# varias lineas se cortaria por abajo) baja la letra hasta que quepa. Las medidas llegan ya
# como [single]: 'New-Object RectangleF(($Ancho*0.08)+3, 3, ...)' hace que PS 5.1 lea el resto
# de argumentos como un array y lo sume al primero (op_Addition).
function Add-TextoConSombra {
    param(
        [System.Drawing.Graphics]$Graficos, [string]$Texto,
        [single]$X, [single]$Y, [single]$Ancho, [single]$Alto, [int]$Tam,
        [System.Drawing.StringAlignment]$Horizontal = 'Center',
        [System.Drawing.StringAlignment]$Vertical = 'Center'
    )
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Alignment = $Horizontal; $fmt.LineAlignment = $Vertical
    while ($true) {
        $fuente = New-Object System.Drawing.Font('Segoe UI', $Tam, [System.Drawing.FontStyle]::Bold)
        $medida = $Graficos.MeasureString($Texto, $fuente, [int]$Ancho, $fmt)
        if ($medida.Height -le $Alto -or $Tam -le 10) { break }
        $fuente.Dispose()
        $Tam = [int]($Tam * 0.9)
    }
    $xs = [single]($X + 3); $ys = [single]($Y + 3)
    $rect   = New-Object System.Drawing.RectangleF($X, $Y, $Ancho, $Alto)
    $rect2  = New-Object System.Drawing.RectangleF($xs, $ys, $Ancho, $Alto)
    $sombra = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(200,0,0,0))
    $blanco = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $Graficos.DrawString($Texto, $fuente, $sombra, $rect2, $fmt)
    $Graficos.DrawString($Texto, $fuente, $blanco, $rect, $fmt)
    $sombra.Dispose(); $blanco.Dispose(); $fuente.Dispose(); $fmt.Dispose()
}

# Compone una caratula a partir de un fondo + logo (plan B sin internet). Pinta el logo o el
# texto, salvo con -LogoYNombre, que pone los dos: es para los iconos de las apps de la Store,
# que a diferencia del logo de un juego no llevan el nombre y solos no se reconocen.
function New-CaratulaCompuesta {
    param(
        [System.Drawing.Bitmap]$Fondo, [System.Drawing.Bitmap]$Logo,
        [int]$Ancho, [int]$Alto, [string]$Texto = '', [switch]$LogoYNombre
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
    if ($Logo -and $LogoYNombre -and $Texto) {
        if ($Alto -ge $Ancho) {
            # vertical (portada): el icono acaba en la mitad y el nombre va debajo
            $esc = [Math]::Min(($Ancho * 0.5) / $Logo.Width, ($Alto * 0.28) / $Logo.Height)
            $lw = [int]($Logo.Width * $esc); $lh = [int]($Logo.Height * $esc)
            $g.DrawImage($Logo, [int](($Ancho - $lw)/2), [int]($Alto * 0.5) - $lh, $lw, $lh)
            Add-TextoConSombra -Graficos $g -Texto $Texto -X ($Ancho * 0.08) -Y ($Alto * 0.54) `
                -Ancho ($Ancho * 0.84) -Alto ($Alto * 0.36) -Tam ([Math]::Max(14, [int]($Ancho / 13))) -Vertical Near
        } else {
            # apaisada (capsula): el icono a la izquierda y el nombre a su derecha
            $lado = $Alto * 0.6
            $esc = [Math]::Min($lado / $Logo.Width, $lado / $Logo.Height)
            $lw = [int]($Logo.Width * $esc); $lh = [int]($Logo.Height * $esc)
            $lx = [int]($Ancho * 0.07)
            $g.DrawImage($Logo, $lx + [int](($lado - $lw)/2), [int](($Alto - $lh)/2), $lw, $lh)
            $tx = $lx + $lado + ($Ancho * 0.05)
            Add-TextoConSombra -Graficos $g -Texto $Texto -X $tx -Y ($Alto * 0.1) `
                -Ancho ($Ancho * 0.95 - $tx) -Alto ($Alto * 0.8) -Tam ([Math]::Max(12, [int]($Alto / 7))) -Horizontal Near
        }
    }
    elseif ($Logo) {
        $maxW = [int]($Ancho * 0.72); $maxH = [int]($Alto * 0.42)
        $esc = [Math]::Min($maxW / $Logo.Width, $maxH / $Logo.Height)
        $lw = [int]($Logo.Width * $esc); $lh = [int]($Logo.Height * $esc)
        $g.DrawImage($Logo, [int](($Ancho - $lw)/2), [int](($Alto - $lh)/2), $lw, $lh)
    }
    elseif ($Texto) {
        Add-TextoConSombra -Graficos $g -Texto $Texto -X ($Ancho * 0.08) -Y 0 `
            -Ancho ($Ancho * 0.84) -Alto $Alto -Tam ([Math]::Max(14, [int]($Ancho / 11)))
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
    # caratula, pero no para generar un _icon.png de 256 (sale borroso) ni un _logo.png. Un
    # .ico (Ubisoft) se lee con su imagen grande, pero si no la trae se trata igual.
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
        if ($r.Logo) { $r.LogoDelExe = [bool](($Icono -match '\.exe$') -or $r.Logo.Width -lt 128) }
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
    $poster = $null; $hero = $null; $capsule = $null; $logo = $null; $logoDeSgdb = $false

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
    $sgdbId = $null
    if (-not $poster -and ($OrigenArte -eq 'Automatico' -or $OrigenArte -eq 'SteamGridDB')) {
        Registrar "Buscando '$NombreFinal' en SteamGridDB..."
        $sg = Get-SgdbImagenes -Nombre $NombreFinal -Log $Log
        if ($sg) {
            $sgdbId = $sg['Id']
            if ($sg['Poster'])  { $poster  = Get-BitmapDesdeUrl $sg['Poster'] }
            if ($sg['Hero'])    { $hero    = Get-BitmapDesdeUrl $sg['Hero'] }
            if ($sg['Capsule']) { $capsule = Get-BitmapDesdeUrl $sg['Capsule'] }
            if ($sg['Logo'])    { $logo    = Get-BitmapDesdeUrl $sg['Logo']; $logoDeSgdb = [bool]$logo }
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
    $esApp = [bool]($Juego.LaunchOptions -and $Juego.LaunchOptions.StartsWith($prefijoApp))
    if (-not $iconoLocal -and $esApp -and (Get-Command Get-LogoAppStore -ErrorAction SilentlyContinue)) {
        $iconoLocal = Get-LogoAppStore -Aumid $Juego.LaunchOptions.Substring($prefijoApp.Length)
        if ($iconoLocal) { Registrar "  logo de la app: $(Split-Path $iconoLocal -Leaf)" }
    }
    $loc = Get-AssetsLocales -Carpeta $Juego.Carpeta -Icono $iconoLocal
    $logoDelExe = $false
    if (-not $logo) { $logo = $loc.Logo; $logoDelExe = [bool]$loc.LogoDelExe }
    $fondoLocal = $loc.Fondo
    if (-not $poster) { Registrar 'Componiendo carátulas con los assets locales del juego...' }
    # El icono de una app (del paquete o la baldosa del catalogo) no lleva el nombre: se pinta
    # debajo. El logo de SteamGridDB si lo suele llevar, igual que el de un juego.
    $conNombre = $esApp -and -not $logoDeSgdb

    $rutas = @{}
    # p.png 600x900
    $fondoPortada = $fondoLocal; if (-not $fondoPortada) { $fondoPortada = $hero }
    if ($poster) { $b = New-ImagenCover -Origen $poster -Ancho 600 -Alto 900 }
    else         { $b = New-CaratulaCompuesta -Fondo $fondoPortada -Logo $logo -Ancho 600 -Alto 900 -Texto $NombreFinal -LogoYNombre:$conNombre }
    $rutas['p'] = Join-Path $GridDir "${AppId}p.png"; Save-Png -Bitmap $b -Ruta $rutas['p']; $b.Dispose()

    # .png 460x215
    $baseCap = $capsule; if (-not $baseCap) { $baseCap = $hero }
    if ($baseCap) { $b = New-ImagenCover -Origen $baseCap -Ancho 460 -Alto 215 }
    else          { $b = New-CaratulaCompuesta -Fondo $fondoLocal -Logo $logo -Ancho 460 -Alto 215 -Texto $NombreFinal -LogoYNombre:$conNombre }
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
    # $iconoDe dice de cual ha salido: si luego se elige otra imagen en la galeria, el icono
    # se rehace solo si viene de ese hueco o de uno que manda menos (Set-CaratulaRanura)
    $baseIcono = $null
    if ($logo -and -not $logoDelExe) { $baseIcono = $logo }
    $ic = $null; $iconoDe = ''
    if ($baseIcono)   { $ic = New-IconoCuadrado -Origen $baseIcono -Lado 256; $iconoDe = 'logo' }
    elseif ($poster)  { $ic = New-ImagenCover -Origen $poster  -Ancho 256 -Alto 256; $iconoDe = 'p' }
    elseif ($capsule) { $ic = New-ImagenCover -Origen $capsule -Ancho 256 -Alto 256; $iconoDe = 'cap' }
    if ($ic) {
        $rutas['icon'] = Join-Path $GridDir "${AppId}_icon.png"; Save-Png -Bitmap $ic -Ruta $rutas['icon']; $ic.Dispose()
    }

    # $hero y $capsule pueden ser el mismo bitmap (TitledHeroArt): no repetir el Dispose
    $sueltos = New-Object System.Collections.ArrayList
    foreach ($bm in @($poster, $hero, $capsule, $logo, $fondoLocal)) {
        if ($bm -and -not $sueltos.Contains($bm)) { [void]$sueltos.Add($bm); $bm.Dispose() }
    }
    Registrar "Carátulas generadas desde: $origen"
    return [pscustomobject]@{ Origen = $origen; Rutas = $rutas; StoreId = $storeId; SgdbId = $sgdbId; IconoDe = $iconoDe }
}

# ---------------------------------------------------------------------
#  Galeria de la vista previa: otras imagenes para un hueco y cambiar la elegida
# ---------------------------------------------------------------------

# Medidas finales de cada hueco (el logo va tal cual) y ancho de su miniatura
$MedidasRanura = @{
    p    = @{ Ancho = 600;  Alto = 900; Mini = 240 }
    cap  = @{ Ancho = 460;  Alto = 215; Mini = 368 }
    hero = @{ Ancho = 1920; Alto = 620; Mini = 480 }
    logo = @{ Ancho = 0;    Alto = 0;   Mini = 320 }
}

# Que tipos de imagen del catalogo valen para cada hueco, por orden. El 'Logo' de la Store no
# esta: es una baldosa opaca y no vale de logo suelto (Test-EsLogo).
$StorePropositos = @{
    p    = @('Poster', 'BrandedKeyArt', 'BoxArt')
    cap  = @('TitledHeroArt', 'SuperHeroArt', 'Screenshot')
    hero = @('SuperHeroArt', 'TitledHeroArt', 'Screenshot')
    logo = @()
}

# Las imagenes del catalogo de la Store para un hueco. El servidor de imagenes de la Store
# las da reducidas con ?w=<ancho>: esa es la miniatura.
function Get-StoreAlternativas {
    param(
        [string]$StoreId,
        [Parameter(Mandatory)][ValidateSet('p','cap','hero','logo')][string]$Ranura,
        $Producto = $null
    )
    $props = $StorePropositos[$Ranura]
    if (-not $props.Count) { return @() }
    if (-not $Producto) {
        if (-not $StoreId) { return @() }
        $Producto = Get-StoreProducto -StoreId $StoreId
        if (-not $Producto) { return @() }
    }
    $todas = @(Get-StoreListaImagenes $Producto)
    $ancho = $MedidasRanura[$Ranura].Mini
    $lista = @()
    foreach ($pr in $props) {
        foreach ($im in @($todas | Where-Object { $_.Proposito -eq $pr } | Sort-Object { $_.Ancho * $_.Alto } -Descending)) {
            $sep = if ($im.Uri.Contains('?')) { '&' } else { '?' }
            $lista += New-Alternativa -Origen 'Microsoft Store' -Detalle $pr -Url $im.Uri `
                        -Miniatura ($im.Uri + $sep + "w=$ancho") -Ancho $im.Ancho -Alto $im.Alto
        }
    }
    return $lista
}

# Todo lo que se puede ofrecer para un hueco: primero la Store (oficial) y luego SteamGridDB.
# Sin $SgdbId lo busca por el nombre (si la preparacion se quedo en la Store no se llego a
# buscar) y lo devuelve, para no repetirlo en el siguiente hueco. No lanza.
function Get-Alternativas {
    param(
        [Parameter(Mandatory)][ValidateSet('p','cap','hero','logo')][string]$Ranura,
        [Parameter(Mandatory)][string]$Nombre,
        [string]$StoreId = '',
        [string]$SgdbId = '',
        [scriptblock]$Log = $null
    )
    function Registrar($m) { if ($Log) { & $Log $m | Out-Null } }
    $lista = @()
    if ($StoreId -and $StorePropositos[$Ranura].Count) {
        $lista += @(Get-StoreAlternativas -StoreId $StoreId -Ranura $Ranura)
    }
    $clave = Get-SgdbClave
    if (-not $clave) {
        Registrar '  sin clave de SteamGridDB (se pone en Ajustes): solo hay lo de la Store'
    } else {
        $h = @{ Authorization = "Bearer $clave" }
        try {
            if (-not $SgdbId) { $SgdbId = [string](Find-SgdbId -Nombre $Nombre -Cabeceras $h -Log $Log) }
            if ($SgdbId) { $lista += @(Get-SgdbAlternativas -Id $SgdbId -Ranura $Ranura -Cabeceras $h) }
        } catch {
            Registrar "  SteamGridDB ha fallado: $($_.Exception.Message)"
        }
    }
    return [pscustomobject]@{ Lista = $lista; SgdbId = $SgdbId }
}

# Baja las miniaturas a $Carpeta de una en una y avisa de cada una en cuanto esta, para que
# la galeria las vaya ensenando. La que falle se queda sin miniatura, sin mas.
function Save-Miniaturas {
    param(
        [object[]]$Lista,
        [Parameter(Mandatory)][string]$Carpeta,
        [Parameter(Mandatory)][string]$Prefijo,
        [scriptblock]$Aviso = $null
    )
    Initialize-Tls
    if (-not (Test-Path -LiteralPath $Carpeta)) { [void](New-Item -ItemType Directory -Path $Carpeta -Force) }
    $wc = New-Object System.Net.WebClient
    try {
        for ($i = 0; $i -lt @($Lista).Count; $i++) {
            $destino = Join-Path $Carpeta ('{0}-{1}.img' -f $Prefijo, $i)
            try {
                $wc.Headers['User-Agent'] = 'Mozilla/5.0'
                $wc.DownloadFile($Lista[$i].Miniatura, $destino)
                if ($Aviso) { & $Aviso ([pscustomobject]@{ Tipo = 'Mini'; Indice = $i; Ruta = $destino }) | Out-Null }
            } catch { }
        }
    } finally { $wc.Dispose() }
}

# Cuanto manda cada hueco como base del icono: el logo mas que la portada, y esta mas que la
# capsula (el mismo orden que en New-CaratulasSteam). El hero no se usa nunca.
$PrioridadIcono = @{ '' = 0; cap = 1; p = 2; logo = 3; hero = 0 }

# Cambia la imagen de un hueco por $Origen (una URL o un fichero) y la deja con las medidas de
# Steam en $GridDir, con el mismo nombre que le da New-CaratulasSteam. Si el icono salia de
# este hueco o de uno que manda menos, lo rehace con la nueva. Devuelve la ruta, la del icono
# (vacia si no ha cambiado) y de donde sale ahora el icono. Lanza si no puede con la imagen.
function Set-CaratulaRanura {
    param(
        [Parameter(Mandatory)][ValidateSet('p','cap','hero','logo')][string]$Ranura,
        [Parameter(Mandatory)][string]$Origen,
        [Parameter(Mandatory)][string]$GridDir,
        [Parameter(Mandatory)][uint32]$AppId,
        [string]$IconoDe = '',
        [scriptblock]$Log = $null
    )
    function Registrar($m) { if ($Log) { & $Log $m | Out-Null } }
    if ($Origen -match '^https?://') { $bytes = Get-BytesDesdeUrl $Origen }
    else { $bytes = [System.IO.File]::ReadAllBytes($Origen) }
    try { $bm = Get-BitmapDesdeBytes $bytes } catch { $bm = $null }
    if (-not $bm) { throw 'Lo descargado no es una imagen que se pueda leer.' }
    $final = $null; $ic = $null
    try {
        $nombres = @{ p = "${AppId}p.png"; cap = "${AppId}.png"; hero = "${AppId}_hero.png"; logo = "${AppId}_logo.png" }
        $ruta = Join-Path $GridDir $nombres[$Ranura]
        $icono = ''
        if ($Ranura -eq 'logo') { $final = $bm }
        else {
            $m = $MedidasRanura[$Ranura]
            $final = New-ImagenCover -Origen $bm -Ancho $m.Ancho -Alto $m.Alto
        }
        $actual = 0
        if ($PrioridadIcono.ContainsKey($IconoDe)) { $actual = $PrioridadIcono[$IconoDe] }
        if ($PrioridadIcono[$Ranura] -gt 0 -and $PrioridadIcono[$Ranura] -ge $actual) {
            if ($Ranura -eq 'logo') { $ic = New-IconoCuadrado -Origen $bm -Lado 256 }
            else { $ic = New-ImagenCover -Origen $bm -Ancho 256 -Alto 256 }
            $icono = Join-Path $GridDir "${AppId}_icon.png"
        }
        # Todo lo de disco, al final y solo con metodos .NET: cancelar la tarea solo la para
        # entre dos comandos de PowerShell, asi que o se escriben la imagen y el icono, o nada
        if (-not [System.IO.Directory]::Exists($GridDir)) { [void][System.IO.Directory]::CreateDirectory($GridDir) }
        $final.Save($ruta, [System.Drawing.Imaging.ImageFormat]::Png)
        if ($ic) { $ic.Save($icono, [System.Drawing.Imaging.ImageFormat]::Png) }

        Registrar "  $($nombres[$Ranura]): $($bm.Width)x$($bm.Height)"
        if ($ic) { $IconoDe = $Ranura; Registrar '  icono rehecho con la nueva imagen' }
        return [pscustomobject]@{ Ranura = $Ranura; Ruta = $ruta; Icono = $icono; IconoDe = $IconoDe }
    } finally {
        if ($ic) { $ic.Dispose() }
        if ($final -and -not [object]::ReferenceEquals($final, $bm)) { $final.Dispose() }
        $bm.Dispose()
    }
}
