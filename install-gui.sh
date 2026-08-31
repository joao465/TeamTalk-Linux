#!/usr/bin/env bash
set -Eeuo pipefail

# Orca-friendly installer launcher.
# No custom GTK, Zenity, progress bars, AT-SPI manipulation or focus changes.
# When started from a terminal it uses that terminal directly. When started
# graphically it opens a standard terminal and presents the same text menu.

REPO_RAW="https://raw.githubusercontent.com/joao465/TeamTalk-Linux/main"
SELF="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"

run_menu() {
    while true; do
        printf '\n============================================================\n'
        printf 'TeamTalk Linux - Instalador acessível\n'
        printf '1 - Instalar ou atualizar\n'
        printf '2 - Abrir TeamTalk\n'
        printf '3 - Diagnosticar Ctrl PTT\n'
        printf '4 - Desinstalar\n'
        printf '5 - Sair\n'
        printf '============================================================\n'
        read -r -p 'Escolha uma opção de 1 a 5: ' choice

        case "$choice" in
            1)
                tmp="$(mktemp)"
                if wget -q -O "$tmp" "$REPO_RAW/install.sh"; then
                    bash "$tmp" || true
                else
                    printf 'ERRO: não foi possível baixar install.sh.\n'
                fi
                rm -f "$tmp"
                ;;
            2)
                if [[ -x "$HOME/.local/bin/teamtalk5-linux" ]]; then
                    "$HOME/.local/bin/teamtalk5-linux" >/dev/null 2>&1 &
                    disown || true
                    printf 'TeamTalk iniciado.\n'
                else
                    printf 'TeamTalk ainda não está instalado.\n'
                fi
                ;;
            3)
                tmp="$(mktemp)"
                if wget -q -O "$tmp" "$REPO_RAW/diagnose-ctrl-ptt.sh"; then
                    bash "$tmp"
                else
                    printf 'ERRO: não foi possível baixar o diagnóstico.\n'
                fi
                rm -f "$tmp"
                ;;
            4)
                tmp="$(mktemp)"
                if wget -q -O "$tmp" "$REPO_RAW/uninstall.sh"; then
                    bash "$tmp"
                else
                    printf 'ERRO: não foi possível baixar uninstall.sh.\n'
                fi
                rm -f "$tmp"
                ;;
            5)
                exit 0
                ;;
            *)
                printf 'Opção inválida. Digite um número de 1 a 5.\n'
                ;;
        esac
    done
}

if [[ "${1:-}" == "--terminal-menu" || -t 0 ]]; then
    run_menu
    exit 0
fi

# Graphical launch: use an ordinary terminal application so Orca interacts
# with a well-tested terminal widget instead of a custom installer interface.
if command -v kgx >/dev/null 2>&1; then
    exec kgx -- bash "$SELF" --terminal-menu
elif command -v ptyxis >/dev/null 2>&1; then
    exec ptyxis -- bash "$SELF" --terminal-menu
elif command -v gnome-terminal >/dev/null 2>&1; then
    exec gnome-terminal -- bash "$SELF" --terminal-menu
elif command -v x-terminal-emulator >/dev/null 2>&1; then
    exec x-terminal-emulator -e bash "$SELF" --terminal-menu
fi

printf 'Não encontrei um terminal gráfico. Execute este arquivo a partir de um terminal:\n'
printf 'bash %q\n' "$SELF"
exit 1
