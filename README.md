<p align="center"><img src="assets/icon-256.png" width="96" alt="PulsoUSB"></p>

# PulsoUSB

**Tómale el pulso a tus memorias USB.** Diagnóstico de salud, prueba de integridad (detecta memorias **falsas** o dañadas), formato y particiones para unidades USB, SD y discos externos.
Compatible con **Windows 10 (1703+) y Windows 11**.

## Descarga
En [**Releases**](https://github.com/aarneth/PulsoUSB/releases/latest) hay dos opciones:

| Archivo | Para qué |
|---|---|
| `PulsoUSB-Setup-<versión>.exe` | **Instalador**: instala en *Archivos de programa* y crea accesos directos en el menú Inicio y el escritorio. Se desinstala desde *Configuración > Aplicaciones*. |
| `PulsoUSB-Portable-<versión>.exe` | **Portable**: un solo .exe, sin instalación. Puedes llevarlo en la misma memoria USB. |

Los dos piden permisos de administrador al abrirse (son necesarios para leer y modificar discos).

> Los .exe no están firmados digitalmente, así que Windows SmartScreen puede mostrar "Windows protegió su PC". Pulsa **Más información > Ejecutar de todas formas**. Puedes comprobar los archivos con `SHA256SUMS.txt`.

**Instalación silenciosa** (para TI): `PulsoUSB-Setup-<versión>.exe /S` · desinstalar: `"C:\Program Files\PulsoUSB\uninstall.exe" /uninstall /S`

## Funciones
| Grupo | Función |
|---|---|
| Salud | Estado del disco según Windows, SMART (si el dispositivo lo expone), contadores de confiabilidad (temperatura, desgaste, errores) y estado de cada volumen, con un resumen de color |
| Salud | **Prueba de velocidad e integridad**: escribe datos y los verifica leyendo sin caché. Mide la velocidad real y detecta memorias falsas o con celdas dañadas (no borra tus archivos) |
| Formato | Formatear una partición o el disco completo en exFAT / FAT32 / NTFS, rápido o completo, MBR o GPT |
| Particiones | Crear, eliminar, redimensionar (solo NTFS) y cambiar o quitar la letra de unidad |
| Reparación | CHKDSK (revisar, reparar `/f`, sectores defectuosos `/r`), quitar protección contra escritura, expulsión segura |
| Otros | Detección automática al conectar o desconectar unidades, exportar reporte `.txt` |

## Seguridad
- Solo se listan discos con bus USB, SD o MMC. El disco de sistema o de arranque nunca se puede modificar.
- Las operaciones destructivas piden escribir `BORRAR` para confirmar.

## Limitaciones (propias de Windows)
- Casi ninguna memoria USB expone SMART; por eso la prueba de integridad es la referencia más fiable.
- Windows no formatea en FAT32 volúmenes de más de 32 GB (usa exFAT).
- Redimensionar solo funciona con NTFS.

## Ejecutar desde el código fuente
Sin compilar: doble clic en `Iniciar PulsoUSB.cmd` (ejecuta `PulsoUSB.ps1` con PowerShell 5.1).

Compilar los .exe (no necesita instalar nada; usa el compilador de .NET Framework incluido en Windows):

```powershell
powershell -ExecutionPolicy Bypass -File .\build.ps1
```

Los archivos quedan en `dist\`.

| Archivo | Contenido |
|---|---|
| `PulsoUSB.ps1` | El programa (interfaz WinForms + lógica) |
| `src/Launcher.cs` | Lanzador `PulsoUSB.exe`: ejecuta el script incrustado |
| `src/Setup.cs` | Instalador / desinstalador |
| `src/app.manifest` | Solicita administrador y declara compatibilidad con Windows 10/11 |
| `build.ps1` | Compila todo y genera el icono |
