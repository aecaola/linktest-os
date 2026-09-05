# Alpine mkimage.sh profile for linktest-os
#
# mkimage.sh resolves `--profile linktest` by looking for a mkimg.linktest.sh
# defining profile_linktest() inside its OWN scripts/ directory
# (build/aports/scripts/, once aports is vendored) -- build.sh copies this
# file there before every invocation, since build/aports/ is a throwaway
# clone, not part of this repo. See build/genapkovl-linktest.sh for what
# apkovl="genapkovl-linktest.sh" below actually bakes into the image.

profile_linktest() {
	profile_standard
	title="linktest-os"
	desc="Minimal live Ethernet link tester (see github.com/<you>/linktest-os)"
	image_ext="iso"
	kernel_flavors="lts"
	kernel_cmdline="unionfs_size=64M"
	initfs_features="$initfs_features base squashfs usb"

	# Core packages: ethtool for link stats, iperf3 for throughput,
	# iputils-arping for RFC 3927 IPv4LL duplicate-address detection
	# (Alpine has no avahi-autoipd -- see overlay/usr/local/bin/linktest-ipv4ll),
	# dialog for the TUI menu, bash for scripts, socat for the peer-discovery
	# UDP broadcast/listen exchange (busybox nc can't set SO_BROADCAST).
	apks="$apks ethtool iperf3 iputils-arping dialog bash iproute2 socat"

	# Bake in the menu/daemon scripts and boot-time init.
	apkovl="genapkovl-linktest.sh"
}
