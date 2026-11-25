#!/usr/bin/env python3
"""The companion peer: stdlib-only server side of the companion protocol.

The companion extension (`companion-extension/`) runs in the user's Chromium
and is the SERVER of tool executions: it connects its native-messaging host
(a byte pipe) to this peer's unix socket, says hello, and then answers the
requests we send. This module listens on that socket, accepts multiple host
connections, reads the hello, and offers ``request(tool, params)``: unique
string ids, response matching with timeouts, thread-safe.

Wire framing, both directions: UInt32 little-endian length + UTF-8 JSON, the
native-messaging framing (the host strips and re-adds it on its side of the
pipe, so on the socket the same framing carries whole JSON messages).

Socket path: ``LILO_COMPANION_SOCK``, or ``$XDG_RUNTIME_DIR/lilo/companion.sock``,
or ``/tmp/lilo-companion.sock`` (the Linux-appropriate defaults the extension's
packaging documents; the macOS default differs and never applies here).
"""

import json
import os
import socket
import struct
import threading
import time
import uuid

MAX_FRAME = 32 * 1024 * 1024  # a page snapshot can be large, but not unbounded


def default_socket_path():
    if os.environ.get("LILO_COMPANION_SOCK"):
        return os.environ["LILO_COMPANION_SOCK"]
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    if runtime:
        return os.path.join(runtime, "lilo", "companion.sock")
    return "/tmp/lilo-companion.sock"


class PeerError(Exception):
    """A request that will not get a useful answer: no connection, a dead
    one, a timeout, or the extension's own error message."""


class _Connection:
    """One connected native-messaging host: a reader thread that dispatches
    hello and responses back to the peer."""

    def __init__(self, peer, conn):
        self.peer = peer
        self.conn = conn
        self.alive = True
        self.lock = threading.Lock()

    def serve(self):
        try:
            while True:
                message = _read_frame(self.conn)
                if message is None:
                    break
                self.peer._dispatch(self, message)
        except (OSError, ValueError):
            pass
        finally:
            self._close()

    def _close(self):
        self.alive = False
        try:
            self.conn.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            self.conn.close()
        except OSError:
            pass
        self.peer._dropped(self)

    def send(self, message):
        with self.lock:
            if not self.alive:
                raise PeerError("the companion connection is closed")
            try:
                _write_frame(self.conn, message)
            except OSError as error:
                self._close()
                raise PeerError(f"writing to the companion socket failed: {error}") from error


def _read_frame(conn):
    """One framed message, or None on a clean EOF. A frame longer than
    MAX_FRAME or a body that is not UTF-8 JSON raises ValueError: the caller
    drops the connection (a desynchronized stream cannot be trusted further)."""
    header = _recv_exact(conn, 4)
    if header is None:
        return None
    (length,) = struct.unpack("<I", header)
    if length == 0 or length > MAX_FRAME:
        raise ValueError(f"bad frame length {length}")
    body = _recv_exact(conn, length)
    if body is None:
        return None
    return json.loads(body.decode("utf-8"))


def _recv_exact(conn, count):
    chunks = []
    remaining = count
    while remaining:
        chunk = conn.recv(remaining)
        if not chunk:
            return None
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def _write_frame(conn, message):
    body = json.dumps(message, separators=(",", ":")).encode("utf-8")
    conn.sendall(struct.pack("<I", len(body)) + body)


class CompanionPeer:
    """Listens on the companion socket and speaks the request/response half
    of the protocol. Requests go to one live connection (the last to say
    hello); every connection's responses are matched by id."""

    def __init__(self, path=None):
        self.path = path or default_socket_path()
        self._lock = threading.Lock()
        self._conns = []  # connections that have said hello, most recent last
        self._waiters = {}  # request id -> (event, slot)
        self._server = None
        self._hello_count = 0

    # -- lifecycle -----------------------------------------------------------

    def start(self):
        directory = os.path.dirname(self.path)
        if directory:
            os.makedirs(directory, exist_ok=True)
        try:
            os.unlink(self.path)
        except FileNotFoundError:
            pass
        except OSError:
            pass  # a stale socket in /run: bind fails below with the real reason
        self._server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._server.bind(self.path)
        self._server.listen(8)
        thread = threading.Thread(target=self._accept, daemon=True)
        thread.start()
        return self

    def stop(self):
        if self._server:
            try:
                self._server.close()
            except OSError:
                pass
        with self._lock:
            conns, self._conns = self._conns, []
            waiters, self._waiters = self._waiters, {}
        for conn in conns:
            conn._close()
        for event, _slot in waiters.values():
            event.set()
        try:
            os.unlink(self.path)
        except OSError:
            pass

    def _accept(self):
        while True:
            try:
                conn, _addr = self._server.accept()
            except OSError:
                return  # stop() closed the listener
            connection = _Connection(self, conn)
            threading.Thread(target=connection.serve, daemon=True).start()

    # -- protocol ------------------------------------------------------------

    def _dispatch(self, connection, message):
        if not isinstance(message, dict):
            return  # tolerated: ignored, per the contract's malformed rules
        if message.get("type") == "hello":
            with self._lock:
                self._hello_count += 1
                if connection not in self._conns:
                    self._conns.append(connection)
            return
        request_id = message.get("id")
        if not isinstance(request_id, str):
            return
        with self._lock:
            waiter = self._waiters.pop(request_id, None)
        if waiter:
            waiter[1]["value"] = message
            waiter[0].set()

    def _dropped(self, connection):
        with self._lock:
            if connection in self._conns:
                self._conns.remove(connection)
            for _request_id, (event, slot) in self._waiters.items():
                # Wake every waiter: the connection their request went to is
                # gone, so the answer (if any) will never arrive.
                slot.setdefault("value", {"__liloGone": True})
                event.set()

    def wait_connected(self, timeout=30.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with self._lock:
                if self._conns:
                    return True
            time.sleep(0.05)
        return False

    def request(self, tool, params, timeout=30.0):
        """One tool call: sends on a live connection and waits for the
        response with that id. Raises PeerError when no connection exists,
        the wire breaks, the deadline passes, or the extension reported an
        error for this call."""
        request_id = "p" + uuid.uuid4().hex
        message = {"id": request_id, "tool": tool, "params": params}
        event = threading.Event()
        slot = {}
        with self._lock:
            if not self._conns:
                raise PeerError(
                    "no companion connection: the extension's native host is not "
                    f"connected to {self.path}")
            connection = self._conns[-1]
            self._waiters[request_id] = (event, slot)
        try:
            connection.send(message)
        except PeerError:
            with self._lock:
                self._waiters.pop(request_id, None)
            raise
        if not event.wait(timeout):
            with self._lock:
                self._waiters.pop(request_id, None)
            raise PeerError(f"{tool} got no response within {timeout} s")
        response = slot.get("value")
        if response == {"__liloGone": True}:
            raise PeerError("the companion connection closed before answering")
        if not isinstance(response, dict):
            raise PeerError(f"{tool} got a malformed response")
        if response.get("id") != request_id:
            raise PeerError(f"{tool} response id mismatch: {response.get('id')!r}")
        if response.get("ok") is not True:
            raise PeerError(str(response.get("error") or f"{tool} failed"))
        result = response.get("result")
        if isinstance(result, dict) and result.get("tool") != tool:
            raise PeerError(f"{tool} response carried tool {result.get('tool')!r}")
        return result

    def close_tab(self, tab_id, timeout=10.0):
        """Closes a tab by scripting: the companion protocol has no
        tabs.close tool, so this is a best-effort documented gap. Raises
        PeerError when the page script path is unavailable; callers decide
        how loud that is."""
        return self.request("scripting.execute", {
            "tabId": int(tab_id),
            "funcSource": "() => { window.close(); return true }",
        }, timeout=timeout)

