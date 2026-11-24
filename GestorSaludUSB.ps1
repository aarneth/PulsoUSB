<#
    Gestor de Salud USB  v1.0
    ---------------------------------------------------------------
    Diagnóstico y administración de unidades de almacenamiento USB.
    Compatible con Windows 10 (1703+) y Windows 11 - PowerShell 5.1
    Requiere permisos de administrador (se solicitan automáticamente).

    Funciones:
      - Estado de salud (estado del disco, SMART si está disponible,
        contadores de confiabilidad, estado de volúmenes)
      - Prueba de velocidad e integridad (detecta USB falsas / dañadas)
      - Formatear partición o disco completo (FAT32 / exFAT / NTFS)
      - Crear, eliminar, redimensionar particiones y cambiar letra
      - CHKDSK, quitar protección contra escritura, expulsión segura
      - Exportar reporte
#>

$script:AppName = 'Gestor de Salud USB'

# ------------------------------------------------------------------
#  Elevación a administrador
# ------------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Sta', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"")
    } catch {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show(
            "Este programa necesita permisos de administrador para leer el estado de los discos y modificarlos.`n`nVuelva a ejecutarlo y acepte el aviso de Control de cuentas de usuario.",
            $script:AppName, 'OK', 'Warning')
    }
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
# Necesario en el hilo principal: sus definiciones de tipo convierten los códigos
# numéricos (HealthStatus, BusType, etc.) en texto, también para objetos del segundo plano.
Import-Module Storage -ErrorAction SilentlyContinue

# ------------------------------------------------------------------
#  Código nativo (C#): prueba de integridad, expulsión, utilidades UI
# ------------------------------------------------------------------
if (-not ('UsbTool.Tester' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace UsbTool
{
    public static class NativeUi
    {
        [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
        [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
        public static void HideConsole()
        {
            IntPtr h = GetConsoleWindow();
            if (h != IntPtr.Zero) ShowWindow(h, 0);
        }
    }

    public class TestResult
    {
        public long BytesPlanned;
        public long BytesWritten;
        public long BytesVerified;
        public long BytesCorrupted;
        public long BadBlocks;
        public long FirstErrorMB = -1;
        public double WriteMBps;
        public double ReadMBps;
        public int Files;
        public bool Cancelled;
        public bool DiskFull;
        public string Error;
    }

    // Escribe archivos con un patrón pseudoaleatorio determinista y luego los
    // relee sin caché (FILE_FLAG_NO_BUFFERING) para verificar cada byte.
    // Si la unidad es falsa (capacidad real menor) o tiene celdas dañadas,
    // los datos leídos no coincidirán.
    public static class Tester
    {
        const uint GENERIC_READ = 0x80000000;
        const uint GENERIC_WRITE = 0x40000000;
        const uint FILE_SHARE_READ = 0x1;
        const uint CREATE_ALWAYS = 2;
        const uint OPEN_EXISTING = 3;
        const uint FLAG_NO_BUFFERING = 0x20000000;
        const uint FLAG_WRITE_THROUGH = 0x80000000;
        const uint FLAG_SEQUENTIAL = 0x08000000;
        const int BLOCK = 1048576;              // 1 MiB por bloque
        const long FILE_BYTES = 1073741824L;    // 1 GiB por archivo (compatible FAT32)
        const int ERROR_HANDLE_DISK_FULL = 39;
        const int ERROR_DISK_FULL = 112;

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool WriteFile(SafeFileHandle h, IntPtr buf, uint n, out uint done, IntPtr ov);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool ReadFile(SafeFileHandle h, IntPtr buf, uint n, out uint done, IntPtr ov);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetFilePointerEx(SafeFileHandle h, long dist, IntPtr newPos, uint method);

        static void Fill(long[] buf, int file, int block)
        {
            ulong s = (((ulong)(uint)file) << 32) ^ (ulong)(uint)block ^ 0x5DEECE66DUL;
            for (int i = 0; i < buf.Length; i++)
            {
                s += 0x9E3779B97F4A7C15UL;
                ulong z = s;
                z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL;
                z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL;
                z ^= z >> 31;
                buf[i] = (long)z;
            }
        }

        static bool IsCancel(Hashtable sync)
        {
            object o = sync["Cancel"];
            return (o is bool) && (bool)o;
        }

        static void Report(Hashtable sync, int pct, string status)
        {
            sync["Progress"] = pct;
            sync["Status"] = status;
        }

        public static TestResult Run(string root, long bytes, Hashtable sync, bool deleteAfter)
        {
            TestResult res = new TestResult();
            string dir = Path.Combine(root, "USB_TEST_TMP");
            List<string> files = new List<string>();
            List<int> blocksIn = new List<int>();
            IntPtr raw = IntPtr.Zero;
            try
            {
                Directory.CreateDirectory(dir);
                DriveInfo di = new DriveInfo(Path.GetPathRoot(Path.GetFullPath(root)));
                long max = di.AvailableFreeSpace - 4L * BLOCK;
                if (bytes <= 0 || bytes > max) bytes = max;
                long totalBlocks = bytes / BLOCK;
                if (totalBlocks < 1) { res.Error = "Espacio libre insuficiente para la prueba."; return res; }
                res.BytesPlanned = totalBlocks * BLOCK;

                raw = Marshal.AllocHGlobal(BLOCK + 4096);
                IntPtr buf = new IntPtr((raw.ToInt64() + 4095) & ~4095L);   // búfer alineado (requisito de NO_BUFFERING)
                long[] pat = new long[BLOCK / 8];
                long[] got = new long[BLOCK / 8];
                int perFile = (int)(FILE_BYTES / BLOCK);
                Stopwatch sw = new Stopwatch();

                // ---------------- Fase 1: escritura ----------------
                long done = 0; int fileIdx = 0; bool stop = false;
                while (done < totalBlocks && !stop)
                {
                    string path = Path.Combine(dir, string.Format("test_{0:D4}.bin", fileIdx + 1));
                    int n = (int)Math.Min(perFile, totalBlocks - done);
                    int written = 0;
                    files.Add(path);
                    using (SafeFileHandle h = CreateFileW(path, GENERIC_WRITE, 0, IntPtr.Zero, CREATE_ALWAYS, FLAG_NO_BUFFERING | FLAG_WRITE_THROUGH, IntPtr.Zero))
                    {
                        if (h.IsInvalid)
                        {
                            int e = Marshal.GetLastWin32Error();
                            if (e == ERROR_DISK_FULL || e == ERROR_HANDLE_DISK_FULL) { res.DiskFull = true; blocksIn.Add(0); break; }
                            res.Error = "No se pudo crear el archivo de prueba (Win32 " + e + ").";
                            blocksIn.Add(0); break;
                        }
                        for (int b = 0; b < n; b++)
                        {
                            if (IsCancel(sync)) { res.Cancelled = true; stop = true; break; }
                            Fill(pat, fileIdx, b);
                            Marshal.Copy(pat, 0, buf, pat.Length);
                            uint w;
                            sw.Start();
                            bool ok = WriteFile(h, buf, (uint)BLOCK, out w, IntPtr.Zero);
                            sw.Stop();
                            if (!ok || w != BLOCK)
                            {
                                int e = Marshal.GetLastWin32Error();
                                if (e == ERROR_DISK_FULL || e == ERROR_HANDLE_DISK_FULL) res.DiskFull = true;
                                else res.Error = "Error de escritura en el MB " + done + " (Win32 " + e + "). La unidad podría estar dañada.";
                                stop = true; break;
                            }
                            written++; done++;
                            if ((done & 7) == 0 || done == totalBlocks)
                            {
                                double sec = sw.Elapsed.TotalSeconds;
                                double rate = sec > 0 ? done / sec : 0;
                                Report(sync, (int)(done * 50 / totalBlocks),
                                    string.Format("Escribiendo: {0:N0} / {1:N0} MB  ({2:N1} MB/s)", done, totalBlocks, rate));
                            }
                        }
                    }
                    blocksIn.Add(written);
                    fileIdx++;
                }
                res.Files = files.Count;
                res.BytesWritten = done * BLOCK;
                if (sw.Elapsed.TotalSeconds > 0) res.WriteMBps = done / sw.Elapsed.TotalSeconds;
                if (res.Cancelled || done == 0) return res;

                // ---------------- Fase 2: verificación ----------------
                sw.Reset();
                long vdone = 0; long global = 0;
                for (int f = 0; f < files.Count; f++)
                {
                    int n = blocksIn[f];
                    if (n == 0) continue;
                    using (SafeFileHandle h = CreateFileW(files[f], GENERIC_READ, FILE_SHARE_READ, IntPtr.Zero, OPEN_EXISTING, FLAG_NO_BUFFERING | FLAG_SEQUENTIAL, IntPtr.Zero))
                    {
                        if (h.IsInvalid)
                        {
                            res.BytesCorrupted += (long)n * BLOCK; res.BadBlocks += n;
                            if (res.FirstErrorMB < 0) res.FirstErrorMB = global;
                            vdone += n; global += n; continue;
                        }
                        for (int b = 0; b < n; b++)
                        {
                            if (IsCancel(sync)) { res.Cancelled = true; break; }
                            SetFilePointerEx(h, (long)b * BLOCK, IntPtr.Zero, 0);
                            uint r;
                            sw.Start();
                            bool ok = ReadFile(h, buf, (uint)BLOCK, out r, IntPtr.Zero);
                            sw.Stop();
                            if (!ok || r != BLOCK)
                            {
                                res.BytesCorrupted += BLOCK; res.BadBlocks++;
                                if (res.FirstErrorMB < 0) res.FirstErrorMB = global;
                            }
                            else
                            {
                                Marshal.Copy(buf, got, 0, got.Length);
                                Fill(pat, f, b);
                                int bad = 0;
                                for (int i = 0; i < got.Length; i++) if (got[i] != pat[i]) bad++;
                                if (bad > 0)
                                {
                                    res.BytesCorrupted += (long)bad * 8; res.BadBlocks++;
                                    if (res.FirstErrorMB < 0) res.FirstErrorMB = global;
                                }
                                res.BytesVerified += BLOCK;
                            }
                            vdone++; global++;
                            if ((vdone & 7) == 0 || vdone == done)
                            {
                                double sec = sw.Elapsed.TotalSeconds;
                                double rate = sec > 0 ? vdone / sec : 0;
                                Report(sync, 50 + (int)(vdone * 50 / done),
                                    string.Format("Verificando: {0:N0} / {1:N0} MB  ({2:N1} MB/s)  Errores: {3:N0} MB", vdone, done, rate, res.BadBlocks));
                            }
                        }
                    }
                    if (res.Cancelled) break;
                }
                if (sw.Elapsed.TotalSeconds > 0) res.ReadMBps = vdone / sw.Elapsed.TotalSeconds;
                return res;
            }
            catch (Exception ex)
            {
                res.Error = ex.Message;
                return res;
            }
            finally
            {
                if (raw != IntPtr.Zero) Marshal.FreeHGlobal(raw);
                if (deleteAfter)
                {
                    Report(sync, -1, "Eliminando archivos de prueba...");
                    foreach (string p in files) { try { File.Delete(p); } catch { } }
                    try { Directory.Delete(dir, false); } catch { }
                }
            }
        }
    }

    // Expulsión segura mediante el Administrador de configuración (cfgmgr32)
    public static class Ejector
    {
        [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
        static extern int CM_Locate_DevNodeW(out uint devInst, string deviceId, int flags);
        [DllImport("cfgmgr32.dll")]
        static extern int CM_Get_Parent(out uint parent, uint devInst, int flags);
        [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
        static extern int CM_Request_Device_EjectW(uint devInst, out int vetoType, StringBuilder vetoName, int nameLength, int flags);

        static string Describe(int veto, string name, int cr)
        {
            string why;
            switch (veto)
            {
                case 2: why = "hay un cierre pendiente de archivos"; break;
                case 3: why = "una aplicación está usando la unidad"; break;
                case 4: why = "un servicio está usando la unidad"; break;
                case 5: why = "hay archivos o carpetas abiertos en la unidad"; break;
                case 6: case 7: why = "otro dispositivo o controlador lo impide"; break;
                case 10: why = "el dispositivo no se puede deshabilitar"; break;
                case 12: why = "permisos insuficientes"; break;
                case 0: why = (cr != 0) ? ("error del sistema CR=" + cr) : "motivo desconocido"; break;
                default: why = "veto tipo " + veto; break;
            }
            if (!string.IsNullOrEmpty(name)) why += " (" + name + ")";
            return "No se pudo expulsar: " + why + ". Cierre las ventanas y programas que usen la unidad e inténtelo de nuevo.";
        }

        public static string Eject(string pnpId)
        {
            uint inst;
            int cr = CM_Locate_DevNodeW(out inst, pnpId, 0);
            if (cr != 0) return "No se encontró el dispositivo en el sistema (CR=" + cr + ").";
            string last = "";
            // Intenta con el disco y, si no, con su dispositivo USB padre (nunca más arriba: podría ser un hub)
            for (int i = 0; i < 2; i++)
            {
                int veto;
                StringBuilder sb = new StringBuilder(512);
                cr = CM_Request_Device_EjectW(inst, out veto, sb, sb.Capacity, 0);
                if (cr == 0 && veto == 0) return "OK";
                last = Describe(veto, sb.ToString(), cr);
                if (veto >= 2 && veto <= 5) break;       // en uso: subir de nivel no ayuda
                uint parent;
                if (CM_Get_Parent(out parent, inst, 0) != 0) break;
                inst = parent;
            }
            return last;
        }
    }
}
'@
}

try { [void][UsbTool.NativeUi]::SetProcessDPIAware() } catch {}
[UsbTool.NativeUi]::HideConsole()
[System.Windows.Forms.Application]::EnableVisualStyles()

$g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
$script:Scale = [Math]::Max(1.0, $g.DpiX / 96.0)
$g.Dispose()
function S([double]$v) { [int]([Math]::Round($v * $script:Scale)) }

$script:FontNormal = New-Object System.Drawing.Font('Segoe UI', 9)
$script:FontBold   = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$script:FontTitle  = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
$script:FontMono   = New-Object System.Drawing.Font('Consolas', 9)

$script:SelDisk      = $null
$script:Binding      = $false
$script:Busy         = $false
$script:Modal        = 0
$script:TickCount    = 0
$script:Signature    = ''
$script:Tasks        = New-Object System.Collections.ArrayList
$script:CurrentTask  = $null
$script:TestResults  = @{}
$script:ActionButtons = New-Object System.Collections.ArrayList

$C_OK   = [System.Drawing.Color]::FromArgb(0, 128, 0)
$C_INFO = [System.Drawing.Color]::FromArgb(60, 60, 60)
$C_WARN = [System.Drawing.Color]::FromArgb(200, 110, 0)
$C_CRIT = [System.Drawing.Color]::FromArgb(200, 0, 0)
$C_HEAD = [System.Drawing.Color]::FromArgb(0, 70, 140)

# ------------------------------------------------------------------
#  Utilidades generales
# ------------------------------------------------------------------
function Format-Size([double]$b) {
    if ($b -ge 1TB) { return '{0:N2} TB' -f ($b / 1TB) }
    if ($b -ge 1GB) { return '{0:N2} GB' -f ($b / 1GB) }
    if ($b -ge 1MB) { return '{0:N1} MB' -f ($b / 1MB) }
    if ($b -ge 1KB) { return '{0:N0} KB' -f ($b / 1KB) }
    return "$([int64]$b) B"
}

function Write-Log([string]$msg) {
    $line = '[{0:HH:mm:ss}] {1}' -f (Get-Date), $msg
    $txtLog.AppendText($line + [Environment]::NewLine)
}

function Show-Msg([string]$Text, [string]$Icon = 'Information', [string]$Buttons = 'OK') {
    $script:Modal++
    try { return [System.Windows.Forms.MessageBox]::Show($script:Form, $Text, $script:AppName, $Buttons, $Icon) }
    finally { $script:Modal-- }
}

function Get-HealthText($v) {
    switch ("$v") {
        'Healthy'   { 'Saludable' }
        'Warning'   { 'Advertencia' }
        'Unhealthy' { 'Dañado' }
        default     { if ("$v") { "$v" } else { 'Desconocido' } }
    }
}

function Get-OpText($v) {
    $s = "$v"
    switch -Wildcard ($s) {
        'Online'    { 'En línea' }
        'Offline'   { 'Sin conexión' }
        '*No Media*'{ 'Sin medio' }
        default     { if ($s) { $s } else { 'Desconocido' } }
    }
}

function Get-YesNo($b) { if ($b) { 'Sí' } else { 'No' } }

function Get-UsbDisks {
    @(Get-Disk -ErrorAction SilentlyContinue | Where-Object { "$($_.BusType)" -in @('USB', 'SD', 'MMC', '7', '12', '13') } | Sort-Object Number)
}

function Test-SafeDisk($d) {
    if (-not $d) { return $false }
    if ($d.IsBoot -or $d.IsSystem) { return $false }
    return ("$($d.BusType)" -in @('USB', 'SD', 'MMC', '7', '12', '13'))
}

function Get-DeviceSignature {
    $a = @(Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Index):$($_.Size)" }) -join ','
    $b = @([System.IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name }) -join ','
    "$a|$b"
}

function Get-TestKey($d) {
    $sn = "$($d.SerialNumber)".Trim()
    if ($sn) { return "SN:$sn" }
    return "N:$($d.Number)"
}

function Get-FreeLetters {
    $used = @()
    $used += @([System.IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpper() })
    $used += @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { "$($_.DriveLetter)" -match '^[A-Za-z]$' } | ForEach-Object { "$($_.DriveLetter)".ToUpper() })
    $used += @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | ForEach-Object { $_.Name.ToUpper() })
    @([char[]](68..90) | ForEach-Object { "$_" } | Where-Object { $used -notcontains $_ })
}

# ------------------------------------------------------------------
#  Diálogos
# ------------------------------------------------------------------
function New-Combo([string[]]$Items, [int]$Selected = 0) {
    $c = New-Object System.Windows.Forms.ComboBox
    $c.DropDownStyle = 'DropDownList'
    foreach ($i in $Items) { [void]$c.Items.Add($i) }
    if ($c.Items.Count -gt 0) { $c.SelectedIndex = [Math]::Min($Selected, $c.Items.Count - 1) }
    return $c
}

function New-Check([string]$Text, [bool]$Checked) {
    $c = New-Object System.Windows.Forms.CheckBox
    $c.Text = $Text; $c.Checked = $Checked; $c.AutoSize = $true
    return $c
}

function New-InfoLabel([string]$Text) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text; $l.AutoSize = $true; $l.MaximumSize = New-Object System.Drawing.Size((S 300), 0)
    return $l
}

function Show-InputDialog {
    param([string]$Title, [System.Collections.Specialized.OrderedDictionary]$Fields, [string]$Note, [string]$OkText = 'Aceptar')
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $Title
    $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.StartPosition = 'CenterParent'; $dlg.ShowInTaskbar = $false; $dlg.Font = $script:FontNormal
    $dlg.AutoSize = $true; $dlg.AutoSizeMode = 'GrowAndShrink'
    $dlg.Padding = New-Object System.Windows.Forms.Padding((S 12))

    $tl = New-Object System.Windows.Forms.TableLayoutPanel
    $tl.AutoSize = $true; $tl.AutoSizeMode = 'GrowAndShrink'; $tl.ColumnCount = 2
    $tl.Location = New-Object System.Drawing.Point((S 12), (S 12))
    [void]$tl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$tl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $row = 0
    if ($Note) {
        $ln = New-Object System.Windows.Forms.Label
        $ln.Text = $Note; $ln.AutoSize = $true
        $ln.MaximumSize = New-Object System.Drawing.Size((S 480), 0)
        $ln.Margin = New-Object System.Windows.Forms.Padding(3, 3, 3, (S 12))
        $tl.Controls.Add($ln, 0, $row); $tl.SetColumnSpan($ln, 2); $row++
    }
    foreach ($key in $Fields.Keys) {
        $ctl = $Fields[$key]
        if ($ctl -is [System.Windows.Forms.CheckBox]) {
            $tl.Controls.Add($ctl, 1, $row)
        } else {
            $l = New-Object System.Windows.Forms.Label
            $l.Text = $key; $l.AutoSize = $true; $l.Anchor = 'Left'
            $tl.Controls.Add($l, 0, $row)
            if (-not ($ctl -is [System.Windows.Forms.Label])) { $ctl.Width = (S 280) }
            $ctl.Anchor = 'Left'
            $tl.Controls.Add($ctl, 1, $row)
        }
        $row++
    }
    $fl = New-Object System.Windows.Forms.FlowLayoutPanel
    $fl.FlowDirection = 'RightToLeft'; $fl.AutoSize = $true; $fl.Dock = 'Fill'
    $fl.Margin = New-Object System.Windows.Forms.Padding(0, (S 14), 0, 0)
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = $OkText; $ok.DialogResult = 'OK'; $ok.AutoSize = $true; $ok.MinimumSize = New-Object System.Drawing.Size((S 90), 0)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancelar'; $cancel.DialogResult = 'Cancel'; $cancel.AutoSize = $true; $cancel.MinimumSize = New-Object System.Drawing.Size((S 90), 0)
    $fl.Controls.Add($cancel); $fl.Controls.Add($ok)
    $tl.Controls.Add($fl, 0, $row); $tl.SetColumnSpan($fl, 2)
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel
    $dlg.Controls.Add($tl)

    $script:Modal++
    try { $res = $dlg.ShowDialog($script:Form) } finally { $script:Modal-- }
    return ($res -eq [System.Windows.Forms.DialogResult]::OK)
}

function Confirm-Typed([string]$Message, [string]$Word = 'BORRAR') {
    $tb = New-Object System.Windows.Forms.TextBox
    $f = [ordered]@{ "Escriba $Word para confirmar:" = $tb }
    if (-not (Show-InputDialog -Title 'Confirmar operación destructiva' -Fields $f -Note $Message -OkText 'Continuar')) { return $false }
    if ($tb.Text.Trim().ToUpper() -ne $Word) {
        [void](Show-Msg 'El texto de confirmación no coincide. Operación cancelada.' 'Warning')
        return $false
    }
    return $true
}

function Get-DiskDescription($d) {
    $letters = @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue | Where-Object { "$($_.DriveLetter)" -match '^[A-Z]$' } | ForEach-Object { "$($_.DriveLetter):" }) -join ' '
    if (-not $letters) { $letters = '(sin letra)' }
    "Disco $($d.Number): $($d.FriendlyName)  -  $(Format-Size $d.Size)  -  Unidades: $letters"
}

# ------------------------------------------------------------------
#  Ejecución en segundo plano (para que la ventana no se congele)
# ------------------------------------------------------------------
function Set-UiBusy([bool]$busy, [bool]$cancelable = $false) {
    foreach ($b in $script:ActionButtons) { $b.Enabled = -not $busy }
    $btnRefresh.Enabled = -not $busy
    $btnCancel.Enabled = $busy -and $cancelable
    $progress.Visible = $busy
    if (-not $busy) { $progress.Style = 'Continuous'; $progress.Value = 0 }
    $script:Form.Cursor = if ($busy) { [System.Windows.Forms.Cursors]::AppStarting } else { [System.Windows.Forms.Cursors]::Default }
}

function Start-BgTask {
    param(
        [string]$Name,
        [string]$Script,
        [hashtable]$Params = @{},
        [scriptblock]$OnDone,
        [object]$Context,
        [switch]$Exclusive,
        [switch]$Cancelable
    )
    if ($Exclusive) {
        if ($script:Busy) { [void](Show-Msg 'Ya hay una operación en curso. Espere a que termine.' 'Warning'); return $null }
        $script:Busy = $true
        Set-UiBusy $true ([bool]$Cancelable)
        $progress.Style = 'Marquee'
        $lblStatus.Text = "$Name..."
        Write-Log "Iniciando: $Name"
    }
    $sync = [hashtable]::Synchronized(@{
        Progress = -1; Status = ''; Cancel = $false; Error = $null
        Log = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    })
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($Script)
    [void]$ps.AddParameter('sync', $sync)
    foreach ($k in $Params.Keys) { [void]$ps.AddParameter($k, $Params[$k]) }
    $task = [pscustomobject]@{
        Name = $Name; PS = $ps; Handle = $ps.BeginInvoke(); Sync = $sync
        OnDone = $OnDone; Context = $Context; Exclusive = [bool]$Exclusive
    }
    [void]$script:Tasks.Add($task)
    if ($Exclusive) { $script:CurrentTask = $task }
    return $task
}

function Invoke-TaskPump {
    foreach ($t in @($script:Tasks)) {
        $msg = $null
        while ($t.Sync.Log.TryDequeue([ref]$msg)) { Write-Log $msg }
        if ($t.Exclusive) {
            $p = [int]$t.Sync.Progress
            if ($p -ge 0) {
                if ($progress.Style -ne 'Continuous') { $progress.Style = 'Continuous' }
                $progress.Value = [Math]::Min(100, [Math]::Max(0, $p))
            } elseif ($progress.Style -ne 'Marquee') { $progress.Style = 'Marquee' }
            if ($t.Sync.Status) { $lblStatus.Text = "$($t.Sync.Status)" }
        }
        if ($t.Handle.IsCompleted) {
            $out = $null; $errs = New-Object System.Collections.ArrayList
            try { $out = $t.PS.EndInvoke($t.Handle) }
            catch {
                $e = $_.Exception
                while ($e.InnerException) { $e = $e.InnerException }
                [void]$errs.Add($e.Message)
            }
            if ($t.Sync.Error) { [void]$errs.Add("$($t.Sync.Error)") }
            if ($t.Exclusive) {
                foreach ($er in @($t.PS.Streams.Error)) { Write-Log "Aviso: $er" }
            }
            while ($t.Sync.Log.TryDequeue([ref]$msg)) { Write-Log $msg }
            $t.PS.Dispose()
            $script:Tasks.Remove($t)
            if ($t.Exclusive) {
                $script:Busy = $false
                $script:CurrentTask = $null
                Set-UiBusy $false
                $lblStatus.Text = 'Listo.'
            }
            if ($t.OnDone) {
                try { & $t.OnDone $out @($errs) $t.Context }
                catch { Write-Log "Error al procesar el resultado de '$($t.Name)': $_" }
            }
        }
    }
}

# Resultado estándar de una operación de disco
$script:StdDone = {
    param($out, $errs, $ctx)
    $errs = @($errs | Where-Object { $_ } | Select-Object -Unique)
    if ($errs.Count -gt 0) {
        foreach ($e in $errs) { Write-Log "ERROR: $e" }
        [void](Show-Msg ("La operación '$($ctx.Name)' no se pudo completar:`n`n" + ($errs -join "`n")) 'Error')
    } else {
        $extra = ''
        if ($out -and $out.Count -gt 0) { $extra = ($out | ForEach-Object { "$_" }) -join "`n" }
        Write-Log "Completado: $($ctx.Name). $extra"
        [void](Show-Msg ("$($ctx.Name): completado correctamente.`n`n$extra").Trim() 'Information')
    }
    Update-DiskList
}

function Start-DiskOp([string]$Name, [string]$Script, [hashtable]$Params) {
    [void](Start-BgTask -Name $Name -Script $Script -Params $Params -Exclusive -OnDone $script:StdDone -Context @{ Name = $Name })
}

# ------------------------------------------------------------------
#  Scripts que corren en segundo plano
# ------------------------------------------------------------------
$script:HealthScript = @'
param($sync, $n)
Import-Module Storage -ErrorAction SilentlyContinue
$d = Get-Disk -Number $n -ErrorAction SilentlyContinue
$pd = $null
try { $pd = Get-PhysicalDisk -ErrorAction Stop | Where-Object { "$($_.DeviceId)" -eq "$n" } | Select-Object -First 1 } catch {}
$w = Get-CimInstance Win32_DiskDrive -Filter "Index=$n" -ErrorAction SilentlyContinue
$rel = $null
if ($pd) { try { $rel = $pd | Get-StorageReliabilityCounter -ErrorAction Stop } catch {} }
$smart = $null
if ($w -and $w.PNPDeviceID) {
    try {
        $smart = Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction Stop |
            Where-Object { $_.InstanceName -and $_.InstanceName.StartsWith($w.PNPDeviceID, [StringComparison]::OrdinalIgnoreCase) } |
            Select-Object -First 1
    } catch {}
}
$vols = @()
foreach ($p in @(Get-Partition -DiskNumber $n -ErrorAction SilentlyContinue)) {
    $v = $null
    try { $v = Get-Volume -Partition $p -ErrorAction Stop } catch {}
    $vols += [pscustomobject]@{ Partition = $p; Volume = $v }
}
[pscustomobject]@{ Disk = $d; Phys = $pd; Wmi = $w; Rel = $rel; Smart = $smart; Vols = $vols }
'@

$script:FormatDiskScript = @'
param($sync, $n, $fs, $label, $quick, $style)
$ErrorActionPreference = 'Stop'
try {
    Import-Module Storage
    $d = Get-Disk -Number $n
    if ($d.IsBoot -or $d.IsSystem) { throw 'Por seguridad no se permite operar sobre el disco del sistema.' }
    if ($d.IsOffline)  { $sync.Log.Enqueue('Poniendo el disco en línea...'); Set-Disk -Number $n -IsOffline $false }
    if ($d.IsReadOnly) { $sync.Log.Enqueue('Quitando atributo de solo lectura...'); Set-Disk -Number $n -IsReadOnly $false }
    $d = Get-Disk -Number $n
    if ("$($d.PartitionStyle)" -ne 'RAW') {
        $sync.Status = 'Borrando tabla de particiones...'
        $sync.Log.Enqueue("Limpiando disco $n (Clear-Disk)")
        Clear-Disk -Number $n -RemoveData -RemoveOEM -Confirm:$false
    }
    $d = Get-Disk -Number $n
    $sync.Status = "Inicializando disco ($style)..."
    if ("$($d.PartitionStyle)" -eq 'RAW') { Initialize-Disk -Number $n -PartitionStyle $style }
    elseif ("$($d.PartitionStyle)" -ne $style) { Set-Disk -Number $n -PartitionStyle $style }
    $sync.Status = 'Creando partición...'
    $p = New-Partition -DiskNumber $n -UseMaximumSize
    $sync.Status = "Formateando en $fs" + $(if ($quick) { ' (rápido)...' } else { ' (completo, puede tardar bastante)...' })
    $sync.Log.Enqueue($sync.Status)
    $fmt = @{ FileSystem = $fs; Confirm = $false; Force = $true }
    if ($label) { $fmt.NewFileSystemLabel = $label }
    if (-not $quick) { $fmt.Full = $true }
    try {
        Format-Volume -Partition $p @fmt | Out-Null
        $p = Get-Partition -DiskNumber $n -PartitionNumber $p.PartitionNumber
        if ("$($p.DriveLetter)" -notmatch '^[A-Z]$') { $p | Add-PartitionAccessPath -AssignDriveLetter }
    } catch {
        $sync.Log.Enqueue('Reintentando formato con letra asignada...')
        $p = Get-Partition -DiskNumber $n -PartitionNumber $p.PartitionNumber
        if ("$($p.DriveLetter)" -notmatch '^[A-Z]$') { $p | Add-PartitionAccessPath -AssignDriveLetter; Start-Sleep -Seconds 1 }
        $p = Get-Partition -DiskNumber $n -PartitionNumber $p.PartitionNumber
        Format-Volume -DriveLetter $p.DriveLetter @fmt | Out-Null
    }
    $p = Get-Partition -DiskNumber $n -PartitionNumber $p.PartitionNumber
    "Unidad lista: $($p.DriveLetter): ($fs)"
} catch { $sync.Error = $_.Exception.Message }
'@

$script:FormatPartScript = @'
param($sync, $n, $pn, $fs, $label, $quick)
$ErrorActionPreference = 'Stop'
try {
    Import-Module Storage
    $p = Get-Partition -DiskNumber $n -PartitionNumber $pn
    $sync.Status = "Formateando partición $pn en $fs" + $(if ($quick) { ' (rápido)...' } else { ' (completo, puede tardar bastante)...' })
    $sync.Log.Enqueue($sync.Status)
    $fmt = @{ FileSystem = $fs; Confirm = $false; Force = $true }
    if ($label) { $fmt.NewFileSystemLabel = $label }
    if (-not $quick) { $fmt.Full = $true }
    Format-Volume -Partition $p @fmt | Out-Null
    $p = Get-Partition -DiskNumber $n -PartitionNumber $pn
    if ("$($p.DriveLetter)" -notmatch '^[A-Z]$') { $p | Add-PartitionAccessPath -AssignDriveLetter; $p = Get-Partition -DiskNumber $n -PartitionNumber $pn }
    "Partición $pn formateada en $fs. Unidad $($p.DriveLetter):"
} catch { $sync.Error = $_.Exception.Message }
'@

$script:CreatePartScript = @'
param($sync, $n, $size, $useMax, $fs, $label, $quick, $style)
$ErrorActionPreference = 'Stop'
try {
    Import-Module Storage
    $d = Get-Disk -Number $n
    if ("$($d.PartitionStyle)" -eq 'RAW') { $sync.Log.Enqueue("Inicializando disco en $style"); Initialize-Disk -Number $n -PartitionStyle $style }
    $sync.Status = 'Creando partición...'
    if ($useMax) { $p = New-Partition -DiskNumber $n -UseMaximumSize }
    else { $p = New-Partition -DiskNumber $n -Size $size }
    $sync.Status = "Formateando en $fs..."
    $fmt = @{ FileSystem = $fs; Confirm = $false; Force = $true }
    if ($label) { $fmt.NewFileSystemLabel = $label }
    if (-not $quick) { $fmt.Full = $true }
    Format-Volume -Partition $p @fmt | Out-Null
    $p = Get-Partition -DiskNumber $n -PartitionNumber $p.PartitionNumber
    if ("$($p.DriveLetter)" -notmatch '^[A-Z]$') { $p | Add-PartitionAccessPath -AssignDriveLetter; $p = Get-Partition -DiskNumber $n -PartitionNumber $p.PartitionNumber }
    "Partición $($p.PartitionNumber) creada ($fs). Unidad $($p.DriveLetter):"
} catch { $sync.Error = $_.Exception.Message }
'@

$script:ResizeScript = @'
param($sync, $n, $pn, $size)
$ErrorActionPreference = 'Stop'
try {
    Import-Module Storage
    $sync.Status = 'Redimensionando partición...'
    Resize-Partition -DiskNumber $n -PartitionNumber $pn -Size $size
    $p = Get-Partition -DiskNumber $n -PartitionNumber $pn
    "Nuevo tamaño: {0:N0} MB" -f ($p.Size / 1MB)
} catch { $sync.Error = $_.Exception.Message }
'@

$script:DeletePartScript = @'
param($sync, $n, $pn)
$ErrorActionPreference = 'Stop'
try {
    Import-Module Storage
    Remove-Partition -DiskNumber $n -PartitionNumber $pn -Confirm:$false
    "Partición $pn eliminada."
} catch { $sync.Error = $_.Exception.Message }
'@

$script:LetterScript = @'
param($sync, $n, $pn, $letter, $oldLetter)
$ErrorActionPreference = 'Stop'
try {
    Import-Module Storage
    if ($letter -eq '-') {
        Remove-PartitionAccessPath -DiskNumber $n -PartitionNumber $pn -AccessPath "$($oldLetter):\"
        "Letra $($oldLetter): quitada."
    } else {
        if ($oldLetter) { Set-Partition -DiskNumber $n -PartitionNumber $pn -NewDriveLetter $letter }
        else { Add-PartitionAccessPath -DiskNumber $n -PartitionNumber $pn -AccessPath "$($letter):\" }
        "Letra asignada: $($letter):"
    }
} catch { $sync.Error = $_.Exception.Message }
'@

$script:ChkdskScript = @'
param($sync, $letter, $mode)
$cargs = switch ($mode) { 'scan' { "$($letter):" } 'fix' { "$($letter): /f /x" } default { "$($letter): /r /x" } }
$sync.Status = "Ejecutando chkdsk $cargs ..."
$sync.Log.Enqueue("> chkdsk $cargs")
& cmd.exe /c "chkdsk $cargs" 2>&1 | ForEach-Object {
    $s = ("$_" -split "`r")[-1].Trim()
    if ($s) { $sync.Log.Enqueue("  $s") }
}
$LASTEXITCODE
'@

$script:WriteProtScript = @'
param($sync, $n, $letters, $fixReg)
$ErrorActionPreference = 'Stop'
try {
    Import-Module Storage
    $d = Get-Disk -Number $n
    if ($d.IsOffline) { $sync.Log.Enqueue('Poniendo disco en línea...'); Set-Disk -Number $n -IsOffline $false }
    $sync.Log.Enqueue('Quitando atributo de solo lectura del disco...')
    try { Set-Disk -Number $n -IsReadOnly $false } catch { $sync.Log.Enqueue("Set-Disk: $($_.Exception.Message)") }
    $lines = @("select disk $n", 'attributes disk clear readonly')
    foreach ($l in @($letters)) { if ($l) { $lines += "select volume $l"; $lines += 'attributes volume clear readonly' } }
    $f = [IO.Path]::GetTempFileName()
    Set-Content -Path $f -Value $lines -Encoding ASCII
    & diskpart.exe /s $f 2>&1 | ForEach-Object { $s = "$_".Trim(); if ($s) { $sync.Log.Enqueue("  diskpart: $s") } }
    Remove-Item $f -ErrorAction SilentlyContinue
    if ($fixReg) {
        $sync.Log.Enqueue('Desactivando WriteProtect en el registro (StorageDevicePolicies)...')
        Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\StorageDevicePolicies' -Name WriteProtect -Value 0 -Type DWord
    }
    $d = Get-Disk -Number $n
    if ($d.IsReadOnly) { 'El disco sigue en solo lectura. Si tiene un interruptor físico (lock), muévalo. Si no, el controlador de la memoria puede estar dañado (las memorias suelen bloquearse en solo lectura al final de su vida útil).' }
    else { 'El disco ya no está protegido contra escritura. Desconecte y vuelva a conectar la unidad si sigue sin permitir escribir.' }
} catch { $sync.Error = $_.Exception.Message }
'@

$script:EjectScript = @'
param($sync, $n)
$ErrorActionPreference = 'Stop'
try {
    $w = Get-CimInstance Win32_DiskDrive -Filter "Index=$n"
    if (-not $w) { throw 'No se encontró el dispositivo.' }
    $sync.Status = 'Expulsando...'
    [UsbTool.Ejector]::Eject($w.PNPDeviceID)
} catch { $sync.Error = $_.Exception.Message }
'@

$script:TestScript = @'
param($sync, $root, $bytes, $del)
[UsbTool.Tester]::Run($root, [long]$bytes, $sync, [bool]$del)
'@

# ------------------------------------------------------------------
#  Interfaz
# ------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "$script:AppName - Diagnóstico y administración de unidades USB"
$form.Size = New-Object System.Drawing.Size((S 1220), (S 840))
$form.MinimumSize = New-Object System.Drawing.Size((S 960), (S 640))
$form.StartPosition = 'CenterScreen'
$form.Font = $script:FontNormal
try { $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon("$env:SystemRoot\System32\DeviceProperties.exe") } catch {}
$script:Form = $form

function New-Grid {
    $gr = New-Object System.Windows.Forms.DataGridView
    $gr.Dock = 'Fill'; $gr.ReadOnly = $true
    $gr.AllowUserToAddRows = $false; $gr.AllowUserToDeleteRows = $false; $gr.AllowUserToResizeRows = $false
    $gr.SelectionMode = 'FullRowSelect'; $gr.MultiSelect = $false; $gr.RowHeadersVisible = $false
    $gr.AutoSizeColumnsMode = 'Fill'; $gr.AutoSizeRowsMode = 'AllCells'
    $gr.ColumnHeadersHeightSizeMode = 'AutoSize'
    $gr.BackgroundColor = [System.Drawing.Color]::White; $gr.BorderStyle = 'FixedSingle'
    $gr.ColumnHeadersDefaultCellStyle.Font = $script:FontBold
    return $gr
}

function New-SectionLabel([string]$Text) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text; $l.Dock = 'Top'; $l.Font = $script:FontBold; $l.AutoSize = $false
    $l.Height = (S 24); $l.TextAlign = 'MiddleLeft'
    return $l
}

# --- Tabla de discos
$dtDisks = New-Object System.Data.DataTable
foreach ($c in 'Disco', 'Modelo', 'Capacidad', 'Estilo', 'Salud', 'Estado', 'Solo lectura', 'Unidades', 'N.º de serie') { [void]$dtDisks.Columns.Add($c) }
$gridDisks = New-Grid
$gridDisks.DataSource = $dtDisks

# --- Tabla de particiones
$dtParts = New-Object System.Data.DataTable
foreach ($c in 'Partición', 'Letra', 'Etiqueta', 'Sistema', 'Tamaño', 'Libre', 'Uso', 'Tipo', 'Estado') { [void]$dtParts.Columns.Add($c) }
$gridParts = New-Grid
$gridParts.DataSource = $dtParts

$lblFree = New-Object System.Windows.Forms.Label
$lblFree.Dock = 'Bottom'; $lblFree.Height = (S 24); $lblFree.TextAlign = 'MiddleLeft'

# --- Panel de salud
$lblBanner = New-Object System.Windows.Forms.Label
$lblBanner.Dock = 'Top'; $lblBanner.Height = (S 38); $lblBanner.Font = $script:FontTitle
$lblBanner.TextAlign = 'MiddleCenter'; $lblBanner.ForeColor = [System.Drawing.Color]::White
$lblBanner.BackColor = [System.Drawing.Color]::Gray; $lblBanner.Text = 'Seleccione una unidad'

$rtb = New-Object System.Windows.Forms.RichTextBox
$rtb.Dock = 'Fill'; $rtb.ReadOnly = $true; $rtb.BackColor = [System.Drawing.Color]::White
$rtb.BorderStyle = 'None'; $rtb.Font = $script:FontNormal; $rtb.DetectUrls = $false

# --- Contenedores
$splitMain = New-Object System.Windows.Forms.SplitContainer
$splitMain.Dock = 'Fill'; $splitMain.Orientation = 'Horizontal'
$splitMain.Panel1.Controls.Add($gridDisks)
$splitMain.Panel1.Controls.Add((New-SectionLabel 'Unidades de almacenamiento USB conectadas'))
$splitMain.Panel1.Padding = New-Object System.Windows.Forms.Padding((S 6), 0, (S 6), (S 4))

$splitBottom = New-Object System.Windows.Forms.SplitContainer
$splitBottom.Dock = 'Fill'; $splitBottom.Orientation = 'Vertical'
$splitBottom.Panel1.Controls.Add($gridParts)
$splitBottom.Panel1.Controls.Add($lblFree)
$splitBottom.Panel1.Controls.Add((New-SectionLabel 'Particiones y volúmenes de la unidad seleccionada'))
$healthPanel = New-Object System.Windows.Forms.Panel
$healthPanel.Dock = 'Fill'; $healthPanel.BorderStyle = 'FixedSingle'; $healthPanel.BackColor = [System.Drawing.Color]::White
$healthPanel.Controls.Add($rtb)
$healthPanel.Controls.Add($lblBanner)
$splitBottom.Panel2.Controls.Add($healthPanel)
$splitBottom.Panel2.Controls.Add((New-SectionLabel 'Estado de salud'))
$splitMain.Panel2.Controls.Add($splitBottom)
$splitMain.Panel2.Padding = New-Object System.Windows.Forms.Padding((S 6), 0, (S 6), 0)

# --- Barra superior
$pnlTop = New-Object System.Windows.Forms.FlowLayoutPanel
$pnlTop.Dock = 'Top'; $pnlTop.AutoSize = $true; $pnlTop.Padding = New-Object System.Windows.Forms.Padding((S 4))

function New-Btn([string]$Text, [scriptblock]$OnClick, [switch]$Action, [string]$Tip) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text; $b.AutoSize = $true; $b.Padding = New-Object System.Windows.Forms.Padding((S 6), (S 2), (S 6), (S 2))
    $b.MinimumSize = New-Object System.Drawing.Size((S 110), (S 30))
    $b.Add_Click($OnClick)
    if ($Tip) { $script:ToolTip.SetToolTip($b, $Tip) }
    if ($Action) { [void]$script:ActionButtons.Add($b) }
    return $b
}
$script:ToolTip = New-Object System.Windows.Forms.ToolTip

$btnRefresh = New-Btn 'Actualizar' { Update-DiskList } -Tip 'Volver a detectar las unidades USB'
$btnExport  = New-Btn 'Exportar reporte' { Export-Report } -Tip 'Guardar un reporte de texto de la unidad seleccionada'
$btnHelp    = New-Btn 'Ayuda' { Show-Help }
$chkAuto = New-Object System.Windows.Forms.CheckBox
$chkAuto.Text = 'Detectar conexión/desconexión automáticamente'; $chkAuto.Checked = $true; $chkAuto.AutoSize = $true
$chkAuto.Margin = New-Object System.Windows.Forms.Padding((S 12), (S 9), 0, 0)
$pnlTop.Controls.AddRange(@($btnRefresh, $btnExport, $btnHelp, $chkAuto))

# --- Barra de acciones
$pnlActions = New-Object System.Windows.Forms.FlowLayoutPanel
$pnlActions.Dock = 'Bottom'; $pnlActions.AutoSize = $true; $pnlActions.WrapContents = $true
$pnlActions.Padding = New-Object System.Windows.Forms.Padding((S 4))

function New-Group([string]$Title, [object[]]$Buttons) {
    $gb = New-Object System.Windows.Forms.GroupBox
    $gb.Text = $Title; $gb.AutoSize = $true; $gb.AutoSizeMode = 'GrowAndShrink'; $gb.Font = $script:FontBold
    $fl = New-Object System.Windows.Forms.FlowLayoutPanel
    $fl.AutoSize = $true; $fl.WrapContents = $false; $fl.Location = New-Object System.Drawing.Point((S 6), (S 20))
    $fl.Font = $script:FontNormal
    foreach ($b in $Buttons) { $fl.Controls.Add($b) }
    $gb.Controls.Add($fl)
    return $gb
}

$grpHealth = New-Group 'Salud' @(
    (New-Btn 'Analizar salud' { if ($null -ne $script:SelDisk) { Start-HealthAnalysis $script:SelDisk } } -Action -Tip 'Leer de nuevo el estado del disco, SMART y volúmenes'),
    (New-Btn 'Prueba de velocidad e integridad' { Invoke-SpeedTest } -Action -Tip 'Escribe y verifica datos para medir la velocidad real y detectar memorias falsas o dañadas')
)
$grpFormat = New-Group 'Formato' @(
    (New-Btn 'Formatear partición' { Invoke-FormatPartition } -Action -Tip 'Formatea la partición seleccionada en la tabla de particiones'),
    (New-Btn 'Formatear disco completo' { Invoke-FormatDisk } -Action -Tip 'Borra todas las particiones y crea una sola que ocupa toda la unidad')
)
$grpParts = New-Group 'Particiones' @(
    (New-Btn 'Crear' { Invoke-CreatePartition } -Action -Tip 'Crear una partición en el espacio sin asignar'),
    (New-Btn 'Redimensionar' { Invoke-ResizePartition } -Action -Tip 'Ampliar o reducir la partición seleccionada (solo NTFS)'),
    (New-Btn 'Eliminar' { Invoke-DeletePartition } -Action -Tip 'Eliminar la partición seleccionada'),
    (New-Btn 'Cambiar letra' { Invoke-ChangeLetter } -Action -Tip 'Asignar, cambiar o quitar la letra de unidad')
)
$grpRepair = New-Group 'Reparación' @(
    (New-Btn 'Revisar / reparar (CHKDSK)' { Invoke-Chkdsk } -Action -Tip 'Buscar y corregir errores del sistema de archivos'),
    (New-Btn 'Quitar protección contra escritura' { Invoke-RemoveWriteProtect } -Action -Tip 'Quitar atributos de solo lectura del disco y volúmenes'),
    (New-Btn 'Expulsar de forma segura' { Invoke-Eject } -Action -Tip 'Expulsar la unidad para desconectarla sin perder datos')
)
$pnlActions.Controls.AddRange(@($grpHealth, $grpFormat, $grpParts, $grpRepair))

# --- Barra de estado
$pnlStatus = New-Object System.Windows.Forms.TableLayoutPanel
$pnlStatus.Dock = 'Bottom'; $pnlStatus.Height = (S 34); $pnlStatus.ColumnCount = 3
$pnlStatus.Padding = New-Object System.Windows.Forms.Padding((S 6), (S 2), (S 6), (S 2))
[void]$pnlStatus.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$pnlStatus.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, (S 300))))
[void]$pnlStatus.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Dock = 'Fill'; $lblStatus.TextAlign = 'MiddleLeft'; $lblStatus.Text = 'Listo.'
$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Dock = 'Fill'; $progress.Visible = $false; $progress.MarqueeAnimationSpeed = 30
$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = 'Cancelar'; $btnCancel.AutoSize = $true; $btnCancel.Enabled = $false
$btnCancel.Add_Click({
    if ($script:CurrentTask) {
        $script:CurrentTask.Sync.Cancel = $true
        $lblStatus.Text = 'Cancelando...'
        Write-Log 'Cancelación solicitada.'
    }
})
$pnlStatus.Controls.Add($lblStatus, 0, 0)
$pnlStatus.Controls.Add($progress, 1, 0)
$pnlStatus.Controls.Add($btnCancel, 2, 0)

# --- Registro
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Dock = 'Bottom'; $txtLog.Multiline = $true; $txtLog.ReadOnly = $true; $txtLog.ScrollBars = 'Vertical'
$txtLog.Height = (S 120); $txtLog.Font = $script:FontMono; $txtLog.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 250)

# Orden de acoplamiento: el control "Fill" primero, luego los bordes
$form.Controls.Add($splitMain)
$form.Controls.Add($pnlTop)
$form.Controls.Add($pnlActions)
$form.Controls.Add($pnlStatus)
$form.Controls.Add($txtLog)
$splitMain.BringToFront()

# ------------------------------------------------------------------
#  Lógica de lista de discos y particiones
# ------------------------------------------------------------------
function Update-DiskList {
    $prev = $script:SelDisk
    $script:Binding = $true
    $disks = @()
    try {
        $script:Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $dtDisks.Rows.Clear()
        $disks = Get-UsbDisks
        foreach ($d in $disks) {
            $letters = @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue |
                Where-Object { "$($_.DriveLetter)" -match '^[A-Z]$' } | ForEach-Object { "$($_.DriveLetter):" }) -join ' '
            [void]$dtDisks.Rows.Add(
                "$($d.Number)", "$($d.FriendlyName)", (Format-Size $d.Size), "$($d.PartitionStyle)",
                (Get-HealthText $d.HealthStatus), (Get-OpText $d.OperationalStatus), (Get-YesNo $d.IsReadOnly),
                $letters, "$($d.SerialNumber)".Trim())
        }
        $script:Signature = Get-DeviceSignature
        Set-DiskRowColors
        $target = $null
        foreach ($row in $gridDisks.Rows) { if ($null -ne $prev -and "$($row.Cells['Disco'].Value)" -eq "$prev") { $target = $row } }
        if (-not $target -and $gridDisks.Rows.Count -gt 0) { $target = $gridDisks.Rows[0] }
        if ($target) {
            $gridDisks.ClearSelection()
            $target.Selected = $true
            $gridDisks.CurrentCell = $target.Cells[1]
        }
    } finally {
        $script:Binding = $false
        $script:Form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
    if ($target) { Select-Disk ([int]$target.Cells['Disco'].Value) }
    else {
        $script:SelDisk = $null
        $dtParts.Rows.Clear(); $lblFree.Text = ''; $rtb.Clear()
        $lblBanner.Text = 'No hay unidades USB conectadas'; $lblBanner.BackColor = [System.Drawing.Color]::Gray
    }
    if (-not $script:Busy) { $lblStatus.Text = '{0} unidad(es) USB detectada(s).' -f $disks.Count }
}

function Set-DiskRowColors {
    foreach ($row in $gridDisks.Rows) {
        $h = "$($row.Cells['Salud'].Value)"
        $color = [System.Drawing.Color]::White
        if ("$($row.Cells['Solo lectura'].Value)" -eq 'Sí' -or $h -eq 'Advertencia') { $color = [System.Drawing.Color]::FromArgb(255, 244, 204) }
        if ($h -eq 'Dañado') { $color = [System.Drawing.Color]::FromArgb(255, 215, 215) }
        $row.DefaultCellStyle.BackColor = $color
    }
}

function Select-Disk([int]$n) {
    $script:SelDisk = $n
    Update-PartitionList $n
    Start-HealthAnalysis $n
}

function Update-PartitionList([int]$n) {
    $dtParts.Rows.Clear()
    $d = Get-Disk -Number $n -ErrorAction SilentlyContinue
    if (-not $d) { $lblFree.Text = 'La unidad ya no está disponible.'; return }
    $parts = @(Get-Partition -DiskNumber $n -ErrorAction SilentlyContinue)
    foreach ($p in $parts) {
        $v = $null
        try { $v = Get-Volume -Partition $p -ErrorAction Stop } catch {}
        $letter = if ("$($p.DriveLetter)" -match '^[A-Z]$') { "$($p.DriveLetter):" } else { '' }
        $fs = ''; $lab = ''; $free = ''; $use = ''; $st = ''
        if ($v) {
            $fs = if ($v.FileSystem) { "$($v.FileSystem)" } else { 'RAW' }
            $lab = "$($v.FileSystemLabel)"
            if ($v.Size -gt 0) {
                $free = Format-Size $v.SizeRemaining
                $use = '{0:N0} %' -f (100 * ($v.Size - $v.SizeRemaining) / $v.Size)
            }
            $st = Get-HealthText $v.HealthStatus
        }
        [void]$dtParts.Rows.Add("$($p.PartitionNumber)", $letter, $lab, $fs, (Format-Size $p.Size), $free, $use, "$($p.Type)", $st)
    }
    $lblFree.Text = 'Estilo: {0}   |   Particiones: {1}   |   Espacio sin asignar: {2}' -f "$($d.PartitionStyle)", $parts.Count, (Format-Size $d.LargestFreeExtent)
    if ($gridParts.Rows.Count -gt 0) {
        # Selecciona la primera partición con letra (o la primera)
        $sel = $null
        foreach ($r in $gridParts.Rows) { if (-not $sel -and "$($r.Cells['Letra'].Value)") { $sel = $r } }
        if (-not $sel) { $sel = $gridParts.Rows[0] }
        $gridParts.ClearSelection(); $sel.Selected = $true; $gridParts.CurrentCell = $sel.Cells[0]
    }
}

function Get-SelDisk {
    if ($null -eq $script:SelDisk) { [void](Show-Msg 'Seleccione primero una unidad USB de la lista.' 'Warning'); return $null }
    $d = Get-Disk -Number $script:SelDisk -ErrorAction SilentlyContinue
    if (-not $d) { [void](Show-Msg 'La unidad ya no está disponible. Se actualizará la lista.' 'Warning'); Update-DiskList; return $null }
    if (-not (Test-SafeDisk $d)) { [void](Show-Msg 'Por seguridad, solo se permite operar sobre unidades USB que no sean el disco de sistema o arranque.' 'Error'); return $null }
    return $d
}

function Get-SelPartition {
    if ($gridParts.SelectedRows.Count -eq 0) { [void](Show-Msg 'Seleccione una partición en la tabla de particiones.' 'Warning'); return $null }
    $pn = [int]$gridParts.SelectedRows[0].Cells['Partición'].Value
    $p = Get-Partition -DiskNumber $script:SelDisk -PartitionNumber $pn -ErrorAction SilentlyContinue
    if (-not $p) { [void](Show-Msg 'La partición ya no existe. Actualice la lista.' 'Warning') }
    return $p
}

# ------------------------------------------------------------------
#  Salud
# ------------------------------------------------------------------
function Add-Rtb([string]$Text, [System.Drawing.Color]$Color = [System.Drawing.Color]::Black, [switch]$Bold) {
    $rtb.SelectionStart = $rtb.TextLength
    $rtb.SelectionLength = 0
    $rtb.SelectionColor = $Color
    $rtb.SelectionFont = if ($Bold) { $script:FontBold } else { $script:FontNormal }
    $rtb.AppendText($Text + "`n")
}

function Start-HealthAnalysis([int]$n) {
    $lblBanner.Text = 'Analizando...'
    $lblBanner.BackColor = [System.Drawing.Color]::SteelBlue
    $rtb.Clear()
    Add-Rtb 'Leyendo información del dispositivo (estado, SMART, contadores, volúmenes)...' $C_INFO
    [void](Start-BgTask -Name 'Salud' -Script $script:HealthScript -Params @{ n = $n } -Context $n -OnDone {
        param($out, $errs, $ctx)
        if ($ctx -ne $script:SelDisk) { return }
        if (-not $out -or $out.Count -eq 0 -or -not $out[0].Disk) {
            $rtb.Clear(); Add-Rtb 'No se pudo leer la unidad. Puede haber sido desconectada.' $C_CRIT
            $lblBanner.Text = 'SIN DATOS'; $lblBanner.BackColor = [System.Drawing.Color]::Gray
            return
        }
        Show-Health $out[0] $ctx
    })
}

function Show-Health($h, [int]$n) {
    $d = $h.Disk; $pd = $h.Phys; $w = $h.Wmi; $rel = $h.Rel; $smart = $h.Smart
    $items = New-Object System.Collections.ArrayList
    $add = { param($s, $t) [void]$items.Add([pscustomobject]@{ Sev = $s; Text = $t }) }

    # --- Estado del disco
    switch ("$($d.HealthStatus)") {
        'Healthy'   { & $add 0 'Windows reporta el disco como saludable.' }
        'Warning'   { & $add 2 'Windows reporta ADVERTENCIA en el estado del disco.' }
        'Unhealthy' { & $add 3 'Windows reporta el disco como DAÑADO.' }
        default     { & $add 1 "Estado del disco no determinado ($($d.HealthStatus))." }
    }
    $op = "$($d.OperationalStatus)"
    if ($op -like '*No Media*') { & $add 3 'El dispositivo no reporta medio de almacenamiento (lector vacío o memoria dañada).' }
    elseif ($op -ne 'Online') { & $add 2 "Estado operativo: $(Get-OpText $op)." }
    else { & $add 0 'El disco está en línea.' }
    if ($d.Size -le 0) { & $add 3 'Capacidad reportada: 0 bytes. El controlador no detecta la memoria (posible falla).' }
    if ($d.IsReadOnly) { & $add 2 'El disco está en SOLO LECTURA. Puede ser un interruptor físico, un atributo de Windows o, en memorias desgastadas, un bloqueo del controlador por fin de vida útil.' }
    if ($d.IsOffline) { & $add 2 "El disco está sin conexión (motivo: $($d.OfflineReason))." }
    if ($pd) {
        switch ("$($pd.HealthStatus)") {
            'Warning'   { & $add 2 'El disco físico reporta ADVERTENCIA.' }
            'Unhealthy' { & $add 3 'El disco físico reporta estado DAÑADO.' }
        }
    }
    if ($w) {
        switch ("$($w.Status)") {
            'OK'        { }
            'Pred Fail' { & $add 3 'WMI reporta "Pred Fail": se predice una falla inminente.' }
            'Degraded'  { & $add 2 'WMI reporta el dispositivo como degradado.' }
            ''          { }
            default     { & $add 2 "WMI reporta estado: $($w.Status)." }
        }
    }

    # --- SMART
    if ($smart) {
        if ($smart.PredictFailure) { & $add 3 "SMART predice una FALLA INMINENTE (código $($smart.Reason)). Respalde sus datos de inmediato." }
        else { & $add 0 'SMART: sin predicción de falla.' }
    } else {
        & $add 1 'SMART no disponible (normal en memorias USB: la mayoría de controladores no lo exponen).'
    }

    # --- Contadores de confiabilidad
    $relLines = New-Object System.Collections.ArrayList
    if ($rel) {
        if ($null -ne $rel.Temperature -and $rel.Temperature -gt 0) {
            [void]$relLines.Add("Temperatura: $($rel.Temperature) °C (máx. $($rel.TemperatureMax) °C)")
            if ($rel.Temperature -ge 70) { & $add 3 "Temperatura muy alta: $($rel.Temperature) °C." }
            elseif ($rel.Temperature -ge 55) { & $add 2 "Temperatura elevada: $($rel.Temperature) °C." }
        }
        if ($null -ne $rel.Wear) {
            [void]$relLines.Add("Desgaste: $($rel.Wear) %")
            if ($rel.Wear -ge 95) { & $add 3 "Desgaste crítico: $($rel.Wear) % de la vida útil consumida." }
            elseif ($rel.Wear -ge 80) { & $add 2 "Desgaste alto: $($rel.Wear) % de la vida útil consumida." }
        }
        if ($null -ne $rel.PowerOnHours)            { [void]$relLines.Add("Horas encendido: $($rel.PowerOnHours)") }
        if ($null -ne $rel.StartStopCycleCount)     { [void]$relLines.Add("Ciclos de encendido: $($rel.StartStopCycleCount)") }
        if ($null -ne $rel.ReadErrorsTotal)         { [void]$relLines.Add("Errores de lectura (total/corregidos/no corregidos): $($rel.ReadErrorsTotal) / $($rel.ReadErrorsCorrected) / $($rel.ReadErrorsUncorrected)") }
        if ($null -ne $rel.WriteErrorsTotal)        { [void]$relLines.Add("Errores de escritura (total/corregidos/no corregidos): $($rel.WriteErrorsTotal) / $($rel.WriteErrorsCorrected) / $($rel.WriteErrorsUncorrected)") }
        if ($rel.ReadErrorsUncorrected -gt 0 -or $rel.WriteErrorsUncorrected -gt 0) { & $add 3 'Hay errores de lectura/escritura NO corregidos registrados por el dispositivo.' }
        elseif ($rel.ReadErrorsTotal -gt 0 -or $rel.WriteErrorsTotal -gt 0) { & $add 2 'El dispositivo registró errores de lectura/escritura (corregidos).' }
        if ($relLines.Count -eq 0) { & $add 1 'Contadores de confiabilidad sin datos (el dispositivo no los reporta).' }
        else { & $add 0 'Contadores de confiabilidad leídos correctamente.' }
    } else {
        & $add 1 'Contadores de confiabilidad no disponibles para este dispositivo.'
    }

    # --- Volúmenes
    foreach ($x in @($h.Vols)) {
        $p = $x.Partition; $v = $x.Volume
        $name = "Partición $($p.PartitionNumber)"
        if ("$($p.DriveLetter)" -match '^[A-Z]$') { $name += " ($($p.DriveLetter):)" }
        if (-not $v) { continue }
        if (-not $v.FileSystem -or "$($v.FileSystem)" -eq 'RAW') {
            & $add 2 "$($name): sin sistema de archivos reconocido (RAW). Puede estar sin formato o dañada."
            continue
        }
        switch ("$($v.HealthStatus)") {
            'Healthy'   { & $add 0 "$($name): volumen $($v.FileSystem) saludable." }
            'Warning'   { & $add 2 "$($name): el volumen reporta advertencia; se recomienda ejecutar CHKDSK." }
            'Unhealthy' { & $add 3 "$($name): el volumen está dañado; ejecute CHKDSK (reparar) y respalde los datos." }
        }
        if ($v.Size -gt 0 -and ($v.SizeRemaining / $v.Size) -lt 0.05) { & $add 1 "$($name): queda menos del 5 % de espacio libre." }
    }

    # --- Última prueba de integridad
    $key = Get-TestKey $d
    $t = $script:TestResults[$key]
    if ($t) {
        $r = $t.Result
        if ($r.BytesCorrupted -gt 0 -or $r.BadBlocks -gt 0) {
            & $add 3 ("Prueba de integridad ({0:dd/MM HH:mm}): {1:N0} MB con errores. La unidad está DAÑADA o es FALSA." -f $t.Date, $r.BadBlocks)
        } elseif ($r.Error) {
            & $add 3 ("Prueba de integridad ({0:dd/MM HH:mm}) falló: {1}" -f $t.Date, $r.Error)
        } elseif (-not $r.Cancelled) {
            & $add 0 ("Prueba de integridad ({0:dd/MM HH:mm}): {1:N0} MB verificados sin errores." -f $t.Date, ($r.BytesVerified / 1MB))
        }
    }

    $max = ($items | Measure-Object -Property Sev -Maximum).Maximum
    $rtb.Clear()

    # --- Banner
    switch ($max) {
        3 { $lblBanner.Text = 'ESTADO: CRÍTICO'; $lblBanner.BackColor = $C_CRIT }
        2 { $lblBanner.Text = 'ESTADO: ADVERTENCIA'; $lblBanner.BackColor = $C_WARN }
        default {
            if ($t -and -not $t.Result.Cancelled) { $lblBanner.Text = 'ESTADO: BUENO'; $lblBanner.BackColor = $C_OK }
            else { $lblBanner.Text = 'ESTADO: BUENO (sin prueba de integridad)'; $lblBanner.BackColor = [System.Drawing.Color]::FromArgb(70, 140, 70) }
        }
    }

    Add-Rtb 'INFORMACIÓN DEL DISPOSITIVO' $C_HEAD -Bold
    Add-Rtb "  Modelo:              $($d.FriendlyName)"
    Add-Rtb "  N.º de serie:        $("$($d.SerialNumber)".Trim())"
    Add-Rtb "  Firmware:            $($d.FirmwareVersion)"
    Add-Rtb "  Bus:                 $($d.BusType)"
    Add-Rtb ("  Capacidad:           {0}  ({1:N0} bytes)" -f (Format-Size $d.Size), $d.Size)
    Add-Rtb "  Estilo de partición: $($d.PartitionStyle)"
    Add-Rtb "  Particiones:         $($d.NumberOfPartitions)"
    Add-Rtb "  Sin asignar:         $(Format-Size $d.LargestFreeExtent)"
    if ($pd) { Add-Rtb "  Tipo de medio:       $($pd.MediaType)" }
    if ($w)  { Add-Rtb "  ID de dispositivo:   $($w.PNPDeviceID)" }
    if ($relLines.Count -gt 0) {
        Add-Rtb ''
        Add-Rtb 'CONTADORES DE CONFIABILIDAD' $C_HEAD -Bold
        foreach ($l in $relLines) { Add-Rtb "  $l" }
    }
    Add-Rtb ''
    Add-Rtb 'DIAGNÓSTICO' $C_HEAD -Bold
    foreach ($i in ($items | Sort-Object Sev -Descending)) {
        switch ($i.Sev) {
            3 { Add-Rtb "  ✖  $($i.Text)" $C_CRIT -Bold }
            2 { Add-Rtb "  ⚠  $($i.Text)" $C_WARN }
            1 { Add-Rtb "  ℹ  $($i.Text)" $C_INFO }
            default { Add-Rtb "  ✔  $($i.Text)" $C_OK }
        }
    }
    if ($t) {
        $r = $t.Result
        Add-Rtb ''
        Add-Rtb 'ÚLTIMA PRUEBA DE VELOCIDAD E INTEGRIDAD' $C_HEAD -Bold
        Add-Rtb ("  Fecha:               {0:dd/MM/yyyy HH:mm}" -f $t.Date)
        Add-Rtb ("  Datos verificados:   {0:N0} MB de {1:N0} MB escritos" -f ($r.BytesVerified / 1MB), ($r.BytesWritten / 1MB))
        Add-Rtb ("  Escritura:           {0:N1} MB/s" -f $r.WriteMBps)
        Add-Rtb ("  Lectura:             {0:N1} MB/s" -f $r.ReadMBps)
        Add-Rtb ("  MB con errores:      {0:N0}" -f $r.BadBlocks)
    }
    if (-not $t -and $max -lt 2) {
        Add-Rtb ''
        Add-Rtb 'RECOMENDACIÓN' $C_HEAD -Bold
        Add-Rtb '  Las memorias USB casi nunca reportan SMART. Para confirmar que la unidad funciona bien'
        Add-Rtb '  y que su capacidad es real, ejecute "Prueba de velocidad e integridad".'
    }
    $rtb.SelectionStart = 0; $rtb.ScrollToCaret()
}

# ------------------------------------------------------------------
#  Acciones
# ------------------------------------------------------------------
function Get-LabelMax([string]$fs) { switch ($fs) { 'FAT32' { 11 } 'exFAT' { 15 } default { 32 } } }

function Invoke-SpeedTest {
    $d = Get-SelDisk; if (-not $d) { return }
    $letter = $null
    if ($gridParts.SelectedRows.Count -gt 0) {
        $l = "$($gridParts.SelectedRows[0].Cells['Letra'].Value)"
        $fs = "$($gridParts.SelectedRows[0].Cells['Sistema'].Value)"
        if ($l -and $fs -and $fs -ne 'RAW') { $letter = $l.Substring(0, 1) }
    }
    if (-not $letter) {
        foreach ($r in $gridParts.Rows) {
            if (-not $letter -and "$($r.Cells['Letra'].Value)" -and "$($r.Cells['Sistema'].Value)" -and "$($r.Cells['Sistema'].Value)" -ne 'RAW') {
                $letter = "$($r.Cells['Letra'].Value)".Substring(0, 1)
            }
        }
    }
    if (-not $letter) { [void](Show-Msg 'La unidad necesita una partición con letra y sistema de archivos para la prueba. Formatéela primero.' 'Warning'); return }
    $vol = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
    $free = if ($vol) { $vol.SizeRemaining } else { 0 }
    if ($free -lt 16MB) { [void](Show-Msg "La unidad $($letter): no tiene espacio libre suficiente (mínimo 16 MB)." 'Warning'); return }

    $sizes = @(
        @{ T = '256 MB (rápida)'; B = 256MB },
        @{ T = '1 GB'; B = 1GB },
        @{ T = '4 GB'; B = 4GB },
        @{ T = '16 GB'; B = 16GB },
        @{ T = "Todo el espacio libre ($(Format-Size $free)) - detecta USB falsas"; B = 0 }
    )
    $cmb = New-Combo ($sizes | ForEach-Object { $_.T }) 1
    $chkDel = New-Check 'Eliminar los archivos de prueba al terminar' $true
    $f = [ordered]@{ 'Cantidad a probar:' = $cmb; 'del' = $chkDel }
    $note = "Se escribirán archivos en $($letter):\USB_TEST_TMP y luego se leerán sin caché para comprobar cada byte.`n`n" +
            "Sus archivos existentes NO se modifican. La opción 'Todo el espacio libre' es la única que detecta memorias falsas " +
            "(que aparentan más capacidad de la real), pero puede tardar mucho en unidades grandes o lentas."
    if (-not (Show-InputDialog -Title "Prueba de velocidad e integridad - $($letter):" -Fields $f -Note $note -OkText 'Iniciar prueba')) { return }
    $bytes = [int64]$sizes[$cmb.SelectedIndex].B
    if ($bytes -gt 0 -and $bytes -gt $free) { Write-Log "La cantidad elegida supera el espacio libre; se usará todo el espacio libre."; $bytes = 0 }

    $ctx = @{ Key = (Get-TestKey $d); Letter = $letter; Disk = $d.Number }
    [void](Start-BgTask -Name "Prueba de velocidad e integridad ($($letter):)" -Script $script:TestScript -Exclusive -Cancelable -Context $ctx `
        -Params @{ root = "$($letter):\"; bytes = $bytes; del = $chkDel.Checked } -OnDone {
        param($out, $errs, $ctx)
        if ($errs.Count -gt 0) { [void](Show-Msg ("La prueba falló:`n" + ($errs -join "`n")) 'Error'); return }
        $r = $out[0]
        if (-not $r) { return }
        $script:TestResults[$ctx.Key] = @{ Date = Get-Date; Result = $r }
        $summary = ("Escrito: {0:N0} MB   Verificado: {1:N0} MB`nEscritura: {2:N1} MB/s   Lectura: {3:N1} MB/s`nMB con errores: {4:N0}" -f `
            ($r.BytesWritten / 1MB), ($r.BytesVerified / 1MB), $r.WriteMBps, $r.ReadMBps, $r.BadBlocks)
        Write-Log ("Resultado de prueba: " + ($summary -replace "`n", ' | '))
        if ($r.BadBlocks -gt 0) {
            $msg = "SE DETECTARON ERRORES.`n`n$summary`n`nPrimer error cerca del MB {0:N0}.`n`n" -f $r.FirstErrorMB
            $msg += "La unidad está dañada o es falsa (su capacidad real es menor a la anunciada). No guarde datos importantes en ella."
            if ($r.FirstErrorMB -gt 0) { $msg += ("`n`nCapacidad confiable aproximada: {0}. Puede crear una partición de ese tamaño para usar solo la parte buena." -f (Format-Size ($r.FirstErrorMB * 1MB))) }
            [void](Show-Msg $msg 'Error')
        } elseif ($r.Error) {
            [void](Show-Msg "La prueba se detuvo por un error:`n$($r.Error)`n`n$summary" 'Error')
        } elseif ($r.Cancelled) {
            [void](Show-Msg "Prueba cancelada.`n`n$summary" 'Information')
        } else {
            [void](Show-Msg "Prueba completada SIN ERRORES.`n`n$summary" 'Information')
        }
        if ($ctx.Disk -eq $script:SelDisk) { Update-PartitionList $ctx.Disk; Start-HealthAnalysis $ctx.Disk }
    })
}

function Invoke-FormatPartition {
    $d = Get-SelDisk; if (-not $d) { return }
    $p = Get-SelPartition; if (-not $p) { return }
    $v = $null; try { $v = Get-Volume -Partition $p -ErrorAction Stop } catch {}
    $cmbFs = New-Combo @('exFAT', 'FAT32', 'NTFS') 0
    $txtLabel = New-Object System.Windows.Forms.TextBox; $txtLabel.Text = if ($v -and $v.FileSystemLabel) { "$($v.FileSystemLabel)" } else { 'USB' }
    $chkQuick = New-Check 'Formato rápido (desmarque para formato completo, que revisa toda la superficie)' $true
    $f = [ordered]@{ 'Sistema de archivos:' = $cmbFs; 'Etiqueta:' = $txtLabel; 'q' = $chkQuick }
    $note = "Partición $($p.PartitionNumber) de $(Get-DiskDescription $d)`nTamaño: $(Format-Size $p.Size)`n`n" +
            "exFAT: recomendado (archivos > 4 GB, compatible con Windows/Mac/TV recientes).`nFAT32: máxima compatibilidad, archivos de máx. 4 GB y particiones de máx. 32 GB en Windows.`nNTFS: solo Windows; permite redimensionar."
    if (-not (Show-InputDialog -Title 'Formatear partición' -Fields $f -Note $note -OkText 'Formatear')) { return }
    $fs = "$($cmbFs.SelectedItem)"
    if ($fs -eq 'FAT32' -and $p.Size -gt 32GB) { [void](Show-Msg 'Windows no puede formatear en FAT32 particiones mayores de 32 GB. Use exFAT.' 'Warning'); return }
    $label = $txtLabel.Text.Trim(); $mx = Get-LabelMax $fs
    if ($label.Length -gt $mx) { $label = $label.Substring(0, $mx); Write-Log "Etiqueta recortada a $mx caracteres: $label" }
    if (-not (Confirm-Typed "Se BORRARÁN todos los datos de la partición $($p.PartitionNumber) de:`n$(Get-DiskDescription $d)")) { return }
    Start-DiskOp "Formatear partición $($p.PartitionNumber) ($fs)" $script:FormatPartScript @{ n = $d.Number; pn = $p.PartitionNumber; fs = $fs; label = $label; quick = $chkQuick.Checked }
}

function Invoke-FormatDisk {
    $d = Get-SelDisk; if (-not $d) { return }
    $defStyle = if ($d.Size -gt 2TB) { 1 } else { 0 }
    $cmbFs = New-Combo @('exFAT', 'FAT32', 'NTFS') 0
    $cmbStyle = New-Combo @('MBR (máxima compatibilidad)', 'GPT') $defStyle
    $txtLabel = New-Object System.Windows.Forms.TextBox; $txtLabel.Text = 'USB'
    $chkQuick = New-Check 'Formato rápido (desmarque para formato completo)' $true
    $f = [ordered]@{ 'Sistema de archivos:' = $cmbFs; 'Tabla de particiones:' = $cmbStyle; 'Etiqueta:' = $txtLabel; 'q' = $chkQuick }
    $note = "$(Get-DiskDescription $d)`n`nSe eliminarán TODAS las particiones y se creará una sola que ocupe toda la unidad. " +
            "Útil también para recuperar memorias con particiones raras o capacidad 'perdida'."
    if (-not (Show-InputDialog -Title 'Formatear disco completo' -Fields $f -Note $note -OkText 'Formatear')) { return }
    $fs = "$($cmbFs.SelectedItem)"
    $style = if ($cmbStyle.SelectedIndex -eq 1) { 'GPT' } else { 'MBR' }
    if ($fs -eq 'FAT32' -and $d.Size -gt 32GB) { [void](Show-Msg 'Windows no puede formatear en FAT32 volúmenes mayores de 32 GB. Use exFAT (o cree una partición de 32 GB con "Crear").' 'Warning'); return }
    if ($style -eq 'MBR' -and $d.Size -gt 2TB) { [void](Show-Msg 'MBR no admite discos de más de 2 TB. Use GPT.' 'Warning'); return }
    $label = $txtLabel.Text.Trim(); $mx = Get-LabelMax $fs
    if ($label.Length -gt $mx) { $label = $label.Substring(0, $mx) }
    if (-not (Confirm-Typed "Se BORRARÁ TODO el contenido de:`n$(Get-DiskDescription $d)`n`nEsta acción no se puede deshacer.")) { return }
    Start-DiskOp "Formatear disco $($d.Number) completo ($fs, $style)" $script:FormatDiskScript @{ n = $d.Number; fs = $fs; label = $label; quick = $chkQuick.Checked; style = $style }
}

function Invoke-CreatePartition {
    $d = Get-SelDisk; if (-not $d) { return }
    $maxMB = [int64][Math]::Floor($d.LargestFreeExtent / 1MB)
    if ("$($d.PartitionStyle)" -eq 'RAW') { $maxMB = [int64][Math]::Floor(($d.Size - 2MB) / 1MB) }
    if ($maxMB -lt 8) { [void](Show-Msg "No hay espacio sin asignar suficiente en la unidad.`nElimine o reduzca una partición primero." 'Warning'); return }
    $num = New-Object System.Windows.Forms.NumericUpDown
    $num.Minimum = 8; $num.Maximum = $maxMB; $num.Value = $maxMB; $num.ThousandsSeparator = $true; $num.Increment = 1024
    $cmbFs = New-Combo @('exFAT', 'FAT32', 'NTFS') 0
    $txtLabel = New-Object System.Windows.Forms.TextBox; $txtLabel.Text = 'USB'
    $chkQuick = New-Check 'Formato rápido' $true
    $f = [ordered]@{ 'Tamaño (MB):' = $num; 'Sistema de archivos:' = $cmbFs; 'Etiqueta:' = $txtLabel; 'q' = $chkQuick }
    $cmbStyle = $null
    if ("$($d.PartitionStyle)" -eq 'RAW') {
        $cmbStyle = New-Combo @('MBR', 'GPT') ([int]($d.Size -gt 2TB))
        $f.Insert(0, 'Inicializar como:', $cmbStyle)
    }
    $note = "$(Get-DiskDescription $d)`nEspacio sin asignar disponible: {0:N0} MB" -f $maxMB
    if ("$($d.PartitionStyle)" -eq 'MBR') { $note += "`n`nNota: en MBR se admiten máximo 4 particiones primarias. Windows 10 1703+ muestra varias particiones en memorias USB." }
    if (-not (Show-InputDialog -Title 'Crear partición' -Fields $f -Note $note -OkText 'Crear')) { return }
    $sizeMB = [int64]$num.Value
    $fs = "$($cmbFs.SelectedItem)"
    if ($fs -eq 'FAT32' -and $sizeMB -gt 32768) { [void](Show-Msg 'Windows no puede formatear en FAT32 particiones mayores de 32 GB (32768 MB).' 'Warning'); return }
    $label = $txtLabel.Text.Trim(); $mx = Get-LabelMax $fs
    if ($label.Length -gt $mx) { $label = $label.Substring(0, $mx) }
    $style = if ($cmbStyle -and $cmbStyle.SelectedIndex -eq 1) { 'GPT' } else { 'MBR' }
    Start-DiskOp "Crear partición de $sizeMB MB ($fs)" $script:CreatePartScript @{
        n = $d.Number; size = ($sizeMB * 1MB); useMax = ($sizeMB -ge $maxMB); fs = $fs; label = $label; quick = $chkQuick.Checked; style = $style }
}

function Invoke-ResizePartition {
    $d = Get-SelDisk; if (-not $d) { return }
    $p = Get-SelPartition; if (-not $p) { return }
    $v = $null; try { $v = Get-Volume -Partition $p -ErrorAction Stop } catch {}
    if (-not $v -or "$($v.FileSystem)" -ne 'NTFS') {
        [void](Show-Msg ("Windows solo puede redimensionar particiones NTFS. Esta partición es: $(if ($v -and $v.FileSystem) { $v.FileSystem } else { 'RAW / sin formato' }).`n`n" +
            "Alternativas:`n - Respaldar los datos, eliminar la partición y crearla con el tamaño deseado.`n - Formatearla como NTFS y luego redimensionar.") 'Warning')
        return
    }
    $script:Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try { $sup = Get-PartitionSupportedSize -DiskNumber $d.Number -PartitionNumber $p.PartitionNumber -ErrorAction Stop }
    catch { $script:Form.Cursor = [System.Windows.Forms.Cursors]::Default; [void](Show-Msg "No se pudo calcular el rango de tamaños: $($_.Exception.Message)" 'Error'); return }
    $script:Form.Cursor = [System.Windows.Forms.Cursors]::Default
    $minMB = [int64][Math]::Ceiling($sup.SizeMin / 1MB); $maxMB = [int64][Math]::Floor($sup.SizeMax / 1MB)
    $curMB = [int64][Math]::Floor($p.Size / 1MB)
    if ($maxMB -le $minMB) { [void](Show-Msg 'La partición no se puede redimensionar (no hay margen disponible).' 'Warning'); return }
    $num = New-Object System.Windows.Forms.NumericUpDown
    $num.Minimum = $minMB; $num.Maximum = $maxMB; $num.Value = [Math]::Min($maxMB, [Math]::Max($minMB, $curMB))
    $num.ThousandsSeparator = $true; $num.Increment = 1024
    $f = [ordered]@{ 'Nuevo tamaño (MB):' = $num }
    $note = "Partición $($p.PartitionNumber) ($($p.DriveLetter):) de $($d.FriendlyName)`n`n" +
            ("Tamaño actual: {0:N0} MB`nMínimo posible: {1:N0} MB`nMáximo posible: {2:N0} MB`n`nSe recomienda respaldar los datos antes de redimensionar." -f $curMB, $minMB, $maxMB)
    if (-not (Show-InputDialog -Title 'Redimensionar partición' -Fields $f -Note $note -OkText 'Redimensionar')) { return }
    $newMB = [int64]$num.Value
    if ($newMB -eq $curMB) { return }
    $size = if ($newMB -ge $maxMB) { [int64]$sup.SizeMax } elseif ($newMB -le $minMB) { [int64]$sup.SizeMin } else { $newMB * 1MB }
    $verb = if ($newMB -gt $curMB) { 'Ampliar' } else { 'Reducir' }
    Start-DiskOp "$verb partición $($p.PartitionNumber) a $newMB MB" $script:ResizeScript @{ n = $d.Number; pn = $p.PartitionNumber; size = $size }
}

function Invoke-DeletePartition {
    $d = Get-SelDisk; if (-not $d) { return }
    $p = Get-SelPartition; if (-not $p) { return }
    $l = if ("$($p.DriveLetter)" -match '^[A-Z]$') { " ($($p.DriveLetter):)" } else { '' }
    if (-not (Confirm-Typed "Se ELIMINARÁ la partición $($p.PartitionNumber)$l de $(Format-Size $p.Size) y todos sus datos.`n$(Get-DiskDescription $d)")) { return }
    Start-DiskOp "Eliminar partición $($p.PartitionNumber)" $script:DeletePartScript @{ n = $d.Number; pn = $p.PartitionNumber }
}

function Invoke-ChangeLetter {
    $d = Get-SelDisk; if (-not $d) { return }
    $p = Get-SelPartition; if (-not $p) { return }
    $old = if ("$($p.DriveLetter)" -match '^[A-Z]$') { "$($p.DriveLetter)" } else { '' }
    $letters = @(Get-FreeLetters)
    $items = @($letters | ForEach-Object { "$($_):" })
    if ($old) { $items += '(Quitar letra)' }
    if ($items.Count -eq 0) { [void](Show-Msg 'No hay letras de unidad disponibles.' 'Warning'); return }
    $cmb = New-Combo $items 0
    $f = [ordered]@{ 'Nueva letra:' = $cmb }
    $note = "Partición $($p.PartitionNumber) de $($d.FriendlyName)`nLetra actual: $(if ($old) { "$($old):" } else { '(ninguna)' })"
    if (-not (Show-InputDialog -Title 'Cambiar letra de unidad' -Fields $f -Note $note)) { return }
    $sel = "$($cmb.SelectedItem)"
    $new = if ($sel -eq '(Quitar letra)') { '-' } else { $sel.Substring(0, 1) }
    Start-DiskOp "Cambiar letra de la partición $($p.PartitionNumber)" $script:LetterScript @{ n = $d.Number; pn = $p.PartitionNumber; letter = $new; oldLetter = $old }
}

function Invoke-Chkdsk {
    $d = Get-SelDisk; if (-not $d) { return }
    $p = Get-SelPartition; if (-not $p) { return }
    if ("$($p.DriveLetter)" -notmatch '^[A-Z]$') { [void](Show-Msg 'La partición necesita una letra de unidad para ejecutar CHKDSK. Asígnela con "Cambiar letra".' 'Warning'); return }
    $L = "$($p.DriveLetter)"
    $cmb = New-Combo @('Solo revisar (no modifica nada)', 'Revisar y reparar errores (/f)', 'Reparar y buscar sectores defectuosos (/r) - lento') 1
    $f = [ordered]@{ 'Modo:' = $cmb }
    $note = "Unidad $($L): - $($d.FriendlyName)`n`nLos modos de reparación desmontan la unidad temporalmente: cierre los archivos abiertos en ella."
    if (-not (Show-InputDialog -Title 'CHKDSK - revisar y reparar' -Fields $f -Note $note -OkText 'Ejecutar')) { return }
    $mode = @('scan', 'fix', 'full')[$cmb.SelectedIndex]
    [void](Start-BgTask -Name "CHKDSK $($L):" -Script $script:ChkdskScript -Params @{ letter = $L; mode = $mode } -Exclusive -Context $L -OnDone {
        param($out, $errs, $ctx)
        $code = if ($out -and $out.Count -gt 0) { [int]"$($out[$out.Count - 1])" } else { -1 }
        $txt = switch ($code) {
            0 { 'No se encontraron errores.' }
            1 { 'Se encontraron y corrigieron errores.' }
            2 { 'Se realizó limpieza del disco (sin errores graves).' }
            3 { 'No se pudo revisar, o hay errores que no se corrigieron. Si eligió "Solo revisar", ejecute el modo de reparación.' }
            default { 'Proceso terminado. Revise el registro para ver el detalle.' }
        }
        Write-Log "CHKDSK $($ctx): código $code - $txt"
        [void](Show-Msg "CHKDSK $($ctx): terminado.`n`n$txt`n`nEl detalle completo está en el registro inferior." $(if ($code -eq 3) { 'Warning' } else { 'Information' }))
        Update-DiskList
    })
}

function Invoke-RemoveWriteProtect {
    $d = Get-SelDisk; if (-not $d) { return }
    $letters = @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue | Where-Object { "$($_.DriveLetter)" -match '^[A-Z]$' } | ForEach-Object { "$($_.DriveLetter)" })
    $regVal = $null
    try { $regVal = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\StorageDevicePolicies' -Name WriteProtect -ErrorAction Stop).WriteProtect } catch {}
    $fixReg = $false
    $msg = "Se quitará el atributo de solo lectura de:`n$(Get-DiskDescription $d)`n`nEstado actual: $(if ($d.IsReadOnly) { 'SOLO LECTURA' } else { 'escritura permitida a nivel de disco' })"
    if ($regVal -eq 1) {
        $r = Show-Msg "La directiva del sistema 'WriteProtect' (registro StorageDevicePolicies) está ACTIVADA: bloquea la escritura en TODAS las memorias USB de este equipo.`n`n¿Desea desactivarla también?`n(Si su equipo es administrado por una empresa, puede haber sido configurada a propósito.)" 'Question' 'YesNoCancel'
        if ($r -eq 'Cancel') { return }
        $fixReg = ($r -eq 'Yes')
    } elseif ((Show-Msg "$msg`n`n¿Continuar?" 'Question' 'YesNo') -ne 'Yes') { return }
    Start-DiskOp 'Quitar protección contra escritura' $script:WriteProtScript @{ n = $d.Number; letters = $letters; fixReg = $fixReg }
}

function Invoke-Eject {
    $d = Get-SelDisk; if (-not $d) { return }
    $desc = Get-DiskDescription $d
    [void](Start-BgTask -Name 'Expulsar unidad' -Script $script:EjectScript -Params @{ n = $d.Number } -Exclusive -Context $desc -OnDone {
        param($out, $errs, $ctx)
        $res = if ($out -and $out.Count -gt 0) { "$($out[0])" } else { '' }
        if ($errs.Count -gt 0) { [void](Show-Msg ("No se pudo expulsar:`n" + ($errs -join "`n")) 'Error') }
        elseif ($res -eq 'OK') {
            Write-Log "Unidad expulsada: $ctx"
            [void](Show-Msg "Ya puede retirar la unidad de forma segura.`n`n$ctx" 'Information')
        } else {
            Write-Log $res
            [void](Show-Msg $res 'Warning')
        }
        Update-DiskList
    })
}

function Export-Report {
    if ($null -eq $script:SelDisk) { [void](Show-Msg 'Seleccione una unidad primero.' 'Warning'); return }
    $sfd = New-Object System.Windows.Forms.SaveFileDialog
    $sfd.Filter = 'Archivo de texto (*.txt)|*.txt'
    $sfd.FileName = 'Reporte_USB_Disco{0}_{1:yyyyMMdd_HHmm}.txt' -f $script:SelDisk, (Get-Date)
    $sfd.InitialDirectory = [Environment]::GetFolderPath('Desktop')
    $script:Modal++
    try { if ($sfd.ShowDialog($script:Form) -ne 'OK') { return } } finally { $script:Modal-- }
    $sb = New-Object System.Text.StringBuilder
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    [void]$sb.AppendLine("REPORTE - $script:AppName")
    [void]$sb.AppendLine(('Fecha: {0:dd/MM/yyyy HH:mm:ss}' -f (Get-Date)))
    [void]$sb.AppendLine("Equipo: $env:COMPUTERNAME   Sistema: $($os.Caption) ($($os.Version))")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('=== UNIDADES USB DETECTADAS ===')
    foreach ($r in $dtDisks.Rows) { [void]$sb.AppendLine(($dtDisks.Columns | ForEach-Object { "$($_.ColumnName): $($r[$_.ColumnName])" }) -join ' | ') }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("=== DISCO $($script:SelDisk) - $($lblBanner.Text) ===")
    [void]$sb.AppendLine($rtb.Text)
    [void]$sb.AppendLine('=== PARTICIONES ===')
    foreach ($r in $dtParts.Rows) { [void]$sb.AppendLine(($dtParts.Columns | ForEach-Object { "$($_.ColumnName): $($r[$_.ColumnName])" }) -join ' | ') }
    [void]$sb.AppendLine($lblFree.Text)
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('=== REGISTRO DE LA SESIÓN ===')
    [void]$sb.AppendLine($txtLog.Text)
    [System.IO.File]::WriteAllText($sfd.FileName, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
    Write-Log "Reporte guardado en $($sfd.FileName)"
    [void](Show-Msg "Reporte guardado en:`n$($sfd.FileName)" 'Information')
}

function Show-Help {
    $t = @"
$script:AppName v1.0

SALUD
 • El estado combina: estado de Windows del disco, SMART (si el dispositivo lo expone), contadores de confiabilidad, estado de los volúmenes y la última prueba de integridad.
 • La mayoría de memorias USB NO exponen SMART. La forma más fiable de saber si una memoria está bien es la "Prueba de velocidad e integridad".
 • "Todo el espacio libre" detecta memorias FALSAS (que dicen tener 128 GB pero tienen 8 GB reales) y celdas dañadas. No borra sus archivos.

FORMATO Y PARTICIONES
 • exFAT: recomendado para memorias. FAT32: archivos de máx. 4 GB y volúmenes de máx. 32 GB en Windows. NTFS: solo Windows.
 • "Formatear disco completo" elimina todo y crea una sola partición: útil para memorias con capacidad "perdida".
 • Redimensionar solo funciona con NTFS (limitación de Windows).
 • Varias particiones en memorias USB requieren Windows 10 versión 1703 o posterior.

REPARACIÓN
 • CHKDSK repara el sistema de archivos (no la memoria física).
 • Protección contra escritura: se quitan los atributos de Windows. Si la memoria tiene interruptor físico, muévalo. Una memoria que vuelve sola a "solo lectura" suele estar al final de su vida útil.

SEGURIDAD
 • Solo se muestran unidades USB/SD. El disco del sistema nunca se puede modificar.
 • Las operaciones destructivas piden escribir BORRAR para confirmar.
"@
    [void](Show-Msg $t 'Information')
}

# ------------------------------------------------------------------
#  Eventos
# ------------------------------------------------------------------
$gridDisks.Add_SelectionChanged({
    if ($script:Binding) { return }
    if ($gridDisks.SelectedRows.Count -gt 0) {
        $n = [int]$gridDisks.SelectedRows[0].Cells['Disco'].Value
        if ($n -ne $script:SelDisk) { Select-Disk $n }
    }
})

$gridDisks.Add_DataBindingComplete({
    if ($gridDisks.Columns.Contains('Disco')) { $gridDisks.Columns['Disco'].FillWeight = 40 }
    if ($gridDisks.Columns.Contains('Modelo')) { $gridDisks.Columns['Modelo'].FillWeight = 180 }
    if ($gridDisks.Columns.Contains('Estilo')) { $gridDisks.Columns['Estilo'].FillWeight = 50 }
    foreach ($c in $gridDisks.Columns) { $c.SortMode = 'NotSortable' }
})
$gridParts.Add_DataBindingComplete({
    if ($gridParts.Columns.Contains('Partición')) { $gridParts.Columns['Partición'].FillWeight = 55 }
    if ($gridParts.Columns.Contains('Letra')) { $gridParts.Columns['Letra'].FillWeight = 40 }
    foreach ($c in $gridParts.Columns) { $c.SortMode = 'NotSortable' }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 250
$timer.Add_Tick({
    try {
        Invoke-TaskPump
        $script:TickCount++
        if ($chkAuto.Checked -and -not $script:Busy -and $script:Modal -eq 0 -and ($script:TickCount % 12) -eq 0) {
            $sig = Get-DeviceSignature
            if ($sig -ne $script:Signature) {
                Write-Log 'Cambio de dispositivos detectado. Actualizando lista...'
                Update-DiskList
            }
        }
    } catch { Write-Log "Error interno: $_" }
})

$form.Add_Shown({
    try {
        $splitMain.SplitterDistance = [int]($splitMain.Height * 0.36)
        $splitBottom.SplitterDistance = [int]($splitBottom.Width * 0.52)
    } catch {}
    Write-Log "$script:AppName iniciado. Detectando unidades USB..."
    Update-DiskList
    $timer.Start()
})

$form.Add_FormClosing({
    param($s, $e)
    if ($script:Busy) {
        $r = [System.Windows.Forms.MessageBox]::Show($script:Form, "Hay una operación en curso. Cerrar ahora puede dejar la unidad en un estado inconsistente.`n`n¿Desea cerrar de todos modos?", $script:AppName, 'YesNo', 'Warning')
        if ($r -ne 'Yes') { $e.Cancel = $true; return }
        if ($script:CurrentTask) { $script:CurrentTask.Sync.Cancel = $true }
    }
    $timer.Stop()
})

try {
    [void]$form.ShowDialog()
} catch {
    [void][System.Windows.Forms.MessageBox]::Show("Error inesperado:`n$($_.Exception.Message)", $script:AppName, 'OK', 'Error')
} finally {
    foreach ($t in @($script:Tasks)) { try { $t.PS.Stop(); $t.PS.Dispose() } catch {} }
    $form.Dispose()
}
