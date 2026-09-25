# =====================================================================
#  Vaporera Arcade  -  Anadir juegos de otras plataformas a Steam
#
#  Detecta los juegos instalados (Xbox/Game Pass, Ubisoft, Epic, GOG,
#  apps de la Store y programas ejecutados hace poco), descarga las
#  caratulas oficiales y escribe el acceso directo en shortcuts.vdf.
#
#  Uso:  .\VaporeraArcade.ps1   (o el acceso directo que crea CrearAccesoDirecto.ps1)
# =====================================================================
$ErrorActionPreference = 'Stop'

# Version de la aplicacion. Sale en el titulo de la ventana, junto al nombre de la cabecera, en
# la primera linea del registro y en el historial del README.md: los cuatro tienen que ir
# sincronizados. El XAML es una cadena literal y no interpola: la ventana la pone por codigo.
$AppVersion = '0.8'

$Raiz = Split-Path -Parent $MyInvocation.MyCommand.Path
$TempDir = Join-Path $env:TEMP 'VaporeraArcade'

# El registro va en %LOCALAPPDATA%, igual que config.json: instalada en Program Files la
# aplicacion no puede escribir en su propia carpeta. La ruta se calcula aqui a mano porque
# lib\Config.ps1 (Get-ConfigRuta) todavia no esta cargado.
$DatosDir = $Raiz
if ($env:LOCALAPPDATA) { $DatosDir = Join-Path $env:LOCALAPPDATA 'VaporeraArcade' }
$LogFile = Join-Path $DatosDir 'vaporera-arcade.log'

# El registro y el aviso de errores van antes de cargar lib\: tienen que funcionar aunque falle eso
function Write-Registro {
    param([string]$Texto)
    $linea = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Texto
    try {
        $dir = Split-Path $LogFile -Parent
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        Add-Content -LiteralPath $LogFile -Value $linea -Encoding UTF8
    } catch { }
}

# Se llama una vez al arrancar. Pasado el limite, el registro actual pasa a ser el .log.1
# (pisando el anterior) y se empieza uno nuevo: nunca ocupan mas del doble del limite entre
# los dos y el .1 conserva lo ultimo por si hace falta para un informe. Devuelve si ha rotado.
function Invoke-RotarRegistro {
    param([long]$MaxBytes = 1MB)
    try {
        $f = Get-Item -LiteralPath $LogFile -ErrorAction Stop
        if ($f.Length -lt $MaxBytes) { return $false }
        Move-Item -LiteralPath $LogFile -Destination "$LogFile.1" -Force -ErrorAction Stop
        return $true
    } catch { return $false }
}

# Guarda un error con su detalle tecnico (fichero y linea) para poder diagnosticarlo
function Write-RegistroError {
    param([string]$Contexto, $Fallo)
    Write-Registro "ERROR en $Contexto : $($Fallo.Exception.Message)"
    $pos = $Fallo.InvocationInfo.PositionMessage
    if ($pos) { foreach ($l in ($pos -split "`r?`n")) { if ($l.Trim()) { Write-Registro "    $($l.Trim())" } } }
    if ($Fallo.Exception.InnerException) { Write-Registro "    causa: $($Fallo.Exception.InnerException.Message)" }
}

function Show-AvisoError {
    param([string]$Texto)
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show($Texto, 'Vaporera Arcade - Error', 'OK', 'Error')
    } catch {
        # si ni siquiera carga Windows Forms, el cuadro basico de Windows
        try { [void](New-Object -ComObject WScript.Shell).Popup($Texto, 0, 'Vaporera Arcade - Error', 16) } catch { }
    }
}

# Cualquier error sin controlar (una lib que no carga, el XAML, Add-Type...) acaba aqui.
# Lanzado desde el acceso directo la ventana de PowerShell va oculta: sin esto, la aplicacion
# no aparece y no se ve por que.
trap {
    $fallo = $_
    Write-RegistroError -Contexto 'error sin controlar' -Fallo $fallo
    # la causa raiz es mas corta (con el XAML roto, el mensaje de fuera incluye el XAML entero)
    $lineas = @($fallo.Exception.GetBaseException().Message -split "`r?`n")
    $resumen = ($lineas | Select-Object -First 8) -join "`r`n"
    if ($lineas.Count -gt 8) { $resumen += "`r`n(...)" }
    $texto = "Vaporera Arcade $AppVersion se ha cerrado por un error inesperado:`r`n`r`n$resumen"
    if ($fallo.InvocationInfo -and $fallo.InvocationInfo.ScriptName) {
        $texto += "`r`n`r`n($(Split-Path $fallo.InvocationInfo.ScriptName -Leaf), línea $($fallo.InvocationInfo.ScriptLineNumber))"
    }
    $texto += "`r`n`r`nDetalle en el registro:`r`n$LogFile"
    Show-AvisoError $texto
    exit 1
}

# Primera linea del registro en cada arranque. Es lo que hay que pedir en un informe de fallo:
# sin la version, un log ajeno no dice de que codigo viene.
$registroRotado = Invoke-RotarRegistro
Write-Registro "=== Vaporera Arcade $AppVersion | PowerShell $($PSVersionTable.PSVersion) | Windows $([Environment]::OSVersion.Version) ==="
if ($registroRotado) { Write-Registro "El registro anterior pasaba de 1 MB: se ha movido a $(Split-Path $LogFile -Leaf).1" }

. (Join-Path $Raiz 'lib\Config.ps1')
. (Join-Path $Raiz 'lib\Vdf.ps1')
. (Join-Path $Raiz 'lib\Fuentes.ps1')
. (Join-Path $Raiz 'lib\Caratulas.ps1')
. (Join-Path $Raiz 'lib\SteamCtl.ps1')

# Busqueda de texto sin comodines: con -like un '[' en el filtro da error
function Test-Contiene {
    param([string]$Texto, [string]$Buscado)
    return ($Texto.IndexOf($Buscado, [StringComparison]::OrdinalIgnoreCase) -ge 0)
}

# =====================================================================
#  Nucleo: caratulas, anadir y quitar
# =====================================================================

# Las imagenes que Steam no puede dejar de tener: sin ellas el juego sale en blanco
$ImagenesClave = [ordered]@{ p = 'portada'; cap = 'cápsula'; hero = 'cabecera' }

# Deja las imagenes en config\grid\: copia las que preparo la vista previa o, si no llega
# ninguna, las genera al vuelo. Devuelve Ok (estan las tres imprescindibles), la ruta del _icon.png (la que
# va al campo 'icon' del VDF) y las que falten.
function Invoke-Caratulas {
    param(
        [Parameter(Mandatory)]$Juego,
        [Parameter(Mandatory)][string]$Nombre,
        [Parameter(Mandatory)][uint32]$AppId,
        [Parameter(Mandatory)]$Steam,
        [hashtable]$CaratulasListas = $null,
        [string]$OrigenArte = 'Automatico',
        [scriptblock]$Log = $null
    )
    function Registrar($m) { if ($Log) { & $Log $m | Out-Null } else { Write-Registro $m } }

    # las que hayan quedado de verdad en config\grid\, para saber si se puede decir que esta listo
    function Get-Informe($Rutas, $Icono) {
        $faltan = @()
        foreach ($k in $ImagenesClave.Keys) {
            if (-not $Rutas[$k] -or -not (Test-Path -LiteralPath $Rutas[$k])) { $faltan += $ImagenesClave[$k] }
        }
        return [pscustomobject]@{ Ok = ($faltan.Count -eq 0); Icono = $Icono; Faltan = $faltan }
    }

    if (-not $CaratulasListas -or -not $CaratulasListas.Count) {
        $c = New-CaratulasSteam -Juego $Juego -AppId $AppId -GridDir $Steam.GridDir -NombreFinal $Nombre `
                -OrigenArte $OrigenArte -Log $Log
        Registrar "Carátulas: $($c.Origen)"
        return (Get-Informe -Rutas $c.Rutas -Icono $c.Rutas['icon'])
    }

    # en un PC recien estrenado config\grid\ todavia no existe: hay que crearla
    if (-not (Test-Path -LiteralPath $Steam.GridDir)) {
        [void](New-Item -ItemType Directory -Path $Steam.GridDir -Force)
        Registrar "Creada la carpeta config\grid\ (no existía)."
    }
    $copiadas = 0
    $puestas = @{}
    $finales = @{}
    foreach ($k in $CaratulasListas.Keys) {
        $origenImg = $CaratulasListas[$k]
        if (-not (Test-Path -LiteralPath $origenImg)) { Registrar "  falta la imagen '$k', me la salto."; continue }
        $hoja = Split-Path $origenImg -Leaf
        $destino = Join-Path $Steam.GridDir $hoja
        try {
            Copy-Item -LiteralPath $origenImg -Destination $destino -Force
            $copiadas++; $puestas[$hoja] = $true; $finales[$k] = $destino
        }
        catch { Registrar "  no he podido copiar '$k': $($_.Exception.Message)" }
    }
    # lo que esta vez no se ha generado (un _logo.png que no valia, por ejemplo) se quita:
    # si no, Steam seguiria usando el de un intento anterior
    foreach ($n in @("${AppId}p.png", "${AppId}.png", "${AppId}_hero.png", "${AppId}_logo.png", "${AppId}_icon.png")) {
        if ($puestas.ContainsKey($n)) { continue }
        $viejo = Join-Path $Steam.GridDir $n
        if (Test-Path -LiteralPath $viejo) {
            Remove-Item -LiteralPath $viejo -Force -ErrorAction SilentlyContinue
            Registrar "  quitada la imagen antigua $n"
        }
    }
    Registrar "Carátulas copiadas a config\grid\ ($copiadas de $($CaratulasListas.Count) imágenes)."
    return (Get-Informe -Rutas $finales -Icono $finales['icon'])
}

function Invoke-AnadirJuego {
    param(
        [Parameter(Mandatory)]$Juego,
        [Parameter(Mandatory)][string]$Nombre,
        [Parameter(Mandatory)]$Steam,
        [switch]$Reemplazar,
        [switch]$AbrirBigPicture,
        [switch]$NoReabrirSteam,
        [hashtable]$CaratulasListas = $null,
        [ValidateSet('Automatico','Store','SteamGridDB','Local')][string]$OrigenArte = 'Automatico',
        [scriptblock]$Log = $null
    )
    # si hay $Log, el propio bloque ya escribe en el fichero: asi no se duplican lineas
    function Registrar($m) { if ($Log) { & $Log $m | Out-Null } else { Write-Registro $m } }

    $appId = Get-SteamShortcutAppId -ExeQuoted ('"' + $Juego.Exe + '"') -AppName $Nombre
    Registrar "=== $Nombre ==="
    Registrar "Origen : $($Juego.Fuente)"
    Registrar "Exe    : $($Juego.Exe)"
    if ($Juego.LaunchOptions) { Registrar "Opciones: $($Juego.LaunchOptions)" }
    Registrar "AppId  : $appId"

    # el duplicado se mira antes de cerrar Steam: si no hay nada que escribir, no se cierra
    if (-not $Reemplazar) {
        $dup = Test-ShortcutDuplicado -RutaVdf $Steam.Shortcuts -Nombre $Nombre -Exe $Juego.Exe -LaunchOptions $Juego.LaunchOptions
        if ($null -ne $dup) {
            Registrar "Ya existe un acceso directo igual (entrada $dup). No se ha tocado nada."
            return [pscustomobject]@{ Ok = $false; AppId = $appId; Motivo = 'duplicado'; CaratulasOk = $false }
        }
    }

    $estabaAbierto = Test-SteamCorriendo
    if (-not (Stop-SteamYEsperar -SteamExe $Steam.Exe -Log $Log)) {
        Registrar 'ABORTADO: Steam no se ha cerrado. Ciérralo a mano y repite.'
        return [pscustomobject]@{ Ok = $false; AppId = $appId; Motivo = 'steam-abierto'; CaratulasOk = $false }
    }

    # a partir de aqui Steam esta cerrado: pase lo que pase, se vuelve a abrir en el finally
    $escrito = $false
    try {
        # Otra vez, ahora con Steam cerrado: al salir reescribe shortcuts.vdf y lo leido antes
        # puede haber cambiado. Tiene que ir antes de copiar las imagenes: con un duplicado del
        # mismo appid, copiarlas machacaria las del acceso directo que ya existe.
        if (-not $Reemplazar) {
            $dup = Test-ShortcutDuplicado -RutaVdf $Steam.Shortcuts -Nombre $Nombre -Exe $Juego.Exe -LaunchOptions $Juego.LaunchOptions
            if ($null -ne $dup) {
                Registrar "Ya existe un acceso directo igual (entrada $dup). No se ha tocado nada."
                return [pscustomobject]@{ Ok = $false; AppId = $appId; Motivo = 'duplicado'; CaratulasOk = $false }
            }
        }

        $bak = Backup-Shortcuts -Ruta $Steam.Shortcuts -Log $Log
        if ($bak) { Registrar "Copia de seguridad: $(Split-Path $bak -Leaf)" }

        # Las caratulas van ANTES de escribir el VDF: Steam no busca el icono por el nombre del
        # fichero, lo saca del campo 'icon' de la entrada, y hasta que no estan generadas no se
        # sabe si hay _icon.png. Si fallan se anade el juego igual: sin caratula se ve, sin
        # acceso directo no.
        $icono = $Juego.Icono
        $arte = $null
        try {
            $arte = Invoke-Caratulas -Juego $Juego -Nombre $Nombre -AppId $appId -Steam $Steam `
                        -CaratulasListas $CaratulasListas -OrigenArte $OrigenArte -Log $Log
            if ($arte.Icono -and (Test-Path -LiteralPath $arte.Icono)) { $icono = $arte.Icono }
        } catch {
            Registrar "Las carátulas han fallado: $($_.Exception.Message). Sigo con el acceso directo."
            Write-RegistroError -Contexto 'generar carátulas' -Fallo $_
        }
        $arteOk = [bool]($arte -and $arte.Ok)

        $r = Add-SteamShortcut -RutaVdf $Steam.Shortcuts -Nombre $Nombre -Exe $Juego.Exe `
                -StartDir $Juego.StartDir -Icono $icono -LaunchOptions $Juego.LaunchOptions `
                -Reemplazar:$Reemplazar -Log $Log
        if (-not $r.Ok) {
            # con la comprobacion de arriba no deberia pasar; si pasa, las imagenes recien
            # copiadas no son de nadie (salvo que el duplicado tenga el mismo appid)
            Registrar "Ya existe un acceso directo igual (entrada $($r.Indice)). No se ha tocado nada."
            [void](Remove-CaratulasHuerfanas -RutaVdf $Steam.Shortcuts -GridDir $Steam.GridDir -AppId $appId -Log $Log)
            return [pscustomobject]@{ Ok = $false; AppId = $appId; Motivo = 'duplicado'; CaratulasOk = $false }
        }
        $escrito = $true

        # al reemplazar una entrada de otro appid, sus imagenes ya no las usa nadie
        if ($null -ne $r.AppIdAnterior -and $r.AppIdAnterior -ne $appId) {
            [void](Remove-CaratulasHuerfanas -RutaVdf $Steam.Shortcuts -GridDir $Steam.GridDir -AppId $r.AppIdAnterior -Log $Log)
        }

        if ($arteOk) {
            Registrar "LISTO. '$Nombre' ya está en la biblioteca."
        } else {
            # el acceso directo esta, que es lo que importa, pero sin decir que todo ha ido bien
            $queFalta = if ($arte -and $arte.Faltan.Count) { "falta " + ($arte.Faltan -join ', ') } else { 'no hay carátulas' }
            Registrar "'$Nombre' ya está en la biblioteca, pero las carátulas no están completas ($queFalta)."
            Registrar 'Steam lo mostrará sin imagen. Puedes volver a intentarlo con "Reemplazar si ya existe".'
        }
        return [pscustomobject]@{ Ok = $true; AppId = $appId; Motivo = ''; CaratulasOk = $arteOk }
    } catch {
        if ($escrito) { Registrar 'El acceso directo ya está escrito, pero algo ha fallado después (ver el error).' }
        else {
            Registrar 'Algo ha fallado antes de terminar de escribir.'
            # las imagenes ya copiadas se quedarian sin acceso directo (si al reemplazar sigue
            # la entrada vieja con el mismo appid, son suyas y no se tocan)
            [void](Remove-CaratulasHuerfanas -RutaVdf $Steam.Shortcuts -GridDir $Steam.GridDir -AppId $appId -Log $Log)
        }
        # el aviso de la copia de seguridad, siempre que exista: antes solo salia en una rama
        if ($bak) { Registrar "Si shortcuts.vdf quedara mal, restaura la copia: $bak" }
        throw
    } finally {
        # tras escribir se abre siempre (el usuario querra verlo); si no, solo si estaba abierto
        if (-not $NoReabrirSteam -and ($escrito -or $estabaAbierto)) {
            Start-Steam -SteamExe $Steam.Exe -BigPicture:$AbrirBigPicture -Log $Log
        }
    }
}

# Quita de shortcuts.vdf el acceso directo que corresponde a $Juego (el mismo criterio que la
# marca 'YA EN STEAM': nombre igual, o exe con las mismas opciones) y sus imagenes de
# config\grid\. La confirmacion es cosa de quien llama.
function Invoke-QuitarJuego {
    param(
        [Parameter(Mandatory)]$Juego,
        [Parameter(Mandatory)]$Steam,
        [switch]$AbrirBigPicture,
        [switch]$NoReabrirSteam,
        [scriptblock]$Log = $null
    )
    function Registrar($m) { if ($Log) { & $Log $m | Out-Null } else { Write-Registro $m } }

    $estabaAbierto = Test-SteamCorriendo
    if (-not (Stop-SteamYEsperar -SteamExe $Steam.Exe -Log $Log)) {
        Registrar 'ABORTADO: Steam no se ha cerrado. Ciérralo a mano y repite.'
        return [pscustomobject]@{ Ok = $false; Motivo = 'steam-abierto' }
    }

    $bak = $null
    try {
        # se busca con Steam ya cerrado: al salir reescribe el fichero y las claves pueden cambiar
        $existentes = @(Get-ShortcutsExistentes -Ruta $Steam.Shortcuts)
        $indice = Find-ShortcutDuplicado -Existentes $existentes -Nombre $Juego.Nombre -Exe $Juego.Exe -LaunchOptions $Juego.LaunchOptions
        if ($null -eq $indice) {
            Registrar "No hay ningún acceso directo de '$($Juego.Nombre)' en Steam. No se ha tocado nada."
            return [pscustomobject]@{ Ok = $false; Motivo = 'no-esta' }
        }
        $entrada = $existentes | Where-Object { $_.Indice -eq $indice } | Select-Object -First 1
        Registrar "=== Quitar $($entrada.Nombre) ==="

        $bak = Backup-Shortcuts -Ruta $Steam.Shortcuts -Log $Log
        if ($bak) { Registrar "Copia de seguridad: $(Split-Path $bak -Leaf)" }

        $quitados = @(Remove-SteamShortcut -RutaVdf $Steam.Shortcuts -Indice $indice)
        foreach ($a in $quitados) {
            [void](Remove-CaratulasHuerfanas -RutaVdf $Steam.Shortcuts -GridDir $Steam.GridDir -AppId $a -Log $Log)
        }
        Registrar "LISTO. '$($entrada.Nombre)' ya no está en la biblioteca."
        return [pscustomobject]@{ Ok = $true; Motivo = '' }
    } catch {
        if ($bak) { Registrar "Si shortcuts.vdf quedara mal, restaura la copia: $bak" }
        throw
    } finally {
        # aqui no se abre si no estaba abierto: al quitar no hay nada nuevo que ir a ver
        if (-not $NoReabrirSteam -and $estabaAbierto) {
            Start-Steam -SteamExe $Steam.Exe -BigPicture:$AbrirBigPicture -Log $Log
        }
    }
}

# =====================================================================
#  GUI (WPF)
# =====================================================================
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Drawing

# El de la ventana, la de Ajustes y la barra de tareas; sin el sale el de PowerShell. Si falta
# o no se puede leer se queda ese: no es motivo para no arrancar. Del .ico WPF coge solo el
# tamano que necesita en cada sitio. Lo genera docs\CrearIcono.ps1.
$script:IconoVentana = $null
$icoApp = Join-Path $Raiz 'docs\VaporeraArcade.ico'
if (Test-Path -LiteralPath $icoApp) {
    try { $script:IconoVentana = [Windows.Media.Imaging.BitmapFrame]::Create((New-Object Uri($icoApp))) }
    catch { Write-Registro "No he podido cargar el icono de la ventana: $($_.Exception.Message)" }
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Vaporera Arcade" Height="668" Width="1060"
        MinHeight="480" MinWidth="820"
        WindowStartupLocation="CenterScreen" Background="#FF15171B">
  <Window.Resources>
    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="#FFE6E8EC"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#FFB9BEC7"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="Margin" Value="0,4,14,4"/>
    </Style>
    <!-- El ComboBox necesita plantilla propia: el tema de Windows pinta su cuadro de blanco
         pase lo que pase en Background, y el texto claro encima no se lee. -->
    <Style TargetType="ComboBox">
      <Setter Property="Background" Value="#FF1E2127"/>
      <Setter Property="Foreground" Value="#FFE6E8EC"/>
      <Setter Property="BorderBrush" Value="#FF3A3F49"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="Height" Value="30"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                      BorderThickness="1" SnapsToDevicePixels="True"/>
              <ToggleButton Focusable="False" ClickMode="Press" Background="Transparent"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border Background="Transparent">
                      <Path HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,10,0"
                            Data="M 0 0 L 4 4 L 8 0 Z" Fill="#FFB9BEC7"/>
                    </Border>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter Margin="8,0,26,0" VerticalAlignment="Center" HorizontalAlignment="Left"
                                IsHitTestVisible="False" TextElement.Foreground="{TemplateBinding Foreground}"
                                Content="{TemplateBinding SelectionBoxItem}"
                                ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"/>
              <Popup IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom" Focusable="False"
                     AllowsTransparency="True" PopupAnimation="None">
                <Border Background="#FF1E2127" BorderBrush="#FF3A3F49" BorderThickness="1"
                        MinWidth="{TemplateBinding ActualWidth}">
                  <ScrollViewer MaxHeight="{TemplateBinding MaxDropDownHeight}">
                    <ItemsPresenter/>
                  </ScrollViewer>
                </Border>
              </Popup>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ComboBoxItem">
      <Setter Property="Background" Value="#FF1E2127"/>
      <Setter Property="Foreground" Value="#FFE6E8EC"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <!-- sin esto, el elemento bajo el raton sale con el azul claro del sistema -->
            <Border Name="Bd" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}"
                    SnapsToDevicePixels="True">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#FF2E3440"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#FF262A31"/>
      <Setter Property="Foreground" Value="#FFE6E8EC"/>
      <Setter Property="BorderBrush" Value="#FF3A3F49"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
    </Style>
  </Window.Resources>

  <Grid Margin="14">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="96"/>
    </Grid.RowDefinitions>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="380"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <!-- cabecera -->
    <Grid Grid.Row="0" Grid.ColumnSpan="2" Margin="0,0,0,10">
      <StackPanel>
        <StackPanel Orientation="Horizontal">
          <TextBlock Text="Vaporera Arcade" FontSize="20" FontWeight="SemiBold" Foreground="#FFDC1E23"/>
          <TextBlock Name="TxtVersion" FontSize="11" Foreground="#FF6E747E" Margin="7,0,0,3"
                     VerticalAlignment="Bottom"/>
        </StackPanel>
        <TextBlock Name="TxtSteam" Text="" FontSize="11" Foreground="#FF8A909B" Margin="0,2,0,0"/>
      </StackPanel>
      <Button Name="BtnAjustes" Content="Ajustes..." HorizontalAlignment="Right" VerticalAlignment="Center"
              Padding="10,3" Margin="0"/>
    </Grid>

    <!-- lista -->
    <Grid Grid.Row="1" Grid.Column="0" Margin="0,0,14,0">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>
      <TextBlock Grid.Row="0" Text="Buscar por nombre" FontSize="11" Foreground="#FF8A909B" Margin="0,0,0,3"/>
      <TextBox Name="TxtBuscar" Grid.Row="1" Height="30" FontSize="14" Padding="6,4"
               Background="#FF1E2127" Foreground="#FFE6E8EC" BorderBrush="#FF3A3F49"
               VerticalContentAlignment="Center"/>
      <WrapPanel Grid.Row="2" Margin="0,8,0,8">
        <CheckBox Name="ChkRecientes" Content="Programas recientes"/>
        <CheckBox Name="ChkApps" Content="Apps de la Store"/>
        <Button Name="BtnRefrescar" Content="Refrescar" Padding="10,3"/>
        <Button Name="BtnExaminar" Content="Examinar .exe..." Padding="10,3"/>
      </WrapPanel>
      <ListBox Name="LstJuegos" Grid.Row="3" Background="#FF1E2127" BorderBrush="#FF3A3F49"
               Foreground="#FFE6E8EC" ScrollViewer.HorizontalScrollBarVisibility="Disabled">
        <ListBox.ItemTemplate>
          <DataTemplate>
            <StackPanel Margin="2,4">
              <TextBlock Text="{Binding Nombre}" FontSize="14"/>
              <TextBlock FontSize="11" Foreground="#FF8A909B">
                <Run Text="{Binding Fuente, Mode=OneWay}"/><Run Text="   "/><Run Text="{Binding Marca, Mode=OneWay}"/>
              </TextBlock>
            </StackPanel>
          </DataTemplate>
        </ListBox.ItemTemplate>
      </ListBox>
    </Grid>

    <!-- detalle -->
    <ScrollViewer Grid.Row="1" Grid.Column="1" VerticalScrollBarVisibility="Auto">
    <StackPanel>
      <TextBlock Text="Nombre en la biblioteca" FontSize="11" Foreground="#FF8A909B"/>
      <TextBox Name="TxtNombre" Height="30" FontSize="15" Padding="6,4" Margin="0,3,0,10"
               Background="#FF1E2127" Foreground="#FFE6E8EC" BorderBrush="#FF3A3F49"
               VerticalContentAlignment="Center"/>
      <TextBlock Text="Ejecutable" FontSize="11" Foreground="#FF8A909B"/>
      <TextBox Name="TxtExe" Height="28" Margin="0,3,0,10" IsReadOnly="True"
               Background="#FF1A1D22" Foreground="#FFB9BEC7" BorderBrush="#FF2A2E36"/>
      <TextBlock Text="Opciones de lanzamiento" FontSize="11" Foreground="#FF8A909B"/>
      <TextBox Name="TxtOpciones" Height="28" Margin="0,3,0,10"
               Background="#FF1E2127" Foreground="#FFE6E8EC" BorderBrush="#FF3A3F49"/>
      <TextBlock Name="TxtDetalle" FontSize="11" Foreground="#FF8A909B" TextWrapping="Wrap" Margin="0,0,0,12"/>

      <TextBlock Text="Origen de las carátulas" FontSize="11" Foreground="#FF8A909B"/>
      <ComboBox Name="CmbOrigenArte" Margin="0,3,0,12" SelectedIndex="0">
        <ComboBoxItem Tag="Automatico"  Content="Automático: Store, luego SteamGridDB, luego las del juego"/>
        <ComboBoxItem Tag="Store"       Content="Solo Microsoft Store"/>
        <ComboBoxItem Tag="SteamGridDB" Content="Solo SteamGridDB"/>
        <ComboBoxItem Tag="Local"       Content="Solo imágenes del propio juego"/>
      </ComboBox>

      <WrapPanel Margin="0,0,0,12">
        <Button Name="BtnPreparar" Content="1. Preparar carátulas" Background="#FF2E3440"/>
        <Button Name="BtnAnadir" Content="2. Añadir a Steam" IsEnabled="False" Background="#FF7A1418"/>
        <Button Name="BtnQuitar" Content="Quitar de Steam" IsEnabled="False"/>
      </WrapPanel>

      <TextBlock Name="TxtOrigenArte" FontSize="11" Foreground="#FF8A909B" Margin="0,0,0,6"/>
      <StackPanel Orientation="Horizontal">
        <StackPanel Margin="0,0,14,0">
          <TextBlock Text="Portada 600x900" FontSize="10" Foreground="#FF6E747E"/>
          <Border BorderBrush="#FF3A3F49" BorderThickness="1" Margin="0,3,0,0">
            <Image Name="ImgPortada" Width="140" Height="210" Stretch="UniformToFill"/>
          </Border>
        </StackPanel>
        <StackPanel>
          <TextBlock Text="Cápsula 460x215" FontSize="10" Foreground="#FF6E747E"/>
          <Border BorderBrush="#FF3A3F49" BorderThickness="1" Margin="0,3,0,10">
            <Image Name="ImgCapsula" Width="195" Height="91" Stretch="UniformToFill"/>
          </Border>
          <TextBlock Text="Hero 1920x620" FontSize="10" Foreground="#FF6E747E"/>
          <Border BorderBrush="#FF3A3F49" BorderThickness="1" Margin="0,3,0,0">
            <Image Name="ImgHero" Width="280" Height="90" Stretch="UniformToFill"/>
          </Border>
        </StackPanel>
      </StackPanel>
    </StackPanel>
    </ScrollViewer>

    <!-- registro -->
    <Grid Grid.Row="2" Grid.ColumnSpan="2" Margin="0,12,0,0">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>
      <WrapPanel Grid.Row="0">
        <CheckBox Name="ChkBigPicture" Content="Reabrir Steam en Big Picture" IsChecked="True"/>
        <CheckBox Name="ChkReemplazar" Content="Reemplazar si ya existe"/>
      </WrapPanel>
      <TextBox Name="TxtLog" Grid.Row="1" Margin="0,6,0,0" IsReadOnly="True" FontFamily="Consolas"
               FontSize="11" Background="#FF111316" Foreground="#FF9CD1A0" BorderBrush="#FF2A2E36"
               VerticalScrollBarVisibility="Auto" TextWrapping="NoWrap"/>
    </Grid>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$win = [Windows.Markup.XamlReader]::Load($reader)

$ctl = @{}
foreach ($n in @('TxtVersion','TxtSteam','BtnAjustes','TxtBuscar','ChkRecientes','ChkApps','BtnRefrescar','BtnExaminar','LstJuegos',
                 'TxtNombre','TxtExe','TxtOpciones','TxtDetalle','CmbOrigenArte','BtnPreparar','BtnAnadir','BtnQuitar','TxtOrigenArte',
                 'ImgPortada','ImgCapsula','ImgHero','ChkBigPicture','ChkReemplazar','TxtLog')) {
    $ctl[$n] = $win.FindName($n)
}

$script:Steam = Get-SteamInfo
$script:Todos = @()        # lo que se ve en la lista: los de 'Examinar' y detras lo detectado
$script:Detectados = @()   # lo que devolvio la ultima busqueda
$script:Manuales = @()     # los elegidos con 'Examinar .exe...', que la busqueda no encuentra
$script:Preparado = $null
$script:CambiandoJuego = $false   # true mientras la seleccion rellena los cuadros de texto
$script:Ocupado = $false          # true mientras hay una operacion larga en marcha

function Add-Log {
    param([string]$Texto)
    Write-Registro $Texto
    $ctl.TxtLog.AppendText($Texto + "`r`n")
    $ctl.TxtLog.ScrollToEnd()
    Update-Interfaz
}
$LogGui = { param($m) Add-Log $m }

function Update-Interfaz {
    $frame = New-Object Windows.Threading.DispatcherFrame
    [void][Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
        [Windows.Threading.DispatcherPriority]::Background, [action]{ $frame.Continue = $false })
    [Windows.Threading.Dispatcher]::PushFrame($frame)
}

# Lo que se desactiva mientras dura una operacion larga. El cuadro del registro NO esta en la
# lista: es lo unico que el usuario mira mientras espera, y desactivado se lee gris.
$ControlesInteractivos = @('BtnAjustes','TxtBuscar','ChkRecientes','ChkApps','BtnRefrescar','BtnExaminar',
                           'LstJuegos','TxtNombre','TxtOpciones','CmbOrigenArte','BtnPreparar','BtnAnadir',
                           'BtnQuitar','ChkBigPicture','ChkReemplazar')

# Un solo sitio decide que botones estan vivos. Antes lo hacia cada evento por su cuenta y no
# se puede combinar con Invoke-Ocupado, que al terminar reactiva todo a la vez.
function Update-Botones {
    # en plena operacion todo esta desactivado; Invoke-Ocupado lo vuelve a llamar al terminar
    if ($script:Ocupado) { return }
    $ctl.BtnPreparar.IsEnabled = [bool]$script:Steam
    $ctl.BtnAnadir.IsEnabled   = ([bool]$script:Steam -and $null -ne $script:Preparado)
    # solo tiene sentido con un juego que ya tenga acceso directo (la marca 'YA EN STEAM')
    $sel = $ctl.LstJuegos.SelectedItem
    $ctl.BtnQuitar.IsEnabled   = ([bool]$script:Steam -and $null -ne $sel -and [bool]$sel.YaEnSteam)
}

# Envoltorio de toda operacion larga lanzada desde un evento. Add-Log llama a Update-Interfaz,
# que es una bomba de mensajes: sin esto WPF atiende clics en Refrescar, Examinar, las casillas
# o la lista DENTRO de la escritura del VDF, con Steam cerrado y el fichero a medio escribir.
function Invoke-Ocupado {
    param(
        [Parameter(Mandatory)][scriptblock]$Accion,
        # Nombre del boton que mientras dura la operacion cambia de texto, para que se vea que
        # esta trabajando y no colgado: todo va en el hilo de la UI y las descargas de imagenes
        # dejan la ventana sin responder un buen rato.
        [string]$Boton = '',
        [string]$TextoOcupado = ''
    )
    if ($script:Ocupado) { return }          # nunca anidado
    $script:Ocupado = $true
    $textoAntes = $null
    if ($Boton -and $TextoOcupado) {
        $textoAntes = $ctl[$Boton].Content
        $ctl[$Boton].Content = $TextoOcupado
    }
    foreach ($n in $ControlesInteractivos) { $ctl[$n].IsEnabled = $false }
    try { & $Accion }
    finally {
        # el orden importa: la marca primero, para no dejarla puesta si algo falla al reactivar
        $script:Ocupado = $false
        if ($null -ne $textoAntes) { $ctl[$Boton].Content = $textoAntes }
        foreach ($n in $ControlesInteractivos) { $ctl[$n].IsEnabled = $true }
        Update-Botones
    }
}

function Get-ImagenSegura {
    param([string]$Ruta)
    if (-not $Ruta -or -not (Test-Path -LiteralPath $Ruta)) { return $null }
    $bi = New-Object Windows.Media.Imaging.BitmapImage
    $bi.BeginInit()
    $bi.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bi.CreateOptions = [Windows.Media.Imaging.BitmapCreateOptions]::IgnoreImageCache
    $bi.UriSource = New-Object Uri($Ruta)
    $bi.EndInit()
    return $bi
}

function Update-Lista {
    $filtro = $ctl.TxtBuscar.Text.Trim()
    $vista = $script:Todos
    if ($filtro) { $vista = $vista | Where-Object { (Test-Contiene $_.Nombre $filtro) -or (Test-Contiene $_.Exe $filtro) } }
    $ctl.LstJuegos.ItemsSource = @($vista)
}

# Rehace la lista y la marca 'YA EN STEAM' con el mismo criterio que usa la escritura del
# VDF (Find-ShortcutDuplicado): nombre igual, o exe con las mismas opciones.
function Update-Todos {
    $existentes = @()
    if ($script:Steam) { $existentes = @(Get-ShortcutsExistentes -Ruta $script:Steam.Shortcuts) }
    foreach ($j in (@($script:Manuales) + @($script:Detectados))) {
        $dup = Find-ShortcutDuplicado -Existentes $existentes -Nombre $j.Nombre -Exe $j.Exe -LaunchOptions $j.LaunchOptions
        $j.YaEnSteam = ($null -ne $dup)
        $marca = if ($j.YaEnSteam) { 'YA EN STEAM' } else { '' }
        $j | Add-Member -NotePropertyName Marca -NotePropertyValue $marca -Force
    }
    # los de 'Examinar' van delante: el usuario los acaba de elegir y no salen de la busqueda
    $script:Todos = @($script:Manuales) +
                    @($script:Detectados | Sort-Object @{Expression={$_.YaEnSteam}}, @{Expression={$_.Fuente}}, @{Expression={$_.Nombre}})
    Update-Lista
}

function Update-Deteccion {
  try {
    $ctl.LstJuegos.ItemsSource = $null
    Add-Log 'Buscando juegos instalados...'
    $script:Detectados = @(Get-TodosLosJuegos -IncluirRecientes:([bool]$ctl.ChkRecientes.IsChecked) `
                                              -IncluirApps:([bool]$ctl.ChkApps.IsChecked) -Log $LogGui)
    Update-Todos
    $texto = "Detectados {0} títulos ({1} ya están en Steam)." -f
                @($script:Detectados).Count, (@($script:Detectados | Where-Object YaEnSteam)).Count
    if (@($script:Manuales).Count) { $texto += " Y {0} elegidos a mano." -f @($script:Manuales).Count }
    Add-Log $texto
  } catch {
    Add-Log "ERROR detectando juegos: $($_.Exception.Message)"
    Write-RegistroError -Contexto 'detectar juegos' -Fallo $_
  }
}

function Clear-Preview {
    $script:Preparado = $null
    Update-Botones
    $ctl.ImgPortada.Source = $null; $ctl.ImgCapsula.Source = $null; $ctl.ImgHero.Source = $null
    $ctl.TxtOrigenArte.Text = ''
}

# Ventana de ajustes: por ahora solo la clave de SteamGridDB
function Show-Ajustes {
    [xml]$xamlAjustes = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Ajustes" Width="520" SizeToContent="Height" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner" ShowInTaskbar="False" Background="#FF15171B">
  <Window.Resources>
    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="#FFE6E8EC"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#FF262A31"/>
      <Setter Property="Foreground" Value="#FFE6E8EC"/>
      <Setter Property="BorderBrush" Value="#FF3A3F49"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="Margin" Value="8,0,0,0"/>
    </Style>
  </Window.Resources>
  <StackPanel Margin="16">
    <TextBlock Text="SteamGridDB" FontSize="15" FontWeight="SemiBold"/>
    <TextBlock TextWrapping="Wrap" FontSize="11" Foreground="#FF8A909B" Margin="0,4,0,12">
      Opcional. Se usa para las carátulas de los juegos que no están en la Microsoft Store.
      La clave es gratuita: <Hyperlink Name="LnkSgdb" NavigateUri="https://www.steamgriddb.com/profile/preferences/api"
      Foreground="#FF6FA8FF">consíguela en tu perfil de SteamGridDB</Hyperlink>.
    </TextBlock>
    <TextBlock Text="Clave de API" FontSize="11" Foreground="#FF8A909B"/>
    <TextBox Name="TxtClave" Height="28" Margin="0,3,0,8" Padding="4,0" FontFamily="Consolas"
             Background="#FF1E2127" Foreground="#FFE6E8EC" BorderBrush="#FF3A3F49"
             VerticalContentAlignment="Center"/>
    <TextBlock Name="TxtEstado" FontSize="11" TextWrapping="Wrap" MinHeight="15" Margin="0,0,0,14"
               Foreground="#FF8A909B"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
      <Button Name="BtnProbar" Content="Probar"/>
      <Button Name="BtnGuardar" Content="Guardar" Background="#FF7A1418" IsDefault="True"/>
      <Button Name="BtnCancelar" Content="Cancelar" IsCancel="True"/>
    </StackPanel>
  </StackPanel>
</Window>
'@
    $dlg = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xamlAjustes))
    $dlg.Owner = $win
    if ($script:IconoVentana) { $dlg.Icon = $script:IconoVentana }
    $txtClave  = $dlg.FindName('TxtClave')
    $txtEstado = $dlg.FindName('TxtEstado')
    $brocha    = New-Object Windows.Media.BrushConverter

    $claveAntes = [string](Get-SgdbClave)
    $txtClave.Text = $claveAntes

    $dlg.FindName('LnkSgdb').Add_RequestNavigate({ Start-Process $_.Uri.AbsoluteUri })
    $dlg.FindName('BtnProbar').Add_Click({
        $clave = $txtClave.Text.Trim()
        if (-not $clave) { $txtEstado.Text = 'Escribe una clave para probarla.'; return }
        $txtEstado.Foreground = $brocha.ConvertFromString('#FF8A909B')
        $txtEstado.Text = 'Probando...'
        Update-Interfaz
        $r = Test-SgdbClave -Clave $clave
        $txtEstado.Foreground = $brocha.ConvertFromString($(if ($r.Ok) { '#FF9CD1A0' } else { '#FFE07A7A' }))
        $txtEstado.Text = $r.Mensaje
    })
    $dlg.FindName('BtnGuardar').Add_Click({ $dlg.DialogResult = $true })

    if (-not $dlg.ShowDialog()) { return }
    $clave = $txtClave.Text.Trim()
    if ($clave -eq $claveAntes) { return }
    try {
        Set-ConfigValor -Nombre 'SgdbClave' -Valor $clave
        if ($clave) { Add-Log 'Clave de SteamGridDB guardada.' } else { Add-Log 'Clave de SteamGridDB borrada.' }
    } catch {
        Add-Log "ERROR guardando los ajustes: $($_.Exception.Message)"
        Write-RegistroError -Contexto 'guardar ajustes' -Fallo $_
    }
}

# --- eventos ---------------------------------------------------------
$ctl.BtnAjustes.Add_Click({ Invoke-Ocupado { Show-Ajustes } })
$ctl.TxtBuscar.Add_TextChanged({ Update-Lista })
$ctl.BtnRefrescar.Add_Click({ Invoke-Ocupado { Update-Deteccion } })
$ctl.ChkRecientes.Add_Click({ Invoke-Ocupado { Update-Deteccion } })
$ctl.ChkApps.Add_Click({ Invoke-Ocupado { Update-Deteccion } })

$ctl.LstJuegos.Add_SelectionChanged({
    $j = $ctl.LstJuegos.SelectedItem
    # sin seleccion (el filtro de busqueda la quita) el boton de quitar se tiene que apagar
    if (-not $j) { Update-Botones; return }
    # rellenar TxtNombre dispara su TextChanged: sin esta marca avisaria de un cambio de nombre
    # que no ha hecho el usuario, solo por elegir otro juego de la lista
    $script:CambiandoJuego = $true
    try {
        $ctl.TxtNombre.Text   = $j.Nombre
        $ctl.TxtExe.Text      = $j.Exe
        $ctl.TxtOpciones.Text = $j.LaunchOptions
        $ctl.TxtDetalle.Text  = $j.Detalle + $(if ($j.YaEnSteam) { "  |  OJO: ya hay un acceso directo con este nombre." } else { '' })
    } finally { $script:CambiandoJuego = $false }
    Clear-Preview
})

$ctl.BtnExaminar.Add_Click({
    if ($script:Ocupado) { return }
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Ejecutables (*.exe)|*.exe'
    if ($dlg.ShowDialog() -eq 'OK') {
        $exe = $dlg.FileName
        $j = New-Juego -Nombre ([IO.Path]::GetFileNameWithoutExtension($exe)) -Fuente 'Manual' `
             -Exe $exe -StartDir ((Split-Path $exe -Parent) + '\') -Icono $exe `
             -Carpeta (Split-Path $exe -Parent) -Detalle 'Elegido a mano'
        $j | Add-Member -NotePropertyName Marca -NotePropertyValue '' -Force
        # aparte de lo detectado: si no, Refrescar (o anadir un juego) se los llevaba por delante
        $script:Manuales = @($j) + @($script:Manuales | Where-Object { $_.Exe -ne $exe })
        # con un filtro puesto el juego recien elegido podria no salir en la lista
        if ($ctl.TxtBuscar.Text) { $ctl.TxtBuscar.Text = '' }
        Update-Todos
        $ctl.LstJuegos.SelectedIndex = 0
        Add-Log "Añadido a la lista a mano: $($j.Nombre)"
    }
})

$ctl.TxtNombre.Add_TextChanged({
    if ($script:CambiandoJuego) { return }
    if ($script:Preparado) { Clear-Preview; Add-Log 'El nombre ha cambiado: hay que preparar las carátulas otra vez.' }
})

# El cuerpo de los dos botones largos va en una funcion aparte para poder envolverlo en
# Invoke-Ocupado. Ya no tocan IsEnabled: de eso se encarga Update-Botones.
function Invoke-Preparar {
    $j = $ctl.LstJuegos.SelectedItem
    if (-not $j) { Add-Log 'Elige un juego de la lista.'; return }
    $nombre = $ctl.TxtNombre.Text.Trim()
    if (-not $nombre) { Add-Log 'El nombre no puede estar vacío.'; return }

    # Aviso antes de empezar: las imagenes se descargan en el hilo de la UI y la ventana se
    # queda sin responder hasta que termina. Decirlo no lo arregla, pero evita que parezca
    # que la aplicacion se ha colgado (el arreglo de verdad es sacarlo a un runspace).
    Add-Log "Preparando carátulas de '$nombre'. Puede tardar hasta un minuto."
    Add-Log 'Mientras descarga las imágenes la ventana no responderá. Es normal: espera.'

    try {
        $j.LaunchOptions = $ctl.TxtOpciones.Text
        $appId = Get-SteamShortcutAppId -ExeQuoted ('"' + $j.Exe + '"') -AppName $nombre
        $destino = Join-Path $TempDir "$appId"
        if (Test-Path -LiteralPath $destino) { Remove-Item -LiteralPath $destino -Recurse -Force -ErrorAction SilentlyContinue }
        Add-Log "AppId: $appId"
        $origenArte = [string]$ctl.CmbOrigenArte.SelectedItem.Tag
        if (-not $origenArte) { $origenArte = 'Automatico' }
        $c = New-CaratulasSteam -Juego $j -AppId $appId -GridDir $destino -NombreFinal $nombre `
                -OrigenArte $origenArte -Log $LogGui
        $ctl.ImgPortada.Source = Get-ImagenSegura $c.Rutas['p']
        $ctl.ImgCapsula.Source = Get-ImagenSegura $c.Rutas['cap']
        $ctl.ImgHero.Source    = Get-ImagenSegura $c.Rutas['hero']
        $ctl.TxtOrigenArte.Text = "Carátulas: $($c.Origen)"
        $script:Preparado = @{ Juego = $j; Nombre = $nombre; AppId = $appId; Rutas = $c.Rutas }
        Add-Log 'Listas. Si te gustan, pulsa "2. Añadir a Steam".'
    } catch {
        Add-Log "ERROR preparando carátulas: $($_.Exception.Message)"
        Write-RegistroError -Contexto 'preparar carátulas' -Fallo $_
    }
}
$ctl.BtnPreparar.Add_Click({ Invoke-Ocupado -Boton 'BtnPreparar' -TextoOcupado 'Preparando…' -Accion { Invoke-Preparar } })

function Invoke-Anadir {
    if (-not $script:Preparado) { return }
    if (-not $script:Steam) { Add-Log (Get-SteamMotivo); return }
    try {
        $p = $script:Preparado
        $p.Juego.LaunchOptions = $ctl.TxtOpciones.Text
        $r = Invoke-AnadirJuego -Juego $p.Juego -Nombre $p.Nombre -Steam $script:Steam `
                -Reemplazar:([bool]$ctl.ChkReemplazar.IsChecked) -AbrirBigPicture:([bool]$ctl.ChkBigPicture.IsChecked) `
                -CaratulasListas $p.Rutas -Log $LogGui
        # si no ha ido bien, $script:Preparado sigue puesto y Update-Botones deja el boton vivo
        if ($r.Ok) { Clear-Preview; Update-Deteccion }
    } catch {
        Add-Log "ERROR: $($_.Exception.Message)"
        Write-RegistroError -Contexto 'añadir a Steam' -Fallo $_
    }
}
$ctl.BtnAnadir.Add_Click({ Invoke-Ocupado -Boton 'BtnAnadir' -TextoOcupado 'Añadiendo…' -Accion { Invoke-Anadir } })

function Invoke-Quitar {
    $j = $ctl.LstJuegos.SelectedItem
    if (-not $j -or -not $j.YaEnSteam) { return }
    if (-not $script:Steam) { Add-Log (Get-SteamMotivo); return }
    # El nombre que sale en la pregunta es el del acceso directo, no el detectado: si se anadio
    # con otro nombre (casa por el exe), es ese el que el usuario reconoce en su biblioteca.
    $dup = Test-ShortcutDuplicado -RutaVdf $script:Steam.Shortcuts -Nombre $j.Nombre -Exe $j.Exe -LaunchOptions $j.LaunchOptions
    $entrada = Get-ShortcutsExistentes -Ruta $script:Steam.Shortcuts | Where-Object { $_.Indice -eq $dup } | Select-Object -First 1
    $nombre = if ($entrada) { $entrada.Nombre } else { $j.Nombre }
    $texto = "¿Quitar «$nombre» de la biblioteca de Steam?`r`n`r`n" +
             "Se borran el acceso directo y sus carátulas. El juego no se desinstala.`r`n" +
             "Si Steam está abierto se cerrará un momento; antes se hace copia de shortcuts.vdf."
    $resp = [Windows.MessageBox]::Show($win, $texto, 'Quitar de Steam', 'YesNo', 'Question', 'No')
    if ($resp -ne 'Yes') { return }
    try {
        $r = Invoke-QuitarJuego -Juego $j -Steam $script:Steam -AbrirBigPicture:([bool]$ctl.ChkBigPicture.IsChecked) -Log $LogGui
        if ($r.Ok) { Clear-Preview; Update-Deteccion }
    } catch {
        Add-Log "ERROR: $($_.Exception.Message)"
        Write-RegistroError -Contexto 'quitar de Steam' -Fallo $_
    }
}
$ctl.BtnQuitar.Add_Click({ Invoke-Ocupado -Boton 'BtnQuitar' -TextoOcupado 'Quitando…' -Accion { Invoke-Quitar } })

# "Preparar caratulas" deja cada juego en %TEMP%\VaporeraArcade\<appid>\ (~1,6 MB) y solo se
# borraba al volver a preparar el mismo appid: lo preparado y no anadido, o lo de un nombre que
# luego se cambio, se quedaba ahi para siempre. Lo preparado no sobrevive a la sesion, pero no
# se borra todo: con dos ventanas abiertas, la segunda se llevaria lo que acaba de preparar la
# primera. Solo carpetas con nombre de appid, por si alguien deja algo mas ahi.
function Remove-TempViejo {
    param([int]$Horas = 24)
    if (-not (Test-Path -LiteralPath $TempDir)) { return }
    $limite = (Get-Date).AddHours(-$Horas)
    $n = 0
    foreach ($d in @(Get-ChildItem -LiteralPath $TempDir -Directory -ErrorAction SilentlyContinue)) {
        if ($d.Name -notmatch '^\d+$' -or $d.LastWriteTime -gt $limite) { continue }
        try { Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction Stop; $n++ } catch { }
    }
    if ($n) { Write-Registro "Borradas $n carpetas de carátulas preparadas hace más de $Horas horas en $TempDir." }
}

# --- arranque --------------------------------------------------------
Remove-TempViejo
$win.Title = "Vaporera Arcade $AppVersion"
if ($script:IconoVentana) { $win.Icon = $script:IconoVentana }
$ctl.TxtVersion.Text = "v$AppVersion"
if ($script:Steam) {
    $ctl.TxtSteam.Text = "Perfil $($script:Steam.UserId)  ~  $($script:Steam.Shortcuts)"
    # con varias cuentas en el mismo PC conviene dejar claro en cual se va a escribir
    if ($script:Steam.Perfiles -gt 1) {
        Write-Registro "Hay $($script:Steam.Perfiles) perfiles de Steam; se usa el $($script:Steam.UserId) ($($script:Steam.ComoElegido))."
    }
} else {
    $ctl.TxtSteam.Text = Get-SteamMotivo
}
Update-Botones

# Con una operacion en marcha Steam esta cerrado y el VDF puede estar a medio escribir, asi que
# la X de la ventana tampoco vale: Update-Interfaz deja que WPF la atienda ahi en medio.
$win.Add_Closing({
    if ($script:Ocupado) {
        $_.Cancel = $true
        # a mano, sin Add-Log: llamaria a Update-Interfaz estando ya dentro de una
        $ctl.TxtLog.AppendText("Espera a que termine la operación en curso." + "`r`n")
        $ctl.TxtLog.ScrollToEnd()
    }
})
$win.Add_ContentRendered({ Invoke-Ocupado { Update-Deteccion } })
[void]$win.ShowDialog()
