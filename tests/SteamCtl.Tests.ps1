# =====================================================================
#  Tests de lib/SteamCtl.ps1: duplicados, anadir, reemplazar y quitar accesos directos, y la
#  limpieza de caratulas huerfanas, y la eleccion de instalacion y perfil de Get-SteamInfo.
#  Todo sobre ficheros de $TestDrive y con la sesion activa simulada: no toca Steam.
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

Describe 'Find-ShortcutParaQuitar' {
    BeforeAll {
        # dos del mismo nombre: la vieja (otro exe, que ya no arranca) va delante de la buena
        $existentes = @(
            [pscustomobject]@{ Indice = '0'; Nombre = 'Mi Juego'; Exe = 'C:\Viejo\Juego.exe'; LaunchOptions = '' }
            [pscustomobject]@{ Indice = '1'; Nombre = 'Mi Juego'; Exe = 'C:\Juegos\Juego.exe'; LaunchOptions = '' }
            [pscustomobject]@{ Indice = '2'; Nombre = 'Renombrado'; Exe = 'C:\Otro\Otro.exe'; LaunchOptions = '-x' }
        )
    }

    It 'prefiere la del nombre, exe y opciones a la primera del nombre' {
        Find-ShortcutParaQuitar -Existentes $existentes -Nombre 'Mi Juego' -Exe 'C:\Juegos\Juego.exe' | Should -Be '1'
        Find-ShortcutParaQuitar -Existentes $existentes -Nombre 'Mi Juego' -Exe 'C:\Viejo\Juego.exe' | Should -Be '0'
    }
    It 'luego la del exe y las opciones, aunque se llame distinto' {
        Find-ShortcutParaQuitar -Existentes $existentes -Nombre 'Otro' -Exe 'C:\Otro\Otro.exe' -LaunchOptions '-x' | Should -Be '2'
    }
    It 'y si no, la primera con su nombre' {
        Find-ShortcutParaQuitar -Existentes $existentes -Nombre 'Mi Juego' -Exe 'C:\Nuevo.exe' | Should -Be '0'
    }
    It 'sin ninguna que case, nada' {
        Find-ShortcutParaQuitar -Existentes $existentes -Nombre 'Nuevo' -Exe 'C:\Nuevo.exe' | Should -BeNullOrEmpty
        Find-ShortcutParaQuitar -Existentes $null -Nombre 'Nuevo' -Exe 'C:\Nuevo.exe' | Should -BeNullOrEmpty
    }
}

Describe 'Get-EstadoEnSteam' {
    BeforeAll {
        $existentes = @(
            [pscustomobject]@{ Indice = '0'; Nombre = 'Rayman Origins'; Exe = $script:Ubi; LaunchOptions = 'uplay://launch/80/0' }
            [pscustomobject]@{ Indice = '1'; Nombre = 'Mi Juego'; Exe = 'C:\Juegos\Juego.exe'; LaunchOptions = '-ventana' }
        )
    }

    It 'con su exe y sus opciones está en Steam, aunque allí se llame distinto' {
        $r = Get-EstadoEnSteam -Existentes $existentes -Nombre 'Rayman' -Exe $script:Ubi -LaunchOptions 'uplay://launch/80/0'
        $r.Estado | Should -Be 'en-steam'
        $r.Entrada.Indice | Should -Be '0'
    }
    It 'con su nombre y su exe también, aunque las opciones se editaran al añadirlo' {
        (Get-EstadoEnSteam -Existentes $existentes -Nombre 'Mi Juego' -Exe 'C:\Juegos\Juego.exe').Estado | Should -Be 'en-steam'
    }
    It 'con su nombre y otro exe está cambiado (las mayúsculas de la ruta no cuentan)' {
        $r = Get-EstadoEnSteam -Existentes $existentes -Nombre 'Mi Juego' -Exe 'D:\Juegos\Juego.exe'
        $r.Estado | Should -Be 'cambiado'
        $r.Entrada.Indice | Should -Be '1'
        (Get-EstadoEnSteam -Existentes $existentes -Nombre 'Mi Juego' -Exe 'c:\JUEGOS\juego.exe').Estado | Should -Be 'en-steam'
    }
    It 'otro juego del mismo lanzador no está en Steam' {
        $r = Get-EstadoEnSteam -Existentes $existentes -Nombre 'Rayman Legends' -Exe $script:Ubi -LaunchOptions 'uplay://launch/410/0'
        $r.Estado | Should -Be ''
        $r.Entrada | Should -BeNullOrEmpty
    }
    It 'casa con lo mismo que Find-ShortcutDuplicado: <Caso>' -ForEach @(
        @{ Caso = 'por exe';    Nombre = 'X';        Exe = 'C:\Juegos\Juego.exe'; Opc = '-ventana' }
        @{ Caso = 'por nombre'; Nombre = 'Mi Juego'; Exe = 'C:\otro.exe';         Opc = '' }
        @{ Caso = 'ninguno';    Nombre = 'Nuevo';    Exe = 'C:\nuevo.exe';        Opc = '' }
    ) {
        $estado = (Get-EstadoEnSteam -Existentes $existentes -Nombre $Nombre -Exe $Exe -LaunchOptions $Opc).Estado
        $dup = Find-ShortcutDuplicado -Existentes $existentes -Nombre $Nombre -Exe $Exe -LaunchOptions $Opc
        ($estado -ne '') | Should -Be ($null -ne $dup)
    }
}

Describe 'Get-EntradasSinJuego' {
    BeforeAll {
        $existentes = @(
            [pscustomobject]@{ Indice = '0'; Nombre = 'Rayman Origins'; Exe = $script:Ubi; LaunchOptions = 'uplay://launch/80/0' }
            [pscustomobject]@{ Indice = '1'; Nombre = 'Mi Juego'; Exe = 'C:\Viejo\Juego.exe'; LaunchOptions = '' }
            [pscustomobject]@{ Indice = '2'; Nombre = 'Mi Juego'; Exe = 'C:\Juegos\Juego.exe'; LaunchOptions = '' }
            [pscustomobject]@{ Indice = '3'; Nombre = 'Emulador'; Exe = 'C:\Emu\emu.exe'; LaunchOptions = '' }
            [pscustomobject]@{ Indice = '4'; Nombre = 'Vaporera Arcade'; Exe = 'C:\ps.exe'; LaunchOptions = '-File "C:\Vieja\v.ps1"' }
        )
        $juegos = @(
            [pscustomobject]@{ Nombre = 'Mi Juego'; Exe = 'C:\Juegos\Juego.exe'; LaunchOptions = '' }
            [pscustomobject]@{ Nombre = 'Otro'; Exe = 'C:\otro.exe'; LaunchOptions = '' }
        )
        $vaporera = [pscustomobject]@{ Nombre = 'Vaporera Arcade'; Exe = 'C:\ps.exe'; LaunchOptions = '-File "C:\Nueva\v.ps1"' }
    }

    It 'devuelve las que no le tocan a ningún juego, también la vieja del mismo nombre' {
        $r = @(Get-EntradasSinJuego -Existentes $existentes -Juegos $juegos -Excluir @($vaporera))
        $r.Indice | Should -Be @('0', '1', '3')
    }
    It 'la de un juego cambiado le toca a él y no sale' {
        $cambiado = [pscustomobject]@{ Nombre = 'Rayman Origins'; Exe = 'D:\Ubisoft\UbisoftConnect.exe'; LaunchOptions = 'uplay://launch/80/0' }
        $r = @(Get-EntradasSinJuego -Existentes $existentes -Juegos @($juegos + $cambiado) -Excluir @($vaporera))
        $r.Indice | Should -Be @('1', '3')
    }
    It 'lo excluido no sale aunque tenga otra ruta (casa por el nombre)' {
        $r = @(Get-EntradasSinJuego -Existentes $existentes -Juegos @() -Excluir @($vaporera))
        $r.Indice | Should -Not -Contain '4'
        @(Get-EntradasSinJuego -Existentes $existentes -Juegos @()).Count | Should -Be 5
    }
    It 'sin entradas, nada' {
        @(Get-EntradasSinJuego -Existentes @() -Juegos $juegos).Count | Should -Be 0
    }
}

Describe 'Test-EntradaNoInstalada' {
    BeforeAll {
        $raiz = [IO.Path]::GetPathRoot($TestDrive)
        $exe = Join-Path $TestDrive 'existe.exe'
        Set-Content -LiteralPath $exe -Value 'x'
        function New-Entrada([string]$e, [string]$o = '') { [pscustomobject]@{ Indice = '0'; Nombre = 'X'; Exe = $e; LaunchOptions = $o } }
    }

    It 'con el exe en su sitio sigue instalado' {
        Test-EntradaNoInstalada -Entrada (New-Entrada $exe) -Unidades @($raiz) | Should -BeFalse
    }
    It 'sin el exe ya no está' {
        Test-EntradaNoInstalada -Entrada (New-Entrada (Join-Path $TestDrive 'falta.exe')) -Unidades @($raiz) | Should -BeTrue
    }
    It 'por la URI de Ubisoft o de Epic ya no está, aunque el lanzador siga: <Uri>' -ForEach @(
        @{ Uri = 'uplay://launch/80/0' }
        @{ Uri = 'com.epicgames.launcher://apps/Juego?action=launch&silent=true' }
    ) {
        Test-EntradaNoInstalada -Entrada (New-Entrada $exe $Uri) -Unidades @($raiz) | Should -BeTrue
    }
    It 'fuera de las unidades fijas no se mira (una de red puede tardar): no se sabe' {
        Test-EntradaNoInstalada -Entrada (New-Entrada '\\servidor\juegos\falta.exe') -Unidades @($raiz) | Should -BeFalse
        Test-EntradaNoInstalada -Entrada (New-Entrada (Join-Path $TestDrive 'falta.exe')) -Unidades @() | Should -BeFalse
    }
    It 'una app de la Store (explorer y shell:AppsFolder) no se da por desinstalada' {
        $explorer = Join-Path $env:SystemRoot 'explorer.exe'
        Test-EntradaNoInstalada -Entrada (New-Entrada $explorer 'shell:AppsFolder\App!App') -Unidades @([IO.Path]::GetPathRoot($explorer)) | Should -BeFalse
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

Describe 'Invoke-CambiosShortcuts' {
    # Varios juegos con un solo reinicio de Steam: todo en memoria sobre lo leido del VDF
    BeforeAll {
        function New-Juego([string]$nombre, [string]$exe, [string]$opciones = '') {
            [pscustomobject]@{ Nombre = $nombre; Exe = $exe; StartDir = 'C:\Juegos\'; Icono = ''; LaunchOptions = $opciones }
        }
        $raymanDeLista = New-Juego 'Rayman Origins' $script:Ubi 'uplay://launch/80/0'
    }
    BeforeEach {
        $vdf = Join-Path $TestDrive 'shortcuts.vdf'
        New-VdfConDos $vdf
        $root = Read-BinaryVdf -Path $vdf
    }

    It 'quita varios de una vez, con sus appid, y renumera como Steam' {
        $r = @(Invoke-CambiosShortcuts -Root $root -Bajas @((New-Juego 'Mi Juego' 'C:\Juegos\Juego.exe'), $raymanDeLista))
        $r.Ok | Should -Be @($true, $true)
        $r[0].Quitados | Should -Be @($script:IdMiJuego)
        $r[1].Quitados | Should -Be @($script:IdRayman)
        $root['shortcuts'].Count | Should -Be 0
    }
    It 'una baja casa también por el exe, y dice el nombre que tenía en Steam' {
        $r = @(Invoke-CambiosShortcuts -Root $root -Bajas @(New-Juego 'ACValhalla' $script:Ubi 'uplay://launch/80/0'))
        $r[0].Ok | Should -BeTrue
        $r[0].NombreEnSteam | Should -BeExactly 'Rayman Origins'
        @($root['shortcuts'].Keys) | Should -Be @('0')
        $root['shortcuts']['0']['AppName'] | Should -BeExactly 'Mi Juego'
    }
    It 'la que no está se anota y no para a las demás; dos que casan con la misma entrada no quitan otra' {
        $r = @(Invoke-CambiosShortcuts -Root $root -Bajas @((New-Juego 'No existe' 'C:\x.exe'), $raymanDeLista, $raymanDeLista))
        $r.Motivo | Should -Be @('no-esta', '', 'no-esta')
        $root['shortcuts'].Count | Should -Be 1
    }
    It 'añade varios detrás de los que hay, cada uno con su appid y su clave' {
        $r = @(Invoke-CambiosShortcuts -Root $root -Altas @((New-Juego 'Uno' 'C:\uno.exe'), (New-Juego 'Dos' 'C:\dos.exe')))
        $r.Ok | Should -Be @($true, $true)
        $r.Clave | Should -Be @('2', '3')
        $r[0].AppId | Should -Be (Get-SteamShortcutAppId -ExeQuoted '"C:\uno.exe"' -AppName 'Uno')
        $root['shortcuts']['3']['AppName'] | Should -BeExactly 'Dos'
    }
    It 'sin reemplazar, el que ya está se salta y no cambia nada' {
        $r = @(Invoke-CambiosShortcuts -Root $root -Altas @($raymanDeLista))
        $r[0].Ok | Should -BeFalse
        $r[0].Motivo | Should -Be 'duplicado'
        $salida = Join-Path $TestDrive 'salida.vdf'
        Write-BinaryVdf -Root $root -Path $salida
        Get-Hash $salida | Should -Be (Get-Hash $vdf)
    }
    It 'dos elegidos iguales: el segundo es un repetido (por nombre o por exe)' {
        $r = @(Invoke-CambiosShortcuts -Root $root -Altas @((New-Juego 'Uno' 'C:\uno.exe'), (New-Juego 'Uno' 'C:\otro.exe'), (New-Juego 'Otro' 'C:\uno.exe')))
        $r.Motivo | Should -Be @('', 'repetido', 'repetido')
        $root['shortcuts'].Count | Should -Be 3
    }
    It 'al reemplazar con otro exe da el appid anterior, en la misma clave' {
        $r = @(Invoke-CambiosShortcuts -Root $root -Reemplazar -Altas @(New-Juego 'Mi Juego' 'C:\Juegos\Nuevo.exe'))
        $r[0].Ok | Should -BeTrue
        $r[0].Clave | Should -Be '0'
        $r[0].AppIdAnterior | Should -Be $script:IdMiJuego
        $root['shortcuts']['0']['Exe'] | Should -BeExactly '"C:\Juegos\Nuevo.exe"'
    }
    It 'un alta puede pedir que se reemplace solo ella (un juego que ha cambiado de exe)' {
        $cambiado = New-Juego 'Mi Juego' 'D:\Juegos\Juego.exe'
        $cambiado | Add-Member -NotePropertyName Reemplazar -NotePropertyValue $true
        $r = @(Invoke-CambiosShortcuts -Root $root -Altas @($cambiado, $raymanDeLista))
        $r.Ok | Should -Be @($true, $false)
        $r[1].Motivo | Should -Be 'duplicado'
        $r[0].AppIdAnterior | Should -Be $script:IdMiJuego
        $root['shortcuts']['0']['Exe'] | Should -BeExactly '"D:\Juegos\Juego.exe"'
        $root['shortcuts'].Count | Should -Be 2
    }
    It 'una baja quita la entrada exacta aunque haya otra del mismo nombre antes' {
        # una vieja de 'Mi Juego' con otro exe detrás de las dos
        [void](Invoke-CambiosShortcuts -Root $root -Altas @(New-Juego 'Viejo' 'C:\Viejo\Juego.exe'))
        $root['shortcuts']['2']['AppName'] = 'Mi Juego'
        $r = @(Invoke-CambiosShortcuts -Root $root -Bajas @(New-Juego 'Mi Juego' 'C:\Viejo\Juego.exe'))
        $r[0].Ok | Should -BeTrue
        @($root['shortcuts'].Keys) | Should -Be @('0', '1')
        $root['shortcuts']['0']['Exe'] | Should -BeExactly '"C:\Juegos\Juego.exe"'
    }
    It 'un alta que falla no para a las demás' {
        $r = @(Invoke-CambiosShortcuts -Root $root -Altas @((New-Juego '' 'C:\sin-nombre.exe'), (New-Juego 'Bueno' 'C:\bueno.exe')))
        $r[0].Ok | Should -BeFalse
        $r[0].Motivo | Should -Not -BeNullOrEmpty
        $r[1].Ok | Should -BeTrue
        $root['shortcuts']['2']['AppName'] | Should -BeExactly 'Bueno'
    }
    It 'bajas y altas en el mismo lote: primero las bajas' {
        $r = @(Invoke-CambiosShortcuts -Root $root -Bajas @(New-Juego 'Mi Juego' 'C:\Juegos\Juego.exe') -Altas @(New-Juego 'Nuevo' 'C:\nuevo.exe'))
        $r.Tipo | Should -Be @('Baja', 'Alta')
        @($root['shortcuts'].Keys) | Should -Be @('0', '1')
        $root['shortcuts']['1']['AppName'] | Should -BeExactly 'Nuevo'
    }
    It 'añadir dos y quitarlos después deja el fichero idéntico byte a byte' {
        $antes = Get-Hash $vdf
        $nuevos = @((New-Juego 'Uno' 'C:\uno.exe'), (New-Juego 'Dos' 'C:\dos.exe' '-x'))
        [void](Invoke-CambiosShortcuts -Root $root -Altas $nuevos)
        Write-BinaryVdf -Root $root -Path $vdf
        $root = Read-BinaryVdf -Path $vdf
        [void](Invoke-CambiosShortcuts -Root $root -Bajas $nuevos)
        Write-BinaryVdf -Root $root -Path $vdf
        Get-Hash $vdf | Should -Be $antes
    }
    It 'sin entradas (VDF nuevo) añade desde la 0' {
        $vacio = Read-ShortcutsOVacio -Ruta (Join-Path $TestDrive 'no-existe.vdf')
        $r = @(Invoke-CambiosShortcuts -Root $vacio -Altas @(New-Juego 'Uno' 'C:\uno.exe'))
        $r[0].Clave | Should -Be '0'
    }
    It 'sin nada que hacer no devuelve nada' {
        @(Invoke-CambiosShortcuts -Root $root).Count | Should -Be 0
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

Describe 'Get-SteamInfo' {
    BeforeAll {
        # Una instalacion de Steam de mentira en $TestDrive. Los perfiles se crean con su
        # localconfig.vdf y fechas crecientes: el ultimo de la lista es el mas reciente.
        function New-SteamFalso {
            param([string]$Carpeta, [string[]]$Perfiles = @(), [switch]$SinExe, [string]$LoginUsers = '')
            $raiz = Join-Path $TestDrive $Carpeta
            Remove-Item -LiteralPath $raiz -Recurse -Force -ErrorAction SilentlyContinue
            $null = New-Item -ItemType Directory -Path $raiz
            if (-not $SinExe) { Set-Content -LiteralPath (Join-Path $raiz 'steam.exe') -Value '' }
            $fecha = [datetime]'2026-01-01'
            foreach ($p in $Perfiles) {
                $cfg = Join-Path $raiz "userdata\$p\config"
                $null = New-Item -ItemType Directory -Path $cfg -Force
                $lc = Join-Path $cfg 'localconfig.vdf'
                Set-Content -LiteralPath $lc -Value 'x'
                (Get-Item -LiteralPath $lc).LastWriteTime = $fecha
                $fecha = $fecha.AddDays(1)
            }
            if ($LoginUsers) {
                $null = New-Item -ItemType Directory -Path (Join-Path $raiz 'config') -Force
                Set-Content -LiteralPath (Join-Path $raiz 'config\loginusers.vdf') -Value $LoginUsers -Encoding UTF8
            }
            return $raiz
        }
        # SteamID64 = 76561197960265728 + id de cuenta (el nombre de la carpeta de userdata)
        $script:Id64De111 = '76561197960265839'
        $script:Id64De222 = '76561197960265950'
    }
    # Sin sesion iniciada salvo que el It diga otra cosa: la de verdad de este PC no debe contar
    BeforeEach {
        Mock Get-ItemProperty { throw 'no hay sesión' } -ParameterFilter { $Path -like '*\ActiveProcess' }
    }

    It 'sin steam.exe devuelve $null y el motivo lo dice' {
        $d = New-SteamFalso -Carpeta 'sinexe' -Perfiles '111' -SinExe
        Get-SteamInfo -RutaSteam $d | Should -BeNullOrEmpty
        Get-SteamMotivo | Should -BeLike '*steam.exe*'
    }
    It 'con una carpeta que no existe devuelve $null sin lanzar' {
        Get-SteamInfo -RutaSteam (Join-Path $TestDrive 'no-existe') | Should -BeNullOrEmpty
        Get-SteamMotivo | Should -BeLike '*steam.exe*'
    }
    It 'sin carpeta userdata devuelve $null y pide iniciar sesión' {
        $d = New-SteamFalso -Carpeta 'sinuserdata'
        Get-SteamInfo -RutaSteam $d | Should -BeNullOrEmpty
        Get-SteamMotivo | Should -BeLike '*ningún perfil*'
    }
    It 'no cuenta como perfil la carpeta 0 ni las que no son números' {
        $d = New-SteamFalso -Carpeta 'solocero'
        foreach ($p in '0', 'anonymous') { $null = New-Item -ItemType Directory -Path (Join-Path $d "userdata\$p") -Force }
        Get-SteamInfo -RutaSteam $d | Should -BeNullOrEmpty
        Get-SteamMotivo | Should -BeLike '*ningún perfil*'
    }
    It 'elige la cuenta con la sesión iniciada aunque otra sea más reciente' {
        Mock Get-ItemProperty { [pscustomobject]@{ ActiveUser = 111 } } -ParameterFilter { $Path -like '*\ActiveProcess' }
        $d = New-SteamFalso -Carpeta 'sesion' -Perfiles '111', '222'
        $s = Get-SteamInfo -RutaSteam $d
        $s.UserId | Should -Be '111'
        $s.ComoElegido | Should -BeExactly 'sesión iniciada'
        $s.Perfiles | Should -Be 2
        $s.Dir | Should -Be $d
        $s.Exe | Should -Be (Join-Path $d 'steam.exe')
        $s.ConfigDir | Should -Be (Join-Path $d 'userdata\111\config')
        $s.Shortcuts | Should -Be (Join-Path $d 'userdata\111\config\shortcuts.vdf')
        $s.GridDir | Should -Be (Join-Path $d 'userdata\111\config\grid')
        Should -Invoke Get-ItemProperty -Times 1 -Exactly -ParameterFilter { $Path -like '*\ActiveProcess' }
    }
    It 'lee bien una cuenta por encima de 2^31 (el DWORD llega negativo)' {
        Mock Get-ItemProperty { [pscustomobject]@{ ActiveUser = [int]-1294967296 } } -ParameterFilter { $Path -like '*\ActiveProcess' }
        $d = New-SteamFalso -Carpeta 'grande' -Perfiles '3000000000', '222'
        (Get-SteamInfo -RutaSteam $d).UserId | Should -Be '3000000000'
    }
    It 'con ActiveUser a 0 usa la cuenta marcada MostRecent en loginusers.vdf' {
        Mock Get-ItemProperty { [pscustomobject]@{ ActiveUser = 0 } } -ParameterFilter { $Path -like '*\ActiveProcess' }
        $lu = @"
"users"
{
	"$($script:Id64De111)"
	{
		"AccountName"		"uno"
		"MostRecent"		"1"
		"Timestamp"		"1700000000"
	}
	"$($script:Id64De222)"
	{
		"AccountName"		"dos"
		"MostRecent"		"0"
		"Timestamp"		"1800000000"
	}
}
"@
        $d = New-SteamFalso -Carpeta 'mostrecent' -Perfiles '111', '222' -LoginUsers $lu
        $s = Get-SteamInfo -RutaSteam $d
        $s.UserId | Should -Be '111'
        $s.ComoElegido | Should -BeExactly 'sesión iniciada'
    }
    It 'sin MostRecent en loginusers.vdf gana el Timestamp más alto' {
        $lu = @"
"users"
{
	"$($script:Id64De222)"
	{
		"AccountName"		"dos"
		"Timestamp"		"1800000000"
	}
	"$($script:Id64De111)"
	{
		"AccountName"		"uno"
		"Timestamp"		"1700000000"
	}
}
"@
        # 111 es el perfil mas reciente por fecha: si ganara, no se habria leido loginusers.vdf
        $d = New-SteamFalso -Carpeta 'timestamp' -Perfiles '222', '111' -LoginUsers $lu
        (Get-SteamInfo -RutaSteam $d).UserId | Should -Be '222'
    }
    It 'si la cuenta de la sesión no tiene perfil, coge el localconfig.vdf más reciente' {
        Mock Get-ItemProperty { [pscustomobject]@{ ActiveUser = 999 } } -ParameterFilter { $Path -like '*\ActiveProcess' }
        $d = New-SteamFalso -Carpeta 'reciente' -Perfiles '111', '222'
        $s = Get-SteamInfo -RutaSteam $d
        $s.UserId | Should -Be '222'
        $s.ComoElegido | Should -BeExactly 'el más reciente'
    }
    It 'un perfil sin localconfig.vdf no gana a uno que lo tiene' {
        $d = New-SteamFalso -Carpeta 'sinlocalconfig' -Perfiles '111', '222'
        Remove-Item -LiteralPath (Join-Path $d 'userdata\222\config\localconfig.vdf')
        (Get-SteamInfo -RutaSteam $d).UserId | Should -Be '111'
    }
    It 'un acierto borra el motivo del fallo anterior' {
        $null = Get-SteamInfo -RutaSteam (Join-Path $TestDrive 'no-existe')
        $d = New-SteamFalso -Carpeta 'bien' -Perfiles '111'
        $null = Get-SteamInfo -RutaSteam $d
        Get-SteamMotivo | Should -BeExactly 'No encuentro la instalación de Steam.'
    }
}
