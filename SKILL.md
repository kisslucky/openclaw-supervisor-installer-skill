---
name: openclaw-supervisor-installer
description: Install, update, test, or uninstall a Windows-only OpenClaw gateway supervisor that inherits Windows proxy settings, watches proxy changes, protects active sessions, prompts before route changes, and adapts model routing when the new route cannot reach the current models. Use when Codex needs to make OpenClaw survive proxy or network changes instead of timing out on direct egress.
---

# OpenClaw Supervisor Installer

Use this skill from any `SKILL.md`-compatible agent runtime that can execute local terminal commands on Windows, including OpenClaw and Hermes.

- The managed system is a local OpenClaw installation on Windows.
- The invoking runtime is intentionally decoupled from the managed system.
- Do not use it as a generic Windows proxy manager. Its scope is the OpenClaw gateway task, bundled supervisor files, and model-routing adaptation policy.

## Quick Start

Run `scripts/install-supervisor.ps1 -Force -AsJson` to install or update the packaged supervisor.

Run `scripts/test-supervisor.ps1 -AsJson` immediately after installation.

## Workflow

1. Read `references/configuration.md` only if the user wants to change install paths, polling windows, replacement models, or notification behavior.
2. Install or update with `scripts/install-supervisor.ps1`.
3. Validate with `scripts/test-supervisor.ps1`.
4. Use `references/operations.md` when the user asks how the installed supervisor behaves.
5. Uninstall with `scripts/uninstall-supervisor.ps1` only when the user explicitly asks to remove the continuity layer.

## Installation Policy

Use the packaged assets instead of editing the live system script by hand.

Default install target:

- `%USERPROFILE%\.openclaw\supervisor`

Default task target:

- `OpenClaw Gateway`

Always validate after install. Do not leave the user on an untested task target.

## Durable Changes

Explain these changes before applying them:

- The scheduled task target is replaced with the packaged supervisor launcher.
- A user-local install directory is created under `.openclaw\supervisor`.
- The supervisor can rewrite persistent model routing when the user selects the adaptation path during a network change prompt.

## Resources

- `scripts/install-supervisor.ps1`
  Install or update the packaged supervisor and retarget the gateway task.
- `scripts/test-supervisor.ps1`
  Verify the installed files, task target, config, and supervisor route view.
- `scripts/uninstall-supervisor.ps1`
  Restore the previous task target or the direct gateway launcher.
- `assets/openclaw-gateway-supervisor.ps1`
  Runtime supervisor script.
- `assets/openclaw-gateway-supervisor.cmd`
  Runtime launcher used by the scheduled task.
- `assets/config.json`
  Default packaged config.
- `references/configuration.md`
  Supported config knobs.
- `references/operations.md`
  Runtime behavior and prompt semantics.

## Typical Requests

- "Install a proxy-aware gateway supervisor."
- "Update the continuity layer without losing my existing config."
- "Test whether the installed supervisor sees the current route correctly."
- "Remove the supervisor and restore the original gateway launcher."
