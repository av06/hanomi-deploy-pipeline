param(
  [Parameter(Mandatory = $true)] [string] $ServiceName,
  [Parameter(Mandatory = $true)] [string] $ReleaseId,
  [Parameter(Mandatory = $true)] [string] $ArtifactPath,
  [Parameter(Mandatory = $true)] [string] $TaskName,
  [Parameter(Mandatory = $true)] [string] $HealthUrl,
  [switch] $WhatIf
)

$ErrorActionPreference = "Stop"

$BaseDir = "C:\hanomi\$ServiceName"
$ReleasesDir = Join-Path $BaseDir "releases"
$NewReleaseDir = Join-Path $ReleasesDir $ReleaseId
$CurrentPath = Join-Path $BaseDir "current"
$PreviousFile = Join-Path $BaseDir "previous.txt"

function Write-Log {
  param([string] $Message)
  Write-Host "[$(Get-Date -Format o)] [$ServiceName] $Message"
}

function Test-Health {
  param(
    [string] $Url,
    [int] $Attempts = 18,
    [int] $SleepSeconds = 5
  )

  for ($i = 1; $i -le $Attempts; $i++) {
    try {
      $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 3
      if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
        Write-Log "health check passed on attempt $i"
        return $true
      }
    }
    catch {
      Write-Log "health check attempt $i/$Attempts failed: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds $SleepSeconds
  }

  return $false
}

function Set-CurrentRelease {
  param([string] $Target)

  if (Test-Path $CurrentPath) {
    Remove-Item $CurrentPath -Force -Recurse
  }

  New-Item -ItemType Junction -Path $CurrentPath -Target $Target | Out-Null
}

function Restart-WorkerTask {
  schtasks.exe /End /TN $TaskName 2>$null | Out-Null
  Start-Sleep -Seconds 2
  schtasks.exe /Run /TN $TaskName | Out-Null
}

function Invoke-Rollback {
  Write-Log "attempting rollback"

  if (-not (Test-Path $PreviousFile)) {
    Write-Log "no previous release file found; manual intervention required"
    return $false
  }

  $PreviousRelease = Get-Content $PreviousFile -Raw
  $PreviousRelease = $PreviousRelease.Trim()

  if ([string]::IsNullOrWhiteSpace($PreviousRelease) -or -not (Test-Path $PreviousRelease)) {
    Write-Log "previous release is invalid: $PreviousRelease"
    return $false
  }

  Set-CurrentRelease -Target $PreviousRelease
  Restart-WorkerTask
  [void](Test-Health -Url $HealthUrl -Attempts 12 -SleepSeconds 5)
  Write-Log "rolled back to $PreviousRelease"
  return $true
}

if ($WhatIf) {
  Write-Log "WhatIf mode: script parsed successfully"
  exit 0
}

Write-Log "starting deployment release=$ReleaseId artifact=$ArtifactPath"

if (-not (Test-Path $ArtifactPath)) {
  throw "artifact not found: $ArtifactPath"
}

New-Item -ItemType Directory -Force -Path $ReleasesDir | Out-Null

if (Test-Path $NewReleaseDir) {
  Remove-Item $NewReleaseDir -Force -Recurse
}
New-Item -ItemType Directory -Force -Path $NewReleaseDir | Out-Null

if (Test-Path $CurrentPath) {
  $CurrentTarget = (Get-Item $CurrentPath).Target
  if ($CurrentTarget -is [array]) { $CurrentTarget = $CurrentTarget[0] }
  Set-Content -Path $PreviousFile -Value $CurrentTarget
  Write-Log "previous release: $CurrentTarget"
}
else {
  Set-Content -Path $PreviousFile -Value ""
  Write-Log "no previous release found"
}

Expand-Archive -Path $ArtifactPath -DestinationPath $NewReleaseDir -Force
Set-CurrentRelease -Target $NewReleaseDir
Write-Log "current switched to $NewReleaseDir"

Restart-WorkerTask
Write-Log "scheduled task restarted: $TaskName"

if (-not (Test-Health -Url $HealthUrl)) {
  Write-Log "health check failed after deployment"
  [void](Invoke-Rollback)
  exit 1
}

$PreviousRelease = ""
if (Test-Path $PreviousFile) {
  $PreviousRelease = (Get-Content $PreviousFile -Raw).Trim()
}

Get-ChildItem $ReleasesDir -Directory |
  Sort-Object LastWriteTime -Descending |
  Select-Object -Skip 5 |
  Where-Object {
    $_.FullName -ne $NewReleaseDir -and
    ([string]::IsNullOrWhiteSpace($PreviousRelease) -or $_.FullName -ne $PreviousRelease)
  } |
  Remove-Item -Force -Recurse

Write-Log "deployment completed successfully"
