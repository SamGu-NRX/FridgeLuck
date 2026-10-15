"""Loopback-only fault-injection HTTP fixture server for acquisition testing.

Serves deterministic synthetic image payloads from 127.0.0.1 with declared
faults: truncation (clean EOF and RST), wrong Content-Length, wrong
Content-Type, wrong payload hash, redirects, empty bodies, and transient
error statuses. Every scenario carries exact expected final-byte records
(sha256 + size) so a harness can prove byte correctness or its absence.

The server binds ONLY to 127.0.0.1 on an ephemeral port. It has no outbound
network capability and refuses to construct non-loopback URLs. All payloads
are synthetic; nothing here fetches, mirrors, or references a public corpus.
"""

from __future__ import annotations

import hashlib
import socket
import struct
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

LOOPBACK_HOSTS = {"127.0.0.1", "localhost", "::1"}

PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


class NonLoopbackURL(RuntimeError):
    """Raised when a URL does not target the loopback interface."""


def require_loopback_url(url: str) -> str:
    """Return the host of `url`, raising NonLoopbackURL unless it is loopback."""
    host = (urlsplit(url).hostname or "").lower()
    if host not in LOOPBACK_HOSTS:
        raise NonLoopbackURL(f"refusing non-loopback URL host {host!r}: {url}")
    return host


def synthetic_content(seed: str, size: int) -> bytes:
    """Deterministic PNG-magic-prefixed synthetic payload of exactly `size` bytes."""
    if size < len(PNG_MAGIC):
        raise ValueError("size must be at least the PNG magic length")
    body = hashlib.shake_256(seed.encode()).digest(size)
    return PNG_MAGIC + body[len(PNG_MAGIC):]


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class FaultServer:
    """Threaded HTTP server bound to 127.0.0.1 implementing scenario faults."""

    def __init__(self, scenarios: list[dict]):
        self.scenarios = {s["id"]: s for s in scenarios}
        self.request_log: list[dict] = []
        self._log_lock = threading.Lock()
        self._counters: dict[str, int] = {}
        self._counter_lock = threading.Lock()
        self._httpd = _FaultHTTPD(("127.0.0.1", 0), _Handler)
        self._httpd.faultlab = self
        self._thread = threading.Thread(target=self._httpd.serve_forever, daemon=True)

    # -- lifecycle ----------------------------------------------------------
    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        """Stop the serve loop and release the socket. Safe if never started."""
        if self._thread.is_alive():
            self._httpd.shutdown()
        self._httpd.server_close()

    def __enter__(self) -> "FaultServer":
        self.start()
        return self

    def __exit__(self, *exc) -> None:
        self.stop()

    # -- introspection ------------------------------------------------------
    @property
    def port(self) -> int:
        return self._httpd.server_address[1]

    @property
    def bind_host(self) -> str:
        return self._httpd.server_address[0]

    @property
    def base_url(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    def scenario_url(self, scenario_id: str) -> str:
        require_loopback_url(self.base_url)
        return f"{self.base_url}/sc/{scenario_id}"

    def log_request(self, record: dict) -> None:
        with self._log_lock:
            self.request_log.append(record)

    def requests_for(self, scenario_id: str) -> list[dict]:
        with self._log_lock:
            return [r for r in self.request_log if r["scenario_id"] == scenario_id]

    def next_counter(self, scenario_id: str) -> int:
        with self._counter_lock:
            n = self._counters.get(scenario_id, 0)
            self._counters[scenario_id] = n + 1
            return n


class _FaultHTTPD(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


class _Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    timeout = 30

    # Silence default stderr chatter; the request log is the record.
    def log_message(self, *args) -> None:  # noqa: D102
        pass

    # -- helpers ------------------------------------------------------------
    def _send_headers(self, status: int, content_type: str, length: int | None, close: bool,
                      location: str | None = None) -> None:
        self.send_response(status)
        if content_type is not None:
            self.send_header("Content-Type", content_type)
        if length is not None:
            self.send_header("Content-Length", str(length))
        if location is not None:
            self.send_header("Location", location)
        if close:
            self.send_header("Connection", "close")
            self.close_connection = True
        self.end_headers()

    def _sever_with_rst(self) -> None:
        """Force a TCP RST so the client sees an abrupt connection failure."""
        self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        self.close_connection = True

    # -- dispatch -----------------------------------------------------------
    def do_GET(self) -> None:  # noqa: N802
        lab: FaultServer = self.server.faultlab  # type: ignore[attr-defined]
        split = urlsplit(self.path)
        parts = split.path.strip("/").split("/")
        if len(parts) >= 2 and parts[0] == "sc":
            scenario_id = parts[1]                       # canonical: /sc/<id>
        elif len(parts) >= 2 and parts[0] == "imagery":
            scenario_id = parts[1]                       # adapter-shaped: /imagery/<id>/<dish>/<fname>
        else:
            scenario_id = split.path
        qs = parse_qs(split.query)
        scenario = lab.scenarios.get(scenario_id)
        if scenario is None:
            self._send_headers(404, "text/plain", 0, close=True)
            lab.log_request({"scenario_id": scenario_id, "status": 404, "bytes_sent": 0,
                             "range": self.headers.get("Range"), "end": "complete"})
            return

        seq = lab.next_counter(scenario_id)
        fault = scenario["fault"]
        content = synthetic_content(scenario["content"]["seed"], scenario["content"]["size"])
        serve = scenario["serve"]
        range_header = self.headers.get("Range")

        def record(status: int, sent: int, end: str) -> None:
            lab.log_request({"scenario_id": scenario_id, "seq": seq, "status": status,
                             "bytes_sent": sent, "range": range_header, "end": end})

        # Transient-status faults: serve a failing status for the first
        # `fail_times` requests, then a clean 200. The request is logged
        # BEFORE the response is written so a completed client read can
        # never race the log.
        if fault == "transient_status":
            fail_times = serve["fail_times"]
            if seq < fail_times:
                status = serve["status"]
                record(status, 0, "complete")
                self._send_headers(status, "text/plain", 0, close=True)
                return
            record(200, len(content), "complete")
            self._send_headers(200, serve.get("content_type", "image/png"), len(content), close=True)
            self.wfile.write(content)
            return

        # Redirect faults: each hop has a distinct URL (query param) so urllib's
        # self-redirect loop guard never trips; the final request serves the plan.
        if fault == "redirect":
            hops = serve["hops"]
            hop = int(qs.get("hop", ["0"])[0])
            if hop < hops:
                location = f"{lab.base_url}/sc/{scenario_id}?hop={hop + 1}"
                record(302, 0, "complete")
                self._send_headers(302, "text/plain", 0, close=True, location=location)
                return
            if serve.get("final_404"):
                record(404, 0, "complete")
                self._send_headers(404, "text/plain", 0, close=True)
                return
            record(200, len(content), "complete")
            self._send_headers(200, serve.get("content_type", "image/png"), len(content), close=True)
            self.wfile.write(content)
            return

        # Body faults: all served as 200 with a per-fault body plan.
        if fault == "truncation":
            cut = serve["truncate_at_bytes"]
            record(200, cut, serve.get("end", "eof"))
            self._send_headers(200, serve.get("content_type", "image/png"), len(content), close=True)
            self.wfile.write(content[:cut])
            self.wfile.flush()
            if serve.get("end") == "rst":
                self._sever_with_rst()
            return

        if fault == "wrong_content_length":
            delta = serve["length_delta"]
            declared = len(content) + delta
            record(200, len(content), "complete")
            self._send_headers(200, serve.get("content_type", "image/png"), declared, close=True)
            self.wfile.write(content)
            self.wfile.flush()
            return

        if fault == "wrong_content_type":
            record(200, len(content), "complete")
            self._send_headers(200, serve["content_type"], len(content), close=True)
            self.wfile.write(content)
            return

        if fault == "wrong_hash":
            served = corrupt_bytes(content, serve["corrupt_at_bytes"])
            record(200, len(served), "complete")
            self._send_headers(200, serve.get("content_type", "image/png"), len(served), close=True)
            self.wfile.write(served)
            return

        if fault == "empty":
            record(200, 0, "complete")
            self._send_headers(200, serve.get("content_type", "image/png"), 0, close=True)
            return

        if fault == "clean":
            record(200, len(content), "complete")
            self._send_headers(200, serve.get("content_type", "image/png"), len(content), close=True)
            self.wfile.write(content)
            return

        record(500, 0, "complete")
        self._send_headers(500, "text/plain", 0, close=True)


def corrupt_bytes(content: bytes, offset: int) -> bytes:
    """Deterministically alter one payload region, preserving total length."""
    mutate = bytearray(content)
    for i in range(offset, min(offset + 64, len(mutate))):
        mutate[i] ^= 0xFF
    return bytes(mutate)


# -- guarded urllib opener ---------------------------------------------------
# Installed by run.py so every urllib request in the harness process (including
# those issued by the PR41 adapter) fails fast on any non-loopback URL.
import urllib.request as _ur  # noqa: E402


class LoopbackGuardedHTTPHandler(_ur.HTTPHandler):
    def http_open(self, req):
        require_loopback_url(req.full_url)
        return super().http_open(req)


class LoopbackGuardedHTTPSHandler(_ur.HTTPSHandler):
    def https_open(self, req):
        require_loopback_url(req.full_url)
        return super().https_open(req)


def install_loopback_opener() -> "urllib.request.OpenerDirector":
    opener = _ur.build_opener(
        LoopbackGuardedHTTPHandler,
        LoopbackGuardedHTTPSHandler,
        _ur.HTTPRedirectHandler,
        _ur.HTTPDefaultErrorHandler,
        _ur.HTTPErrorProcessor,
    )
    _ur.install_opener(opener)
    return opener
