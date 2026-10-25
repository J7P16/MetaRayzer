#!/usr/bin/env python3
"""DEVELOPMENT TOOL: impersonates the iPhone companion and streams JPEG files to the Mac app.

Use it to test the Mac side (link, decode, detection, tracking, overlay) without a phone or
glasses. Frames are clearly labelled as a mock source in the Mac UI. Standard library only.

    python3 tool/send_frames.py --fps 24 path/to/frames/*.jpg
    python3 tool/send_frames.py --host 192.168.1.20 --loop hand.jpg

Implements the framing documented in WireProtocol.swift (protocol version 1).
"""
import argparse
import json
import math
import socket
import struct
import sys
import threading
import time

MSG_HELLO, MSG_FRAME, MSG_STATUS, MSG_COMMAND, MSG_MOTION, MSG_AUDIO = 1, 2, 3, 4, 5, 6


def message(msg_type: int, payload: bytes) -> bytes:
    return struct.pack(">IB", 1 + len(payload), msg_type) + payload


def json_message(msg_type: int, obj: dict) -> bytes:
    return message(msg_type, json.dumps(obj).encode())


def jpeg_size(data: bytes) -> tuple[int, int]:
    """Width/height from the first SOFn marker."""
    i = 2
    while i < len(data) - 9:
        if data[i] != 0xFF:
            i += 1
            continue
        marker = data[i + 1]
        if marker in (0xC0, 0xC1, 0xC2):
            h, w = struct.unpack(">HH", data[i + 5:i + 9])
            return w, h
        seg_len = struct.unpack(">H", data[i + 2:i + 4])[0]
        i += 2 + seg_len
    return 0, 0


def read_commands(sock: socket.socket, state: dict) -> None:
    """Prints commands from the Mac and honours start/stop."""
    buf = b""
    while True:
        try:
            chunk = sock.recv(4096)
        except OSError:
            return
        if not chunk:
            return
        buf += chunk
        while len(buf) >= 5:
            length = struct.unpack(">I", buf[:4])[0]
            if len(buf) < 4 + length:
                break
            body, buf = buf[4:4 + length], buf[4 + length:]
            if body[0] == MSG_AUDIO:
                print(f"<- audio relay: {json.loads(body[1:] or b'{}')}")
            elif body[0] == MSG_COMMAND:
                cmd = json.loads(body[1:] or b"{}").get("cmd")
                print(f"<- command from Mac: {cmd}")
                state["streaming"] = cmd == "startStream"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("images", nargs="+", help="JPEG files to send, in order")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=47800)
    ap.add_argument("--fps", type=float, default=24)
    ap.add_argument("--loop", action="store_true", help="repeat forever")
    ap.add_argument("--count", type=int, default=0, help="stop after N frames (0 = no limit)")
    ap.add_argument("--wait-for-start", action="store_true", help="only stream after the Mac sends startStream")
    ap.add_argument("--motion-yaw", type=float, default=0,
                    help="also send simulated glasses orientation, sweeping yaw by +/- this many degrees (tests head tracking)")
    args = ap.parse_args()

    frames = []
    for path in args.images:
        with open(path, "rb") as f:
            data = f.read()
        w, h = jpeg_size(data)
        frames.append((data, w, h))
        print(f"loaded {path}: {w}x{h}, {len(data)} bytes")

    sock = socket.create_connection((args.host, args.port), timeout=5)
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    sock.settimeout(None)
    print(f"connected to {args.host}:{args.port}")
    state = {"streaming": not args.wait_for_start}
    threading.Thread(target=read_commands, args=(sock, state), daemon=True).start()

    sock.sendall(json_message(MSG_HELLO, {"protocol": 1, "name": "send_frames.py (dev)"}))

    def status(stream: str) -> None:
        w, h = frames[0][1], frames[0][2]
        sock.sendall(json_message(MSG_STATUS, {
            "registration": "dev sender", "device": "none (dev sender)", "permission": "n/a",
            "stream": stream, "resolution": f"{w}x{h}", "mock": True,
        }))

    seq, sent, last_state = 0, 0, None
    interval = 1.0 / args.fps
    t_next = time.monotonic()
    try:
        while True:
            if state["streaming"] != last_state:
                last_state = state["streaming"]
                status("streaming" if last_state else "stopped")
            if not state["streaming"]:
                time.sleep(0.05)
                continue
            if args.motion_yaw:
                # Orientation about +y (right-handed, y up): turning right = negative angle.
                yaw = math.radians(args.motion_yaw) * math.sin(time.monotonic() * 0.8)
                q = (0.0, math.sin(-yaw / 2), 0.0, math.cos(-yaw / 2))
                sock.sendall(message(MSG_MOTION, struct.pack(">ffffq", *q, time.monotonic_ns())))
            data, w, h = frames[seq % len(frames)]
            header = struct.pack(">IQHH", seq & 0xFFFFFFFF, int(time.time() * 1000), w, h)
            sock.sendall(message(MSG_FRAME, header + data))
            seq += 1
            sent += 1
            if args.count and sent >= args.count:
                break
            if not args.loop and seq >= len(frames):
                break
            t_next += interval
            time.sleep(max(0.0, t_next - time.monotonic()))
    except (BrokenPipeError, ConnectionResetError):
        print("Mac closed the connection")
        return 1
    except KeyboardInterrupt:
        pass
    status("stopped")
    print(f"sent {sent} frames")
    time.sleep(0.2)
    sock.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
