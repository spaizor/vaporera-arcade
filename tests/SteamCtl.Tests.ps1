# =====================================================================
#  Tests de lib/SteamCtl.ps1: duplicados, anadir, reemplazar y quitar accesos directos, y la
#  limpieza de caratulas huerfanas. Todo sobre ficheros de $TestDrive: no toca Steam.
#  Se lanzan con tests\Invoke-Tests.ps1 (Pester 5, Windows PowerShell 5.1)
# =====================================================================

BeforeAll {
    . (Join-Path $PSScriptRoot '..\lib\Vdf.ps1')
    . (Join-Path $PSScriptRoot '..\lib\SteamCtl.ps1')

    $script:Ubi = 'C:\Program Files (x86)\Ubisoft\Ubisoft Game Launcher\UbisoftConnect.exe'
    # appid de referencia calculados con zlib.crc32 de Python (ver Vdf.Tests.ps1)
    $script:IdMiJuego = [uint32]2564720459
    $script:IdRayman  = [uint32]3942880765

    # Un shortcuts.vdf nuevo con dos entradas: un juego suelto y uno de Ubisoft
    function New-VdfConDos([string]$ruta) {
        Remove-Item -LiteralPath $ruta -ErrorAction SilentlyContinue
        $null = Add-SteamShortcut -RutaVdf $ruta -Nombre 'Mi Juego' -Exe 'C:\Juegos\Juego.exe' -StartDir 'C:\Juegos\'
        $null = Add-SteamShortcut -RutaVdf $ruta -Nombre 'Rayman Origins' -Exe $script:Ubi `
                    -StartDir 'C:\Program Files (x86)\Ubisoft\Ubisoft Game Launcher\' -LaunchOptions 'uplay://launch/80/0'
    }
    function Get-Hash([string]$ruta) { (Get-FileHash -LiteralPath $ruta -Algorithm SHA256).Hash }
}

Describe 'Find-ShortcutDuplicado' {
    BeforeAll {
        $existentes = @(
            [pscustomobject]@{ Indice = '0'; Nombre = 'Rayman Origins'; Exe = $script:Ubi; LaunchOptions = 'uplay://launch/80/0' }
            [pscustomobject]@{ Indice = '1'; Nombre = 'Mi Juego'; Exe = 'C:\Juegos\Juego.exe'; LaunchOptions = '' }
        )
    }

    It 'choca por el nombre aunque el exe sea otro' {
        Find-ShortcutDuplicado -Existentes $existentes -Nombre 'Mi Juego' -Exe 'C:\Otro.exe' | Should -Be '1'
    }
    It 'choca por el exe con las mismas opciones aunque el nombre sea otro' {
        Find-ShortcutDuplicado -Existentes $existentes -Nombre 'ACValhalla' -Exe $script:Ubi -LaunchOptions 'uplay://launch/80/0' | Should -Be '0'
    }
    It 'no choca con el mismo lanzador y otra URI (otro juego de Ubisoft)' {
        Find-ShortcutDuplicado -Existentes $existentes -Nombre 'Rayman Legends' -Exe $script:Ubi -LaunchOptions 'uplay://launch/410/0' | Should -BeNullOrEmpty
    }
    It 'choca por el exe cuando ninguno de los dos tiene opciones' {
        Find-ShortcutDuplicado -Existentes $existentes -Nombre 'Otro nombre' -Exe 'C:\Juegos\Juego.exe' | Should -Be '1'
    }
    It 'no choca si no comparten ni nombre ni exe' {
        Find-ShortcutDuplicado -Existentes $existentes -Nombre 'Nuevo' -Exe 'C:\Nuevo.exe' | Should -BeNullOrEmpty
    }
    It 'no falla con la lista vacía, con $null ni con huecos $null' {
        Find-ShortcutDuplicado -Existentes @() -Nombre 'Mi Juego' -Exe 'x' | Should -BeNullOrEmpty
        Find-ShortcutDuplicado -Existentes $null -Nombre 'Mi Juego' -Exe 'x' | Should -BeNullOrEmpty
        Find-ShortcutDuplicado -Existentes @($null, $existentes[1]) -Nombre 'Mi Juego' -Exe 'x' | Should -Be '1'
    }
}

Describe 'Add-SteamShortcut' {
    BeforeEach {
        $vdf = Join-Path $TestDrive 'shortcuts.vdf'
        New-VdfConDos $vdf
    }

    It 'crea el fichero si no existe, con la entrada completa' {
        $nuevo = Join-Path $TestDrive 'desde-cero.vdf'
        $r = Add-SteamShortcut -RutaVdf $nuevo -Nombre 'Mi Juego' -Exe 'C:\Juegos\Juego.exe' -StartDir 'C:\Juegos\'
        $r.Ok | Should -BeTrue
        $r.AppId | Should -Be $script:IdMiJuego
        $e = (Read-BinaryVdf -Path $nuevo)['shortcuts']['0']
        $e['appid'] | Should -Be -1730246837
        $e['Exe'] | Should -BeExactly '"C:\Juegos\Juego.exe"'
        $e['StartDir'] | Should -BeExactly '"C:\Juegos\"'
        $e['tags']['0'] | Should -BeExactly 'Installed locally'
    }
    It 'numera la siguiente entrada detrás de la última' {
        $r = Add-SteamShortcut -RutaVdf $vdf -Nombre 'Nuevo' -Exe 'C:\Nuevo.exe' -StartDir 'C:\'
        $r.Ok | Should -BeTrue
        @((Read-BinaryVdf -Path $vdf)['shortcuts'].Keys) | Should -Be @('0', '1', '2')
    }
    It 'no escribe nada si es un duplicado, y dice con qué choca' {
        $antes = Get-Hash $vdf
        $r = Add-SteamShortcut -RutaVdf $vdf -Nombre 'Mi Juego' -Exe 'C:\Otro.exe' -StartDir 'C:\'
        $r.Ok | Should -BeFalse
        $r.Motivo | Should -Be 'duplicado'
        $r.Indice | Should -Be '0'
        $r.AppIdAnterior | Should -Be $script:IdMiJuego
        Get-Hash $vdf | Should -Be $antes
    }
    It 'añade otro juego del mismo lanzador con otra URI' {
        $r = Add-SteamShortcut -RutaVdf $vdf -Nombre 'Rayman Legends' -Exe $script:Ubi -StartDir 'C:\' -LaunchOptions 'uplay://launch/410/0'
        $r.Ok | Should -BeTrue
        (Read-BinaryVdf -Path $vdf)['shortcuts'].Count | Should -Be 3
    }
    It 'al reemplazar con otro exe cambia el appid y devuelve el anterior' {
        $r = Add-SteamShortcut -RutaVdf $vdf -Nombre 'Mi Juego' -Exe 'C:\Juegos\Nuevo.exe' -StartDir 'C:\Juegos\' -Reemplazar
        $r.Ok | Should -BeTrue
        $r.Indice | Should -Be '0'
        $r.AppIdAnterior | Should -Be $script:IdMiJuego
        $r.AppId | Should -Not -Be $script:IdMiJuego
        $sc = (Read-BinaryVdf -Path $vdf)['shortcuts']
        $sc.Count | Should -Be 2
        $sc['0']['Exe'] | Should -BeExactly '"C:\Juegos\Nuevo.exe"'
    }
    It 'al reemplazar con lo mismo, el appid anterior es el mismo' {
        $r = Add-SteamShortcut -RutaVdf $vdf -Nombre 'Mi Juego' -Exe 'C:\Juegos\Juego.exe' -StartDir 'C:\Juegos\' -Reemplazar
        $r.AppIdAnterior | Should -Be $r.AppId
    }
    It 'no deja el .tmp de la escritura' {
        "$vdf.tmp" | Should -Not -Exist
    }
    It 'añadir y quitar deja el fichero idéntico byte a byte' {
        $antes = Get-Hash $vdf
        $r = Add-SteamShortcut -RutaVdf $vdf -Nombre 'De paso' -Exe 'C:\DePaso.exe' -StartDir 'C:\'
        $quitados = Remove-SteamShortcut -RutaVdf $vdf -Indice '2'
        $quitados | Should -Be $r.AppId
        Get-Hash $vdf | Should -Be $antes
    }
}

Describe 'Remove-SteamShortcut' {
    BeforeEach {
        $vdf = Join-Path $TestDrive 'shortcuts.vdf'
        New-VdfConDos $vdf
    }

    It 'quita por índice, devuelve su appid y renumera las demás' {
        $q = @(Remove-SteamShortcut -RutaVdf $vdf -Indice '0')
        $q | Should -Be @($script:IdMiJuego)
        $q[0] | Should -BeOfType [uint32]
        $sc = (Read-BinaryVdf -Path $vdf)['shortcuts']
        @($sc.Keys) | Should -Be @('0')
        $sc['0']['AppName'] | Should -BeExactly 'Rayman Origins'
    }
    It 'quita por nombre' {
        Remove-SteamShortcut -RutaVdf $vdf -Nombre 'Rayman Origins' | Should -Be $script:IdRayman
        (Read-BinaryVdf -Path $vdf)['shortcuts'].Count | Should -Be 1
    }
    It 'no toca el fichero si no hay nada que quitar' {
        $antes = Get-Hash $vdf
        Remove-SteamShortcut -RutaVdf $vdf -Nombre 'No existe' | Should -BeNullOrEmpty
        Get-Hash $vdf | Should -Be $antes
    }
    It 'no falla si el fichero no existe' {
        Remove-SteamShortcut -RutaVdf (Join-Path $TestDrive 'no-existe.vdf') -Nombre 'x' | Should -BeNullOrEmpty
    }
    It 'lanza si no se le dice qué quitar' {
        { Remove-SteamShortcut -RutaVdf $vdf } | Should -Throw
    }
}

Describe 'Remove-CaratulasHuerfanas' {
    BeforeEach {
        $vdf = Join-Path $TestDrive 'shortcuts.vdf'
        New-VdfConDos $vdf
        $grid = Join-Path $TestDrive 'grid'
        Remove-Item -LiteralPath $grid -Recurse -Force -ErrorAction SilentlyContinue
        $null = New-Item -ItemType Directory -Path $grid
        # un appid que no esta en el VDF, con todo lo que puede haber de el
        $huerfano = [uint32]3000000001
        $suyos = @("${huerfano}p.png", "${huerfano}.png", "${huerfano}_hero.jpg", "${huerfano}_logo.png",
                   "${huerfano}_icon.png", "${huerfano}.json")
        $enUso = @("$($script:IdMiJuego)p.png", "$($script:IdMiJuego)_hero.png")
        foreach ($f in ($suyos + $enUso + 'otro.png')) { Set-Content -LiteralPath (Join-Path $grid $f) -Value 'x' }
    }

    It 'borra las imágenes de un appid que ya no usa nadie, y solo esas' {
        Remove-CaratulasHuerfanas -RutaVdf $vdf -GridDir $grid -AppId $huerfano | Should -Be $suyos.Count
        foreach ($f in $suyos) { Join-Path $grid $f | Should -Not -Exist }
        foreach ($f in ($enUso + 'otro.png')) { Join-Path $grid $f | Should -Exist }
    }
    It 'no borra las de un appid que sigue en el VDF' {
        Remove-CaratulasHuerfanas -RutaVdf $vdf -GridDir $grid -AppId $script:IdMiJuego | Should -Be 0
        foreach ($f in $enUso) { Join-Path $grid $f | Should -Exist }
    }
    It 'no borra nada ni lanza si no puede leer el VDF' {
        [IO.File]::WriteAllBytes($vdf, [byte[]](5, 0x78, 0, 8))
        Remove-CaratulasHuerfanas -RutaVdf $vdf -GridDir $grid -AppId $huerfano | Should -Be 0
        foreach ($f in $suyos) { Join-Path $grid $f | Should -Exist }
    }
    It 'no hace nada con el appid 0' {
        Remove-CaratulasHuerfanas -RutaVdf $vdf -GridDir $grid -AppId 0 | Should -Be 0
    }
}
