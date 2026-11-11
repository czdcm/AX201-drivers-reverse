$ErrorActionPreference = 'Continue'
$work = 'C:\ProgramData\AX201work\ihv'
$log  = 'C:\ProgramData\AX201work\rollback\ihv-probe2.log'
Set-Content -Path $log -Value 'STARTED' -Encoding utf8
function L($m) { Add-Content -Path $log -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding utf8 }

$src = @'
using System;
using System.IO;
using System.Security.Principal;
using System.Text;
using System.Runtime.InteropServices;

class IhvProbe2
{
    [DllImport("wlanapi.dll")]
    static extern uint WlanOpenHandle(uint v, IntPtr r, out uint n, out IntPtr h);
    [DllImport("wlanapi.dll")]
    static extern uint WlanCloseHandle(IntPtr h, IntPtr r);
    [DllImport("wlanapi.dll")]
    static extern uint WlanIhvControl(IntPtr h, ref Guid guid, int type,
        uint inSize, byte[] inBuf, uint outSize, byte[] outBuf, out uint returned);

    static StringBuilder log = new StringBuilder();

    static void Main(string[] args)
    {
        string path = args.Length > 0 ? args[0] : @"C:\ProgramData\AX201work\rollback\ihv-inner2.log";
        try { log.AppendLine("identity=" + WindowsIdentity.GetCurrent().Name); }
        catch (Exception ex) { log.AppendLine("identity ERROR " + ex.Message); }

        Guid g = new Guid("FCB16329-6BE3-429A-B6BF-880F68B827B7");
        uint neg = 0; IntPtr h = IntPtr.Zero;
        uint rc = WlanOpenHandle(2, IntPtr.Zero, out neg, out h);
        log.AppendLine("WlanOpenHandle rc=0x" + rc.ToString("X8"));
        if (rc == 0)
        {
            uint outSize = 512;
            byte[] output = new byte[outSize];
            uint returned = 0;
            uint r1 = WlanIhvControl(h, ref g, 1, 16, new byte[16], outSize, output, out returned);
            log.AppendLine("drv/16z rc=0x" + r1.ToString("X8"));
            uint r2 = WlanIhvControl(h, ref g, 0, 16, new byte[16], outSize, output, out returned);
            log.AppendLine("svc/16z rc=0x" + r2.ToString("X8"));
            WlanCloseHandle(h, IntPtr.Zero);
        }
        log.AppendLine("DONE");
        File.AppendAllText(path, log.ToString(), Encoding.UTF8);
    }
}
'@

$cs = Join-Path $work 'IhvProbe2.cs'
Set-Content -Path $cs -Value $src -Encoding utf8
$csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$exe = Join-Path $work 'IhvProbe2.exe'
if (Test-Path $exe) { Remove-Item $exe -Force }
$cr = & $csc /nologo /out:$exe $cs 2>&1
foreach ($x in @($cr)) { L ("csc: " + ([string]$x).TrimEnd()) }
if (-not (Test-Path $exe)) { L 'COMPILE_FAILED'; L 'DONE2'; exit 1 }

$inner = 'C:\ProgramData\AX201work\rollback\ihv-inner2.log'
if (Test-Path $inner) { Remove-Item $inner -Force }

$svcName = 'Ax201IhvProbe2'
& sc.exe stop $svcName 2>&1 | Out-Null
& sc.exe delete $svcName 2>&1 | Out-Null
Start-Sleep -Seconds 1

$binPath = '"' + $exe + '" "' + $inner + '"'
$out = & sc.exe create $svcName binPath= $binPath obj= 'NT AUTHORITY\NetworkService' start= demand 2>&1
foreach ($x in @($out)) { L ("sc create: " + ([string]$x).TrimEnd()) }
$qc = & sc.exe qc $svcName 2>&1
foreach ($x in @($qc)) { L ("sc qc: " + ([string]$x).TrimEnd()) }

$out = & sc.exe start $svcName 2>&1
foreach ($x in @($out)) { L ("sc start: " + ([string]$x).TrimEnd()) }
Start-Sleep -Seconds 4
& sc.exe delete $svcName 2>&1 | Out-Null

L '-- inner log'
if (Test-Path $inner) { foreach ($line in (Get-Content $inner)) { L ("   " + $line) } } else { L '   NO_INNER_LOG' }
L 'DONE2'
