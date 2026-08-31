#!/usr/bin/env python3
"""TeamTalk left-Ctrl relay for Linux Wayland.

This privileged helper intentionally observes only EV_KEY/KEY_LEFTCTRL (code 29).
All other input events are discarded immediately and are never logged, stored or
forwarded. It exposes the current left-Ctrl state over a read-only Unix socket.
"""

from __future__ import annotations

import errno
import fcntl
import glob
import os
import select
import socket
import struct
import sys
import time
from typing import Dict, List, Set

SOCKET_PATH = "/run/teamtalk-ctrl-ptt/input.sock"
EV_KEY = 0x01
KEY_LEFTCTRL = 29

# struct input_event on the supported Ubuntu 26.04 x86_64 target:
# struct timeval (long, long), type (u16), code (u16), value (s32).
INPUT_EVENT = struct.Struct("@llHHi")

_IOC_NRBITS = 8
_IOC_TYPEBITS = 8
_IOC_SIZEBITS = 14
_IOC_NRSHIFT = 0
_IOC_TYPESHIFT = _IOC_NRSHIFT + _IOC_NRBITS
_IOC_SIZESHIFT = _IOC_TYPESHIFT + _IOC_TYPEBITS
_IOC_DIRSHIFT = _IOC_SIZESHIFT + _IOC_SIZEBITS
_IOC_READ = 2


def _ioc(direction: int, type_: int, nr: int, size: int) -> int:
    return (
        (direction << _IOC_DIRSHIFT)
        | (type_ << _IOC_TYPESHIFT)
        | (nr << _IOC_NRSHIFT)
        | (size << _IOC_SIZESHIFT)
    )


def eviocgbit(event_type: int, length: int) -> int:
    return _ioc(_IOC_READ, ord("E"), 0x20 + event_type, length)


def bit_is_set(bits: bytearray, bit: int) -> bool:
    index = bit // 8
    return index < len(bits) and bool(bits[index] & (1 << (bit % 8)))


def supports_left_ctrl(fd: int) -> bool:
    """Return True only for event devices that advertise KEY_LEFTCTRL."""
    event_bits = bytearray(32)
    fcntl.ioctl(fd, eviocgbit(0, len(event_bits)), event_bits, True)
    if not bit_is_set(event_bits, EV_KEY):
        return False

    key_bits = bytearray(64)
    fcntl.ioctl(fd, eviocgbit(EV_KEY, len(key_bits)), key_bits, True)
    return bit_is_set(key_bits, KEY_LEFTCTRL)


def open_keyboard_devices(existing_paths: Set[str]) -> Dict[int, str]:
    opened: Dict[int, str] = {}
    for path in sorted(glob.glob("/dev/input/event*")):
        if path in existing_paths:
            continue

        fd = None
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC)
            if not supports_left_ctrl(fd):
                os.close(fd)
                fd = None
                continue
            opened[fd] = path
            fd = None  # ownership moved to the returned mapping
        except (OSError, IOError):
            if fd is not None:
                try:
                    os.close(fd)
                except OSError:
                    pass
    return opened


def make_server() -> socket.socket:
    os.makedirs(os.path.dirname(SOCKET_PATH), mode=0o755, exist_ok=True)
    try:
        os.unlink(SOCKET_PATH)
    except FileNotFoundError:
        pass

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.setblocking(False)
    server.bind(SOCKET_PATH)
    # Clients may only connect/read. The helper never accepts commands from them.
    os.chmod(SOCKET_PATH, 0o666)
    server.listen(16)
    return server


def send_state(client: socket.socket, active: bool) -> bool:
    try:
        client.sendall(b"1\n" if active else b"0\n")
        return True
    except (BrokenPipeError, ConnectionResetError, OSError):
        return False


def main() -> int:
    if os.geteuid() != 0:
        print("This helper must run as root via systemd.", file=sys.stderr)
        return 1

    server = make_server()
    clients: List[socket.socket] = []
    devices: Dict[int, str] = {}
    pressed_devices: Set[str] = set()
    active = False
    last_scan = 0.0

    print("TeamTalk Ctrl PTT input helper started (KEY_LEFTCTRL only).", flush=True)

    try:
        while True:
            now = time.monotonic()
            if now - last_scan >= 1.0:
                known_paths = set(devices.values())
                devices.update(open_keyboard_devices(known_paths))
                last_scan = now

            read_fds = [server.fileno(), *devices.keys()]
            try:
                ready, _, _ = select.select(read_fds, [], [], 1.0)
            except InterruptedError:
                continue

            if server.fileno() in ready:
                while True:
                    try:
                        client, _ = server.accept()
                        client.setblocking(True)
                        if len(clients) >= 16:
                            client.close()
                            continue
                        if send_state(client, active):
                            clients.append(client)
                        else:
                            client.close()
                    except BlockingIOError:
                        break

            for fd in list(devices):
                if fd not in ready:
                    continue
                path = devices[fd]
                try:
                    data = os.read(fd, INPUT_EVENT.size * 64)
                    if not data:
                        raise OSError(errno.ENODEV, "input device closed")

                    for offset in range(0, len(data) - INPUT_EVENT.size + 1, INPUT_EVENT.size):
                        _sec, _usec, event_type, code, value = INPUT_EVENT.unpack_from(data, offset)
                        if event_type != EV_KEY or code != KEY_LEFTCTRL:
                            continue
                        if value == 1:
                            pressed_devices.add(path)
                        elif value == 0:
                            pressed_devices.discard(path)
                        else:
                            # Ignore auto-repeat (value 2) and unexpected values.
                            continue

                        new_active = bool(pressed_devices)
                        if new_active == active:
                            continue
                        active = new_active

                        alive: List[socket.socket] = []
                        for client in clients:
                            if send_state(client, active):
                                alive.append(client)
                            else:
                                try:
                                    client.close()
                                except OSError:
                                    pass
                        clients = alive
                except (BlockingIOError, InterruptedError):
                    continue
                except OSError:
                    try:
                        os.close(fd)
                    except OSError:
                        pass
                    devices.pop(fd, None)
                    if path in pressed_devices:
                        pressed_devices.discard(path)
                        new_active = bool(pressed_devices)
                        if new_active != active:
                            active = new_active
                            alive = []
                            for client in clients:
                                if send_state(client, active):
                                    alive.append(client)
                                else:
                                    try:
                                        client.close()
                                    except OSError:
                                        pass
                            clients = alive
    finally:
        for client in clients:
            try:
                client.close()
            except OSError:
                pass
        for fd in devices:
            try:
                os.close(fd)
            except OSError:
                pass
        try:
            server.close()
        except OSError:
            pass
        try:
            os.unlink(SOCKET_PATH)
        except FileNotFoundError:
            pass

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
