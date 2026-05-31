param(
  [Parameter(Mandatory = $true)] [string] $ServiceName,
  [Parameter(Mandatory = $true)] [string] $TaskName,
  [Parameter(Mandatory = $true)] [string] $HealthUrl
)

$ErrorActionPreference = "Stop"

$BaseDir = "C:\hanomi\$ServiceName"
$CurrentPath = Join-Path $BaseDir "current"
$PreviousFile = Join-Path $BaseDir "previous.txt"

function Write-Log {
  param([string] $Message)
  Write-Host "[$(Get-Date -Format o)] [$ServiceName] $Message"
}

function Test-Health {
  param([string] $Url)
  for ($i = 1; $i -le 12; $i++) {
    try {
      $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 3
      if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
        Write-Log "health check passed"
        return $true
      }
    }
    catch {}
    Start-Sleep -Seconds 5
  }
  return $false
}

if (-not (Test-Path $PreviousFile)) {
  throw "previous release file missing: $PreviousFile"
}

$PreviousRelease = (Get-Content $PreviousFile -Raw).Trim()
if ([string]::IsNullOrWhiteSpace($PreviousRelease) -or -not (Test-Path $PreviousRelease)) {
  throw "previous release is invalid: $PreviousRelease"
}

if (Test-Path $CurrentPath) {
  Remove-Item $CurrentPath -Force -Recurse
}

New-Item -ItemType Junction -Path $CurrentPath -Target $PreviousRelease | Out-Null
schtasks.exe /End /TN $TaskName 2>$null | Out-Null
Start-Sleep -Seconds 2
schtasks.exe /Run /TN $TaskName | Out-Null

if (-not (Test-Health -Url $HealthUrl)) {
  throw "health check failed after rollback"
}

Write-Log "rollback completed to $PreviousRelease"
