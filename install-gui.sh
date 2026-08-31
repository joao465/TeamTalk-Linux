#!/usr/bin/env bash
set -Eeuo pipefail

# Simple GTK installer for TeamTalk Linux.
# Intentionally uses only standard GTK widgets. No manual AT-SPI names,
# no focus stealing and no continuously-updating progress widget.

ensure_gui_runtime() {
    if python3 - <<'PY' >/dev/null 2>&1
import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, Gio
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
            'ERRO: não foi possível instalar a interface GTK.' \
            'Instale python3-gi e gir1.2-gtk-3.0 e execute novamente.' >&2
        exit 1
    fi
}

ensure_gui_runtime

python3 - "$@" <<'PY'
import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, GLib, Gio

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import urllib.request

REPO = "joao465/TeamTalk-Linux"
ASSET = "teamtalk-linux-ctrlptt-ubuntu26-x86_64.tgz"
META_ASSET = "metadata.json"
EXT_ASSET = "extension.js"
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

EXT_UUID = "teamtalk-ctrl-ptt-v2@joao465"
OLD_EXT_UUIDS = ["teamtalk-ctrl-ptt@joao465"]
EXT_BASE = DATA_HOME / "gnome-shell/extensions"
EXT_DIR = EXT_BASE / EXT_UUID

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
        self.set_default_size(640, 300)
        self.set_border_width(18)
        self.connect("destroy", Gtk.main_quit)
        self.busy = False

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        self.add(box)

        heading = Gtk.Label(label="TeamTalk Linux")
        heading.set_xalign(0)
        box.pack_start(heading, False, False, 0)

        description = Gtk.Label(
            label="Use Tab e Shift+Tab para navegar. O instalador usa apenas controles GTK padrão."
        )
        description.set_xalign(0)
        description.set_line_wrap(True)
        box.pack_start(description, False, False, 0)

        self.info = Gtk.Label()
        self.info.set_xalign(0)
        self.info.set_line_wrap(True)
        box.pack_start(self.info, False, False, 0)

        status_label = Gtk.Label(label="Status:")
        status_label.set_xalign(0)
        box.pack_start(status_label, False, False, 0)

        # A normal read-only GTK entry is predictable for Orca. Users can Tab
        # to this field at any time and hear the current installation state.
        self.status = Gtk.Entry()
        self.status.set_editable(False)
        self.status.set_text("Pronto.")
        box.pack_start(self.status, False, False, 0)

        buttons = Gtk.ButtonBox(orientation=Gtk.Orientation.HORIZONTAL)
        buttons.set_layout(Gtk.ButtonBoxStyle.EXPAND)
        box.pack_end(buttons, False, False, 0)

        self.install_button = Gtk.Button.new_with_label("Instalar ou atualizar")
        self.open_button = Gtk.Button.new_with_label("Abrir TeamTalk")
        self.uninstall_button = Gtk.Button.new_with_label("Desinstalar")
        self.close_button = Gtk.Button.new_with_label("Fechar")

        for button in (self.install_button, self.open_button,
                       self.uninstall_button, self.close_button):
            buttons.add(button)

        self.install_button.connect("clicked", self.on_install)
        self.open_button.connect("clicked", self.on_open)
        self.uninstall_button.connect("clicked", self.on_uninstall)
        self.close_button.connect("clicked", lambda *_: Gtk.main_quit())

        self.refresh_info()
        self.show_all()
        self.install_button.grab_focus()

    def refresh_info(self):
        installed = "Sim" if (APP_DIR / "teamtalk5").is_file() else "Não"
        ext_installed = "Sim" if (EXT_DIR / "extension.js").is_file() else "Não"
        session = os.environ.get("XDG_SESSION_TYPE", "desconhecida")
        self.info.set_text(
            f"TeamTalk instalado: {installed}. Extensão Ctrl PTT: {ext_installed}. Sessão: {session}."
        )
        return False

    def set_status(self, text):
        self.status.set_text(text)
        return False

    def set_busy(self, busy):
        self.busy = busy
        # Keep the focused Install button enabled so GTK/Orca do not have to
        # move focus while background work is running. Repeated clicks are
        # ignored by on_install().
        self.open_button.set_sensitive(not busy)
        self.uninstall_button.set_sensitive(not busy)
        return False

    def dialog(self, kind, title, details=None, buttons=Gtk.ButtonsType.OK):
        dlg = Gtk.MessageDialog(
            transient_for=self,
            modal=True,
            destroy_with_parent=True,
            message_type=kind,
            buttons=buttons,
            text=title,
        )
        if details:
            dlg.format_secondary_text(details)
        response = dlg.run()
        dlg.destroy()
        return response

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

    def run_cmd(self, args, check=True):
        return subprocess.run(
            args,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=check,
        )

    def install_packages(self):
        if os.geteuid() == 0:
            self.run_cmd(["apt-get", "update"])
            self.run_cmd(["apt-get", "install", "-y", *RUNTIME_PACKAGES])
            return
        if shutil.which("pkexec"):
            self.run_cmd([
                "pkexec", "env", "DEBIAN_FRONTEND=noninteractive", "sh", "-c",
                "apt-get update && apt-get install -y " + " ".join(RUNTIME_PACKAGES),
            ])
            return
        raise RuntimeError("Não foi possível abrir a autenticação do sistema para instalar dependências.")

    def release_info(self):
        req = urllib.request.Request(API, headers={"User-Agent": "TeamTalk-Linux-installer"})
        with urllib.request.urlopen(req, timeout=30) as response:
            data = json.load(response)

        by_name = {a.get("name"): a.get("browser_download_url") for a in data.get("assets", [])}
        missing = [name for name in (ASSET, META_ASSET, EXT_ASSET) if not by_name.get(name)]
        if missing:
            raise RuntimeError("Arquivos ausentes na Release: " + ", ".join(missing))

        return (
            data.get("tag_name", "desconhecida"),
            by_name[ASSET],
            by_name[META_ASSET],
            by_name[EXT_ASSET],
        )

    def download(self, url, destination):
        req = urllib.request.Request(url, headers={"User-Agent": "TeamTalk-Linux-installer"})
        with urllib.request.urlopen(req, timeout=90) as response, open(destination, "wb") as out:
            shutil.copyfileobj(response, out)

    def write_launcher(self):
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

    def update_shell_enabled_extensions(self, enable_new):
        settings = Gio.Settings.new("org.gnome.shell")
        enabled = list(settings.get_strv("enabled-extensions"))

        for old_uuid in OLD_EXT_UUIDS:
            enabled = [x for x in enabled if x != old_uuid]

        enabled = [x for x in enabled if x != EXT_UUID]
        if enable_new:
            enabled.append(EXT_UUID)

        settings.set_strv("enabled-extensions", enabled)
        Gio.Settings.sync()

    def extension_active(self):
        tool = shutil.which("gnome-extensions")
        if not tool:
            return False
        result = subprocess.run(
            [tool, "list", "--active"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        return EXT_UUID in {line.strip() for line in result.stdout.splitlines()}

    def install_extension(self, metadata_url, extension_url, temp_dir):
        # Remove the previously cached UUID so the new implementation cannot
        # be confused with the old module on the next GNOME session.
        tool = shutil.which("gnome-extensions")
        for old_uuid in OLD_EXT_UUIDS:
            if tool:
                subprocess.run([tool, "disable", old_uuid],
                               stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL)
            old_dir = EXT_BASE / old_uuid
            if old_dir.exists():
                shutil.rmtree(old_dir)

        if tool:
            subprocess.run([tool, "disable", EXT_UUID],
                           stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)

        if EXT_DIR.exists():
            shutil.rmtree(EXT_DIR)
        EXT_DIR.mkdir(parents=True, exist_ok=True)

        metadata_path = temp_dir / META_ASSET
        extension_path = temp_dir / EXT_ASSET
        self.download(metadata_url, metadata_path)
        self.download(extension_url, extension_path)
        shutil.copy2(metadata_path, EXT_DIR / "metadata.json")
        shutil.copy2(extension_path, EXT_DIR / "extension.js")

        # Mark the fresh UUID enabled. GNOME may activate it immediately; if
        # the running Shell has not rescanned user extensions yet, it will be
        # loaded automatically at the next login.
        self.update_shell_enabled_extensions(True)
        if tool:
            subprocess.run([tool, "enable", EXT_UUID],
                           stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)

        time.sleep(1.0)
        return self.extension_active()

    def worker_install(self):
        temp_dir = None
        try:
            GLib.idle_add(self.set_status, "Verificando o sistema.")
            self.check_platform()

            GLib.idle_add(self.set_status, "Instalando dependências necessárias.")
            self.install_packages()

            GLib.idle_add(self.set_status, "Consultando a versão mais recente.")
            tag, package_url, metadata_url, extension_url = self.release_info()

            temp_dir = Path(tempfile.mkdtemp(prefix="teamtalk-linux-"))
            archive = temp_dir / ASSET

            GLib.idle_add(self.set_status, f"Baixando TeamTalk {tag}.")
            self.download(package_url, archive)

            GLib.idle_add(self.set_status, "Extraindo os arquivos.")
            extract_dir = temp_dir / "extract"
            extract_dir.mkdir()
            with tarfile.open(archive, "r:gz") as tar:
                tar.extractall(extract_dir, filter="data")

            matches = list(extract_dir.glob("**/client/teamtalk5"))
            if not matches:
                raise RuntimeError("O executável teamtalk5 não foi encontrado no pacote.")
            client_dir = matches[0].parent

            GLib.idle_add(self.set_status, "Instalando o TeamTalk.")
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

            GLib.idle_add(self.set_status, "Instalando a extensão GNOME Ctrl PTT nova.")
            active_now = self.install_extension(metadata_url, extension_url, temp_dir)

            GLib.idle_add(self.set_status, "Criando o atalho do TeamTalk.")
            self.write_launcher()
            if shutil.which("update-desktop-database"):
                subprocess.run(["update-desktop-database", str(DESKTOP_DIR)],
                               stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL)

            if active_now:
                final = f"TeamTalk {tag} instalado. Extensão Ctrl PTT ativa nesta sessão."
            else:
                final = (
                    f"TeamTalk {tag} instalado. A extensão nova foi habilitada para o GNOME. "
                    "Saia da sessão e entre novamente uma vez antes de testar o Ctrl."
                )

            GLib.idle_add(self.refresh_info)
            GLib.idle_add(self.set_status, final)
        except Exception as exc:
            GLib.idle_add(self.set_status, "Falha na instalação.")
            GLib.idle_add(
                self.dialog,
                Gtk.MessageType.ERROR,
                "Não foi possível instalar o TeamTalk",
                str(exc),
            )
        finally:
            if temp_dir:
                shutil.rmtree(temp_dir, ignore_errors=True)
            GLib.idle_add(self.set_busy, False)

    def on_install(self, *_):
        if self.busy:
            return
        self.set_busy(True)
        self.set_status("Iniciando a instalação.")
        threading.Thread(target=self.worker_install, daemon=True).start()

    def on_open(self, *_):
        if not LAUNCHER.is_file():
            self.dialog(Gtk.MessageType.WARNING,
                        "TeamTalk não instalado",
                        "Escolha Instalar ou atualizar primeiro.")
            return
        try:
            subprocess.Popen([str(LAUNCHER)],
                             stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL,
                             start_new_session=True)
            self.set_status("TeamTalk iniciado.")
        except OSError as exc:
            self.dialog(Gtk.MessageType.ERROR, "Não foi possível abrir o TeamTalk", str(exc))

    def on_uninstall(self, *_):
        if self.busy:
            return
        response = self.dialog(
            Gtk.MessageType.QUESTION,
            "Desinstalar TeamTalk?",
            f"A configuração será preservada em {CFG_DIR}.",
            Gtk.ButtonsType.OK_CANCEL,
        )
        if response != Gtk.ResponseType.OK:
            return

        try:
            tool = shutil.which("gnome-extensions")
            for uuid in [EXT_UUID, *OLD_EXT_UUIDS]:
                if tool:
                    subprocess.run([tool, "disable", uuid],
                                   stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL)
                ext_dir = EXT_BASE / uuid
                if ext_dir.exists():
                    shutil.rmtree(ext_dir)

            self.update_shell_enabled_extensions(False)

            if APP_DIR.exists():
                shutil.rmtree(APP_DIR)
            LAUNCHER.unlink(missing_ok=True)
            DESKTOP_FILE.unlink(missing_ok=True)
            self.refresh_info()
            self.set_status("TeamTalk e extensão Ctrl PTT removidos. A configuração foi preservada.")
        except OSError as exc:
            self.dialog(Gtk.MessageType.ERROR, "Falha ao desinstalar", str(exc))


win = Installer()
Gtk.main()
PY
