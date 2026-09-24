# =====================================================================
#  Tests de lib/Vdf.ps1: lectura y escritura de shortcuts.vdf y appid
#  Se lanzan con tests\Invoke-Tests.ps1 (Pester 5, Windows PowerShell 5.1)
#
#  El VDF de prueba se monta byte a byte aqui mismo, sin pasar por Write-VdfMap: si se
#  generara con el propio escritor, un fallo de formato saldria igual a la ida y a la vuelta
#  y el round-trip daria bueno. Por lo mismo, los CRC32 y appid de referencia salen de
#  zlib.crc32 de Python y no de este codigo.
# =====================================================================

BeforeAll {
    . (Join-Path $PSScriptRoot '..\lib\Vdf.ps1')

    $script:Utf8 = New-Object System.Text.UTF8Encoding($false)
    function Add-Clave($l, [byte]$tipo, [string]$clave) {
        $l.Add($tipo); $l.AddRange($script:Utf8.GetBytes($clave)); $l.Add([byte]0)
    }
    function Add-Texto($l, [string]$clave, [string]$valor) {
        Add-Clave $l 1 $clave; $l.AddRange($script:Utf8.GetBytes($valor)); $l.Add([byte]0)
    }
    function Add-Entero($l, [string]$clave, [int]$valor)     { Add-Clave $l 2 $clave; $l.AddRange([BitConverter]::GetBytes($valor)) }
    function Add-Real($l, [string]$clave, [single]$valor)    { Add-Clave $l 3 $clave; $l.AddRange([BitConverter]::GetBytes($valor)) }
    function Add-Entero64($l, [string]$clave, [uint64]$valor){ Add-Clave $l 7 $clave; $l.AddRange([BitConverter]::GetBytes($valor)) }
    function Open-Mapa($l, [string]$clave) { Add-Clave $l 0 $clave }
    function Close-Mapa($l) { $l.Add([byte]8) }

    # Dos entradas con todo lo que puede aparecer: los tipos 1, 2, 3 y 7, cadenas vacias,
    # tildes en UTF-8, comillas y espacios en las opciones, un appid negativo (el bit alto
    # puesto) y un mapa 'tags' vacio.
    function New-VdfPrueba {
        $l = New-Object 'System.Collections.Generic.List[byte]'
        Open-Mapa $l 'shortcuts'
            Open-Mapa $l '0'
                Add-Entero $l 'appid' -1730246837
                Add-Texto  $l 'AppName' 'Mi Juego'
                Add-Texto  $l 'Exe' '"C:\Juegos\Juego.exe"'
                Add-Texto  $l 'StartDir' '"C:\Juegos\"'
                Add-Texto  $l 'icon' ''
                Add-Texto  $l 'LaunchOptions' ''
                Add-Entero $l 'IsHidden' 0
                Add-Entero $l 'LastPlayTime' 1758620000
                Open-Mapa $l 'tags'
                    Add-Texto $l '0' 'Installed locally'
                    Add-Texto $l '1' 'Favoritos'
                Close-Mapa $l
            Close-Mapa $l
            Open-Mapa $l '1'
                Add-Entero   $l 'appid' -1317327358
                Add-Texto    $l 'AppName' 'Pokémon Edición Oro'
                Add-Texto    $l 'Exe' '"C:\Juegos\Pokémon.exe"'
                Add-Texto    $l 'LaunchOptions' 'uplay://launch/80/0 -modo "ventana completa"'
                Add-Real     $l 'Escala' 1.5
                Add-Entero64 $l 'Grande' ([uint64]::MaxValue)
                Open-Mapa $l 'tags'
                Close-Mapa $l
            Close-Mapa $l
        Close-Mapa $l
        Close-Mapa $l       # cierre del documento
        return ,$l.ToArray()
    }

    # -1 si son iguales; si no, el primer offset en que difieren (o la longitud mas corta)
    function Get-PrimeraDiferencia([byte[]]$a, [byte[]]$b) {
        $n = [Math]::Min($a.Length, $b.Length)
        for ($i = 0; $i -lt $n; $i++) { if ($a[$i] -ne $b[$i]) { return $i } }
        if ($a.Length -ne $b.Length) { return $n }
        return -1
    }

    # Lee y reescribe un fichero: el caso de Add-SteamShortcut sin cambios
    function Invoke-IdaYVuelta([string]$origen, [string]$destino) {
        $raiz = Read-BinaryVdf -Path $origen
        Write-BinaryVdf -Root $raiz -Path $destino
        return ,[IO.File]::ReadAllBytes($destino)
    }
}

Describe 'Read-BinaryVdf' {
    BeforeAll {
        $ruta = Join-Path $TestDrive 'lectura.vdf'
        [IO.File]::WriteAllBytes($ruta, (New-VdfPrueba))
        $raiz = Read-BinaryVdf -Path $ruta
        $sc = $raiz['shortcuts']
    }

    It 'lee las dos entradas en orden' {
        @($sc.Keys) | Should -Be @('0', '1')
    }
    It 'lee las cadenas, también las vacías' {
        $sc['0']['AppName'] | Should -BeExactly 'Mi Juego'
        $sc['0']['Exe'] | Should -BeExactly '"C:\Juegos\Juego.exe"'
        $sc['0']['icon'] | Should -BeExactly ''
    }
    It 'lee las tildes en UTF-8' {
        $sc['1']['AppName'] | Should -BeExactly 'Pokémon Edición Oro'
    }
    It 'lee el appid como entero con signo' {
        $sc['0']['appid'] | Should -Be -1730246837
        $sc['0']['appid'] | Should -BeOfType [int]
    }
    It 'lee los tipos 3 (real) y 7 (entero de 64 bits)' {
        $sc['1']['Escala'] | Should -Be 1.5
        $sc['1']['Escala'] | Should -BeOfType [single]
        $sc['1']['Grande'] | Should -Be ([uint64]::MaxValue)
    }
    It 'lee los mapas anidados, también el vacío' {
        $sc['0']['tags']['1'] | Should -BeExactly 'Favoritos'
        $sc['1']['tags'] | Should -BeOfType [System.Collections.IDictionary]
        $sc['1']['tags'].Count | Should -Be 0
    }
    It 'lanza con un tipo que no conoce, en vez de seguir leyendo basura' {
        $mala = Join-Path $TestDrive 'mala.vdf'
        [IO.File]::WriteAllBytes($mala, [byte[]](5, 0x78, 0, 8))
        { Read-BinaryVdf -Path $mala } | Should -Throw '*Tipo VDF desconocido*'
    }
}

Describe 'Write-BinaryVdf: ida y vuelta byte a byte' {
    BeforeAll {
        $original = New-VdfPrueba
        $origen = Join-Path $TestDrive 'origen.vdf'
        [IO.File]::WriteAllBytes($origen, $original)
    }

    It 'deja un fichero idéntico al leer y reescribir (destino nuevo)' {
        $destino = Join-Path $TestDrive 'nuevo.vdf'
        $bytes = Invoke-IdaYVuelta $origen $destino
        Get-PrimeraDiferencia $original $bytes | Should -Be -1
    }
    It 'deja un fichero idéntico al sobrescribir uno que ya existe' {
        $destino = Join-Path $TestDrive 'existente.vdf'
        [IO.File]::WriteAllBytes($destino, [byte[]](1, 2, 3))
        $bytes = Invoke-IdaYVuelta $origen $destino
        Get-PrimeraDiferencia $original $bytes | Should -Be -1
    }
    It 'sigue idéntico tras 10 vueltas seguidas sobre el mismo fichero' {
        $destino = Join-Path $TestDrive 'vueltas.vdf'
        [IO.File]::WriteAllBytes($destino, $original)
        for ($i = 0; $i -lt 10; $i++) { $bytes = Invoke-IdaYVuelta $destino $destino }
        Get-PrimeraDiferencia $original $bytes | Should -Be -1
    }
    It 'no deja el .tmp de la escritura atómica' {
        $destino = Join-Path $TestDrive 'sintmp.vdf'
        $null = Invoke-IdaYVuelta $origen $destino
        $null = Invoke-IdaYVuelta $origen $destino
        "$destino.tmp" | Should -Not -Exist
    }
    It 'escribe un [uint32] con los mismos 4 bytes que el [int] equivalente' {
        $a = [ordered]@{ 'x' = [ordered]@{ 'appid' = [uint32]2564720459 } }
        $b = [ordered]@{ 'x' = [ordered]@{ 'appid' = [int]-1730246837 } }
        Write-BinaryVdf -Root $a -Path (Join-Path $TestDrive 'u32.vdf')
        Write-BinaryVdf -Root $b -Path (Join-Path $TestDrive 'i32.vdf')
        $ba = [IO.File]::ReadAllBytes((Join-Path $TestDrive 'u32.vdf'))
        $bb = [IO.File]::ReadAllBytes((Join-Path $TestDrive 'i32.vdf'))
        Get-PrimeraDiferencia $ba $bb | Should -Be -1
    }

    # Sobre una COPIA de los shortcuts.vdf de verdad de este PC, si los hay: el fichero de
    # prueba no puede tener todo lo que mete Steam. Solo se lee el original.
    It 'deja idéntica una copia de cada shortcuts.vdf real del equipo' {
        $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
        $reales = @()
        if ($steam) {
            $reales = @(Get-ChildItem -Path (Join-Path $steam 'userdata\*\config\shortcuts.vdf') -ErrorAction SilentlyContinue)
        }
        if (-not $reales.Count) { Set-ItResult -Skipped -Because 'no hay ningún shortcuts.vdf en este equipo'; return }
        $n = 0
        foreach ($f in $reales) {
            $n++
            $copia = Join-Path $TestDrive "real-$n.vdf"
            Copy-Item -LiteralPath $f.FullName -Destination $copia
            $antes = [IO.File]::ReadAllBytes($copia)
            $bytes = Invoke-IdaYVuelta $copia (Join-Path $TestDrive "real-$n-vuelta.vdf")
            Get-PrimeraDiferencia $antes $bytes | Should -Be -1 -Because $f.FullName
        }
    }
}

Describe 'CRC32 y appid' {
    It 'CRC32 de "<Texto>" es <Esperado> (valores de control del estándar)' -ForEach @(
        @{ Texto = '123456789'; Esperado = 3421780262 }
        @{ Texto = ''; Esperado = 0 }
        @{ Texto = 'The quick brown fox jumps over the lazy dog'; Esperado = 1095738169 }
    ) {
        Get-Crc32 -Bytes ([Text.Encoding]::ASCII.GetBytes($Texto)) | Should -Be $Esperado
    }

    It 'appid de "<Titulo>" es <AppId>' -ForEach @(
        @{ Ruta = '"C:\Juegos\Juego.exe"'; Titulo = 'Mi Juego'; AppId = 2564720459; EnVdf = -1730246837 }
        @{ Ruta = '"C:\Program Files (x86)\Ubisoft\Ubisoft Game Launcher\UbisoftConnect.exe"'; Titulo = 'Rayman Origins'; AppId = 3942880765; EnVdf = -352086531 }
        # el CRC de este no lleva el bit alto: comprueba que se le suma el 0x80000000
        @{ Ruta = '"C:\XboxGames\Wolfenstein II- The New Colossus\Content\gamelaunchhelper.exe"'; Titulo = 'Wolfenstein II: The New Colossus'; AppId = 3410483158; EnVdf = -884484138 }
        @{ Ruta = '"C:\Juegos\Pokémon.exe"'; Titulo = 'Pokémon Edición Oro'; AppId = 2977639938; EnVdf = -1317327358 }
    ) {
        $id = Get-SteamShortcutAppId -ExeQuoted $Ruta -AppName $Titulo
        $id | Should -Be $AppId
        $id | Should -BeOfType [uint32]
        ConvertTo-VdfAppId -AppId $id | Should -Be $EnVdf
    }

    It 'cambia el appid si cambia una sola letra del nombre' {
        $a = Get-SteamShortcutAppId -ExeQuoted '"C:\a.exe"' -AppName 'Juego'
        $b = Get-SteamShortcutAppId -ExeQuoted '"C:\a.exe"' -AppName 'Juegos'
        $a | Should -Not -Be $b
    }
}
