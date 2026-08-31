#!/usr/bin/env bash
set -u

APP_DIR="${TEAMTALK_LINUX_APP_DIR:-$HOME/.local/opt/teamtalk5-linux-ctrlptt}"
SOCKET="/run/teamtalk-ctrl-ptt/input.sock"
SERVICE="teamtalk-ctrl-ptt-input.service"

printf '=== Diagnóstico TeamTalk Ctrl PTT ===\n'
printf 'Sessão: %s\n' "${XDG_SESSION_TYPE:-desconhecida}"
printf 'Desktop: %s\n' "${XDG_CURRENT_DESKTOP:-desconhecido}"
if command -v gnome-shell >/dev/null 2>&1; then
    gnome-shell --version 2>/dev/null || true
fi

printf '\n1. TeamTalk instalado\n'
if [[ -x "$APP_DIR/teamtalk5" ]]; then
    printf 'TeamTalk: OK - %s\n' "$APP_DIR/teamtalk5"
else
    printf 'TeamTalk: AUSENTE\n'
fi

printf '\n2. Helper Linux KEY_LEFTCTRL\n'
if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
    printf 'Serviço do helper: ATIVO\n'
else
    printf 'Serviço do helper: INATIVO ou AUSENTE\n'
    systemctl status "$SERVICE" --no-pager 2>&1 | head -n 20 || true
fi

if [[ -S "$SOCKET" ]]; then
    printf 'Socket do helper: OK - %s\n' "$SOCKET"
else
    printf 'Socket do helper: AUSENTE - %s\n' "$SOCKET"
fi

printf '\n3. Teste direto do Ctrl esquerdo\n'
if [[ -S "$SOCKET" ]]; then
    printf 'Pressione e solte o CTRL ESQUERDO algumas vezes nos próximos 5 segundos.\n'
    python3 - "$SOCKET" <<'PY'
import socket, sys, time
path = sys.argv[1]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    s.connect(path)
    s.settimeout(0.25)
    end = time.monotonic() + 5.0
    buf = b''
    seen = []
    while time.monotonic() < end:
        try:
            data = s.recv(128)
            if not data:
                print('Helper fechou a conexão inesperadamente.')
                break
            buf += data
            while b'\n' in buf:
                line, buf = buf.split(b'\n', 1)
                if line in (b'0', b'1'):
                    value = line.decode()
                    seen.append(value)
                    print('Estado KEY_LEFTCTRL:', 'PRESSIONADO' if value == '1' else 'SOLTO')
        except socket.timeout:
            pass
    transitions = sum(a != b for a, b in zip(seen, seen[1:]))
    print(f'Transições observadas: {transitions}')
    if transitions == 0:
        print('RESULTADO HELPER: FALHA - nenhuma mudança do Ctrl esquerdo foi observada.')
    else:
        print('RESULTADO HELPER: OK - o Ctrl esquerdo chegou ao helper.')
finally:
    s.close()
PY
else
    printf 'Teste não executado porque o socket não existe.\n'
fi

printf '\n4. Receptor do TeamTalk\n'
if command -v gdbus >/dev/null 2>&1; then
    if gdbus introspect --session \
        --dest org.teamtalk.CtrlPTT \
        --object-path /org/teamtalk/CtrlPTT >/tmp/teamtalk-ctrlptt-introspect.$$ 2>/tmp/teamtalk-ctrlptt-error.$$; then
        printf 'Serviço D-Bus de diagnóstico do TeamTalk: OK\n'
        if grep -q 'getGnomeCtrlPttStatus' /tmp/teamtalk-ctrlptt-introspect.$$; then
            printf 'Método de diagnóstico: OK\n'
            printf 'Estado informado pelo TeamTalk: '
            gdbus call --session \
                --dest org.teamtalk.CtrlPTT \
                --object-path /org/teamtalk/CtrlPTT \
                --method org.teamtalk.CtrlPTT.getGnomeCtrlPttStatus 2>&1 || true
        else
            printf 'Método de diagnóstico: AUSENTE - o TeamTalk aberto é antigo.\n'
        fi
    else
        printf 'Serviço D-Bus do TeamTalk: NÃO ENCONTRADO\n'
        cat /tmp/teamtalk-ctrlptt-error.$$ 2>/dev/null || true
        printf 'Abra o TeamTalk novo e execute o diagnóstico novamente.\n'
    fi
    rm -f /tmp/teamtalk-ctrlptt-introspect.$$ /tmp/teamtalk-ctrlptt-error.$$
else
    printf 'gdbus não encontrado.\n'
fi

printf '\n=== Interpretação objetiva ===\n'
printf 'Helper INATIVO/socket AUSENTE -> falha na instalação do serviço Linux.\n'
printf 'Helper ativo + 0 transições -> falha na leitura KEY_LEFTCTRL; não é problema do TeamTalk.\n'
printf 'Helper com transições + inputHelper=disconnected -> TeamTalk não conectou ao socket.\n'
printf 'Helper com transições + inputHelper=connected + ptt=off/ctrlOnly=no -> configuração do PTT.\n'
printf 'Tudo acima OK e sem voz -> falha dentro da ativação de voz; então testamos TT_EnableVoiceTransmission diretamente.\n'
