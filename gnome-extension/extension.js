import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const SERVICE = 'org.teamtalk.CtrlPTT';
const OBJECT_PATH = '/org/teamtalk/CtrlPTT';
const INTERFACE = 'org.teamtalk.CtrlPTT';
const METHOD = 'setGnomeCtrlPttPressed';

export default class TeamTalkCtrlPttExtension extends Extension {
    enable() {
        this._ctrlDown = false;

        // captured-event is emitted before the focused application receives
        // the event. Returning false is intentional: Ctrl remains available
        // to GNOME and applications, so Ctrl+Tab/Ctrl+C/etc. still work while
        // TeamTalk treats the held left Ctrl as Push-to-Talk.
        this._capturedEventId = global.stage.connect(
            'captured-event',
            (_actor, event) => this._onCapturedEvent(event)
        );
    }

    disable() {
        // Never leave TeamTalk transmitting if the extension is disabled
        // while Ctrl is physically held.
        if (this._ctrlDown)
            this._sendState(false);

        this._ctrlDown = false;

        if (this._capturedEventId) {
            global.stage.disconnect(this._capturedEventId);
            this._capturedEventId = 0;
        }
    }

    _onCapturedEvent(event) {
        const type = event.type();
        if (type !== Clutter.EventType.KEY_PRESS &&
            type !== Clutter.EventType.KEY_RELEASE)
            return false;

        // Deliberately only the physical/symbolic left Ctrl is PTT.
        // Right Ctrl remains a normal modifier.
        if (event.get_key_symbol() !== Clutter.KEY_Control_L)
            return false;

        const down = type === Clutter.EventType.KEY_PRESS;

        // Ignore auto-repeat/duplicate state notifications. PTT changes only
        // on the real transition from released->pressed or pressed->released.
        if (down === this._ctrlDown)
            return false;

        this._ctrlDown = down;
        this._sendState(down);

        // Do not consume the key. This is why Ctrl+Tab, Ctrl+C and all other
        // Ctrl combinations continue to reach the desktop/applications.
        return false;
    }

    _sendState(active) {
        // Call the TeamTalk-owned D-Bus service directly instead of emitting
        // an unaddressed broadcast signal. The method call is asynchronous so
        // the GNOME Shell never blocks while TeamTalk handles the PTT change.
        Gio.DBus.session.call(
            SERVICE,
            OBJECT_PATH,
            INTERFACE,
            METHOD,
            new GLib.Variant('(b)', [active]),
            null,
            Gio.DBusCallFlags.NONE,
            1000,
            null,
            (connection, result) => {
                try {
                    connection.call_finish(result);
                } catch (error) {
                    // TeamTalk may simply not be running yet. Keep the Shell
                    // quiet and log the failure for diagnostics only.
                    console.debug(`TeamTalk Ctrl PTT: D-Bus call not delivered: ${error}`);
                }
            }
        );
    }
}

// Build synchronization marker: package client, extension and accessible installer together.
