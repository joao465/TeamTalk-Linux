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

        // GNOME's modern keyboard event controller. The controller is attached
        // to the global stage and observes key press/release without consuming
        // the key, so Ctrl+Tab/Ctrl+C/etc. continue to work normally.
        this._keyController = new Clutter.KeyController();
        this._keyPressId = this._keyController.connect('key-press', () => {
            this._onControllerKey(true);
            return Clutter.EVENT_PROPAGATE;
        });
        this._keyReleaseId = this._keyController.connect('key-release', () => {
            this._onControllerKey(false);
            return Clutter.EVENT_PROPAGATE;
        });
        global.stage.add_action(this._keyController);

        // Keep captured-event as a compatibility fallback. State deduplication
        // guarantees that only one D-Bus transition is sent even if both paths
        // observe the same physical key event.
        this._capturedEventId = global.stage.connect(
            'captured-event',
            (_actor, event) => this._onCapturedEvent(event)
        );

        console.log('TeamTalk Ctrl PTT v3: extension enabled');
    }

    disable() {
        if (this._ctrlDown)
            this._setCtrlState(false, 'disable');

        if (this._capturedEventId) {
            global.stage.disconnect(this._capturedEventId);
            this._capturedEventId = 0;
        }

        if (this._keyController) {
            if (this._keyPressId)
                this._keyController.disconnect(this._keyPressId);
            if (this._keyReleaseId)
                this._keyController.disconnect(this._keyReleaseId);
            global.stage.remove_action(this._keyController);
            this._keyController = null;
        }

        this._ctrlDown = false;
        console.log('TeamTalk Ctrl PTT v3: extension disabled');
    }

    _onControllerKey(down) {
        if (!this._keyController)
            return;

        const [ok, symbol, code] = this._keyController.get_key();
        if (!ok || symbol !== Clutter.KEY_Control_L)
            return;

        this._setCtrlState(down, `KeyController code=${code}`);
    }

    _onCapturedEvent(event) {
        const type = event.type();
        if (type !== Clutter.EventType.KEY_PRESS &&
            type !== Clutter.EventType.KEY_RELEASE)
            return Clutter.EVENT_PROPAGATE;

        if (event.get_key_symbol() !== Clutter.KEY_Control_L)
            return Clutter.EVENT_PROPAGATE;

        this._setCtrlState(type === Clutter.EventType.KEY_PRESS, 'captured-event');
        return Clutter.EVENT_PROPAGATE;
    }

    _setCtrlState(down, source) {
        if (down === this._ctrlDown)
            return;

        this._ctrlDown = down;
        console.log(`TeamTalk Ctrl PTT v3: Ctrl ${down ? 'pressed' : 'released'} via ${source}`);
        this._sendState(down);
    }

    _sendState(active) {
        Gio.DBus.session.call(
            SERVICE,
            OBJECT_PATH,
            INTERFACE,
            METHOD,
            new GLib.Variant('(b)', [active]),
            null,
            Gio.DBusCallFlags.NONE,
            1500,
            null,
            (connection, result) => {
                try {
                    connection.call_finish(result);
                    console.log(`TeamTalk Ctrl PTT v3: D-Bus ${active ? 'ON' : 'OFF'} delivered`);
                } catch (error) {
                    console.warn(`TeamTalk Ctrl PTT v3: D-Bus delivery failed: ${error}`);
                }
            }
        );
    }
}
