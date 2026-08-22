# Design

## Goals

- Single ISO, no build-time or boot-time role flag. Both machines are identical.
- No manual IP configuration.
- Either operator can initiate a test from either end.
- Recovers automatically from cable unplug/replug and renegotiation without
  requiring the operator to navigate menus or reboot.
- Distinguishes "link up" from "link good" — a marginal cable that's technically
  up but throwing errors or renegotiated to a lower speed should be visibly flagged.

## Addressing: IPv4LL (RFC 3927)

On boot, each machine runs an IPv4LL client (`avahi-autoipd` or equivalent minimal
implementation) on the Ethernet interface. This self-assigns a 169.254.x.x/16
address with ARP conflict probing — no DHCP server needed, works symmetrically
on both ends.

## Peer discovery

IPv4LL gives each machine an address but not its peer's. A lightweight UDP
broadcast/listen exchange on the link-local subnet (custom, not full mDNS/avahi-daemon
— that's more weight than this needs) lets each side learn the other's IP once
both are addressed.

## Server/client role

Both machines run `iperf3 -s -D` persistently in the background once addressed
(idle cost is negligible). Whichever operator presses "Run Test" on their machine
acts as the iperf3 client for that run, connecting to the peer's discovered IP.
No persistent role assignment. An advanced menu option allows forcing
server-only / client-only for testing against a non-participating device.

## State machine

```
NO_LINK
   │ carrier detected
   ▼
LINK_UP_NEGOTIATING
   │ ethtool speed/duplex read
   ▼
ADDRESSED               (IPv4LL complete, ARP-probed, no conflict)
   │ discovery broadcast
   ▼
PEER_DISCOVERY
   │ peer hello received
   ▼
READY                   (menu shows "Run Test", peer IP, link stats)
   │ operator triggers test
   ▼
TESTING
   │ test complete / timeout / error
   ▼
READY

  (any state) ──carrier lost──▶ NO_LINK
```

Implemented as a small daemon that owns transitions and writes current state to
a well-known location (e.g. `/run/linktest/state`) that the menu UI reads —
menu never polls hardware directly, only the state file. This keeps unplug/replug
recovery as one code path instead of special-casing every menu screen.

## Link quality vs. link up

"Link detected: yes" in ethtool does not mean the cable is good. On every
`LINK_UP_NEGOTIATING` transition:

- Read negotiated speed/duplex via `ethtool`. Diff against last known-good value
  for this session. If it renegotiated down (e.g. 1000→100, full→half), flag
  visibly rather than silently proceeding to READY.
- Snapshot `ip -s link` error/drop/CRC counters before and after each test run.
  A jump in RX errors on an otherwise "up" link is the bad-cable signal this
  project is meant to surface — report the delta on the results screen, not
  just throughput.

## Timeouts

Every iperf3 invocation is wrapped with a hard connect timeout (e.g.
`timeout 15 iperf3 -c ...`), separate from the test duration itself. A flaky
link that negotiates but doesn't pass traffic should fail fast and visibly,
not hang.

## Session log

Link-flap events (each NO_LINK transition, with timestamp) are appended to a
session scrollback file. "Link dropped 3 times this session" is diagnostic
signal a bare iperf3 run never gives you, and it's nearly free once carrier
state is already being monitored.

## Known open questions

- Exact discovery protocol wire format (custom UDP vs. reusing something
  existing — leaning custom + minimal to avoid pulling in avahi-daemon).
- Whether the state daemon is shell or a small Python/Go binary. Shell keeps
  the image tiny and dependency-free; a compiled option reduces string-parsing
  footguns. Open for discussion — see Issues.
- 2.5G/5G/10G USB-C dongle chipset driver coverage on `linux-lts` — needs
  hardware-in-hand verification, tracked in `COMPATIBILITY.md`.
