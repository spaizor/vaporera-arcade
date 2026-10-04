# =====================================================================
#  Mando.ps1 - Leer un mando de Xbox (o compatible) con XInput
#
#  El mando no tiene acciones propias: cada boton se convierte en la tecla que hace lo mismo
#  (A, Enter; B, Escape; la cruceta, las flechas...), y la ventana se maneja con el teclado
#  como siempre. Asi vale igual en las ventanas de WPF que en un MessageBox o en el dialogo de
#  abrir fichero, que son de Windows.
#
#  Aqui no hay nada de WPF: quien llama (la ventana, con un DispatcherTimer) pregunta cada
#  poco a [VaporeraArcade.Mando]::Tic(), que devuelve los botones recien pulsados (o que toca
#  repetir), y decide que tecla mandar con [VaporeraArcade.Mando]::Pulsar().
#
#  Tic() solo lee el mando con una ventana del hilo que llama delante (la de la aplicacion o
#  uno de sus dialogos): si no, el mando la manejaria mientras se juega a otra cosa. Al volver
#  a ella, lo que ya estuviera pulsado no cuenta hasta que se suelte.
#
#  XInput solo ve mandos de Xbox o los que se hacen pasar por uno (modo X-input). Los de
#  PlayStation o Switch, a traves de Steam Input o DS4Windows.
#
#  Es C# compilado al arrancar (Add-Type): si no se puede (antivirus, modo de lenguaje
#  restringido), Initialize-Mando lanza y la aplicacion sigue sin mando.
# =====================================================================

$script:CodigoMando = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace VaporeraArcade {
    public static class Mando {
        // Los botones, con los valores de XInput (wButtons). La cruceta y el stick izquierdo
        // dan los mismos cuatro.
        public const int Arriba = 0x0001, Abajo = 0x0002, Izquierda = 0x0004, Derecha = 0x0008;
        public const int LB = 0x0100, RB = 0x0200, A = 0x1000, B = 0x2000, X = 0x4000, Y = 0x8000;
        // los que se repiten mientras se mantienen, como una tecla
        public const int ConRepeticion = Arriba | Abajo | Izquierda | Derecha | LB | RB;
        public const int Usados = ConRepeticion | A | B | X | Y;
        // cuanto hay que mover el stick (de 32767) y cada cuanto se repite (ms)
        public const int Umbral = 16000;
        public const int PrimeraRepeticion = 400, Repeticion = 90;
        // un hueco sin mando se vuelve a mirar cada tanto: XInputGetState tarda en los vacios
        public const int EsperaHuecoVacio = 2000;

        [DllImport("xinput1_4.dll")] static extern uint XInputGetState(uint hueco, byte[] estado);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
        [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
        [DllImport("user32.dll")] static extern uint MapVirtualKey(uint codigo, uint tipo);
        [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);

        static readonly Stopwatch Reloj = Stopwatch.StartNew();
        static readonly bool[] Conectado = new bool[4];
        static readonly long[] ProximoIntento = new long[4];
        static readonly long[] SiguienteRepeticion = new long[16];
        // XINPUT_STATE: dwPacketNumber (4), wButtons (2), gatillos (2), sticks (4 x 2)
        static readonly byte[] Bufer = new byte[16];
        static int Anterior;
        static bool Fuera = true;

        // La ventana que estaba delante en el ultimo Tic (IntPtr.Zero si no era nuestra)
        public static IntPtr Ventana { get; private set; }
        // Cuantos mandos habia en el ultimo Tic con la ventana delante
        public static int Mandos { get; private set; }

        public static int[] Tic() {
            IntPtr fg = GetForegroundWindow();
            if (fg == IntPtr.Zero || GetWindowThreadProcessId(fg, IntPtr.Zero) != GetCurrentThreadId()) {
                Ventana = IntPtr.Zero;
                Fuera = true;
                return new int[0];
            }
            Ventana = fg;
            long ahora = Reloj.ElapsedMilliseconds;
            int estado = Leer(ahora);
            if (Fuera) {
                Fuera = false;
                Reiniciar(estado);
                return new int[0];
            }
            return Procesar(estado, ahora);
        }

        // Lo pulsado ahora pasa a ser lo de antes: no cuenta hasta que se suelte
        public static void Reiniciar(int estado) {
            Anterior = estado & Usados;
        }

        // Los botones que hay que atender con este estado: los recien pulsados y, de los que
        // se repiten, los que llevan pulsados lo bastante.
        public static int[] Procesar(int estado, long ahora) {
            estado &= Usados;
            List<int> r = new List<int>();
            for (int i = 0; i < 16; i++) {
                int b = 1 << i;
                if ((Usados & b) == 0 || (estado & b) == 0) continue;
                if ((Anterior & b) == 0) {
                    r.Add(b);
                    SiguienteRepeticion[i] = ahora + PrimeraRepeticion;
                } else if ((ConRepeticion & b) != 0 && ahora >= SiguienteRepeticion[i]) {
                    r.Add(b);
                    SiguienteRepeticion[i] = ahora + Repeticion;
                }
            }
            Anterior = estado;
            return r.ToArray();
        }

        // Los botones con el stick izquierdo convertido en cruceta: solo el eje que mas se
        // mueve, para que una diagonal no mande dos flechas.
        public static int Direcciones(int botones, int lx, int ly) {
            int r = botones;
            if (Math.Abs(lx) > Math.Abs(ly)) {
                if (lx > Umbral) r |= Derecha; else if (lx < -Umbral) r |= Izquierda;
            } else {
                if (ly > Umbral) r |= Arriba; else if (ly < -Umbral) r |= Abajo;
            }
            return r;
        }

        // Todos los mandos conectados a la vez, como si fueran uno
        static int Leer(long ahora) {
            int estado = 0, n = 0;
            for (uint i = 0; i < 4; i++) {
                if (!Conectado[i] && ahora < ProximoIntento[i]) continue;
                if (XInputGetState(i, Bufer) != 0) {
                    Conectado[i] = false;
                    ProximoIntento[i] = ahora + EsperaHuecoVacio;
                    continue;
                }
                Conectado[i] = true;
                n++;
                estado |= Direcciones(BitConverter.ToUInt16(Bufer, 4),
                                      BitConverter.ToInt16(Bufer, 8), BitConverter.ToInt16(Bufer, 10));
            }
            Mandos = n;
            return estado;
        }

        // Pulsa y suelta la tecla vk (con Mayus si hace falta) en la ventana que este delante
        public static void Pulsar(int vk, bool mayus) {
            if (mayus) Tecla(0x10, false);
            Tecla(vk, false);
            Tecla(vk, true);
            if (mayus) Tecla(0x10, true);
        }

        static void Tecla(int vk, bool soltar) {
            // RePag, AvPag, Fin, Inicio y las flechas son teclas extendidas: sin la marca, con
            // el bloqueo numerico se leerian como las del teclado numerico
            uint marcas = (vk >= 0x21 && vk <= 0x28) ? 1u : 0u;
            if (soltar) marcas |= 2u;
            keybd_event((byte)vk, (byte)MapVirtualKey((uint)vk, 0), marcas, UIntPtr.Zero);
        }
    }
}
'@

# Compila la clase del mando (una vez por sesion). Lanza si no se puede.
function Initialize-Mando {
    if (-not ('VaporeraArcade.Mando' -as [type])) {
        Add-Type -TypeDefinition $script:CodigoMando -ErrorAction Stop
    }
}
