#!/usr/bin/env bash
set -e

DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
EXT_BASE="$DATA_HOME/gnome-shell/extensions"
EXTENSIONS=(
    "teamtalk-ctrl-ptt@joao465"
    "teamtalk-ctrl-ptt-v2@joao465"
    "teamtalk-ctrl-ptt-v3@joao465"
)

if [[ "$EUID" -eq 0 ]]; then
    SUDO=""
else
    SUDO="sudo"
fi

if command -v systemctl >/dev/null 2>&1; then
    $SUDO systemctl disable --now teamtalk-ctrl-ptt-input.service >/dev/null 2>&1 || true
fi
$SUDO rm -f /etc/systemd/system/teamtalk-ctrl-ptt-input.service
$SUDO rm -rf /usr/local/lib/teamtalk-ctrl-ptt
$SUDO rm -rf /run/teamtalk-ctrl-ptt
if command -v systemctl >/dev/null 2>&1; then
    $SUDO systemctl daemon-reload >/dev/null 2>&1 || true
fi

for uuid in "${EXTENSIONS[@]}"; do
    if command -v gnome-extensions >/dev/null 2>&1; then
        gnome-extensions disable "$uuid" >/dev/null 2>&1 || true
    fi
    rm -rf "$EXT_BASE/$uuid"
done

rm -rf "$HOME/.local/opt/teamtalk5-linux-ctrlptt"
rm -f "$HOME/.local/bin/teamtalk5-linux"
rm -f "$DATA_HOME/applications/teamtalk5-linux.desktop"

printf 'TeamTalk Linux, extensões antigas e helper Ctrl PTT removidos.\n'
printf 'A configuração foi preservada em %s\n' \
       "${XDG_CONFIG_HOME:-$HOME/.config}/teamtalk5-linux-ctrlptt"
