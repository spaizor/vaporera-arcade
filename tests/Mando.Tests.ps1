# =====================================================================
#  Tests de lib/Mando.ps1: lo que no depende de tener un mando ni la ventana delante (que el
#  C# compile, el stick convertido en cruceta y cuando se atiende un boton). Leer el mando de
#  verdad y las teclas que manda lo prueba el usuario con el mando en la mano.
#  Se lanzan con tests\Invoke-Tests.ps1 (Pester 5, Windows PowerShell 5.1)
# =====================================================================

BeforeAll {
    . (Join-Path $PSScriptRoot '..\lib\Mando.ps1')
    Initialize-Mando
    $script:M = [VaporeraArcade.Mando]
    # los botones que salen de Procesar, como lista de PowerShell
    function Get-Pulsados([int]$estado, [long]$ms) { @($script:M::Procesar($estado, $ms)) }
}

Describe 'Initialize-Mando' {
    It 'compila la clase y una segunda vez no hace nada' {
        'VaporeraArcade.Mando' -as [type] | Should -Not -BeNullOrEmpty
        { Initialize-Mando } | Should -Not -Throw
    }
}

Describe 'Direcciones: el stick izquierdo como cruceta' {
    It 'en reposo, o dentro del umbral, no da ninguna' {
        $M::Direcciones(0, 0, 0) | Should -Be 0
        $M::Direcciones(0, 15000, -15000) | Should -Be 0
    }
    It 'pasado el umbral, la de su lado (Y positivo es arriba)' {
        $M::Direcciones(0, 0, 20000) | Should -Be $M::Arriba
        $M::Direcciones(0, 0, -20000) | Should -Be $M::Abajo
        $M::Direcciones(0, -20000, 0) | Should -Be $M::Izquierda
        $M::Direcciones(0, 32767, 0) | Should -Be $M::Derecha
    }
    It 'en diagonal, solo la del eje que mas se mueve' {
        $M::Direcciones(0, 30000, 20000) | Should -Be $M::Derecha
        $M::Direcciones(0, 20000, -30000) | Should -Be $M::Abajo
    }
    It 'con el stick al tope negativo (-32768) no se desborda' {
        $M::Direcciones(0, -32768, 0) | Should -Be $M::Izquierda
        $M::Direcciones(0, 0, -32768) | Should -Be $M::Abajo
    }
    It 'conserva los botones que ya venian pulsados' {
        $M::Direcciones($M::A, 0, 20000) | Should -Be ($M::A -bor $M::Arriba)
    }
}

Describe 'Procesar: cuando se atiende un boton' {
    BeforeEach { $M::Reiniciar(0) }

    It 'un boton recien pulsado sale una vez, aunque se mantenga' {
        Get-Pulsados $M::A 1000 | Should -Be @($M::A)
        Get-Pulsados $M::A 1040 | Should -BeNullOrEmpty
        Get-Pulsados $M::A 5000 | Should -BeNullOrEmpty
    }
    It 'soltarlo y volver a pulsarlo cuenta otra vez' {
        Get-Pulsados $M::B 1000 | Should -Be @($M::B)
        Get-Pulsados 0 1040 | Should -BeNullOrEmpty
        Get-Pulsados $M::B 1080 | Should -Be @($M::B)
    }
    It 'una direccion mantenida se repite: primero a los 400 ms y luego cada 90' {
        Get-Pulsados $M::Abajo 1000 | Should -Be @($M::Abajo)
        Get-Pulsados $M::Abajo 1399 | Should -BeNullOrEmpty
        Get-Pulsados $M::Abajo 1400 | Should -Be @($M::Abajo)
        Get-Pulsados $M::Abajo 1489 | Should -BeNullOrEmpty
        Get-Pulsados $M::Abajo 1490 | Should -Be @($M::Abajo)
    }
    It 'LB y RB tambien se repiten; A, B, X e Y no' {
        Get-Pulsados ($M::RB -bor $M::X) 1000 | Should -Be @($M::RB, $M::X)
        Get-Pulsados ($M::RB -bor $M::X) 1400 | Should -Be @($M::RB)
    }
    It 'varios a la vez salen todos, en orden de su valor' {
        Get-Pulsados ($M::Y -bor $M::Arriba -bor $M::A) 1000 | Should -Be @($M::Arriba, $M::A, $M::Y)
    }
    It 'los botones que no se usan (Start, Back, sticks pulsados) no salen' {
        Get-Pulsados (0x0010 -bor 0x0020 -bor 0x0040 -bor 0x0080) 1000 | Should -BeNullOrEmpty
    }
    It 'lo que ya estaba pulsado al reiniciar no cuenta hasta que se suelte' {
        $M::Reiniciar($M::A)
        Get-Pulsados $M::A 1000 | Should -BeNullOrEmpty
        Get-Pulsados 0 1040 | Should -BeNullOrEmpty
        Get-Pulsados $M::A 1080 | Should -Be @($M::A)
    }
}
