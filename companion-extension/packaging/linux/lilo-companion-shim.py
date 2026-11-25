#!/usr/bin/env python3
"""The Linux native-messaging host for the Lilo companion extension.

Chromium starts this as the host named com.getlilo.lilo.companion and speaks
native messaging over its stdio. Like the macOS host binary it answers nothing
itself: it is a byte pipe between stdio and the unix socket the Lilo peer (the
headless container, or a running install) listens on, so the protocol schema is
validated only where it is spoken. With no peer listening it exits at once and
the extension's reconnect backoff carries the retry.
"""
import os
import selectors
import socket
import sys

BUFFER = 64 * 1024


def socket_path() -> str:
    override = os.environ.get("LILO_COMPANION_SOCK")
    if override:
        return override
    runtime = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
    return os.path.join(runtime, "lilo", "companion.sock")


def main() -> int:
    peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        peer.connect(socket_path())
    except OSError:
        return 1

    selector = selectors.DefaultSelector()
    selector.register(sys.stdin.buffer.raw, selectors.EVENT_READ, "stdin")
    selector.register(peer, selectors.EVENT_READ, "peer")
    open_ends = {"stdin", "peer"}

    while open_ends:
        for key, _ in selector.select():
            try:
                data = os.read(key.fileobj.fileno(), BUFFER)
            except OSError:
                data = b""
            if not data:
                # One direction closed: stop reading it, but let the other drain.
                selector.unregister(key.fileobj)
                open_ends.discard(key.data)
                if key.data == "stdin":
                    peer.shutdown(socket.SHUT_WR)
                continue
            target_fd = peer.fileno() if key.data == "stdin" else sys.stdout.fileno()
            try:
                written = 0
                while written < len(data):
                    written += os.write(target_fd, data[written:])
            except OSError:
                return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
