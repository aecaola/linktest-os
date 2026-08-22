#!/bin/bash
# linktest-os state machine daemon
#
# Owns transitions between NO_LINK -> LINK_UP_NEGOTIATING -> ADDRESSED ->
# PEER_DISCOVERY -> READY -> TESTING -> READY, writing current state to
# STATE_FILE so the menu UI can read it without polling hardware directly.
# See docs/DESIGN.md for the full state diagram and rationale.
#
# STATUS: skeleton / not yet functional. Contributions welcome.

set -euo pipefail

IFACE="${LINKTEST_IFACE:-eth0}"
STATE_FILE="/run/linktest/state"
LOG_FILE="/run/linktest/session.log"

mkdir -p "$(dirname "$STATE_FILE")"

set_state() {
	echo "$1" > "$STATE_FILE"
	echo "$(date -Iseconds) $1" >> "$LOG_FILE"
}

read_link_quality() {
	# TODO: parse `ethtool $IFACE` for Speed/Duplex, diff against last
	# known-good value for this session; parse `ip -s link show $IFACE`
	# for RX error/drop/CRC counters. Flag renegotiation-down or rising
	# error counts rather than silently proceeding.
	:
}

on_carrier_up() {
	set_state "LINK_UP_NEGOTIATING"
	read_link_quality
	set_state "ADDRESSED"       # TODO: gate on actual IPv4LL completion
	# TODO: kick off peer discovery broadcast
	set_state "PEER_DISCOVERY"
	# TODO: gate on peer hello received
	set_state "READY"
}

on_carrier_down() {
	# TODO: kill any in-flight iperf3 test, clear cached peer entry
	set_state "NO_LINK"
}

main() {
	set_state "NO_LINK"
	# TODO: replace with `ip monitor link` event loop instead of polling.
	while true; do
		if ip link show "$IFACE" | grep -q "state UP"; then
			[ "$(cat "$STATE_FILE" 2>/dev/null)" = "NO_LINK" ] && on_carrier_up
		else
			[ "$(cat "$STATE_FILE" 2>/dev/null)" != "NO_LINK" ] && on_carrier_down
		fi
		sleep 1
	done
}

main "$@"
