#!/usr/bin/env bash
set -u

EXT_UUID="teamtalk-ctrl-ptt-v3@joao465"
APP_DIR="${TEAMTALK_LINUX_APP_DIR:-$HOME/.local/opt/teamtalk5-linux-ctrlptt}"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
EXT_DIR="$DATA_HOME/gnome-shell/extensions/$EXT_UUID"

printf '=== Diagnóstico TeamTalk Ctrl PTT ===\n'
printf 'Sessão: %s\n' "${XDG_SESSION_TYPE:-desconhecida}"
printf 'Desktop: %s\n' "${XDG_CURRENT_DESKTOP:-desconhecido}"
if command -v gnome-shell >/dev/null 2>&1; then
    gnome-shell --version 2>/dev/null || true
fi

printf '\n1. Arquivos instalados\n'
if [[ -x "$APP_DIR/teamtalk5" ]]; then
    printf 'TeamTalk: OK - %s\n' "$APP_DIR/teamtalk5"
else
    printf 'TeamTalk: AUSENTE\n'
fi
if [[ -f "$EXT_DIR/metadata.json" && -f "$EXT_DIR/extension.js" ]]; then
    printf 'Extensão v3: OK - %s\n' "$EXT_DIR"
else
    printf 'Extensão v3: AUSENTE\n'
fi

printf '\n2. Estado da extensão GNOME\n'
if command -v gnome-extensions >/dev/null 2>&1; then
    if gnome-extensions list --active 2>/dev/null | grep -Fxq "$EXT_UUID"; then
        printf 'Extensão ativa: SIM\n'
    else
        printf 'Extensão ativa: NÃO\n'
    fi
    printf 'Detalhes:\n'
    gnome-extensions info "$EXT_UUID" 2>&1 || true
else
    printf 'Comando gnome-extensions não encontrado.\n'
fi

printf '\n3. Serviço D-Bus do TeamTalk\n'
if command -v gdbus >/dev/null 2>&1; then
    if gdbus introspect --session \
        --dest org.teamtalk.CtrlPTT \
        --object-path /org/teamtalk/CtrlPTT >/tmp/teamtalk-ctrlptt-introspect.$$ 2>/tmp/teamtalk-ctrlptt-error.$$; then
        printf 'Serviço D-Bus: OK\n'
        if grep -q 'getGnomeCtrlPttStatus' /tmp/teamtalk-ctrlptt-introspect.$$; then
            printf 'Método de diagnóstico: OK\n'
            printf 'Estado informado pelo TeamTalk: '
            gdbus call --session \
                --dest org.teamtalk.CtrlPTT \
                --object-path /org/teamtalk/CtrlPTT \
                --method org.teamtalk.CtrlPTT.getGnomeCtrlPttStatus 2>&1 || true
        else
            printf 'Método de diagnóstico: AUSENTE - o TeamTalk aberto parece ser uma build antiga.\n'
        fi
    else
        printf 'Serviço D-Bus: NÃO ENCONTRADO\n'
        cat /tmp/teamtalk-ctrlptt-error.$$ 2>/dev/null || true
        printf 'Abra o TeamTalk Linux novo e execute este diagnóstico novamente.\n'
    fi
    rm -f /tmp/teamtalk-ctrlptt-introspect.$$ /tmp/teamtalk-ctrlptt-error.$$
else
    printf 'gdbus não encontrado.\n'
fi

printf '\n4. Teste de captura do Ctrl\n'
printf 'Pressione e solte o CTRL ESQUERDO algumas vezes nos próximos 5 segundos.\n'
sleep 5
printf 'Últimos registros da extensão:\n'
LOGS=""
if command -v journalctl >/dev/null 2>&1; then
    LOGS="$(journalctl --user -b --no-pager 2>/dev/null | grep 'TeamTalk Ctrl PTT v3:' | tail -n 20 || true)"
    if [[ -z "$LOGS" ]]; then
        LOGS="$(journalctl -b --no-pager 2>/dev/null | grep 'TeamTalk Ctrl PTT v3:' | tail -n 20 || true)"
    fi
fi
if [[ -n "$LOGS" ]]; then
    printf '%s\n' "$LOGS"
else
    printf 'Nenhum registro v3 encontrado. Se a extensão aparece ativa, isso indica que ela não está capturando o Ctrl ou que o GNOME ainda não carregou o código novo.\n'
fi

printf '\n=== Interpretação rápida ===\n'
printf 'Extensão ativa NÃO -> problema no carregamento da extensão.\n'
printf 'Extensão ativa SIM + sem logs de Ctrl -> problema na captura do GNOME.\n'
printf 'Logs de Ctrl + D-Bus falhando -> problema na comunicação com o TeamTalk.\n'
printf 'D-Bus OK + status ptt=off/ctrlOnly=no -> problema na configuração do atalho dentro do TeamTalk.\n'
printf 'Tudo OK + sem transmissão -> problema dentro da ativação de voz do cliente, e os logs do TeamTalk indicarão o retorno de TT_EnableVoiceTransmission.\n'
