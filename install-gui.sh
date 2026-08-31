#!/usr/bin/env bash
set -Eeuo pipefail

# TeamTalk5 Linux graphical installer for GNOME/GTK.
# Uses Zenity for the interface and pkexec only for system package installation.
# The TeamTalk application itself is installed in the current user's home.

REPO="joao465/TeamTalk-Linux"
ASSET="teamtalk-linux-ctrlptt-ubuntu26-x86_64.tgz"
API="https://api.github.com/repos/$REPO/releases/latest"

APP_DIR="${TEAMTALK_LINUX_APP_DIR:-$HOME/.local/opt/teamtalk5-linux-ctrlptt}"
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/teamtalk5-linux-ctrlptt"
BIN_DIR="$HOME/.local/bin"
DESKTOP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
LAUNCHER="$BIN_DIR/teamtalk5-linux"
DESKTOP_FILE="$DESKTOP_DIR/teamtalk5-linux.desktop"
TITLE="TeamTalk Linux — Instalador"
TMP_DIR=""

cleanup() {
    [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR:-}" ]] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT

plain_error() {
    printf 'ERRO: %s\n' "$*" >&2
    exit 1
}

ensure_zenity() {
    if command -v zenity >/dev/null 2>&1; then
        return
    fi

    [[ "$(uname -s)" == "Linux" ]] || plain_error "Este instalador é somente para Linux."

    if [[ "$EUID" -eq 0 ]]; then
        apt-get update && env DEBIAN_FRONTEND=noninteractive apt-get install -y zenity
    elif command -v pkexec >/dev/null 2>&1; then
        printf 'Zenity não está instalado. Será aberta a autenticação do sistema para instalá-lo.\n'
        pkexec sh -c 'apt-get update && env DEBIAN_FRONTEND=noninteractive apt-get install -y zenity'
    elif command -v sudo >/dev/null 2>&1 && [[ -t 0 ]]; then
        sudo apt-get update
        sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y zenity
    else
        plain_error "Zenity não está instalado e não foi possível abrir um método gráfico de autenticação. Instale o pacote zenity e execute novamente."
    fi

    command -v zenity >/dev/null 2>&1 || plain_error "Não foi possível instalar o Zenity."
}

show_error() {
    zenity --error --title="$TITLE" --width=520 --text="$1" 2>/dev/null || true
}

show_info() {
    zenity --info --title="$TITLE" --width=520 --text="$1" 2>/dev/null || true
}

show_warning() {
    zenity --warning --title="$TITLE" --width=540 --text="$1" 2>/dev/null || true
}

run_with_progress() {
    local heading="$1"
    local message="$2"
    shift 2

    local log_file
    log_file="$(mktemp)"

    set +e
    "$@" >"$log_file" 2>&1 &
    local cmd_pid=$!

    (
        while kill -0 "$cmd_pid" 2>/dev/null; do
            printf '# %s\n' "$message"
            sleep 0.8
        done
        printf '100\n'
    ) | zenity --progress \
        --title="$heading" \
        --text="$message" \
        --pulsate --auto-close --no-cancel \
        --width=520 2>/dev/null
    local zenity_status=${PIPESTATUS[1]}

    wait "$cmd_pid"
    local cmd_status=$?
    set -e

    if [[ "$zenity_status" -ne 0 && "$cmd_status" -eq 0 ]]; then
        rm -f "$log_file"
        return 0
    fi

    if [[ "$cmd_status" -ne 0 ]]; then
        local details
        details="$(tail -n 30 "$log_file" 2>/dev/null || true)"
        rm -f "$log_file"
        show_error "$message\n\nCódigo de erro: $cmd_status\n\n$details"
        return "$cmd_status"
    fi

    rm -f "$log_file"
    return 0
}

run_root_packages() {
    local packages=(
        ca-certificates wget python3 tar
        libqt6dbus6 libqt6multimedia6 libqt6network6
        libqt6texttospeech6 libqt6widgets6 libqt6xml6
        libasound2t64 libpulse0 libxss1 qt6-speech-speechd-plugin
    )

    if [[ "$EUID" -eq 0 ]]; then
        apt-get update
        env DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
        return
    fi

    if command -v pkexec >/dev/null 2>&1; then
        pkexec env DEBIAN_FRONTEND=noninteractive sh -c \
            'apt-get update && apt-get install -y ca-certificates wget python3 tar libqt6dbus6 libqt6multimedia6 libqt6network6 libqt6texttospeech6 libqt6widgets6 libqt6xml6 libasound2t64 libpulse0 libxss1 qt6-speech-speechd-plugin'
        return
    fi

    return 126
}

check_platform() {
    [[ "$(uname -s)" == "Linux" ]] || {
        show_error "Este instalador é somente para Linux."
        exit 1
    }

    [[ "$(uname -m)" == "x86_64" ]] || {
        show_error "Esta build do TeamTalk é somente para computadores x86_64."
        exit 1
    }

    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
    fi

    if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "26.04" ]]; then
        show_error "Esta build foi preparada para Ubuntu 26.04 LTS.\n\nSistema detectado: ${PRETTY_NAME:-desconhecido}."
        exit 1
    fi
}

release_info() {
    python3 - "$API" "$ASSET" <<'PY'
import json, sys, urllib.request
api, wanted = sys.argv[1], sys.argv[2]
with urllib.request.urlopen(api, timeout=30) as r:
    data = json.load(r)
asset = next((a for a in data.get("assets", []) if a.get("name") == wanted), None)
if not asset:
    raise SystemExit(f"Asset {wanted!r} não encontrado na última Release")
print(data.get("tag_name", "desconhecida"))
print(asset["browser_download_url"])
PY
}

install_or_update() {
    if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
        show_warning "Sua sessão atual é Wayland.\n\nO TeamTalk pode ser instalado e usado normalmente, mas Ctrl sozinho como Push-to-Talk GLOBAL requer uma sessão X11/Xorg."
    fi

    run_with_progress "$TITLE" "Instalando dependências necessárias…" run_root_packages || return

    local info tag asset_url
    set +e
    info="$(release_info 2>&1)"
    local info_status=$?
    set -e
    if [[ "$info_status" -ne 0 ]]; then
        show_error "Não foi possível consultar a última Release.\n\n$info"
        return
    fi

    tag="$(printf '%s\n' "$info" | sed -n '1p')"
    asset_url="$(printf '%s\n' "$info" | sed -n '2p')"

    TMP_DIR="$(mktemp -d)"
    local archive="$TMP_DIR/$ASSET"

    run_with_progress "$TITLE" "Baixando TeamTalk Linux $tag…" \
        wget -q -O "$archive" "$asset_url" || return

    if ! tar -tzf "$archive" >/dev/null 2>&1; then
        show_error "O pacote baixado não é um arquivo válido."
        return
    fi

    mkdir -p "$TMP_DIR/extract"
    tar -xzf "$archive" -C "$TMP_DIR/extract"

    local client_dir
    client_dir="$(find "$TMP_DIR/extract" -type f -path '*/client/teamtalk5' -printf '%h\n' -quit)"
    if [[ -z "$client_dir" ]]; then
        show_error "O executável teamtalk5 não foi encontrado dentro do pacote."
        return
    fi

    mkdir -p "$APP_DIR" "$CFG_DIR" "$BIN_DIR" "$DESKTOP_DIR"
    rm -rf "$APP_DIR"
    mkdir -p "$APP_DIR"
    cp -a "$client_dir"/. "$APP_DIR"/
    chmod +x "$APP_DIR/teamtalk5"

    if [[ ! -f "$CFG_DIR/TeamTalk5.ini" ]]; then
        if [[ -f "$APP_DIR/TeamTalk5.ini.default" ]]; then
            cp "$APP_DIR/TeamTalk5.ini.default" "$CFG_DIR/TeamTalk5.ini"
        else
            : > "$CFG_DIR/TeamTalk5.ini"
        fi
    fi

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
Comment=TeamTalk Linux com suporte a Ctrl como Push-to-Talk no X11
Exec=$LAUNCHER
Icon=audio-input-microphone
Terminal=false
Categories=Network;AudioVideo;Audio;
StartupNotify=true
EOF
    chmod +x "$DESKTOP_FILE" 2>/dev/null || true

    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true
    fi

    rm -rf "$TMP_DIR"
    TMP_DIR=""

    if zenity --question --title="$TITLE" --width=520 \
        --ok-label="Abrir TeamTalk" --cancel-label="Concluir" \
        --text="TeamTalk Linux $tag foi instalado com sucesso.\n\nAplicativo: $APP_DIR\nConfiguração: $CFG_DIR/TeamTalk5.ini\n\nDeseja abrir o TeamTalk agora?" 2>/dev/null; then
        "$LAUNCHER" >/dev/null 2>&1 &
    fi
}

uninstall_app() {
    if [[ ! -e "$APP_DIR" && ! -e "$LAUNCHER" && ! -e "$DESKTOP_FILE" ]]; then
        show_info "O TeamTalk Linux não parece estar instalado para este usuário."
        return
    fi

    if ! zenity --question --title="$TITLE" --width=520 \
        --ok-label="Desinstalar" --cancel-label="Cancelar" \
        --text="Deseja remover o TeamTalk Linux?\n\nA configuração será preservada em:\n$CFG_DIR" 2>/dev/null; then
        return
    fi

    rm -rf "$APP_DIR"
    rm -f "$LAUNCHER" "$DESKTOP_FILE"
    show_info "TeamTalk Linux removido.\n\nSua configuração foi preservada em:\n$CFG_DIR"
}

open_app() {
    if [[ ! -x "$LAUNCHER" ]]; then
        show_warning "O TeamTalk Linux ainda não está instalado."
        return
    fi
    "$LAUNCHER" >/dev/null 2>&1 &
}

main_menu() {
    local installed="Não"
    [[ -x "$APP_DIR/teamtalk5" ]] && installed="Sim"
    local session="${XDG_SESSION_TYPE:-desconhecida}"

    while true; do
        local choice
        set +e
        choice="$(zenity --list --title="$TITLE" --width=620 --height=390 \
            --text="TeamTalk Linux com Ctrl sozinho como PTT no X11\n\nInstalado: $installed    Sessão: $session" \
            --radiolist --column="" --column="Ação" --column="Descrição" \
            TRUE "Instalar / Atualizar" "Baixa a Release mais recente e instala para este usuário" \
            FALSE "Abrir TeamTalk" "Inicia o TeamTalk Linux instalado" \
            FALSE "Desinstalar" "Remove o aplicativo e preserva sua configuração" \
            --ok-label="Continuar" --cancel-label="Fechar" 2>/dev/null)"
        local status=$?
        set -e

        [[ "$status" -eq 0 ]] || break

        case "$choice" in
            "Instalar / Atualizar")
                install_or_update
                [[ -x "$APP_DIR/teamtalk5" ]] && installed="Sim"
                ;;
            "Abrir TeamTalk")
                open_app
                ;;
            "Desinstalar")
                uninstall_app
                [[ -x "$APP_DIR/teamtalk5" ]] || installed="Não"
                ;;
            *)
                break
                ;;
        esac
    done
}

ensure_zenity
check_platform
main_menu
