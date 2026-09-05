#!/bin/sh -e
# linktest-os :: apkovl generator
#
# Invoked by Alpine's mkimage.sh (mkimg.base.sh's build_apkovl) as:
#   fakeroot genapkovl-linktest.sh <hostname>
# with $PWD already set to $DESTDIR (the assembled image root). There is no
# stdout contract -- mkimage.sh just expects <hostname>.apkovl.tar.gz to
# exist in the current directory once this returns. fakeroot lets us
# chown/chmod correctly even though the build itself may not run as root.
#
# Modeled on Alpine's own scripts/genapkovl-dhcp.sh, with one deliberate
# difference: dhcp's genapkovl generates small config files inline via a
# heredoc + explicit chmod, because it has nothing pre-existing to copy.
# We do have pre-existing, already-correctly-mode-bit'd files (the repo's
# overlay/ tree and two scripts under src/), so we `cp -a` them instead of
# re-declaring their permissions a second time in a place that could drift
# out of sync with the actual files.
#
# What ends up in the apkovl:
#   - all of overlay/ (etc/local.d/*.start+.stop, etc/inittab,
#     usr/local/bin/linktest-ipv4ll, linktest-testrunner, linktest-menu)
#   - src/statemachine.sh and src/linkstat.sh, copied to sit alongside the
#     rest in usr/local/bin/ -- every script's own "look for my sibling
#     next to me" path resolution (e.g. statemachine.sh's LINKSTAT_BIN)
#     assumes they all land in one directory, and this is where that
#     assumption is actually made true
#   - etc/runlevels/default/local, enabling the `local` OpenRC service so
#     etc/local.d/*.start actually runs at boot -- easy to forget, and the
#     ISO would build fine and boot to nothing if it were missing
#
# $OVERLAY_DIR and $SRC_DIR must be set in the environment, pointing at the
# repo's overlay/ and src/ directories (build/build.sh sets both before
# invoking mkimage.sh).

HOSTNAME="$1"
if [ -z "$HOSTNAME" ]; then
	echo "usage: $0 hostname" >&2
	exit 1
fi
: "${OVERLAY_DIR:?OVERLAY_DIR must be set -- see build/build.sh}"
: "${SRC_DIR:?SRC_DIR must be set -- see build/build.sh}"
[ -d "$OVERLAY_DIR" ] || { echo "genapkovl-linktest: no such directory: $OVERLAY_DIR" >&2; exit 1; }
[ -d "$SRC_DIR" ] || { echo "genapkovl-linktest: no such directory: $SRC_DIR" >&2; exit 1; }

cleanup() {
	rm -rf "$tmp"
}
trap cleanup EXIT
tmp="$(mktemp -d)"

# The whole overlay/ tree, verbatim, modes and all.
cp -a "$OVERLAY_DIR"/. "$tmp"/

# See the file header: these two need to land next to the overlay scripts.
mkdir -p "$tmp"/usr/local/bin
cp -a "$SRC_DIR"/statemachine.sh "$tmp"/usr/local/bin/statemachine.sh
cp -a "$SRC_DIR"/linkstat.sh "$tmp"/usr/local/bin/linkstat.sh

rc_add() {
	mkdir -p "$tmp"/etc/runlevels/"$2"
	ln -sf /etc/init.d/"$1" "$tmp"/etc/runlevels/"$2"/"$1"
}
rc_add local default

# Fail the build loudly here rather than ship an apkovl that boots to
# nothing because a script lost its executable bit somewhere along the way.
missing=0
for f in "$tmp"/etc/local.d/*.start "$tmp"/etc/local.d/*.stop "$tmp"/usr/local/bin/*; do
	[ -e "$f" ] || continue
	if [ ! -x "$f" ]; then
		echo "genapkovl-linktest: not executable: $f" >&2
		missing=1
	fi
done
[ "$missing" -eq 0 ] || { echo "genapkovl-linktest: aborting -- fix the permissions above" >&2; exit 1; }

tar -c -C "$tmp" etc usr | gzip -9n > "$HOSTNAME".apkovl.tar.gz
