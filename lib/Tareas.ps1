# =====================================================================
#  Tareas.ps1 - Trabajo en segundo plano (un runspace aparte)
#
#  Todo lo de la ventana va en el hilo de la UI: una descarga larga la deja congelada hasta
#  que acaba. Esto lanza un bloque de codigo en otro runspace, con las lib\ que necesite
#  cargadas alli, y deja lo que va registrando en una cola que la ventana vacia a su ritmo.
#
#  Aqui no hay nada de WPF: quien llama pregunta por Handle.IsCompleted (la ventana, con un
#  DispatcherTimer), va sacando lineas con Get-TareaLineas y al acabar recoge el resultado
#  con Complete-TareaFondo. Para lo que no es texto (una miniatura ya descargada, por
#  ejemplo) hay un segundo canal: el cuerpo llama a -Aviso con un objeto y quien llama los
#  recoge con Get-TareaAvisos, sin esperar a que acabe.
#
#  Cancelar (Stop-TareaFondo) no es inmediato: PowerShell solo para entre un comando y el
#  siguiente, y una llamada .NET en curso (WebClient.DownloadData, por ejemplo) sigue hasta
#  que vuelve. Por eso quien cancela no debe esperar: la tarea se marca y termina sola.
# =====================================================================

# Lo que se ejecuta dentro del runspace. El cuerpo llega como texto y se vuelve a crear
# alli: un scriptblock queda atado al runspace donde nacio, e invocarlo desde otro hilo lo
# ejecuta contra el de la ventana. $Log escribe en la cola; con GetNewClosure no depende de
# que ninguna funcion de las lib\ tenga una variable que se llame igual que $Cola.
$script:PreambuloTarea = {
    param([string[]]$Lib, $Cola, $Avisos, [string]$Cuerpo, [hashtable]$Parametros)
    $ErrorActionPreference = 'Stop'
    try {
        foreach ($f in $Lib) { . $f }
        $Parametros['Log'] = { param($m) $Cola.Enqueue([string]$m) }.GetNewClosure()
        $Parametros['Aviso'] = { param($o) $Avisos.Enqueue($o) }.GetNewClosure()
        $res = & ([scriptblock]::Create($Cuerpo)) @Parametros
        [pscustomobject]@{ Resultado = $res; Fallo = $null }
    } catch {
        [pscustomobject]@{ Resultado = $null; Fallo = $_ }
    }
}

# Lanza $Cuerpo en segundo plano y vuelve enseguida. $Cuerpo recibe $Parametros y ademas
# -Log (un scriptblock como el de las lib\) y -Aviso, asi que tiene que declarar
# param(..., $Log); $Aviso solo si lo usa (un bloque sin [CmdletBinding] no se queja).
# $Lib son las rutas de los .ps1 que se cargan antes: el runspace empieza vacio.
# Devuelve la tarea, una hashtable que no hay que tocar salvo Datos, que es de quien llama.
function Start-TareaFondo {
    param(
        [Parameter(Mandatory)][scriptblock]$Cuerpo,
        [hashtable]$Parametros = @{},
        [string[]]$Lib = @(),
        $Datos = $null
    )
    $cola = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    $avisos = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    # una copia: el preambulo le anade Log y Aviso y no tiene por que verlo quien llama
    $param = @{}
    foreach ($k in $Parametros.Keys) { $param[$k] = $Parametros[$k] }
    [void]$ps.AddScript($script:PreambuloTarea).AddParameter('Lib', $Lib).AddParameter('Cola', $cola).
             AddParameter('Avisos', $avisos).AddParameter('Cuerpo', $Cuerpo.ToString()).AddParameter('Parametros', $param)
    $handle = $ps.BeginInvoke()
    return @{ PS = $ps; Runspace = $rs; Handle = $handle; Cola = $cola; Avisos = $avisos; Cancelada = $false; Datos = $Datos }
}

# Los objetos que ha mandado la tarea con -Aviso desde la ultima vez, en orden (usar @(...))
function Get-TareaAvisos {
    param([Parameter(Mandatory)][hashtable]$Tarea)
    $lista = New-Object System.Collections.Generic.List[object]
    $o = $null
    while ($Tarea.Avisos.TryDequeue([ref]$o)) { $lista.Add($o) }
    return $lista.ToArray()
}

# Las lineas que ha registrado la tarea desde la ultima vez (puede no haber ninguna: usar
# @(...) al recogerlas)
function Get-TareaLineas {
    param([Parameter(Mandatory)][hashtable]$Tarea)
    $lineas = New-Object System.Collections.Generic.List[string]
    $l = $null
    while ($Tarea.Cola.TryDequeue([ref]$l)) { $lineas.Add($l) }
    return $lineas.ToArray()
}

# Pide que pare y vuelve sin esperar. Lo que registre a partir de aqui ya no interesa.
function Stop-TareaFondo {
    param([Parameter(Mandatory)][hashtable]$Tarea)
    $Tarea.Cancelada = $true
    try { [void]$Tarea.PS.BeginStop($null, $null) } catch { }
}

# Solo con Handle.IsCompleted: recoge el resultado y suelta el runspace. No lanza nunca.
# Devuelve Resultado (lo que devolvio el cuerpo), Fallo (el ErrorRecord, si lanzo) y
# Cancelada. Una tarea cancelada no trae ni resultado ni fallo.
function Complete-TareaFondo {
    param([Parameter(Mandatory)][hashtable]$Tarea)
    $salida = $null; $fallo = $null
    try { $salida = @($Tarea.PS.EndInvoke($Tarea.Handle)) | Select-Object -First 1 }
    catch { $fallo = $_ }
    finally {
        try { $Tarea.PS.Dispose() } catch { }
        try { $Tarea.Runspace.Dispose() } catch { }
    }
    if ($Tarea.Cancelada) { return [pscustomobject]@{ Resultado = $null; Fallo = $null; Cancelada = $true } }
    if ($fallo) { return [pscustomobject]@{ Resultado = $null; Fallo = $fallo; Cancelada = $false } }
    if (-not $salida) {
        # no deberia pasar: el preambulo siempre devuelve algo
        $e = New-Object System.Management.Automation.ErrorRecord (
            (New-Object InvalidOperationException 'La tarea en segundo plano no ha devuelto nada.')),
            'TareaSinSalida', 'InvalidResult', $null
        return [pscustomobject]@{ Resultado = $null; Fallo = $e; Cancelada = $false }
    }
    return [pscustomobject]@{ Resultado = $salida.Resultado; Fallo = $salida.Fallo; Cancelada = $false }
}
