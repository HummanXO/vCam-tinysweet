#!/usr/bin/env python3
"""Relay OBS H.264/MPEG-TS to the authenticated VCam receiver on iPhone.

FFmpeg decodes outside iOS camera processes. A single-slot queue discards old
frames whenever encoding or the LAN falls behind, so latency cannot build up.
"""
import argparse
import os
from pathlib import Path
import queue
import shutil
import socket
import struct
import subprocess
import threading
import time

MAGIC = b"VCAMOBS1"
FRAME = struct.Struct("!4sIQQHHI")
REPO = Path(__file__).resolve().parents[1]
PROJECT = next((directory for directory in (REPO.parent, REPO.parent.parent)
                if (directory / "scripts" / "dssh.sh").exists()), REPO)
TOKEN_FILE = PROJECT / "data" / "vcam-obs-token.hex"


def read_token(path):
    if not path.exists():
        remote = subprocess.run(
            [str(PROJECT / "scripts" / "dssh.sh"), "cat /var/jb/var/mobile/VCam/Media/live-token.hex"],
            capture_output=True, check=True,
        )
        path.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(remote.stdout.strip())
    token = bytes.fromhex(path.read_text().strip())
    if len(token) != 32:
        raise ValueError("receiver token must be 32 bytes")
    return token


def jpeg_dimensions(jpeg):
    if not jpeg.startswith(b"\xff\xd8"):
        return None
    index = 2
    while index + 9 < len(jpeg):
        if jpeg[index] != 0xff:
            index += 1
            continue
        marker = jpeg[index + 1]
        index += 2
        if marker in (0xd8, 0xd9) or 0xd0 <= marker <= 0xd7:
            continue
        if index + 2 > len(jpeg):
            return None
        length = int.from_bytes(jpeg[index:index + 2], "big")
        if length < 2 or index + length > len(jpeg):
            return None
        if marker in (0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf):
            height = int.from_bytes(jpeg[index + 3:index + 5], "big")
            width = int.from_bytes(jpeg[index + 5:index + 7], "big")
            return width, height
        index += length
    return None


def ffmpeg_command(options, hardware):
    cmd = [options.ffmpeg, "-hide_banner", "-loglevel", "error"]
    if hardware:
        cmd += ["-hwaccel", "videotoolbox"]
    if options.test_pattern:
        cmd += ["-re", "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30"]
    else:
        url = f"udp://127.0.0.1:{options.obs_port}?fifo_size=1000000&overrun_nonfatal=1"
        cmd += ["-fflags", "nobuffer", "-flags", "low_delay", "-probesize", "32768",
                "-analyzeduration", "0", "-i", url]
    cmd += ["-an", "-vf", "fps=30", "-c:v", "mjpeg", "-q:v", "4", "-f", "image2pipe", "-flush_packets", "1", "pipe:1"]
    return cmd


def hardware_available(ffmpeg):
    result = subprocess.run([ffmpeg, "-hide_banner", "-hwaccels"], capture_output=True, text=True)
    return result.returncode == 0 and "videotoolbox" in result.stdout.split()


class LatestFrames:
    def __init__(self):
        self.queue = queue.Queue(maxsize=1)
        self.next_sequence = 0
        self.dropped = 0

    def offer(self, jpeg):
        dimensions = jpeg_dimensions(jpeg)
        if not dimensions:
            return
        self.next_sequence += 1
        frame = (self.next_sequence, int(time.time() * 1_000_000), dimensions, jpeg)
        if self.queue.full():
            try:
                self.queue.get_nowait()
                self.dropped += 1
            except queue.Empty:
                pass
        self.queue.put_nowait(frame)


def read_jpegs(pipe, latest):
    buffer = bytearray()
    while True:
        # BufferedReader.read(n) waits for n bytes and can batch two 50 KB
        # JPEGs, making the one-slot queue discard a frame unnecessarily.
        chunk = os.read(pipe.fileno(), 65536)
        if not chunk:
            return
        buffer.extend(chunk)
        while True:
            start = buffer.find(b"\xff\xd8")
            if start < 0:
                buffer.clear()
                break
            if start:
                del buffer[:start]
            end = buffer.find(b"\xff\xd9", 2)
            if end < 0:
                if len(buffer) > 1_000_000:
                    buffer.clear()
                break
            jpeg = bytes(buffer[:end + 2])
            del buffer[:end + 2]
            if len(jpeg) <= 1_000_000:
                latest.offer(jpeg)


def connect(iphone, port, token):
    conn = socket.create_connection((iphone, port), timeout=2.0)
    conn.settimeout(2.0)
    conn.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 262144)
    conn.sendall(MAGIC + token)
    if conn.recv(4) != b"OKAY":
        conn.close()
        raise ConnectionError("receiver rejected authentication")
    return conn


def relay(options):
    if not shutil.which(options.ffmpeg):
        raise SystemExit("FFmpeg is required on the Mac")
    token = read_token(Path(options.token_file))
    latest = LatestFrames()
    hardware = hardware_available(options.ffmpeg) and not options.software
    decoder = subprocess.Popen(ffmpeg_command(options, hardware), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    threading.Thread(target=read_jpegs, args=(decoder.stdout, latest), daemon=True).start()
    print(f"OBS UDP {options.obs_port} -> iPhone {options.iphone}:{options.port}; VideoToolbox: {'yes' if hardware else 'no'}", flush=True)
    conn = None
    sent = 0
    last_report = time.monotonic()
    try:
        while True:
            try:
                seq, sent_us, (width, height), jpeg = latest.queue.get(timeout=1)
            except queue.Empty:
                if decoder.poll() is not None:
                    raise RuntimeError("FFmpeg stopped; check OBS output settings")
                continue
            if conn is None:
                try:
                    conn = connect(options.iphone, options.port, token)
                except OSError as exc:
                    if time.monotonic() - last_report > 3:
                        print(f"Waiting for iPhone receiver: {exc}", flush=True)
                        last_report = time.monotonic()
                    continue
            try:
                conn.sendall(FRAME.pack(b"FRAM", len(jpeg), seq, sent_us, width, height, latest.dropped) + jpeg)
                sent += 1
            except OSError:
                conn.close()
                conn = None
            if time.monotonic() - last_report > 5:
                print(f"sent={sent} dropped_before_send={latest.dropped} latest={width}x{height}", flush=True)
                last_report = time.monotonic()
    finally:
        if conn:
            conn.close()
        decoder.terminate()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--iphone", required=True, help="iPhone Wi-Fi IPv4 address")
    parser.add_argument("--port", type=int, default=47110, help="iPhone receiver port")
    parser.add_argument("--obs-port", type=int, default=47111, help="local OBS UDP output port")
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--token-file", default=str(TOKEN_FILE))
    parser.add_argument("--software", action="store_true", help="disable VideoToolbox decoding on Mac")
    parser.add_argument("--test-pattern", action="store_true", help="send a synthetic 720p30 image without OBS")
    try:
        relay(parser.parse_args())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
