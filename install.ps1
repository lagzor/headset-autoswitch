# Installs headset-autoswitch for the current user:
#   - copies headset-autoswitch.ps1 to %LOCALAPPDATA%\HeadsetAutoswitch
#   - creates settings.json there (an existing one is kept)
#   - registers the scheduled task "HeadsetAutoswitch", which starts the script
#     hidden at logon and checks every 15 minutes that it is still running
#   - starts it right away
# Run it again at any time to update to a newer version.

$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path -Parent $PSCommandPath) 'headset-autoswitch.ps1'
$target = Join-Path $env:LOCALAPPDATA 'HeadsetAutoswitch'
$script = Join-Path $target 'headset-autoswitch.ps1'
$taskName = 'HeadsetAutoswitch'
$startupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'HeadsetAutoswitch.lnk'

if (-not (Test-Path $source)) {
  Write-Host "headset-autoswitch.ps1 was not found next to install.ps1. Unzip the whole download first." -ForegroundColor Red
  return
}

# Stop a copy that is already running, so the new version takes over.
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -like '*headset-autoswitch.ps1*' -and $_.ProcessId -ne $PID } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

New-Item -ItemType Directory -Path $target -Force | Out-Null
Copy-Item -Path $source -Destination $script -Force
Unblock-File -Path $script -ErrorAction SilentlyContinue
Write-Host "Copied to $target" -ForegroundColor Green

$argument = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$script`""
$registered = $false
try {
  $action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument $argument
  $triggers = @(
    (New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"),
    (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 15))
  )
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
  $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers -Settings $settings -Principal $principal -Force | Out-Null
  $registered = $true
  if (Test-Path $startupLink) { Remove-Item $startupLink -Force }
  Start-ScheduledTask -TaskName $taskName
  Write-Host "Scheduled task '$taskName' registered and started." -ForegroundColor Green
} catch {
  Write-Host "Could not register the scheduled task ($($_.Exception.Message))." -ForegroundColor Yellow
}

# Without permission to create tasks: start it from the Startup folder instead.
if (-not $registered) {
  $shell = New-Object -ComObject WScript.Shell
  $link = $shell.CreateShortcut($startupLink)
  $link.TargetPath = Join-Path $env:WINDIR 'System32\conhost.exe'
  $link.Arguments = $argument
  $link.WorkingDirectory = $target
  $link.WindowStyle = 7
  $link.Save()
  Start-Process -FilePath 'conhost.exe' -ArgumentList $argument -WindowStyle Hidden
  Write-Host "Added to the Startup folder instead, and started." -ForegroundColor Green
}

Write-Host ''
Write-Host 'Done. Turn your headset on and off: audio should follow within a few seconds.' -ForegroundColor Cyan
Write-Host "Settings: $(Join-Path $target 'settings.json')"
Write-Host "Log:      $(Join-Path $target 'log.txt')"
Write-Host ''
Write-Host 'If it does not switch, check the log, or run:'
Write-Host "  powershell -ExecutionPolicy Bypass -File `"$script`" -List"
Write-Host "  powershell -ExecutionPolicy Bypass -File `"$script`" -Test"
