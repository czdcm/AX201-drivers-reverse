$ErrorActionPreference = 'Continue'
$out = 'C:\ProgramData\AX201work\rollback'
$log = Join-Path $out 'oid-probe2.log'
Set-Content -Path $log -Value 'STARTED' -Encoding utf8
function L($m) { Add-Content -Path $log -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding utf8 }

$cs = @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class Npf2 {
  [DllImport("Packet.dll", CharSet=CharSet.Ansi, SetLastError=true)]
  public static extern byte PacketGetAdapterNames(StringBuilder names, ref uint size);
  [DllImport("Packet.dll", CharSet=CharSet.Ansi, SetLastError=true)]
  public static extern IntPtr PacketOpenAdapter(string name);
  [DllImport("Packet.dll", SetLastError=true)]
  public static extern void PacketCloseAdapter(IntPtr a);
  [DllImport("Packet.dll", SetLastError=true)]
  public static extern byte PacketRequest(IntPtr a, byte set, IntPtr oid);
}
'@
try { Add-Type -TypeDefinition $cs -ErrorAction Stop; L 'Add-Type OK' } catch { L ("Add-Type FAIL: " + $_.Exception.Message); L 'PROBE_ABORT'; exit 1 }

$sb = New-Object System.Text.StringBuilder 8192
$sz = [uint32]8192
$ok = [Npf2]::PacketGetAdapterNames($sb, [ref]$sz)
$err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
L ("GetAdapterNames ok=$ok lastError=$err size=$sz")
$raw = $sb.ToString()
$parts = $raw -split "`0"
$names = @($parts | Where-Object { $_ -match '^\\\\\.\\NPF_' -or $_ -match 'NPF_' })
L "-- device names seen:"
foreach ($n in $names) { L ("   [" + $n + "]") }
L ("raw_len=" + $raw.Length)

$dev = '\\.\NPF_{FCB16329-6BE3-429A-B6BF-880F68B827B7}'
L ("trying device=" + $dev)
$a = [Npf2]::PacketOpenAdapter($dev)
$err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
L ("adapter handle=" + $a + " lastError=" + $err)
if ($a -eq [IntPtr]::Zero) {
  L 'OPEN_FAILED_FIRST'
  if ($names.Count -gt 0) {
    foreach ($n in $names) {
      $try = $n
      if (-not $try.StartsWith('\\.\')) { $try = '\\.\' + $try }
      $h = [Npf2]::PacketOpenAdapter($try)
      L ("   try [" + $try + "] handle=" + $h)
      if ($h -ne [IntPtr]::Zero) { [Npf2]::PacketCloseAdapter($h) }
    }
  }
  L 'PROBE_ABORT'
  exit 1
}

function Probe($adapter, [uint32]$oid, [int]$len, [byte]$set, [string]$label) {
  $buf = [Runtime.InteropServices.Marshal]::AllocHGlobal(8 + $len)
  try {
    for ($i=0; $i -lt 8 + $len; $i++) { [Runtime.InteropServices.Marshal]::WriteByte($buf, $i, 0) }
    [Runtime.InteropServices.Marshal]::WriteInt32($buf, 0, [int]$oid)
    [Runtime.InteropServices.Marshal]::WriteInt32($buf, 4, $len)
    $r = [Npf2]::PacketRequest($adapter, $set, $buf)
    $e = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    $retLen = [Runtime.InteropServices.Marshal]::ReadInt32($buf, 4)
    $hex = ''
    $n = [Math]::Min([Math]::Max($retLen,0), $len)
    for ($i=0; $i -lt $n; $i++) { $hex += ('{0:X2}' -f [Runtime.InteropServices.Marshal]::ReadByte($buf, 8+$i)) }
    L ("RESULT {0} oid=0x{1:X8} set={2} ok={3} err={4} outLen={5} data={6}" -f $label,$oid,$set,$r,$e,$retLen,$hex)
  } catch { L ("EXCEPTION " + $label + " : " + $_.Exception.Message) }
  finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($buf) }
}

L '-- sanity'
Probe $a 0x01010102 8 0 'permanent_address'
L '-- sniffer OID query'
Probe $a 0x0D01011A 64 0 'sniffer_query'
L '-- sniffer OID set'
Probe $a 0x0D01011A 64 1 'sniffer_set'

[Npf2]::PacketCloseAdapter($a)
L 'PROBE_DONE'
