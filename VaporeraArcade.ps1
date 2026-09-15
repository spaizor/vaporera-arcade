# =====================================================================
#  Vaporera Arcade  -  Anadir juegos de otras plataformas a Steam
#
#  Detecta los juegos instalados (Xbox/Game Pass, Ubisoft, Epic, GOG,
#  apps de la Store y programas ejecutados hace poco), descarga las
#  caratulas oficiales y escribe el acceso directo en shortcuts.vdf.
#
#  Uso:  .\VaporeraArcade.ps1            (o el .vbs de al lado, sin consola)
#        .\VaporeraArcade.ps1 -Consola   (modo texto, sin ventana)
# =====================================================================
param([switch]$Consola, [string]$Juego)

$ErrorActionPreference = 'Stop'
$Raiz = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Raiz 'lib\Vdf.ps1')
. (Join-Path $Raiz 'lib\Fuentes.ps1')
. (Join-Path $Raiz 'lib\Caratulas.ps1')
. (Join-Path $Raiz 'lib\SteamCtl.ps1')

$TempDir = Join-Path $env:TEMP 'VaporeraArcade'
$LogFile = Join-Path $Raiz 'vaporera-arcade.log'

function Write-Registro {
    param([string]$Texto)
    $linea = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Texto
    try { Add-Content -Path $LogFile -Value $linea -Encoding UTF8 } catch { }
}

# Guarda un error con su detalle tecnico (fichero y linea) para poder diagnosticarlo
function Write-RegistroError {
    param([string]$Contexto, $Fallo)
    Write-Registro "ERROR en $Contexto : $($Fallo.Exception.Message)"
    $pos = $Fallo.InvocationInfo.PositionMessage
    if ($pos) { foreach ($l in ($pos -split "`r?`n")) { if ($l.Trim()) { Write-Registro "    $($l.Trim())" } } }
    if ($Fallo.Exception.InnerException) { Write-Registro "    causa: $($Fallo.Exception.InnerException.Message)" }
}

# =====================================================================
#  Nucleo compartido por la GUI y el modo consola
# =====================================================================
function Invoke-AnadirJuego {
    param(
        [Parameter(Mandatory)]$Juego,
        [Parameter(Mandatory)][string]$Nombre,
        [Parameter(Mandatory)]$Steam,
        [switch]$Reemplazar,
        [switch]$AbrirBigPicture,
        [switch]$NoReabrirSteam,
        [hashtable]$CaratulasListas = $null,
        [scriptblock]$Log = $null
    )
    # si hay $Log, el propio bloque ya escribe en el fichero: asi no se duplican lineas
    function Registrar($m) { if ($Log) { & $Log $m } else { Write-Registro $m } }

    $appId = Get-SteamShortcutAppId -ExeQuoted ('"' + $Juego.Exe + '"') -AppName $Nombre
    Registrar "=== $Nombre ==="
    Registrar "Origen : $($Juego.Fuente)"
    Registrar "Exe    : $($Juego.Exe)"
    if ($Juego.LaunchOptions) { Registrar "Opciones: $($Juego.LaunchOptions)" }
    Registrar "AppId  : $appId"

    $estabaAbierto = Test-SteamCorriendo
    if (-not (Stop-SteamYEsperar -SteamExe $Steam.Exe -Log $Log)) {
        Registrar 'ABORTADO: Steam no se ha cerrado. Ciérralo a mano y repite.'
        return [pscustomobject]@{ Ok = $false; AppId = $appId; Motivo = 'steam-abierto' }
    }

    $bak = Backup-Shortcuts -Ruta $Steam.Shortcuts
    if ($bak) { Registrar "Copia de seguridad: $(Split-Path $bak -Leaf)" }

    $r = Add-SteamShortcut -RutaVdf $Steam.Shortcuts -Nombre $Nombre -Exe $Juego.Exe `
            -StartDir $Juego.StartDir -Icono $Juego.Icono -LaunchOptions $Juego.LaunchOptions `
            -Reemplazar:$Reemplazar -Log $Log
    if (-not $r.Ok) {
        Registrar "Ya existe un acceso directo igual (entrada $($r.Indice)). No se ha tocado nada."
        if ($estabaAbierto -and -not $NoReabrirSteam) { Start-Steam -SteamExe $Steam.Exe -BigPicture:$AbrirBigPicture -Log $Log }
        return [pscustomobject]@{ Ok = $false; AppId = $appId; Motivo = 'duplicado' }
    }

    # caratulas: o las ya preparadas, o generarlas ahora
    if ($CaratulasListas -and $CaratulasListas.Count) {
        # en un PC recien estrenado config\grid\ todavia no existe: hay que crearla
        if (-not (Test-Path $Steam.GridDir)) {
            [void](New-Item -ItemType Directory -Path $Steam.GridDir -Force)
            Registrar "Creada la carpeta config\grid\ (no existía)."
        }
        $copiadas = 0
        foreach ($k in $CaratulasListas.Keys) {
            $origenImg = $CaratulasListas[$k]
            if (-not (Test-Path $origenImg)) { Registrar "  falta la imagen '$k', me la salto."; continue }
            $destino = Join-Path $Steam.GridDir (Split-Path $origenImg -Leaf)
            try { Copy-Item $origenImg $destino -Force; $copiadas++ }
            catch { Registrar "  no he podido copiar '$k': $($_.Exception.Message)" }
        }
        Registrar "Carátulas copiadas a config\grid\ ($copiadas de $($CaratulasListas.Count) imágenes)."
    } else {
        $c = New-CaratulasSteam -Juego $Juego -AppId $appId -GridDir $Steam.GridDir -NombreFinal $Nombre -Log $Log
        Registrar "Carátulas: $($c.Origen)"
    }

    if (-not $NoReabrirSteam) { Start-Steam -SteamExe $Steam.Exe -BigPicture:$AbrirBigPicture -Log $Log }
    Registrar "LISTO. '$Nombre' ya está en la biblioteca."
    return [pscustomobject]@{ Ok = $true; AppId = $appId; Motivo = '' }
}

# =====================================================================
#  Modo consola
# =====================================================================
if ($Consola) {
    $steam = Get-SteamInfo
    if (-not $steam) { Write-Host 'No encuentro la instalación de Steam.' -ForegroundColor Red; exit 1 }
    $todos = Get-TodosLosJuegos -IncluirRecientes -IncluirApps
    if ($Juego) { $todos = $todos | Where-Object { $_.Nombre -like "*$Juego*" } }
    if (-not $todos) { Write-Host 'Ningún juego detectado con ese filtro.'; exit 1 }
    $i = 0
    $todos | ForEach-Object { Write-Host ("[{0,2}] {1,-45} {2}" -f $i, $_.Nombre, $_.Fuente); $i++ }
    $sel = Read-Host 'Número del juego a añadir'
    $j = $todos[[int]$sel]
    $r = Invoke-AnadirJuego -Juego $j -Nombre $j.Nombre -Steam $steam -Log { param($m) Write-Host $m; Write-Registro $m }
    exit $(if ($r.Ok) { 0 } else { 1 })
}

# =====================================================================
#  GUI (WPF)
# =====================================================================
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Drawing

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
    <StackPanel Grid.Row="0" Grid.ColumnSpan="2" Margin="0,0,0,10">
      <TextBlock Text="Vaporera Arcade" FontSize="20" FontWeight="SemiBold" Foreground="#FFDC1E23"/>
      <TextBlock Name="TxtSteam" Text="" FontSize="11" Foreground="#FF8A909B" Margin="0,2,0,0"/>
    </StackPanel>

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

      <WrapPanel Margin="0,0,0,12">
        <Button Name="BtnPreparar" Content="1. Preparar carátulas" Background="#FF2E3440"/>
        <Button Name="BtnAnadir" Content="2. Añadir a Steam" IsEnabled="False" Background="#FF7A1418"/>
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
foreach ($n in @('TxtSteam','TxtBuscar','ChkRecientes','ChkApps','BtnRefrescar','BtnExaminar','LstJuegos',
                 'TxtNombre','TxtExe','TxtOpciones','TxtDetalle','BtnPreparar','BtnAnadir','TxtOrigenArte',
                 'ImgPortada','ImgCapsula','ImgHero','ChkBigPicture','ChkReemplazar','TxtLog')) {
    $ctl[$n] = $win.FindName($n)
}

$script:Steam = Get-SteamInfo
$script:Todos = @()
$script:Preparado = $null

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

function Get-ImagenSegura {
    param([string]$Ruta)
    if (-not $Ruta -or -not (Test-Path $Ruta)) { return $null }
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
    if ($filtro) { $vista = $vista | Where-Object { $_.Nombre -like "*$filtro*" -or $_.Exe -like "*$filtro*" } }
    $ctl.LstJuegos.ItemsSource = @($vista)
}

function Update-Deteccion {
  try {
    $ctl.LstJuegos.ItemsSource = $null
    Add-Log 'Buscando juegos instalados...'
    $lista = @(Get-TodosLosJuegos -IncluirRecientes:([bool]$ctl.ChkRecientes.IsChecked) -IncluirApps:([bool]$ctl.ChkApps.IsChecked))

    $yaPuestos = @{}
    if ($script:Steam) {
        foreach ($e in Get-ShortcutsExistentes -Ruta $script:Steam.Shortcuts) { $yaPuestos[$e.Nombre.ToLower()] = $true }
    }
    foreach ($j in $lista) {
        $j.YaEnSteam = $yaPuestos.ContainsKey($j.Nombre.ToLower())
        $marca = if ($j.YaEnSteam) { 'YA EN STEAM' } else { '' }
        $j | Add-Member -NotePropertyName Marca -NotePropertyValue $marca -Force
    }
    $script:Todos = @($lista | Sort-Object @{Expression={$_.YaEnSteam}}, @{Expression={$_.Fuente}}, @{Expression={$_.Nombre}})
    Add-Log ("Detectados {0} títulos ({1} ya están en Steam)." -f $script:Todos.Count, (@($script:Todos | Where-Object YaEnSteam)).Count)
    Update-Lista
  } catch {
    Add-Log "ERROR detectando juegos: $($_.Exception.Message)"
    Write-RegistroError -Contexto 'detectar juegos' -Fallo $_
  }
}

function Clear-Preview {
    $script:Preparado = $null
    $ctl.BtnAnadir.IsEnabled = $false
    $ctl.ImgPortada.Source = $null; $ctl.ImgCapsula.Source = $null; $ctl.ImgHero.Source = $null
    $ctl.TxtOrigenArte.Text = ''
}

# --- eventos ---------------------------------------------------------
$ctl.TxtBuscar.Add_TextChanged({ Update-Lista })
$ctl.BtnRefrescar.Add_Click({ Update-Deteccion })
$ctl.ChkRecientes.Add_Click({ Update-Deteccion })
$ctl.ChkApps.Add_Click({ Update-Deteccion })

$ctl.LstJuegos.Add_SelectionChanged({
    $j = $ctl.LstJuegos.SelectedItem
    if (-not $j) { return }
    $ctl.TxtNombre.Text   = $j.Nombre
    $ctl.TxtExe.Text      = $j.Exe
    $ctl.TxtOpciones.Text = $j.LaunchOptions
    $ctl.TxtDetalle.Text  = $j.Detalle + $(if ($j.YaEnSteam) { "  |  OJO: ya hay un acceso directo con este nombre." } else { '' })
    Clear-Preview
})

$ctl.BtnExaminar.Add_Click({
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Ejecutables (*.exe)|*.exe'
    if ($dlg.ShowDialog() -eq 'OK') {
        $exe = $dlg.FileName
        $j = New-Juego -Nombre ([IO.Path]::GetFileNameWithoutExtension($exe)) -Fuente 'Manual' `
             -Exe $exe -StartDir ((Split-Path $exe -Parent) + '\') -Icono $exe `
             -Carpeta (Split-Path $exe -Parent) -Detalle 'Elegido a mano'
        $j | Add-Member -NotePropertyName Marca -NotePropertyValue '' -Force
        $script:Todos = @($j) + $script:Todos
        Update-Lista
        $ctl.LstJuegos.SelectedIndex = 0
    }
})

$ctl.TxtNombre.Add_TextChanged({ if ($script:Preparado) { Clear-Preview; Add-Log 'El nombre ha cambiado: hay que preparar las carátulas otra vez.' } })

$ctl.BtnPreparar.Add_Click({
    $j = $ctl.LstJuegos.SelectedItem
    if (-not $j) { Add-Log 'Elige un juego de la lista.'; return }
    $nombre = $ctl.TxtNombre.Text.Trim()
    if (-not $nombre) { Add-Log 'El nombre no puede estar vacío.'; return }

    $ctl.BtnPreparar.IsEnabled = $false
    try {
        $j.LaunchOptions = $ctl.TxtOpciones.Text
        $appId = Get-SteamShortcutAppId -ExeQuoted ('"' + $j.Exe + '"') -AppName $nombre
        $destino = Join-Path $TempDir "$appId"
        if (Test-Path $destino) { Remove-Item $destino -Recurse -Force -ErrorAction SilentlyContinue }
        Add-Log "AppId: $appId"
        $c = New-CaratulasSteam -Juego $j -AppId $appId -GridDir $destino -NombreFinal $nombre -Log $LogGui
        $ctl.ImgPortada.Source = Get-ImagenSegura $c.Rutas['p']
        $ctl.ImgCapsula.Source = Get-ImagenSegura $c.Rutas['cap']
        $ctl.ImgHero.Source    = Get-ImagenSegura $c.Rutas['hero']
        $ctl.TxtOrigenArte.Text = "Carátulas: $($c.Origen)"
        $script:Preparado = @{ Juego = $j; Nombre = $nombre; AppId = $appId; Rutas = $c.Rutas }
        $ctl.BtnAnadir.IsEnabled = $true
        Add-Log 'Listas. Si te gustan, pulsa "2. Añadir a Steam".'
    } catch {
        Add-Log "ERROR preparando carátulas: $($_.Exception.Message)"
        Write-RegistroError -Contexto 'preparar carátulas' -Fallo $_
    } finally {
        $ctl.BtnPreparar.IsEnabled = $true
    }
})

$ctl.BtnAnadir.Add_Click({
    if (-not $script:Preparado) { return }
    if (-not $script:Steam) { Add-Log 'No encuentro Steam.'; return }
    $ctl.BtnAnadir.IsEnabled = $false; $ctl.BtnPreparar.IsEnabled = $false
    try {
        $p = $script:Preparado
        $p.Juego.LaunchOptions = $ctl.TxtOpciones.Text
        $r = Invoke-AnadirJuego -Juego $p.Juego -Nombre $p.Nombre -Steam $script:Steam `
                -Reemplazar:([bool]$ctl.ChkReemplazar.IsChecked) -AbrirBigPicture:([bool]$ctl.ChkBigPicture.IsChecked) `
                -CaratulasListas $p.Rutas -Log $LogGui
        if ($r.Ok) { Clear-Preview; Update-Deteccion }
        else { $ctl.BtnAnadir.IsEnabled = $true }
    } catch {
        Add-Log "ERROR: $($_.Exception.Message)"
        Write-RegistroError -Contexto 'añadir a Steam' -Fallo $_
        $ctl.BtnAnadir.IsEnabled = $true
    } finally {
        $ctl.BtnPreparar.IsEnabled = $true
    }
})

# --- arranque --------------------------------------------------------
if ($script:Steam) {
    $ctl.TxtSteam.Text = "Perfil $($script:Steam.UserId)  ~  $($script:Steam.Shortcuts)"
} else {
    $ctl.TxtSteam.Text = 'No encuentro la instalación de Steam.'
    $ctl.BtnPreparar.IsEnabled = $false
}
$win.Add_ContentRendered({ Update-Deteccion })
[void]$win.ShowDialog()
