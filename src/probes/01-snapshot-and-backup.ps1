$ErrorActionPreference = 'Continue'
$out = 'C:\ProgramData\AX201work\rollback'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$log = Join-Path $out 'snapshot.log'
Set-Content -Path $log -Value 'STARTED' -Encoding utf8
function L($m) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
  Add-Content -Path $log -Value $line -Encoding utf8
}
function Step($name, $block) {
  L ("-- " + $name)
  try {
    $r = & $block 2>&1
    foreach ($x in @($r)) { L ("   " + ([string]$x).TrimEnd()) }
  } catch { L ("   EXCEPTION: " + $_.Exception.Message) }
}
L ("Admin=" + (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))

Step 'SecureBoot'          { (Confirm-SecureBootUEFI).ToString() }
Step 'HVCI-registry'       { $p='HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'; if (Test-Path $p) { (Get-ItemProperty $p).Enabled } else { 'key-absent' } }
Step 'DeviceGuard-CIM'     { $dg = Get-CimInstance Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard; "VBS=$($dg.VirtualizationBasedSecurityStatus) Configured=$($dg.SecurityServicesConfigured -join ',') Running=$($dg.SecurityServicesRunning -join ',')" }
Step 'bcdedit-current'     { bcdedit /enum '{current}' }
Step 'WLAN-device'         { Get-PnpDevice -Class Net | Where-Object { $_.FriendlyName -like '*AX201*' } | Select-Object Status,FriendlyName,InstanceId | Format-List | Out-String }

$inst = (Get-PnpDevice -Class Net | Where-Object { $_.FriendlyName -like '*AX201*' } | Select-Object -First 1).InstanceId
L ("InstanceId=" + $inst)

if ($inst) {
  Step 'Driver-props' {
    Get-PnpDeviceProperty -InstanceId $inst -KeyName 'DEVPKEY_Device_DriverVersion','DEVPKEY_Device_DriverDate','DEVPKEY_Device_DriverInfPath','DEVPKEY_Device_DriverProvider' |
      Select-Object KeyName,Data | Format-Table -AutoSize | Out-String
  }
}

$infName = $null
if ($inst) {
  $p = Get-PnpDeviceProperty -InstanceId $inst -KeyName 'DEVPKEY_Device_DriverInfPath' -ErrorAction SilentlyContinue
  if ($p) { $infName = $p.Data }
}
L ("InfName=" + $infName)

if ($infName) {
  Step 'pnputil-export' {
    $dest = Join-Path $out 'driver-export'
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    pnputil /export-driver $infName $dest
  }
  Step 'copy-inf' {
    $src = Join-Path $env:WINDIR ('INF\' + $infName)
    if (Test-Path $src) { Copy-Item $src $out -Force; 'copied ' + $src } else { 'missing ' + $src }
  }
}

Step 'driverstore-list' {
  Get-ChildItem 'C:\Windows\System32\DriverStore\FileRepository' -Directory -Filter 'netwtw08.inf_amd64_*' | ForEach-Object {
    $_.FullName
    Get-ChildItem $_.FullName -File | ForEach-Object { '  {0}  {1}  {2}' -f $_.Name, $_.Length, (Get-FileHash $_.FullName -Algorithm SHA256).Hash }
  } | Out-String
}

Step 'restore-point' { Checkpoint-Computer -Description 'AX201-pre-driver-mod' -RestorePointType 'MODIFY_SETTINGS'; 'checkpoint-ok' }

Step 'backup-hashes' {
  Get-ChildItem (Join-Path $out 'driver-export') -File -ErrorAction SilentlyContinue |
    ForEach-Object { '{0}  {1}' -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash, $_.Name } | Out-String
}

L 'SNAPSHOT_COMPLETE'
