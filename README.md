# OpenClaw Supervisor Installer

Install, update, test, or uninstall a Windows-only OpenClaw gateway supervisor that inherits Windows proxy settings, watches proxy changes, protects active sessions, prompts before route changes, and adapts model routing when the new route cannot reach the current models.

## What It Does

- installs the packaged supervisor into `%USERPROFILE%\.openclaw\supervisor`
- retargets the `OpenClaw Gateway` scheduled task to the packaged launcher
- validates the installed continuity layer after every install or update
- supports uninstall and task-target restoration

## Runtime Support

- Host runtimes: OpenClaw, Hermes, or any `SKILL.md`-compatible runtime with terminal access
- Managed target: OpenClaw on Windows
- Shell: PowerShell 5+
- Primary use: keep OpenClaw usable when direct egress stops working but a proxy path still exists

## Hermes Compatibility

No special Hermes fork is required. The same skill folder works in Hermes because it follows the `SKILL.md` convention and uses bundled terminal scripts.

The key boundary is not "OpenClaw runtime vs Hermes runtime". The key boundary is "host runtime" vs "managed system". This skill manages an OpenClaw installation from whichever compatible host runtime invokes it.

## Contents

- `SKILL.md`
- `agents/openai.yaml`
- `scripts/install-supervisor.ps1`
- `scripts/test-supervisor.ps1`
- `scripts/uninstall-supervisor.ps1`
- `assets/openclaw-gateway-supervisor.ps1`
- `assets/openclaw-gateway-supervisor.cmd`
- `assets/config.json`
- `references/configuration.md`
- `references/operations.md`

## Validation

Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-supervisor.ps1 -Force -AsJson
powershell -ExecutionPolicy Bypass -File .\scripts\test-supervisor.ps1 -AsJson
```

Successful validation confirms the installed files, task target, config, and current route view.

## License

MIT
