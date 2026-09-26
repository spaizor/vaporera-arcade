# =====================================================================
#  Tests de lib/Tareas.ps1: lanzar trabajo en otro runspace, sus lineas de registro, sus
#  fallos y cancelarlo. Nada de red.
#  Se lanzan con tests\Invoke-Tests.ps1 (Pester 5, Windows PowerShell 5.1)
# =====================================================================

BeforeAll {
    . (Join-Path $PSScriptRoot '..\lib\Tareas.ps1')

    # Espera a que acabe (con limite, para que un fallo no deje colgados los tests)
    function Wait-Tarea([hashtable]$t, [int]$MaxSegundos = 20) {
        $reloj = [Diagnostics.Stopwatch]::StartNew()
        while (-not $t.Handle.IsCompleted -and $reloj.Elapsed.TotalSeconds -lt $MaxSegundos) { Start-Sleep -Milliseconds 20 }
        return $t.Handle.IsCompleted
    }
}

Describe 'Start-TareaFondo / Complete-TareaFondo' {
    It 'devuelve lo que devuelve el cuerpo, con sus parámetros' {
        $t = Start-TareaFondo -Cuerpo { param($A, $B, $Log) [pscustomobject]@{ Suma = $A + $B } } -Parametros @{ A = 2; B = 3 }
        Wait-Tarea $t | Should -BeTrue
        $r = Complete-TareaFondo $t
        $r.Fallo | Should -BeNullOrEmpty
        $r.Cancelada | Should -BeFalse
        $r.Resultado.Suma | Should -Be 5
    }

    It 'lo que pasa por -Log llega a la cola, en orden y con tildes' {
        $t = Start-TareaFondo -Cuerpo { param($Log) & $Log 'uno' | Out-Null; & $Log 'dos: carátulas' | Out-Null; 'ok' }
        Wait-Tarea $t | Should -BeTrue
        $lineas = Get-TareaLineas $t
        $lineas | Should -Be @('uno', 'dos: carátulas')
        @(Get-TareaLineas $t).Count | Should -Be 0     # ya se han sacado
        (Complete-TareaFondo $t).Resultado | Should -Be 'ok'
    }

    It 'el -Log funciona dentro de las funciones de una lib, aunque una variable se llame como la cola' {
        $lib = Join-Path $TestDrive 'LibPrueba.ps1'
        Set-Content -LiteralPath $lib -Encoding UTF8 -Value @'
function Invoke-Prueba {
    param([scriptblock]$Log)
    $Cola = 'no soy la cola'
    & $Log "desde la lib ($Cola)" | Out-Null
    return 'hecho'
}
'@
        $t = Start-TareaFondo -Cuerpo { param($Log) Invoke-Prueba -Log $Log } -Lib @($lib)
        Wait-Tarea $t | Should -BeTrue
        $r = Complete-TareaFondo $t
        $r.Fallo | Should -BeNullOrEmpty
        $r.Resultado | Should -Be 'hecho'
        Get-TareaLineas $t | Should -Be @('desde la lib (no soy la cola)')
    }

    It 'carga las lib\ de verdad (Caratulas.ps1)' {
        $lib = (Resolve-Path (Join-Path $PSScriptRoot '..\lib\Caratulas.ps1')).Path
        $t = Start-TareaFondo -Cuerpo { param($Log) Get-TituloNormalizado 'Pokémon Edición Deluxe' } -Lib @($lib)
        Wait-Tarea $t | Should -BeTrue
        (Complete-TareaFondo $t).Resultado | Should -Be 'pokemon'
    }

    It 'un error del cuerpo vuelve como Fallo, con su mensaje y su posición' {
        $t = Start-TareaFondo -Cuerpo { param($Log) & $Log 'antes' | Out-Null; throw 'se ha roto' }
        Wait-Tarea $t | Should -BeTrue
        $r = Complete-TareaFondo $t
        $r.Resultado | Should -BeNullOrEmpty
        $r.Fallo.Exception.Message | Should -Be 'se ha roto'
        $r.Fallo.InvocationInfo | Should -Not -BeNullOrEmpty
        Get-TareaLineas $t | Should -Be @('antes')
    }

    It 'una lib que no existe también vuelve como Fallo, no revienta' {
        $t = Start-TareaFondo -Cuerpo { param($Log) 'no llego' } -Lib @((Join-Path $TestDrive 'no-existe.ps1'))
        Wait-Tarea $t | Should -BeTrue
        $r = Complete-TareaFondo $t
        $r.Fallo | Should -Not -BeNullOrEmpty
        $r.Resultado | Should -BeNullOrEmpty
    }

    It 'lo que pasa por -Aviso llega aparte, en orden y sin convertir a texto' {
        $t = Start-TareaFondo -Cuerpo {
            param($Log, $Aviso)
            & $Aviso ([pscustomobject]@{ Indice = 0; Ruta = 'a.png' }) | Out-Null
            & $Log 'entre medias' | Out-Null
            & $Aviso ([pscustomobject]@{ Indice = 1; Ruta = 'b.png' }) | Out-Null
            'fin'
        }
        Wait-Tarea $t | Should -BeTrue
        $avisos = @(Get-TareaAvisos $t)
        $avisos.Count | Should -Be 2
        $avisos[0].Indice | Should -Be 0
        $avisos[1].Ruta | Should -Be 'b.png'
        Get-TareaLineas $t | Should -Be @('entre medias')
        @(Get-TareaAvisos $t).Count | Should -Be 0
        (Complete-TareaFondo $t).Resultado | Should -Be 'fin'
    }

    It 'no cambia la hashtable de parámetros de quien llama' {
        $p = @{ A = 1 }
        $t = Start-TareaFondo -Cuerpo { param($A, $Log) $A } -Parametros $p
        Wait-Tarea $t | Should -BeTrue
        [void](Complete-TareaFondo $t)
        $p.Keys | Should -Be @('A')
    }
}

Describe 'Stop-TareaFondo' {
    It 'vuelve enseguida y la tarea acaba como cancelada, sin resultado ni fallo' {
        $t = Start-TareaFondo -Cuerpo { param($Log) & $Log 'empiezo' | Out-Null; Start-Sleep -Seconds 30; 'no llego' }
        # hasta que no ha empezado, parar no demuestra nada
        $reloj = [Diagnostics.Stopwatch]::StartNew()
        while ($t.Cola.IsEmpty -and $reloj.Elapsed.TotalSeconds -lt 10) { Start-Sleep -Milliseconds 20 }
        $reloj.Restart()
        Stop-TareaFondo $t
        $reloj.ElapsedMilliseconds | Should -BeLessThan 1000
        Wait-Tarea $t -MaxSegundos 10 | Should -BeTrue
        $r = Complete-TareaFondo $t
        $r.Cancelada | Should -BeTrue
        $r.Resultado | Should -BeNullOrEmpty
        $r.Fallo | Should -BeNullOrEmpty
    }

    It 'parar una tarea que ya ha acabado no lanza' {
        $t = Start-TareaFondo -Cuerpo { param($Log) 'ya' }
        Wait-Tarea $t | Should -BeTrue
        { Stop-TareaFondo $t } | Should -Not -Throw
        (Complete-TareaFondo $t).Cancelada | Should -BeTrue
    }
}
