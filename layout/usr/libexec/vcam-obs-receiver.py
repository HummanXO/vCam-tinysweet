#!/var/jb/usr/bin/python3
"""Authenticated, bounded LIVE OBS frame receiver for VCam.

The Mac relay decodes OBS's H.264/MPEG-TS stream with FFmpeg and sends the
newest JPEG frames over a LAN TCP connection. This process never runs inside
the camera service. Only a complete, validated frame replaces live-frame.jpg.
"""
import argparse
from collections import deque
import hmac
import json
import os
import secrets
import socket
import struct
import tempfile
import time

MAGIC = b"VCAMOBS1"
FRAME = struct.Struct("!4sIQQHHI")  # tag, bytes, sequence, send time us, width, height, sender drops
MAX_FRAME = 1_000_000
DEFAULT_DIR = "/var/jb/var/mobile/VCam/Media"
DEFAULT_PORT = 47110


def atomic_write(path, payload, mode=0o644):
    directory = os.path.dirname(path)
    fd, temporary = tempfile.mkstemp(prefix=".vcam-", dir=directory)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(payload)
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def recv_exact(conn, count):
    result = bytearray()
    while len(result) < count:
        chunk = conn.recv(count - len(result))
        if not chunk:
            raise ConnectionError("sender disconnected")
        result.extend(chunk)
    return bytes(result)


class Receiver:
    def __init__(self, state_dir, port, host="0.0.0.0"):
        self.state_dir = state_dir
        self.port = port
        self.host = host
        os.makedirs(state_dir, mode=0o755, exist_ok=True)
        os.chmod(state_dir, 0o755)
        self.frame_path = os.path.join(state_dir, "live-frame.jpg")
        self.status_path = os.path.join(state_dir, "live-status.json")
        token_path = os.path.join(state_dir, "live-token.hex")
        if not os.path.exists(token_path):
            atomic_write(token_path, secrets.token_hex(32).encode("ascii"), 0o600)
        with open(token_path, "rb") as stream:
            self.token = bytes.fromhex(stream.read().decode("ascii").strip())
        if len(self.token) != 32:
            raise ValueError("invalid receiver token")
        self.connected = False
        self.last_error = "Waiting for OBS"
        self.last_frame_wall_us = 0
        self.last_seq = None
        self.width = 0
        self.height = 0
        self.fps_times = deque()
        self.sender_drops = 0
        self.network_drops = 0
        self.latency_ms = None
        self.frames_received = 0
        self.last_status_emit = 0.0
        self.publish_status()

    def publish_status(self):
        now = time.time()
        while self.fps_times and now - self.fps_times[0] > 2:
            self.fps_times.popleft()
        fps = 0.0
        if len(self.fps_times) > 1:
            span = self.fps_times[-1] - self.fps_times[0]
            if span > 0:
                fps = (len(self.fps_times) - 1) / span
        age_ms = (int(now * 1000) - self.last_frame_wall_us // 1000) if self.last_frame_wall_us else None
        status = {
            "connected": self.connected and age_ms is not None and age_ms < 2000,
            "fps": round(fps, 1),
            "width": self.width,
            "height": self.height,
            "frame_age_ms": age_ms,
            "latency_est_ms": self.latency_ms,
            # Sequence gaps include the sender's one-slot queue drops.
            "dropped_frames": max(self.sender_drops, self.network_drops),
            "sender_drops": self.sender_drops,
            "frames_received": self.frames_received,
            "last_error": self.last_error,
            "updated_at": now,
            "port": self.port,
        }
        atomic_write(self.status_path, json.dumps(status, separators=(",", ":")).encode("utf-8"))
        self.last_status_emit = time.monotonic()

    def handle(self, conn):
        conn.settimeout(2.0)
        conn.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 262144)
        hello = recv_exact(conn, len(MAGIC) + 32)
        if hello[:len(MAGIC)] != MAGIC or not hmac.compare_digest(hello[len(MAGIC):], self.token):
            self.last_error = "Sender authentication failed"
            self.publish_status()
            return
        conn.sendall(b"OKAY")
        self.connected = True
        self.last_error = ""
        self.last_seq = None
        self.fps_times.clear()
        self.publish_status()
        while True:
            tag, length, seq, sent_us, width, height, sender_drops = FRAME.unpack(recv_exact(conn, FRAME.size))
            if tag != b"FRAM" or not 4 <= length <= MAX_FRAME or not 1 <= width <= 1920 or not 1 <= height <= 1080:
                raise ValueError("invalid frame header")
            jpeg = recv_exact(conn, length)
            if not (jpeg.startswith(b"\xff\xd8") and jpeg.endswith(b"\xff\xd9")):
                raise ValueError("invalid JPEG frame")
            if self.last_seq is not None and seq > self.last_seq + 1:
                self.network_drops += seq - self.last_seq - 1
            self.last_seq = seq
            self.sender_drops = sender_drops
            self.width, self.height = width, height
            self.last_frame_wall_us = int(time.time() * 1_000_000)
            measured_ms = (self.last_frame_wall_us - sent_us) // 1000
            self.latency_ms = measured_ms if 0 <= measured_ms <= 5000 else None
            atomic_write(self.frame_path, jpeg)
            self.frames_received += 1
            self.fps_times.append(time.time())
            if time.monotonic() - self.last_status_emit >= 0.25:
                self.publish_status()

    def serve(self):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            listener.bind((self.host, self.port))
            listener.listen(2)
            listener.settimeout(0.5)
            while True:
                try:
                    conn, _ = listener.accept()
                except socket.timeout:
                    if self.connected and time.time() * 1_000_000 - self.last_frame_wall_us > 2_000_000:
                        self.connected = False
                        self.last_error = "OBS stream timed out"
                        self.publish_status()
                    continue
                try:
                    with conn:
                        self.handle(conn)
                except (ConnectionError, OSError, ValueError) as exc:
                    self.last_error = str(exc)[:160]
                finally:
                    self.connected = False
                    self.publish_status()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state-dir", default=DEFAULT_DIR)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    options = parser.parse_args()
    Receiver(options.state_dir, options.port, options.host).serve()


if __name__ == "__main__":
    main()
