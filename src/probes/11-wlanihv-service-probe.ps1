$ErrorActionPreference = 'Continue'
$work = 'C:\ProgramData\AX201work\ihv'
$log  = 'C:\ProgramData\AX201work\rollback\ihv-probe.log'
New-Item -ItemType Directory -Force -Path $work | Out-Null
Set-Content -Path $log -Value 'STARTED' -Encoding utf8
function L($m) { Add-Content -Path $log -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding utf8 }

$src = @'
using System;
using System.IO;
using System.Text;
using System.Runtime.InteropServices;

class IhvProbe
{
    [DllImport("wlanapi.dll")]
    static extern uint WlanOpenHandle(uint v, IntPtr r, out uint n, out IntPtr h);
    [DllImport("wlanapi.dll")]
    static extern uint WlanCloseHandle(IntPtr h, IntPtr r);
    [DllImport("wlanapi.dll")]
    static extern uint WlanIhvControl(IntPtr h, ref Guid guid, int type,
        uint inSize, byte[] inBuf, uint outSize, byte[] outBuf, out uint returned);

    static StringBuilder log = new StringBuilder();

    static void Call(IntPtr h, Guid g, string label, int type, byte[] input)
    {
        uint outSize = 512;
        byte[] output = new byte[outSize];
        uint returned = 0;
        uint rc;
        try
        {
            rc = WlanIhvControl(h, ref g, type, (uint)(input == null ? 0 : input.Length), input,
                                outSize, output, out returned);
        }
        catch (Exception ex)
        {
            log.AppendLine(label + " EXCEPTION " + ex.GetType().Name + " " + ex.Message);
            return;
        }
        StringBuilder hex = new StringBuilder();
        for (int i = 0; i < Math.Min(returned, 32); i++) hex.Append(output[i].ToString("X2"));
        log.AppendLine(string.Format("{0} type={1} inLen={2} rc=0x{3:X8} returned={4} data={5}",
            label, type, input == null ? 0 : input.Length, rc, returned, hex.ToString()));
    }

    static void Main(string[] args)
    {
        string path = args.Length > 0 ? args[0] : @"C:\ProgramData\AX201work\rollback\ihv-inner.log";
        Guid g = new Guid("FCB16329-6BE3-429A-B6BF-880F68B827B7");
        uint neg = 0;
        IntPtr h = IntPtr.Zero;
        uint rc = WlanOpenHandle(2, IntPtr.Zero, out neg, out h);
        log.AppendLine("WlanOpenHandle rc=0x" + rc.ToString("X8") + " h=" + h);
        if (rc == 0)
        {
            Call(h, g, "svc/zero", 0, null);
            Call(h, g, "drv/zero", 1, null);
            Call(h, g, "drv/8z", 1, new byte[8]);
            Call(h, g, "drv/16z", 1, new byte[16]);
            Call(h, g, "drv/32z", 1, new byte[32]);
            WlanCloseHandle(h, IntPtr.Zero);
        }
        log.AppendLine("DONE");
        File.AppendAllText(path, log.ToString(), Encoding.UTF8);
    }
}
'@

$cs = Join-Path $work 'IhvProbe.cs'
Set-Content -Path $cs -Value $src -Encoding utf8
L ("source written=" + (Test-Path $cs))

$csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
L ("csc exists=" + (Test-Path $csc))
$exe = Join-Path $work 'IhvProbe.exe'
if (Test-Path $exe) { Remove-Item $exe -Force }
$cr = & $csc /nologo /out:$exe $cs 2>&1
foreach ($x in @($cr)) { L ("csc: " + ([string]$x).TrimEnd()) }
L ("exe exists=" + (Test-Path $exe))
if (-not (Test-Path $exe)) { L 'COMPILE_FAILED'; L 'IHV_DONE'; exit 1 }

$inner = 'C:\ProgramData\AX201work\rollback\ihv-inner.log'
if (Test-Path $inner) { Remove-Item $inner -Force }

$svcName = 'Ax201IhvProbe'
L '-- cleanup any previous service'
& sc.exe stop $svcName 2>&1 | Out-Null
& sc.exe delete $svcName 2>&1 | Out-Null
Start-Sleep -Seconds 1

L '-- create service running as NetworkService'
$binPath = '"' + $exe + '" "' + $inner + '"'
$out = & sc.exe create $svcName binPath= $binPath obj= 'NT AUTHORITY\NetworkService' start= demand 2>&1
foreach ($x in @($out)) { L ("sc create: " + ([string]$x).TrimEnd()) }

L '-- start service'
$out = & sc.exe start $svcName 2>&1
foreach ($x in @($out)) { L ("sc start: " + ([string]$x).TrimEnd()) }

Start-Sleep -Seconds 4

L '-- stop and delete'
$out = & sc.exe stop $svcName 2>&1
foreach ($x in @($out)) { L ("sc stop: " + ([string]$x).TrimEnd()) }
Start-Sleep -Seconds 1
$out = & sc.exe delete $svcName 2>&1
foreach ($x in @($out)) { L ("sc delete: " + ([string]$x).TrimEnd()) }

L '-- inner log'
if (Test-Path $inner) {
  foreach ($line in (Get-Content $inner)) { L ("   " + $line) }
} else { L '   NO_INNER_LOG' }

L 'IHV_DONE'
