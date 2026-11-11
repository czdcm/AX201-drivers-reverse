$ErrorActionPreference = 'Continue'
$out = 'C:\ProgramData\AX201work\rollback'
$log = Join-Path $out 'oid-matrix.log'
Set-Content -Path $log -Value 'STARTED' -Encoding utf8
function L($m) { Add-Content -Path $log -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding utf8 }

$cs = @'
using System;
using System.Runtime.InteropServices;
public static class Npf6 {
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
$a = [Npf6]::PacketOpenAdapter($dev)
L ("handle=" + $a)
if ($a -eq [IntPtr]::Zero) { L 'OPEN_FAILED'; exit 1 }

function Probe($adapter, [uint32]$oid, [int]$len, [byte]$set, [string]$label) {
  $b = [Runtime.InteropServices.Marshal]::AllocHGlobal(8 + $len)
  try {
    for ($i=0; $i -lt 8 + $len; $i++) { [Runtime.InteropServices.Marshal]::WriteByte($b, $i, 0) }
    [Runtime.InteropServices.Marshal]::WriteInt32($b, 0, [int]$oid)
    [Runtime.InteropServices.Marshal]::WriteInt32($b, 4, $len)
    $r = [Npf6]::PacketRequest($adapter, $set, $b)
    $e = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    $dl = [Convert]::ToString($e, 16).PadLeft(8,'0')
    $retLen = [Runtime.InteropServices.Marshal]::ReadInt32($b, 4)
    $hex = ''
    $n = [Math]::Min([Math]::Max($retLen,0), [Math]::Min($len,32))
    for ($i=0; $i -lt $n; $i++) { $hex += ('{0:X2}' -f [Runtime.InteropServices.Marshal]::ReadByte($b, 8+$i)) }
    $tag = if ($hex -match '[0-9A-F]{2}') { $ascii = -join ($hex -split '(..)' | Where-Object {$_} | ForEach-Object { [char][Convert]::ToByte($_,16) }) ; $ascii } else { '' }
    L ("{0,-26} oid=0x{1:X8} set={2} ok={3} status=0x{4} outLen={5} data={6}" -f $label,$oid,$set,$r,$dl,$retLen,$hex)
  } catch { L ("EXCEPTION " + $label + " : " + $_.Exception.Message) }
  finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($b) }
}

L '--- standard OIDs (control) ---'
Probe $a 0x01010102 8  0 'OID_802_3_PERMANENT_ADDR'
Probe $a 0x0001010C 64 0 'OID_GEN_VENDOR_DESC'
Probe $a 0x00010103 64 0 'OID_GEN_VENDOR_DRIVER_VER'

L '--- iwlwifi-style vendor OIDs (driver claims support) ---'
Probe $a 0xFF100015 8  0 'OID_WIFI_FIRMWARE_VERSION'
Probe $a 0xFF100014 64 0 'OID_WIFI_DEVICE_INFORMATION'
Probe $a 0xFF40003C 8  0 'OID_SV_DRIVER_VERSION'

L '--- sniffer ---'
Probe $a 0x0D01011A 64 0 'OID_SV_EXECUTE_SNIFFER'

[Npf6]::PacketCloseAdapter($a)
L 'MATRIX_DONE'
