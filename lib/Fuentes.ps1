# =====================================================================
#  Fuentes.ps1 - Deteccion de juegos instalados por origen
#  Devuelve objetos con: Nombre, Fuente, Exe, StartDir, LaunchOptions,
#                        Icono, StoreId, Carpeta, Detalle
# =====================================================================

function New-Juego {
    param(
        [string]$Nombre, [string]$Fuente, [string]$Exe, [string]$StartDir,
        [string]$LaunchOptions = '', [string]$Icono = '', [string]$StoreId = '',
        [string]$Carpeta = '', [string]$Detalle = '', [datetime]$Fecha = [datetime]::MinValue
    )
    [pscustomobject]@{
        Nombre        = $Nombre
        Fuente        = $Fuente
        Exe           = $Exe
        StartDir      = $StartDir
        LaunchOptions = $LaunchOptions
        Icono         = $Icono
        StoreId       = $StoreId
        Carpeta       = $Carpeta
        Detalle       = $Detalle
        Fecha         = $Fecha
        YaEnSteam     = $false
        AppId         = [uint32]0
    }
}

# ---------------------------------------------------------------------
#  Xbox / Game Pass  ->  C:\XboxGames\<Juego>\Content\gamelaunchhelper.exe
# ---------------------------------------------------------------------
function Get-JuegosXbox {
    $res = @()
    $unidades = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
                Where-Object { Test-Path -LiteralPath (Join-Path $_.Root 'XboxGames') }
    foreach ($u in $unidades) {
        $raiz = Join-Path $u.Root 'XboxGames'
        foreach ($dir in Get-ChildItem -LiteralPath $raiz -Directory -ErrorAction SilentlyContinue) {
            if ($dir.Name -eq 'GameSave') { continue }
            $content = Join-Path $dir.FullName 'Content'
            $helper  = Join-Path $content 'gamelaunchhelper.exe'
            if (-not (Test-Path -LiteralPath $helper)) { continue }

            $nombre = $dir.Name; $storeId = ''; $icono = ''
            $cfg = Join-Path $content 'MicrosoftGame.config'
            if (Test-Path -LiteralPath $cfg) {
                try {
                    [xml]$x = Get-Content -LiteralPath $cfg -Raw -Encoding UTF8
                    if ($x.Game.ShellVisuals.DefaultDisplayName) { $nombre = $x.Game.ShellVisuals.DefaultDisplayName }
                    if ($x.Game.StoreId) { $storeId = $x.Game.StoreId }
                    foreach ($cand in @($x.Game.ShellVisuals.Square480x480Logo, $x.Game.ShellVisuals.Square150x150Logo, $x.Game.ShellVisuals.StoreLogo)) {
                        if ($cand) {
                            $p = Join-Path $content $cand
                            if (Test-Path -LiteralPath $p) { $icono = $p; break }
                        }
                    }
                } catch { }
            }
            if (-not $icono) {
                foreach ($cand in @('Resources\Square480x480Logo.png','MediumLogo.png','Square150x150Logo.png','StoreLogo.png')) {
                    $p = Join-Path $content $cand
                    if (Test-Path -LiteralPath $p) { $icono = $p; break }
                }
            }
            $res += New-Juego -Nombre $nombre -Fuente 'Xbox / Game Pass' `
                    -Exe $helper -StartDir ($content + '\') -Icono $icono -StoreId $storeId `
                    -Carpeta $content -Detalle 'gamelaunchhelper.exe (lanzador oficial firmado)' `
                    -Fecha $dir.LastWriteTime
        }
    }
    return $res
}

# ---------------------------------------------------------------------
#  Ubisoft Connect  ->  UbisoftConnect.exe + uplay://launch/<id>/0
# ---------------------------------------------------------------------
function Get-JuegosUbisoft {
    $res = @()
    $lk = 'HKLM:\SOFTWARE\WOW6432Node\Ubisoft\Launcher'
    if (-not (Test-Path $lk)) { return $res }
    $launcherDir = (Get-ItemProperty $lk -ErrorAction SilentlyContinue).InstallDir
    if (-not $launcherDir) { return $res }
    $launcherExe = Join-Path ($launcherDir -replace '/','\') 'UbisoftConnect.exe'
    if (-not (Test-Path -LiteralPath $launcherExe)) { return $res }
    $startDir = (Split-Path $launcherExe -Parent) + '\'

    foreach ($k in Get-ChildItem "$lk\Installs" -ErrorAction SilentlyContinue) {
        $id  = Split-Path $k.Name -Leaf
        $dir = (Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue).InstallDir
        if (-not $dir) { continue }
        $dir = $dir -replace '/','\'
        # El registro conserva la clave de juegos desinstalados y de los que estan en un disco
        # desconectado. Sin esta comprobacion, Get-Item devuelve $null, '-Fecha $null' no se
        # puede convertir a [datetime] y la excepcion se lleva por delante la deteccion de
        # TODOS los origenes: el usuario ve la lista vacia.
        $info = Get-Item -LiteralPath $dir -ErrorAction SilentlyContinue
        if (-not $info) { continue }
        $nombre = Split-Path $dir.TrimEnd('\') -Leaf
        $icono = ''
        $exeGrande = Get-ChildItem -LiteralPath $dir -Filter *.exe -Recurse -ErrorAction SilentlyContinue |
                     Sort-Object Length -Descending | Select-Object -First 1
        if ($exeGrande) { $icono = $exeGrande.FullName }
        $res += New-Juego -Nombre $nombre -Fuente 'Ubisoft Connect' `
                -Exe $launcherExe -StartDir $startDir -LaunchOptions "uplay://launch/$id/0" `
                -Icono $icono -Carpeta $dir -Detalle "URI de Ubisoft (el .exe directo no arranca por DRM)" `
                -Fecha $info.LastWriteTime
    }
    return $res
}

# ---------------------------------------------------------------------
#  Epic Games  ->  manifiestos .item
# ---------------------------------------------------------------------
function Get-JuegosEpic {
    $res = @()
    $man = Join-Path $env:ProgramData 'Epic\EpicGamesLauncher\Data\Manifests'
    if (-not (Test-Path -LiteralPath $man)) { return $res }
    foreach ($f in Get-ChildItem -LiteralPath $man -Filter *.item -ErrorAction SilentlyContinue) {
        try { $j = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        if (-not $j.InstallLocation -or -not $j.LaunchExecutable) { continue }
        $exe = Join-Path $j.InstallLocation $j.LaunchExecutable
        if (-not (Test-Path -LiteralPath $exe)) { continue }
        $res += New-Juego -Nombre $j.DisplayName -Fuente 'Epic Games' `
                -Exe $exe -StartDir ((Split-Path $exe -Parent) + '\') -Icono $exe `
                -Carpeta $j.InstallLocation -Detalle 'Ejecutable directo del juego' `
                -Fecha $f.LastWriteTime
    }
    return $res
}

# ---------------------------------------------------------------------
#  GOG Galaxy
# ---------------------------------------------------------------------
function Get-JuegosGog {
    $res = @()
    foreach ($base in @('HKLM:\SOFTWARE\WOW6432Node\GOG.com\Games','HKLM:\SOFTWARE\GOG.com\Games')) {
        foreach ($k in Get-ChildItem $base -ErrorAction SilentlyContinue) {
            $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
            if (-not $p.path -or -not $p.exe) { continue }
            $exe = if (Test-Path -LiteralPath $p.exe) { $p.exe } else { Join-Path $p.path $p.exe }
            if (-not (Test-Path -LiteralPath $exe)) { continue }
            $res += New-Juego -Nombre $p.gameName -Fuente 'GOG' `
                    -Exe $exe -StartDir ((Split-Path $exe -Parent) + '\') -Icono $exe `
                    -Carpeta $p.path -Detalle 'Ejecutable directo del juego'
        }
    }
    return $res
}

# ---------------------------------------------------------------------
#  Apps de la Store (UWP): sin .exe, van por explorer.exe + AUMID
# ---------------------------------------------------------------------
function Get-AppsStore {
    $res = @()
    foreach ($a in (Get-StartApps -ErrorAction SilentlyContinue)) {
        if ($a.AppID -notmatch '!') { continue }          # solo AUMID de paquete
        if ($a.AppID -match '^Microsoft\.(Windows|BingWeather|ScreenSketch|MicrosoftEdge|Todos|People|Getstarted|WindowsStore|549981)') { continue }
        $res += New-Juego -Nombre $a.Name -Fuente 'App de la Store' `
                -Exe (Join-Path $env:SystemRoot 'explorer.exe') -StartDir ($env:SystemRoot + '\') `
                -LaunchOptions ('shell:AppsFolder\' + $a.AppID) `
                -Detalle 'UWP: Steam pierde el proceso (sin overlay ni horas)'
    }
    return $res
}

# ---------------------------------------------------------------------
#  Ultimos programas ejecutados (UserAssist de Windows)
# ---------------------------------------------------------------------
function ConvertFrom-Rot13 {
    param([string]$Texto)
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $Texto.ToCharArray()) {
        if     ($c -cmatch '[a-z]') { [void]$sb.Append([char]((([int]$c - 97 + 13) % 26) + 97)) }
        elseif ($c -cmatch '[A-Z]') { [void]$sb.Append([char]((([int]$c - 65 + 13) % 26) + 65)) }
        else                        { [void]$sb.Append($c) }
    }
    return $sb.ToString()
}

$script:GuidCarpetas = @{
    '{6D809377-6AF0-444B-8957-A3773F02200E}' = ${env:ProgramFiles}
    '{7C5A40EF-A0FB-4BFC-874A-C0F2E0B9FA8E}' = ${env:ProgramFiles(x86)}
    '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}' = "$env:SystemRoot\System32"
    '{F38BF404-1D43-42F2-9305-67DE0B28FC23}' = $env:SystemRoot
    '{D65231B0-B2F1-4857-A4CE-A8E7C6EA7D27}' = "$env:SystemRoot\System32"
    '{B4BFCC3A-DB2C-424C-B029-7FE99A87C641}' = "$env:USERPROFILE\Desktop"
    '{0139D44E-6AFE-49F2-8690-3DAFCAE6FFB8}' = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs"
    '{A4115719-D62E-491D-AA7C-E74B8BE3B067}' = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs"
    '{9E3995AB-1F9C-4F13-B827-48B24B6C7174}' = "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned"
}

function Get-ProgramasRecientes {
    param([int]$Maximo = 60)
    $res = @()
    $base = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\UserAssist'
    $vistos = @{}
    foreach ($guid in Get-ChildItem $base -ErrorAction SilentlyContinue) {
        $count = Join-Path $guid.PSPath 'Count'
        $item = Get-Item $count -ErrorAction SilentlyContinue
        if (-not $item) { continue }
        foreach ($nombreVal in $item.GetValueNames()) {
            $ruta = ConvertFrom-Rot13 $nombreVal
            if ($ruta -notmatch '\.exe$') { continue }
            foreach ($g in $script:GuidCarpetas.Keys) {
                if ($ruta.StartsWith($g, 'OrdinalIgnoreCase')) {
                    $ruta = $script:GuidCarpetas[$g] + $ruta.Substring($g.Length); break
                }
            }
            if ($ruta -match '^\{') { continue }
            if (-not (Test-Path -LiteralPath $ruta)) { continue }
            $hoja = Split-Path $ruta -Leaf
            if ($hoja -match '^(explorer|cmd|powershell|pwsh|regedit|mmc|notepad|taskmgr|control|rundll32|msedge|chrome|firefox|steam|steamwebhelper|EpicGamesLauncher|UbisoftConnect|GalaxyClient)\.exe$') { continue }
            if ($ruta -like "$env:SystemRoot\System32\*" -or $ruta -like "$env:SystemRoot\SysWOW64\*") { continue }
            if ($vistos.ContainsKey($ruta.ToLower())) { continue }

            $fecha = [datetime]::MinValue
            try {
                $datos = $item.GetValue($nombreVal)
                if ($datos -and $datos.Length -ge 68) {
                    $ft = [System.BitConverter]::ToInt64($datos, 60)
                    if ($ft -gt 0) { $fecha = [datetime]::FromFileTime($ft) }
                }
            } catch { }
            $vistos[$ruta.ToLower()] = $true
            $res += New-Juego -Nombre ([IO.Path]::GetFileNameWithoutExtension($ruta)) -Fuente 'Reciente' `
                    -Exe $ruta -StartDir ((Split-Path $ruta -Parent) + '\') -Icono $ruta `
                    -Carpeta (Split-Path $ruta -Parent) -Detalle "Ultima ejecucion: $(if($fecha -gt [datetime]::MinValue){$fecha.ToString('dd/MM/yyyy HH:mm')}else{'desconocida'})" `
                    -Fecha $fecha
        }
    }
    return ($res | Sort-Object Fecha -Descending | Select-Object -First $Maximo)
}

# ---------------------------------------------------------------------
#  Todo junto, cada origen aislado del resto
# ---------------------------------------------------------------------

# Deja constancia de un origen que ha fallado. Sin -Log intenta el registro de la aplicacion,
# que solo existe si esta lib se ha cargado desde VaporeraArcade.ps1 (se puede usar suelta).
function Write-AvisoFuente {
    param([string]$Texto, [scriptblock]$Log = $null)
    if ($Log) { & $Log $Texto | Out-Null; return }
    if (Get-Command Write-Registro -ErrorAction SilentlyContinue) { Write-Registro $Texto }
}

function Get-TodosLosJuegos {
    param([switch]$IncluirRecientes, [switch]$IncluirApps, [scriptblock]$Log = $null)
    # Cada origen va en su propio try: uno que falle (una clave del registro que apunta a un
    # disco desconectado, un manifiesto ilegible...) no puede dejar la lista entera vacia.
    $origenes = [ordered]@{
        'Xbox / Game Pass' = { Get-JuegosXbox }
        'Ubisoft Connect'  = { Get-JuegosUbisoft }
        'Epic Games'       = { Get-JuegosEpic }
        'GOG'              = { Get-JuegosGog }
    }
    if ($IncluirApps)      { $origenes['apps de la Store']   = { Get-AppsStore } }
    if ($IncluirRecientes) { $origenes['programas recientes'] = { Get-ProgramasRecientes } }

    $lista = @()
    foreach ($nombre in @($origenes.Keys)) {
        try { $lista += & $origenes[$nombre] }
        catch {
            Write-AvisoFuente -Log $Log -Texto "No he podido leer los juegos de $nombre : $($_.Exception.Message)"
        }
    }
    return $lista
}
