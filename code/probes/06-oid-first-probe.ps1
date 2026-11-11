$ErrorActionPreference = 'Continue'
$out = 'C:\ProgramData\AX201work\rollback'
$log = Join-Path $out 'oid-final.log'
Set-Content -Path $log -Value 'STARTED' -Encoding utf8
function L($m) { Add-Content -Path $log -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding utf8 }

$cs = @'
using System;
using System.Runtime.InteropServices;
public static class Npf5 {
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
$a = [Npf5]::PacketOpenAdapter($dev)
L ("handle=" + $a)
if ($a -eq [IntPtr]::Zero) { L 'OPEN_FAILED'; L 'PROBE_ABORT'; exit 1 }

function Probe($adapter, [uint32]$oid, [int]$len, [byte]$set, [string]$label, [byte[]]$seed) {
  $b = [Runtime.InteropServices.Marshal]::AllocHGlobal(8 + $len)
  try {
    for ($i=0; $i -lt 8 + $len; $i++) { [Runtime.InteropServices.Marshal]::WriteByte($b, $i, 0) }
    [Runtime.InteropServices.Marshal]::WriteInt32($b, 0, [int]$oid)
    [Runtime.InteropServices.Marshal]::WriteInt32($b, 4, $len)
    if ($seed) { for ($i=0; $i -lt [Math]::Min($seed.Length,$len); $i++) { [Runtime.InteropServices.Marshal]::WriteByte($b, 8+$i, $seed[$i]) } }
    $r = [Npf5]::PacketRequest($adapter, $set, $b)
    $e = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    $retLen = [Runtime.InteropServices.Marshal]::ReadInt32($b, 4)
    $hex = ''
    $n = [Math]::Min([Math]::Max($retLen,0), $len)
    if ($n -gt 48) { $n = 48 }
    for ($i=0; $i -lt $n; $i++) { $hex += ('{0:X2}' -f [Runtime.InteropServices.Marshal]::ReadByte($b, 8+$i)) }
    L ("RESULT {0} oid=0x{1:X8} set={2} ok={3} err={4} outLen={5} data={6}" -f $label,$oid,$set,$r,$e,$retLen,$hex)
    return $r
  } catch { L ("EXCEPTION " + $label + " : " + $_.Exception.Message) ; return -1 }
  finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($b) }
}

L '--- 1. sanity: OID_802_3_PERMANENT_ADDRESS ---'
[void](Probe $a 0x01010102 8 0 'permanent_address' $null)

L '--- 2. OID_SV_EXECUTE_SNIFFER_CMD (query) ---'
[void](Probe $a 0x0D01011A 64 0 'sniffer_query' $null)

L '--- 3. OID_GEN_VENDOR_DESCRIPTION (query, known-good control) ---'
[void](Probe $a 0x0001010C 64 0 'vendor_description' $null)

[Npf5]::PacketCloseAdapter($a)

L '--- post: adapter status ---'
Get-NetAdapter -Name 'WLAN' | Select-Object Name,Status,MacAddress | Format-Table -AutoSize | Out-String | ForEach-Object { L $_ }

L 'PROBE_DONE'
