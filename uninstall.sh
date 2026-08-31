#!/usr/bin/env bash
set -e

DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
EXT_BASE="$DATA_HOME/gnome-shell/extensions"
EXTENSIONS=(
    "teamtalk-ctrl-ptt@joao465"
    "teamtalk-ctrl-ptt-v2@joao465"
    "teamtalk-ctrl-ptt-v3@joao465"
)

for uuid in "${EXTENSIONS[@]}"; do
    if command -v gnome-extensions >/dev/null 2>&1; then
        gnome-extensions disable "$uuid" >/dev/null 2>&1 || true
    fi
    rm -rf "$EXT_BASE/$uuid"
done

rm -rf "$HOME/.local/opt/teamtalk5-linux-ctrlptt"
rm -f "$HOME/.local/bin/teamtalk5-linux"
rm -f "$DATA_HOME/applications/teamtalk5-linux.desktop"

printf 'TeamTalk Linux e extensões Ctrl PTT removidos.\n'
printf 'A configuração foi preservada em %s\n' \
       "${XDG_CONFIG_HOME:-$HOME/.config}/teamtalk5-linux-ctrlptt"
