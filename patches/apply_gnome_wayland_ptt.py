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
private slots:
    // Método D-Bus chamado diretamente pela extensão do GNOME Shell quando
    // o Ctrl esquerdo é pressionado ou solto globalmente.
    Q_SCRIPTABLE void setGnomeCtrlPttPressed(bool active);
#endif

signals:
'''
replace_once(mainwindow_h, old, new, "adicionar método D-Bus para PTT no GNOME Wayland")

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
    // Isso é mais confiável que um broadcast sem destinatário e permite que
    // o cliente seja o responsável final por ligar/desligar a transmissão.
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
void MainWindow::setGnomeCtrlPttPressed(bool active)
{
    // Só aceite o relay quando Push-to-Talk estiver habilitado e configurado
    // exatamente como Ctrl sozinho.
    Hotkeys activeHotkeys = ttSettings->value(
        SETTINGS_SHORTCUTS_ACTIVEHKS,
        SETTINGS_SHORTCUTS_ACTIVEHKS_DEFAULT).toULongLong();
    if((activeHotkeys & HOTKEY_PUSHTOTALK) == 0)
        return;

    hotkey_t hk;
    if(!loadHotKeySettings(HOTKEY_PUSHTOTALK, hk))
        return;
    if(hk.size() != 1 || hk[0] != Qt::CTRL)
        return;

    // O comportamento solicitado é sempre pressionar-para-falar no relay do
    // GNOME: pressionou = transmissão ligada, soltou = desligada. Não aplique
    // o modo "travar PTT" aqui, pois ele transformaria o Ctrl em alternância.
    const bool ok = TT_EnableVoiceTransmission(ttInst, active);
    emit updateMyself();
    playSoundEvent(SOUNDEVENT_HOTKEY);

    if(active && ok)
        transmitOn(STREAMTYPE_VOICE);
    else if(active && !ok)
        addStatusMsg(STATUSBAR_BYPASS, tr("Voice transmission failed"));
}

void MainWindow::keysActive(quint32 keycode, quint32 mods, bool active)
'''
replace_once(mainwindow, old, new, "receber Ctrl global por chamada D-Bus direta")

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
