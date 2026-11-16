#!/bin/bash
# Debian forky: Noctalia v5 + noctalia-greeter (greetd) on top of a working niri.
# Run as your normal user. Safe to run again.
set -euo pipefail

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
[ "$(id -u)" -ne 0 ] || { echo "run as your normal user, not root" >&2; exit 1; }
niri_session="$HOME/.nix-profile/bin/niri-session"
[ -x "$niri_session" ] || { echo "$niri_session not found: set up niri first" >&2; exit 1; }

say "1/5 Noctalia apt repo (the sid entry, as forky has no own build)"
if ! dpkg -s nickh-archive-keyring >/dev/null 2>&1; then
    tmp=$(mktemp -d)
    wget -O "$tmp/keyring.deb" https://pkg.noctalia.dev/deb/nickh-archive-keyring.deb
    sudo dpkg -i "$tmp/keyring.deb"
    rm -rf "$tmp"
fi
sudo wget -O /etc/apt/sources.list.d/noctalia-unstable.sources \
    https://pkg.noctalia.dev/deb/noctalia-unstable.sources
sudo apt-get update

say "2/5 Packages"
sudo apt-get install -y noctalia noctalia-greeter

say "3/5 Session entry so the greeter can offer niri (niri comes from Nix)"
sudo mkdir -p /usr/local/share/wayland-sessions
printf '[Desktop Entry]\nName=Niri\nComment=Scrollable-tiling Wayland compositor\nExec=%s\nType=Application\nDesktopNames=niri\n' "$niri_session" |
    sudo tee /usr/local/share/wayland-sessions/niri.desktop >/dev/null

say "4/5 Start Noctalia with niri"
cfg="$HOME/.config/niri/config.kdl"
if [ ! -f "$cfg" ]; then
    echo "  $cfg not found (start niri once first); add this line yourself later:"
    echo '  spawn-at-startup "noctalia"'
elif grep -Eq '^[[:space:]]*spawn-at-startup[[:space:]]+"noctalia"' "$cfg"; then
    echo "  already in $cfg"
else
    cp -a "$cfg" "$cfg.before-noctalia"
    printf '\nspawn-at-startup "noctalia"\n' >> "$cfg"
    echo "  added to $cfg (previous version: config.kdl.before-noctalia)"
fi

say "5/5 greetd"
echo "  /etc/greetd/config.toml:"
sudo sed 's/^/    /' /etc/greetd/config.toml
if sudo grep -q 'noctalia-greeter-session' /etc/greetd/config.toml; then
    echo "  OK: greetd starts noctalia-greeter-session"
else
    echo "  NOT set to the greeter. In [default_session] it should read:"
    echo "    command = \"$(command -v noctalia-greeter-session || echo /usr/bin/noctalia-greeter-session)\""
fi
systemctl is-enabled greetd 2>/dev/null | sed 's/^/  greetd service: /'

say "Done. Reboot to get the greeter; the TTY (Ctrl+Alt+F2) and niri-session still work."
