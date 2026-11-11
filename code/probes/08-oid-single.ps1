$ErrorActionPreference = 'Continue'
$out = 'C:\ProgramData\AX201work\rollback'
$log = Join-Path $out 'oid-single.log'
Set-Content -Path $log -Value 'STARTED' -Encoding utf8
function L($m) { try { Add-Content -Path $log -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding utf8 } catch {} }

$cs = @'
using System;
using System.Runtime.InteropServices;
public static class Npf7 {
  [DllImport("Packet.dll", CharSet=CharSet.Ansi, SetLastError=true)]
  public static extern IntPtr PacketOpenAdapter(string name);
  [DllImport("Packet.dll", SetLastError=true)]
  public static extern void PacketCloseAdapter(IntPtr a);
  [DllImport("Packet.dll", SetLastError=true)]
  public static extern byte PacketRequest(IntPtr a, byte set, IntPtr oid);
}
'@
Add-Type -TypeDefinition $cs -ErrorAction Stop
L 'Add-Type OK'
$dev = '\Device\NPF_{FCB16329-6BE3-429A-B6BF-880F68B827B7}'
$a = [Npf7]::PacketOpenAdapter($dev)
L ("handle=" + $a)
if ($a -eq [IntPtr]::Zero) { L 'OPEN_FAILED'; exit 1 }

foreach ($spec in @(
  @{ oid = 0xFF100015; len = 8;  name = 'FIRMWARE_VERSION' },
  @{ oid = 0xFF100014; len = 64; name = 'DEVICE_INFORMATION' },
  @{ oid = 0xFF40003C; len = 8;  name = 'SV_DRIVER_VERSION' }
)) {
  L ("BEFORE " + $spec.name)
  $b = [Runtime.InteropServices.Marshal]::AllocHGlobal(8 + $spec.len)
  try {
    for ($i=0; $i -lt 8 + $spec.len; $i++) { [Runtime.InteropServices.Marshal]::WriteByte($b, $i, 0) }
    [Runtime.InteropServices.Marshal]::WriteInt32($b, 0, [int]$spec.oid)
    [Runtime.InteropServices.Marshal]::WriteInt32($b, 4, [int]$spec.len)
    L ("CALLING oid=0x{0:X8}" -f $spec.oid)
    $r = [Npf7]::PacketRequest($a, 0, $b)
    $e = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    L ("AFTER " + $spec.name + " ok=" + $r + " err=" + $e)
    $retLen = [Runtime.InteropServices.Marshal]::ReadInt32($b, 4)
    L ("LEN=" + $retLen)
    $hex = ''
    for ($i=0; $i -lt [Math]::Min([Math]::Max($retLen,0),32); $i++) { $hex += ('{0:X2}' -f [Runtime.InteropServices.Marshal]::ReadByte($b, 8+$i)) }
    L ("DATA=" + $hex)
  } catch {
    L ("CAUGHT " + $spec.name + " : " + $_.Exception.GetType().Name + " / " + $_.Exception.Message)
  } finally {
    [Runtime.InteropServices.Marshal]::FreeHGlobal($b)
    L ("FREED " + $spec.name)
  }
}

[Npf7]::PacketCloseAdapter($a)
L 'SINGLE_DONE'
