// PulsoUSB.exe - lanzador que ejecuta el script PulsoUSB.ps1 incrustado como recurso
// dentro de un runspace de PowerShell 5.1 (incluido en Windows 10/11).
// Los tipos de UsbTool (UsbTool.cs, generado desde el script) se compilan dentro
// de este mismo .exe, así el script no necesita compilar C# al iniciar.
using System;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using System.Management.Automation;
using System.Management.Automation.Runspaces;

[assembly: AssemblyTitle("PulsoUSB")]
[assembly: AssemblyDescription("Diagnóstico de salud y administración de unidades USB")]
[assembly: AssemblyProduct("PulsoUSB")]
[assembly: AssemblyCompany("aarneth")]
[assembly: AssemblyCopyright("© 2026 aarneth")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]
[assembly: AssemblyInformationalVersion("1.0.0")]

static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        try
        {
            // Equivalente a -ExecutionPolicy Bypass para este proceso y sus runspaces
            Environment.SetEnvironmentVariable("PSExecutionPolicyPreference", "Bypass");

            string script;
            using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("PulsoUSB.ps1"))
            using (StreamReader r = new StreamReader(s, Encoding.UTF8))
                script = r.ReadToEnd();

            InitialSessionState iss = InitialSessionState.CreateDefault();
            iss.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
            using (Runspace rs = RunspaceFactory.CreateRunspace(iss))
            {
                rs.ApartmentState = ApartmentState.STA;
                rs.ThreadOptions = PSThreadOptions.UseCurrentThread;
                rs.Open();
                using (PowerShell ps = PowerShell.Create())
                {
                    ps.Runspace = rs;
                    ps.AddScript(script);
                    ps.Invoke();
                }
            }
            return 0;
        }
        catch (Exception ex)
        {
            Exception e = ex;
            while (e.InnerException != null) e = e.InnerException;
            MessageBox.Show("PulsoUSB no pudo iniciarse:\n\n" + e.Message, "PulsoUSB",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
