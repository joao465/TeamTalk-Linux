#!/usr/bin/env bash
set -Eeuo pipefail

REPO="joao465/TeamTalk-Linux"
ASSET="teamtalk-linux-ctrlptt-ubuntu26-x86_64.tgz"
API="https://api.github.com/repos/$REPO/releases/latest"

APP_DIR="${TEAMTALK_LINUX_APP_DIR:-$HOME/.local/opt/teamtalk5-linux-ctrlptt}"
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/teamtalk5-linux-ctrlptt"
BIN_DIR="$HOME/.local/bin"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
DESKTOP_DIR="$DATA_HOME/applications"
LAUNCHER="$BIN_DIR/teamtalk5-linux"
DESKTOP_FILE="$DESKTOP_DIR/teamtalk5-linux.desktop"
EXT_BASE="$DATA_HOME/gnome-shell/extensions"
OLD_EXT_UUIDS=(
    "teamtalk-ctrl-ptt@joao465"
    "teamtalk-ctrl-ptt-v2@joao465"
    "teamtalk-ctrl-ptt-v3@joao465"
)
HELPER_INSTALL_DIR="/usr/local/lib/teamtalk-ctrl-ptt"
HELPER_SERVICE="/etc/systemd/system/teamtalk-ctrl-ptt-input.service"

log() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERRO: %s\n' "$*" >&2; exit 1; }
cleanup() { [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR:-}" ]] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT

[[ "$(uname -s)" == "Linux" ]] || die "Este instalador é somente para Linux."
[[ "$(uname -m)" == "x86_64" ]] || die "Esta build é somente x86_64."
source /etc/os-release
[[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "26.04" ]] || die "Esta build foi preparada para Ubuntu 26.04 LTS."

if pgrep -f "$APP_DIR/teamtalk5" >/dev/null 2>&1; then
    die "O TeamTalk Linux está aberto. Feche-o completamente e execute a atualização novamente."
fi

if [[ "$EUID" -eq 0 ]]; then
    SUDO=""
else
    command -v sudo >/dev/null || die "sudo não encontrado."
    SUDO="sudo"
fi

log "Instalando dependências de execução"
$SUDO apt-get update
$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates wget python3 tar \
    libqt6dbus6 libqt6multimedia6 libqt6network6 \
    libqt6texttospeech6 libqt6widgets6 libqt6xml6 \
    libasound2t64 libpulse0 libxss1 qt6-speech-speechd-plugin

log "Localizando a última Release"
readarray -t RELEASE_DATA < <(python3 - "$API" "$ASSET" <<'PY'
import json, sys, urllib.request
api, wanted = sys.argv[1], sys.argv[2]
req = urllib.request.Request(api, headers={"User-Agent":"TeamTalk-Linux-installer"})
with urllib.request.urlopen(req, timeout=30) as r:
    data = json.load(r)
print(data.get("tag_name", "desconhecida"))
for asset in data.get("assets", []):
    if asset.get("name") == wanted:
        print(asset["browser_download_url"])
        break
else:
    raise SystemExit(f"Asset {wanted!r} não encontrado.")
PY
)
[[ ${#RELEASE_DATA[@]} -ge 2 ]] || die "Não foi possível localizar a Release."
TAG="${RELEASE_DATA[0]}"
ASSET_URL="${RELEASE_DATA[1]}"

TMP_DIR="$(mktemp -d)"
ARCHIVE="$TMP_DIR/$ASSET"

log "Baixando TeamTalk $TAG"
wget -q -O "$ARCHIVE" "$ASSET_URL"
tar -tzf "$ARCHIVE" >/dev/null || die "Arquivo baixado inválido."

mkdir -p "$TMP_DIR/extract"
tar -xzf "$ARCHIVE" -C "$TMP_DIR/extract"
CLIENT_DIR="$(find "$TMP_DIR/extract" -type f -path '*/client/teamtalk5' -printf '%h\n' -quit)"
[[ -n "$CLIENT_DIR" ]] || die "Executável teamtalk5 não encontrado no pacote."
PACKAGE_ROOT="$(dirname "$CLIENT_DIR")"
HELPER_SOURCE="$PACKAGE_ROOT/input-helper"
[[ -f "$HELPER_SOURCE/input-helper.py" && -f "$HELPER_SOURCE/teamtalk-ctrl-ptt-input.service" ]] || \
    die "O pacote não contém o helper Linux KEY_LEFTCTRL esperado."

grep -q 'KEY_LEFTCTRL = 29' "$HELPER_SOURCE/input-helper.py" || \
    die "Helper de entrada inválido: KEY_LEFTCTRL não encontrado."

log "Instalando o TeamTalk"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR"
cp -a "$CLIENT_DIR"/. "$APP_DIR"/
chmod +x "$APP_DIR/teamtalk5"

mkdir -p "$CFG_DIR"
if [[ ! -f "$CFG_DIR/TeamTalk5.ini" ]]; then
    if [[ -f "$APP_DIR/TeamTalk5.ini.default" ]]; then
        cp "$APP_DIR/TeamTalk5.ini.default" "$CFG_DIR/TeamTalk5.ini"
    else
        : > "$CFG_DIR/TeamTalk5.ini"
    fi
fi

log "Removendo a antiga extensão GNOME Ctrl PTT"
for uuid in "${OLD_EXT_UUIDS[@]}"; do
    if command -v gnome-extensions >/dev/null 2>&1; then
        gnome-extensions disable "$uuid" >/dev/null 2>&1 || true
    fi
    rm -rf "$EXT_BASE/$uuid"
done

log "Instalando o helper Linux restrito ao Ctrl esquerdo"
$SUDO systemctl stop teamtalk-ctrl-ptt-input.service >/dev/null 2>&1 || true
$SUDO install -d -m 0755 "$HELPER_INSTALL_DIR"
$SUDO install -m 0755 "$HELPER_SOURCE/input-helper.py" "$HELPER_INSTALL_DIR/input-helper.py"
$SUDO install -m 0644 "$HELPER_SOURCE/teamtalk-ctrl-ptt-input.service" "$HELPER_SERVICE"
$SUDO systemctl daemon-reload
$SUDO systemctl enable --now teamtalk-ctrl-ptt-input.service
sleep 1
if ! $SUDO systemctl is-active --quiet teamtalk-ctrl-ptt-input.service; then
    $SUDO journalctl -u teamtalk-ctrl-ptt-input.service -n 30 --no-pager || true
    die "O helper Ctrl PTT não iniciou corretamente."
fi
[[ -S /run/teamtalk-ctrl-ptt/input.sock ]] || \
    die "O helper iniciou, mas o socket /run/teamtalk-ctrl-ptt/input.sock não foi criado."

log "Criando comando e atalho"
mkdir -p "$BIN_DIR" "$DESKTOP_DIR"
cat > "$LAUNCHER" <<EOF
#!/usr/bin/env bash
set -e
APP_DIR="$APP_DIR"
CFG_FILE="$CFG_DIR/TeamTalk5.ini"
export LD_LIBRARY_PATH="\$APP_DIR\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
cd "\$APP_DIR"
exec "\$APP_DIR/teamtalk5" -cfg "\$CFG_FILE" "\$@"
EOF
chmod +x "$LAUNCHER"

cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=TeamTalk 5 Linux (Ctrl PTT)
Comment=TeamTalk Linux com Ctrl esquerdo global como Push-to-Talk
Exec=$LAUNCHER
Icon=audio-input-microphone
Terminal=false
Categories=Network;AudioVideo;Audio;
StartupNotify=true
EOF

printf '\n============================================================\n'
printf 'TeamTalk %s instalado.\n' "$TAG"
printf 'Helper Ctrl esquerdo: ATIVO\n'
printf 'Socket do helper: /run/teamtalk-ctrl-ptt/input.sock\n'
printf 'Comando: %s\n' "$LAUNCHER"
printf '\nNão é necessário sair da sessão do GNOME.\n'
printf 'O helper observa somente KEY_LEFTCTRL; ele não bloqueia nem remapeia a tecla.\n'
printf 'Depois de abrir o TeamTalk, execute diagnose-ctrl-ptt.sh se o Ctrl ainda não responder.\n'
