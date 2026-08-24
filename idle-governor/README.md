# Idle clock governor (optional)

Cuts idle power roughly in half. It is **not** part of the unlock and nothing
else depends on it.

## Why it is needed

The card does not lower its own clock request. Measured on a CMP 50HX
(`10de:1e09`, driver `610.43.03`, 2026-08-24):

| Condition | P-state | SM / Mem | Power |
|---|---|---|---|
| Idle, 0 % utilisation, no processes | P0 | 1920 / 7000 MHz | 62–64 W |
| Same, 60 s after a load ended | P0 | 1905 MHz | 63 W |
| `nvidia-smi -lgc 300,1920` (range allowed) | P0 | 1905 MHz | 63 W |
| `nvidia-smi -lgc 300` (hard ceiling) | **P3** | **300 / 5000 MHz** | **32.3 W** |

`Clocks Event Reasons → Idle` reads *Not Active* the whole time. Given a
permitted clock *range*, the arbiter always resolves it to the maximum and
never issues a downward request on its own. The only lever the firmware
honours from the host is an explicit ceiling — which this service supplies
automatically.

The underlying policy sits in signed GSP firmware, configured by VBIOS perf
tables that are encrypted on Turing (including on consumer cards such as the
RTX 2080 Ti), so there is no host-side switch that re-enables the native
behaviour. Full investigation and measurements:
`experiments/cmp50-pstate-20260824/RESULT.md` in the research workspace.

## Measured result

| | Idle | Under load |
|---|---|---|
| without the governor | 62–64 W | full clocks |
| with the governor | **32.4 W** | full clocks, restored within one poll |

About **−29 W per idle card**. Verified live end to end: 30 s idle → clamped to
P3/32.4 W; a load released it within one poll to 1905 MHz and 171–229 W; the
load ending clamped it again; stopping the unit released it cleanly.

## Install

Either pass `--idle-governor` to `install.sh`, or enable it later:

```sh
sudo systemctl enable --now cmp-idle-governor
```

Status and log:

```sh
systemctl status cmp-idle-governor
journalctl -u cmp-idle-governor -f
```

## Remove

```sh
sudo systemctl disable --now cmp-idle-governor
```

The unit releases the clamp on stop, and clock locks are runtime state that a
reboot clears anyway.

## Tuning

Defaults are conservative. Override with a systemd drop-in
(`systemctl edit cmp-idle-governor`):

| Variable | Default | Meaning |
|---|---|---|
| `CMP_IDLE_CLOCK` | lowest supported graphics clock, auto-detected per GPU | MHz ceiling while idle |
| `CMP_POLL` | `5` | seconds between samples; also the worst-case delay before a new job gets full clocks |
| `CMP_IDLE_AFTER` | `6` | consecutive idle polls before clamping (6 × 5 s = 30 s) |
| `CMP_UTIL` | `5` | utilisation percent still treated as idle |
| `CMP_LOAD_CORE_OFFSET` | unset | core VF offset to restore on load; while idle the offset is set to 0 so the card can reach P3. Written by `cmp-tune apply` |

Example — clamp sooner, react faster:

```ini
[Service]
Environment=CMP_POLL=2
Environment=CMP_IDLE_AFTER=5
```

## Interaction with `cmp50-vfctl` (undervolt / overclock)

`cmp50-vfctl` sets four independent things. The governor touches exactly one
of them, so read this before combining the two.

| vfctl sets | NVML call | Governor effect |
|---|---|---|
| power limit | `nvmlDeviceSetPowerManagementLimit` | untouched, survives |
| core VF offset | `nvmlDeviceSetGpcClkVfOffset` | untouched, survives |
| memory VF offset | `nvmlDeviceSetMemClkVfOffset` | untouched, survives |
| **locked GPU clock** | **`nvmlDeviceSetGpuLockedClocks`** | **same setting the governor uses** |

The clash is only the last row: `nvidia-smi -lgc/-rgc` and vfctl's
`set` / `set-range` clock argument are the *same* control.

Measured with `cmp50-vfctl set 170 225 2100 1000` (170 W, VF +225, locked
2100 MHz, memory +1000):

| Step | SM clock | Memory | Power limit | Mem offset |
|---|---|---|---|---|
| profile applied | 2100 MHz | 7500 MHz | 170 W | +1000 |
| governor clamps (idle) | 300 MHz | 7500 MHz | 170 W | +1000 |
| released with `-rgc` (default) | **2145 MHz** | 7500 MHz | 170 W | +1000 |
| released with `CMP_LOAD_CLOCK=2100` | **2100 MHz** | 7500 MHz | 170 W | +1000 |

Two things to note:

1. **Your undervolt/overclock is not lost.** Power limit and both VF offsets
   survive a clamp/release cycle untouched.
2. **The default release overshoots your tuned clock.** `-rgc` clears the lock
   entirely, and because the +225 VF offset is still active the card then
   boosts to 2145 MHz — *above* the 2100 MHz you validated. That is the one
   real hazard of running both tools with default settings.

**So if you use vfctl clock locking, tell the governor what to restore:**

```sh
sudo systemctl edit cmp-idle-governor
```

```ini
[Service]
Environment=CMP_LOAD_CLOCK=2100
```

Then the card goes 2100 MHz under load → 300 MHz idle → back to exactly
2100 MHz, with the power limit and both offsets untouched throughout.
`CMP_LOAD_CLOCK` also accepts a range, e.g. `1700,1980` to match
`vfctl set-range`.

### Why the core offset is dropped while idle

A non-zero **core** VF offset pins the card in P0, and in P0 the memory clock
never steps down — so a tuned card would idle at ~40 W instead of ~32 W even
with the core clamped. Measured, core clamped to 300 MHz throughout:

| core offset | mem offset | P-state | memory | power |
|---|---|---|---|---|
| +225 | +1000 | P0 | 7500 MHz | 40.0 W |
| **0** | +1000 | **P3** | **5000 MHz** | **32.5 W** |
| +225 | 0 | P0 | 7000 MHz | 39.6 W |
| +225 | −2000 | P0 | 6801 MHz | 39.5 W |
| **0** | −2000 | **P3** | **5000 MHz** | **32.6 W** |

The memory offset makes no difference to this; the core offset decides it, and
once the card reaches P3 memory drops to 5000 MHz on its own. So the governor
sets the core offset to 0 while clamped and restores `CMP_LOAD_CORE_OFFSET` on
release. Your memory tuning is never touched.

Note there is no way to select a P-state directly: NVML exposes
`nvmlDeviceGetPerformanceState` but no setter, `-lmc` is rejected on this card
("Setting locked Memory clocks is not supported"), and `-ac` is deprecated.
P3 is the deepest state reachable from the host — the card advertises a
405 MHz memory tier too, but only the firmware idle path can select it, and
that path is what does not work on this SKU.

Order of operations does not matter — apply the vfctl profile before or after
starting the governor — as long as `CMP_LOAD_CLOCK` matches the clock your
profile uses.

## Trade-off and limits

- A job that starts while the card is clamped runs at the idle clock for up to
  one poll interval (5 s by default). Lower `CMP_POLL` if that matters.
- Utilisation-based, so a workload that leaves the GPU at 0 % between bursts
  (very short, widely spaced kernels) will clamp and release repeatedly. Raise
  `CMP_IDLE_AFTER` for that pattern.
- Multi-GPU aware: each card is tracked and clamped independently.
- Measured on CMP 50HX only. The mechanism is generic `nvidia-smi` clock
  control and the idle ceiling is auto-detected, so it should work on a
  CMP 90HX, but that is untested.
