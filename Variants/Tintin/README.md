# Tintin Monitor 3.2

A local macOS desktop companion for this Apple M4 laptop. On this laptop it is installed at `~/Applications/Tintin Monitor.app`.

## Offline security

Version 3.1 blocks the pet process's networking through a macOS sandbox policy, applied before app initialization. If it cannot apply the policy, it refuses to start. No Internet, cloud service, remote assets, server, or account is needed at runtime. GitHub uploads are separate development actions.

See [SECURITY.md](SECURITY.md) for the exact policy, test procedure, and scope. `--security-test` verifies IPv4/IPv6 TCP, UDP, and bind operations are blocked using loopback only.

## Compact window and power

Version 3.2 replaces the tall scrolling panel with a 336×450 window, about one-third shorter. Overview shows CPU/GPU graphs and top-two apps, temperatures, RAM, battery, health, and activity. Settings holds size, login launch, and quick actions.

The Power tab adds:

- Battery charge history and charging state.
- Battery temperature from available local SMC battery sensors.
- System power in watts from SMC, with local power telemetry as fallback, and a recent history graph.
- Measured adapter input in watts, with the separately labeled rated maximum. Disconnected adapters are shown as not connected; unavailable readings show a dash.
- Top two applications by kernel process-energy counter changes per second. This measures reported process energy and does not account for all hardware or sum to whole-system wattage. Older systems without counters show no per-app data instead of estimates from CPU/GPU usage.
- Estimated battery health and cycle count.

All readings remain local under the same enforced network-denial policy. No online service is used.

## RAM and battery

Version 3.1 adds RAM used/total and percentage, battery charge percentage, charging/plugged-in status, estimated battery health capacity, and charge cycle count. These are local kernel, IOKit power-source, and battery-registry reads under the existing network-denial policy.

RAM uses GiB (binary units). Used RAM includes resident anonymous pages minus purgeable pages, plus wired and compressed memory; reclaimable file cache is excluded. Swap use is available in the RAM tooltip.

Battery health percentage is an estimate of nominal full-charge capacity divided by design capacity, capped at 100%; raw full-charge capacity is used only if nominal capacity is unavailable. It can differ from Apple's rounded Battery Health screen. macOS condition is shown when available. Missing data is displayed as unavailable; battery-less Macs do not get fabricated readings.

The compact 336×450 panel has Overview, Power, and Settings tabs; all readings and size/startup controls fit without scrolling. No hardware samples or battery identifiers are sent to GitHub.

## Pixel-art edition

Tintin sits using a laptop, with idle/blink, typing, waving, and hardware-warning animations. “32-bit” describes the retro artwork; the executable is native 64-bit Apple silicon, as required by modern macOS. Your existing local Shinchan size, position, and warning preferences are copied on first launch.

## Use

- Click Tintin to open live laptop status. Click the close button to return to the pet.
- Drag Tintin to move him. His position and size are saved.
- Adjust **Pet size** from 50% to 200% in the status panel. Right-click presets are also available.
- **Start automatically at login** is enabled on this laptop. The checkbox turns it off or on. macOS starts login items after you sign in, not before the login screen.
- The paw menu in the menu bar can show Tintin, reset his position, or quit.
- **Activity Monitor** opens Apple's detailed process viewer. **Downloads** opens your local Downloads folder.

## Live readings

The panel refreshes every two seconds and shows:

- Total CPU usage across all cores and a recent history graph.
- Total GPU usage reported by the accelerator driver and a recent history graph.
- Top two CPU applications, grouping helper processes under their application. CPU percentages are normalized to total machine capacity.
- Top two GPU applications ranked by measured GPU time. Units are **milliseconds of GPU work per second** (ms/s); these are not application utilization percentages. Parallel GPU work can overlap, and the driver may omit some processes.
- Separate CPU and GPU temperatures, averaged from available M4 die sensors. A dash indicates unavailable data.
- Sampled activity level, busiest application names, process count, process disk reads + writes per second, and macOS thermal pressure.

Activity summaries describe observed resource usage. They do not inspect documents, command arguments, browser content, or determine task completion/progress. This version is a local system companion, with no cloud AI connection, microphone listener, or network telemetry.

## Hardware alerts

Click **Alerts…** in the panel or **Hardware alerts…** in the paw menu.

| Reading | Default warning limit | Must stay high for |
| --- | --- | --- |
| CPU usage | 90% | 30 seconds |
| GPU usage | 90% | 30 seconds |
| CPU temperature | 85 °C | 10 seconds |
| GPU temperature | 85 °C | 10 seconds |

- Change each limit with its slider. Enable/disable alerts and sound independently. Preferences are saved locally.
- A warning appears in a bubble beside Tintin for 18 seconds, with buttons to show laptop status or dismiss it. The paw menu becomes a warning symbol while a qualified high reading remains active.
- If macOS notification permission is allowed, a local notification also appears. Focus and screen-sharing settings can suppress system banners; the pet bubble remains available.
- Each metric alerts at most once every five minutes, including after restarting the app. Sustained high readings can trigger another reminder after that cooldown.
- Short spikes do not alert. Recovery uses a 5-percentage-point margin for usage and 3 °C for temperature, to avoid flickering around a threshold.
- Missing sensors do not generate alerts. Sampling gaps after sleep reset the qualification timer.
- **Test alert** demonstrates the warning without stressing or heating the laptop. The test is clearly labeled and does not alter real alert cooldowns.

These are configurable warning levels, not hardware shutdown limits. CPU/GPU temperatures use the available sensor averages described above. Alerts run while Tintin is running; login launch keeps him available after sign-in.

## Build and diagnostics

Requires Apple silicon macOS 13+ and Xcode Command Line Tools. Temperature keys are intended for this M4 laptop; other hardware can show unavailable temperatures.

```sh
bash Source/test.sh
bash Source/build.sh
"Tintin Monitor.app/Contents/MacOS/TintinMonitor" --security-test
"Tintin Monitor.app/Contents/MacOS/TintinMonitor" --self-test
```

The self-test prints actual readings and top-two process samples after a two-second sampling interval. Login registration belongs to the installed app's path:

```sh
"$HOME/Applications/Tintin Monitor.app/Contents/MacOS/TintinMonitor" --login-status
```

The implementation uses AppKit, Metal, read-only IOKit/AppleSMC queries, libproc, and Apple's ServiceManagement login-item API. It does not alter fan settings or system processes. The included source builds an ad-hoc signed local app. No developer account or extra runtime is needed on this Mac.

Verified locally: CPU/GPU totals, per-app CPU and GPU samples, separate CPU/GPU temperatures, enabled login status, continuous size and alert-limit sliders, and enabled macOS notification access. The alert state machine passes 196 deterministic checks covering sustained readings, all four metrics, cooldowns, recovery, missing sensors, sleep gaps, disable, and preference persistence.

Version 3.1 validation: 196 alert-engine checks and 16 RAM/battery calculation checks passed. Local self-test and on-screen RAM/charge/health/cycle readings were verified with the network restriction active.

Version 3.2 validation: both build/signature and offline network-denial checks passed, local temperature/power/process-energy readings were sampled, all three compact tabs were checked on screen, and 196 alert + 20 RAM/battery/power checks passed.
