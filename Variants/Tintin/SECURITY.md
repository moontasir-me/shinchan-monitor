# Offline operation and security boundary

The installed apps run locally. They require no account, API key, browser, server, or Internet connection. Artwork is bundled in the app. Monitoring uses local macOS hardware/process APIs. Alerts use local UserNotifications requests and a local pet bubble; no remote-notification/APNs registration is performed.

## Enforced network restriction

Before initializing the application, each executable applies a process-local macOS Seatbelt profile:

```scheme
(version 1)
(allow default)
(deny network*)
```

The network denial applies to the pet process, including incoming/outgoing socket operations. It also blocks localhost networking; no local web server is used. If applying the policy fails, the executable exits with status 78 instead of starting without the restriction. There is no configuration switch to bypass it.

`--security-test` verifies blocked IPv4 and IPv6 TCP connections, UDP sends, and socket binds using loopback and an unprivileged test port. It contacts no external hosts and performs no DNS lookup. Expected result: `PASS` and exit status 0. Run from a normal local Terminal; nesting inside an existing execution sandbox may prevent adding the profile, in which case the app refuses to start.

This uses macOS's legacy `sandbox_init` interface, which Apple marks deprecated. It was verified on this M4 laptop. It may need replacement for a future macOS/SDK; failure remains closed. This is a targeted network restriction, not the full App Sandbox filesystem/permission model.

## Data and dependencies

- No HTTP client calls, web views, sockets for app operation, analytics, crash upload, automatic updater, cloud AI, or remote asset downloads.
- RAM use, battery percentage/health/cycles, CPU/GPU usage, die temperatures, app names, and activity summaries are read and displayed locally. Process command arguments and document/browser contents are not inspected.
- Position, size, warning preferences, and last warning timestamps use local UserDefaults. No diagnostic hardware samples are uploaded to GitHub.
- Notifications, login launch, window rendering, and opening Activity Monitor/Downloads rely on local macOS services. The app cannot control what macOS or other installed apps do on the network.
- Only Apple system frameworks/libraries are linked. No downloaded runtime, package manager, or third-party background service is installed.
- The app does not request Full Disk Access, Accessibility control, microphone, camera, or administrator privileges. It does not change fans or terminate other processes.

The restriction is on this app, not the entire computer. OS services and other apps retain their own network access. GitHub publishing is an explicit developer action outside the installed pet; it is not built into the app. The executable is locally ad-hoc signed, so users downloading it should review and build the included source if they require their own trusted build.

## Local validation

```sh
bash Source/test.sh
bash Source/build.sh
"Shinchan Monitor.app/Contents/MacOS/ShinchanMonitor" --security-test
"Shinchan Monitor.app/Contents/MacOS/ShinchanMonitor" --self-test
```

For the Tintin archive, replace `Shinchan` with `Tintin` in those executable paths. Both variants use the same network policy and alert logic.
