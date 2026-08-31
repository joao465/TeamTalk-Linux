#!/usr/bin/env bash
set -Eeuo pipefail

# Accessible TeamTalk Linux installer for GNOME/Orca.
# Uses native GTK 3 widgets exposed through AT-SPI. Zenity is intentionally
# not used because its dialog roles/progress were not announced reliably by Orca.

ensure_gui_runtime() {
    if python3 - <<'PY' >/dev/null 2>&1
import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk
PY
    then
        return
    fi

    if command -v pkexec >/dev/null 2>&1; then
        pkexec env DEBIAN_FRONTEND=noninteractive sh -c \
            'apt-get update && apt-get install -y python3-gi gir1.2-gtk-3.0 policykit-1'
    elif command -v sudo >/dev/null 2>&1 && [[ -t 0 ]]; then
        sudo apt-get update
        sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
            python3-gi gir1.2-gtk-3.0 policykit-1
    else
        printf '%s\n' \
            'ERRO: a interface GTK não está instalada e não foi possível abrir a autenticação do sistema.' \
            'Instale python3-gi e gir1.2-gtk-3.0 e execute novamente.' >&2
        exit 1
    fi
}

ensure_gui_runtime

python3 - "$@" <<'PY'
import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, GLib

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
import urllib.request

REPO = "joao465/TeamTalk-Linux"
ASSET = "teamtalk-linux-ctrlptt-ubuntu26-x86_64.tgz"
API = f"https://api.github.com/repos/{REPO}/releases/latest"

HOME = Path.home()
DATA_HOME = Path(os.environ.get("XDG_DATA_HOME", HOME / ".local/share"))
APP_DIR = Path(os.environ.get("TEAMTALK_LINUX_APP_DIR",
                              HOME / ".local/opt/teamtalk5-linux-ctrlptt"))
CFG_DIR = Path(os.environ.get("XDG_CONFIG_HOME", HOME / ".config")) / "teamtalk5-linux-ctrlptt"
BIN_DIR = HOME / ".local/bin"
DESKTOP_DIR = DATA_HOME / "applications"
LAUNCHER = BIN_DIR / "teamtalk5-linux"
DESKTOP_FILE = DESKTOP_DIR / "teamtalk5-linux.desktop"
EXT_UUID = "teamtalk-ctrl-ptt@joao465"
EXT_DIR = DATA_HOME / "gnome-shell/extensions" / EXT_UUID

RUNTIME_PACKAGES = [
    "ca-certificates", "wget", "python3", "tar",
    "libqt6dbus6", "libqt6multimedia6", "libqt6network6",
    "libqt6texttospeech6", "libqt6widgets6", "libqt6xml6",
    "libasound2t64", "libpulse0", "libxss1", "qt6-speech-speechd-plugin",
]


def read_os_release():
    data = {}
    try:
        for line in Path("/etc/os-release").read_text(encoding="utf-8").splitlines():
            if "=" in line:
                key, value = line.split("=", 1)
                data[key] = value.strip().strip('"')
    except OSError:
        pass
    return data


class Installer(Gtk.Window):
    def __init__(self):
        super().__init__(title="TeamTalk Linux — Instalador")
        self.set_default_size(680, 390)
        self.set_border_width(18)
        self.connect("destroy", Gtk.main_quit)
        self.busy = False

        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        self.add(outer)

        title = Gtk.Label()
        title.set_markup("<big><b>TeamTalk Linux</b></big>")
        title.set_xalign(0)
        outer.pack_start(title, False, False, 0)

        self.summary = Gtk.Label(
            label="Instalador acessível para GNOME e Orca. "
                  "Use Tab e Shift+Tab para navegar pelos controles."
        )
        self.summary.set_line_wrap(True)
        self.summary.set_xalign(0)
        outer.pack_start(self.summary, False, False, 0)

        session = os.environ.get("XDG_SESSION_TYPE", "desconhecida")
        installed = "Sim" if (APP_DIR / "teamtalk5").is_file() else "Não"
        extension = "Sim" if (EXT_DIR / "extension.js").is_file() else "Não"
        self.info = Gtk.Label(
            label=f"TeamTalk instalado: {installed}. Extensão GNOME: {extension}. Sessão: {session}."
        )
        self.info.set_xalign(0)
        self.info.set_line_wrap(True)
        outer.pack_start(self.info, False, False, 0)

        self.status = Gtk.Label(label="Pronto.")
        self.status.set_xalign(0)
        self.status.set_line_wrap(True)
        self.status.set_selectable(True)
        self.status.get_accessible().set_name("Status da instalação")
        outer.pack_start(self.status, False, False, 0)

        self.progress = Gtk.ProgressBar()
        self.progress.set_show_text(True)
        self.progress.set_text("0% — Pronto")
        self.progress.set_fraction(0.0)
        self.progress.set_can_focus(True)
        acc = self.progress.get_accessible()
        acc.set_name("Progresso da instalação")
        acc.set_description("0 por cento. Pronto.")
        outer.pack_start(self.progress, False, False, 0)

        buttons = Gtk.ButtonBox(orientation=Gtk.Orientation.HORIZONTAL)
        buttons.set_layout(Gtk.ButtonBoxStyle.EXPAND)
        outer.pack_end(buttons, False, False, 0)

        self.install_button = Gtk.Button.new_with_label("Instalar ou atualizar")
        self.open_button = Gtk.Button.new_with_label("Abrir TeamTalk")
        self.uninstall_button = Gtk.Button.new_with_label("Desinstalar")
        self.close_button = Gtk.Button.new_with_label("Fechar")

        self.install_button.get_accessible().set_name("Instalar ou atualizar TeamTalk")
        self.open_button.get_accessible().set_name("Abrir TeamTalk instalado")
        self.uninstall_button.get_accessible().set_name("Desinstalar TeamTalk")
        self.close_button.get_accessible().set_name("Fechar instalador")

        for button in (self.install_button, self.open_button,
                       self.uninstall_button, self.close_button):
            buttons.add(button)

        self.install_button.connect("clicked", self.on_install)
        self.open_button.connect("clicked", self.on_open)
        self.uninstall_button.connect("clicked", self.on_uninstall)
        self.close_button.connect("clicked", lambda *_: Gtk.main_quit())

        self.show_all()
        self.install_button.grab_focus()

        if session.lower() == "wayland":
            GLib.idle_add(self.show_wayland_notice)

    def dialog(self, message_type, text, secondary=None, buttons=Gtk.ButtonsType.OK):
        dlg = Gtk.MessageDialog(
            transient_for=self,
            modal=True,
            destroy_with_parent=True,
            message_type=message_type,
            buttons=buttons,
            text=text,
        )
        if secondary:
            dlg.format_secondary_text(secondary)
        dlg.get_accessible().set_name(text)
        response = dlg.run()
        dlg.destroy()
        return response

    def show_wayland_notice(self):
        self.dialog(
            Gtk.MessageType.INFO,
            "Sessão GNOME Wayland detectada",
            "Esta versão instala uma extensão do GNOME Shell para permitir "
            "Ctrl esquerdo sozinho como Push-to-Talk global. O Ctrl não é bloqueado: "
            "Ctrl+Tab, Ctrl+C e outras combinações continuam funcionando. "
            "Se a extensão não puder ser ativada imediatamente, será necessário "
            "sair e entrar na sessão GNOME uma vez."
        )
        return False

    def set_busy(self, busy):
        self.busy = busy
        for button in (self.install_button, self.open_button,
                       self.uninstall_button, self.close_button):
            button.set_sensitive(not busy)

    def announce(self, text, fraction):
        fraction = max(0.0, min(1.0, fraction))
        percent = int(round(fraction * 100))
        self.status.set_text(text)
        self.progress.set_fraction(fraction)
        self.progress.set_text(f"{percent}% — {text}")
        acc = self.progress.get_accessible()
        acc.set_name(f"Progresso da instalação: {percent} por cento")
        acc.set_description(f"{percent} por cento. {text}")
        self.progress.grab_focus()
        return False

    def finish(self, text):
        self.announce(text, 1.0)
        self.set_busy(False)
        self.install_button.grab_focus()
        return False

    def fail(self, title, details):
        self.set_busy(False)
        self.dialog(Gtk.MessageType.ERROR, title, details)
        self.install_button.grab_focus()
        return False

    def update_installed_label(self):
        installed = "Sim" if (APP_DIR / "teamtalk5").is_file() else "Não"
        extension = "Sim" if (EXT_DIR / "extension.js").is_file() else "Não"
        session = os.environ.get("XDG_SESSION_TYPE", "desconhecida")
        self.info.set_text(
            f"TeamTalk instalado: {installed}. Extensão GNOME: {extension}. Sessão: {session}."
        )
        return False

    def run_cmd(self, args, check=True):
        return subprocess.run(args, text=True, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, check=check)

    def check_platform(self):
        if sys.platform != "linux":
            raise RuntimeError("Este instalador é somente para Linux.")
        if os.uname().machine != "x86_64":
            raise RuntimeError("Esta build é somente para computadores x86_64.")
        release = read_os_release()
        if release.get("ID") != "ubuntu" or release.get("VERSION_ID") != "26.04":
            pretty = release.get("PRETTY_NAME", "sistema desconhecido")
            raise RuntimeError(
                "Esta build foi preparada para Ubuntu 26.04 LTS. "
                f"Sistema detectado: {pretty}."
            )

    def install_packages(self):
        if os.geteuid() == 0:
            self.run_cmd(["apt-get", "update"])
            self.run_cmd(["apt-get", "install", "-y", *RUNTIME_PACKAGES])
            return
        if shutil.which("pkexec"):
            self.run_cmd(["pkexec", "env", "DEBIAN_FRONTEND=noninteractive",
                          "sh", "-c",
                          "apt-get update && apt-get install -y " +
                          " ".join(RUNTIME_PACKAGES)])
            return
        raise RuntimeError(
            "Não foi possível abrir a autenticação gráfica para instalar as dependências."
        )

    def release_info(self):
        req = urllib.request.Request(API, headers={"User-Agent": "TeamTalk-Linux-installer"})
        with urllib.request.urlopen(req, timeout=30) as response:
            data = json.load(response)
        asset = next((a for a in data.get("assets", [])
                      if a.get("name") == ASSET), None)
        if not asset:
            raise RuntimeError(f"O arquivo {ASSET} não foi encontrado na última Release.")
        return data.get("tag_name", "desconhecida"), asset["browser_download_url"]

    def download(self, url, destination):
        req = urllib.request.Request(url, headers={"User-Agent": "TeamTalk-Linux-installer"})
        with urllib.request.urlopen(req, timeout=90) as response, open(destination, "wb") as out:
            total = int(response.headers.get("Content-Length") or 0)
            done = 0
            while True:
                chunk = response.read(1024 * 256)
                if not chunk:
                    break
                out.write(chunk)
                done += len(chunk)
                if total:
                    fraction = 0.44 + 0.20 * min(done / total, 1.0)
                    GLib.idle_add(self.announce, "Baixando o TeamTalk.", fraction)

    def write_launcher(self):
        APP_DIR.mkdir(parents=True, exist_ok=True)
        CFG_DIR.mkdir(parents=True, exist_ok=True)
        BIN_DIR.mkdir(parents=True, exist_ok=True)
        DESKTOP_DIR.mkdir(parents=True, exist_ok=True)

        launcher = f'''#!/usr/bin/env bash
set -e
APP_DIR="{APP_DIR}"
CFG_FILE="{CFG_DIR / 'TeamTalk5.ini'}"
export LD_LIBRARY_PATH="$APP_DIR${{LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}}"
cd "$APP_DIR"
exec "$APP_DIR/teamtalk5" -cfg "$CFG_FILE" "$@"
'''
        LAUNCHER.write_text(launcher, encoding="utf-8")
        LAUNCHER.chmod(0o755)

        desktop = f'''[Desktop Entry]
Type=Application
Name=TeamTalk 5 Linux
Comment=TeamTalk Linux com Ctrl esquerdo global como Push-to-Talk
Exec={LAUNCHER}
Icon=audio-input-microphone
Terminal=false
Categories=Network;AudioVideo;Audio;
StartupNotify=true
'''
        DESKTOP_FILE.write_text(desktop, encoding="utf-8")
        DESKTOP_FILE.chmod(0o755)

    def install_gnome_extension(self, package_root):
        source = package_root / "gnome-extension"
        metadata = source / "metadata.json"
        extension_js = source / "extension.js"
        if not metadata.is_file() or not extension_js.is_file():
            raise RuntimeError(
                "A extensão GNOME para Ctrl PTT não foi encontrada dentro do pacote."
            )

        EXT_DIR.parent.mkdir(parents=True, exist_ok=True)
        if EXT_DIR.exists():
            shutil.rmtree(EXT_DIR)
        shutil.copytree(source, EXT_DIR)

        # Try to enable it immediately. A freshly copied extension may not be
        # known to the running Shell until the next login; that case is not an
        # installation failure and is reported clearly to the user.
        tool = shutil.which("gnome-extensions")
        if not tool:
            return False, "O comando gnome-extensions não foi encontrado. Saia e entre novamente na sessão GNOME e habilite a extensão TeamTalk Ctrl Push-to-Talk."

        result = subprocess.run(
            [tool, "enable", EXT_UUID],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        if result.returncode == 0:
            return True, "Extensão GNOME habilitada."

        details = (result.stdout or "").strip()
        return False, (
            "A extensão foi instalada, mas o GNOME Shell ainda não a reconheceu nesta sessão. "
            "Saia e entre na sessão GNOME uma vez; depois ela poderá ser habilitada. "
            + (f"Detalhe: {details}" if details else "")
        )

    def worker_install(self):
        temp_dir = None
        try:
            GLib.idle_add(self.announce, "Verificando o sistema.", 0.05)
            self.check_platform()

            GLib.idle_add(self.announce, "Instalando dependências necessárias.", 0.14)
            self.install_packages()

            GLib.idle_add(self.announce, "Consultando a versão mais recente.", 0.35)
            tag, url = self.release_info()

            temp_dir = Path(tempfile.mkdtemp(prefix="teamtalk-linux-"))
            archive = temp_dir / ASSET

            GLib.idle_add(self.announce, f"Baixando TeamTalk {tag}.", 0.44)
            self.download(url, archive)

            GLib.idle_add(self.announce, "Extraindo os arquivos.", 0.68)
            extract_dir = temp_dir / "extract"
            extract_dir.mkdir()
            with tarfile.open(archive, "r:gz") as tar:
                tar.extractall(extract_dir, filter="data")

            matches = list(extract_dir.glob("**/client/teamtalk5"))
            if not matches:
                raise RuntimeError("O executável teamtalk5 não foi encontrado no pacote.")
            client_dir = matches[0].parent
            package_root = client_dir.parent

            GLib.idle_add(self.announce, "Instalando os arquivos do TeamTalk.", 0.80)
            if APP_DIR.exists():
                shutil.rmtree(APP_DIR)
            shutil.copytree(client_dir, APP_DIR)
            (APP_DIR / "teamtalk5").chmod(0o755)

            CFG_DIR.mkdir(parents=True, exist_ok=True)
            cfg = CFG_DIR / "TeamTalk5.ini"
            if not cfg.exists():
                default_cfg = APP_DIR / "TeamTalk5.ini.default"
                if default_cfg.exists():
                    shutil.copy2(default_cfg, cfg)
                else:
                    cfg.touch()

            GLib.idle_add(self.announce, "Instalando a extensão GNOME para Ctrl PTT.", 0.89)
            extension_enabled, extension_note = self.install_gnome_extension(package_root)

            GLib.idle_add(self.announce, "Criando o atalho no menu de aplicativos.", 0.96)
            self.write_launcher()
            if shutil.which("update-desktop-database"):
                subprocess.run(["update-desktop-database", str(DESKTOP_DIR)],
                               stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL)

            GLib.idle_add(self.update_installed_label)
            if extension_enabled:
                final = f"TeamTalk {tag} instalado. Extensão GNOME habilitada; Ctrl esquerdo global está pronto para PTT."
            else:
                final = f"TeamTalk {tag} instalado. {extension_note}"
            GLib.idle_add(self.finish, final)
        except Exception as exc:
            GLib.idle_add(self.fail, "Não foi possível instalar o TeamTalk", str(exc))
        finally:
            if temp_dir:
                shutil.rmtree(temp_dir, ignore_errors=True)

    def on_install(self, *_):
        if self.busy:
            return
        self.set_busy(True)
        self.announce("Iniciando a instalação.", 0.01)
        threading.Thread(target=self.worker_install, daemon=True).start()

    def on_open(self, *_):
        if not LAUNCHER.is_file():
            self.dialog(Gtk.MessageType.WARNING,
                        "TeamTalk não instalado",
                        "Escolha “Instalar ou atualizar” primeiro.")
            return
        try:
            subprocess.Popen([str(LAUNCHER)],
                             stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL,
                             start_new_session=True)
            self.status.set_text("TeamTalk iniciado.")
        except OSError as exc:
            self.dialog(Gtk.MessageType.ERROR, "Não foi possível abrir o TeamTalk", str(exc))

    def on_uninstall(self, *_):
        if self.busy:
            return
        if (not APP_DIR.exists() and not LAUNCHER.exists() and
                not DESKTOP_FILE.exists() and not EXT_DIR.exists()):
            self.dialog(Gtk.MessageType.INFO, "TeamTalk não está instalado")
            return
        response = self.dialog(
            Gtk.MessageType.QUESTION,
            "Desinstalar TeamTalk?",
            f"A configuração será preservada em {CFG_DIR}. A extensão GNOME do Ctrl PTT também será removida.",
            Gtk.ButtonsType.OK_CANCEL,
        )
        if response != Gtk.ResponseType.OK:
            return
        try:
            tool = shutil.which("gnome-extensions")
            if tool:
                subprocess.run([tool, "disable", EXT_UUID],
                               stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL)
            if EXT_DIR.exists():
                shutil.rmtree(EXT_DIR)
            if APP_DIR.exists():
                shutil.rmtree(APP_DIR)
            LAUNCHER.unlink(missing_ok=True)
            DESKTOP_FILE.unlink(missing_ok=True)
            self.update_installed_label()
            self.announce("TeamTalk e extensão GNOME removidos. A configuração foi preservada.", 1.0)
        except OSError as exc:
            self.dialog(Gtk.MessageType.ERROR, "Falha ao desinstalar", str(exc))


win = Installer()
Gtk.main()
PY
