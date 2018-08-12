#!/bin/sh
# vim:set ts=4:

set -eu

: ${ALPINE_RELEASE:="3.8"} # not tested against edge
: ${APK_TOOLS_URI:="https://github.com/alpinelinux/apk-tools/releases/download/v2.10.0/apk-tools-2.10.0-x86_64-linux.tar.gz"}
: ${APK_TOOLS_SHA256:="77f2d256fcd5d6fdafadf43bb6a9c85c3da7bb471ee842dcd729175235cb9fed"}
: ${ALPINE_KEYS:="http://dl-cdn.alpinelinux.org/alpine/v3.8/main/x86_64/alpine-keys-2.1-r1.apk"}
: ${ALPINE_KEYS_SHA256:="f7832b848cedca482b145011cf516e82392f02a10713875cb09f39c7221c6f17"}

die() {
	printf '\033[1;31mERROR:\033[0m %s\n' "$@" >&2  # bold red
	exit 1
}

einfo() {
	printf '\n\033[1;36m> %s\033[0m\n' "$@" >&2  # bold cyan
}

rc_add() {
	local target="$1"; shift # target directory
	local runlevel="$1"; shift  # runlevel name
	local services="$*"  # names of services

	local svc; for svc in $services; do
		mkdir -p "$target"/etc/runlevels/$runlevel
		ln -s /etc/init.d/$svc "$target"/etc/runlevels/$runlevel/$svc
		echo " * service $svc added to runlevel $runlevel"
	done
}

wgets() (
	local url="$1" # url to fetch
	local sha256="$2" # expected SHA256 sum of output
	local dest="$3" # output path and filename

	wget -T 10 -q -O "$dest" "$url"
	echo "$sha256  $dest" | sha256sum -c > /dev/null
)


validate_block_device() {
	local dev="$1" # target directory

	lsblk -P --fs "$dev" >/dev/null 2>&1 || \
		die "'$dev' is not a valid block device"

	if lsblk -P --fs "$dev" | grep -vq 'FSTYPE=""'; then
		die "Block device '$dev' is not blank"
	fi
}

fetch_apk_tools() {
	local store="$(mktemp -d)"
	local tarball="$(basename $APK_TOOLS_URI)"

	wgets "$APK_TOOLS_URI" "$APK_TOOLS_SHA256" "$store/$tarball"
	tar -C "$store" -xf "$store/$tarball"

	find "$store" -name apk
}

make_filesystem() {
	local device="$1" # target device path
	local target="$2" # mount target

	mkfs.ext4 "$device"
	e2label "$device" /
	mount "$device" "$target"
}

setup_repositories() {
	local target="$1" # target directory

  # NOTE: we only need @testing for aws-ena-driver-vanilla, this can be removed if/when released
	mkdir -p "$target"/etc/apk/keys
	cat > "$target"/etc/apk/repositories <<-EOF
	http://dl-cdn.alpinelinux.org/alpine/v$ALPINE_RELEASE/main
	http://dl-cdn.alpinelinux.org/alpine/v$ALPINE_RELEASE/community
	@testing http://dl-cdn.alpinelinux.org/alpine/edge/testing
	EOF
}

fetch_keys() {
	local target="$1"
	local tmp="$(mktemp -d)"

	wgets "$ALPINE_KEYS" "$ALPINE_KEYS_SHA256" "$tmp/alpine-keys.apk"
	tar -C "$target" -xvf "$tmp"/alpine-keys.apk etc/apk/keys
	rm -rf "$tmp"
}

setup_chroot() {
	local target="$1"

	mount -t proc none "$target"/proc
	mount --bind /dev "$target"/dev
	mount --bind /sys "$target"/sys

	# Don't want to ship this but it's needed for bootstrap. Will be removed in
	# the cleanup stage. 
	install -Dm644 /etc/resolv.conf "$target"/etc/resolv.conf
}

install_core_packages() {
	local target="$1"

	# Most from: https://git.alpinelinux.org/cgit/alpine-iso/tree/alpine-virt.packages
	#
	# acct - installed by some configurations, so added here
	# aws-ena-driver-vanilla - required for ENA enabled instances (still in edge/testing)
	# e2fsprogs - required by init scripts to maintain ext4 volumes
	# linux-vanilla - can't use virt because it's missing NVME support
	# mkinitfs - required to build custom initfs
	# sudo - to allow alpine user to become root, disallow root SSH logins
	# tiny-ec2-bootstrap - to bootstrap system from EC2 metadata
	chroot "$target" apk --no-cache add \
		acct \
		alpine-mirrors \
		aws-ena-driver-vanilla@testing \
		chrony \
		e2fsprogs \
		linux-vanilla \
		mkinitfs \
		openssh \
		sudo \
		tiny-ec2-bootstrap \
		tzdata

	chroot "$target" apk --no-cache add --no-scripts syslinux

    # Disable starting getty for physical ttys because they're all inaccessible
    # anyhow. With this configuration boot messages will still display in the
    # EC2 console.
    sed -Ei '/^tty\d/s/^/#/' "$target"/etc/inittab

    # Make it a little more obvious who is logged in by adding username to the
    # prompt
    sed -i "s/^export PS1='/&\\\\u@/" "$target"/etc/profile
}

create_initfs() {
	local target="$1"

	# Create ENA feature for mkinitfs
	echo "kernel/drivers/net/ethernet/amazon" > \
		"$target"/etc/mkinitfs/features.d/ena.modules

	# Enable ENA and NVME features these don't hurt for any instance and are
	# hard requirements of the 5 series and i3 series of instances
	sed -Ei 's/^features="([^"]+)"/features="\1 nvme ena"/' \
		"$target"/etc/mkinitfs/mkinitfs.conf

	chroot "$target" /sbin/mkinitfs $(basename $(find "$target"/lib/modules/* -maxdepth 0))
}

setup_extlinux() {
	local target="$1"

	# Must use disk labels instead of UUID or devices paths so that this works
	# across instance familes. UUID works for many instances but breaks on the
	# NVME ones because EBS volumes are hidden behind NVME devices.
	#
	# Enable ext4 because the root device is formatted ext4
	#
	# Shorten timeout because EC2 has no way to interact with instance console
    #
    # ttyS0 is the target for EC2s "Get System Log" feature whereas tty0 is the
    # target for EC2s "Get Instance Screenshot" feature. Enabling the serial
    # port early in extlinux gives the most complete output in the system log.
	sed -Ei -e "s|^[# ]*(root)=.*|\1=LABEL=/|" \
		-e "s|^[# ]*(default_kernel_opts)=.*|\1=\"console=ttyS0 console=tty0\"|" \
		-e "s|^[# ]*(serial_port)=.*|\1=ttyS0|" \
		-e "s|^[# ]*(modules)=.*|\1=sd-mod,usb-storage,ext4|" \
		-e "s|^[# ]*(default)=.*|\1=hardened|" \
		-e "s|^[# ]*(timeout)=.*|\1=1|" \
		"$target"/etc/update-extlinux.conf
}

install_extlinux() {
	local target="$1"

	chroot "$target" /sbin/extlinux --install /boot
	chroot "$target" /sbin/update-extlinux --warn-only
}

setup_fstab() {
	local target="$1"

	cat > "$target"/etc/fstab <<-EOF
	# <fs>		<mountpoint>	<type>	<opts>				<dump/pass>
	LABEL=/		/				ext4	defaults,noatime	1 1
	EOF
}

setup_networking() {
	local target="$1"

	cat > "$target"/etc/network/interfaces <<-EOF
	auto lo
	iface lo inet loopback

	auto eth0
	iface eth0 inet dhcp
	EOF
}

enable_services() {
	local target="$1"

	rc_add "$target" default sshd chronyd networking tiny-ec2-bootstrap
	rc_add "$target" sysinit devfs dmesg mdev hwdrivers
	rc_add "$target" boot modules hwclock swap hostname sysctl bootmisc syslog acpid
	rc_add "$target" shutdown killprocs savecache mount-ro
}

create_alpine_user() {
	local target="$1"

	# Allow members of the wheel group to sudo without a password. By default
	# this will only be the alpine user. This allows us to ship an AMI that is
	# accessible via SSH using the user's configured SSH keys (thanks to
	# tiny-ec2-bootstrap) but does not allow remote root access which is the
	# best-practice.
	sed -i '/%wheel .* NOPASSWD: .*/s/^# //' "$target"/etc/sudoers

	# There is no real standard ec2 username across AMIs, Amazon uses ec2-user
	# for their Amazon Linux AMIs but Ubuntu uses ubuntu, Fedora uses fedora,
	# etc... (see: https://alestic.com/2014/01/ec2-ssh-username/). So our user
	# and group are alpine because this is Alpine Linux. On instance bootstrap
	# the user can create whatever users they want and delete this one.
	chroot "$target" /usr/sbin/addgroup alpine
	chroot "$target" /usr/sbin/adduser -h /home/alpine -s /bin/sh -G alpine -D alpine
	chroot "$target" /usr/sbin/addgroup alpine wheel
	chroot "$target" /usr/bin/passwd -u alpine
}

configure_ntp() {
	local target="$1"

	# EC2 provides an instance-local NTP service syncronized with GPS and
	# atomic clocks in-region. Prefer this over external NTP hosts when running
	# in EC2.
	#
	# See: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/set-time.html
	sed -i 's/^server .*/server 169.254.169.123/' "$target"/etc/chrony/chrony.conf 
}

cleanup() {
	local target="$1"

	# Sweep cruft out of the image that doesn't need to ship or will be
	# re-generated when the image boots 
	rm -f \
		"$target"/var/cache/apk/* \
		"$target"/etc/resolv.conf \
		"$target"/root/.ash_history \
		"$target"/etc/*-

	umount \
		"$target"/dev \
		"$target"/proc \
		"$target"/sys

	umount "$target" 
}

main() {
	[ "$#" -ne 1 ] && { echo "usage: $0 <block-device>"; exit 1; }

	device="$1"
	target="/mnt/target"

	validate_block_device "$device"

	[ -d "$target" ] || mkdir "$target" 

	einfo "Fetching static APK tools"
	apk="$(fetch_apk_tools)"

	einfo "Creating root filesystem"
	make_filesystem "$device" "$target" 

	setup_repositories "$target"

	einfo "Fetching Alpine signing keys"
	fetch_keys "$target"

	einfo "Installing base system"
	$apk add --root "$target" --update-cache --initdb alpine-base

	setup_chroot "$target"

	einfo "Installing core packages"
	install_core_packages "$target"

	einfo "Configuring and enabling boot loader"
	create_initfs "$target"
	setup_extlinux "$target"
	install_extlinux "$target"

	einfo "Configuring system"
	setup_fstab "$target"
	setup_networking "$target"
	enable_services "$target"
	create_alpine_user "$target"
	configure_ntp "$target"

	einfo "All done, cleaning up"
	cleanup "$target"
}

main "$@"
