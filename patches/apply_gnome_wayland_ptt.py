#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("Uso: apply_gnome_wayland_ptt.py /caminho/TeamTalk5")

repo = Path(sys.argv[1]).resolve()


def replace_once(path: Path, old: str, new: str, label: str) -> None:
    with path.open("r", encoding="utf-8", newline="") as f:
        raw = f.read()

    line_ending = "\r\n" if "\r\n" in raw else "\n"
    text = raw.replace("\r\n", "\n")

    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: esperado 1 bloco, encontrado {count} em {path}")

    result = text.replace(old, new, 1)
    if line_ending == "\r\n":
        result = result.replace("\n", "\r\n")

    with path.open("w", encoding="utf-8", newline="") as f:
        f.write(result)

    print(f"OK: {label}")


mainwindow_h = repo / "Client/qtTeamTalk/mainwindow.h"

old = r'''    MediaFilePlayback m_mfp = {};
    VideoCodec m_mfp_videocodec = {};
    std::optional<MediaFileInfo> m_mfi;

signals:
'''
new = r'''    MediaFilePlayback m_mfp = {};
    VideoCodec m_mfp_videocodec = {};
    std::optional<MediaFileInfo> m_mfi;

#if defined(Q_OS_LINUX)
private slots:
    // GNOME Shell Wayland relay. The shell extension emits this signal when
    // the physical left Ctrl key is pressed or released globally.
    void slotGnomeCtrlPttChanged(bool active);
#endif

signals:
'''
replace_once(mainwindow_h, old, new, "adicionar slot D-Bus para PTT no GNOME Wayland")

mainwindow = repo / "Client/qtTeamTalk/mainwindow.cpp"

old = r'''#include <QSysInfo>
#include <QThread>

#if defined(QT_TEXTTOSPEECH_LIB)
'''
new = r'''#include <QSysInfo>
#include <QThread>
#if defined(Q_OS_LINUX)
#include <QDBusConnection>
#endif

#if defined(QT_TEXTTOSPEECH_LIB)
'''
replace_once(mainwindow, old, new, "incluir QDBusConnection no Linux")

old = r'''    ui.setupUi(this);
    setupChatHistory();
'''
new = r'''    ui.setupUi(this);

#if defined(Q_OS_LINUX)
    // GNOME Shell on Wayland cannot register a bare modifier through the
    // standard GlobalShortcuts portal. A tiny GNOME Shell extension captures
    // left Ctrl press/release and emits org.teamtalk.CtrlPTT.Changed(bool)
    // on the user's session bus. An empty service name intentionally accepts
    // the signal from the extension's unique D-Bus sender.
    QDBusConnection::sessionBus().connect(
        QString(),
        QStringLiteral("/org/teamtalk/CtrlPTT"),
        QStringLiteral("org.teamtalk.CtrlPTT"),
        QStringLiteral("Changed"),
        this,
        SLOT(slotGnomeCtrlPttChanged(bool)));
#endif

    setupChatHistory();
'''
replace_once(mainwindow, old, new, "conectar relay D-Bus do GNOME")

old = r'''#if defined(Q_OS_LINUX)
void MainWindow::keysActive(quint32 keycode, quint32 mods, bool active)
'''
new = r'''#if defined(Q_OS_LINUX)
void MainWindow::slotGnomeCtrlPttChanged(bool active)
{
    // Ignore the extension unless Push-to-Talk is enabled and the configured
    // PTT shortcut is exactly bare Ctrl. This prevents the shell relay from
    // changing microphone state when the user selects another shortcut.
    Hotkeys activeHotkeys = ttSettings->value(
        SETTINGS_SHORTCUTS_ACTIVEHKS,
        SETTINGS_SHORTCUTS_ACTIVEHKS_DEFAULT).toULongLong();
    if((activeHotkeys & HOTKEY_PUSHTOTALK) == 0)
        return;

    hotkey_t hk;
    if(!loadHotKeySettings(HOTKEY_PUSHTOTALK, hk))
        return;

    if(hk.size() == 1 && hk[0] == Qt::CTRL)
        pttHotKey(active);
}

void MainWindow::keysActive(quint32 keycode, quint32 mods, bool active)
'''
replace_once(mainwindow, old, new, "receber Ctrl global do GNOME Shell")

# This block exists after apply_linux_hotkeys.py has already run. On X11 we
# keep using XGrabKey. On Wayland, bare Ctrl for PTT is registered logically
# and driven by the GNOME Shell D-Bus relay instead of showing an X11 error.
old = r'''    Display* display = teamtalkHotKeyX11Display();
    if(!display)
    {
        QMessageBox::warning(this, tr("Enable HotKey"),
                             tr("Global hotkeys that use a modifier key by itself "
                                "require an X11/Xorg session. This session is not "
                                "using the Qt X11 platform."));
        return;
    }

    Window x11window = DefaultRootWindow(display);

    keycomp_t keycomp;
    quint32 mods = 0, keycode = 0;

    // XGrabKey requires a real keycode. When the entire shortcut is a
    // modifier, convert it to the physical left-side X11 modifier key.
    const bool modifierOnly = hk.size() == 1 &&
                              teamtalkModifierKeySym(hk[0]) != NoSymbol;
'''
new = r'''    const bool modifierOnly = hk.size() == 1 &&
                              teamtalkModifierKeySym(hk[0]) != NoSymbol;

    Display* display = teamtalkHotKeyX11Display();
    if(!display)
    {
        // GNOME/Wayland path: bare Ctrl PTT is delivered by the TeamTalk
        // GNOME Shell extension over D-Bus. Keep the shortcut enabled and
        // visible instead of rejecting it merely because Qt is on Wayland.
        if(id == HOTKEY_PUSHTOTALK && modifierOnly && hk[0] == Qt::CTRL)
        {
            m_pttlabel->setText(tr("Push To Talk: ") + getHotKeyText(hk));
            return;
        }

        QMessageBox::warning(this, tr("Enable HotKey"),
                             tr("This global hotkey requires an X11/Xorg session. "
                                "On GNOME Wayland, TeamTalk currently supports "
                                "bare Ctrl for Push-to-Talk through the installed "
                                "TeamTalk GNOME Shell extension."));
        return;
    }

    Window x11window = DefaultRootWindow(display);

    keycomp_t keycomp;
    quint32 mods = 0, keycode = 0;

    // XGrabKey requires a real keycode. When the entire shortcut is a
    // modifier, convert it to the physical left-side X11 modifier key.
'''
replace_once(mainwindow, old, new, "aceitar Ctrl PTT via GNOME Wayland")

print("Integração GNOME Wayland Ctrl PTT aplicada.")

# This file is also the build trigger for client-side GNOME/Wayland PTT changes.
