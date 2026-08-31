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

old = r'''class MainWindow : public QMainWindow
{
    Q_OBJECT
'''
new = r'''class MainWindow : public QMainWindow
{
    Q_OBJECT
#if defined(Q_OS_LINUX)
    Q_CLASSINFO("D-Bus Interface", "org.teamtalk.CtrlPTT")
#endif
'''
replace_once(mainwindow_h, old, new, "declarar interface D-Bus do TeamTalk")

old = r'''    MediaFilePlayback m_mfp = {};
    VideoCodec m_mfp_videocodec = {};
    std::optional<MediaFileInfo> m_mfi;

signals:
'''
new = r'''    MediaFilePlayback m_mfp = {};
    VideoCodec m_mfp_videocodec = {};
    std::optional<MediaFileInfo> m_mfi;

#if defined(Q_OS_LINUX)
public slots:
    // Métodos D-Bus usados pela extensão GNOME Shell e pelo diagnóstico.
    Q_SCRIPTABLE void setGnomeCtrlPttPressed(bool active);
    Q_SCRIPTABLE QString getGnomeCtrlPttStatus();
#endif

signals:
'''
replace_once(mainwindow_h, old, new, "adicionar métodos D-Bus para PTT e diagnóstico")

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
    // No GNOME/Wayland o portal de atalhos globais não aceita um modificador
    // sozinho. O TeamTalk registra um serviço D-Bus local e a extensão do
    // GNOME Shell chama setGnomeCtrlPttPressed(true/false) diretamente.
    QDBusConnection ctrlPttBus = QDBusConnection::sessionBus();
    if(ctrlPttBus.registerService(QStringLiteral("org.teamtalk.CtrlPTT")))
    {
        if(!ctrlPttBus.registerObject(
               QStringLiteral("/org/teamtalk/CtrlPTT"),
               this,
               QDBusConnection::ExportScriptableSlots))
        {
            qWarning() << "Falha ao registrar objeto D-Bus do Ctrl PTT";
        }
    }
    else
    {
        qWarning() << "Serviço D-Bus org.teamtalk.CtrlPTT já está em uso";
    }
#endif

    setupChatHistory();
'''
replace_once(mainwindow, old, new, "registrar serviço D-Bus do TeamTalk")

old = r'''#if defined(Q_OS_LINUX)
void MainWindow::keysActive(quint32 keycode, quint32 mods, bool active)
'''
new = r'''#if defined(Q_OS_LINUX)
QString MainWindow::getGnomeCtrlPttStatus()
{
    hotkey_t hk;
    const bool hasHotkey = loadHotKeySettings(HOTKEY_PUSHTOTALK, hk);
    const bool ctrlOnly = hasHotkey && hk.size() == 1 && hk[0] == Qt::CTRL;
    const bool pttEnabled = ui.actionEnablePushToTalk->isChecked();

    return QStringLiteral("service=ready;ptt=%1;ctrlOnly=%2")
        .arg(pttEnabled ? QStringLiteral("on") : QStringLiteral("off"))
        .arg(ctrlOnly ? QStringLiteral("yes") : QStringLiteral("no"));
}

void MainWindow::setGnomeCtrlPttPressed(bool active)
{
    // Use the live UI state instead of the persisted active-hotkeys bit.
    // The persisted setting can lag behind the current QAction state while
    // configuring/reloading shortcuts, which made valid D-Bus calls return
    // without touching voice transmission.
    if(!ui.actionEnablePushToTalk->isChecked())
    {
        qWarning() << "GNOME Ctrl PTT ignored: Push-to-Talk action is disabled";
        return;
    }

    hotkey_t hk;
    if(!loadHotKeySettings(HOTKEY_PUSHTOTALK, hk) ||
       hk.size() != 1 || hk[0] != Qt::CTRL)
    {
        qWarning() << "GNOME Ctrl PTT ignored: configured shortcut is not bare Ctrl";
        return;
    }

    // GNOME relay is deliberately momentary: press = transmit, release = stop.
    const bool ok = TT_EnableVoiceTransmission(ttInst, active);
    qWarning() << "GNOME Ctrl PTT" << (active ? "pressed" : "released")
               << "TT_EnableVoiceTransmission=" << ok;
    emit updateMyself();

    if(!ok)
        addStatusMsg(STATUSBAR_BYPASS, tr("Voice transmission failed"));
}

void MainWindow::keysActive(quint32 keycode, quint32 mods, bool active)
'''
replace_once(mainwindow, old, new, "receber Ctrl global por D-Bus usando estado atual do TeamTalk")

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
