param(
  [string]$InstallRoot = $(Join-Path $env:USERPROFILE ".openclaw\supervisor"),
  [string]$TaskName = "OpenClaw Gateway",
  [switch]$DeleteFiles,
  [switch]$AsJson
)

$ErrorActionPreference = "Stop"

$BackupTaskActionPath = Join-Path $InstallRoot "task-action.backup.json"
$GatewayLauncherPath = Join-Path $env:USERPROFILE ".openclaw\gateway.cmd"
$SchTasksExe = Join-Path $env:SystemRoot "System32\schtasks.exe"

function Invoke-CapturedProcess {
  param(
    [string]$FilePath,
    [string[]]$Arguments = @(),
    [int]$TimeoutSeconds = 15
  )

  $command = Get-Command $FilePath -ErrorAction SilentlyContinue
  if ($null -eq $command) {
    return [pscustomobject]@{
      available = $false
      file = $FilePath
      exit_code = $null
      stdout = ""
      stderr = "Command not found."
    }
  }

  $previousExitCode = $global:LASTEXITCODE
  $global:LASTEXITCODE = 0

  try {
    $lines = @(& $FilePath @Arguments 2>&1 | ForEach-Object { $_.ToString() })
    $exitCode = if ($null -ne $global:LASTEXITCODE) { [int]$global:LASTEXITCODE } else { 0 }
    return [pscustomobject]@{
      available = $true
      file = $command.Source
      exit_code = $exitCode
      stdout = ($lines -join "`n").Trim()
      stderr = ""
    }
  } catch {
    return [pscustomobject]@{
      available = $true
      file = $command.Source
      exit_code = 1
      stdout = ""
      stderr = $_.Exception.Message
    }
  } finally {
    $global:LASTEXITCODE = $previousExitCode
  }
}

$restoreAction = if (Test-Path -LiteralPath $BackupTaskActionPath) {
  Get-Content -LiteralPath $BackupTaskActionPath -Raw | ConvertFrom-Json
} else {
  [pscustomobject]@{
    execute = $GatewayLauncherPath
    arguments = $null
  }
}

$action = New-ScheduledTaskAction -Execute ([string]$restoreAction.execute) -Argument ([string]$restoreAction.arguments)
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
Set-ScheduledTask -TaskName $TaskName -Action $action -Principal $task.Principal | Out-Null

$restartResults = @()
try {
  Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  $restartResults += [pscustomobject]@{ action = "stop"; success = $true }
} catch {
  $restartResults += [pscustomobject]@{ action = "stop"; success = $false; error = $_.Exception.Message }
}

try {
  Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
  $restartResults += [pscustomobject]@{ action = "start"; success = $true }
} catch {
  $restartResults += [pscustomobject]@{ action = "start"; success = $false; error = $_.Exception.Message }
}

if ($DeleteFiles -and (Test-Path -LiteralPath $InstallRoot)) {
  Remove-Item -LiteralPath $InstallRoot -Recurse -Force
}

$result = [pscustomobject]@{
  timestamp = (Get-Date).ToString("s")
  install_root = $InstallRoot
  restored_target = if ($restoreAction.arguments) { "$($restoreAction.execute) $($restoreAction.arguments)" } else { [string]$restoreAction.execute }
  deleted_files = [bool]$DeleteFiles
  restart_results = $restartResults
}

if ($AsJson) {
  $result | ConvertTo-Json -Depth 10
} else {
  $result
}
