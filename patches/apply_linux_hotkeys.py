#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("Uso: apply_linux_hotkeys.py /caminho/TeamTalk5")

repo = Path(sys.argv[1]).resolve()

def replace_once(path: Path, old: str, new: str, label: str) -> None:
    # Preserve the upstream file's CRLF/LF style so the resulting Git diff
    # contains only the real code changes.
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

keycomp = repo / "Client/qtTeamTalk/keycompdlg.cpp"

old = r'''void KeyCompDlg::keyPressEvent(QKeyEvent* event)
{
    m_hotkey.clear();

    Qt::KeyboardModifiers mods = event->modifiers();
    if(mods & Qt::CTRL)
        m_activekeys.insert(Qt::CTRL);
    if(mods & Qt::ALT)
        m_activekeys.insert(Qt::ALT);
    if(mods & Qt::SHIFT)
        m_activekeys.insert(Qt::SHIFT);
    if(mods & Qt::META)
        m_activekeys.insert(Qt::META);

    switch(event->key())
    {
    case Qt::Key_Control :
    case Qt::Key_Alt :
    case Qt::Key_Shift :
    case Qt::Key_Meta :
        break;
    default:
        m_activekeys.insert(event->key());
    }

    QSet<INT32>::const_iterator ite = m_activekeys.begin();
    for(;ite != m_activekeys.end();ite++)
        m_hotkey.push_back(*ite);

    ui.keycompEdit->setText(getHotKeyText(m_hotkey));
}
'''

new = r'''void KeyCompDlg::keyPressEvent(QKeyEvent* event)
{
    m_hotkey.clear();

    Qt::KeyboardModifiers mods = event->modifiers();
    if(mods & Qt::CTRL)
        m_activekeys.insert(Qt::CTRL);
    if(mods & Qt::ALT)
        m_activekeys.insert(Qt::ALT);
    if(mods & Qt::SHIFT)
        m_activekeys.insert(Qt::SHIFT);
    if(mods & Qt::META)
        m_activekeys.insert(Qt::META);

    // On Linux a modifier-key press must not depend only on
    // QKeyEvent::modifiers(). When the modifier itself is the key event,
    // explicitly store its TeamTalk/Qt modifier value. This makes Ctrl,
    // Alt, Shift or Meta a complete hotkey without requiring a second key.
    switch(event->key())
    {
    case Qt::Key_Control :
        m_activekeys.insert(Qt::CTRL);
        break;
    case Qt::Key_Alt :
        m_activekeys.insert(Qt::ALT);
        break;
    case Qt::Key_Shift :
        m_activekeys.insert(Qt::SHIFT);
        break;
    case Qt::Key_Meta :
        m_activekeys.insert(Qt::META);
        break;
    default:
        m_activekeys.insert(event->key());
        break;
    }

    QSet<INT32>::const_iterator ite = m_activekeys.begin();
    for(;ite != m_activekeys.end();ite++)
        m_hotkey.push_back(*ite);

    ui.keycompEdit->setText(getHotKeyText(m_hotkey));
}
'''
replace_once(keycomp, old, new, "capturar modificador sozinho no diálogo")

old = r'''void KeyCompDlg::keyReleaseEvent(QKeyEvent* event)
{
    // if KeyCompDlg is opened from a key press (e.g. Space-key) then
    // we receive an unwanted keyReleaseEvent()
    if (!m_activekeys.contains(event->key()))
    {
        QDialog::keyReleaseEvent(event);
        return;
    }

    if(event->isAutoRepeat())
        return;
    if(event->modifiers() == 0)
        this->accept();
}
'''

new = r'''void KeyCompDlg::keyReleaseEvent(QKeyEvent* event)
{
    INT32 releasedKey = event->key();

    // Modifier keys are stored in m_activekeys as Qt::CTRL, Qt::ALT,
    // Qt::SHIFT and Qt::META. Normalize the release event to the same
    // representation so a modifier can be a complete hotkey by itself.
    switch(event->key())
    {
    case Qt::Key_Control :
        releasedKey = Qt::CTRL;
        break;
    case Qt::Key_Alt :
        releasedKey = Qt::ALT;
        break;
    case Qt::Key_Shift :
        releasedKey = Qt::SHIFT;
        break;
    case Qt::Key_Meta :
        releasedKey = Qt::META;
        break;
    default:
        break;
    }

    // if KeyCompDlg is opened from a key press (e.g. Space-key) then
    // we receive an unwanted keyReleaseEvent()
    if (!m_activekeys.contains(releasedKey))
    {
        QDialog::keyReleaseEvent(event);
        return;
    }

    if(event->isAutoRepeat())
        return;

    m_activekeys.remove(releasedKey);
    if(m_activekeys.isEmpty())
        this->accept();
}
'''
replace_once(keycomp, old, new, "normalizar liberação de modificadores no diálogo")

utilhotkey = repo / "Client/qtTeamTalk/utilhotkey.cpp"
old = r'''#elif defined(Q_OS_LINUX)
    int keys[4] = {0, 0, 0, 0};
    for(std::size_t i=0;i<hotkey.size();i++)
        keys[i] = hotkey[i];

    QKeySequence keyseq(keys[0], keys[1], keys[2], keys[3]);
    return keyseq.toString();
'''

new = r'''#elif defined(Q_OS_LINUX)
    if(hotkey.size() == 1)
    {
        switch(hotkey[0])
        {
        case Qt::CTRL :
            return QStringLiteral("Ctrl");
        case Qt::ALT :
            return QStringLiteral("Alt");
        case Qt::SHIFT :
            return QStringLiteral("Shift");
        case Qt::META :
            return QStringLiteral("Meta");
        default:
            break;
        }
    }

    int keys[4] = {0, 0, 0, 0};
    for(std::size_t i=0;i<hotkey.size() && i<4;i++)
        keys[i] = hotkey[i];

    QKeySequence keyseq(keys[0], keys[1], keys[2], keys[3]);
    return keyseq.toString();
'''
replace_once(utilhotkey, old, new, "mostrar modificador sozinho corretamente")

mainwindow = repo / "Client/qtTeamTalk/mainwindow.cpp"

old = r'''#if defined(Q_OS_LINUX) //For hotkeys on X11
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#if QT_VERSION < QT_VERSION_CHECK(6,0,0)
#include <QX11Info>
#endif
#endif /*Q_OS_LINUX */
'''

new = r'''#if defined(Q_OS_LINUX) //For hotkeys on X11
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/keysym.h>
#if QT_VERSION < QT_VERSION_CHECK(6,0,0)
#include <QX11Info>
#endif
#endif /*Q_OS_LINUX */
'''
replace_once(mainwindow, old, new, "usar interface X11 pública do Qt 6")

old = r'''#include <functional>
#include <algorithm>
using namespace std::placeholders;

extern TTInstance* ttInst;
'''

new = r'''#include <functional>
#include <algorithm>
using namespace std::placeholders;

#if defined(Q_OS_LINUX)
static Display* teamtalkHotKeyX11Display()
{
#if QT_VERSION < QT_VERSION_CHECK(6,0,0)
    return QX11Info::display();
#else
    if(auto* x11 = qGuiApp->nativeInterface<QNativeInterface::QX11Application>())
        return x11->display();
    return nullptr;
#endif
}

static KeySym teamtalkModifierKeySym(INT32 key)
{
    switch(key)
    {
    case Qt::CTRL :
        return XK_Control_L;
    case Qt::ALT :
        return XK_Alt_L;
    case Qt::SHIFT :
        return XK_Shift_L;
    case Qt::META :
        return XK_Super_L;
    default:
        return NoSymbol;
    }
}
#endif

extern TTInstance* ttInst;
'''
replace_once(mainwindow, old, new, "adicionar helpers X11/Qt6")

old = r'''#elif defined(Q_OS_LINUX) && QT_VERSION < QT_VERSION_CHECK(6,0,0)

    Display* display = QX11Info::display();
    Window x11window = QX11Info::appRootWindow();

    keycomp_t keycomp;
    quint32 mods = 0, keycode = 0;
    for(int i=0;i<hk.size();i++)
    {
        switch(hk[i])
        {
        case Qt::CTRL :
            mods |= ControlMask;
            keycomp.insert(ControlMask);
            break;
        case Qt::ALT :
            mods |= Mod1Mask;
            keycomp.insert(Mod1Mask);
            break;
        case Qt::SHIFT :
            mods |= ShiftMask;
            keycomp.insert(ShiftMask);
            break;
        default:
            keycode = XKeysymToKeycode(display, XStringToKeysym(QKeySequence(hk[i]).toString().toLatin1().data()));  
            keycomp.insert(keycode);
            break;
        }
    }

    m_hotkeys.insert(id, keycomp);
    Bool owner = True;
    int pointer = GrabModeAsync;
    int keyboard = GrabModeAsync;

    // no way to check for success
    XGrabKey(display, keycode, mods, x11window, owner, pointer, keyboard);
    // allow numlock
    XGrabKey(display, keycode, mods | Mod2Mask, x11window, owner, pointer, keyboard);

#elif defined(Q_OS_DARWIN)
'''

new = r'''#elif defined(Q_OS_LINUX)

    Display* display = teamtalkHotKeyX11Display();
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

    if(modifierOnly)
    {
        keycode = XKeysymToKeycode(display, teamtalkModifierKeySym(hk[0]));
        keycomp.insert(keycode);
    }
    else
    {
        for(int i=0;i<hk.size();i++)
        {
            switch(hk[i])
            {
            case Qt::CTRL :
                mods |= ControlMask;
                keycomp.insert(ControlMask);
                break;
            case Qt::ALT :
                mods |= Mod1Mask;
                keycomp.insert(Mod1Mask);
                break;
            case Qt::SHIFT :
                mods |= ShiftMask;
                keycomp.insert(ShiftMask);
                break;
            case Qt::META :
                mods |= Mod4Mask;
                keycomp.insert(Mod4Mask);
                break;
            default:
                keycode = XKeysymToKeycode(
                    display,
                    XStringToKeysym(QKeySequence(hk[i]).toString().toLatin1().data()));
                if(keycode)
                    keycomp.insert(keycode);
                break;
            }
        }
    }

    if(!keycode)
    {
        QMessageBox::warning(this, tr("Enable HotKey"),
                             tr("Failed to translate the selected hotkey to an X11 key."));
        return;
    }

    m_hotkeys.insert(id, keycomp);
    Bool owner = True;
    int pointer = GrabModeAsync;
    int keyboard = GrabModeAsync;

    // X11 delivers both KeyPress and KeyRelease for this passive grab.
    // MainWindow::keysActive() forwards those as active=true/false, which
    // gives Push-to-Talk the same hold-to-talk behaviour as on Windows.
    XGrabKey(display, keycode, mods, x11window, owner, pointer, keyboard);
    // allow numlock
    XGrabKey(display, keycode, mods | Mod2Mask, x11window, owner, pointer, keyboard);
    XSync(display, False);

#elif defined(Q_OS_DARWIN)
'''
replace_once(mainwindow, old, new, "registrar hotkeys X11 no Qt6 e aceitar modificador sozinho")

old = r'''#elif defined(Q_OS_LINUX) && QT_VERSION < QT_VERSION_CHECK(6,0,0)

    Display* display = QX11Info::display();
    Window window = QX11Info::appRootWindow();

    reghotkeys_t::iterator hk_ite = m_hotkeys.find(id);
    if(hk_ite != m_hotkeys.end())
    {
        quint32 mods = 0;
        quint32 keycode = 0;
        const keycomp_t& comp = hk_ite.value();
        keycomp_t::const_iterator ite = comp.begin();
        while(ite != comp.end())
        {
            switch(*ite)
            {
            case ControlMask :
                mods |= ControlMask;
                break;
            case Mod1Mask :
                mods |= Mod1Mask;
                break;
            case ShiftMask :
                mods |= ShiftMask;
                break;
            default:
                keycode = *ite;
                break;
            }
            ite++;
        }
        XUngrabKey(display, keycode, mods, window);
        XUngrabKey(display, keycode, mods | Mod2Mask, window);
    }

    m_hotkeys.remove(id);

#elif defined(Q_OS_DARWIN)
'''

new = r'''#elif defined(Q_OS_LINUX)

    Display* display = teamtalkHotKeyX11Display();

    reghotkeys_t::iterator hk_ite = m_hotkeys.find(id);
    if(display && hk_ite != m_hotkeys.end())
    {
        Window window = DefaultRootWindow(display);
        quint32 mods = 0;
        quint32 keycode = 0;
        const keycomp_t& comp = hk_ite.value();
        keycomp_t::const_iterator ite = comp.begin();
        while(ite != comp.end())
        {
            switch(*ite)
            {
            case ControlMask :
                mods |= ControlMask;
                break;
            case Mod1Mask :
                mods |= Mod1Mask;
                break;
            case ShiftMask :
                mods |= ShiftMask;
                break;
            case Mod4Mask :
                mods |= Mod4Mask;
                break;
            default:
                keycode = *ite;
                break;
            }
            ite++;
        }
        if(keycode)
        {
            XUngrabKey(display, keycode, mods, window);
            XUngrabKey(display, keycode, mods | Mod2Mask, window);
            XSync(display, False);
        }
    }

    m_hotkeys.remove(id);

#elif defined(Q_OS_DARWIN)
'''
replace_once(mainwindow, old, new, "desregistrar hotkeys X11 no Qt6")

print("Todas as alterações Linux foram aplicadas.")
