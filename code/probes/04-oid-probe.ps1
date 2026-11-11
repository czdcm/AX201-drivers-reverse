$ErrorActionPreference = 'Continue'
$out = 'C:\ProgramData\AX201work\rollback'
$log = Join-Path $out 'oid-probe.log'
Set-Content -Path $log -Value 'STARTED' -Encoding utf8
function L($m) { Add-Content -Path $log -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding utf8 }

$cs = @'
using System;
using System.Runtime.InteropServices;
public static class Npf {
  [DllImport("Packet.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern IntPtr PacketOpenAdapter(string name);
  [DllImport("Packet.dll", SetLastError=true)]
  public static extern void PacketCloseAdapter(IntPtr a);
  [DllImport("Packet.dll", SetLastError=true)]
  public static extern byte PacketRequest(IntPtr a, byte set, IntPtr oid);
}
'@
try { Add-Type -TypeDefinition $cs -ErrorAction Stop; L 'Add-Type OK' } catch { L ("Add-Type FAIL: " + $_.Exception.Message); L 'PROBE_ABORT'; exit 1 }

function Probe($adapter, [uint32]$oid, [int]$len, [byte]$set, [string]$label) {
  $buf = [Runtime.InteropServices.Marshal]::AllocHGlobal(8 + $len)
  try {
    for ($i=0; $i -lt 8 + $len; $i++) { [Runtime.InteropServices.Marshal]::WriteByte($buf, $i, 0) }
    [Runtime.InteropServices.Marshal]::WriteInt32($buf, 0, [int]$oid)
    [Runtime.InteropServices.Marshal]::WriteInt32($buf, 4, $len)
    $r = [Npf]::PacketRequest($adapter, $set, $buf)
    $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    $retLen = [Runtime.InteropServices.Marshal]::ReadInt32($buf, 4)
    $hex = ''
    $n = [Math]::Min([Math]::Max($retLen,0), $len)
    for ($i=0; $i -lt $n; $i++) { $hex += ('{0:X2}' -f [Runtime.InteropServices.Marshal]::ReadByte($buf, 8+$i)) }
    L ("RESULT label={0} oid=0x{1:X8} set={2} ok={3} lastError={4} outLen={5} data={6}" -f $label,$oid,$set,$r,$err,$retLen,$hex)
  } catch { L ("EXCEPTION " + $label + " : " + $_.Exception.Message) }
  finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($buf) }
}

$dev = '\\.\NPF_{FCB16329-6BE3-429A-B6BF-880F68B827B7}'
L ("device=" + $dev)
$a = [Npf]::PacketOpenAdapter($dev)
L ("adapter handle=" + $a)
if ($a -eq [IntPtr]::Zero) { L 'OPEN_FAILED'; L 'PROBE_ABORT'; exit 1 }

L '-- sanity: OID_802_3_PERMANENT_ADDRESS query'
Probe $a 0x01010102 8 0 'permanent_address'

L '-- target: OID_SV_EXECUTE_SNIFFER_CMD query'
Probe $a 0x0D01011A 64 0 'sv_execute_sniffer_query'

L '-- target: OID_SV_EXECUTE_SNIFFER_CMD set (len 64, zeroed)'
Probe $a 0x0D01011A 64 1 'sv_execute_sniffer_set'

[Npf]::PacketCloseAdapter($a)
L 'PROBE_DONE'
