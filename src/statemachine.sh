#!/bin/bash
# linktest-os state machine daemon
#
# Owns transitions between NO_LINK -> LINK_UP_NEGOTIATING -> ADDRESSED ->
# PEER_DISCOVERY -> READY -> TESTING -> READY, writing current state to
# STATE_FILE so the menu UI can read it without polling hardware directly.
# Any state recovers to NO_LINK on carrier loss. See docs/DESIGN.md for the
# full state diagram and rationale.
#
# Event model: carrier transitions are driven by `ip monitor link`, not by
# re-polling `ip link show` -- see main(). Everything a state is *waiting*
# on (an IPv4LL address, a peer hello, an operator's start-test) is checked
# with a single non-blocking test per tick rather than an internal sleep
# loop, so a carrier-loss event is never stuck behind a multi-second wait.
#
# This daemon does not run linkstat.sh, IPv4LL, or peer discovery as
# separate processes it must supervise -- with one exception (peer
# discovery, which is state-machine-owned, see below):
#   * link quality (speed/duplex/RX counters) is read by shelling out to
#     linkstat.sh on demand -- see read_link_quality / snapshot_link.
#   * IPv4LL addressing is a separate, independently-running daemon
#     (overlay/usr/local/bin/linktest-ipv4ll, started at boot). This script
#     only *observes* the address it claims (current_ll_addr) -- it must
#     keep running across state-machine restarts and carrier flaps on its
#     own, so it isn't ours to launch or own.
#   * peer discovery IS owned here: the beacon/listener are background
#     helpers started and stopped as part of the PEER_DISCOVERY state
#     itself (see "Peer discovery protocol" below).
#
# Control-file protocol for READY <-> TESTING (for the not-yet-built
# menu/test-runner to use):
#   echo start-test > $CONTROL_FILE     while state is READY
#   echo test-done  > $CONTROL_FILE     while state is TESTING (success)
#   echo test-error > $CONTROL_FILE     while state is TESTING (failure)
# start-test snapshots RX error/dropped/CRC counters as a baseline;
# test-done/test-error snapshots again, logs the delta, and writes
# TEST_RESULT_FILE for the results screen. Commands sent from the wrong
# state are logged and ignored. A test that never reports back is force-
# reverted to READY after TEST_MAX_DURATION seconds (0 disables this).
#
# STATUS: functional per docs/DESIGN.md; menu/test-runner UI not built yet.

set -euo pipefail

IFACE="${LINKTEST_IFACE:-eth0}"

RUN_DIR="${LINKTEST_RUN_DIR:-/run/linktest}"
STATE_FILE="$RUN_DIR/state"
LOG_FILE="$RUN_DIR/session.log"
PEER_FILE="$RUN_DIR/peer"
LINK_FLAG_FILE="$RUN_DIR/link_flag"
CONTROL_FILE="$RUN_DIR/control"
TEST_BASELINE_FILE="$RUN_DIR/test_baseline"
TEST_RESULT_FILE="$RUN_DIR/test_result"

# linkstat.sh is expected to sit next to this script wherever it's deployed
# (both live in src/ today; the eventual packaging should keep them
# together). Override for testing.
# shellcheck disable=SC1007  # `CDPATH=` here clears it for the `cd`, not an assignment typo
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
LINKSTAT_BIN="${LINKTEST_LINKSTAT_BIN:-$SCRIPT_DIR/linkstat.sh}"

TICK_INTERVAL="${LINKTEST_TICK_INTERVAL:-1}"
IPV4LL_TIMEOUT="${LINKTEST_IPV4LL_TIMEOUT:-60}"
TEST_MAX_DURATION="${LINKTEST_TEST_MAX_DURATION:-600}"

mkdir -p "$RUN_DIR"

set_state() {
	echo "$1" > "$STATE_FILE"
	echo "$(date -Iseconds) $1" >> "$LOG_FILE"
}

log() {
	echo "$(date -Iseconds) $*" >> "$LOG_FILE"
}

current_state() {
	cat "$STATE_FILE" 2>/dev/null || echo "NO_LINK"
}

# --- Peer discovery protocol ---------------------------------------------------
#
# IPv4LL hands each machine a 169.254.x.x/16 address but not its peer's. We
# close that gap with a deliberately tiny custom UDP broadcast exchange on the
# link-local subnet -- full mDNS / avahi-daemon is more weight than a two-host
# point-to-point link needs (see docs/DESIGN.md "Peer discovery").
#
# Wire format: one plain-text line per datagram, space-separated fields:
#
#     LINKTEST-OS/1 <msgtype> <sender-ipv4> <sender-nonce>
#
#   LINKTEST-OS/1  magic + protocol version. Datagrams that don't start with
#                  this exact token are ignored, so stray broadcast traffic on
#                  the port can never move our state machine.
#   msgtype        HELLO      - unsolicited "I'm here, this is my address".
#                  HELLO-ACK  - direct answer to a HELLO we just received. Lets
#                               the far side converge immediately instead of
#                               waiting for its own next broadcast tick.
#   sender-ipv4    the sender's link-local address. Redundant with the UDP
#                  source address, but carrying it explicitly means discovery
#                  doesn't depend on recvfrom plumbing and can be cross-checked.
#   sender-nonce   random per-boot id. Our own broadcasts come back to us on
#                  this subnet; a nonce match is how we discard them. (Matching
#                  on source IP is unreliable while IPv4LL is still ARP-probing
#                  and addresses may still be shifting.)
#
# Both sides broadcast HELLO every DISCOVERY_HELLO_INTERVAL seconds until they
# have learned a peer, and answer every HELLO with a HELLO-ACK. The first valid
# packet from a different nonce wins and its address is cached in PEER_FILE; the
# menu UI reads that file for the "peer IP" line and as the `iperf3 -c` target.

DISCOVERY_PORT="${LINKTEST_DISCOVERY_PORT:-15987}"
DISCOVERY_MAGIC="LINKTEST-OS/1"
DISCOVERY_BCAST="169.254.255.255"
DISCOVERY_HELLO_INTERVAL="${LINKTEST_HELLO_INTERVAL:-2}"
DISCOVERY_TIMEOUT="${LINKTEST_DISCOVERY_TIMEOUT:-30}"

# Per-boot identifier used to recognise (and drop) our own broadcasts.
SELF_NONCE="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"

# PIDs of the background beacon + listener, and the SECONDS value at which
# various waits started -- used to time out and re-arm without blocking.
DISCOVERY_PIDS=""
DISCOVERY_STARTED_AT=0
IPV4LL_DEADLINE=0
IPV4LL_WARNED=0
TEST_STARTED_AT=0
FLAP_COUNT=0

# "Best confirmed" speed/duplex seen this session (this daemon's lifetime).
# Only ratchets up, so a marginal renegotiation keeps being flagged instead
# of quietly becoming the new normal. Empty until the first clean reading.
LAST_GOOD_SPEED=""
LAST_GOOD_DUPLEX=""

# The `ip monitor link` supervisor's FIFO path and PID (see main()). These
# must be plain globals, not `local` to main(): the EXIT trap needs them,
# and when a signal terminates the shell mid-function, bash does not keep
# that function's locals visible to the trap it runs on the way out
# (confirmed with `bash -x` -- the trap fired but "monitor_pid" read back
# unbound even though `main` was still on the stack when SIGTERM arrived).
MONITOR_FIFO=""
MONITOR_PID=""

# Fire a single discovery datagram at the link-local broadcast address.
# UDP4- (not the protocol-family-agnostic UDP-), deliberately: Alpine's
# shipped socat (1.8.0.0) fails UDP-DATAGRAM/UDP-RECV's address resolution
# with "getaddrinfo(\"NULL\", ...): Name has no usable address" -- found by
# booting two real VMs and watching peer discovery never converge despite
# everything else (addressing, connectivity) working. UDP4- takes a
# different, working code path in this socat version, and is arguably more
# correct anyway since this whole protocol is IPv4-only.
send_discovery() {
	local msgtype="$1" our_ip="$2"
	printf '%s %s %s %s\n' \
		"$DISCOVERY_MAGIC" "$msgtype" "$our_ip" "$SELF_NONCE" \
		| socat -u -t0.2 - \
			"UDP4-DATAGRAM:${DISCOVERY_BCAST}:${DISCOVERY_PORT},broadcast" \
			2>/dev/null || true
}

# Broadcast HELLO on a fixed interval until a peer has been cached.
discovery_beacon() {
	local our_ip="$1"
	while [ ! -s "$PEER_FILE" ]; do
		send_discovery "HELLO" "$our_ip"
		sleep "$DISCOVERY_HELLO_INTERVAL"
	done
}

# Listen for discovery datagrams, validate them against the wire format, cache
# the first peer we hear in PEER_FILE, and answer every HELLO with a direct
# HELLO-ACK so the far side converges without waiting for its next tick.
discovery_listener() {
	local our_ip="$1"
	local magic msgtype peer_ip nonce rest
	socat -u "UDP4-RECV:${DISCOVERY_PORT},reuseaddr" - 2>/dev/null \
	| while read -r magic msgtype peer_ip nonce rest; do
		[ "$magic" = "$DISCOVERY_MAGIC" ] || continue
		[ "$nonce" = "$SELF_NONCE" ] && continue        # our own broadcast
		case "$peer_ip" in
			169.254.*) ;;
			*) continue ;;                          # not a link-local sender
		esac
		[ "$peer_ip" = "$our_ip" ] && continue          # address clash / echo

		if [ ! -s "$PEER_FILE" ]; then
			printf '%s\n' "$peer_ip" > "$PEER_FILE"
			log "discovery: peer learned $peer_ip (via $msgtype)"
		fi

		[ "$msgtype" = "HELLO" ] && send_discovery "HELLO-ACK" "$our_ip"
	done || true   # socat exiting / being killed must not trip `set -e`
}

# (Re)arm the beacon + listener for the given local address. Idempotent: any
# previous discovery processes are reaped and PEER_FILE is cleared first.
start_peer_discovery() {
	local our_ip="$1"
	stop_peer_discovery
	rm -f "$PEER_FILE"

	discovery_listener "$our_ip" &
	DISCOVERY_PIDS="$!"
	discovery_beacon "$our_ip" &
	DISCOVERY_PIDS="$DISCOVERY_PIDS $!"
	DISCOVERY_STARTED_AT="$SECONDS"
	log "discovery: armed on udp/$DISCOVERY_PORT as $our_ip (nonce $SELF_NONCE)"
}

stop_peer_discovery() {
	local pid
	for pid in $DISCOVERY_PIDS; do
		kill "$pid" 2>/dev/null || true
	done
	DISCOVERY_PIDS=""
	# Reap the socat children the beacon/listener spawned.
	pkill -f "socat.*:${DISCOVERY_PORT}" 2>/dev/null || true
}

# --- IPv4LL (observed, not owned) ------------------------------------------

# Echo our current IPv4LL address on $IFACE, or nothing if none is assigned
# yet. Always exits 0: under `pipefail` (set script-wide) a pipeline reports
# the last *non-zero* stage, not simply the last command's status, so
# `grep` finding no match would make this "fail" even though `head` itself
# exits 0 -- and every caller here does a bare `addr="$(current_ll_addr)"`,
# which `set -e` treats as a failed command. Caught by testing: the daemon
# died silently, mid-tick, the very first time no address was assigned yet
# (i.e. on every normal boot before IPv4LL claims one).
current_ll_addr() {
	ip -4 -o addr show dev "$IFACE" 2>/dev/null \
		| grep -oE '169\.254\.[0-9]{1,3}\.[0-9]{1,3}' \
		| head -n1 \
		|| true
}

# --- link quality (linkstat.sh) --------------------------------------------

snapshot_link() {
	"$LINKSTAT_BIN" "$IFACE" 2>>"$LOG_FILE"
}

field_of() {
	printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n1
}

# Called on every LINK_UP_NEGOTIATING transition. Reads speed/duplex/RX
# counters via linkstat.sh and flags a renegotiation-down against the best
# value confirmed so far this session, per docs/DESIGN.md "Link quality vs.
# link up". Does not localize IFACE/TIMESTAMP: linkstat.sh's own IFACE=...
# line reasserts the same value we already have, so letting it fall through
# to the script-global $IFACE is harmless -- do not add IFACE to the locals
# below, that would shadow it out from under snapshot_link's own "$IFACE".
read_link_quality() {
	# shellcheck disable=SC2034  # most of these exist only to contain eval's
	# assignments to this function's scope instead of leaking them as globals
	# (see the IFACE/TIMESTAMP note above) -- not all are read below.
	local CARRIER OPERSTATE LINK_DETECTED SPEED_MBPS DUPLEX AUTONEG \
		RX_BYTES RX_PACKETS RX_ERRORS RX_DROPPED RX_MISSED RX_MCAST \
		TX_BYTES TX_PACKETS TX_ERRORS TX_DROPPED TX_CARRIER TX_COLLSNS \
		RX_CRC_ERRORS
	local snap flag=""

	if ! snap="$(snapshot_link)"; then
		log "linkstat: failed to read $IFACE"
		return
	fi
	eval "$snap"

	if [ -n "$SPEED_MBPS" ] && [ -n "$LAST_GOOD_SPEED" ] && [ "$SPEED_MBPS" -lt "$LAST_GOOD_SPEED" ]; then
		flag="speed renegotiated down: ${LAST_GOOD_SPEED} -> ${SPEED_MBPS} Mb/s"
	fi
	if [ "$DUPLEX" = "half" ] && [ "$LAST_GOOD_DUPLEX" = "full" ]; then
		flag="${flag:+$flag; }duplex renegotiated down: full -> half"
	fi

	if [ -n "$flag" ]; then
		log "LINK QUALITY: $flag"
		printf '%s\n' "$flag" > "$LINK_FLAG_FILE"
	else
		rm -f "$LINK_FLAG_FILE"
	fi

	if [ -n "$SPEED_MBPS" ] && { [ -z "$LAST_GOOD_SPEED" ] || [ "$SPEED_MBPS" -gt "$LAST_GOOD_SPEED" ]; }; then
		LAST_GOOD_SPEED="$SPEED_MBPS"
	fi
	if [ "$DUPLEX" = "full" ]; then
		LAST_GOOD_DUPLEX="full"
	elif [ -z "$LAST_GOOD_DUPLEX" ] && [ "$DUPLEX" != "unknown" ]; then
		LAST_GOOD_DUPLEX="$DUPLEX"
	fi

	log "link: ${SPEED_MBPS:-?}Mb/s ${DUPLEX} (autoneg ${AUTONEG}), rx_errors=${RX_ERRORS:-?} rx_dropped=${RX_DROPPED:-?} rx_crc=${RX_CRC_ERRORS:-n/a}"
}

# --- READY <-> TESTING control file -----------------------------------------

# Diff RX error/dropped/CRC counters across a test run and log + record the
# delta, per docs/DESIGN.md "Snapshot ip -s link ... before and after each
# test run."
report_test_result() {
	local outcome="$1" before after
	before="$(cat "$TEST_BASELINE_FILE" 2>/dev/null || true)"
	after="$(snapshot_link || true)"

	local b_err b_drop b_crc a_err a_drop a_crc
	b_err="$(field_of "$before" RX_ERRORS)"
	b_drop="$(field_of "$before" RX_DROPPED)"
	b_crc="$(field_of "$before" RX_CRC_ERRORS)"
	a_err="$(field_of "$after" RX_ERRORS)"
	a_drop="$(field_of "$after" RX_DROPPED)"
	a_crc="$(field_of "$after" RX_CRC_ERRORS)"

	local d_err=$(( ${a_err:-0} - ${b_err:-0} ))
	local d_drop=$(( ${a_drop:-0} - ${b_drop:-0} ))
	local d_crc=$(( ${a_crc:-0} - ${b_crc:-0} ))

	log "test $outcome: RX errors +$d_err, dropped +$d_drop, crc +$d_crc"
	{
		printf 'OUTCOME=%s\n' "$outcome"
		printf 'RX_ERRORS_DELTA=%s\n' "$d_err"
		printf 'RX_DROPPED_DELTA=%s\n' "$d_drop"
		printf 'RX_CRC_ERRORS_DELTA=%s\n' "$d_crc"
	} > "$TEST_RESULT_FILE"
	rm -f "$TEST_BASELINE_FILE"
}

# Consume one pending command from CONTROL_FILE, if any. $1 is the state
# we're currently in, so a command sent from the wrong state is a no-op.
check_control() {
	local expected="$1" cmd
	[ -s "$CONTROL_FILE" ] || return 0
	cmd="$(cat "$CONTROL_FILE" 2>/dev/null || true)"
	: > "$CONTROL_FILE"

	case "$cmd" in
		start-test)
			if [ "$expected" = "READY" ]; then
				snapshot_link > "$TEST_BASELINE_FILE" 2>/dev/null || true
				TEST_STARTED_AT="$SECONDS"
				set_state "TESTING"
				log "test started (control: start-test)"
			else
				log "control: ignoring start-test, not READY"
			fi
			;;
		test-done|test-error)
			if [ "$expected" = "TESTING" ]; then
				report_test_result "$cmd"
				set_state "READY"
			else
				log "control: ignoring $cmd, not TESTING"
			fi
			;;
		*)
			log "control: unknown command '$cmd'"
			;;
	esac
}

# --- state transitions -------------------------------------------------------

begin_link_up() {
	set_state "LINK_UP_NEGOTIATING"
	read_link_quality
	IPV4LL_DEADLINE=$((SECONDS + IPV4LL_TIMEOUT))
	IPV4LL_WARNED=0
}

on_carrier_down() {
	stop_peer_discovery
	pkill -f 'iperf3 -c' 2>/dev/null || true   # in-flight client test, not the idle -s
	rm -f "$PEER_FILE" "$TEST_BASELINE_FILE" "$LINK_FLAG_FILE"
	FLAP_COUNT=$((FLAP_COUNT + 1))
	log "link dropped (flap #$FLAP_COUNT this session)"
	set_state "NO_LINK"
}

# Dispatch one line of `ip monitor link` (or the one-shot seed read at
# startup). Lines for interfaces other than $IFACE, or that don't change UP
# vs DOWN, are no-ops -- so re-delivering the current state is always safe.
handle_link_line() {
	local line="$1"
	printf '%s\n' "$line" | grep -qE "^[0-9]+: ${IFACE}:" || return 0

	case "$line" in
		*"state UP"*)
			[ "$(current_state)" = "NO_LINK" ] && begin_link_up
			;;
		*"state DOWN"*)
			[ "$(current_state)" != "NO_LINK" ] && on_carrier_down
			;;
	esac
}

# Advance whatever the current state is waiting on. Called once per tick
# (either a real `ip monitor` event or a TICK_INTERVAL timeout) -- every
# branch is a single non-blocking check, never an internal sleep loop.
progress_state() {
	case "$(current_state)" in
		LINK_UP_NEGOTIATING)
			local addr
			addr="$(current_ll_addr)"
			if [ -n "$addr" ]; then
				set_state "ADDRESSED"
				start_peer_discovery "$addr"
				set_state "PEER_DISCOVERY"
				DISCOVERY_STARTED_AT="$SECONDS"
			elif [ "$IPV4LL_WARNED" = 0 ] && [ "$SECONDS" -ge "$IPV4LL_DEADLINE" ]; then
				log "ipv4ll: still no 169.254.x.x on $IFACE after ${IPV4LL_TIMEOUT}s (is linktest-ipv4ll running?)"
				IPV4LL_WARNED=1
			fi
			;;
		PEER_DISCOVERY)
			local addr
			addr="$(current_ll_addr)"
			if [ -z "$addr" ]; then
				# Lost our own address mid-discovery (e.g. ipv4ll re-probing
				# after its own carrier event) -- fall back and re-wait for it.
				log "peer-discovery: lost our own address, reverting to LINK_UP_NEGOTIATING"
				stop_peer_discovery
				set_state "LINK_UP_NEGOTIATING"
				IPV4LL_DEADLINE=$((SECONDS + IPV4LL_TIMEOUT))
				IPV4LL_WARNED=0
			elif [ -s "$PEER_FILE" ]; then
				stop_peer_discovery
				set_state "READY"
			elif [ $((SECONDS - DISCOVERY_STARTED_AT)) -ge "$DISCOVERY_TIMEOUT" ]; then
				log "discovery: no peer after ${DISCOVERY_TIMEOUT}s, re-arming"
				start_peer_discovery "$addr"
				DISCOVERY_STARTED_AT="$SECONDS"
			fi
			;;
		READY)
			check_control "READY"
			;;
		TESTING)
			check_control "TESTING"
			if [ "$TEST_MAX_DURATION" -gt 0 ] && [ $((SECONDS - TEST_STARTED_AT)) -ge "$TEST_MAX_DURATION" ]; then
				log "test exceeded ${TEST_MAX_DURATION}s with no test-done/test-error; forcing READY"
				rm -f "$TEST_BASELINE_FILE"
				set_state "READY"
			fi
			;;
	esac
}

main() {
	command -v ip >/dev/null 2>&1 || { log "FATAL: ip (iproute2) not found"; exit 1; }
	command -v socat >/dev/null 2>&1 || log "WARNING: socat not found; peer discovery will not function"
	[ -x "$LINKSTAT_BIN" ] || log "WARNING: linkstat not found/executable at $LINKSTAT_BIN; link-quality readings will fail"

	set_state "NO_LINK"
	: > "$CONTROL_FILE"

	# The carrier monitor runs in its own background process, feeding lines
	# through a named FIFO, so it has a PID we can actually reach on
	# shutdown. (An earlier version used `< <(...)` process substitution
	# instead: that gives no PID to kill, so on SIGTERM the supervisor and
	# its `ip monitor` child were orphaned and kept running forever instead
	# of exiting with the daemon -- caught by testing, not by inspection.)
	# It restarts `ip monitor` if it ever dies, so a crash degrades to "just
	# the tick", not a busy loop: the supervisor holds the FIFO's write end
	# open across restarts, so `read -t` below only ever times out or gets a
	# real line, never EOF.
	MONITOR_FIFO="$RUN_DIR/monitor.fifo"
	rm -f "$MONITOR_FIFO"
	mkfifo "$MONITOR_FIFO"
	(
		while true; do
			ip monitor link 2>/dev/null
			log "ip monitor link exited; restarting in 2s"
			sleep 2
		done
	) > "$MONITOR_FIFO" &
	MONITOR_PID=$!

	trap 'pkill -P "$MONITOR_PID" 2>/dev/null; kill "$MONITOR_PID" 2>/dev/null; rm -f "$MONITOR_FIFO"; stop_peer_discovery' EXIT

	# `ip monitor` only reports future changes, so seed from whatever the
	# interface is doing right now before entering the event loop.
	handle_link_line "$(ip -o link show dev "$IFACE" 2>/dev/null || true)"

	# React the instant the monitor reports a carrier change, and otherwise
	# wake once per TICK_INTERVAL to progress whatever the current state is
	# waiting on.
	exec 3< "$MONITOR_FIFO"
	while true; do
		local line=""
		if IFS= read -r -t "$TICK_INTERVAL" line <&3; then
			handle_link_line "$line"
		fi
		progress_state
	done
}

# Allow this file to be sourced (e.g. by tests) without running the daemon.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	main "$@"
fi
