# =====================================================================
#  CrearIcono.ps1 - Genera docs\VaporeraArcade.ico
#
#    powershell -NoProfile -ExecutionPolicy Bypass -File .\docs\CrearIcono.ps1 [-Vista <png>]
#
#  El icono se dibuja por codigo (GDI+), sin editores: una olla ("vaporera") con vapor y una
#  palanca de arcade por pomo de la tapa, en los colores de la ventana. Se dibuja en vectorial
#  a cada tamano, no se reduce el de 256: asi los pequenos salen nitidos.
#  El .ico lleva cada tamano como PNG dentro (valido desde Windows Vista). Lo usan el acceso
#  directo que crea CrearAccesoDirecto.ps1 y la ventana de la aplicacion.
#  -Vista guarda ademas una hoja con los tamanos, para revisarlo sin abrir el .ico.
#  Solo hace falta para cambiar el icono: no va en el ZIP de las releases.
# =====================================================================
param([string]$Vista = '')

Add-Type -AssemblyName System.Drawing
$Destino = Join-Path $PSScriptRoot 'VaporeraArcade.ico'
# 20, 24 y 40 son los del escalado al 125-150 %; sin ellos Windows reduce el siguiente y se
# ve borroso
$Tamanos = @(16, 20, 24, 32, 40, 48, 64, 256)

function Get-Color([string]$Hex, [int]$Alfa = 255) {
    $c = [Drawing.ColorTranslator]::FromHtml($Hex)
    return [Drawing.Color]::FromArgb($Alfa, $c.R, $c.G, $c.B)
}
# los de la ventana (XAML de VaporeraArcade.ps1)
$Rojo    = Get-Color '#DC1E23'
$RojoOsc = Get-Color '#7A1418'
$Claro   = Get-Color '#E6E8EC'
$Metal   = Get-Color '#B9BEC7'
$Fondo1  = Get-Color '#2A2E36'
$Fondo2  = Get-Color '#15171B'

function New-Redondeado([single]$X, [single]$Y, [single]$W, [single]$H, [single]$R) {
    $p = New-Object Drawing.Drawing2D.GraphicsPath
    $d = [single]($R * 2)
    $p.AddArc($X, $Y, $d, $d, 180, 90)
    $p.AddArc([single]($X + $W - $d), $Y, $d, $d, 270, 90)
    $p.AddArc([single]($X + $W - $d), [single]($Y + $H - $d), $d, $d, 0, 90)
    $p.AddArc($X, [single]($Y + $H - $d), $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

# Todo en coordenadas de 256x256; New-Icono escala al tamano pedido
function Invoke-Dibujo($G) {
    # fondo: cuadrado redondeado con degradado, como las baldosas de Windows 11
    $p = New-Redondeado 8 8 240 240 52
    $br = New-Object Drawing.Drawing2D.LinearGradientBrush((New-Object Drawing.PointF(0, 8)), (New-Object Drawing.PointF(0, 248)), $Fondo1, $Fondo2)
    $G.FillPath($br, $p); $br.Dispose(); $p.Dispose()

    # vapor: dos curvas en S a los lados de la palanca
    $pen = New-Object Drawing.Pen($Claro, 13)
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
    foreach ($x in @(70, 186)) {
        $G.DrawBezier($pen, (New-Object Drawing.PointF($x, 112)), (New-Object Drawing.PointF(($x - 20), 89)),
                            (New-Object Drawing.PointF(($x + 20), 69)), (New-Object Drawing.PointF($x, 46)))
    }
    $pen.Dispose()

    # olla: cuerpo, asas y tapa
    $rojo = New-Object Drawing.SolidBrush($Rojo)
    $cuerpo = New-Redondeado 52 150 152 70 18
    $G.FillPath($rojo, $cuerpo); $cuerpo.Dispose()
    $asa = New-Object Drawing.Pen($Rojo, 14)
    $asa.StartCap = 'Round'; $asa.EndCap = 'Round'
    $G.DrawLine($asa, 38, 166, 56, 166); $G.DrawLine($asa, 200, 166, 218, 166)
    $asa.Dispose()
    $oscuro = New-Object Drawing.SolidBrush($RojoOsc)
    $tapa = New-Redondeado 44 136 168 18 9
    $G.FillPath($oscuro, $tapa); $tapa.Dispose(); $oscuro.Dispose()

    # palanca de arcade por pomo: palo, bola y brillo
    $metal = New-Object Drawing.SolidBrush($Metal)
    $G.FillRectangle($metal, 121, 84, 14, 56); $metal.Dispose()
    $G.FillEllipse($rojo, 98, 44, 60, 60); $rojo.Dispose()
    $brillo = New-Object Drawing.SolidBrush((Get-Color '#FFFFFF' 110))
    $G.FillEllipse($brillo, 111, 54, 20, 14); $brillo.Dispose()
}

function New-Icono([int]$Lado) {
    $bm = New-Object Drawing.Bitmap -ArgumentList $Lado, $Lado, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($bm)
    $g.SmoothingMode = 'AntiAlias'; $g.PixelOffsetMode = 'HighQuality'
    $g.Clear([Drawing.Color]::Transparent)
    $g.ScaleTransform([single]($Lado / 256), [single]($Lado / 256))
    Invoke-Dibujo $g
    $g.Dispose()
    return $bm
}

# --- el .ico: cabecera (6 bytes), una entrada de 16 bytes por tamano y los PNG detras ---
$pngs = @()
foreach ($t in $Tamanos) {
    $bm = New-Icono $t
    $ms = New-Object IO.MemoryStream
    try { $bm.Save($ms, [Drawing.Imaging.ImageFormat]::Png); $pngs += ,$ms.ToArray() }
    finally { $ms.Dispose(); $bm.Dispose() }
}
$salida = New-Object IO.MemoryStream
$bw = New-Object IO.BinaryWriter($salida)
try {
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$Tamanos.Count)
    $offset = 6 + 16 * $Tamanos.Count
    for ($i = 0; $i -lt $Tamanos.Count; $i++) {
        $lado = [byte]($Tamanos[$i] % 256)              # 256 se escribe como 0
        $bw.Write($lado); $bw.Write($lado)
        $bw.Write([byte]0); $bw.Write([byte]0)          # sin paleta, reservado
        $bw.Write([uint16]1); $bw.Write([uint16]32)     # planos, bits por pixel
        $bw.Write([uint32]$pngs[$i].Length); $bw.Write([uint32]$offset)
        $offset += $pngs[$i].Length
    }
    foreach ($png in $pngs) { $bw.Write($png) }
    $bw.Flush()
    [IO.File]::WriteAllBytes($Destino, $salida.ToArray())
} finally { $bw.Dispose(); $salida.Dispose() }
Write-Host "Creado $Destino ($($Tamanos -join ', ') px)"

if ($Vista) {
    # cada tamano a su medida real, sobre claro y sobre un escritorio azul
    $hoja = New-Object Drawing.Bitmap(620, 380)
    $g = [Drawing.Graphics]::FromImage($hoja)
    $g.Clear([Drawing.Color]::White)
    $fondoAzul = New-Object Drawing.SolidBrush((Get-Color '#1F4E79'))
    $g.FillRectangle($fondoAzul, 0, 280, 620, 100); $fondoAzul.Dispose()
    $x = 10
    foreach ($t in $Tamanos) {
        $bm = New-Icono $t
        $g.DrawImageUnscaled($bm, $x, (270 - $t))
        if ($t -le 64) { $g.DrawImageUnscaled($bm, $x, (370 - $t)) }
        $bm.Dispose()
        $x += [Math]::Min($t, 256) + 8
    }
    $g.Dispose(); $hoja.Save($Vista); $hoja.Dispose()
    Write-Host "Vista previa en $Vista"
}
