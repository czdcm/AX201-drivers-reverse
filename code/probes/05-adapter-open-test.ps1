$ErrorActionPreference = 'Continue'
$out = 'C:\ProgramData\AX201work\rollback'
$log = Join-Path $out 'open-test.log'
Set-Content -Path $log -Value 'STARTED' -Encoding utf8
function L($m) { Add-Content -Path $log -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding utf8 }

$cs = @'
using System;
using System.Runtime.InteropServices;
public static class Npf4 {
  [DllImport("Packet.dll", CharSet=CharSet.Ansi, SetLastError=true)]
  public static extern IntPtr PacketOpenAdapter(string name);
  [DllImport("Packet.dll", SetLastError=true)]
  public static extern void PacketCloseAdapter(IntPtr a);
}
'@
Add-Type -TypeDefinition $cs -ErrorAction Stop
L 'Add-Type OK'

$g = 'FCB16329-6BE3-429A-B6BF-880F68B827B7'
$variants = @(
  "\Device\NPF_{$g}",
  "\\.\NPF_{$g}",
  "NPF_{$g}",
  "\\.\Device\NPF_{$g}",
  "{$g}"
)
foreach ($v in $variants) {
  try {
    $h = [Npf4]::PacketOpenAdapter($v)
    $e = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    L ("name=[" + $v + "] handle=" + $h + " err=" + $e)
    if ($h -ne [IntPtr]::Zero) { [Npf4]::PacketCloseAdapter($h) }
  } catch { L ("name=[" + $v + "] EXCEPTION " + $_.Exception.Message) }
}

L '-- also try loopback for control'
$h = [Npf4]::PacketOpenAdapter('\Device\NPF_Loopback')
$e = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
L ("loopback(\Device) handle=" + $h + " err=" + $e)
if ($h -ne [IntPtr]::Zero) { [Npf4]::PacketCloseAdapter($h) }
$h = [Npf4]::PacketOpenAdapter('\\.\NPF_Loopback')
$e = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
L ("loopback(\\.\) handle=" + $h + " err=" + $e)
if ($h -ne [IntPtr]::Zero) { [Npf4]::PacketCloseAdapter($h) }

L 'OPEN_TEST_DONE'
