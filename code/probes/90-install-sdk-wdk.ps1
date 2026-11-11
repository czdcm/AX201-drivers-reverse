$ErrorActionPreference = 'Continue'
$log = 'C:\ProgramData\AX201work\rollback\sdk4.log'
Set-Content $log 'START' -Encoding utf8
function L($m) { Add-Content $log ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding utf8 }

L '-- kill setups and runner'
Get-Process -Name winsdksetup,wdksetup -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue; L ("killed setup " + $_.Id) }
$rp = 'C:\ProgramData\AX201work\runner.pid'
if (Test-Path $rp) {
  $pid_ = Get-Content $rp
  $p = Get-Process -Id $pid_ -ErrorAction SilentlyContinue
  if ($p) { Stop-Process -Id $pid_ -Force -ErrorAction SilentlyContinue; L ("killed runner " + $pid_) }
}
Start-Sleep -Seconds 3

L '-- clear inbox'
Get-ChildItem 'C:\ProgramData\AX201work\inbox' -File -ErrorAction SilentlyContinue | ForEach-Object {
  L ("removing " + $_.Name)
  Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
}

L '-- winhttp proxy'
$r = netsh winhttp set proxy proxy-server="127.0.0.1:7890" bypass-list="<local>" 2>&1
foreach ($x in @($r)) { L ("   " + ([string]$x).TrimEnd()) }
$q = netsh winhttp show proxy 2>&1
foreach ($x in @($q)) { L ("   " + ([string]$x).TrimEnd()) }

$env:HTTP_PROXY = 'http://127.0.0.1:7890'
$env:HTTPS_PROXY = 'http://127.0.0.1:7890'

$sdk = Join-Path $env:USERPROFILE 'Downloads\winsdksetup.exe'
$wdk = Join-Path $env:USERPROFILE 'Downloads\wdksetup.exe'
L ("sdk_exists=" + (Test-Path $sdk) + " wdk_exists=" + (Test-Path $wdk))

L '-- SDK install (this downloads several hundred MB)'
try {
  $p = Start-Process -FilePath $sdk -ArgumentList '/features', '+', '/q', '/norestart' -Wait -PassThru -ErrorAction Stop
  L ("sdk_exit=" + $p.ExitCode)
} catch { L ("sdk_EXCEPTION " + $_.Exception.Message) }

L ("include_exists=" + (Test-Path 'C:\Program Files (x86)\Windows Kits\10\Include'))
if (Test-Path 'C:\Program Files (x86)\Windows Kits\10\Include') {
  L ("versions=" + ((Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\Include' -Directory | Select-Object -ExpandProperty Name) -join ','))
}

L '-- WDK install'
try {
  $p2 = Start-Process -FilePath $wdk -ArgumentList '/features', '+', '/q', '/norestart' -Wait -PassThru -ErrorAction Stop
  L ("wdk_exit=" + $p2.ExitCode)
} catch { L ("wdk_EXCEPTION " + $_.Exception.Message) }

L '-- verify'
$ndis = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\Include\*\km\ndis.h' -ErrorAction SilentlyContinue | Select-Object -First 2 -ExpandProperty FullName
if ($ndis) { foreach ($n in $ndis) { L ("ndis.h=" + $n) } } else { L 'ndis.h NOT FOUND' }
$lib = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\Lib\*\km\x64\ndis.lib' -ErrorAction SilentlyContinue | Select-Object -First 2 -ExpandProperty FullName
if ($lib) { foreach ($l in $lib) { L ("ndis.lib=" + $l) } } else { L 'ndis.lib NOT FOUND' }
$wdf = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\Include\*\km\wdf' -Directory -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
if ($wdf) { L ("wdflib_dir=" + $wdf) }

L 'FINISHED'
