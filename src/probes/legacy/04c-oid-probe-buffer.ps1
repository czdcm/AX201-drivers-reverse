$ErrorActionPreference = 'Continue'
$out = 'C:\ProgramData\AX201work\rollback'
$log = Join-Path $out 'oid-probe3.log'
Set-Content -Path $log -Value 'STARTED' -Encoding utf8
function L($m) { Add-Content -Path $log -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding utf8 }

$cs = @'
using System;
using System.Runtime.InteropServices;
public static class Npf3 {
  [DllImport("Packet.dll", SetLastError=true)]
  public static extern byte PacketGetAdapterNames(IntPtr names, ref uint size);
  [DllImport("Packet.dll", CharSet=CharSet.Ansi, SetLastError=true)]
  public static extern IntPtr PacketOpenAdapter(string name);
  [DllImport("Packet.dll", SetLastError=true)]
  public static extern void PacketCloseAdapter(IntPtr a);
  [DllImport("Packet.dll", SetLastError=true)]
  public static extern byte PacketRequest(IntPtr a, byte set, IntPtr oid);
}
'@
try { Add-Type -TypeDefinition $cs -ErrorAction Stop; L 'Add-Type OK' } catch { L ("Add-Type FAIL: " + $_.Exception.Message); exit 1 }

$cap = 65536
$buf = [Runtime.InteropServices.Marshal]::AllocHGlobal($cap)
$sz = [uint32]$cap
$ok = [Npf3]::PacketGetAdapterNames($buf, [ref]$sz)
$err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
L ("GetAdapterNames ok=$ok err=$err size=$sz")

$bytes = New-Object byte[] $cap
[Runtime.InteropServices.Marshal]::Copy($buf, $bytes, 0, $cap)
[Runtime.InteropServices.Marshal]::FreeHGlobal($buf)

$names = @()
$cur = New-Object System.Text.StringBuilder
for ($i = 0; $i -lt $sz; $i++) {
  $b = $bytes[$i]
  if ($b -eq 0) {
    if ($cur.Length -eq 0) { if ($i -gt 0) { break } }
    else { $names += $cur.ToString(); [void]$cur.Clear() }
  } else { [void]$cur.Append([char]$b) }
}
L ("names_count=" + $names.Count)
foreach ($n in $names) { L ("   [" + $n + "]") }

$target = $names | Where-Object { $_ -match 'FCB16329' }
if (-not $target) { $target = $names | Where-Object { $_ -match 'NPF_' -and $_ -notmatch 'Loopback' } | Select-Object -First 1 }
L ("target=" + $target)

if (-not $target) { L 'NO_TARGET'; L 'PROBE_ABORT'; exit 1 }
$dev = $target
if (-not $dev.StartsWith('\\.\')) { $dev = '\\.\' + ($dev -replace '^\\Device\\','') }
L ("open=" + $dev)
$a = [Npf3]::PacketOpenAdapter($dev)
$err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
L ("handle=" + $a + " err=" + $err)
if ($a -eq [IntPtr]::Zero) { L 'OPEN_FAILED'; L 'PROBE_ABORT'; exit 1 }

function Probe($adapter, [uint32]$oid, [int]$len, [byte]$set, [string]$label) {
  $b = [Runtime.InteropServices.Marshal]::AllocHGlobal(8 + $len)
  try {
    for ($i=0; $i -lt 8 + $len; $i++) { [Runtime.InteropServices.Marshal]::WriteByte($b, $i, 0) }
    [Runtime.InteropServices.Marshal]::WriteInt32($b, 0, [int]$oid)
    [Runtime.InteropServices.Marshal]::WriteInt32($b, 4, $len)
    $r = [Npf3]::PacketRequest($adapter, $set, $b)
    $e = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    $retLen = [Runtime.InteropServices.Marshal]::ReadInt32($b, 4)
    $hex = ''
    $n = [Math]::Min([Math]::Max($retLen,0), $len)
    for ($i=0; $i -lt $n; $i++) { $hex += ('{0:X2}' -f [Runtime.InteropServices.Marshal]::ReadByte($b, 8+$i)) }
    L ("RESULT {0} oid=0x{1:X8} set={2} ok={3} err={4} outLen={5} data={6}" -f $label,$oid,$set,$r,$e,$retLen,$hex)
  } catch { L ("EXCEPTION " + $label + " : " + $_.Exception.Message) }
  finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($b) }
}

L '-- sanity: OID_802_3_PERMANENT_ADDRESS'
Probe $a 0x01010102 8 0 'permanent_address'
L '-- sniffer OID query'
Probe $a 0x0D01011A 64 0 'sniffer_query'
L '-- sniffer OID set'
Probe $a 0x0D01011A 64 1 'sniffer_set'

[Npf3]::PacketCloseAdapter($a)
L 'PROBE_DONE'
