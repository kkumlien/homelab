#!/bin/bash
# Debian forky: from a fresh netinst TTY to a running niri, one step at a time.
#
#   wget -O desktop.sh https://github.com/kkumlien/homelab/raw/main/debian-forky/desktop.sh
#   bash desktop.sh          # start at step 1
#   bash desktop.sh 5        # start (again) at step 5
#   bash desktop.sh --list   # show the steps
#
# Run as your normal user, not root. Each step says what it will do and waits:
# Enter runs it, s skips it, q quits. Steps are safe to run again.
# Scope: only what it takes to get a compositor with a terminal, a launcher
# and a browser. Noctalia, greeter, keyring and the rest come after, by hand.

# shellcheck disable=SC2034  # the about_* texts are read indirectly (${!a})
STEPS="font network packages browser nix home_manager gpu niri_session start"
SWITCH_LOG="$HOME/.cache/desktop-sh-switch.log"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }
die()  { printf '\n\033[1;31mFAILED:\033[0m %s\n' "$*" >&2; exit 1; }

load_nix() {
    # shellcheck disable=SC1091
    [ -e "$HOME/.nix-profile/etc/profile.d/nix.sh" ] && . "$HOME/.nix-profile/etc/profile.d/nix.sh"
    command -v nix >/dev/null || die "nix is not installed yet: run the nix step first"
}

# ---------------------------------------------------------------- 1
about_font="Bigger console font (Terminus 16x32), now and at every boot."
step_font() {
    local f=/usr/share/consolefonts/Lat15-Terminus32x16.psf.gz
    [ -e "$f" ] || { note "font file not found, skipping"; return 0; }
    sudo sed -i -e 's/^FONTFACE=.*/FONTFACE="Terminus"/' -e 's/^FONTSIZE=.*/FONTSIZE="16x32"/' /etc/default/console-setup
    setfont "$f" 2>/dev/null || sudo setfont "$f" || note "setfont failed (not on a console?); it applies after a reboot"
}

# ---------------------------------------------------------------- 2
about_network="Install NetworkManager and take the network over from ifupdown
  (/etc/network/interfaces). The connection drops for a few seconds."
step_network() {
    local f=/etc/network/interfaces ifaces ssid psk
    sudo apt-get install -y network-manager
    ifaces=$(sudo awk '$1 == "iface" && $2 != "lo" { print $2 }' "$f" | sort -u)
    if [ -z "$ifaces" ]; then
        note "ifupdown manages no interface, nothing to hand over"
    else
        note "ifupdown manages: $(echo "$ifaces" | tr '\n' ' ')"
        ssid=$(sudo awk '$1 == "wpa-ssid" { $1 = ""; sub(/^ +/, ""); gsub(/^"|"$/, ""); print; exit }' "$f")
        psk=$(sudo awk '$1 == "wpa-psk" { $1 = ""; sub(/^ +/, ""); gsub(/^"|"$/, ""); print; exit }' "$f")
        for i in $ifaces; do sudo ifdown --force "$i" 2>/dev/null || true; done
        # Rewritten, not commented out: the old block holds the Wi-Fi password.
        printf 'source /etc/network/interfaces.d/*\n\nauto lo\niface lo inet loopback\n' | sudo tee "$f" >/dev/null
        sudo systemctl restart NetworkManager
        sleep 5
        if [ -n "$ssid" ]; then
            note "reconnecting to Wi-Fi \"$ssid\""
            nmcli dev wifi rescan 2>/dev/null || true; sleep 5
            if [ -n "$psk" ]; then
                sudo nmcli dev wifi connect "$ssid" password "$psk" ||
                    sudo nmcli dev wifi connect "$ssid" --ask
            else
                sudo nmcli dev wifi connect "$ssid" --ask
            fi
        fi
    fi
    nm-online -t 30 >/dev/null || die "no connection. Try: nmtui   then re-run this step"
    note "online: $(nmcli -t -f DEVICE,STATE dev | grep ':connected' | tr '\n' ' ')"
}

# ---------------------------------------------------------------- 3
about_packages="Debian packages for a first session: terminal (alacritty), launcher
  (fuzzel), clipboard, audio, portals, fonts, plus what the Nix installer needs."
step_packages() {
    sudo apt-get install -y curl xz-utils git gnupg \
        alacritty fuzzel wl-clipboard pipewire-audio \
        xdg-desktop-portal-gtk xdg-desktop-portal-gnome \
        fonts-noto-color-emoji adwaita-icon-theme
}

# ---------------------------------------------------------------- 4
about_browser="Firefox from Mozilla's apt repo (pinned to firefox* only).
  Falls back to Debian's firefox-esr if the repo setup fails."
step_browser() {
    if mozilla_repo; then
        sudo apt-get install -y firefox && return 0
    fi
    note "Mozilla repo did not work, installing firefox-esr instead"
    sudo rm -f /etc/apt/sources.list.d/mozilla.list
    sudo apt-get update
    sudo apt-get install -y firefox-esr
}
mozilla_repo() {
    local key=/etc/apt/keyrings/packages.mozilla.org.asc want=35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3 got
    sudo install -d -m 0755 /etc/apt/keyrings || return 1
    curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg | sudo tee "$key" >/dev/null || return 1
    got=$(gpg -n -q --import --import-options import-show --with-colons "$key" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')
    [ "$got" = "$want" ] || { note "key fingerprint mismatch: $got"; sudo rm -f "$key"; return 1; }
    echo "deb [signed-by=$key] https://packages.mozilla.org/apt mozilla main" | sudo tee /etc/apt/sources.list.d/mozilla.list >/dev/null
    printf 'Package: firefox*\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' | sudo tee /etc/apt/preferences.d/mozilla >/dev/null
    sudo apt-get update
}

# ---------------------------------------------------------------- 5
about_nix="Single-user Nix (no daemon) into /nix, flakes enabled, and the
  profile scripts sourced from the top of ~/.bashrc."
step_nix() {
    [ -d /nix ] || die "/nix does not exist"
    [ -w /nix ] || { note "/nix is not yours, fixing ownership"; sudo chown "$(id -u):$(id -g)" /nix; }
    if [ ! -e "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
        curl -L https://nixos.org/nix/install | sh -s -- --no-daemon
    else
        note "nix already installed"
    fi
    mkdir -p "$HOME/.config/nix"
    grep -qs 'experimental-features' "$HOME/.config/nix/nix.conf" ||
        echo 'experimental-features = nix-command flakes' >> "$HOME/.config/nix/nix.conf"
    if ! grep -qs 'homelab desktop.sh' "$HOME/.bashrc"; then
        {
            echo '# nix + home-manager session (homelab desktop.sh); both have re-entry guards'
            echo '[ -e ~/.nix-profile/etc/profile.d/nix.sh ] && . ~/.nix-profile/etc/profile.d/nix.sh'
            echo '[ -e ~/.nix-profile/etc/profile.d/hm-session-vars.sh ] && . ~/.nix-profile/etc/profile.d/hm-session-vars.sh'
            echo
            cat "$HOME/.bashrc" 2>/dev/null
        } > "$HOME/.bashrc.new" && mv "$HOME/.bashrc.new" "$HOME/.bashrc"
    fi
    load_nix
    nix --version
}

# ---------------------------------------------------------------- 6
about_home_manager="Home Manager from a flake in ~/.config/home-manager, with niri and
  xwayland-satellite. First run downloads a lot; give it time."
step_home_manager() {
    local d="$HOME/.config/home-manager" sv
    load_nix
    [ -f "$d/flake.nix" ] || nix run home-manager/master -- init
    [ -f "$d/home.nix" ] || die "$d/home.nix was not generated"
    if grep -q 'niri' "$d/home.nix"; then
        note "home.nix already lists niri, leaving it alone"
    else
        sv=$(sed -n 's/.*home\.stateVersion *= *"\([^"]*\)".*/\1/p' "$d/home.nix" | head -n1)
        [ -n "$sv" ] || die "could not read home.stateVersion from $d/home.nix"
        cp -a "$d/home.nix" "$d/home.nix.init"
        cat > "$d/home.nix" <<EOF
{ config, pkgs, ... }:
{
  home.username = "$USER";
  home.homeDirectory = "$HOME";
  home.stateVersion = "$sv";            # what init wrote, never bump

  targets.genericLinux.enable = true;  # also enables the GPU module

  home.packages = with pkgs; [
    niri
    xwayland-satellite
    # later: chromium logseq rclone
  ];

  programs.home-manager.enable = true;
}
EOF
        note "wrote $d/home.nix (generated one kept as home.nix.init)"
    fi
    mkdir -p "$(dirname "$SWITCH_LOG")"
    nix run home-manager/master -- switch 2>&1 | tee "$SWITCH_LOG"
    [ "${PIPESTATUS[0]}" -eq 0 ] || die "home-manager switch failed, see above"
    [ -x "$HOME/.nix-profile/bin/niri" ] || die "niri is not in ~/.nix-profile/bin after the switch"
}

# ---------------------------------------------------------------- 7
about_gpu="Link the Nix Mesa drivers into /run/opengl-driver (non-nixos-gpu-setup).
  Without it niri starts to a black screen."
step_gpu() {
    local cmd
    cmd=$(grep -o '/nix/store/[^ ]*non-nixos-gpu-setup' "$SWITCH_LOG" 2>/dev/null | tail -n1)
    if [ -z "$cmd" ]; then
        set -- /nix/store/*-non-nixos-gpu/bin/non-nixos-gpu-setup
        if [ $# -eq 1 ] && [ -x "$1" ]; then cmd=$1; fi
    fi
    if [ -z "$cmd" ]; then
        [ -e /run/opengl-driver ] && { note "/run/opengl-driver already there, nothing to do"; return 0; }
        die "could not find non-nixos-gpu-setup. Run 'home-manager switch' and use the sudo command it prints"
    fi
    note "running: sudo $cmd"
    sudo "$cmd"
    [ -e /run/opengl-driver ] || sudo systemd-tmpfiles --create 2>/dev/null || true
    [ -e /run/opengl-driver ] || note "WARNING: /run/opengl-driver still missing; reboot before starting niri"
}

# ---------------------------------------------------------------- 8
about_niri_session="Make niri's systemd user units visible to the user manager, so
  niri-session works from a TTY (the units live in the Nix profile)."
step_niri_session() {
    local src="$HOME/.nix-profile/share/systemd/user" dst="$HOME/.config/systemd/user" f
    for f in niri.service niri-shutdown.target; do
        [ -e "$src/$f" ] || die "$src/$f not found: is niri installed (home_manager step)?"
    done
    mkdir -p "$dst/niri.service.d"
    for f in niri.service niri-shutdown.target; do ln -sfn "$src/$f" "$dst/$f"; done
    printf '[Service]\nExecStart=\nExecStart=%%h/.nix-profile/bin/niri --session\n' > "$dst/niri.service.d/override.conf"
    systemctl --user daemon-reload
    systemctl --user cat niri.service >/dev/null || die "the user manager still cannot see niri.service"
    note "niri.service is visible to systemd --user"
}

# ---------------------------------------------------------------- 9
about_start="Start niri. Keys (Mod = Super):
    Mod+T terminal    Mod+D launcher    Mod+Shift+/ all key bindings
    Mod+Q close window    Mod+Shift+E quit niri
  If the screen stays black: Ctrl+Alt+F2, log in, run this script with 'gpu'.
  Fallback if niri-session complains: niri --session"
step_start() {
    load_nix
    [ -z "${WAYLAND_DISPLAY:-}" ] || { note "already inside a Wayland session"; return 0; }
    niri-session
}

# ---------------------------------------------------------------- driver
n=0; for s in $STEPS; do n=$((n + 1)); done; total=$n

list() { n=0; for s in $STEPS; do n=$((n + 1)); a="about_$s"; printf '%2d  %-14s %s\n' "$n" "$s" "$(echo "${!a}" | head -n1)"; done; }

case "${1:-1}" in
    --list|-l) list; exit 0 ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

[ "$(id -u)" -ne 0 ] || die "run this as your normal user, not root"

# start point: a number or a step name
start=${1:-1}
case "$start" in
    *[!0-9]*) n=0; found=""; for s in $STEPS; do n=$((n + 1)); [ "$s" = "$start" ] && found=$n; done
              [ -n "$found" ] || { list; die "unknown step: $start"; }; start=$found ;;
esac
[ "$start" -ge 1 ] && [ "$start" -le "$total" ] || { list; die "step must be 1..$total"; }

n=0
for s in $STEPS; do
    n=$((n + 1)); [ "$n" -ge "$start" ] || continue
    a="about_$s"
    say "[$n/$total] $s"
    printf '  %s\n' "${!a}"
    printf '\n  Enter = run, s = skip, q = quit > '
    read -r ans || ans=q
    case "$ans" in
        s|S) note "skipped"; continue ;;
        q|Q) note "stopped. Resume with: bash $0 $n"; exit 0 ;;
    esac
    # not inside an "if": errexit is ignored there, even in a subshell
    ( set -e; "step_$s" ); rc=$?
    if [ "$rc" -eq 0 ]; then
        note "done: $s"
    else
        printf '\n\033[1;31mStep %d (%s) failed.\033[0m Fix it, then resume with: bash %s %d\n' "$n" "$s" "$0" "$n" >&2
        exit 1
    fi
done
say "All steps done."
