# linktest-os

A minimal, bootable Linux distro for point-to-point Ethernet link testing between two machines.
Boot it on both ends of a cable, and it auto-negotiates addressing, reports link quality
(speed, duplex, errors), and runs a sustained throughput test — no manual IP config,
no SSH-ing in, no typing iperf3 flags.

Built for field/semi-pro use where a $3-8k handheld tester is overkill but "hope the
cable is fine" isn't good enough.

## Status

Working end-to-end as of v0.1.0: the ISO builds, boots straight to the menu with no
login prompt, two machines find each other over a real Ethernet cable, and a throughput
test completes successfully. Still early — hardware coverage and edge cases are thin,
see `docs/COMPATIBILITY.md` for what's actually been tested.

## Why

- iperf3 + ethtool already do the hard work — this project just removes the manual
  setup friction (IP config, role assignment, remembering flags) and adds resilience
  (auto-recovery from unplug/replug, bad-cable detection via renegotiation/error deltas).
- Runs entirely from RAM off a USB stick — nothing touches the host laptop's installed
  OS or disk.
- Symmetric: both machines boot the identical ISO. No "build A" vs "build B."

## Quickstart

1. Flash the latest ISO from [Releases](../../releases) to two USB sticks (`dd` or Rufus/balenaEtcher).
2. Boot both laptops from USB.
3. Connect them via Ethernet cable (crossover or straight-through — both fine, MDI-X autosenses).
4. Wait for "Ready" on both screens.
5. Press **Run Test** on either machine.

## How addressing works

Both machines self-assign an IPv4LL (169.254.x.x/16, RFC 3927) address on boot — no DHCP,
no manual config, no role flag baked into the image. A lightweight discovery broadcast lets
each side learn its peer's address automatically. Both sides run an idle `iperf3 -s`, so
either operator can initiate a test from either laptop. See `docs/DESIGN.md` for the full
state machine (link up → addressed → peer discovery → ready → testing, with automatic
recovery on cable unplug/replug).

## Repo layout

```
build/              Alpine mkimage profile: package list, kernel/init config
overlay/             Files copied verbatim into the live image
  etc/local.d/       Boot-time init scripts (link monitor, IPv4LL, discovery)
  usr/local/bin/      Menu + test-runner scripts
src/                 Source for the state-machine daemon (link/peer/test states)
docs/
  DESIGN.md          Architecture, state machine, addressing scheme
  COMPATIBILITY.md   Known-good / known-bad NIC and USB-C dongle hardware matrix
.github/workflows/    CI: build ISO on tag, publish to Releases
```

## Contributing

- **Hardware compatibility matrix** (`docs/COMPATIBILITY.md`) is the thing that makes
  this useful long-term — PRs adding tested NIC/dongle chipsets (especially 2.5G/5G/10G
  USB-C adapters) are the highest-value contribution right now.
- Bug reports and feature requests: use Issues.
- Design discussion: use Discussions.

## License

MIT — see [LICENSE](LICENSE).
