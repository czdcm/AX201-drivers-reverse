$ErrorActionPreference='Continue'
for($i=0; $i -lt 6; $i++){
  $ps = Get-Process -Name winsdksetup,wdksetup -ErrorAction SilentlyContinue
  if(-not $ps){ break }
  foreach($p in $ps){ Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Seconds 2
}
$left = Get-Process -Name winsdksetup,wdksetup -ErrorAction SilentlyContinue
if($left){ "STILL=" + ($left.Id -join ',') } else { "ALL_CLEAR" }
Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10' -ErrorAction SilentlyContinue | Select-Object Name | Format-Table -AutoSize | Out-String
