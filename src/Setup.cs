// PulsoUSB-Setup.exe - instalador / desinstalador.
//   PulsoUSB-Setup.exe              asistente gráfico
//   PulsoUSB-Setup.exe /S           instalación silenciosa (Program Files, accesos directos)
//   uninstall.exe /uninstall [/S]   desinstalación (la usa "Aplicaciones instaladas" de Windows)
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: AssemblyTitle("Instalador de PulsoUSB")]
[assembly: AssemblyDescription("Instalador de PulsoUSB")]
[assembly: AssemblyProduct("PulsoUSB")]
[assembly: AssemblyCompany("aarneth")]
[assembly: AssemblyCopyright("© 2026 aarneth")]
[assembly: AssemblyVersion("1.0.1.0")]
[assembly: AssemblyFileVersion("1.0.1.0")]
[assembly: AssemblyInformationalVersion("1.0.1")]

static class Setup
{
    public const string AppName = "PulsoUSB";
    public const string Version = "1.0.1";
    public const string Publisher = "aarneth";
    public const string Url = "https://github.com/aarneth/PulsoUSB";
    const string UninstKey = @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PulsoUSB";

    public static string DefaultDir
    {
        get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), AppName); }
    }
    static string StartMenuLink
    {
        get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonPrograms), AppName + ".lnk"); }
    }
    static string DesktopLink
    {
        get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonDesktopDirectory), AppName + ".lnk"); }
    }

    [STAThread]
    static int Main(string[] args)
    {
        Application.EnableVisualStyles();
        bool silent = false, uninstall = false;
        foreach (string a in args)
        {
            string x = a.ToLowerInvariant();
            if (x == "/s" || x == "/silent" || x == "-s") silent = true;
            if (x == "/uninstall" || x == "-uninstall") uninstall = true;
        }
        try
        {
            if (uninstall) return Uninstall(silent);
            if (silent) { Install(DefaultDir, true, true); return 0; }
            Application.Run(new SetupForm());
            return 0;
        }
        catch (Exception ex)
        {
            if (!silent) MessageBox.Show("Error: " + ex.Message, AppName, MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    public static string InstalledDir()
    {
        using (RegistryKey k = Registry.LocalMachine.OpenSubKey(UninstKey))
            return k == null ? null : k.GetValue("InstallLocation") as string;
    }

    static bool EnsureNotRunning(bool silent)
    {
        while (Process.GetProcessesByName(AppName).Length > 0)
        {
            if (silent)
            {
                foreach (Process p in Process.GetProcessesByName(AppName)) { try { p.Kill(); p.WaitForExit(5000); } catch { } }
                return true;
            }
            DialogResult r = MessageBox.Show("PulsoUSB está abierto. Ciérrelo y pulse Reintentar.", AppName,
                MessageBoxButtons.RetryCancel, MessageBoxIcon.Warning);
            if (r != DialogResult.Retry) return false;
        }
        return true;
    }

    public static bool Install(string dir, bool desktop, bool silent = false)
    {
        if (!EnsureNotRunning(silent)) return false;
        Directory.CreateDirectory(dir);
        string exe = Path.Combine(dir, AppName + ".exe");
        using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("PulsoUSB.exe"))
        using (FileStream f = File.Create(exe))
            s.CopyTo(f);

        string self = Assembly.GetExecutingAssembly().Location;
        string uninst = Path.Combine(dir, "uninstall.exe");
        if (!string.Equals(Path.GetFullPath(self), Path.GetFullPath(uninst), StringComparison.OrdinalIgnoreCase))
            File.Copy(self, uninst, true);

        CreateShortcut(StartMenuLink, exe, dir);
        if (desktop) CreateShortcut(DesktopLink, exe, dir);
        else if (File.Exists(DesktopLink)) File.Delete(DesktopLink);

        using (RegistryKey k = Registry.LocalMachine.CreateSubKey(UninstKey))
        {
            k.SetValue("DisplayName", AppName);
            k.SetValue("DisplayVersion", Version);
            k.SetValue("Publisher", Publisher);
            k.SetValue("DisplayIcon", exe + ",0");
            k.SetValue("InstallLocation", dir);
            k.SetValue("URLInfoAbout", Url);
            k.SetValue("UninstallString", "\"" + uninst + "\" /uninstall");
            k.SetValue("QuietUninstallString", "\"" + uninst + "\" /uninstall /S");
            k.SetValue("NoModify", 1, RegistryValueKind.DWord);
            k.SetValue("NoRepair", 1, RegistryValueKind.DWord);
            k.SetValue("EstimatedSize", (int)((new FileInfo(exe).Length + new FileInfo(uninst).Length) / 1024), RegistryValueKind.DWord);
            k.SetValue("InstallDate", DateTime.Now.ToString("yyyyMMdd"));
        }
        return true;
    }

    static int Uninstall(bool silent)
    {
        string dir = InstalledDir();
        if (string.IsNullOrEmpty(dir)) dir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        if (!silent && MessageBox.Show("¿Desea desinstalar PulsoUSB?", AppName, MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes)
            return 1;
        if (!EnsureNotRunning(silent)) return 1;

        try { if (File.Exists(StartMenuLink)) File.Delete(StartMenuLink); } catch { }
        try { if (File.Exists(DesktopLink)) File.Delete(DesktopLink); } catch { }
        try { Registry.LocalMachine.DeleteSubKeyTree(UninstKey, false); } catch { }
        try { File.Delete(Path.Combine(dir, AppName + ".exe")); } catch { }

        // Solo se borra la carpeta si contiene los archivos de PulsoUSB (nunca otra carpeta)
        string self = Assembly.GetExecutingAssembly().Location;
        bool selfInDir = string.Equals(Path.GetDirectoryName(Path.GetFullPath(self)).TrimEnd('\\'),
                                       Path.GetFullPath(dir).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase);
        if (selfInDir)
        {
            ProcessStartInfo psi = new ProcessStartInfo("cmd.exe",
                "/c ping 127.0.0.1 -n 3 > nul & del /f /q \"" + self + "\" & rmdir \"" + dir + "\"");
            psi.CreateNoWindow = true; psi.UseShellExecute = false;
            Process.Start(psi);
        }
        else
        {
            try { File.Delete(Path.Combine(dir, "uninstall.exe")); } catch { }
            try { Directory.Delete(dir, false); } catch { }
        }
        if (!silent) MessageBox.Show("PulsoUSB se desinstaló correctamente.", AppName, MessageBoxButtons.OK, MessageBoxIcon.Information);
        return 0;
    }

    static void CreateShortcut(string lnk, string target, string workDir)
    {
        Type t = Type.GetTypeFromProgID("WScript.Shell");
        object shell = Activator.CreateInstance(t);
        object sc = t.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { lnk });
        Type st = sc.GetType();
        st.InvokeMember("TargetPath", BindingFlags.SetProperty, null, sc, new object[] { target });
        st.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, sc, new object[] { workDir });
        st.InvokeMember("IconLocation", BindingFlags.SetProperty, null, sc, new object[] { target + ",0" });
        st.InvokeMember("Description", BindingFlags.SetProperty, null, sc, new object[] { "Diagnóstico de salud y administración de unidades USB" });
        st.InvokeMember("Save", BindingFlags.InvokeMethod, null, sc, null);
    }
}

class SetupForm : Form
{
    TextBox txtDir;
    CheckBox chkDesktop, chkLaunch;

    public SetupForm()
    {
        Text = "Instalar PulsoUSB " + Setup.Version;
        Font = new Font("Segoe UI", 9f);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false; MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        AutoScaleMode = AutoScaleMode.Font;
        ClientSize = new Size(520, 300);
        try { Icon = Icon.ExtractAssociatedIcon(Assembly.GetExecutingAssembly().Location); } catch { }

        Panel header = new Panel();
        header.Dock = DockStyle.Top; header.Height = 70;
        header.BackColor = Color.FromArgb(0, 92, 175);
        Label title = new Label();
        title.Text = "PulsoUSB " + Setup.Version;
        title.ForeColor = Color.White; title.Font = new Font("Segoe UI", 15f, FontStyle.Bold);
        title.AutoSize = true; title.Location = new Point(16, 8);
        Label sub = new Label();
        sub.Text = "Diagnóstico de salud y administración de unidades USB";
        sub.ForeColor = Color.White; sub.AutoSize = true; sub.Location = new Point(19, 42);
        header.Controls.Add(title); header.Controls.Add(sub);
        Controls.Add(header);

        string existing = Setup.InstalledDir();
        Label info = new Label();
        info.AutoSize = false; info.Location = new Point(16, 84); info.Size = new Size(488, 36);
        info.Text = existing != null
            ? "Ya hay una versión instalada. Se actualizará en la misma carpeta."
            : "Elija la carpeta de instalación:";
        Controls.Add(info);

        txtDir = new TextBox();
        txtDir.Location = new Point(16, 124); txtDir.Size = new Size(395, 25);
        txtDir.Text = existing ?? Setup.DefaultDir;
        Controls.Add(txtDir);

        Button browse = new Button();
        browse.Text = "Examinar..."; browse.Location = new Point(418, 122); browse.Size = new Size(86, 28);
        browse.Click += delegate
        {
            using (FolderBrowserDialog fb = new FolderBrowserDialog())
            {
                fb.Description = "Carpeta de instalación de PulsoUSB";
                if (fb.ShowDialog(this) == DialogResult.OK) txtDir.Text = Path.Combine(fb.SelectedPath, Setup.AppName);
            }
        };
        Controls.Add(browse);

        chkDesktop = new CheckBox();
        chkDesktop.Text = "Crear acceso directo en el escritorio"; chkDesktop.Checked = true;
        chkDesktop.AutoSize = true; chkDesktop.Location = new Point(16, 164);
        Controls.Add(chkDesktop);

        chkLaunch = new CheckBox();
        chkLaunch.Text = "Abrir PulsoUSB al terminar"; chkLaunch.Checked = true;
        chkLaunch.AutoSize = true; chkLaunch.Location = new Point(16, 190);
        Controls.Add(chkLaunch);

        Label req = new Label();
        req.Text = "Requisitos: Windows 10 (1703 o posterior) u 11. PulsoUSB se ejecuta como administrador.";
        req.ForeColor = Color.DimGray; req.AutoSize = true; req.Location = new Point(16, 222);
        Controls.Add(req);

        Button install = new Button();
        install.Text = "Instalar"; install.Location = new Point(324, 254); install.Size = new Size(88, 32);
        install.Click += OnInstall;
        Controls.Add(install);
        AcceptButton = install;

        Button cancel = new Button();
        cancel.Text = "Cancelar"; cancel.Location = new Point(418, 254); cancel.Size = new Size(86, 32);
        cancel.Click += delegate { Close(); };
        Controls.Add(cancel);
        CancelButton = cancel;
    }

    void OnInstall(object sender, EventArgs e)
    {
        string dir = txtDir.Text.Trim();
        if (dir.Length == 0 || !Path.IsPathRooted(dir))
        {
            MessageBox.Show("Indique una carpeta válida (ruta completa).", Setup.AppName, MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }
        Cursor = Cursors.WaitCursor; Enabled = false;
        try
        {
            if (!Setup.Install(dir, chkDesktop.Checked)) { Enabled = true; Cursor = Cursors.Default; return; }
        }
        catch (Exception ex)
        {
            Enabled = true; Cursor = Cursors.Default;
            MessageBox.Show("No se pudo instalar: " + ex.Message, Setup.AppName, MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }
        Cursor = Cursors.Default;
        MessageBox.Show("PulsoUSB se instaló correctamente.\n\nLo encontrará en el menú Inicio" +
            (chkDesktop.Checked ? " y en el escritorio." : "."), Setup.AppName, MessageBoxButtons.OK, MessageBoxIcon.Information);
        if (chkLaunch.Checked)
        {
            try { Process.Start(new ProcessStartInfo(Path.Combine(dir, Setup.AppName + ".exe")) { UseShellExecute = true, WorkingDirectory = dir }); } catch { }
        }
        Close();
    }
}
