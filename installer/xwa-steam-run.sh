#!/bin/bash
# Steam launch-options wrapper for X-Wing Alliance + XWAU 2025.
#
# Used as a launch-options PREFIX: `... "<game>/xwa-steam-run.sh" %command%`.
# A launch-options prefix runs on the HOST (outside the Proton / pressure-vessel
# container, same as gamescope/mangohud), so it can touch host GNOME settings.
#
# On the first launch the game window is briefly unresponsive while DXVK compiles
# its shader cache, and GNOME then pops the "not responding — Wait / Force Quit"
# dialog. Silence that dialog for the duration of the game only, then restore the
# previous value. No-op off GNOME or without gsettings.
set -u
_CA_RESTORE=""
if command -v gsettings >/dev/null 2>&1 &&
   gsettings get org.gnome.mutter check-alive-timeout >/dev/null 2>&1; then
    _CA_OLD="$(gsettings get org.gnome.mutter check-alive-timeout 2>/dev/null)"
    if gsettings set org.gnome.mutter check-alive-timeout 0 2>/dev/null; then
        _CA_RESTORE="$_CA_OLD"
    fi
fi
_restore() { [ -n "$_CA_RESTORE" ] && gsettings set org.gnome.mutter check-alive-timeout "$_CA_RESTORE" 2>/dev/null || true; }
trap _restore EXIT INT TERM

"$@"                 # run the real %command% (enters the Proton container)
rc=$?
_restore; trap - EXIT INT TERM
exit "$rc"
