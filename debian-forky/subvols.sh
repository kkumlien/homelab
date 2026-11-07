#!/bin/sh
# Debian forky install: btrfs subvolumes + fstab in one go (build plan layout).
#
# When: installer shell (Ctrl+Alt+F2) at the "Configure the package manager"
# prompt, i.e. base system installed, software not selected yet.
#   wget -O /tmp/s https://github.com/kkumlien/homelab/raw/main/debian-forky/subvols.sh
#   sh /tmp/s
# Then Ctrl+Alt+F1 and carry on. Safe to re-run.
#
# Creates @home @nix @log @snapshots next to @rootfs, seeds @home and @log
# with what the base install already wrote, mounts all four under /target so
# the rest of the install writes into them, puts noatime,compress=zstd:1 on
# the / line of fstab (keeping its subvol=) plus one line per subvolume, and
# hands /nix to uid 1000 for the single-user Nix installer.
# The original fstab is kept as /etc/fstab.d-i.
set -eu

OPTS=noatime,compress=zstd:1
SUBVOLS="@home:/home @nix:/nix @log:/var/log @snapshots:/.snapshots"
F=/target/etc/fstab
TOP=/mnt/top

die() { echo "subvols: $*" >&2; exit 1; }
mounted() { grep -q " $1 " /proc/mounts; }

[ -f "$F" ] || die "no $F yet: run me later (the Finish screen works too)"
grep -q ' /target btrfs ' /proc/mounts || die "/target is not btrfs"

set -- /dev/mapper/*_crypt
[ $# -eq 1 ] && [ -e "$1" ] || die "expected one *_crypt device, found: $*"
DEV=$1

# Device spec d-i used for /, reused for the new lines
SPEC=$(awk '$1 !~ /^#/ && $2 == "/" { print $1 }' "$F")
[ -n "$SPEC" ] || die "no / line in $F"

# 1. Create, seed and mount each subvolume
mkdir -p "$TOP"
mounted "$TOP" || mount -o subvolid=5 "$DEV" "$TOP"
for pair in $SUBVOLS; do
    sv=${pair%%:*}; mp=/target${pair#*:}
    mounted "$mp" && continue
    [ -d "$TOP/$sv" ] || btrfs subvolume create "$TOP/$sv"
    if [ -d "$mp" ]; then cp -a "$mp/." "$TOP/$sv/"; else mkdir -p "$mp"; fi
    mount -o "$OPTS,subvol=$sv" "$DEV" "$mp"
done
umount "$TOP"

# 2. fstab: options on the / line, one line per subvolume
[ -f "$F.d-i" ] || cp "$F" "$F.d-i"
awk -v o="$OPTS" '
    $1 !~ /^#/ && $2 == "/" && $3 == "btrfs" {
        sv = ""; n = split($4, a, ",")
        for (i = 1; i <= n; i++) if (a[i] ~ /^subvol=/) sv = "," a[i]
        $4 = o sv
    }
    { print }' "$F" > /tmp/fstab.new
cat /tmp/fstab.new > "$F"
for pair in $SUBVOLS; do
    sv=${pair%%:*}; mp=${pair#*:}
    grep -q "subvol=$sv " "$F" ||
        printf '%s %s btrfs %s,subvol=%s 0 0\n' "$SPEC" "$mp" "$OPTS" "$sv" >> "$F"
done

# 3. /nix for the single-user Nix installer (d-i's first user gets uid 1000)
chown 1000:1000 /target/nix

echo; grep ' /target' /proc/mounts; echo; cat "$F"
