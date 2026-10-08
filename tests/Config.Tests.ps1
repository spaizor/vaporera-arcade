# =====================================================================
#  Tests de lib/Config.ps1: config.json y los juegos elegidos a mano para las caratulas.
#  No tocan el config.json de verdad: Get-ConfigRuta apunta a un fichero de $TestDrive.
#  Se lanzan con tests\Invoke-Tests.ps1 (Pester 5, Windows PowerShell 5.1)
# =====================================================================

BeforeAll {
    . (Join-Path $PSScriptRoot '..\lib\Config.ps1')

    # el lanzador de Ubisoft: el mismo exe para todos sus juegos, que se distinguen por las opciones
    $script:Ubi = 'C:\Program Files (x86)\Ubisoft\Ubisoft Game Launcher\UbisoftConnect.exe'

    # Cada test con su config.json, en una carpeta que todavia no existe. Si el Mock no
    # prendiera, los tests escribirian en el de verdad: se comprueba antes de seguir.
    function Use-ConfigDePrueba {
        $script:RutaCfg = Join-Path $TestDrive ('cfg-' + [guid]::NewGuid().ToString('N') + '\config.json')
        Mock Get-ConfigRuta { $script:RutaCfg }
        Get-ConfigRuta | Should -BeExactly $script:RutaCfg
    }
    function Get-Json { [IO.File]::ReadAllText($script:RutaCfg) }
    function Set-Json([string]$texto) {
        $null = [IO.Directory]::CreateDirectory((Split-Path $script:RutaCfg -Parent))
        [IO.File]::WriteAllText($script:RutaCfg, $texto, (New-Object Text.UTF8Encoding($false)))
    }
}

Describe 'Get-Config / Set-ConfigValor' {
    BeforeEach { Use-ConfigDePrueba }

    It 'sin fichero devuelve una tabla vacía' {
        $c = Get-Config
        $c -is [hashtable] | Should -BeTrue
        $c.Count | Should -Be 0
    }
    It 'guarda un ajuste creando la carpeta, y lo vuelve a leer con sus tildes' {
        Set-ConfigValor -Nombre 'Prueba' -Valor 'carátulas ñ'
        (Get-Config)['Prueba'] | Should -BeExactly 'carátulas ñ'
        # UTF-8 sin BOM, como siempre
        $b = [IO.File]::ReadAllBytes($script:RutaCfg)
        ($b[0] -eq 0xEF -and $b[1] -eq 0xBB) | Should -BeFalse
    }
    It 'guardar un ajuste no toca los demás' {
        Set-ConfigValor -Nombre 'Uno' -Valor '1'
        Set-ConfigValor -Nombre 'Dos' -Valor '2'
        Set-ConfigValor -Nombre 'Uno' -Valor 'otro'
        $c = Get-Config
        $c['Uno'] | Should -Be 'otro'
        $c['Dos'] | Should -Be '2'
        $c.Count | Should -Be 2
    }
    It 'un valor vacío borra el ajuste: <Caso>' -ForEach @(
        @{ Caso = '$null';          Valor = $null }
        @{ Caso = 'cadena vacía';   Valor = '' }
        @{ Caso = 'lista sin nada'; Valor = @() }
    ) {
        Set-ConfigValor -Nombre 'Queda' -Valor 'sí'
        Set-ConfigValor -Nombre 'Fuera' -Valor 'algo'
        Set-ConfigValor -Nombre 'Fuera' -Valor $Valor
        $c = Get-Config
        $c.ContainsKey('Fuera') | Should -BeFalse
        $c['Queda'] | Should -Be 'sí'
    }
    It 'una lista con un solo objeto se guarda, y vuelve como lista' {
        # [string] de una lista con un solo pscustomobject es '': antes contaba como vacia
        Set-ConfigValor -Nombre 'Lista' -Valor @([pscustomobject]@{ A = 'uno' })
        $l = (Get-Config)['Lista']
        $l -is [array] | Should -BeTrue
        @($l).Count | Should -Be 1
        $l[0].A | Should -Be 'uno'
    }
    It 'no corta lo anidado a dos niveles' {
        Set-ConfigValor -Nombre 'Tabla' -Valor @{ Juego = @{ Elegido = @{ Id = 'fondo' } } }
        (Get-Config)['Tabla'].Juego.Elegido.Id | Should -Be 'fondo'
        Get-Json | Should -Not -Match 'System\.Collections'
    }
    It 'un fichero roto se lee como vacío, sin lanzar' {
        Set-Json '{ "SgdbClave": "abc", '
        (Get-Config).Count | Should -Be 0
    }
    It 'no deja el .tmp al lado, ni la primera vez ni al reescribir' {
        Set-ConfigValor -Nombre 'Uno' -Valor '1'
        Test-Path -LiteralPath "$($script:RutaCfg).tmp" | Should -BeFalse
        Set-ConfigValor -Nombre 'Uno' -Valor '2'
        Test-Path -LiteralPath "$($script:RutaCfg).tmp" | Should -BeFalse
        (Get-Config)['Uno'] | Should -Be '2'
    }
}

Describe 'Juegos elegidos a mano' {
    BeforeEach { Use-ConfigDePrueba }

    It 'sin nada guardado, la lista está vacía y no encuentra nada' {
        @(Get-JuegosElegidos).Count | Should -Be 0
        Find-JuegoElegido -Lista @(Get-JuegosElegidos) -Exe 'C:\Juegos\Juego.exe' | Should -BeNullOrEmpty
    }
    It 'guarda el elegido de un juego y sigue ahí al volver a leer' {
        $l = @(Set-JuegoElegido -Exe 'C:\Juegos\Juego.exe' -Fuente 'Microsoft Store' -Id '9NBLGGH' -Titulo 'Mi Juego')
        $l.Count | Should -Be 1
        # lo que cuenta es lo que ha quedado en el fichero
        $e = Find-JuegoElegido -Lista @(Get-JuegosElegidos) -Exe 'C:\Juegos\Juego.exe'
        $e.Fuente | Should -BeExactly 'Microsoft Store'
        $e.Id | Should -BeExactly '9NBLGGH'
        $e.Titulo | Should -BeExactly 'Mi Juego'
        $e.Opciones | Should -BeExactly ''
    }
    It 'dos juegos de Ubisoft (el mismo exe) no se pisan: los distinguen las opciones' {
        $null = Set-JuegoElegido -Exe $script:Ubi -Opciones 'uplay://launch/80/0' -Fuente 'SteamGridDB' -Id '2254' -Titulo 'Rayman Origins'
        $l = @(Set-JuegoElegido -Exe $script:Ubi -Opciones 'uplay://launch/410/0' -Fuente 'SteamGridDB' -Id '2255' -Titulo 'Rayman Legends')
        $l.Count | Should -Be 2
        $guardados = @(Get-JuegosElegidos)
        (Find-JuegoElegido -Lista $guardados -Exe $script:Ubi -Opciones 'uplay://launch/80/0').Titulo | Should -Be 'Rayman Origins'
        (Find-JuegoElegido -Lista $guardados -Exe $script:Ubi -Opciones 'uplay://launch/410/0').Titulo | Should -Be 'Rayman Legends'
    }
    It 'el exe solo no basta: con otras opciones, o sin ellas, no es ese juego' {
        $null = Set-JuegoElegido -Exe $script:Ubi -Opciones 'uplay://launch/80/0' -Fuente 'SteamGridDB' -Id '2254' -Titulo 'Rayman Origins'
        $guardados = @(Get-JuegosElegidos)
        Find-JuegoElegido -Lista $guardados -Exe $script:Ubi -Opciones 'uplay://launch/5/0' | Should -BeNullOrEmpty
        Find-JuegoElegido -Lista $guardados -Exe $script:Ubi | Should -BeNullOrEmpty
    }
    It 'elegir otro para el mismo juego sustituye al anterior' {
        $null = Set-JuegoElegido -Exe 'C:\Juegos\Juego.exe' -Fuente 'Microsoft Store' -Id '9MAL' -Titulo 'El que no era'
        $l = @(Set-JuegoElegido -Exe 'C:\Juegos\Juego.exe' -Fuente 'SteamGridDB' -Id '77' -Titulo 'El bueno')
        $l.Count | Should -Be 1
        $guardados = @(Get-JuegosElegidos)
        $guardados.Count | Should -Be 1
        $guardados[0].Id | Should -Be '77'
        $guardados[0].Fuente | Should -Be 'SteamGridDB'
    }
    It 'reconoce el juego sin distinguir mayúsculas en la ruta, al buscar y al sustituir' {
        $null = Set-JuegoElegido -Exe 'C:\XboxGames\Juego\Content\gamelaunchhelper.exe' -Fuente 'SteamGridDB' -Id '1' -Titulo 'Uno'
        (Find-JuegoElegido -Lista @(Get-JuegosElegidos) -Exe 'c:\xboxgames\juego\content\GameLaunchHelper.exe').Id | Should -Be '1'
        $l = @(Set-JuegoElegido -Exe 'c:\xboxgames\juego\content\GameLaunchHelper.exe' -Fuente 'SteamGridDB' -Id '2' -Titulo 'Dos')
        $l.Count | Should -Be 1
        $l[0].Id | Should -Be '2'
    }
    It 'un título con tildes, comillas y símbolos vuelve igual' {
        $titulo = 'Assassin''s Creed® «Edición» "Pokémon" <b> & c\o {0}'
        $null = Set-JuegoElegido -Exe 'C:\Juegos\Juego.exe' -Opciones '-c "..\juego.ini" x' -Fuente 'SteamGridDB' -Id '5' -Titulo $titulo
        $e = Find-JuegoElegido -Lista @(Get-JuegosElegidos) -Exe 'C:\Juegos\Juego.exe' -Opciones '-c "..\juego.ini" x'
        $e.Titulo | Should -BeExactly $titulo
    }
    It 'olvidar uno deja los demás' {
        $null = Set-JuegoElegido -Exe 'C:\uno.exe' -Fuente 'SteamGridDB' -Id '1' -Titulo 'Uno'
        $null = Set-JuegoElegido -Exe 'C:\dos.exe' -Fuente 'SteamGridDB' -Id '2' -Titulo 'Dos'
        $null = Set-JuegoElegido -Exe 'C:\tres.exe' -Fuente 'SteamGridDB' -Id '3' -Titulo 'Tres'
        $l = @(Remove-JuegoElegido -Exe 'C:\DOS.exe')
        $l.Count | Should -Be 2
        $guardados = @(Get-JuegosElegidos)
        $guardados.Titulo | Should -Be @('Uno', 'Tres')
    }
    It 'olvidar el último quita la clave del fichero y deja la lista vacía' {
        $null = Set-JuegoElegido -Exe 'C:\uno.exe' -Fuente 'SteamGridDB' -Id '1' -Titulo 'Uno'
        @(Remove-JuegoElegido -Exe 'C:\uno.exe').Count | Should -Be 0
        @(Get-JuegosElegidos).Count | Should -Be 0
        (Get-Config).ContainsKey('JuegosElegidos') | Should -BeFalse
    }
    It 'olvidar uno que no está no escribe nada' {
        @(Remove-JuegoElegido -Exe 'C:\no-esta.exe').Count | Should -Be 0
        Test-Path -LiteralPath $script:RutaCfg | Should -BeFalse

        $null = Set-JuegoElegido -Exe 'C:\uno.exe' -Opciones '-x' -Fuente 'SteamGridDB' -Id '1' -Titulo 'Uno'
        $antes = Get-Json
        # el mismo exe con otras opciones es otro juego
        @(Remove-JuegoElegido -Exe 'C:\uno.exe').Count | Should -Be 1
        Get-Json | Should -BeExactly $antes
    }
    It 'guardar la clave de SteamGridDB no toca los juegos, ni guardar un juego la clave' {
        Set-ConfigValor -Nombre 'SgdbClave' -Valor 'clave-de-antes'
        $null = Set-JuegoElegido -Exe $script:Ubi -Opciones 'uplay://launch/80/0' -Fuente 'SteamGridDB' -Id '2254' -Titulo 'Rayman Origins'
        (Get-Config)['SgdbClave'] | Should -BeExactly 'clave-de-antes'

        # lo que hace Ajustes: lee el fichero entero (los juegos llegan como pscustomobject) y lo reescribe
        Set-ConfigValor -Nombre 'SgdbClave' -Valor 'clave-nueva'
        (Get-Config)['SgdbClave'] | Should -BeExactly 'clave-nueva'
        $guardados = @(Get-JuegosElegidos)
        $guardados.Count | Should -Be 1
        $guardados[0].Exe | Should -BeExactly $script:Ubi
        $guardados[0].Opciones | Should -BeExactly 'uplay://launch/80/0'
        $guardados[0].Id | Should -BeExactly '2254'

        # y borrar la clave tampoco se los lleva
        Set-ConfigValor -Nombre 'SgdbClave' -Valor ''
        @(Get-JuegosElegidos).Count | Should -Be 1
    }
    It 'de un fichero tocado a mano se salta lo que no está entero' {
        Set-Json @'
{ "JuegosElegidos": [
    { "Exe": "C:\\sin-elegido.exe" },
    "texto suelto",
    null,
    7,
    { "Fuente": "SteamGridDB", "Id": "1", "Titulo": "Sin exe" },
    { "Exe": "C:\\bueno.exe", "Opciones": "-x", "Fuente": "Microsoft Store", "Id": "9X", "Titulo": "Bueno" }
] }
'@
        $guardados = @(Get-JuegosElegidos)
        $guardados.Count | Should -Be 1
        $guardados[0].Titulo | Should -Be 'Bueno'
    }
    It 'vale una entrada suelta en vez de una lista, con el id en número y sin opciones' {
        Set-Json '{ "JuegosElegidos": { "Exe": "C:\\a.exe", "Fuente": "SteamGridDB", "Id": 5247 } }'
        $guardados = @(Get-JuegosElegidos)
        $guardados.Count | Should -Be 1
        $guardados[0].Id | Should -BeExactly '5247'
        $guardados[0].Opciones | Should -BeExactly ''
        $guardados[0].Titulo | Should -BeExactly ''
        (Find-JuegoElegido -Lista $guardados -Exe 'C:\a.exe').Fuente | Should -Be 'SteamGridDB'
    }
    It 'Find-JuegoElegido no falla con la lista vacía, con $null ni con huecos $null' {
        $uno = [pscustomobject]@{ Exe = 'C:\a.exe'; Opciones = ''; Fuente = 'SteamGridDB'; Id = '1'; Titulo = 'A' }
        Find-JuegoElegido -Lista @() -Exe 'C:\a.exe' | Should -BeNullOrEmpty
        Find-JuegoElegido -Lista $null -Exe 'C:\a.exe' | Should -BeNullOrEmpty
        (Find-JuegoElegido -Lista @($null, $uno) -Exe 'C:\a.exe').Id | Should -Be '1'
    }
}

Describe 'Juegos vistos (para marcar los nuevos)' {
    BeforeEach { Use-ConfigDePrueba }

    It 'la huella no guarda la ruta, no distingue mayúsculas y cambia con las opciones' {
        $h = Get-HuellaJuego -Exe 'C:\Users\Alguien\Juegos\Juego.exe'
        $h | Should -Match '^[0-9a-f]{16}$'
        Get-HuellaJuego -Exe 'c:\users\ALGUIEN\juegos\juego.exe' | Should -BeExactly $h
        Get-HuellaJuego -Exe $script:Ubi -Opciones 'uplay://launch/80/0' |
            Should -Not -Be (Get-HuellaJuego -Exe $script:Ubi -Opciones 'uplay://launch/410/0')
    }
    It 'sin guardar nunca, $null (la primera vez no se marca nada)' {
        Get-JuegosVistos | Should -BeNullOrEmpty
        (Get-JuegosVistos) -eq $null | Should -BeTrue
    }
    It 'guarda y lee las huellas sin repetir, y en config.json no hay rutas' {
        $a = Get-HuellaJuego -Exe 'C:\Users\Alguien\a.exe'
        $b = Get-HuellaJuego -Exe 'C:\Users\Alguien\b.exe'
        Set-JuegosVistos -Huellas @($a, $b, $a)
        $v = Get-JuegosVistos
        $v -is [hashtable] | Should -BeTrue
        $v.Count | Should -Be 2
        $v.ContainsKey($a) | Should -BeTrue
        Get-Json | Should -Not -Match 'Alguien'
    }
    It 'con uno solo sigue siendo una lista en config.json' {
        Set-JuegosVistos -Huellas @('0123456789abcdef')
        (Get-JuegosVistos).ContainsKey('0123456789abcdef') | Should -BeTrue
        Get-Json | Should -Match '"JuegosVistos":\s*\[\s*"0123456789abcdef"\s*\]'
    }
}
