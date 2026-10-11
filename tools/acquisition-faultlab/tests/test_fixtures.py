"""Each fault fixture must behave exactly as its scenario declares.

These tests pin the SERVER contract (headers, wire bytes, severing behavior),
independent of any download client. The expected final-byte records in
scenarios.json are re-derived here from (seed, size).
"""

import http.client
import json
import socket
import urllib.error
import urllib.request

import pytest

from fixture_server import corrupt_bytes, sha256_hex, synthetic_content


def by_id(lab_scenarios):
    return {s["id"]: s for s in lab_scenarios}


def raw_get(url: str, timeout: float = 10.0):
    """urllib GET returning (status, headers, body, error)."""
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            return resp.status, dict(resp.headers), resp.read(), None
    except urllib.error.HTTPError as exc:
        return exc.code, dict(exc.headers), b"", exc
    except Exception as exc:  # transport-level failure
        return None, {}, b"", exc


def content_of(scn: dict) -> bytes:
    return synthetic_content(scn["content"]["seed"], scn["content"]["size"])


# -- clean control ------------------------------------------------------------

def test_clean_control_serves_exact_declared_bytes(server_factory, lab_scenarios):
    scn = by_id(lab_scenarios)["clean-rgb-control"]
    with server_factory("clean-rgb-control") as srv:
        status, headers, body, err = raw_get(srv.scenario_url(scn["id"]))
    assert err is None and status == 200
    assert headers["Content-Type"] == "image/png"
    assert int(headers["Content-Length"]) == scn["expect"]["content_size"]
    assert sha256_hex(body) == scn["expect"]["content_sha256"]


# -- truncation ----------------------------------------------------------------

def test_truncation_declares_full_length_sends_prefix_then_eof(server_factory, lab_scenarios):
    """Wire-level: honest full-length header, prefix payload, clean EOF."""
    scn = by_id(lab_scenarios)["truncation-rgb-clean-eof"]
    content = content_of(scn)
    cut = scn["serve"]["truncate_at_bytes"]
    with server_factory(scn["id"]) as srv:
        status, headers, body, err = raw_get(srv.scenario_url(scn["id"]))
        assert isinstance(err, http.client.IncompleteRead)
        assert err.partial == content[:cut]
        # urlopen discards response metadata on IncompleteRead, so re-read the
        # response at the socket level to pin the header contract.
        path = f"/sc/{scn['id']}"
        with socket.create_connection(("127.0.0.1", srv.port), timeout=10) as sock:
            sock.sendall(f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n".encode())
            raw = b""
            while True:
                chunk = sock.recv(65536)
                if not chunk:
                    break
                raw += chunk
    head, _, payload = raw.partition(b"\r\n\r\n")
    assert head.splitlines()[0].startswith(b"HTTP/1.1 200")
    header_lines = head.decode("latin-1").splitlines()[1:]
    assert any(line.lower() == f"content-length: {scn['expect']['content_size']}" for line in header_lines)
    assert payload == content[:cut]
    log = srv.requests_for(scn["id"])
    assert log[0]["bytes_sent"] == cut and log[0]["end"] == "eof"


def test_truncation_depth_prefix_matches_expected_record(server_factory, lab_scenarios):
    scn = by_id(lab_scenarios)["truncation-depth-clean-eof"]
    content = content_of(scn)
    cut = scn["serve"]["truncate_at_bytes"]
    with server_factory(scn["id"]) as srv:
        _, headers, _, err = raw_get(srv.scenario_url(scn["id"]))
        assert isinstance(err, http.client.IncompleteRead)
        assert err.partial == content[:cut]
    assert sha256_hex(content[:cut]) == scn["expect"]["served_sha256"]
    assert scn["expect"]["served_size"] == cut


def test_interrupted_write_ends_in_rst(server_factory, lab_scenarios):
    scn = by_id(lab_scenarios)["interrupted-write-rgb-rst"]
    with server_factory(scn["id"]) as srv:
        status, headers, body, err = raw_get(srv.scenario_url(scn["id"]))
        assert err is not None  # abrupt transport failure, not a clean response
        log = srv.requests_for(scn["id"])
    assert log[0]["end"] == "rst"
    assert log[0]["bytes_sent"] == scn["serve"]["truncate_at_bytes"]


# -- content length ------------------------------------------------------------

def test_understated_content_length_delivers_partial_image(server_factory, lab_scenarios):
    """Header understates the body: the client keeps only the declared prefix."""
    scn = by_id(lab_scenarios)["wrong-content-length-understated"]
    content = content_of(scn)
    declared = scn["expect"]["content_size"] + scn["serve"]["length_delta"]
    with server_factory(scn["id"]) as srv:
        status, headers, body, err = raw_get(srv.scenario_url(scn["id"]))
    assert err is None and status == 200
    assert int(headers["Content-Length"]) == declared
    assert len(body) == declared
    assert body == content[:declared]  # exact prefix of the correct image
    assert sha256_hex(body) != scn["expect"]["content_sha256"]


def test_overstated_content_length_fails_the_read(server_factory, lab_scenarios):
    scn = by_id(lab_scenarios)["wrong-content-length-overstated"]
    content = content_of(scn)
    with server_factory(scn["id"]) as srv:
        status, headers, body, err = raw_get(srv.scenario_url(scn["id"]))
        assert isinstance(err, http.client.IncompleteRead)
        assert err.partial == content  # full bytes arrived, declared length not met


# -- content type ---------------------------------------------------------------

def test_wrong_content_type_served_with_intact_bytes(server_factory, lab_scenarios):
    scn = by_id(lab_scenarios)["wrong-content-type-html"]
    with server_factory(scn["id"]) as srv:
        status, headers, body, err = raw_get(srv.scenario_url(scn["id"]))
    assert err is None and status == 200
    assert headers["Content-Type"].startswith("text/html")
    assert sha256_hex(body) == scn["expect"]["content_sha256"]


# -- hash -----------------------------------------------------------------------

def test_wrong_hash_serves_same_size_altered_bytes(server_factory, lab_scenarios):
    scn = by_id(lab_scenarios)["wrong-hash-same-size-depth"]
    content = content_of(scn)
    served = corrupt_bytes(content, scn["serve"]["corrupt_at_bytes"])
    with server_factory(scn["id"]) as srv:
        status, headers, body, err = raw_get(srv.scenario_url(scn["id"]))
    assert err is None and status == 200
    assert len(body) == len(content) == scn["expect"]["content_size"]
    assert sha256_hex(body) == scn["expect"]["served_sha256"] == sha256_hex(served)
    assert sha256_hex(body) != scn["expect"]["content_sha256"]


# -- redirects --------------------------------------------------------------------

def test_redirect_single_hop_serves_final_bytes(server_factory, lab_scenarios):
    scn = by_id(lab_scenarios)["redirect-one-hop"]
    with server_factory(scn["id"]) as srv:
        status, headers, body, err = raw_get(srv.scenario_url(scn["id"]))
        log = srv.requests_for(scn["id"])
    assert err is None and status == 200
    assert sha256_hex(body) == scn["expect"]["content_sha256"]
    assert [r["status"] for r in log] == [302, 200]


def test_redirect_three_hops_serves_final_bytes(server_factory, lab_scenarios):
    scn = by_id(lab_scenarios)["redirect-three-hops"]
    with server_factory(scn["id"]) as srv:
        status, headers, body, err = raw_get(srv.scenario_url(scn["id"]))
        log = srv.requests_for(scn["id"])
    assert err is None and status == 200
    assert sha256_hex(body) == scn["expect"]["content_sha256"]
    assert [r["status"] for r in log] == [302, 302, 302, 200]


def test_redirect_to_missing_final_404(server_factory, lab_scenarios):
    scn = by_id(lab_scenarios)["redirect-final-404"]
    with server_factory(scn["id"]) as srv:
        status, headers, body, err = raw_get(srv.scenario_url(scn["id"]))
        log = srv.requests_for(scn["id"])
    assert isinstance(err, urllib.error.HTTPError) and err.code == 404
    assert [r["status"] for r in log] == [302, 404]


# -- empty -------------------------------------------------------------------------

def test_empty_depth_serves_zero_bytes_with_200(server_factory, lab_scenarios):
    scn = by_id(lab_scenarios)["empty-depth-raw"]
    with server_factory(scn["id"]) as srv:
        status, headers, body, err = raw_get(srv.scenario_url(scn["id"]))
    assert err is None and status == 200
    assert int(headers["Content-Length"]) == 0
    assert body == b""
    assert scn["expect"]["served_size"] == 0
    assert sha256_hex(body) == scn["expect"]["served_sha256"]


# -- transient statuses -------------------------------------------------------------

def test_transient_503_recovers_after_fail_times(server_factory, lab_scenarios):
    scn = by_id(lab_scenarios)["transient-503-recovers"]
    fail_times = scn["serve"]["fail_times"]
    with server_factory(scn["id"]) as srv:
        statuses = []
        body = None
        for _ in range(fail_times + 1):
            status, headers, data, err = raw_get(srv.scenario_url(scn["id"]))
            statuses.append(err.code if isinstance(err, urllib.error.HTTPError) else status)
            if status == 200:
                body = data
        log = srv.requests_for(scn["id"])
    assert statuses == [503] * fail_times + [200]
    assert sha256_hex(body) == scn["expect"]["content_sha256"]


def test_transient_429_persists_on_every_request(server_factory, lab_scenarios):
    scn = by_id(lab_scenarios)["transient-429-exhausted"]
    with server_factory(scn["id"]) as srv:
        for _ in range(scn["serve"]["fail_times"]):
            status, headers, body, err = raw_get(srv.scenario_url(scn["id"]))
            assert isinstance(err, urllib.error.HTTPError) and err.code == 429
        log = srv.requests_for(scn["id"])
    assert all(r["status"] == 429 for r in log)
