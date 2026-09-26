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

Describe 'Get-IconoUbisoft' {
    BeforeAll {
        $base  = 'HKCU:\Software\VaporeraArcadeTests\' + [guid]::NewGuid().ToString() + '\Uninstall'
        $base2 = $base + '2'
        $null = New-Item -Path $base -Force
        $null = New-Item -Path $base2 -Force
        function Set-Clave([string]$raiz, [string]$id, $icono) {
            $k = New-Item -Path (Join-Path $raiz "Uplay Install $id") -Force
            if ($null -ne $icono) { $null = New-ItemProperty -LiteralPath $k.PSPath -Name DisplayIcon -Value $icono }
        }
        # los ficheros solo tienen que existir: aqui no se leen
        $data = Join-Path $TestDrive 'Ubisoft Game Launcher\data'
        $ico = Join-Path $data 'abc123.ico'
        $exe = Join-Path $TestDrive 'Juego [x]\Juego.exe'
        $dll = Join-Path $data 'iconos.dll'
        foreach ($f in $ico, $exe, $dll) {
            $null = [IO.Directory]::CreateDirectory((Split-Path $f -Parent))
            [IO.File]::WriteAllBytes($f, [byte[]]@())
        }
        Set-Clave $base '1' ($ico -replace '\\', '/')             # como lo escribe el lanzador
        Set-Clave $base '2' ('"' + $exe + '",0')
        Set-Clave $base '3' (Join-Path $data 'no-existe.ico')
        Set-Clave $base '4' ($dll + ',-101')
        Set-Clave $base '5' ''
        Set-Clave $base '6' $null
        Set-Clave $base2 '7' $ico
    }
    AfterAll {
        Remove-Item -Path 'HKCU:\Software\VaporeraArcadeTests' -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'pasa la ruta con / a \' {
        Get-IconoUbisoft -Id '1' -Bases @($base, $base2) | Should -BeExactly $ico
    }
    It 'quita las comillas y el índice de un exe (con [ ] en la ruta)' {
        Get-IconoUbisoft -Id '2' -Bases @($base, $base2) | Should -BeExactly $exe
    }
    It 'lo encuentra en la segunda base' {
        Get-IconoUbisoft -Id '7' -Bases @($base, $base2) | Should -BeExactly $ico
    }
    It 'id <Id> (<Caso>): $null, para caer al exe más grande' -ForEach @(
        @{ Id = '3'; Caso = 'el fichero no existe' }
        @{ Id = '4'; Caso = 'ni .ico ni .exe' }
        @{ Id = '5'; Caso = 'DisplayIcon vacío' }
        @{ Id = '6'; Caso = 'sin DisplayIcon' }
        @{ Id = '8'; Caso = 'sin clave' }
    ) {
        Get-IconoUbisoft -Id $Id -Bases @($base, $base2) | Should -BeNullOrEmpty
    }
}

Describe 'Get-JuegosGog' {
    # Claves como las que deja GOG Galaxy (copiadas de Beneath a Steel Sky, Champions of Krynn
    # y Cat Quest II), apuntando a ficheros vacios en TestDrive: aqui solo tienen que existir
    BeforeAll {
        $base = 'HKCU:\Software\VaporeraArcadeTests\' + [guid]::NewGuid().ToString() + '\Games'
        $null = New-Item -Path $base -Force
        function Set-JuegoGog([string]$id, [hashtable]$v) {
            $k = New-Item -Path (Join-Path $base $id) -Force
            foreach ($n in $v.Keys) { $null = New-ItemProperty -LiteralPath $k.PSPath -Name $n -Value $v[$n] }
        }
        function New-Vacio([string]$ruta) {
            $null = [IO.Directory]::CreateDirectory((Split-Path $ruta -Parent))
            [IO.File]::WriteAllBytes($ruta, [byte[]]@())
        }
        $bass = Join-Path $TestDrive 'Beneath a Steel Sky'
        New-Vacio (Join-Path $bass 'ScummVM\scummvm.exe')
        New-Vacio (Join-Path $bass 'goggame-1207658695.ico')
        Set-JuegoGog '1207658695' @{ gameName = 'Beneath a Steel Sky'; path = $bass
            exe = (Join-Path $bass 'ScummVM\scummvm.exe'); workingDir = (Join-Path $bass 'ScummVM')
            launchParam = '-c "..\beneath.ini" beneath' }

        $krynn = Join-Path $TestDrive 'Champions of Krynn'
        New-Vacio (Join-Path $krynn 'DOSBOX\dosbox.exe')
        New-Vacio (Join-Path $krynn 'goggame-1432722131.ico')
        Set-JuegoGog '1432722131' @{ gameName = 'Champions of Krynn'; path = $krynn
            exe = (Join-Path $krynn 'DOSBOX\dosbox.exe'); workingDir = (Join-Path $krynn 'DOSBOX')
            launchParam = '-conf "..\dosboxChampionsOfKrynn.conf" -conf "..\dosboxChampionsOfKrynn_single.conf" -noconsole -c "exit" ' }

        # sin su .ico, sin workingDir y con el exe relativo a la carpeta
        $gato = Join-Path $TestDrive 'Cat Quest II'
        New-Vacio (Join-Path $gato 'Cat Quest II.exe')
        Set-JuegoGog '1958338581' @{ gameName = 'Cat Quest II'; path = $gato; exe = 'Cat Quest II.exe'; launchParam = '' }

        # un juego desinstalado a medias: el exe ya no esta
        Set-JuegoGog '1' @{ gameName = 'Borrado'; path = (Join-Path $TestDrive 'Borrado'); exe = (Join-Path $TestDrive 'Borrado\x.exe') }

        $juegos = @(Get-JuegosGog -Bases @($base))
        function Get-Juego([string]$nombre) { $juegos | Where-Object Nombre -eq $nombre | Select-Object -First 1 }
    }
    AfterAll {
        Remove-Item -Path 'HKCU:\Software\VaporeraArcadeTests' -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'deja fuera el que ya no tiene exe' {
        $juegos.Count | Should -Be 3
        Get-Juego 'Borrado' | Should -BeNullOrEmpty
    }
    It 'ScummVM: exe, argumentos tal cual y carpeta de trabajo del registro' {
        $j = Get-Juego 'Beneath a Steel Sky'
        $j.Exe | Should -BeExactly (Join-Path $bass 'ScummVM\scummvm.exe')
        $j.LaunchOptions | Should -BeExactly '-c "..\beneath.ini" beneath'
        $j.StartDir | Should -BeExactly ((Join-Path $bass 'ScummVM') + '\')
        $j.Detalle | Should -Match 'ScummVM'
    }
    It 'DOSBox: argumentos sin el espacio del final' {
        $j = Get-Juego 'Champions of Krynn'
        $j.LaunchOptions | Should -BeExactly '-conf "..\dosboxChampionsOfKrynn.conf" -conf "..\dosboxChampionsOfKrynn_single.conf" -noconsole -c "exit"'
        $j.Detalle | Should -Match 'DOSBox'
    }
    It 'el icono es el goggame-<id>.ico del juego, no el del emulador' -ForEach @(
        @{ Nombre = 'Beneath a Steel Sky'; Ico = 'goggame-1207658695.ico' }
        @{ Nombre = 'Champions of Krynn';  Ico = 'goggame-1432722131.ico' }
    ) {
        (Get-Juego $Nombre).Icono | Should -BeExactly (Join-Path (Get-Juego $Nombre).Carpeta $Ico)
    }
    It 'sin .ico propio, el icono es el exe; sin workingDir, la carpeta del exe' {
        $j = Get-Juego 'Cat Quest II'
        $j.Exe | Should -BeExactly (Join-Path $gato 'Cat Quest II.exe')
        $j.Icono | Should -BeExactly $j.Exe
        $j.StartDir | Should -BeExactly ($gato + '\')
        $j.LaunchOptions | Should -BeExactly ''
        $j.Detalle | Should -Be 'Ejecutable directo del juego'
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
