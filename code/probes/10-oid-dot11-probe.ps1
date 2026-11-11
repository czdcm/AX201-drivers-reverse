$ErrorActionPreference = 'Continue'
$out = 'C:\ProgramData\AX201work\rollback'
$log = Join-Path $out 'oid-dot11.log'
Set-Content -Path $log -Value 'STARTED' -Encoding utf8
function L($m) { Add-Content -Path $log -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding utf8 }

$cs = @'
using System;
using System.Runtime.InteropServices;
public static class Npf8 {
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
$a = [Npf8]::PacketOpenAdapter($dev)
L ("handle=" + $a)
if ($a -eq [IntPtr]::Zero) { L 'OPEN_FAILED'; exit 1 }

function Probe($adapter, [uint32]$oid, [int]$len, [byte]$set, [string]$label) {
  $b = [Runtime.InteropServices.Marshal]::AllocHGlobal(8 + $len)
  try {
    for ($i=0; $i -lt 8 + $len; $i++) { [Runtime.InteropServices.Marshal]::WriteByte($b, $i, 0) }
    [Runtime.InteropServices.Marshal]::WriteInt32($b, 0, [int]$oid)
    [Runtime.InteropServices.Marshal]::WriteInt32($b, 4, $len)
    $r = [Npf8]::PacketRequest($adapter, $set, $b)
    $e = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    $st = $e
    if ($st -lt 0) { $st = $st + 4294967296 }
    $hex = ('0x{0:X8}' -f $st)
    $retLen = [Runtime.InteropServices.Marshal]::ReadInt32($b, 4)
    $data = ''
    for ($i=0; $i -lt [Math]::Min([Math]::Max($retLen,0),48); $i++) { $data += ('{0:X2}' -f [Runtime.InteropServices.Marshal]::ReadByte($b, 8+$i)) }
    L ("{0,-24} oid=0x{1:X8} set={2} ok={3} status={4} outLen={5} data={6}" -f $label,$oid,$set,$r,$hex,$retLen,$data)
  } catch { L ("CAUGHT " + $label + " : " + $_.Exception.Message) }
  finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($b) }
}

L '--- control: the OID WlanHelper uses successfully ---'
Probe $a 0x0D01011B 8 0 'DOT11_CURRENT_OPERATION_MODE'

L '--- target channel: NIC specific extension ---'
Probe $a 0x0D01035C 32 0 'DOT11_NIC_SPECIFIC_EXT query'
Probe $a 0x0D01035C 32 1 'DOT11_NIC_SPECIFIC_EXT set'

L '--- sniffer raw (already known invalid) ---'
Probe $a 0x0D01011A 32 0 'SV_EXECUTE_SNIFFER raw'

[Npf8]::PacketCloseAdapter($a)
L 'DOT11_DONE'
