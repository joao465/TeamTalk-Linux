#!/usr/bin/env bash
set -Eeuo pipefail

# TeamTalk5-Linux installer.
# Downloads a prebuilt GitHub Release. It does NOT build locally and
# does NOT modify TeamTalk5Pro.

REPO="joao465/TeamTalk-Linux"
ASSET="teamtalk-linux-ctrlptt-ubuntu26-x86_64.tgz"
API="https://api.github.com/repos/$REPO/releases/latest"

APP_DIR="${TEAMTALK_LINUX_APP_DIR:-$HOME/.local/opt/teamtalk5-linux-ctrlptt}"
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/teamtalk5-linux-ctrlptt"
BIN_DIR="$HOME/.local/bin"
DESKTOP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
LAUNCHER="$BIN_DIR/teamtalk5-linux"
DESKTOP_FILE="$DESKTOP_DIR/teamtalk5-linux.desktop"

log() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERRO: %s\n' "$*" >&2; exit 1; }

cleanup() {
    [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR:-}" ]] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT

[[ "$(uname -s)" == "Linux" ]] || die "Este instalador é somente para Linux."
[[ "$(uname -m)" == "x86_64" ]] || die "Esta build é somente x86_64."

source /etc/os-release
[[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "26.04" ]] ||
    die "Esta build foi preparada para Ubuntu 26.04 LTS."

if [[ "$EUID" -eq 0 ]]; then
    SUDO=""
else
    command -v sudo >/dev/null || die "sudo não encontrado."
    SUDO="sudo"
fi

log "Instalando apenas dependências de execução"
$SUDO apt-get update
$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates wget python3 tar \
    libqt6dbus6 libqt6multimedia6 libqt6network6 \
    libqt6texttospeech6 libqt6widgets6 libqt6xml6 \
    libasound2t64 libpulse0 libxss1 qt6-speech-speechd-plugin

log "Localizando a última Release do TeamTalk Linux"
ASSET_URL="$(
python3 - "$API" "$ASSET" <<'PY'
import json, sys, urllib.request
api, wanted = sys.argv[1], sys.argv[2]
try:
    with urllib.request.urlopen(api, timeout=30) as r:
        data = json.load(r)
except Exception as e:
    raise SystemExit(f"Não foi possível consultar a Release: {e}")
for asset in data.get("assets", []):
    if asset.get("name") == wanted:
        print(asset["browser_download_url"])
        break
else:
    raise SystemExit(f"Asset {wanted!r} não encontrado na última Release.")
PY
)" || die "Ainda não existe uma Release pronta no repositório $REPO."

TMP_DIR="$(mktemp -d)"
ARCHIVE="$TMP_DIR/$ASSET"

log "Baixando o cliente já compilado"
wget --show-progress -O "$ARCHIVE" "$ASSET_URL"
tar -tzf "$ARCHIVE" >/dev/null || die "Arquivo baixado inválido."

mkdir -p "$TMP_DIR/extract"
tar -xzf "$ARCHIVE" -C "$TMP_DIR/extract"
CLIENT_DIR="$(find "$TMP_DIR/extract" -type f -path '*/client/teamtalk5' -printf '%h\n' -quit)"
[[ -n "$CLIENT_DIR" ]] || die "Executável teamtalk5 não encontrado no pacote."

log "Instalando em $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR"
cp -a "$CLIENT_DIR"/. "$APP_DIR"/
chmod +x "$APP_DIR/teamtalk5"

log "Criando configuração separada do TeamTalk Pro"
mkdir -p "$CFG_DIR"
if [[ ! -f "$CFG_DIR/TeamTalk5.ini" ]]; then
    if [[ -f "$APP_DIR/TeamTalk5.ini.default" ]]; then
        cp "$APP_DIR/TeamTalk5.ini.default" "$CFG_DIR/TeamTalk5.ini"
    else
        : > "$CFG_DIR/TeamTalk5.ini"
    fi
fi

log "Criando comando teamtalk5-linux"
mkdir -p "$BIN_DIR"
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

log "Criando atalho no menu"
mkdir -p "$DESKTOP_DIR"
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=TeamTalk 5 Linux (Ctrl PTT)
Comment=TeamTalk Linux com suporte a Ctrl como Push-to-Talk no X11
Exec=$LAUNCHER
Icon=audio-input-microphone
Terminal=false
Categories=Network;AudioVideo;Audio;
StartupNotify=true
EOF

printf '\n============================================================\n'
printf 'TeamTalk Linux instalado sem compilação local.\n'
printf 'Aplicativo: %s\n' "$APP_DIR"
printf 'Configuração separada: %s\n' "$CFG_DIR/TeamTalk5.ini"
printf 'Comando: %s\n' "$LAUNCHER"
printf 'O TeamTalk5Pro não foi alterado.\n'

if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
    printf '\nATENÇÃO: sua sessão atual é Wayland.\n'
    printf 'Ctrl sozinho como hotkey GLOBAL exige sessão X11/Xorg.\n'
    printf 'O cliente funciona no Wayland, mas essa hotkey global específica não é permitida pelo modelo padrão do Wayland.\n'
fi
