$ErrorActionPreference = 'Continue'
$log = 'C:\ProgramData\AX201work\rollback\stop-install.log'
Set-Content $log 'STOP' -Encoding utf8
function L($m) { Add-Content $log ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding utf8 }

L '-- kill installers'
Get-Process -Name winsdksetup, wdksetup -ErrorAction SilentlyContinue | ForEach-Object {
  Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
  L ("killed " + $_.ProcessName + " " + $_.Id)
}
Start-Sleep -Seconds 2

L '-- kill install script host (powershell running install-kits)'
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*install-kits.ps1*' } | ForEach-Object {
  Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
  L ("killed powershell " + $_.ProcessId)
}
Start-Sleep -Seconds 1

L '-- reset winhttp proxy to direct (restore original)'
$r = netsh winhttp reset proxy 2>&1
foreach ($x in @($r)) { L ("   " + ([string]$x).TrimEnd()) }

L '-- final state'
L ("kits_include=" + (Test-Path 'C:\Program Files (x86)\Windows Kits\10\Include'))
if (Test-Path 'C:\Program Files (x86)\Windows Kits\10') {
  $mb = [math]::Round(((Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10' -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum) / 1MB, 0)
  L ("kits10_MB=" + $mb)
}
$left = Get-Process -Name winsdksetup, wdksetup -ErrorAction SilentlyContinue
if ($left) { L ("still_running=" + ($left.Id -join ',')) } else { L 'no_installer_running' }

L '-- wifi state'
Get-NetAdapter -Name 'WLAN' -ErrorAction SilentlyContinue | Select-Object Name, Status | Format-Table -AutoSize | Out-String | ForEach-Object { L $_ }

L 'STOPPED'
