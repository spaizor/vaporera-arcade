# Vaporera Arcade

Añade a tu biblioteca de Steam los juegos de otras plataformas (Xbox Game Pass, Epic Games,
GOG, Ubisoft Connect, Microsoft Store…) con un par de clics, y con sus carátulas.

Steam permite añadir «juegos que no son de Steam», pero a mano: hay que buscar el ejecutable,
averiguar cómo se lanza cada juego y conseguir las imágenes con el tamaño correcto. Vaporera
Arcade lo hace por ti. Detecta lo que tienes instalado, descarga el arte oficial y crea el
acceso directo, de modo que el juego aparece en Big Picture como uno más.

<!-- TODO: captura de la ventana principal (docs/captura.png) -->

## Características

- **Detección automática** de los juegos instalados, según su origen:

  | Origen | Dónde lo busca | Cómo lo lanza |
  |---|---|---|
  | Xbox / Game Pass | `<unidad>\XboxGames\*\Content\` | `gamelaunchhelper.exe`, el lanzador oficial |
  | Ubisoft Connect | Registro de Windows | `UbisoftConnect.exe` con `uplay://launch/<id>/0` |
  | Epic Games | Manifiestos de `ProgramData\Epic` | El ejecutable del juego |
  | GOG | Registro de Windows | El ejecutable del juego |
  | Apps de la Microsoft Store | Menú Inicio | `explorer.exe shell:AppsFolder\<AUMID>` |
  | Programas recientes | Historial de ejecución de Windows | El ejecutable |
  | Cualquier otro | Botón *Examinar .exe…* | El ejecutable |

  Las apps de la Store y los programas recientes están desactivados por defecto, porque llenan
  la lista de cosas que no son juegos. Se activan con sus casillas.

- **Carátulas automáticas.** Genera las cinco imágenes que usa Steam: portada, cápsula, hero,
  logo e icono.
- **Vista previa.** Puedes ver las carátulas antes de modificar nada en Steam.
- **Marca los juegos que ya están en Steam** y los muestra al final de la lista.
- **Copia de seguridad** de `shortcuts.vdf` antes de cada escritura.
- **Reabre Steam** al terminar, en Big Picture si lo prefieres.
- **Modo consola** para usarlo sin ventana.

## Requisitos

- Windows 10 u 11.
- Windows PowerShell 5.1, que ya viene instalado en Windows. No hace falta PowerShell 7.
- Steam instalado, con al menos una sesión iniciada en el equipo.
- Conexión a internet para descargar las carátulas. Sin conexión, las compone con las imágenes
  que traiga el propio juego.

## Instalación

1. Descarga el proyecto (botón **Code → Download ZIP**) y descomprímelo en una carpeta
   donde tengas permiso de escritura, por ejemplo `Documentos\Vaporera Arcade`.
2. **Desbloquea los ficheros.** Windows marca como peligrosos los ficheros descargados de
   internet y puede impedir que se ejecuten. Abre PowerShell en la carpeta y ejecuta:

   ```powershell
   Get-ChildItem -Recurse | Unblock-File
   ```

   También puedes hacerlo con el ZIP antes de descomprimirlo: clic derecho → *Propiedades* →
   marcar *Desbloquear*.

> **Importante:** los ficheros `.ps1` están guardados en UTF-8 **con BOM**. Si los editas,
> mantén esa codificación; si no, PowerShell 5.1 mostrará mal las tildes y la ñ.

## Uso

### Con ventana

Haz doble clic en **`Vaporera Arcade.vbs`**. Abre la aplicación sin mostrar la consola.

1. Elige un juego de la lista. Puedes filtrarla con el buscador.
2. Si quieres, cambia el nombre con el que aparecerá en Steam o las opciones de lanzamiento.
3. Pulsa **1. Preparar carátulas** y revisa la vista previa.
4. Pulsa **2. Añadir a Steam**. La aplicación cierra Steam, añade el juego, copia las imágenes
   y vuelve a abrir Steam.

Casillas de la parte inferior:

- **Reabrir Steam en Big Picture:** al terminar abre Steam directamente en modo Big Picture.
- **Reemplazar si ya existe:** sobrescribe el acceso directo si ya había uno con el mismo
  nombre o el mismo ejecutable.

### Modo consola

```powershell
powershell -ExecutionPolicy Bypass -File .\VaporeraArcade.ps1 -Consola
```

Con `-Juego` filtra la lista por nombre:

```powershell
powershell -ExecutionPolicy Bypass -File .\VaporeraArcade.ps1 -Consola -Juego "Forza"
```

## De dónde salen las carátulas

Por orden de preferencia:

1. **Microsoft Store.** Los juegos de Xbox / Game Pass indican su identificador de la Store
   en `MicrosoftGame.config`. Con él, el catálogo público de la Store devuelve el arte oficial
   del juego sin necesidad de claves. En los juegos de otros orígenes se busca por el nombre.
2. **SteamGridDB** (opcional). Se usa cuando la Store no tiene el juego. Necesita una clave de
   API, que es gratuita: consíguela en tu [perfil de SteamGridDB](https://www.steamgriddb.com/profile/preferences/api),
   pulsa **Ajustes…** en la aplicación, pégala y usa **Probar** para comprobar que funciona.
   Se guarda en `%LOCALAPPDATA%\VaporeraArcade\config.json`, fuera de la carpeta de la aplicación.
3. **Imágenes del propio juego.** Si no hay nada más, compone las carátulas con el fondo y el
   logo que trae el juego instalado.

Imágenes que se generan en `Steam\userdata\<usuario>\config\grid\`:

| Fichero | Tamaño | Dónde se ve |
|---|---|---|
| `<appid>p.png` | 600×900 | Portada vertical de la biblioteca y de Big Picture |
| `<appid>.png` | 460×215 | Cápsula horizontal |
| `<appid>_hero.png` | 1920×620 | Cabecera de la página del juego |
| `<appid>_logo.png` | Variable | Logo sobre la cabecera |
| `<appid>_icon.png` | 256×256 | Icono |

## Limitaciones conocidas

Son limitaciones de Steam y de cada plataforma, no de esta aplicación:

- **Xbox / Game Pass:** Steam no muestra el overlay ni cuenta las horas de juego.
  `gamelaunchhelper.exe` arranca el juego y termina, así que Steam deja de seguir el proceso.
- **Apps de la Microsoft Store:** ocurre lo mismo. Además, la ventana puede quedar detrás de
  Big Picture.
- **Si cambia el ejecutable de un juego, cambia su identificador en Steam** y las carátulas
  dejan de aparecer. Vuelve a añadirlo con la casilla *Reemplazar si ya existe* marcada.
- **Steam tiene que cerrarse** para modificar `shortcuts.vdf`; si no, lo sobrescribe al salir.
  La aplicación lo cierra sola y espera hasta 40 segundos. Si no se cierra, cancela la operación
  sin tocar nada.

## Quitar un juego

Por ahora no hay botón para quitar juegos. Puedes quitarlo desde Steam (clic derecho sobre el
juego → *Administrar* y la opción para quitarlo de la biblioteca) o, con Steam cerrado, desde
PowerShell en la carpeta de la aplicación:

```powershell
. .\lib\Vdf.ps1
. .\lib\SteamCtl.ps1
$s = Get-SteamInfo
Backup-Shortcuts -Ruta $s.Shortcuts
Remove-SteamShortcut -RutaVdf $s.Shortcuts -Nombre 'Nombre exacto del juego'
```

Las imágenes de `config\grid\` no se borran solas. Puedes eliminarlas a mano.

## Cómo funciona por dentro

```
Vaporera Arcade
├── VaporeraArcade.ps1           aplicación: ventana WPF y modo consola
├── Vaporera Arcade.vbs          lanzador sin ventana de consola
└── lib
    ├── Config.ps1               ajustes del usuario (config.json en %LOCALAPPDATA%)
    ├── Vdf.ps1                  lectura y escritura del formato VDF binario y cálculo del appid
    ├── Fuentes.ps1              detección de juegos según su origen
    ├── Caratulas.ps1            descarga y composición de carátulas
    └── SteamCtl.ps1             localizar, cerrar y abrir Steam, y editar shortcuts.vdf
```

- **`shortcuts.vdf` se lee entero y se vuelve a escribir** a partir de su estructura, no
  insertando bytes sueltos. Leer el fichero y guardarlo sin cambios produce un fichero idéntico
  byte a byte.
- **El appid** de un acceso directo es `CRC32(exe_entre_comillas + nombre) | 0x80000000`, el
  mismo cálculo que hace Steam. Por eso las carátulas se asocian al juego correcto.
- Las entradas nuevas tienen la misma estructura que las que crea Steam.

## Aviso

Vaporera Arcade es un proyecto personal y no tiene relación con Valve, Microsoft, Epic Games,
GOG ni Ubisoft. Usa servicios no documentados del catálogo de la Microsoft Store, que podrían
cambiar o dejar de funcionar en cualquier momento.

La aplicación modifica `shortcuts.vdf` de Steam. Siempre hace una copia de seguridad antes
(`shortcuts.vdf.bak-<fecha>`, en la misma carpeta), pero úsala bajo tu responsabilidad.

## Licencia

Distribuido bajo la licencia [MIT](LICENSE). Puedes usarlo, modificarlo y compartirlo
libremente, siempre que mantengas el aviso de copyright.
