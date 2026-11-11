$ErrorActionPreference = 'Continue'
$out = 'C:\ProgramData\AX201work\rollback'
$log = Join-Path $out 'backup.log'
Set-Content -Path $log -Value 'STARTED' -Encoding utf8
function L($m) { Add-Content -Path $log -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding utf8 }

$src = 'C:\Windows\System32\DriverStore\FileRepository\netwtw08.inf_amd64_7d404936069a9b78'
$dst = Join-Path $out 'driver-package'
L ("source=" + $src)
if (-not (Test-Path $src)) { L 'SOURCE MISSING'; exit 1 }

if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
New-Item -ItemType Directory -Force -Path $dst | Out-Null

$files = Get-ChildItem $src -File
L ("file count=" + $files.Count)
foreach ($f in $files) {
  try {
    Copy-Item $f.FullName (Join-Path $dst $f.Name) -Force
    $h1 = (Get-FileHash $f.FullName -Algorithm SHA256).Hash
    $h2 = (Get-FileHash (Join-Path $dst $f.Name) -Algorithm SHA256).Hash
    $ok = if ($h1 -eq $h2) { 'OK' } else { 'MISMATCH' }
    L ("{0} {1} {2} {3}" -f $ok, $f.Name, $f.Length, $h1)
  } catch { L ("COPY-FAIL " + $f.Name + " : " + $_.Exception.Message) }
}

$inf = 'C:\Windows\INF\oem73.inf'
if (Test-Path $inf) {
  Copy-Item $inf (Join-Path $dst 'oem73.inf') -Force
  L ("oem73.inf copied " + (Get-FileHash (Join-Path $dst 'oem73.inf') -Algorithm SHA256).Hash)
}

$export = Join-Path $out 'pnputil-export'
if (-not (Test-Path $export)) { New-Item -ItemType Directory -Force -Path $export | Out-Null }
L '-- pnputil export retry'
$r = pnputil /export-driver oem73.inf $export 2>&1
foreach ($x in @($r)) { L ("   " + ([string]$x).TrimEnd()) }

L 'BACKUP_COMPLETE'
