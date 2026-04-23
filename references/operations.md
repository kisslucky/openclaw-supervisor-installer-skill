# Runtime Behavior

## Normal Operation

- Start the OpenClaw gateway launcher with proxy environment variables derived from Windows Internet Settings.
- Watch proxy-related registry values for changes.
- Restart the gateway when the effective route changes.

## Active Session Protection

- Inspect recent OpenClaw logs for model-activity markers.
- If the user still appears to be in an active run, do not cut the route immediately.
- Queue the reconnect or model adaptation until the gateway looks idle.

## Prompt Semantics

When the installed supervisor can show a GUI prompt:

- `Yes`
  Keep current model routing.
- `No`
  Adapt unsupported models to currently reachable models.
- `Cancel`
  Ignore this route change.

If a recent model run is still active, `Yes` and `No` queue the action for the next idle window instead of interrupting immediately.

## Model Routing Backup

Before the supervisor changes persistent model routing, it writes a backup file into the shared OpenClaw temp directory.

## Failure Modes

- If the GUI prompt cannot be shown, the supervisor logs the failure and falls back to keeping the current route.
- If no supported replacement model is found, the supervisor logs the reason and only reconnects the gateway.
