# Removes headset-autoswitch: stops it, removes the scheduled task (or the
# Startup shortcut) and deletes %LOCALAPPDATA%\HeadsetAutoswitch.
# Your audio devices stay as they are.

param([switch]$KeepSettings)

$ErrorActionPreference = 'Continue'
$target = Join-Path $env:LOCALAPPDATA 'HeadsetAutoswitch'
$taskName = 'HeadsetAutoswitch'
$startupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'HeadsetAutoswitch.lnk'

if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
  Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
  Write-Host "Removed the scheduled task '$taskName'." -ForegroundColor Green
}
if (Test-Path $startupLink) {
  Remove-Item $startupLink -Force
  Write-Host 'Removed the Startup shortcut.' -ForegroundColor Green
}

Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -like '*headset-autoswitch.ps1*' -and $_.ProcessId -ne $PID } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

if (Test-Path $target) {
  if ($KeepSettings) {
    Get-ChildItem $target | Where-Object { $_.Name -ne 'settings.json' } | Remove-Item -Force -Recurse
    Write-Host "Removed the files in $target, kept settings.json." -ForegroundColor Green
  } else {
    Remove-Item $target -Recurse -Force
    Write-Host "Deleted $target." -ForegroundColor Green
  }
}

Write-Host 'headset-autoswitch is uninstalled.' -ForegroundColor Cyan
