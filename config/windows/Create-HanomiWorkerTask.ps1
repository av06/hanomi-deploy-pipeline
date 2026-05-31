# Run once on the Windows worker VM as Administrator.
# This assumes Python is installed and available on PATH.

$TaskName = "HanomiWorker"
$ScriptPath = "C:\hanomi\worker\current\worker.py"
$Action = New-ScheduledTaskAction -Execute "python.exe" -Argument $ScriptPath
$Trigger = New-ScheduledTaskTrigger -AtStartup
$Settings = New-ScheduledTaskSettingsSet -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask `
  -TaskName $TaskName `
  -Action $Action `
  -Trigger $Trigger `
  -Settings $Settings `
  -Description "Hanomi Python worker" `
  -RunLevel Highest `
  -Force
