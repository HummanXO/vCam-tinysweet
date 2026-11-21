#!/usr/bin/env python3
"""End-to-end synthetic 720p30 test of the OBS relay and receiver."""
import json
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import tempfile
import time

REPO = Path(__file__).resolve().parents[1]
RECEIVER = REPO / "layout/usr/libexec/vcam-obs-receiver.py"
RELAY = REPO / "scripts/obs-relay.py"


def wait_for(predicate, seconds, message):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.1)
    raise AssertionError(message)


def main():
    with tempfile.TemporaryDirectory(prefix="vcam-live-test-") as temporary:
        state = Path(temporary)
        token = secrets.token_hex(32)
        (state / "live-token.hex").write_text(token)
        (state / "relay-token.hex").write_text(token)
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        receiver = subprocess.Popen([sys.executable, str(RECEIVER), "--host", "127.0.0.1",
                                     "--port", str(port), "--state-dir", str(state)])
        relay = None
        try:
            wait_for(lambda: (state / "live-status.json").exists(), 3, "receiver did not start")
            with socket.create_connection(("127.0.0.1", port), timeout=2) as bad:
                bad.sendall(b"VCAMOBS1" + b"\0" * 32)
                assert bad.recv(4) != b"OKAY", "invalid token was accepted"
            relay = subprocess.Popen([sys.executable, str(RELAY), "--iphone", "127.0.0.1",
                                      "--port", str(port), "--token-file", str(state / "relay-token.hex"),
                                      "--test-pattern", "--software"], stdout=subprocess.DEVNULL)
            status_path = state / "live-status.json"
            def active():
                status = json.loads(status_path.read_text())
                return status if status.get("frames_received", 0) >= 30 and status.get("connected") else None
            status = wait_for(active, 10, "720p30 frames did not arrive")
            assert (status["width"], status["height"]) == (1280, 720), status
            assert status["fps"] >= 20, status
            frame = (state / "live-frame.jpg").read_bytes()
            assert frame.startswith(b"\xff\xd8") and frame.endswith(b"\xff\xd9")
            relay.terminate()
            relay.wait(timeout=3)
            relay = None
            wait_for(lambda: not json.loads(status_path.read_text())["connected"], 4,
                     "receiver did not mark disconnect")
            stopped_frame = (state / "live-frame.jpg").read_bytes()
            time.sleep(0.5)
            assert (state / "live-frame.jpg").read_bytes() == stopped_frame, "last frame changed on disconnect"
            print(f"PASS: authenticated 1280x720 stream, {status['fps']} FPS, disconnect keeps last frame")
        finally:
            if relay and relay.poll() is None:
                relay.terminate()
                relay.wait(timeout=3)
            receiver.terminate()
            receiver.wait(timeout=3)


if __name__ == "__main__":
    main()
