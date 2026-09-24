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
