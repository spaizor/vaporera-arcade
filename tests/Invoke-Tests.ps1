# =====================================================================
#  Invoke-Tests.ps1 - Lanza los tests de Vaporera Arcade con Pester 5
#
#    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1 [-Detalle]
#
#  Solo hace falta para desarrollar: la aplicacion no usa Pester y la carpeta tests\ no va en
#  el ZIP de las releases (export-ignore en .gitattributes).
#
#  Pester 5 no viene con Windows (trae la 3.4, de 2016, que no sirve). Se instala con
#    Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -SkipPublisherCheck
#  Si falla con "No se puede encontrar una parte de la ruta de acceso ...\Documents\...", es
#  el "Acceso controlado a carpetas" de Windows Defender, que no deja a PowerShell escribir en
#  Documentos. En vez de abrirle la mano a powershell.exe, se puede guardar fuera:
#    Save-Module Pester -MinimumVersion 5.0 -Path "$env:LOCALAPPDATA\PowerShellModules"
#  y este script lo encuentra ahi solo.
# =====================================================================
param([switch]$Detalle)

# La aplicacion es para Windows PowerShell 5.1: los tests tienen que correr en el mismo
# PowerShell, o no se veria nada de lo que solo falla en 5.1 (que es casi todo lo delicado).
if ($PSVersionTable.PSEdition -eq 'Core') {
    Write-Host 'Estos tests son para Windows PowerShell 5.1 (powershell.exe), no para PowerShell 7 (pwsh).' -ForegroundColor Red
    exit 2
}

$pester = Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge [version]'5.0' } |
          Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester) {
    $manifiesto = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'PowerShellModules\Pester\*\Pester.psd1') -ErrorAction SilentlyContinue |
                  Sort-Object { [version]$_.Directory.Name } -Descending | Select-Object -First 1
    if ($manifiesto -and [version]$manifiesto.Directory.Name -ge [version]'5.0') { $pester = $manifiesto.FullName }
}
if (-not $pester) {
    Write-Host 'No encuentro Pester 5. Mira la cabecera de este script para instalarlo.' -ForegroundColor Red
    exit 2
}
# la 3.4 de Windows puede estar ya cargada y se llama igual
Remove-Module Pester -ErrorAction SilentlyContinue
Import-Module $pester -Force -ErrorAction Stop

$cfg = New-PesterConfiguration
$cfg.Run.Path = $PSScriptRoot
$cfg.Run.PassThru = $true
$cfg.Output.Verbosity = if ($Detalle) { 'Detailed' } else { 'Normal' }
$res = Invoke-Pester -Configuration $cfg
if ($res.FailedCount -gt 0) { exit 1 }
exit 0
