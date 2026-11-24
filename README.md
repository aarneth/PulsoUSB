# PulsoUSB - Gestor de Salud USB

Programa con ventana para diagnosticar y administrar unidades USB (memorias, discos externos, lectores SD).
Compatible con **Windows 10 (1703+) y Windows 11**. No requiere instalar nada (usa PowerShell 5.1 incluido en Windows).

## Cómo ejecutarlo
1. Doble clic en **`Iniciar Gestor USB.cmd`**.
2. Acepte el aviso de Control de cuentas de usuario (se necesitan permisos de administrador).

Ambos archivos (`.cmd` y `GestorSaludUSB.ps1`) deben estar en la misma carpeta.

## Funciones
| Grupo | Función |
|---|---|
| Salud | Estado del disco según Windows, SMART (si el dispositivo lo expone), contadores de confiabilidad (temperatura, desgaste, errores), estado de cada volumen |
| Salud | **Prueba de velocidad e integridad**: escribe datos y los verifica leyendo sin caché. Mide la velocidad real y detecta memorias **falsas** o con celdas dañadas (no borra sus archivos) |
| Formato | Formatear una partición o el disco completo en exFAT / FAT32 / NTFS, rápido o completo, MBR o GPT |
| Particiones | Crear, eliminar, redimensionar (solo NTFS) y cambiar/quitar la letra de unidad |
| Reparación | CHKDSK (revisar, reparar `/f`, sectores defectuosos `/r`), quitar protección contra escritura, expulsión segura |
| Otros | Detección automática al conectar o desconectar unidades, exportar reporte `.txt` |

## Seguridad
- Solo se listan discos con bus USB, SD o MMC; el disco de sistema/arranque nunca se puede modificar.
- Las operaciones destructivas piden escribir `BORRAR` para confirmar.

## Limitaciones (propias de Windows)
- Casi ninguna memoria USB expone SMART; por eso la prueba de integridad es la referencia más fiable.
- Windows no formatea en FAT32 volúmenes mayores de 32 GB (use exFAT).
- Redimensionar solo funciona con NTFS.
