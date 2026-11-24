# Local laptop companions

**Tintin Monitor 3.1** is the new retro 32-bit-style pixel-art companion: Tintin sits using a laptop, idles, blinks, types, waves, and reacts to hardware warnings. The executable is native 64-bit Apple silicon for modern macOS.

<img src="Variants/Tintin/Source/Assets/AppIcon.png" width="220" alt="Pixel-art Tintin using a laptop">

**Shinchan Monitor 2.2** remains available with the same offline network restriction.

## Offline operation

Both apps run locally with no Internet connection, account, server, API key, cloud AI, telemetry, auto-update, or remote artwork. A macOS process sandbox denies networking before app initialization; if that restriction cannot be installed, the app refuses to start. GitHub publishing is separate from the app.

See [SECURITY.md](SECURITY.md) for the exact policy, verification commands, and limitations. This restriction covers the pet process, not other apps or the entire operating system.

## Monitoring and alerts

- RAM used/total and percentage, battery charge/charging state, estimated battery health capacity, cycle count, and reported condition when available. Read locally under the enforced offline policy.
- Real CPU/GPU totals and history, separate M4 CPU/GPU die temperatures, and top two active CPU/GPU applications.
- Local current activity, disk I/O, process count, and thermal pressure.
- Adjustable size, drag-to-position, saved preferences, and native launch-at-login support.
- Warning limits default to 90% CPU/GPU usage for 30 seconds, or 85 °C for 10 seconds.
- Adjustable limits, on-pet warning bubbles, optional local notification sounds/banners, and a five-minute per-metric cooldown.
- No process command arguments or document/browser contents are inspected.

Tintin copies existing local Shinchan size, position, and alert preferences on first launch. Login launch and notification permission are separate per app. Enable the companion you want to use at login.

## Download

Get `TintinMonitor.zip` or `ShinchanMonitor.zip` from [Releases](https://github.com/moontasir-me/shinchan-monitor/releases). Each archive includes its `.app`, source, build/test scripts, and documentation. Builds are locally ad-hoc signed and intended for Apple silicon macOS 13+; die sensor keys were tested on M4.

## Build Tintin

Requires Xcode Command Line Tools; no third-party packages are needed.

```sh
bash Variants/Tintin/Source/test.sh
bash Variants/Tintin/Source/build.sh
"Variants/Tintin/Tintin Monitor.app/Contents/MacOS/TintinMonitor" --security-test
"Variants/Tintin/Tintin Monitor.app/Contents/MacOS/TintinMonitor" --self-test
```

[Full Tintin instructions](Variants/Tintin/README.md) · [Artwork prompts](Variants/Tintin/ASSETS.md)

## Build Shinchan

```sh
bash Source/test.sh
bash Source/build.sh
"Shinchan Monitor.app/Contents/MacOS/ShinchanMonitor" --security-test
```

[Full Shinchan instructions](SHINCHAN.md)

## Validation

Verified locally on an M4 Mac: both native builds and signatures; OS denial of IPv4/IPv6 TCP, UDP, and bind operations using loopback only; actual hardware readings under the restriction; Tintin's visible animation and live status panel; saved size/alert preferences; login launch and local notification permission. Alert logic passes 196 deterministic checks and RAM/battery calculation handling passes 16 additional checks without a hardware stress test. Starting under a sandbox that prevents applying the policy is tested to exit closed.
