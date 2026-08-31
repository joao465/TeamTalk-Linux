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
    // Mantidos também para diagnóstico manual por D-Bus.
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
#include <QLocalSocket>
#include <QTimer>
#endif

#if defined(QT_TEXTTOSPEECH_LIB)
'''
replace_once(mainwindow, old, new, "incluir D-Bus e socket local no Linux")

old = r'''    ui.setupUi(this);
    setupChatHistory();
'''
new = r'''    ui.setupUi(this);

#if defined(Q_OS_LINUX)
    // O serviço D-Bus de sessão fica disponível somente para diagnóstico e
    // testes manuais. A captura real do Ctrl no Wayland vem de um helper
    // Linux restrito a KEY_LEFTCTRL e chega por um socket local somente-leitura.
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

    setProperty("teamtalkCtrlPttInputConnected", false);
    auto* ctrlPttInput = new QLocalSocket(this);
    auto* ctrlPttRetry = new QTimer(this);
    ctrlPttRetry->setInterval(1000);

    connect(ctrlPttRetry, &QTimer::timeout, this, [ctrlPttInput]() {
        if(ctrlPttInput->state() == QLocalSocket::UnconnectedState)
            ctrlPttInput->connectToServer(QStringLiteral("/run/teamtalk-ctrl-ptt/input.sock"),
                                          QIODevice::ReadOnly);
    });

    connect(ctrlPttInput, &QLocalSocket::connected, this, [this]() {
        setProperty("teamtalkCtrlPttInputConnected", true);
        qWarning() << "Linux Ctrl PTT input helper connected";
    });

    connect(ctrlPttInput, &QLocalSocket::disconnected, this, [this]() {
        setProperty("teamtalkCtrlPttInputConnected", false);
        qWarning() << "Linux Ctrl PTT input helper disconnected; forcing PTT off";
        setGnomeCtrlPttPressed(false);
    });

    connect(ctrlPttInput, &QLocalSocket::readyRead, this, [this, ctrlPttInput]() {
        while(ctrlPttInput->canReadLine())
        {
            const QByteArray state = ctrlPttInput->readLine().trimmed();
            if(state == "1")
                setGnomeCtrlPttPressed(true);
            else if(state == "0")
                setGnomeCtrlPttPressed(false);
        }
    });

    ctrlPttRetry->start();
    ctrlPttInput->connectToServer(QStringLiteral("/run/teamtalk-ctrl-ptt/input.sock"),
                                  QIODevice::ReadOnly);
#endif

    setupChatHistory();
'''
replace_once(mainwindow, old, new, "conectar helper KEY_LEFTCTRL ao TeamTalk")

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
    const QString sessionType = qEnvironmentVariable("XDG_SESSION_TYPE");
    const QString qpa = QGuiApplication::platformName();
    const bool inputHelper = property("teamtalkCtrlPttInputConnected").toBool();

    return QStringLiteral("service=ready;ptt=%1;ctrlOnly=%2;inputHelper=%3;session=%4;qpa=%5")
        .arg(pttEnabled ? QStringLiteral("on") : QStringLiteral("off"))
        .arg(ctrlOnly ? QStringLiteral("yes") : QStringLiteral("no"))
        .arg(inputHelper ? QStringLiteral("connected") : QStringLiteral("disconnected"))
        .arg(sessionType.isEmpty() ? QStringLiteral("unknown") : sessionType)
        .arg(qpa.isEmpty() ? QStringLiteral("unknown") : qpa);
}

void MainWindow::setGnomeCtrlPttPressed(bool active)
{
    if(!ui.actionEnablePushToTalk->isChecked())
    {
        qWarning() << "Linux Ctrl PTT ignored: Push-to-Talk action is disabled";
        return;
    }

    hotkey_t hk;
    if(!loadHotKeySettings(HOTKEY_PUSHTOTALK, hk) ||
       hk.size() != 1 || hk[0] != Qt::CTRL)
    {
        qWarning() << "Linux Ctrl PTT ignored: configured shortcut is not bare Ctrl";
        return;
    }

    // O helper observa KEY_LEFTCTRL sem bloquear/remapear a tecla. Assim
    // Ctrl+C, Ctrl+V, Ctrl+Tab etc. continuam chegando normalmente aos apps.
    const bool ok = TT_EnableVoiceTransmission(ttInst, active);
    qWarning() << "Linux Ctrl PTT" << (active ? "pressed" : "released")
               << "TT_EnableVoiceTransmission=" << ok;
    emit updateMyself();

    if(!ok)
        addStatusMsg(STATUSBAR_BYPASS, tr("Voice transmission failed"));
}

void MainWindow::keysActive(quint32 keycode, quint32 mods, bool active)
'''
replace_once(mainwindow, old, new, "receber Ctrl global do helper Linux")

# This block exists after apply_linux_hotkeys.py has already run. A Qt app can
# run through XWayland and therefore expose an X11 Display even while the real
# desktop session is Wayland. Decide the PTT backend from XDG_SESSION_TYPE,
# not from whether QX11Application happens to be available.
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
    const bool waylandSession =
        qEnvironmentVariable("XDG_SESSION_TYPE").compare(
            QStringLiteral("wayland"), Qt::CaseInsensitive) == 0;

    if(waylandSession)
    {
        if(id == HOTKEY_PUSHTOTALK && modifierOnly && hk[0] == Qt::CTRL)
        {
            qWarning() << "Linux Ctrl PTT: using KEY_LEFTCTRL input helper on Wayland; Qt platform ="
                       << QGuiApplication::platformName();

            // TeamTalk's normal updateUI() considers PTT enabled on Linux only
            // when HOTKEY_PUSHTOTALK exists in m_hotkeys. The Wayland helper
            // does not perform an XGrabKey, but we must still register this
            // logical hotkey so updateUI() does not immediately uncheck the
            // Push-to-Talk action after the user enables it.
            keycomp_t logicalHotkey;
            logicalHotkey.insert(Qt::CTRL);
            m_hotkeys.insert(id, logicalHotkey);

            m_pttlabel->setText(tr("Push To Talk: ") + getHotKeyText(hk));
            return;
        }

        QMessageBox::warning(this, tr("Enable HotKey"),
                             tr("This global hotkey is not supported on Wayland. "
                                "On Wayland, this TeamTalk build supports bare "
                                "left Ctrl for Push-to-Talk through its Linux "
                                "input helper."));
        return;
    }

    Display* display = teamtalkHotKeyX11Display();
    if(!display)
    {
        QMessageBox::warning(this, tr("Enable HotKey"),
                             tr("The X11 display required for this global hotkey "
                                "is not available."));
        return;
    }

    Window x11window = DefaultRootWindow(display);

    keycomp_t keycomp;
    quint32 mods = 0, keycode = 0;

    // XGrabKey requires a real keycode. When the entire shortcut is a
    // modifier, convert it to the physical left-side X11 modifier key.
'''
replace_once(mainwindow, old, new, "usar helper KEY_LEFTCTRL no Wayland e manter PTT ativo")

print("Integração Linux Wayland Ctrl PTT via KEY_LEFTCTRL aplicada.")
