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
EXT_UUID="teamtalk-ctrl-ptt-v3@joao465"
OLD_EXT_UUIDS=("teamtalk-ctrl-ptt@joao465" "teamtalk-ctrl-ptt-v2@joao465")
EXT_DIR="$EXT_BASE/$EXT_UUID"

log() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERRO: %s\n' "$*" >&2; exit 1; }
cleanup() { [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR:-}" ]] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT

[[ "$(uname -s)" == "Linux" ]] || die "Este instalador é somente para Linux."
[[ "$(uname -m)" == "x86_64" ]] || die "Esta build é somente x86_64."
source /etc/os-release
[[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "26.04" ]] || die "Esta build foi preparada para Ubuntu 26.04 LTS."

# Replacing files while the previous client is still running leaves the old
# process owning org.teamtalk.CtrlPTT. Require a clean restart instead.
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
EXT_SOURCE="$PACKAGE_ROOT/gnome-extension"
[[ -f "$EXT_SOURCE/metadata.json" && -f "$EXT_SOURCE/extension.js" ]] || die "Extensão GNOME não encontrada no pacote."

grep -q "\"uuid\": \"$EXT_UUID\"" "$EXT_SOURCE/metadata.json" || die "O pacote não contém a extensão GNOME v3 esperada."

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

log "Instalando a extensão GNOME Ctrl PTT v3"
mkdir -p "$EXT_BASE"
for old_uuid in "${OLD_EXT_UUIDS[@]}"; do
    if command -v gnome-extensions >/dev/null 2>&1; then
        gnome-extensions disable "$old_uuid" >/dev/null 2>&1 || true
    fi
    rm -rf "$EXT_BASE/$old_uuid"
done
if command -v gnome-extensions >/dev/null 2>&1; then
    gnome-extensions disable "$EXT_UUID" >/dev/null 2>&1 || true
fi
rm -rf "$EXT_DIR"
cp -a "$EXT_SOURCE" "$EXT_DIR"

# Keep the fresh UUID enabled in Shell settings even if the running Shell only
# discovers it after the next login.
python3 - "$EXT_UUID" "${OLD_EXT_UUIDS[@]}" <<'PY'
import subprocess, sys
new = sys.argv[1]
old = set(sys.argv[2:])
try:
    current = subprocess.check_output(
        ["gsettings", "get", "org.gnome.shell", "enabled-extensions"],
        text=True,
    )
    # Use gsettings itself for the final write; parse the simple string array
    # with ast.literal_eval after replacing GVariant's @as prefix if present.
    import ast
    text = current.strip()
    if text.startswith('@as '):
        text = text[4:]
    values = list(ast.literal_eval(text))
    values = [x for x in values if x not in old and x != new]
    values.append(new)
    rendered = '[' + ', '.join(repr(x) for x in values) + ']'
    subprocess.check_call(["gsettings", "set", "org.gnome.shell", "enabled-extensions", rendered])
except Exception as exc:
    print(f"Aviso: não foi possível atualizar enabled-extensions automaticamente: {exc}")
PY

if command -v gnome-extensions >/dev/null 2>&1; then
    gnome-extensions enable "$EXT_UUID" >/dev/null 2>&1 || true
fi

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
printf 'Extensão: %s\n' "$EXT_UUID"
printf 'Comando: %s\n' "$LAUNCHER"

if command -v gnome-extensions >/dev/null 2>&1 && gnome-extensions list --active 2>/dev/null | grep -Fxq "$EXT_UUID"; then
    printf 'Extensão GNOME: ativa nesta sessão.\n'
else
    printf 'Extensão GNOME: instalada e habilitada para a próxima sessão.\n'
    printf 'Saia da sessão do GNOME e entre novamente uma vez antes de testar o Ctrl.\n'
fi

printf '\nDepois de abrir o TeamTalk, execute diagnose-ctrl-ptt.sh se o Ctrl ainda não responder.\n'
