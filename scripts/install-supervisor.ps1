param(
  [string]$InstallRoot = $(Join-Path $env:USERPROFILE ".openclaw\supervisor"),
  [string]$TaskName = "OpenClaw Gateway",
  [string]$GatewayLauncherPath = $(Join-Path $env:USERPROFILE ".openclaw\gateway.cmd"),
  [int]$GatewayPort = 18789,
  [switch]$NoRestart,
  [switch]$Force,
  [switch]$AsJson
)

$ErrorActionPreference = "Stop"

$SkillRoot = Split-Path -Parent $PSScriptRoot
$AssetsRoot = Join-Path $SkillRoot "assets"
$BackupTaskActionPath = Join-Path $InstallRoot "task-action.backup.json"
$InstalledConfigPath = Join-Path $InstallRoot "config.json"
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

function ConvertTo-PlainData {
  param($Value)

  if ($null -eq $Value) {
    return $null
  }

  if ($Value -is [string] -or $Value -is [ValueType]) {
    return $Value
  }

  if ($Value -is [System.Collections.IDictionary]) {
    $result = @{}
    foreach ($key in $Value.Keys) {
      $result[$key] = ConvertTo-PlainData -Value $Value[$key]
    }
    return $result
  }

  if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
    $items = @()
    foreach ($item in $Value) {
      $items += ,(ConvertTo-PlainData -Value $item)
    }
    return $items
  }

  if ($Value.PSObject -and $Value.PSObject.Properties.Count -gt 0) {
    $result = @{}
    foreach ($property in $Value.PSObject.Properties) {
      $result[$property.Name] = ConvertTo-PlainData -Value $property.Value
    }
    return $result
  }

  return $Value
}

function Merge-Hashtable {
  param(
    [hashtable]$Base,
    [hashtable]$Overlay
  )

  $merged = @{}
  foreach ($key in $Base.Keys) {
    $merged[$key] = $Base[$key]
  }

  foreach ($key in $Overlay.Keys) {
    if ($merged.ContainsKey($key) -and $merged[$key] -is [hashtable] -and $Overlay[$key] -is [hashtable]) {
      $merged[$key] = Merge-Hashtable -Base $merged[$key] -Overlay $Overlay[$key]
    } else {
      $merged[$key] = $Overlay[$key]
    }
  }

  return $merged
}

function Get-ExistingTaskAction {
  try {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    $action = $task.Actions | Select-Object -First 1
    return [pscustomobject]@{
      Exists = $true
      Execute = if ($null -ne $action) { [string]$action.Execute } else { $null }
      Arguments = if ($null -ne $action) { [string]$action.Arguments } else { $null }
      Combined = if ($null -ne $action) {
        if ($action.Arguments) { "$($action.Execute) $($action.Arguments)" } else { [string]$action.Execute }
      } else {
        $null
      }
    }
  } catch {
    return [pscustomobject]@{
      Exists = $false
      Execute = $null
      Arguments = $null
      Combined = $null
    }
  }
}

New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null

$assetFiles = @(
  "openclaw-gateway-supervisor.cmd",
  "openclaw-gateway-supervisor.ps1"
)

foreach ($assetFile in $assetFiles) {
  Copy-Item -LiteralPath (Join-Path $AssetsRoot $assetFile) -Destination (Join-Path $InstallRoot $assetFile) -Force
}

$sampleConfig = ConvertTo-PlainData -Value (Get-Content -LiteralPath (Join-Path $AssetsRoot "config.json") -Raw | ConvertFrom-Json)
$existingConfig = if ((Test-Path -LiteralPath $InstalledConfigPath) -and -not $Force) { ConvertTo-PlainData -Value (Get-Content -LiteralPath $InstalledConfigPath -Raw | ConvertFrom-Json) } else { @{} }
$config = Merge-Hashtable -Base $sampleConfig -Overlay $existingConfig

$config.gateway.launcherPath = $GatewayLauncherPath
$config.gateway.taskName = $TaskName
$config.gateway.port = $GatewayPort

$config | ConvertTo-Json -Depth 20 | Set-Content -Path $InstalledConfigPath -Encoding UTF8

$launcherPath = Join-Path $InstallRoot "openclaw-gateway-supervisor.cmd"
$existingTaskAction = Get-ExistingTaskAction

if (-not (Test-Path -LiteralPath $BackupTaskActionPath)) {
  $backup = if ($existingTaskAction.Exists -and $existingTaskAction.Combined -notmatch "openclaw-gateway-supervisor\.cmd") {
    [ordered]@{
      execute = $existingTaskAction.Execute
      arguments = $existingTaskAction.Arguments
    }
  } else {
    [ordered]@{
      execute = $GatewayLauncherPath
      arguments = $null
    }
  }

  $backup | ConvertTo-Json -Depth 6 | Set-Content -Path $BackupTaskActionPath -Encoding UTF8
}

if ($existingTaskAction.Exists) {
  $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
  $action = New-ScheduledTaskAction -Execute $launcherPath
  Set-ScheduledTask -TaskName $TaskName -Action $action -Principal $task.Principal | Out-Null
} else {
  $action = New-ScheduledTaskAction -Execute $launcherPath
  $trigger = New-ScheduledTaskTrigger -AtLogOn
  $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel LeastPrivilege
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal | Out-Null
}

$restartResults = @()
if (-not $NoRestart) {
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
}

$result = [pscustomobject]@{
  timestamp = (Get-Date).ToString("s")
  install_root = $InstallRoot
  launcher_path = $launcherPath
  config_path = $InstalledConfigPath
  task_name = $TaskName
  gateway_launcher_path = $GatewayLauncherPath
  restarted = -not $NoRestart
  restart_results = $restartResults
}

if ($AsJson) {
  $result | ConvertTo-Json -Depth 10
} else {
  $result
}
