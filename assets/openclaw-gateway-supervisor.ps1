param(
  [string]$ConfigPath = $(Join-Path $PSScriptRoot "config.json"),
  [switch]$ShowConfig
)

$ErrorActionPreference = "Stop"

function Get-ConfigValue {
  param(
    $Value,
    $Default
  )

  if ($null -eq $Value) {
    return $Default
  }

  if ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) {
    return $Default
  }

  return $Value
}

function Get-ConfigArray {
  param(
    $Value,
    [object[]]$Default = @()
  )

  if ($null -eq $Value) {
    return @($Default)
  }

  return @($Value)
}

function Expand-PathToken {
  param([string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $Value
  }

  return [Environment]::ExpandEnvironmentVariables($Value)
}

function Get-JsonObject {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }

  return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
  throw "Supervisor config not found: $ConfigPath"
}

$Config = Get-JsonObject -Path $ConfigPath
if ($null -eq $Config) {
  throw "Supervisor config could not be parsed: $ConfigPath"
}

$GatewayCmd = Expand-PathToken (Get-ConfigValue -Value $Config.gateway.launcherPath -Default (Join-Path $env:USERPROFILE ".openclaw\gateway.cmd"))
$GatewayTaskName = [string](Get-ConfigValue -Value $Config.gateway.taskName -Default "OpenClaw Gateway")
$GatewayPort = [int](Get-ConfigValue -Value $Config.gateway.port -Default 18789)

$OpenClawConfigPath = Expand-PathToken (Get-ConfigValue -Value $Config.paths.openclawConfigPath -Default (Join-Path $env:USERPROFILE ".openclaw\openclaw.json"))
$AgentModelsPath = Expand-PathToken (Get-ConfigValue -Value $Config.paths.agentModelsPath -Default (Join-Path $env:USERPROFILE ".openclaw\agents\main\agent\models.json"))
$LogDir = Expand-PathToken (Get-ConfigValue -Value $Config.paths.logDir -Default (Join-Path $env:LOCALAPPDATA "Temp\openclaw"))
$StatusFile = Expand-PathToken (Get-ConfigValue -Value $Config.paths.statusFile -Default (Join-Path $LogDir "gateway-supervisor.status.txt"))
$LogFile = Expand-PathToken (Get-ConfigValue -Value $Config.paths.supervisorLogFile -Default (Join-Path $LogDir "gateway-supervisor.log"))
$ModelBackupFile = Expand-PathToken (Get-ConfigValue -Value $Config.paths.modelBackupFile -Default (Join-Path $LogDir "gateway-model-routing.backup.json"))

$IdleCheckIntervalSeconds = [int](Get-ConfigValue -Value $Config.activity.idleCheckIntervalSeconds -Default 15)
$ActiveWorkGraceSeconds = [int](Get-ConfigValue -Value $Config.activity.activeWorkGraceSeconds -Default 180)
$ActivityPatterns = Get-ConfigArray -Value $Config.activity.patterns -Default @("agent/embedded", "model-fallback/decision", "embedded_run_", "lane task")
$ReplacementCandidates = Get-ConfigArray -Value $Config.models.replacementCandidates -Default @(
  "bailian/qwen3.6-plus",
  "bailian/kimi-k2.5",
  "moonshot/deepseek-chat",
  "bailian/glm-5",
  "bailian/MiniMax-M2.5"
)

$NotificationTitle = [string](Get-ConfigValue -Value $Config.notifications.title -Default "OpenClaw Network Change")
$UseMsgExe = [bool](Get-ConfigValue -Value $Config.notifications.useMsgExe -Default $true)
$MsgTimeoutSeconds = [int](Get-ConfigValue -Value $Config.notifications.msgTimeoutSeconds -Default 8)

$ProxyRegistrySubPath = [string](Get-ConfigValue -Value $Config.proxy.registryPath -Default "Software\Microsoft\Windows\CurrentVersion\Internet Settings")
$ProxyWatchValues = Get-ConfigArray -Value $Config.proxy.watchValues -Default @("ProxyEnable", "ProxyServer", "ProxyOverride", "AutoConfigURL")

$TaskKillExe = Join-Path $env:SystemRoot "System32\taskkill.exe"
$MsgExe = Join-Path $env:SystemRoot "System32\msg.exe"

foreach ($path in @($LogDir, (Split-Path -Parent $StatusFile), (Split-Path -Parent $LogFile), (Split-Path -Parent $ModelBackupFile))) {
  if (-not [string]::IsNullOrWhiteSpace($path)) {
    New-Item -ItemType Directory -Force -Path $path | Out-Null
  }
}

function Write-Log {
  param([string]$Message)

  $line = "[{0}] [gateway-supervisor] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
  Add-Content -Path $LogFile -Value $line
  Write-Host $line
}

function Write-Status {
  param([string]$Message)

  $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
  Set-Content -Path $StatusFile -Value $line
}

function Send-Hint {
  param([string]$Message)

  Write-Status -Message $Message

  if (-not $UseMsgExe -or -not (Test-Path -LiteralPath $MsgExe)) {
    return
  }

  try {
    & $MsgExe $env:USERNAME /TIME:$MsgTimeoutSeconds $Message | Out-Null
  } catch {
    Write-Log ("Hint delivery failed: {0}" -f $_.Exception.Message)
  }
}

function Clear-PendingEvents {
  param([string[]]$SourceIdentifiers)

  foreach ($sourceIdentifier in $SourceIdentifiers) {
    if ($sourceIdentifier) {
      Get-Event -SourceIdentifier $sourceIdentifier -ErrorAction SilentlyContinue | Remove-Event
    }
  }
}

function Normalize-ProxyUrl {
  param(
    [string]$Value,
    [string]$Kind = "http"
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $null
  }

  $trimmed = $Value.Trim()
  if ($trimmed -match "^[a-zA-Z][a-zA-Z0-9+.-]*://") {
    return $trimmed
  }

  if ($Kind -eq "socks") {
    return "socks5://$trimmed"
  }

  return "http://$trimmed"
}

function Test-ProxyEndpoint {
  param([string]$ProxyUrl)

  if ([string]::IsNullOrWhiteSpace($ProxyUrl)) {
    return $false
  }

  try {
    $uri = [Uri]$ProxyUrl
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
      $asyncResult = $client.BeginConnect($uri.Host, $uri.Port, $null, $null)
      if (-not $asyncResult.AsyncWaitHandle.WaitOne(1500, $false)) {
        return $false
      }

      $client.EndConnect($asyncResult)
      return $true
    } finally {
      $client.Dispose()
    }
  } catch {
    return $false
  }
}

function Test-HostReachable {
  param(
    [string]$HostName,
    [int]$Port = 443,
    [int]$TimeoutMs = 2500
  )

  if ([string]::IsNullOrWhiteSpace($HostName)) {
    return $false
  }

  try {
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
      $asyncResult = $client.BeginConnect($HostName, $Port, $null, $null)
      if (-not $asyncResult.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
        return $false
      }

      $client.EndConnect($asyncResult)
      return $true
    } finally {
      $client.Dispose()
    }
  } catch {
    return $false
  }
}

function Get-NoProxyValue {
  param([string]$ProxyOverride)

  $entries = @("127.0.0.1", "localhost")

  if (-not [string]::IsNullOrWhiteSpace($ProxyOverride)) {
    foreach ($rawEntry in ($ProxyOverride -split ";")) {
      $entry = $rawEntry.Trim()
      if (-not $entry) {
        continue
      }

      if ($entry -eq "<local>") {
        $entries += "*.local"
        continue
      }

      $entries += $entry
    }
  }

  return (($entries | Where-Object { $_ } | Select-Object -Unique) -join ",")
}

function Get-CurrentUserSid {
  return [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Escape-WqlKeyPath {
  param([string]$Value)

  return $Value.Replace("\", "\\")
}

function Get-ProxyRegistryPsPath {
  return "HKCU:\{0}" -f $ProxyRegistrySubPath
}

function Get-ProxyLaunchConfig {
  $settings = Get-ItemProperty (Get-ProxyRegistryPsPath)
  $proxyEnable = [int](Get-ConfigValue -Value $settings.ProxyEnable -Default 0)
  $proxyServer = [string](Get-ConfigValue -Value $settings.ProxyServer -Default "")
  $proxyOverride = [string](Get-ConfigValue -Value $settings.ProxyOverride -Default "")
  $autoConfigUrl = [string](Get-ConfigValue -Value $settings.AutoConfigURL -Default "")

  $resolved = [ordered]@{
    HTTP_PROXY = $null
    HTTPS_PROXY = $null
    ALL_PROXY = $null
    NO_PROXY = Get-NoProxyValue -ProxyOverride $proxyOverride
    NODE_USE_ENV_PROXY = "1"
  }

  if ($proxyEnable -eq 1 -and -not [string]::IsNullOrWhiteSpace($proxyServer)) {
    $proxyMap = @{}
    foreach ($segment in ($proxyServer -split ";")) {
      $part = $segment.Trim()
      if (-not $part) {
        continue
      }

      if ($part -match "^\s*([^=]+)=(.+?)\s*$") {
        $proxyMap[$matches[1].Trim().ToLowerInvariant()] = $matches[2].Trim()
      } else {
        $proxyMap["default"] = $part
      }
    }

    $defaultProxy = Normalize-ProxyUrl -Value (Get-ConfigValue -Value $proxyMap["default"] -Default $null) -Kind "http"
    $httpRaw = Get-ConfigValue -Value $proxyMap["http"] -Default (Get-ConfigValue -Value $proxyMap["https"] -Default (Get-ConfigValue -Value $proxyMap["default"] -Default $null))
    $httpsRaw = Get-ConfigValue -Value $proxyMap["https"] -Default (Get-ConfigValue -Value $proxyMap["http"] -Default (Get-ConfigValue -Value $proxyMap["default"] -Default $null))
    $allRaw = Get-ConfigValue -Value $proxyMap["all"] -Default (Get-ConfigValue -Value $proxyMap["socks"] -Default (Get-ConfigValue -Value $proxyMap["https"] -Default (Get-ConfigValue -Value $proxyMap["http"] -Default (Get-ConfigValue -Value $proxyMap["default"] -Default $null))))

    $candidateMap = [ordered]@{
      HTTP_PROXY = Get-ConfigValue -Value (Normalize-ProxyUrl -Value $httpRaw -Kind "http") -Default $defaultProxy
      HTTPS_PROXY = Get-ConfigValue -Value (Normalize-ProxyUrl -Value $httpsRaw -Kind "http") -Default $defaultProxy
      ALL_PROXY = Get-ConfigValue -Value (Normalize-ProxyUrl -Value $allRaw -Kind $(if ($proxyMap.ContainsKey("socks")) { "socks" } else { "http" })) -Default $defaultProxy
    }

    foreach ($pair in $candidateMap.GetEnumerator()) {
      if (Test-ProxyEndpoint -ProxyUrl $pair.Value) {
        $resolved[$pair.Key] = $pair.Value
      }
    }
  }

  $summary =
    if ($resolved.HTTP_PROXY -or $resolved.HTTPS_PROXY -or $resolved.ALL_PROXY) {
      "proxy active"
    } elseif ($proxyEnable -eq 1 -and $proxyServer) {
      "proxy configured but unavailable"
    } elseif ($autoConfigUrl) {
      "auto-config url present; using direct"
    } else {
      "direct"
    }

  return [pscustomobject]@{
    Fingerprint = ([ordered]@{
        ProxyEnable = $proxyEnable
        ProxyServer = $proxyServer
        ProxyOverride = $proxyOverride
        AutoConfigURL = $autoConfigUrl
        EffectiveEnv = $resolved
      } | ConvertTo-Json -Compress -Depth 8)
    Summary = $summary
    Environment = $resolved
  }
}

function Get-ConfiguredModelsState {
  $config = Get-JsonObject -Path $OpenClawConfigPath
  if ($null -eq $config) {
    return $null
  }

  $primary = $config.agents.defaults.model.primary
  $fallbacks = @()
  if ($null -ne $config.agents.defaults.model.fallbacks) {
    $fallbacks = @($config.agents.defaults.model.fallbacks)
  }

  $knownModels = @()
  $knownModels += $primary
  $knownModels += $fallbacks

  if ($null -ne $config.agents.defaults.models) {
    foreach ($property in $config.agents.defaults.models.PSObject.Properties) {
      $knownModels += $property.Name
    }
  }

  return [pscustomobject]@{
    Config = $config
    Primary = $primary
    Fallbacks = $fallbacks
    KnownModels = @($knownModels | Where-Object { $_ } | Select-Object -Unique)
  }
}

function Get-ProviderBaseUrlMap {
  $providerMap = @{}

  foreach ($path in @($OpenClawConfigPath, $AgentModelsPath)) {
    $json = Get-JsonObject -Path $path
    if ($null -eq $json -or $null -eq $json.providers) {
      continue
    }

    foreach ($property in $json.providers.PSObject.Properties) {
      if ($null -eq $property.Value) {
        continue
      }

      if (-not $providerMap.ContainsKey($property.Name) -and $property.Value.baseUrl) {
        $providerMap[$property.Name] = [string]$property.Value.baseUrl
      }
    }
  }

  return $providerMap
}

function Resolve-ProviderBaseUrl {
  param(
    [string]$Provider,
    [hashtable]$ProviderBaseUrlMap
  )

  if ($ProviderBaseUrlMap.ContainsKey($Provider)) {
    return $ProviderBaseUrlMap[$Provider]
  }

  switch ($Provider) {
    "openai-codex" { return "https://chatgpt.com/backend-api/v1" }
    "codex" { return "https://chatgpt.com/backend-api/v1" }
    "openai" { return "https://api.openai.com/v1" }
    "gemini" { return "https://generativelanguage.googleapis.com/v1beta/openai/v1" }
    "bailian" { return "https://coding.dashscope.aliyuncs.com/v1" }
    "moonshot" { return "https://api.deepseek.com/v1" }
    default { return $null }
  }
}

function Test-ModelSupportedForRoute {
  param(
    [string]$ModelId,
    [hashtable]$ProviderBaseUrlMap,
    [hashtable]$Environment
  )

  if ([string]::IsNullOrWhiteSpace($ModelId)) {
    return $false
  }

  $provider = ($ModelId -split "/", 2)[0]
  $proxyUrl = [string](Get-ConfigValue -Value $Environment["HTTPS_PROXY"] -Default $Environment["HTTP_PROXY"])
  if (-not [string]::IsNullOrWhiteSpace($proxyUrl)) {
    return Test-ProxyEndpoint -ProxyUrl $proxyUrl
  }

  $baseUrl = Resolve-ProviderBaseUrl -Provider $provider -ProviderBaseUrlMap $ProviderBaseUrlMap
  if ([string]::IsNullOrWhiteSpace($baseUrl)) {
    return $true
  }

  try {
    $uri = [Uri]$baseUrl
    return Test-HostReachable -HostName $uri.Host -Port $(if ($uri.Port -gt 0) { $uri.Port } else { 443 })
  } catch {
    return $true
  }
}

function Save-ModelRoutingBackup {
  param(
    [string]$Primary,
    [string[]]$Fallbacks
  )

  ([ordered]@{
      timestamp = (Get-Date).ToString("s")
      primary = $Primary
      fallbacks = @($Fallbacks)
    } | ConvertTo-Json -Depth 6) | Set-Content -Path $ModelBackupFile -Encoding UTF8
}

function Get-ReplacementModelCandidates {
  param([object]$State)

  return @(
    @($State.Primary) +
    @($State.Fallbacks) +
    @($ReplacementCandidates) +
    @($State.KnownModels)
  ) | Where-Object { $_ } | Select-Object -Unique
}

function Get-CurrentOpenClawLogPath {
  $candidate = Join-Path $LogDir ("openclaw-" + (Get-Date -Format "yyyy-MM-dd") + ".log")
  if (Test-Path -LiteralPath $candidate) {
    return $candidate
  }

  $latest = Get-ChildItem -LiteralPath $LogDir -Filter "openclaw-*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($null -ne $latest) {
    return $latest.FullName
  }

  return $null
}

function Get-RecentModelActivityAgeSeconds {
  $logPath = Get-CurrentOpenClawLogPath
  if ([string]::IsNullOrWhiteSpace($logPath) -or -not (Test-Path -LiteralPath $logPath)) {
    return $null
  }

  $lines = @(Get-Content -LiteralPath $logPath -Tail 500 -ErrorAction SilentlyContinue)
  if ($lines.Count -eq 0) {
    return $null
  }

  for ($i = $lines.Count - 1; $i -ge 0; $i--) {
    $line = [string]$lines[$i]
    foreach ($pattern in $ActivityPatterns) {
      if ($line -match [Regex]::Escape($pattern)) {
        if ($line -match '"time":"([^"]+)"') {
          try {
            $timestamp = [DateTimeOffset]::Parse($matches[1])
            $age = [int][Math]::Floor(([DateTimeOffset]::Now - $timestamp).TotalSeconds)
            return [Math]::Max($age, 0)
          } catch {
            return $null
          }
        }
      }
    }
  }

  return $null
}

function Get-GatewayBusyState {
  $recentActivityAgeSeconds = Get-RecentModelActivityAgeSeconds
  return [pscustomobject]@{
    Busy = ($null -ne $recentActivityAgeSeconds -and $recentActivityAgeSeconds -le $ActiveWorkGraceSeconds)
    RecentActivityAgeSeconds = $recentActivityAgeSeconds
  }
}

function Show-RouteChangePrompt {
  param(
    [string]$RouteSummary,
    [pscustomobject]$BusyState
  )

  try {
    Add-Type -AssemblyName PresentationFramework

    $state = Get-ConfiguredModelsState
    $primary = if ($null -ne $state -and $state.Primary) { [string]$state.Primary } else { "unknown" }
    $fallbacks = if ($null -ne $state -and $state.Fallbacks -and @($state.Fallbacks).Count -gt 0) { (@($state.Fallbacks) -join ", ") } else { "none" }
    $activityLine = if ($null -ne $BusyState -and $BusyState.Busy) { "Recent model activity: about {0}s ago." -f $BusyState.RecentActivityAgeSeconds } else { "Recent model activity: no active model run detected." }

    if ($null -ne $BusyState -and $BusyState.Busy) {
      $message = @(
        "OpenClaw detected a network route change while a model task appears to still be active.",
        "",
        "Current route: $RouteSummary",
        "Current primary model: $primary",
        "Current fallback models: $fallbacks",
        $activityLine,
        "",
        "Yes:",
        "Keep the current model routing and wait for the next idle window before reconnecting.",
        "",
        "No:",
        "At the next idle window, adapt unsupported models to models the new network can still reach.",
        "",
        "Cancel:",
        "Ignore this route change for now."
      ) -join "`n"

      $result = [System.Windows.MessageBox]::Show($message, $NotificationTitle, [System.Windows.MessageBoxButton]::YesNoCancel, [System.Windows.MessageBoxImage]::Warning)
      if ($result -eq [System.Windows.MessageBoxResult]::Yes) { return "keep_later" }
      if ($result -eq [System.Windows.MessageBoxResult]::No) { return "adapt_later" }
      return "ignore"
    }

    $message = @(
      "OpenClaw detected a network route change.",
      "",
      "Current route: $RouteSummary",
      "Current primary model: $primary",
      "Current fallback models: $fallbacks",
      $activityLine,
      "",
      "Yes:",
      "Keep the current model routing and reconnect now.",
      "",
      "No:",
      "Adapt unsupported models to reachable ones, then reconnect now.",
      "",
      "Cancel:",
      "Ignore this route change for now."
    ) -join "`n"

    $result = [System.Windows.MessageBox]::Show($message, $NotificationTitle, [System.Windows.MessageBoxButton]::YesNoCancel, [System.Windows.MessageBoxImage]::Information)
    if ($result -eq [System.Windows.MessageBoxResult]::Yes) { return "keep_now" }
    if ($result -eq [System.Windows.MessageBoxResult]::No) { return "adapt_now" }
    return "ignore"
  } catch {
    Write-Log ("Route change prompt failed: {0}" -f $_.Exception.Message)
    return "keep_now"
  }
}

function Apply-ModelRoutingAdaptation {
  param([hashtable]$Environment)

  $state = Get-ConfiguredModelsState
  if ($null -eq $state) {
    return [pscustomobject]@{
      Changed = $false
      Reason = "config unavailable"
    }
  }

  $providerBaseUrlMap = Get-ProviderBaseUrlMap
  $supportedMap = @{}
  foreach ($model in $state.KnownModels) {
    $supportedMap[$model] = Test-ModelSupportedForRoute -ModelId $model -ProviderBaseUrlMap $providerBaseUrlMap -Environment $Environment
  }

  $candidates = Get-ReplacementModelCandidates -State $state
  $supportedCandidates = @($candidates | Where-Object { $supportedMap.ContainsKey($_) -and $supportedMap[$_] })
  if ($supportedCandidates.Count -eq 0) {
    return [pscustomobject]@{
      Changed = $false
      Reason = "no supported replacement model found"
    }
  }

  $newPrimary = if ($supportedMap.ContainsKey($state.Primary) -and $supportedMap[$state.Primary]) { $state.Primary } else { $supportedCandidates[0] }
  $newFallbacks = @($state.Fallbacks | Where-Object { $_ -ne $newPrimary -and $supportedMap.ContainsKey($_) -and $supportedMap[$_] } | Select-Object -Unique)
  if ($newFallbacks.Count -eq 0) {
    $newFallbacks = @($supportedCandidates | Where-Object { $_ -ne $newPrimary } | Select-Object -First 1)
  }

  $fallbackChanged = ((@($state.Fallbacks) -join "|") -ne (@($newFallbacks) -join "|"))
  if ($state.Primary -eq $newPrimary -and -not $fallbackChanged) {
    return [pscustomobject]@{
      Changed = $false
      Reason = "current routing already supported"
      Primary = $newPrimary
      Fallbacks = $newFallbacks
    }
  }

  Save-ModelRoutingBackup -Primary $state.Primary -Fallbacks $state.Fallbacks

  $state.Config.agents.defaults.model.primary = $newPrimary
  $state.Config.agents.defaults.model.fallbacks = @($newFallbacks)
  $state.Config | ConvertTo-Json -Depth 100 | Set-Content -Path $OpenClawConfigPath -Encoding UTF8

  return [pscustomobject]@{
    Changed = $true
    Reason = "model routing adapted to current network"
    Primary = $newPrimary
    Fallbacks = $newFallbacks
  }
}

function Start-GatewayProcess {
  param([hashtable]$ProxyEnvironment)

  if (-not (Test-Path -LiteralPath $GatewayCmd)) {
    throw "Gateway launcher not found: $GatewayCmd"
  }

  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = Join-Path $env:SystemRoot "System32\cmd.exe"
  $startInfo.Arguments = "/d /c `"$GatewayCmd`""
  $startInfo.UseShellExecute = $false
  $startInfo.WorkingDirectory = Split-Path -Parent $GatewayCmd

  foreach ($entry in $ProxyEnvironment.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace([string]$entry.Value)) {
      [void]$startInfo.Environment.Remove($entry.Key)
    } else {
      $startInfo.Environment[$entry.Key] = [string]$entry.Value
    }
  }

  return [System.Diagnostics.Process]::Start($startInfo)
}

function Stop-GatewayProcess {
  param([System.Diagnostics.Process]$Process)

  if ($null -eq $Process) {
    return
  }

  try {
    if (-not $Process.HasExited) {
      Write-Log ("Stopping gateway process tree pid={0}" -f $Process.Id)
      & $TaskKillExe /PID $Process.Id /T /F | Out-Null
      Start-Sleep -Seconds 2
    }
  } catch {
    Write-Log ("Stop request failed: {0}" -f $_.Exception.Message)
  }
}

function Register-ProxyChangeWatchers {
  $sid = Get-CurrentUserSid
  $keyPath = Escape-WqlKeyPath -Value ($sid + "\" + $ProxyRegistrySubPath)
  $watchers = @()

  foreach ($valueName in $ProxyWatchValues) {
    $sourceIdentifier = "OpenClawProxyChange.$valueName"
    $query = "SELECT * FROM RegistryValueChangeEvent WHERE Hive='HKEY_USERS' AND KeyPath='$keyPath' AND ValueName='$valueName'"
    $watchers += Register-WmiEvent -Namespace "root\default" -Query $query -SourceIdentifier $sourceIdentifier
  }

  return $watchers
}

function Register-GatewayExitWatcher {
  param([System.Diagnostics.Process]$Process)

  if ($null -eq $Process) {
    return $null
  }

  $Process.EnableRaisingEvents = $true
  return Register-ObjectEvent -InputObject $Process -EventName Exited -SourceIdentifier "OpenClawGatewayProcessExited"
}

function Start-OrRestartGateway {
  param(
    [pscustomobject]$DesiredConfig,
    [string]$Reason,
    [switch]$Restart
  )

  Write-Log ("{0} gateway: {1}" -f $(if ($Restart) { "Restarting" } else { "Launching" }), $Reason)

  if ($null -ne $script:GatewayExitWatcher) {
    Unregister-Event -SourceIdentifier "OpenClawGatewayProcessExited" -ErrorAction SilentlyContinue
    $script:GatewayExitWatcher = $null
    Clear-PendingEvents -SourceIdentifiers @("OpenClawGatewayProcessExited")
  }

  if ($Restart) {
    Send-Hint -Message "OpenClaw gateway is switching network route. Chats may reconnect briefly."
    Stop-GatewayProcess -Process $script:GatewayProcess
  }

  $script:GatewayProcess = Start-GatewayProcess -ProxyEnvironment $DesiredConfig.Environment
  $script:GatewayExitWatcher = Register-GatewayExitWatcher -Process $script:GatewayProcess
  $script:CurrentFingerprint = $DesiredConfig.Fingerprint

  Write-Log ("Gateway process started pid={0} route={1} task={2} port={3}" -f $script:GatewayProcess.Id, $DesiredConfig.Summary, $GatewayTaskName, $GatewayPort)
  Write-Status -Message ("OpenClaw gateway running via {0} (pid {1}, port {2})" -f $DesiredConfig.Summary, $script:GatewayProcess.Id, $GatewayPort)
}

function Invoke-RouteChangeDecision {
  param(
    [pscustomobject]$DesiredConfig,
    [string]$RouteDecision,
    [string]$Trigger
  )

  if ($RouteDecision -eq "adapt_now" -or $RouteDecision -eq "adapt_later") {
    $adaptation = Apply-ModelRoutingAdaptation -Environment $DesiredConfig.Environment
    if ($adaptation.Changed) {
      Write-Log ("Model routing adapted: primary={0}; fallbacks={1}" -f $adaptation.Primary, (@($adaptation.Fallbacks) -join ", "))
      Write-Status -Message ("OpenClaw switched to network-supported models: primary={0}; fallbacks={1}" -f $adaptation.Primary, (@($adaptation.Fallbacks) -join ", "))
    } else {
      Write-Log ("Model routing adaptation skipped: {0}" -f $adaptation.Reason)
    }
  }

  Start-OrRestartGateway -DesiredConfig $DesiredConfig -Reason ("proxy setting changed via {0}; route={1}" -f $Trigger, $DesiredConfig.Summary) -Restart
}

function Queue-RouteChangeDecision {
  param(
    [pscustomobject]$DesiredConfig,
    [string]$RouteDecision,
    [string]$Trigger,
    [pscustomobject]$BusyState
  )

  $script:PendingRouteChange = [pscustomobject]@{
    DesiredConfig = $DesiredConfig
    RouteDecision = $RouteDecision
    Trigger = $Trigger
    QueuedAt = [DateTimeOffset]::Now
  }

  $statusMessage = if ($RouteDecision -eq "adapt_later") { "OpenClaw queued a model-route adaptation for the next idle window." } else { "OpenClaw queued a gateway reconnect for the next idle window." }
  if ($null -ne $BusyState -and $null -ne $BusyState.RecentActivityAgeSeconds) {
    $statusMessage += " Active model work was detected about $($BusyState.RecentActivityAgeSeconds)s ago."
  }

  Write-Log ("Queued route change decision: {0} (trigger={1}, route={2})" -f $RouteDecision, $Trigger, $DesiredConfig.Summary)
  Write-Status -Message $statusMessage
}

$script:GatewayProcess = $null
$script:GatewayExitWatcher = $null
$script:CurrentFingerprint = $null
$script:PendingRouteChange = $null

if ($ShowConfig) {
  [pscustomobject]@{
    config_path = $ConfigPath
    gateway = [pscustomobject]@{
      launcher_path = $GatewayCmd
      task_name = $GatewayTaskName
      port = $GatewayPort
    }
    paths = [pscustomobject]@{
      openclaw_config_path = $OpenClawConfigPath
      agent_models_path = $AgentModelsPath
      log_dir = $LogDir
      status_file = $StatusFile
      supervisor_log_file = $LogFile
      model_backup_file = $ModelBackupFile
    }
    activity = [pscustomobject]@{
      idle_check_interval_seconds = $IdleCheckIntervalSeconds
      active_work_grace_seconds = $ActiveWorkGraceSeconds
      patterns = $ActivityPatterns
    }
    proxy = Get-ProxyLaunchConfig
  } | ConvertTo-Json -Depth 10
  exit 0
}

$null = Register-EngineEvent PowerShell.Exiting -Action {
  if ($null -ne $script:GatewayExitWatcher) {
    Unregister-Event -SourceIdentifier "OpenClawGatewayProcessExited" -ErrorAction SilentlyContinue
  }

  foreach ($sourceIdentifier in @("OpenClawGatewayProcessExited") + @($ProxyWatchValues | ForEach-Object { "OpenClawProxyChange.$_" })) {
    Unregister-Event -SourceIdentifier $sourceIdentifier -ErrorAction SilentlyContinue
  }

  Stop-GatewayProcess -Process $script:GatewayProcess
}

$configState = Get-ProxyLaunchConfig
$proxyWatchers = Register-ProxyChangeWatchers
Start-OrRestartGateway -DesiredConfig $configState -Reason $configState.Summary

while ($true) {
  $event = Wait-Event -Timeout $IdleCheckIntervalSeconds
  if ($null -eq $event) {
    if ($null -ne $script:PendingRouteChange) {
      $busyState = Get-GatewayBusyState
      if (-not $busyState.Busy) {
        Write-Log ("Idle window reached; applying queued route change decision: {0}" -f $script:PendingRouteChange.RouteDecision)
        $pending = $script:PendingRouteChange
        $script:PendingRouteChange = $null
        Invoke-RouteChangeDecision -DesiredConfig $pending.DesiredConfig -RouteDecision $pending.RouteDecision -Trigger $pending.Trigger
      }
    }

    continue
  }

  Remove-Event -EventIdentifier $event.EventIdentifier -ErrorAction SilentlyContinue

  if ($event.SourceIdentifier -eq "OpenClawGatewayProcessExited") {
    $desiredConfig = Get-ProxyLaunchConfig
    $exitCode = if ($null -ne $script:GatewayProcess) { $script:GatewayProcess.ExitCode } else { "unknown" }
    Start-OrRestartGateway -DesiredConfig $desiredConfig -Reason ("process exited code={0}; route={1}" -f $exitCode, $desiredConfig.Summary)
    continue
  }

  if ($event.SourceIdentifier -like "OpenClawProxyChange.*") {
    $desiredConfig = Get-ProxyLaunchConfig
    if ($desiredConfig.Fingerprint -ne $script:CurrentFingerprint) {
      $busyState = Get-GatewayBusyState
      $routeDecision = Show-RouteChangePrompt -RouteSummary $desiredConfig.Summary -BusyState $busyState
      Write-Log ("Route change decision: {0} (trigger={1}, route={2})" -f $routeDecision, $event.SourceIdentifier, $desiredConfig.Summary)

      if ($routeDecision -eq "ignore") {
        Write-Status -Message "OpenClaw ignored this network change. Current routing stays in place."
        continue
      }

      if ($routeDecision -eq "keep_later" -or $routeDecision -eq "adapt_later") {
        Queue-RouteChangeDecision -DesiredConfig $desiredConfig -RouteDecision $routeDecision -Trigger $event.SourceIdentifier -BusyState $busyState
        continue
      }

      Invoke-RouteChangeDecision -DesiredConfig $desiredConfig -RouteDecision $routeDecision -Trigger $event.SourceIdentifier
    }
  }
}
