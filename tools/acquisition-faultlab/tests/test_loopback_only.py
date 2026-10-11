"""Prove the fault lab is loopback-only: bind address, URL guard, manifest."""

import urllib.request

import pytest

from fixture_server import (
    LOOPBACK_HOSTS,
    LoopbackGuardedHTTPHandler,
    LoopbackGuardedHTTPSHandler,
    NonLoopbackURL,
    FaultServer,
    require_loopback_url,
)

PUBLIC_URLS = [
    "https://storage.googleapis.com/nutrition5k_dataset/nutrition5k_dataset/imagery/x.png",
    "http://example.com/sc/clean-rgb-control",
    "http://0.0.0.0:8000/sc/clean-rgb-control",
    "http://10.1.2.3:9000/sc/x",
    "http://192.168.1.5/sc/x",
    "http://172.16.0.9/sc/x",
    "https://raw.githubusercontent.com/SamGu-NRX/FridgeLuck/main/README.md",
]

LOOPBACK_URLS = [
    "http://127.0.0.1:8000/sc/x",
    "http://localhost:8000/sc/x",
    "http://[::1]:8000/sc/x",
]


def test_server_binds_loopback_only(server_factory):
    srv: FaultServer = server_factory("clean-rgb-control")
    assert srv.bind_host == "127.0.0.1"
    assert srv.base_url.startswith("http://127.0.0.1:")


@pytest.mark.parametrize("url", PUBLIC_URLS)
def test_require_loopback_rejects_public_hosts(url):
    with pytest.raises(NonLoopbackURL):
        require_loopback_url(url)


@pytest.mark.parametrize("url", LOOPBACK_URLS)
def test_require_loopback_accepts_loopback(url):
    assert require_loopback_url(url) in LOOPBACK_HOSTS


def test_guarded_handler_refuses_public_host_before_any_socket():
    handler = LoopbackGuardedHTTPHandler()
    req = urllib.request.Request(PUBLIC_URLS[0])
    with pytest.raises(NonLoopbackURL):
        handler.http_open(req)  # guard raises before http_open reaches a socket


def test_guarded_opener_refuses_public_host_before_any_socket():
    opener = urllib.request.build_opener(LoopbackGuardedHTTPHandler, LoopbackGuardedHTTPSHandler)
    with pytest.raises(NonLoopbackURL):
        opener.open("https://storage.googleapis.com/x.png", timeout=2)


def test_guarded_opener_routes_loopback_to_the_network_layer():
    opener = urllib.request.build_opener(LoopbackGuardedHTTPHandler, LoopbackGuardedHTTPSHandler)
    # Nothing listens on port 9: the failure must be a normal OSError
    # (connection refused), proving the guard passed the loopback URL through.
    with pytest.raises(OSError):
        opener.open("http://127.0.0.1:9/dead-port", timeout=2)


def test_scenario_manifest_carries_no_absolute_urls(lab_scenarios, load_raw_scenarios):
    raw = load_raw_scenarios
    for marker in ("http://", "https://", "googleapis", "storage.googleapis"):
        assert marker not in raw, f"manifest must not embed remote targets ({marker})"
    assert len(lab_scenarios) > 0


def test_scenario_dish_and_file_fields_are_shape_valid(lab_scenarios):
    for s in lab_scenarios:
        assert s["dish_id"].startswith("dish_") and s["dish_id"][5:].isdigit()
        assert s["file"] in ("rgb.png", "depth_raw.png")
