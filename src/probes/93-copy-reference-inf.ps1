$ErrorActionPreference='Continue'
$out='C:\ProgramData\AX201work\ref'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$dir = Get-ChildItem 'C:\Windows\System32\DriverStore\FileRepository' -Directory -Filter 'npcap.inf_amd64_*' -ErrorAction SilentlyContinue | Select-Object -First 1
if($dir){
  "dir=" + $dir.FullName
  Get-ChildItem $dir.FullName -File | Select-Object Name,Length | Format-Table -AutoSize | Out-String
  $inf = Get-ChildItem $dir.FullName -Filter '*.inf' -File | Select-Object -First 1
  if($inf){ Copy-Item $inf.FullName (Join-Path $out $inf.Name) -Force; "copied " + $inf.Name }
} else { 'npcap dir not found' }
