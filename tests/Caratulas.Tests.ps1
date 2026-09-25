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
