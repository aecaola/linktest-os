#!/bin/bash
# linktest-os :: link quality reader
#
# Reads negotiated link parameters and interface counters for one Ethernet
# interface and prints them as KEY=value lines on stdout -- one record per
# invocation, the same key set every time (a value is left empty when its
# source is unavailable). This is a pure reader: it holds no state and makes
# no "good vs. bad" judgement. Consumers (the state-machine daemon's
# read_link_quality, the results screen) do the diffing described in
# docs/DESIGN.md "Link quality vs. link up".
#
# Usage:
#   linkstat.sh [IFACE]      IFACE defaults to $LINKTEST_IFACE, then "eth0".
#
# Output keys (always all present, in this order):
#   IFACE           interface name
#   TIMESTAMP       ISO-8601 time this snapshot was taken
#   CARRIER         1 | 0 | unknown            physical link      (sysfs)
#   OPERSTATE       up | down | unknown | ...   kernel operstate  (sysfs)
#   LINK_DETECTED   yes | no | unknown                            (ethtool)
#   SPEED_MBPS      negotiated speed in Mbit/s (integer) or empty (ethtool)
#   DUPLEX          full | half | unknown                         (ethtool)
#   AUTONEG         on | off | unknown                            (ethtool)
#   RX_BYTES RX_PACKETS RX_ERRORS RX_DROPPED RX_MISSED RX_MCAST    (ip -s link)
#   TX_BYTES TX_PACKETS TX_ERRORS TX_DROPPED TX_CARRIER TX_COLLSNS (ip -s link)
#   RX_CRC_ERRORS   summed CRC/FCS error counters if the driver exposes any,
#                   else empty                        (ethtool -S, best effort)
#
# Every value is a single shell-safe token, so a consumer can:
#   eval "$(linkstat.sh eth0)"
#   [ "$DUPLEX" = full ] || echo "half duplex on $IFACE"
# or snapshot to a file and diff two records field by field.
#
# Exit status: 0 on success, 2 if IFACE does not exist.

set -euo pipefail

IFACE="${1:-${LINKTEST_IFACE:-eth0}}"

case "$IFACE" in
	-h|--help)
		# Print the header comment block (everything after the shebang up to
		# the first non-comment line), stripped of the leading "# ".
		awk 'NR == 1 { next } /^#/ { sub(/^#[[:space:]]?/, ""); print; next } { exit }' "$0"
		exit 0
		;;
esac

if [ ! -e "/sys/class/net/$IFACE" ]; then
	echo "linkstat: no such interface: $IFACE" >&2
	exit 2
fi

lc() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'; }

# --- sysfs: carrier / operstate ---------------------------------------------
# carrier reads back EINVAL while the interface is administratively down.
CARRIER="$(cat "/sys/class/net/$IFACE/carrier" 2>/dev/null || true)"
case "$CARRIER" in 0|1) ;; *) CARRIER="unknown" ;; esac
OPERSTATE="$(cat "/sys/class/net/$IFACE/operstate" 2>/dev/null || true)"
[ -n "$OPERSTATE" ] || OPERSTATE="unknown"

# --- ethtool: negotiated speed / duplex / autoneg / link -------------------
LINK_DETECTED="unknown"
SPEED_MBPS=""
DUPLEX="unknown"
AUTONEG="unknown"

et=""
if et="$(ethtool "$IFACE" 2>/dev/null)"; then
	# Pull the value after "  <Label>: ", first match only (no `head`, so a
	# closed pipe can't trip pipefail).
	et_field() {
		printf '%s\n' "$et" | awk -v key="$1" '
			{ sub(/^[[:space:]]+/, "") }
			index($0, key ": ") == 1 { print substr($0, length(key) + 3); exit }
		'
	}

	SPEED_MBPS="$(et_field "Speed" | grep -oE '^[0-9]+' || true)"

	case "$(lc "$(et_field "Duplex")")" in
		full*) DUPLEX="full" ;;
		half*) DUPLEX="half" ;;
		*)     DUPLEX="unknown" ;;
	esac

	case "$(lc "$(et_field "Auto-negotiation")")" in
		on)  AUTONEG="on" ;;
		off) AUTONEG="off" ;;
		*)   AUTONEG="unknown" ;;
	esac

	case "$(lc "$(et_field "Link detected")")" in
		yes) LINK_DETECTED="yes" ;;
		no)  LINK_DETECTED="no" ;;
		*)   LINK_DETECTED="unknown" ;;
	esac
fi

# --- ip -s link: RX/TX byte/packet/error/drop counters --------------------
# The `-s` table labels its columns in a header row; the values follow on the
# next line in the same order. Map by name so a column rename (older iproute2
# calls RX "missed" -> "overrun") or reordering doesn't silently misread.
counters="$(ip -s link show dev "$IFACE" 2>/dev/null | awk '
	$1 == "RX:" { for (i = 2; i <= NF; i++) n[i] = $i
	              getline
	              for (i = 2; i <= NF + 1; i++) rx[n[i]] = $(i - 1)
	              next }
	$1 == "TX:" { for (i = 2; i <= NF; i++) n[i] = $i
	              getline
	              for (i = 2; i <= NF + 1; i++) tx[n[i]] = $(i - 1)
	              next }
	END {
		miss = rx["missed"]; if (miss == "") miss = rx["overrun"]
		printf "RX_BYTES=%s\nRX_PACKETS=%s\nRX_ERRORS=%s\nRX_DROPPED=%s\nRX_MISSED=%s\nRX_MCAST=%s\n",
			rx["bytes"], rx["packets"], rx["errors"], rx["dropped"], miss, rx["mcast"]
		printf "TX_BYTES=%s\nTX_PACKETS=%s\nTX_ERRORS=%s\nTX_DROPPED=%s\nTX_CARRIER=%s\nTX_COLLSNS=%s\n",
			tx["bytes"], tx["packets"], tx["errors"], tx["dropped"], tx["carrier"], tx["collsns"]
	}
' || true)"

# --- ethtool -S: CRC/FCS errors (driver-specific, often absent) -----------
RX_CRC_ERRORS="$(ethtool -S "$IFACE" 2>/dev/null | awk -F: '
	{ k = tolower($1); sub(/^[[:space:]]+/, "", k) }
	(k ~ /crc/ || k ~ /fcs/) && k ~ /err/ && k !~ /tx/ {
		v = $2; gsub(/[^0-9]/, "", v)
		if (v != "") { s += v; seen = 1 }
	}
	END { if (seen) print s + 0 }
' || true)"

# --- emit ----------------------------------------------------------------
cat <<EOF
IFACE=$IFACE
TIMESTAMP=$(date -Iseconds)
CARRIER=$CARRIER
OPERSTATE=$OPERSTATE
LINK_DETECTED=$LINK_DETECTED
SPEED_MBPS=$SPEED_MBPS
DUPLEX=$DUPLEX
AUTONEG=$AUTONEG
$counters
RX_CRC_ERRORS=$RX_CRC_ERRORS
EOF
