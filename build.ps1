<#
    Compila PulsoUSB sin dependencias externas (usa csc.exe de .NET Framework 4.x, incluido en Windows).

    Genera en .\dist:
      PulsoUSB.exe                    programa (lo incrusta el instalador)
      PulsoUSB-Portable-<ver>.exe     versión portable (no requiere instalación)
      PulsoUSB-Setup-<ver>.exe        instalador
      SHA256SUMS.txt                  sumas de verificación

    Uso:  powershell -ExecutionPolicy Bypass -File .\build.ps1
#>
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
Set-Location $root

$script = Join-Path $root 'PulsoUSB.ps1'
$ver = ([regex]::Match([IO.File]::ReadAllText($script), "\`$script:AppVersion = '([\d\.]+)'")).Groups[1].Value
if (-not $ver) { throw 'No se encontró $script:AppVersion en PulsoUSB.ps1' }

$csc = Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:windir 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw 'No se encontró csc.exe (.NET Framework 4.x).' }
$sma = [PSObject].Assembly.Location

$obj = Join-Path $root 'obj'; $dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force $obj, $dist | Out-Null

# ---------------------------------------------------------------- icono
function New-PulsoIcon([string]$Path) {
    Add-Type -AssemblyName System.Drawing
    $sizes = 16, 24, 32, 48, 64, 128, 256
    $pngs = foreach ($s in $sizes) {
        $bmp = New-Object System.Drawing.Bitmap($s, $s)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = 'AntiAlias'
        $g.Clear([System.Drawing.Color]::Transparent)
        $r = [single]($s * 0.22)
        $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
        $w = [single]($s - 1)
        $gp.AddArc(0, 0, $r, $r, 180, 90); $gp.AddArc($w - $r, 0, $r, $r, 270, 90)
        $gp.AddArc($w - $r, $w - $r, $r, $r, 0, 90); $gp.AddArc(0, $w - $r, $r, $r, 90, 90); $gp.CloseFigure()
        $rect = New-Object System.Drawing.RectangleF(0, 0, $s, $s)
        $br = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, [System.Drawing.Color]::FromArgb(0, 168, 150), [System.Drawing.Color]::FromArgb(0, 84, 170), 45.0)
        $g.FillPath($br, $gp)
        # Conector USB estilizado (parte superior)
        $plug = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(235, 255, 255, 255))
        $g.FillRectangle($plug, [single]($s * 0.36), [single]($s * 0.12), [single]($s * 0.28), [single]($s * 0.16))
        $dark = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(0, 110, 160))
        if ($s -ge 32) {
            $g.FillRectangle($dark, [single]($s * 0.41), [single]($s * 0.16), [single]($s * 0.06), [single]($s * 0.05))
            $g.FillRectangle($dark, [single]($s * 0.53), [single]($s * 0.16), [single]($s * 0.06), [single]($s * 0.05))
        }
        # Línea de pulso
        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, [single]([Math]::Max(1.5, $s * 0.075)))
        $pen.LineJoin = 'Round'; $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
        $pts = @(@(0.12, 0.62), @(0.34, 0.62), @(0.43, 0.42), @(0.53, 0.84), @(0.62, 0.52), @(0.68, 0.62), @(0.88, 0.62)) |
            ForEach-Object { New-Object System.Drawing.PointF([single]($_[0] * $s), [single]($_[1] * $s)) }
        $g.DrawLines($pen, [System.Drawing.PointF[]]$pts)
        $g.Dispose()
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
        , $ms.ToArray()
    }
    # Archivo ICO con imágenes PNG (Windows Vista+)
    $out = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($out)
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $s = $sizes[$i]; $len = $pngs[$i].Length
        $bw.Write([byte]($(if ($s -ge 256) { 0 } else { $s }))); $bw.Write([byte]($(if ($s -ge 256) { 0 } else { $s })))
        $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([uint16]1); $bw.Write([uint16]32)
        $bw.Write([uint32]$len); $bw.Write([uint32]$offset); $offset += $len
    }
    foreach ($p in $pngs) { $bw.Write([byte[]]$p) }
    $bw.Flush()
    [IO.File]::WriteAllBytes($Path, $out.ToArray())
}

$ico = Join-Path $root 'assets\PulsoUSB.ico'
if (-not (Test-Path $ico)) {
    New-Item -ItemType Directory -Force (Split-Path $ico) | Out-Null
    New-PulsoIcon $ico
    Write-Host "Icono generado: $ico"
}

# ---------------------------------------------------------------- código C# del script
$m = [regex]::Match([IO.File]::ReadAllText($script), "(?s)Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@")
if (-not $m.Success) { throw 'No se encontró el bloque C# en PulsoUSB.ps1' }
$usbTool = Join-Path $obj 'UsbTool.cs'
[IO.File]::WriteAllText($usbTool, $m.Groups[1].Value, (New-Object Text.UTF8Encoding($true)))

function Invoke-Csc([string[]]$CscArgs) {
    & $csc /nologo /codepage:65001 /optimize+ /platform:anycpu /target:winexe @CscArgs
    if ($LASTEXITCODE -ne 0) { throw "csc falló (código $LASTEXITCODE)" }
}

# ---------------------------------------------------------------- PulsoUSB.exe
$appExe = Join-Path $dist 'PulsoUSB.exe'
Invoke-Csc @(
    "/out:$appExe", "/win32icon:$ico", "/win32manifest:$root\src\app.manifest",
    "/reference:$sma", '/reference:System.Windows.Forms.dll', '/reference:System.Drawing.dll',
    "/resource:$script,PulsoUSB.ps1",
    "$root\src\Launcher.cs", $usbTool)
Write-Host "OK  $appExe"

$portable = Join-Path $dist "PulsoUSB-Portable-$ver.exe"
Copy-Item $appExe $portable -Force
Write-Host "OK  $portable"

# ---------------------------------------------------------------- instalador
$setup = Join-Path $dist "PulsoUSB-Setup-$ver.exe"
Invoke-Csc @(
    "/out:$setup", "/win32icon:$ico", "/win32manifest:$root\src\app.manifest",
    '/reference:System.Windows.Forms.dll', '/reference:System.Drawing.dll',
    "/resource:$appExe,PulsoUSB.exe",
    "$root\src\Setup.cs")
Write-Host "OK  $setup"

# ---------------------------------------------------------------- sumas
$sums = Get-ChildItem $dist -Filter "PulsoUSB-*-$ver.exe" | ForEach-Object {
    '{0}  {1}' -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower(), $_.Name
}
Set-Content -Path (Join-Path $dist 'SHA256SUMS.txt') -Value $sums -Encoding ASCII
$sums
