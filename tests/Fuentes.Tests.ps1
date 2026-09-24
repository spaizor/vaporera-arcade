# =====================================================================
#  Tests de lib/Fuentes.ps1: lo que se puede probar sin juegos instalados (manifiestos de Epic,
#  .GamingRoot de Xbox, nombre de Ubisoft en el registro, logos de las apps de la Store).
#  El registro se prueba en una clave propia de HKCU que se borra al terminar.
#  Se lanzan con tests\Invoke-Tests.ps1 (Pester 5, Windows PowerShell 5.1)
# =====================================================================

BeforeAll {
    . (Join-Path $PSScriptRoot '..\lib\Fuentes.ps1')

    # .GamingRoot: 'RGBX' + un DWORD + la ruta en UTF-16LE terminada en nulo
    function New-GamingRoot([string]$carpeta, [string]$ruta) {
        $null = New-Item -ItemType Directory -Path $carpeta -Force
        $b = [Text.Encoding]::ASCII.GetBytes('RGBX') + [byte[]](1, 0, 0, 0) + [Text.Encoding]::Unicode.GetBytes($ruta + [char]0)
        [IO.File]::WriteAllBytes((Join-Path $carpeta '.GamingRoot'), [byte[]]$b)
    }

    # Los 24 primeros bytes de un PNG: firma, longitud y tipo del IHDR, ancho y alto. Es todo
    # lo que lee Get-AnchoPng.
    function New-CabeceraPng([string]$ruta, [int]$ancho) {
        $b = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13) + [Text.Encoding]::ASCII.GetBytes('IHDR')
        $dim = [BitConverter]::GetBytes([int]$ancho); [Array]::Reverse($dim)     # big-endian
        [IO.File]::WriteAllBytes($ruta, [byte[]]($b + $dim + $dim))
    }
}

Describe 'Test-EpicEsJuego' {
    It '<Caso>: <Esperado>' -ForEach @(
        @{ Caso = 'juego';                        Esperado = $true;  M = @{ AppName = 'a'; AppCategories = @('public', 'games', 'applications') } }
        @{ Caso = 'Unreal Engine';                Esperado = $false; M = @{ AppName = 'UE_5.4'; AppCategories = @('engines') } }
        @{ Caso = 'plugin';                       Esperado = $false; M = @{ AppName = 'p'; AppCategories = @('plugins', 'engine') } }
        @{ Caso = 'DLC de otro juego';            Esperado = $false; M = @{ AppName = 'dlc'; MainGameAppName = 'a'; AppCategories = @('games', 'addons') } }
        @{ Caso = 'MainGameAppName igual al suyo'; Esperado = $true; M = @{ AppName = 'a'; MainGameAppName = 'a'; AppCategories = @('games') } }
        @{ Caso = 'descarga a medias';            Esperado = $false; M = @{ AppName = 'a'; bIsIncompleteInstall = $true; AppCategories = @('games') } }
        @{ Caso = 'sin categorías (se deja pasar)'; Esperado = $true; M = @{ AppName = 'a' } }
    ) {
        Test-EpicEsJuego ([pscustomobject]$M) | Should -Be $Esperado
    }
}

Describe 'Get-RaizDeGamingRoot' {
    It 'resuelve una ruta relativa a la unidad' {
        $u = Join-Path $TestDrive 'relativa'
        New-GamingRoot $u 'XboxGames'
        Get-RaizDeGamingRoot -Unidad $u | Should -Be (Join-Path $u 'XboxGames')
    }
    It 'devuelve tal cual una ruta absoluta' {
        $u = Join-Path $TestDrive 'absoluta'
        New-GamingRoot $u 'D:\Juegos\Xbox'
        Get-RaizDeGamingRoot -Unidad $u | Should -Be 'D:\Juegos\Xbox'
    }
    It 'devuelve $null sin lanzar si <Caso>' -ForEach @(
        @{ Caso = 'la cabecera no es RGBX'; Bytes = [Text.Encoding]::ASCII.GetBytes('XXXX') + [byte[]](1, 0, 0, 0, 0x41, 0, 0, 0) }
        @{ Caso = 'el fichero está truncado'; Bytes = [Text.Encoding]::ASCII.GetBytes('RGBX') }
        @{ Caso = 'no hay ruta tras la cabecera'; Bytes = [Text.Encoding]::ASCII.GetBytes('RGBX') + [byte[]](1, 0, 0, 0, 0, 0) }
    ) {
        $u = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $u
        [IO.File]::WriteAllBytes((Join-Path $u '.GamingRoot'), [byte[]]$Bytes)
        Get-RaizDeGamingRoot -Unidad $u | Should -BeNullOrEmpty
    }
    It 'devuelve $null si no hay .GamingRoot' {
        Get-RaizDeGamingRoot -Unidad $TestDrive | Should -BeNullOrEmpty
    }
}

Describe 'Get-NombreUbisoft' {
    BeforeAll {
        $base  = 'HKCU:\Software\VaporeraArcadeTests\' + [guid]::NewGuid().ToString() + '\Uninstall'
        $base2 = $base + '2'
        $null = New-Item -Path $base -Force
        $null = New-Item -Path $base2 -Force
        function Set-Clave([string]$raiz, [string]$id, $nombre) {
            $k = New-Item -Path (Join-Path $raiz "Uplay Install $id") -Force
            if ($null -ne $nombre) { $null = New-ItemProperty -LiteralPath $k.PSPath -Name DisplayName -Value $nombre }
        }
        Set-Clave $base '1' "Assassin's Creed Valhalla"
        Set-Clave $base '2' ("Tom Clancy's Rainbow Six" + [char]0x00AE + ' Siege')
        Set-Clave $base '3' ('Far Cry' + [char]0x2122 + ' 6 ')
        Set-Clave $base '4' ''
        Set-Clave $base '5' ([string][char]0x2122)
        Set-Clave $base '6' $null
        Set-Clave $base2 '7' 'Rayman Legends'
    }
    AfterAll {
        Remove-Item -Path 'HKCU:\Software\VaporeraArcadeTests' -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'id <Id>: "<Esperado>"' -ForEach @(
        @{ Id = '1'; Esperado = "Assassin's Creed Valhalla" }
        @{ Id = '2'; Esperado = "Tom Clancy's Rainbow Six Siege" }
        @{ Id = '3'; Esperado = 'Far Cry 6' }
        @{ Id = '7'; Esperado = 'Rayman Legends' }          # solo en la segunda base
    ) {
        Get-NombreUbisoft -Id $Id -Bases @($base, $base2) | Should -BeExactly $Esperado
    }
    It 'id <Id> (<Caso>): $null, para caer al nombre de la carpeta' -ForEach @(
        @{ Id = '4'; Caso = 'nombre vacío' }
        @{ Id = '5'; Caso = 'solo un símbolo de marca' }
        @{ Id = '6'; Caso = 'sin DisplayName' }
        @{ Id = '8'; Caso = 'sin clave' }
    ) {
        Get-NombreUbisoft -Id $Id -Bases @($base, $base2) | Should -BeNullOrEmpty
    }
    It 'no lanza si la base no existe' {
        Get-NombreUbisoft -Id '1' -Bases @('HKCU:\Software\VaporeraArcadeTests\NoExiste') | Should -BeNullOrEmpty
    }
}

Describe 'Get-AnchoPng' {
    It 'lee el ancho de la cabecera' {
        $f = Join-Path $TestDrive 'ancho.png'
        New-CabeceraPng $f 1024
        Get-AnchoPng $f | Should -Be 1024
    }
    It 'da 0 si no es un PNG' {
        $f = Join-Path $TestDrive 'falso.png'
        Set-Content -LiteralPath $f -Value 'esto no es un png, pero es bastante largo'
        Get-AnchoPng $f | Should -Be 0
    }
    It 'da 0 si el fichero es demasiado corto o no existe' {
        $f = Join-Path $TestDrive 'corto.png'
        [IO.File]::WriteAllBytes($f, [byte[]](0x89, 0x50, 0x4E, 0x47))
        Get-AnchoPng $f | Should -Be 0
        Get-AnchoPng (Join-Path $TestDrive 'no-existe.png') | Should -Be 0
    }
}

Describe 'Get-VariantesLogo' {
    BeforeAll {
        $paquete = Join-Path $TestDrive 'paquete'
        $assets = Join-Path $paquete 'Assets'
        $null = New-Item -ItemType Directory -Path $assets -Force
        $anchos = [ordered]@{
            'Logo.png'                                   = 44
            'Logo.scale-200.png'                         = 300
            'Logo.targetsize-256_altform-unplated.png'   = 256
            'Logo.altform-unplated_targetsize-48.png'    = 48     # calificadores al reves
            'Logo.targetsize-256_altform-lightunplated.png' = 256 # para fondo claro: fuera
            'Logo.contrast-black_scale-200.png'          = 300    # alto contraste: fuera
            'LogoGrande.png'                             = 999    # otra imagen que empieza igual
        }
        foreach ($n in $anchos.Keys) { New-CabeceraPng (Join-Path $assets $n) $anchos[$n] }
        $v = @(Get-VariantesLogo -Carpeta $paquete -Relativa 'Assets\Logo.png')
        $nombres = @($v | ForEach-Object { Split-Path $_.Ruta -Leaf })
    }

    It 'encuentra el fichero tal cual y las variantes con calificadores, en cualquier orden' {
        $nombres | Should -Contain 'Logo.png'
        $nombres | Should -Contain 'Logo.scale-200.png'
        $nombres | Should -Contain 'Logo.targetsize-256_altform-unplated.png'
        $nombres | Should -Contain 'Logo.altform-unplated_targetsize-48.png'
        $nombres.Count | Should -Be 4
    }
    It 'deja fuera las de alto contraste, las lightunplated y otras imágenes con el mismo principio' {
        $nombres | Should -Not -Contain 'Logo.targetsize-256_altform-lightunplated.png'
        $nombres | Should -Not -Contain 'Logo.contrast-black_scale-200.png'
        $nombres | Should -Not -Contain 'LogoGrande.png'
    }
    It 'anota el ancho y si es la variante sin placa' {
        $u = $v | Where-Object { $_.Ruta -like '*targetsize-256_altform-unplated.png' }
        $u.Ancho | Should -Be 256
        $u.SinPlaca | Should -BeTrue
        ($v | Where-Object { $_.Ruta -like '*scale-200.png' }).SinPlaca | Should -BeFalse
    }
    It 'devuelve vacío si la carpeta no existe o no hay ruta' {
        @(Get-VariantesLogo -Carpeta $paquete -Relativa 'NoExiste\Logo.png').Count | Should -Be 0
        @(Get-VariantesLogo -Carpeta $paquete -Relativa '').Count | Should -Be 0
    }
}

Describe 'Get-LogoAppStore con AUMID que no valen' {
    It 'devuelve vacío sin lanzar con "<Aumid>"' -ForEach @(
        @{ Aumid = '' }
        @{ Aumid = 'SinExclamacion' }
        @{ Aumid = 'NoExiste.Paquete_abc123!App' }
        @{ Aumid = 'Nombre[raro]_x!App' }
    ) {
        Get-LogoAppStore -Aumid $Aumid | Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-Rot13' {
    It 'descifra las rutas de UserAssist' {
        ConvertFrom-Rot13 'P:\Cebtenz Svyrf\Whrtb.rkr' | Should -BeExactly 'C:\Program Files\Juego.exe'
    }
}
