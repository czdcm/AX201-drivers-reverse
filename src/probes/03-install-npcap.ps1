$ErrorActionPreference = 'Continue'
$out = 'C:\ProgramData\AX201work\rollback'
$log = Join-Path $out 'npcap-install.log'
Set-Content -Path $log -Value 'STARTED' -Encoding utf8
function L($m) { Add-Content -Path $log -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding utf8 }

$exe = 'C:\ProgramData\AX201work\downloads\npcap-1.90.exe'
L ("installer exists=" + (Test-Path $exe))

L '-- running installer /S'
try {
  $p = Start-Process -FilePath $exe -ArgumentList '/S' -Wait -PassThru -ErrorAction Stop
  L ("installer exit=" + $p.ExitCode)
} catch { L ("installer EXCEPTION: " + $_.Exception.Message) }

Start-Sleep -Seconds 3

L '-- service check'
$svc = Get-Service -Name 'npcap' -ErrorAction SilentlyContinue
if ($svc) { L ("npcap service=" + $svc.Status + " start=" + $svc.StartType) } else { L 'npcap service ABSENT' }

L '-- files'
foreach ($f in @('C:\Windows\System32\Npcap\Packet.dll','C:\Windows\System32\Npcap\wpcap.dll','C:\Windows\System32\Npcap\npcap.sys','C:\Windows\System32\drivers\npcap.sys')) {
  L ("{0} {1}" -f (Test-Path $f), $f)
}

L '-- driverstore npcap'
Get-ChildItem 'C:\Windows\System32\DriverStore\FileRepository' -Directory -Filter 'npcap*' -ErrorAction SilentlyContinue | ForEach-Object { L ("   " + $_.Name) }

L '-- net adapters after'
Get-NetAdapter -ErrorAction SilentlyContinue | Select-Object Name,InterfaceDescription,Status | Format-Table -AutoSize | Out-String | ForEach-Object { L $_ }

L 'INSTALL_STEP_DONE'
