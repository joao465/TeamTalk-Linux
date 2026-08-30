#!/usr/bin/env bash
set -e
rm -rf "$HOME/.local/opt/teamtalk5-linux-ctrlptt"
rm -f "$HOME/.local/bin/teamtalk5-linux"
rm -f "${XDG_DATA_HOME:-$HOME/.local/share}/applications/teamtalk5-linux.desktop"
printf 'TeamTalk Linux removido. A configuração foi preservada em %s\n' \
       "${XDG_CONFIG_HOME:-$HOME/.config}/teamtalk5-linux-ctrlptt"
