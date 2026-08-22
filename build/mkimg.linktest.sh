# Alpine mkimage.sh profile for linktest-os
# Place/symlink into build/aports/scripts/ as mkimg.linktest.sh during build,
# or reference via --profile once aports is vendored (see build.sh).
#
# This is a skeleton — package list and overlay wiring will grow as the
# state-machine daemon and menu scripts (src/, overlay/) firm up.

profile_linktest() {
	profile_standard
	title="linktest-os"
	desc="Minimal live Ethernet link tester (see github.com/<you>/linktest-os)"
	image_ext="iso"
	kernel_flavors="lts"
	kernel_cmdline="unionfs_size=64M"
	initfs_features="$initfs_features base squashfs usb"

	# Core packages: ethtool for link stats, iperf3 for throughput,
	# avahi for IPv4LL addressing, dialog for the TUI menu, bash for scripts.
	apks="$apks ethtool iperf3 avahi dialog bash iproute2"

	# Bake in the menu/daemon scripts and boot-time init.
	apkovl="genapkovl-linktest.sh"
}
