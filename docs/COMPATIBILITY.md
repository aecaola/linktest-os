# Hardware Compatibility

Community-maintained. Please open a PR to add a row — this list is the main
long-term value of the project.

Format: fill in what you know, leave blank what you don't. "Tested speed" means
you actually ran a sustained test and observed this, not just what the box says.

## Onboard NICs

| Device / Chipset            | Max Speed | Driver        | Status      | Notes                          |
|------------------------------|-----------|---------------|-------------|----------------------------------|
| Intel I219-LM/V              | 1G        | e1000e        | ✅ Known good | Dell Latitude 7000-series, etc. |
| Intel I225-V/LM               | 2.5G      | igc           | ❓ Untested   |                                  |

## USB-C / USB-A Ethernet Dongles

| Device / Model               | Chipset        | Max Speed | Driver   | Status      | Notes |
|-------------------------------|----------------|-----------|----------|-------------|-------|
| Dell DBQBCBC064               | Realtek RTL8153 (likely) | 1G | r8152 | ❓ Needs confirmation | Common w/ Latitude & Surface docks |

## Multi-gig (2.5G/5G/10G) dongles — needs the most testing

| Device / Model               | Chipset        | Max Speed | Driver   | Status      | Notes |
|-------------------------------|----------------|-----------|----------|-------------|-------|
| _add yours_                   |                |           |          |             |       |

## How to contribute a row

1. Boot linktest-os on the machine with the adapter in question.
2. Check the link status screen (or run `ethtool <iface>` manually) for
   negotiated speed/duplex and the driver in use (`ethtool -i <iface>`).
3. Run a sustained test against a known-good peer and note actual throughput.
4. Open a PR adding/editing a row above.
