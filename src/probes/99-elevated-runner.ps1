# AX201 提权执行器 v2：启动一次，之后由收件箱驱动，无需重复 UAC。
# 停止：创建 stop.flag，或结束进程（PID 见 runner.pid），或到时限自动退出。
$ErrorActionPreference = 'Continue'
$root    = 'C:\ProgramData\AX201work'
$inbox   = Join-Path $root 'inbox'
$outDir  = Join-Path $root 'out'
$doneDir = Join-Path $root 'done'
foreach ($d in @($root,$inbox,$outDir,$doneDir)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

$pidFile = Join-Path $root 'runner.pid'
$hbFile  = Join-Path $root 'runner.heartbeat'
$stopFlag= Join-Path $root 'stop.flag'
$runLog  = Join-Path $outDir '_runner.log'

Set-Content -Path $pidFile -Value $PID -Encoding utf8
if (Test-Path $stopFlag) { Remove-Item $stopFlag -Force }

function Log($m) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
  Add-Content -Path $runLog -Value $line -Encoding utf8
  Set-Content -Path $hbFile -Value $line -Encoding utf8
}

Log ("RUNNER_START pid=" + $PID)
$deadline = (Get-Date).AddHours(4)
Log ("deadline=" + $deadline.ToString('HH:mm:ss'))

while ((Get-Date) -lt $deadline) {
  if (Test-Path $stopFlag) { Log 'STOP_FLAG'; break }

  $jobs = @(Get-ChildItem -Path $inbox -Filter '*.ps1' -File -ErrorAction SilentlyContinue | Sort-Object Name)
  foreach ($job in $jobs) {
    $name = $job.BaseName
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add("JOB $name START " + (Get-Date -Format 'HH:mm:ss'))
    Log ("JOB_START " + $name)
    $code = 0
    try {
      $text = Get-Content -Path $job.FullName -Raw -ErrorAction Stop
      $sb = [scriptblock]::Create($text)
      $result = & $sb 2>&1
      foreach ($item in @($result)) { [void]$lines.Add([string]$item) }
      $code = $LASTEXITCODE
      if ($null -eq $code) { $code = 0 }
    } catch {
      [void]$lines.Add("EXCEPTION: " + $_.Exception.GetType().Name + " / " + $_.Exception.Message)
      $code = -1
    }
    [void]$lines.Add("JOB $name END " + (Get-Date -Format 'HH:mm:ss') + " exit=" + $code)
    $logPath = Join-Path $outDir ($name + '.log')
    try { Set-Content -Path $logPath -Value ($lines -join [Environment]::NewLine) -Encoding utf8 }
    catch { Log ("WRITE_LOG_FAIL " + $name + " " + $_.Exception.Message) }
    try { Move-Item -Path $job.FullName -Destination (Join-Path $doneDir ($name + '.ps1')) -Force } catch { Log ("MOVE_FAIL " + $name) }
    Log ("JOB_END " + $name + " exit=" + $code)
  }
  Start-Sleep -Milliseconds 600
}

Log 'RUNNER_EXIT'
Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
