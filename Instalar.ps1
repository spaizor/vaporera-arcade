# =====================================================================
#  Instalar.ps1 - Crea el acceso directo de Vaporera Arcade
#
#  No instala nada en otro sitio: la aplicacion vive en esta misma
#  carpeta y el acceso directo apunta aqui. Es un programa portable.
#
#  Sustituye al antiguo lanzador .vbs: Windows 11 esta retirando el
#  motor de VBScript, asi que el acceso directo lo crea este script y
#  apunta a powershell.exe con la ventana oculta.
#
#  Uso:  powershell -ExecutionPolicy Bypass -File .\Instalar.ps1
#        ... -Escritorio -MenuInicio    tambien en esos sitios
#        ... -Quitar                    borra los accesos directos
# =====================================================================
param(
    [switch]$Escritorio,
    [switch]$MenuInicio,
    [switch]$Quitar
)

$ErrorActionPreference = 'Stop'

# Los mensajes llevan tildes y la consola de Windows arranca en su propia
# pagina de codigos: sin esto salen como 'aplicaci?n' al abrirlo con el .cmd.
try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false) } catch { }
$Raiz    = $PSScriptRoot
$Destino = Join-Path $Raiz 'VaporeraArcade.ps1'
$Nombre  = 'Vaporera Arcade.lnk'

# Windows PowerShell 5.1, no pwsh: la aplicacion usa WPF y -STA.
# En un proceso de 32 bits System32 se redirige a SysWOW64 y sale el
# powershell de 32 bits, que vale igual.
function Get-PowerShellExe {
    $p = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $p) { return $p }
    $c = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
}

# Las tres carpetas donde puede ir el acceso directo. La de la aplicacion
# siempre; las otras dos solo si se piden.
function Get-Ubicaciones {
    $lista = @([pscustomobject]@{ Sitio = 'la carpeta de la aplicación'; Ruta = $Raiz })
    if ($Escritorio) {
        $d = [Environment]::GetFolderPath('Desktop')
        if ($d) { $lista += [pscustomobject]@{ Sitio = 'el Escritorio'; Ruta = $d } }
    }
    if ($MenuInicio) {
        $m = [Environment]::GetFolderPath('Programs')
        if ($m) { $lista += [pscustomobject]@{ Sitio = 'el menú Inicio'; Ruta = $m } }
    }
    return $lista
}

if (-not (Test-Path -LiteralPath $Destino)) {
    Write-Host "No encuentro VaporeraArcade.ps1 junto a este script." -ForegroundColor Red
    Write-Host "Deja Instalar.ps1 en la misma carpeta que la aplicación."
    exit 1
}

# ---------------------------------------------------------------------
#  Quitar
# ---------------------------------------------------------------------
if ($Quitar) {
    $n = 0
    foreach ($u in (Get-Ubicaciones)) {
        $lnk = Join-Path $u.Ruta $Nombre
        if (Test-Path -LiteralPath $lnk) {
            try {
                Remove-Item -LiteralPath $lnk -Force
                Write-Host "Quitado el acceso directo en $($u.Sitio)." -ForegroundColor Green
                $n++
            } catch {
                Write-Host "No he podido borrar $lnk : $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
    if ($n -eq 0) { Write-Host "No había ningún acceso directo que quitar." }
    Write-Host ""
    Write-Host "Recuerda que los ajustes y el registro siguen en %LOCALAPPDATA%\VaporeraArcade."
    exit 0
}

# ---------------------------------------------------------------------
#  Instalar
# ---------------------------------------------------------------------
$exe = Get-PowerShellExe
if (-not $exe) {
    Write-Host "No encuentro powershell.exe. ¿Windows PowerShell está instalado?" -ForegroundColor Red
    exit 1
}

# Los ficheros bajados de internet vienen marcados y Windows se niega a
# ejecutarlos: esto es lo que el README pedia hacer a mano.
try {
    Get-ChildItem -LiteralPath $Raiz -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
    Write-Host "Ficheros desbloqueados."
} catch {
    Write-Host "No he podido desbloquear los ficheros: $($_.Exception.Message)" -ForegroundColor Yellow
}

try {
    $sh = New-Object -ComObject WScript.Shell
} catch {
    Write-Host "No he podido crear el acceso directo: falta el componente WScript.Shell." -ForegroundColor Red
    Write-Host "Puedes usar la aplicación de todas formas con:"
    Write-Host "  powershell -ExecutionPolicy Bypass -File .\VaporeraArcade.ps1"
    exit 1
}

$icono = Join-Path $Raiz 'docs\VaporeraArcade.ico'
$creados = 0

foreach ($u in (Get-Ubicaciones)) {
    $lnk = Join-Path $u.Ruta $Nombre
    try {
        $s = $sh.CreateShortcut($lnk)
        $s.TargetPath       = $exe
        $s.Arguments        = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + $Destino + '"'
        $s.WorkingDirectory = $Raiz
        $s.Description      = 'Añade a Steam los juegos de otras plataformas'
        # 7 = minimizada: reduce el parpadeo de la consola al arrancar
        $s.WindowStyle      = 7
        if (Test-Path -LiteralPath $icono) { $s.IconLocation = $icono }
        $s.Save()
        Write-Host "Creado el acceso directo en $($u.Sitio)." -ForegroundColor Green
        $creados++
    } catch {
        Write-Host "No he podido crear el acceso directo en $($u.Sitio): $($_.Exception.Message)" -ForegroundColor Red
        if ($u.Ruta -eq $Raiz) {
            Write-Host "Si la aplicación está en una carpeta protegida, prueba con -Escritorio." -ForegroundColor Yellow
        }
    }
}

[void][Runtime.InteropServices.Marshal]::ReleaseComObject($sh)

if ($creados -gt 0) {
    Write-Host ""
    Write-Host "Listo. Abre «Vaporera Arcade» con doble clic." -ForegroundColor Green
    Write-Host ""
    Write-Host "La aplicación se queda en esta carpeta:"
    Write-Host "  $Raiz"
    Write-Host "No la borres ni la muevas, o el acceso directo dejará de funcionar. Si la"
    Write-Host "mueves, vuelve a ejecutar este instalador desde su nueva ubicación."
} else {
    exit 1
}
