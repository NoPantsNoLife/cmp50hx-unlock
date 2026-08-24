# cmp-tune — profile tuning

Sets power limit, core/memory VF offsets and the locked core-clock range from
named profiles, per card. Optional; nothing in the unlock depends on it.

`nvidia-smi` cannot set VF offsets, so this talks to NVML directly through
`ctypes`. No headers, no build step — it loads `libnvidia-ml.so.1`, which the
driver already installs.

## Commands

```sh
cmp-tune list                 # profiles in the config file
cmp-tune status               # live state + the ranges the card reports
cmp-tune show efficient       # what a profile would do, without doing it
sudo cmp-tune apply efficient
sudo cmp-tune reset           # back to card defaults

sudo cmp-tune -i 1 apply quiet   # one card only (default: every CMP card)
```

## Profiles

Config is `/etc/cmp-tune.conf` (seeded from `profiles.conf` at install and
never overwritten afterwards). Each section is a profile; every key optional:

| Key | Meaning |
|---|---|
| `power_w` | power limit, watts |
| `core_offset` | core (GPC) clock VF offset, MHz |
| `mem_offset` | memory clock VF offset, MHz |
| `clock_min` | lower bound of the locked core clock, MHz |
| `clock_max` | upper bound of the locked core clock, MHz |

```ini
[efficient]
power_w = 170
core_offset = 225
mem_offset = 1000
clock_max = 2100
```

## Clock rules

- Set only `clock_max` and the card's **own minimum** supported clock becomes
  the floor. Set only `clock_min` and its maximum becomes the ceiling. So a
  profile never has to hardcode a bound it does not care about, and the lock
  always sits inside the card's real range.
- Set neither and no lock is applied; any existing lock is cleared.
- Every value is validated against what the card reports. On a CMP 50HX that
  is `300..2100 MHz` and `100..225 W`, so:

```
$ cmp-tune show bogus
profile 'bogus' cannot be applied to GPU 0:
  - power_w 500 is outside the card's 100..225 W
  - clock_max 9000 is outside the card's 300..2100 MHz
```

Check the exact numbers for your card with `cmp-tune status`.

## Which GPUs it touches

Only **CMP 50HX** (`10de:1e09`) and **CMP 90HX** (`10de:220d`), matched by PCI
ID. Any other GPU in the box — a display card, another accelerator — is listed
and skipped:

```
skipping GPU 1 (NVIDIA GeForce RTX 3090, pci 10de:2204): not a supported CMP card
```

Pointing `-i` at a non-CMP card is refused. With several CMP cards, the default
is to apply to all of them; use `-i` for one.

## Working with the idle governor

The [idle governor](../idle-governor/README.md) and this tool drive the *same*
NVML locked-clock setting, so on its own the governor's release would clear a
tuned clock and let the card boost past it (measured: 2145 MHz after a profile
set 2100, because the VF offset stays live).

`cmp-tune` handles this: when it applies a profile with a clock lock it writes

```
/etc/systemd/system/cmp-idle-governor.service.d/10-cmp-tune.conf
```

with `CMP_LOAD_CLOCK=min,max` and restarts the governor, so the governor's
release restores exactly the profile's clock. `cmp-tune reset` removes it.
Verified end to end: 2100 MHz under load → 300 MHz idle → back to 2100 MHz,
with the power limit and both offsets untouched throughout.

Pass `--no-sync-governor` to leave the drop-in alone.

## Notes and limits

- Everything set here is **runtime state** and is gone after a reboot, by
  design. To apply a profile at boot, add a small unit or an `ExecStartPost`
  of your own; there is deliberately no auto-apply, because an unstable
  overclock that re-applies on every boot is hard to recover from.
- VF offsets shift the whole curve, so the effective clock under load can end
  up above `clock_max` unless a lock is in force. That is why a tuned profile
  should normally set a clock bound too.
- Power limit, core offset and memory offset survive an idle-governor
  clamp/release cycle untouched.
- Values that a profile omits are left exactly as they are — a profile is not
  a full reset. Use `cmp-tune reset` for that, or a profile with no keys
  (`[stock]`).
