# =====================================================================
#  Config.ps1 - Ajustes del usuario
#
#  Se guardan en %LOCALAPPDATA%\VaporeraArcade\config.json, fuera de la
#  carpeta de la aplicacion: asi funciona aunque este instalada en una
#  ruta sin permiso de escritura y la clave nunca acaba en el repositorio.
# =====================================================================

function Get-ConfigRuta {
    return (Join-Path (Join-Path $env:LOCALAPPDATA 'VaporeraArcade') 'config.json')
}

# Devuelve los ajustes como hashtable (vacia si no hay fichero o esta roto)
function Get-Config {
    $cfg = @{}
    $f = Get-ConfigRuta
    if (Test-Path -LiteralPath $f) {
        try {
            $obj = [IO.File]::ReadAllText($f) | ConvertFrom-Json
            foreach ($p in $obj.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
        } catch { }
    }
    return $cfg
}

# Guarda un ajuste. Un valor vacio lo borra.
function Set-ConfigValor {
    param([Parameter(Mandatory)][string]$Nombre, $Valor)
    $cfg = Get-Config
    if ($null -eq $Valor -or [string]$Valor -eq '') { $cfg.Remove($Nombre) } else { $cfg[$Nombre] = $Valor }
    $f = Get-ConfigRuta
    $dir = Split-Path $f -Parent
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $json = New-Object PSObject -Property $cfg | ConvertTo-Json
    [IO.File]::WriteAllText($f, $json, (New-Object Text.UTF8Encoding($false)))
}
