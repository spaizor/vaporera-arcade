# =====================================================================
#  Tests de lib/Caratulas.ps1: comparacion de titulos y deteccion de logos. Nada de red.
#  Se lanzan con tests\Invoke-Tests.ps1 (Pester 5, Windows PowerShell 5.1)
# =====================================================================

BeforeAll {
    . (Join-Path $PSScriptRoot '..\lib\Caratulas.ps1')

    # Bitmap de prueba: opaco, o con las cuatro esquinas transparentes
    function New-BitmapPrueba([int]$ancho, [int]$alto, [switch]$EsquinasTransparentes) {
        $bm = New-Object System.Drawing.Bitmap -ArgumentList $ancho, $alto, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($bm)
        if ($EsquinasTransparentes) {
            $g.Clear([System.Drawing.Color]::Transparent)
            $pincel = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Red)
            $g.FillEllipse($pincel, 0, 0, $ancho, $alto)
            $pincel.Dispose()
        } else {
            $g.Clear([System.Drawing.Color]::Navy)
        }
        $g.Dispose()
        return $bm
    }
}

Describe 'Get-ParecidoTitulo' {
    # Los casos que motivaron la comparacion: buscar por nombre devolvia otro juego
    It '"<Buscado>" y "<Candidato>" son distintos (0): el número de la saga manda' -ForEach @(
        @{ Buscado = 'Forza Horizon 5'; Candidato = 'Forza Horizon 6' }
        @{ Buscado = 'Forza Horizon 5'; Candidato = 'Forza Horizon 4: Standard Edition' }
    ) {
        Get-ParecidoTitulo $Buscado $Candidato | Should -Be 0
    }

    It '"<Buscado>" y "<Candidato>" son el mismo juego (1)' -ForEach @(
        @{ Buscado = 'Forza Horizon 5'; Candidato = 'Forza Horizon 5 Deluxe Edition' }
        @{ Buscado = 'Forza Horizon 5'; Candidato = 'Forza Horizon 5: Standard Edition' }
        @{ Buscado = 'Forza Horizon 5'; Candidato = 'Forza Horizon 5 Edición Premium' }
        @{ Buscado = 'Sea of Thieves'; Candidato = 'Sea of Thieves Deluxe Edition' }
        @{ Buscado = 'Pokémon'; Candidato = 'pokemon' }
        @{ Buscado = 'Rainbow Six® Siege'; Candidato = 'Rainbow Six Siege' }
        @{ Buscado = 'Tom & Jerry'; Candidato = 'Tom and Jerry: Game of the Year Edition' }
    ) {
        Get-ParecidoTitulo $Buscado $Candidato | Should -Be 1
    }

    # El numero solo en uno de los dos suele ser la edicion: decide la distancia y tiene que
    # pasar el corte
    It '"Sea of Thieves" da por bueno "Sea of Thieves: 2026 Edition"' {
        Get-ParecidoTitulo 'Sea of Thieves' 'Sea of Thieves: 2026 Edition' | Should -BeGreaterOrEqual $MinParecidoTitulo
    }

    It '"<Buscado>" y "<Candidato>" no pasan el corte' -ForEach @(
        @{ Buscado = 'obs64'; Candidato = 'OBS Studio' }
        @{ Buscado = 'obs64'; Candidato = 'Obsidian' }
        @{ Buscado = 'Halo'; Candidato = 'Halo Infinite' }
        # el nombre de carpeta de Ubisoft que motivo leerlo del registro
        @{ Buscado = 'ACValhalla'; Candidato = "Assassin's Creed Valhalla" }
    ) {
        Get-ParecidoTitulo $Buscado $Candidato | Should -BeLessThan $MinParecidoTitulo
    }

    It 'un título vacío no se parece a nada' {
        Get-ParecidoTitulo '' 'Algo' | Should -Be 0
        Get-ParecidoTitulo 'Algo' '' | Should -Be 0
    }

    # Sin letras latinas, la normalizacion lo dejaria vacio y dos vacios se parecerian:
    # cualquier resultado valdria
    It 'los títulos sin letras latinas se comparan por el original' {
        Get-ParecidoTitulo 'ドラゴンクエスト' 'ドラゴンクエスト' | Should -Be 1
        Get-ParecidoTitulo 'ドラゴンクエスト' 'ファイナルファンタジー' | Should -Be 0
    }
}

Describe 'Get-TituloNormalizado' {
    It '"<Texto>" queda como "<Esperado>"' -ForEach @(
        @{ Texto = 'Forza Horizon 5 Edición Premium'; Esperado = 'forza horizon 5' }
        @{ Texto = 'Tom & Jerry: Game of the Year Edition'; Esperado = 'tom and jerry' }
        @{ Texto = 'Wolfenstein II: The New Colossus'; Esperado = 'wolfenstein ii the new colossus' }
        @{ Texto = '  Pokémon™  '; Esperado = 'pokemon' }
        @{ Texto = ''; Esperado = '' }
    ) {
        Get-TituloNormalizado $Texto | Should -BeExactly $Esperado
    }
}

Describe 'Get-DistanciaEdicion' {
    It 'la de "<A>" a "<B>" es <Esperada>' -ForEach @(
        @{ A = 'kitten'; B = 'sitting'; Esperada = 3 }
        @{ A = ''; B = 'abc'; Esperada = 3 }
        @{ A = 'abc'; B = 'abc'; Esperada = 0 }
        @{ A = 'Abc'; B = 'abc'; Esperada = 1 }
    ) {
        Get-DistanciaEdicion -A $A -B $B | Should -Be $Esperada
    }
}

Describe 'Test-EsLogo' {
    # Un logo va suelto encima del hero: tiene que ser apaisado o con el fondo transparente.
    # La baldosa cuadrada y opaca de la Store encima del hero queda fatal.
    It 'acepta una imagen apaisada aunque sea opaca' {
        $bm = New-BitmapPrueba 400 200
        try { Test-EsLogo -Bitmap $bm | Should -BeTrue } finally { $bm.Dispose() }
    }
    It 'rechaza una baldosa cuadrada y opaca' {
        $bm = New-BitmapPrueba 256 256
        try { Test-EsLogo -Bitmap $bm | Should -BeFalse } finally { $bm.Dispose() }
    }
    It 'acepta una cuadrada con las esquinas transparentes' {
        $bm = New-BitmapPrueba 256 256 -EsquinasTransparentes
        try { Test-EsLogo -Bitmap $bm | Should -BeTrue } finally { $bm.Dispose() }
    }
    It 'rechaza $null sin lanzar' {
        Test-EsLogo -Bitmap $null | Should -BeFalse
    }
}

Describe 'New-IconoCuadrado' {
    It 'encaja una imagen apaisada en 256x256 sin deformarla' {
        $bm = New-BitmapPrueba 400 200
        $ic = New-IconoCuadrado -Origen $bm -Lado 256
        try {
            $ic.Width | Should -Be 256
            $ic.Height | Should -Be 256
            # 400x200 escalado a 256 de ancho da 128 de alto, centrado: arriba queda hueco
            $ic.GetPixel(128, 10).A | Should -Be 0
            $ic.GetPixel(128, 128).A | Should -Be 255
        } finally { $bm.Dispose(); $ic.Dispose() }
    }
}

Describe 'New-CaratulaCompuesta' {
    BeforeAll {
        # Cuenta los pixeles que cumplen la condicion en una franja de filas, saltando de 8 en 8
        # (GetPixel es lento). Sin fondo, la caratula es gris oscuro (22,24,28).
        function Get-Pixeles([System.Drawing.Bitmap]$bm, [int]$desde, [int]$hasta, [scriptblock]$cumple) {
            $n = 0
            for ($y = $desde; $y -lt $hasta; $y += 8) {
                for ($x = 0; $x -lt $bm.Width; $x += 8) { if (& $cumple $bm.GetPixel($x, $y)) { $n++ } }
            }
            return $n
        }
        $script:Blanco = { param($c) $c.R -gt 200 -and $c.G -gt 200 -and $c.B -gt 200 }
        $script:Rojo   = { param($c) $c.R -gt 200 -and $c.G -lt 60 -and $c.B -lt 60 }
    }

    It 'con -LogoYNombre la portada lleva el icono arriba y el nombre debajo' {
        $logo = New-BitmapPrueba 256 256 -EsquinasTransparentes
        $p = New-CaratulaCompuesta -Logo $logo -Ancho 600 -Alto 900 -Texto 'Nombre de prueba' -LogoYNombre
        try {
            Get-Pixeles $p 0 450 $script:Rojo | Should -BeGreaterThan 0
            Get-Pixeles $p 450 900 $script:Rojo | Should -Be 0
            Get-Pixeles $p 486 810 $script:Blanco | Should -BeGreaterThan 0
        } finally { $logo.Dispose(); $p.Dispose() }
    }
    It 'sin -LogoYNombre pinta solo el logo, centrado' {
        $logo = New-BitmapPrueba 256 256 -EsquinasTransparentes
        $p = New-CaratulaCompuesta -Logo $logo -Ancho 600 -Alto 900 -Texto 'Nombre de prueba'
        try {
            Get-Pixeles $p 0 900 $script:Blanco | Should -Be 0
            Get-Pixeles $p 640 900 $script:Rojo | Should -Be 0
        } finally { $logo.Dispose(); $p.Dispose() }
    }
    It 'con -LogoYNombre la cápsula lleva el icono a la izquierda y el nombre a la derecha' {
        $logo = New-BitmapPrueba 256 256 -EsquinasTransparentes
        $c = New-CaratulaCompuesta -Logo $logo -Ancho 460 -Alto 215 -Texto 'Nombre de prueba' -LogoYNombre
        try {
            $izq = $c.Clone((New-Object System.Drawing.Rectangle(0, 0, 160, 215)), $c.PixelFormat)
            $der = $c.Clone((New-Object System.Drawing.Rectangle(170, 0, 290, 215)), $c.PixelFormat)
            Get-Pixeles $izq 0 215 $script:Rojo | Should -BeGreaterThan 0
            Get-Pixeles $der 0 215 $script:Rojo | Should -Be 0
            Get-Pixeles $der 0 215 $script:Blanco | Should -BeGreaterThan 0
        } finally { $logo.Dispose(); $c.Dispose(); $izq.Dispose(); $der.Dispose() }
    }
    It 'un nombre larguísimo sin logo no se sale por abajo' {
        $texto = (1..12 | ForEach-Object { 'Palabra' }) -join ' '
        $p = New-CaratulaCompuesta -Ancho 600 -Alto 900 -Texto $texto
        try {
            Get-Pixeles $p 0 900 $script:Blanco | Should -BeGreaterThan 0
            Get-Pixeles $p 0 8 $script:Blanco | Should -Be 0
            Get-Pixeles $p 892 900 $script:Blanco | Should -Be 0
        } finally { $p.Dispose() }
    }
}

Describe 'Get-BitmapDesdeIco' {
    BeforeAll {
        # .ico con varios fotogramas PNG en el orden que se pida: cabecera, una entrada de 16
        # bytes por imagen (0 de lado = 256) y detras los PNG seguidos
        function New-IcoVarios([string]$ruta, [int[]]$lados) {
            $pngs = @(foreach ($lado in $lados) {
                $bm = New-BitmapPrueba $lado $lado -EsquinasTransparentes
                $ms = New-Object System.IO.MemoryStream
                try { $bm.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png) } finally { $bm.Dispose() }
                ,$ms.ToArray()
            })
            $bytes = New-Object System.Collections.Generic.List[byte]
            $bytes.AddRange([byte[]](0, 0, 1, 0)); $bytes.AddRange([BitConverter]::GetBytes([uint16]$lados.Count))
            $pos = 6 + 16 * $lados.Count
            for ($i = 0; $i -lt $lados.Count; $i++) {
                $l = [byte]($lados[$i] % 256)
                $bytes.AddRange([byte[]]($l, $l, 0, 0, 1, 0, 32, 0))
                $bytes.AddRange([BitConverter]::GetBytes([uint32]$pngs[$i].Length))
                $bytes.AddRange([BitConverter]::GetBytes([uint32]$pos))
                $pos += $pngs[$i].Length
            }
            foreach ($p in $pngs) { $bytes.AddRange([byte[]]$p) }
            [IO.File]::WriteAllBytes($ruta, $bytes.ToArray())
        }
    }

    It 'se queda con el fotograma más grande aunque no sea el primero (<Lados>)' -ForEach @(
        @{ Lados = @(16, 256, 32) }
        @{ Lados = @(256, 48, 32, 16) }     # el orden de los de GOG
        @{ Lados = @(16, 32, 48) }
    ) {
        $ico = Join-Path $TestDrive 'varios.ico'
        New-IcoVarios $ico $Lados
        $bm = Get-BitmapDesdeArchivo -Ruta $ico
        try { $bm.Width | Should -Be ($Lados | Measure-Object -Maximum).Maximum }
        finally { if ($bm) { $bm.Dispose() } }
    }

    It 'lee un fotograma BMP (el que escribe Icon.Save)' {
        $bm = New-BitmapPrueba 48 48
        $hicon = $bm.GetHicon()
        $icono = [System.Drawing.Icon]::FromHandle($hicon)
        $ms = New-Object System.IO.MemoryStream
        $icono.Save($ms)
        $icono.Dispose(); $bm.Dispose()
        $bytes = $ms.ToArray()
        $bytes[$bytes[18] + 256 * $bytes[19]] | Should -Not -Be 0x89     # de verdad no es PNG
        $r = Get-BitmapDesdeIco -Bytes $bytes
        try { $r.Width | Should -Be 48 } finally { if ($r) { $r.Dispose() } }
    }

    It 'devuelve $null con lo que no es un .ico, o con el índice roto' {
        Get-BitmapDesdeIco -Bytes ([byte[]](1..40)) | Should -BeNullOrEmpty
        # dice que la imagen esta mas alla del final del fichero
        $roto = [byte[]](0, 0, 1, 0, 1, 0, 32, 32, 0, 0, 1, 0, 32, 0, 100, 0, 0, 0, 22, 0, 0, 0) + [byte[]](1..10)
        Get-BitmapDesdeIco -Bytes $roto | Should -BeNullOrEmpty
    }
}

Describe 'Get-AssetsLocales con un .ico' {
    BeforeAll {
        # Un .ico de una sola imagen en PNG, montado a mano: cabecera (6 bytes), una entrada
        # del directorio (16) y el PNG detras. En la entrada, 0 de ancho/alto significa 256.
        function New-IcoPrueba([string]$ruta, [int]$lado) {
            $bm = New-BitmapPrueba $lado $lado -EsquinasTransparentes
            $ms = New-Object System.IO.MemoryStream
            try { $bm.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png) } finally { $bm.Dispose() }
            $png = $ms.ToArray()
            $l = [byte]($lado % 256)
            $cab = [byte[]](0, 0, 1, 0, 1, 0, $l, $l, 0, 0, 1, 0, 32, 0) +
                   [BitConverter]::GetBytes([uint32]$png.Length) + [BitConverter]::GetBytes([uint32]22)
            [IO.File]::WriteAllBytes($ruta, [byte[]]($cab + $png))
        }
    }

    It 'un .ico de 256 vale de logo y de icono' {
        $ico = Join-Path $TestDrive 'grande.ico'
        New-IcoPrueba $ico 256
        $r = Get-AssetsLocales -Carpeta '' -Icono $ico
        try {
            $r.Logo.Width | Should -Be 256
            $r.LogoDelExe | Should -BeFalse
        } finally { if ($r.Logo) { $r.Logo.Dispose() } }
    }
    It 'un .ico de 32 se trata como el icono de un exe' {
        $ico = Join-Path $TestDrive 'pequeno.ico'
        New-IcoPrueba $ico 32
        $r = Get-AssetsLocales -Carpeta '' -Icono $ico
        try {
            $r.Logo.Width | Should -Be 32
            $r.LogoDelExe | Should -BeTrue
        } finally { if ($r.Logo) { $r.Logo.Dispose() } }
    }
}

Describe 'Get-SgdbAlternativas' {
    BeforeAll {
        Mock Invoke-RestMethod {
            [pscustomobject]@{ data = @(
                [pscustomobject]@{ url = 'https://cdn/a.png'; thumb = 'https://cdn/thumb/a.jpg'; width = 600; height = 900; author = [pscustomobject]@{ name = 'Jinx' } }
                [pscustomobject]@{ url = ''; thumb = 'https://cdn/thumb/x.jpg' }                  # sin imagen: fuera
                [pscustomobject]@{ url = 'https://cdn/b.png'; thumb = $null; width = 600; height = 900; author = $null }
            ) }
        }
    }

    It 'pide a <Ranura> lo que toca: <Esperada>' -ForEach @(
        @{ Ranura = 'p';    Esperada = 'grids/game/1915?dimensions=600x900&mimes=image/png,image/jpeg&types=static' }
        @{ Ranura = 'cap';  Esperada = 'grids/game/1915?dimensions=460x215,920x430&mimes=image/png,image/jpeg&types=static' }
        @{ Ranura = 'hero'; Esperada = 'heroes/game/1915?mimes=image/png,image/jpeg&types=static' }
        @{ Ranura = 'logo'; Esperada = 'logos/game/1915?mimes=image/png&types=static' }
    ) {
        [void](Get-SgdbAlternativas -Id '1915' -Ranura $Ranura -Cabeceras @{})
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -eq "https://www.steamgriddb.com/api/v2/$Esperada" }
    }

    It 'devuelve las que tienen imagen, con su autor y su miniatura (o la imagen si no la hay)' {
        $r = @(Get-SgdbAlternativas -Id '1' -Ranura 'p' -Cabeceras @{})
        $r.Count | Should -Be 2
        $r[0].Origen | Should -Be 'SteamGridDB'
        $r[0].Detalle | Should -Be 'Jinx'
        $r[0].Miniatura | Should -Be 'https://cdn/thumb/a.jpg'
        $r[0].Ancho | Should -Be 600
        $r[1].Detalle | Should -Be ''
        $r[1].Miniatura | Should -Be 'https://cdn/b.png'
    }
}

Describe 'Get-StoreAlternativas' {
    BeforeAll {
        # dos idiomas con el mismo poster: tiene que salir una vez
        function New-Img($p, $u, $w, $h) { [pscustomobject]@{ ImagePurpose = $p; Uri = $u; Width = $w; Height = $h } }
        $producto = [pscustomobject]@{ LocalizedProperties = @(
            [pscustomobject]@{ Images = @(
                (New-Img 'BoxArt' '//img/box' 1080 1080)
                (New-Img 'Poster' '//img/poster' 720 1080)
                (New-Img 'SuperHeroArt' '//img/hero' 1920 1080)
                (New-Img 'Logo' '//img/logo' 300 300)
            ) }
            [pscustomobject]@{ Images = @( (New-Img 'Poster' '//img/poster' 720 1080) ) }
        ) }
    }

    It 'portada: primero el Poster y luego el BoxArt, sin repetir, con https y miniatura reducida' {
        $r = @(Get-StoreAlternativas -Ranura 'p' -Producto $producto)
        $r.Detalle | Should -Be @('Poster', 'BoxArt')
        $r[0].Url | Should -Be 'https://img/poster'
        $r[0].Miniatura | Should -Be 'https://img/poster?w=240'
        $r[0].Origen | Should -Be 'Microsoft Store'
    }
    It 'cabecera: el SuperHeroArt, con la miniatura más ancha' {
        $r = @(Get-StoreAlternativas -Ranura 'hero' -Producto $producto)
        $r.Detalle | Should -Be @('SuperHeroArt')
        $r[0].Miniatura | Should -Be 'https://img/hero?w=480'
    }
    It 'logo: nada (la baldosa de la Store no vale de logo)' {
        @(Get-StoreAlternativas -Ranura 'logo' -Producto $producto).Count | Should -Be 0
    }
    It 'sin StoreId ni ficha: nada, sin preguntar a la red' {
        Mock Invoke-RestMethod { throw 'no deberia llamarse' }
        @(Get-StoreAlternativas -Ranura 'p' -StoreId '').Count | Should -Be 0
    }
}

Describe 'Get-Alternativas' {
    BeforeAll {
        Mock Get-StoreAlternativas { @((New-Alternativa -Origen 'Microsoft Store' -Detalle 'Poster' -Url 'https://s/1')) }
        Mock Get-SgdbAlternativas { @((New-Alternativa -Origen 'SteamGridDB' -Url "https://g/$Id")) }
        Mock Find-SgdbId { '77' }
    }

    It 'primero la Store y luego SteamGridDB, y devuelve el id que ha encontrado' {
        Mock Get-SgdbClave { 'clave' }
        $r = Get-Alternativas -Ranura 'p' -Nombre 'Juego' -StoreId '9ABC'
        @($r.Lista).Origen | Should -Be @('Microsoft Store', 'SteamGridDB')
        $r.Lista[1].Url | Should -Be 'https://g/77'
        $r.SgdbId | Should -Be '77'
    }
    It 'con el id ya sabido no vuelve a buscar el juego' {
        Mock Get-SgdbClave { 'clave' }
        $r = Get-Alternativas -Ranura 'hero' -Nombre 'Juego' -SgdbId '5'
        Should -Invoke Find-SgdbId -Times 0 -Exactly
        $r.Lista[0].Url | Should -Be 'https://g/5'
    }
    It 'sin clave de SteamGridDB, solo la Store, y lo dice' {
        Mock Get-SgdbClave { $null }
        $lineas = New-Object System.Collections.ArrayList
        $r = Get-Alternativas -Ranura 'p' -Nombre 'Juego' -StoreId '9ABC' -Log { param($m) [void]$lineas.Add($m) }
        @($r.Lista).Count | Should -Be 1
        ($lineas -join ' ') | Should -Match 'sin clave'
    }
    It 'si SteamGridDB falla, se queda con lo de la Store y no lanza' {
        Mock Get-SgdbClave { 'clave' }
        Mock Get-SgdbAlternativas { throw 'sin red' }
        $r = Get-Alternativas -Ranura 'p' -Nombre 'Juego' -StoreId '9ABC'
        @($r.Lista).Origen | Should -Be @('Microsoft Store')
    }
}

Describe 'Set-CaratulaRanura' {
    BeforeAll {
        $grid = Join-Path $TestDrive 'grid'
        $null = New-Item -ItemType Directory -Path $grid -Force
        # imagen de origen apaisada, para ver que se recorta a la medida del hueco
        $origen = Join-Path $TestDrive 'origen.png'
        $bm = New-BitmapPrueba 1000 500
        $bm.Save($origen, [System.Drawing.Imaging.ImageFormat]::Png); $bm.Dispose()
        function Get-Medidas([string]$ruta) {
            $b = Get-BitmapDesdeArchivo -Ruta $ruta
            try { "$($b.Width)x$($b.Height)" } finally { $b.Dispose() }
        }
    }
    BeforeEach { Get-ChildItem -LiteralPath $grid | Remove-Item -Force }

    It '<Ranura>: <Fichero> a <Medidas>' -ForEach @(
        @{ Ranura = 'p';    Fichero = '42p.png';      Medidas = '600x900' }
        @{ Ranura = 'cap';  Fichero = '42.png';       Medidas = '460x215' }
        @{ Ranura = 'hero'; Fichero = '42_hero.png';  Medidas = '1920x620' }
        @{ Ranura = 'logo'; Fichero = '42_logo.png';  Medidas = '1000x500' }   # el logo, tal cual
    ) {
        $r = Set-CaratulaRanura -Ranura $Ranura -Origen $origen -GridDir $grid -AppId 42
        $r.Ruta | Should -Be (Join-Path $grid $Fichero)
        Get-Medidas $r.Ruta | Should -Be $Medidas
    }

    It 'con el icono de <IconoDe>, elegir <Ranura> rehace el icono: <Rehace>' -ForEach @(
        @{ IconoDe = '';     Ranura = 'cap';  Rehace = $true;  Queda = 'cap' }
        @{ IconoDe = '';     Ranura = 'hero'; Rehace = $false; Queda = '' }
        @{ IconoDe = 'cap';  Ranura = 'p';    Rehace = $true;  Queda = 'p' }
        @{ IconoDe = 'p';    Ranura = 'p';    Rehace = $true;  Queda = 'p' }
        @{ IconoDe = 'p';    Ranura = 'cap';  Rehace = $false; Queda = 'p' }
        @{ IconoDe = 'p';    Ranura = 'logo'; Rehace = $true;  Queda = 'logo' }
        @{ IconoDe = 'logo'; Ranura = 'p';    Rehace = $false; Queda = 'logo' }
    ) {
        $r = Set-CaratulaRanura -Ranura $Ranura -Origen $origen -GridDir $grid -AppId 42 -IconoDe $IconoDe
        $r.IconoDe | Should -Be $Queda
        $icono = Join-Path $grid '42_icon.png'
        if ($Rehace) {
            $r.Icono | Should -Be $icono
            Get-Medidas $icono | Should -Be '256x256'
        } else {
            $r.Icono | Should -Be ''
            Test-Path -LiteralPath $icono | Should -BeFalse
        }
    }

    It 'una URL que devuelve la imagen vacía (como la portada rota de SteamGridDB) lanza diciéndolo' {
        $vacio = Join-Path $TestDrive 'vacio.png'
        [IO.File]::WriteAllBytes($vacio, [byte[]]@())
        { Get-BytesDesdeUrl ([Uri]$vacio).AbsoluteUri } | Should -Throw '*vacía*'
        { Get-BytesDesdeUrl ([Uri](Join-Path $TestDrive 'no-existe.png')).AbsoluteUri } | Should -Throw '*No he podido descargar*'
        (Get-BytesDesdeUrl ([Uri]$origen).AbsoluteUri).Length | Should -Be (Get-Item -LiteralPath $origen).Length
    }

    It 'lanza si la imagen no se puede leer, sin dejar nada a medias' {
        $malo = Join-Path $TestDrive 'malo.png'
        [IO.File]::WriteAllBytes($malo, [byte[]](1, 2, 3))
        { Set-CaratulaRanura -Ranura 'p' -Origen $malo -GridDir $grid -AppId 42 } | Should -Throw
        @(Get-ChildItem -LiteralPath $grid).Count | Should -Be 0
    }
}