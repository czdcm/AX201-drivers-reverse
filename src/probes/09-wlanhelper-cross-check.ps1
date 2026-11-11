$h='C:\Windows\System32\Npcap\WlanHelper.exe'
$out='C:\ProgramData\AX201work\rollback\wlanhelper.log'
Set-Content $out 'START' -Encoding utf8
foreach($args in @(@('WLAN'), @('WLAN','mode'), @('WLAN','channel'))){
  Add-Content $out ('--- ' + ($args -join ' ')) -Encoding utf8
  $r = & $h @args 2>&1
  Add-Content $out (($r | Out-String)) -Encoding utf8
  Add-Content $out ('exit=' + $LASTEXITCODE) -Encoding utf8
}
Add-Content $out 'DONE' -Encoding utf8
