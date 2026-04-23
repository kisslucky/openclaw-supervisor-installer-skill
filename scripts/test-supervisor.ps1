param(
  [string]$InstallRoot = $(Join-Path $env:USERPROFILE ".openclaw\supervisor"),
  [switch]$AsJson
)

$ErrorActionPreference = "Stop"

$ConfigPath = Join-Path $InstallRoot "config.json"
$SupervisorPath = Join-Path $InstallRoot "openclaw-gateway-supervisor.ps1"
$LauncherPath = Join-Path $InstallRoot "openclaw-gateway-supervisor.cmd"
$TaskName = "OpenClaw Gateway"

function Add-Check {
  param(
    [System.Collections.Generic.List[object]]$Collection,
    [string]$Id,
    [bool]$Passed,
    [string]$Message
  )

  $Collection.Add([pscustomobject]@{
      id = $Id
      passed = $Passed
      message = $Message
    }) | Out-Null
}

$checks = [System.Collections.Generic.List[object]]::new()

Add-Check -Collection $checks -Id "launcher_exists" -Passed (Test-Path -LiteralPath $LauncherPath) -Message "Launcher exists."
Add-Check -Collection $checks -Id "supervisor_exists" -Passed (Test-Path -LiteralPath $SupervisorPath) -Message "Supervisor script exists."
Add-Check -Collection $checks -Id "config_exists" -Passed (Test-Path -LiteralPath $ConfigPath) -Message "Config file exists."

$showConfigOutput = $null
$showConfigPassed = $false
if ((Test-Path -LiteralPath $SupervisorPath) -and (Test-Path -LiteralPath $ConfigPath)) {
  try {
    $showConfigOutput = & $SupervisorPath -ConfigPath $ConfigPath -ShowConfig | ConvertFrom-Json
    $showConfigPassed = $true
  } catch {
    $showConfigOutput = $_.Exception.Message
  }
}

Add-Check -Collection $checks -Id "show_config" -Passed $showConfigPassed -Message "Supervisor can parse config and show its resolved runtime view."

$taskAction = $null
$taskActionPassed = $false
try {
  $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
  $action = $task.Actions | Select-Object -First 1
  if ($null -ne $action) {
    $taskAction = if ($action.Arguments) { "$($action.Execute) $($action.Arguments)" } else { [string]$action.Execute }
    $taskActionPassed = $taskAction -match [Regex]::Escape($LauncherPath)
  }
} catch {
  $taskAction = $_.Exception.Message
}

Add-Check -Collection $checks -Id "task_target" -Passed $taskActionPassed -Message "OpenClaw Gateway task points at the installed launcher."

$listenerPassed = $false
$listenerMessage = "Gateway port listener not detected."
if ($showConfigPassed) {
  try {
    $listener = Get-NetTCPConnection -State Listen -LocalPort $showConfigOutput.gateway.port -ErrorAction Stop | Select-Object -First 1
    if ($null -ne $listener) {
      $listenerPassed = $true
      $listenerMessage = "Gateway listener detected on port $($showConfigOutput.gateway.port)."
    }
  } catch {
  }
}

Add-Check -Collection $checks -Id "listener" -Passed $listenerPassed -Message $listenerMessage

$result = [pscustomobject]@{
  timestamp = (Get-Date).ToString("s")
  install_root = $InstallRoot
  task_name = $TaskName
  task_action = $taskAction
  show_config = $showConfigOutput
  checks = @($checks)
  passed = -not (@($checks | Where-Object { -not $_.passed }).Count)
}

if ($AsJson) {
  $result | ConvertTo-Json -Depth 15
} else {
  $result
}
