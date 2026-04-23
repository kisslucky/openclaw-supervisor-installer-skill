# Configuration

The installer copies `assets/config.json` into the install root and rewrites a few fields from explicit parameters.

## Paths

- `gateway.launcherPath`
  Direct launcher that the supervisor will wrap.
- `gateway.taskName`
  Scheduled task to retarget.
- `gateway.port`
  Listener port used for post-install checks and task health.
- `paths.openclawConfigPath`
  Routing config the supervisor may adapt.
- `paths.agentModelsPath`
  Provider metadata used to infer reachability.
- `paths.logDir`
  Shared log directory for OpenClaw and the supervisor status files.

## Activity Windows

- `activity.idleCheckIntervalSeconds`
  Poll interval for queued route changes.
- `activity.activeWorkGraceSeconds`
  Window used to avoid cutting off an active model run.
- `activity.patterns`
  Log substrings that count as recent model activity.

## Model Adaptation

- `models.replacementCandidates`
  Ordered candidate list used when the current route no longer reaches the active model set.

## Notifications

- `notifications.title`
  Window title for route-change prompts.
- `notifications.useMsgExe`
  When true, send a short text hint with `msg.exe` during route switches.
- `notifications.msgTimeoutSeconds`
  Timeout for the `msg.exe` hint.

## Proxy Watchers

- `proxy.registryPath`
  User proxy registry subpath under `HKEY_USERS\<sid>`.
- `proxy.watchValues`
  Registry values that trigger reevaluation.
