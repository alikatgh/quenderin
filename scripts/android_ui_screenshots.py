#!/usr/bin/env python3
"""Bounded synthetic Android screenshots in job logs; never a general file exporter.

Export on the ephemeral hosted emulator, then decode one downloaded job's text log:
  python3 -B scripts/android_ui_screenshots.py export --serial emulator-5554
  python3 -B scripts/android_ui_screenshots.py decode --input job.log --output review
No credentials, app databases, external storage or arbitrary paths are read.
"""
import argparse
import base64
import binascii
import hashlib
import os
from pathlib import Path
import re
import select
import struct
import subprocess
import sys
import time
import zlib


NAMES = (
    "01-welcome-light.png", "02-setup-light.png", "03-chat-light.png",
    "04-report-light.png", "05-chat-dark-keyboard.png", "06-setup-large-text.png",
    "07-settings-short-window.png", "08-failure.png",
)
MAX_IMAGE = 1024 * 1024
MAX_TOTAL = 8 * MAX_IMAGE
MAX_LOG = 64 * 1024 * 1024
PREFIX = "QUENDERIN_UI_PNG_V1_"
BEGIN = re.compile(r"BEGIN name=([a-z0-9-]+\.png) bytes=([0-9]{1,7}) sha256=([0-9a-f]{64})$")
DATA = re.compile(r"DATA name=([a-z0-9-]+\.png) index=([0-9]{1,4}) data=([A-Za-z0-9+/=]{1,4096})$")
END = re.compile(r"END name=([a-z0-9-]+\.png) chunks=([0-9]{1,4})$")


def validate_png(data):
    if not 57 <= len(data) <= MAX_IMAGE or data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("Invalid or oversized PNG")
    offset, width, height, saw_data, saw_end = 8, None, None, False, False
    while offset < len(data):
        if offset + 12 > len(data):
            raise ValueError("Truncated PNG chunk")
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        kind = data[offset + 4:offset + 8]
        if offset + 12 + length > len(data):
            raise ValueError("PNG chunk exceeds file")
        payload = data[offset + 8:offset + 8 + length]
        crc = struct.unpack(">I", data[offset + 8 + length:offset + 12 + length])[0]
        if zlib.crc32(kind + payload) & 0xffffffff != crc:
            raise ValueError("PNG chunk checksum mismatch")
        if offset == 8:
            if kind != b"IHDR" or length != 13:
                raise ValueError("PNG must begin with IHDR")
            width, height = struct.unpack(">II", payload[:8])
            if not (1 <= width <= 4096 and 1 <= height <= 4096 and width * height <= 8_000_000):
                raise ValueError("PNG dimensions exceed review bounds")
        elif kind == b"IHDR":
            raise ValueError("Duplicate PNG header")
        if kind == b"IDAT":
            saw_data = True
        if kind == b"IEND":
            if length or offset + 12 != len(data):
                raise ValueError("Invalid PNG end or trailing bytes")
            saw_end = True
        offset += 12 + length
    if not saw_data or not saw_end:
        raise ValueError("Incomplete PNG")
    return width, height


def emit(images, output):
    if len(images) > len(NAMES) or sum(len(data) for data in images.values()) > MAX_TOTAL:
        raise ValueError("Screenshot batch exceeds bounds")
    for name, data in images.items():
        if name not in NAMES:
            raise ValueError("Screenshot filename is not allowlisted")
        validate_png(data)
    for name, data in images.items():
        output.write(f"{PREFIX}BEGIN name={name} bytes={len(data)} sha256={hashlib.sha256(data).hexdigest()}\n")
        encoded = base64.b64encode(data).decode("ascii")
        chunks = [encoded[i:i + 4096] for i in range(0, len(encoded), 4096)]
        for index, chunk in enumerate(chunks):
            output.write(f"{PREFIX}DATA name={name} index={index} data={chunk}\n")
        output.write(f"{PREFIX}END name={name} chunks={len(chunks)}\n")


def decode(lines):
    images, pending, total_log = {}, None, 0
    for line in lines:
        total_log += len(line.encode("utf-8"))
        if total_log > MAX_LOG or len(line) > 65536:
            raise ValueError("Job log exceeds decoding bounds")
        marker = line.find(PREFIX)
        if marker < 0:
            continue
        record = line[marker + len(PREFIX):].rstrip("\r\n")
        match = BEGIN.fullmatch(record)
        if match:
            name, size, digest = match.groups()
            if name not in NAMES or name in images or pending is not None or not 57 <= int(size) <= MAX_IMAGE:
                raise ValueError("Invalid or duplicate screenshot begin")
            pending = {"name": name, "size": int(size), "digest": digest, "chunks": 0, "bytes": bytearray()}
            continue
        match = DATA.fullmatch(record)
        if match:
            name, index, payload = match.groups()
            if pending is None or name != pending["name"] or int(index) != pending["chunks"]:
                raise ValueError("Screenshot chunk is out of sequence")
            try:
                data = base64.b64decode(payload, validate=True)
            except binascii.Error as error:
                raise ValueError("Invalid screenshot base64") from error
            pending["bytes"].extend(data)
            pending["chunks"] += 1
            if len(pending["bytes"]) > pending["size"]:
                raise ValueError("Screenshot exceeds declared size")
            continue
        match = END.fullmatch(record)
        if match:
            name, chunks = match.groups()
            if pending is None or name != pending["name"] or int(chunks) != pending["chunks"]:
                raise ValueError("Invalid screenshot end")
            data = bytes(pending["bytes"])
            if len(data) != pending["size"] or hashlib.sha256(data).hexdigest() != pending["digest"]:
                raise ValueError("Screenshot size or digest mismatch")
            validate_png(data)
            images[name] = data
            pending = None
            if sum(len(value) for value in images.values()) > MAX_TOTAL:
                raise ValueError("Screenshot batch exceeds total limit")
            continue
        raise ValueError("Unrecognized screenshot marker")
    if pending is not None:
        raise ValueError("Truncated screenshot export")
    return images


def read_adb_png(serial, name):
    # Fixed package and cache directory; never accept a caller-supplied remote path.
    process = subprocess.Popen(
        ["adb", "-s", serial, "exec-out", "run-as", "ai.quenderin.app", "cat", f"cache/ui-journeys/{name}"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    )
    deadline, data = time.monotonic() + 10, bytearray()
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ValueError("Screenshot read timed out")
            readable, _, _ = select.select([process.stdout], [], [], remaining)
            if not readable:
                raise ValueError("Screenshot read timed out")
            chunk = os.read(process.stdout.fileno(), min(65536, MAX_IMAGE + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
            if len(data) > MAX_IMAGE:
                raise ValueError("Screenshot exceeds per-image limit")
        status = process.wait(timeout=2)
        if status != 0:
            return None  # A failure before that state may legitimately leave no screenshot.
        validate_png(data)
        return bytes(data)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=2)
        process.stdout.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    export = sub.add_parser("export")
    export.add_argument("--serial", required=True, choices=["emulator-5554"])
    restore = sub.add_parser("decode")
    restore.add_argument("--input", type=Path, required=True)
    restore.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "export":
        images = {}
        for name in NAMES:
            data = read_adb_png(args.serial, name)
            if data is not None:
                images[name] = data
        emit(images, sys.stdout)
        print(f"UI_SCREENSHOT_COUNT {len(images)} (synthetic fixtures; visual inspection still required)")
    else:
        if args.input.stat().st_size > MAX_LOG:
            raise ValueError("Job log exceeds decoding bounds")
        with args.input.open(encoding="utf-8", errors="strict") as source:
            images = decode(source)
        if not images:
            raise ValueError("No screenshot records found")
        if args.output.is_symlink():
            raise ValueError("Output directory must not be a symlink")
        args.output.mkdir(parents=True, exist_ok=True)
        if any((args.output / name).exists() or (args.output / name).is_symlink() for name in images):
            raise ValueError("Refusing to overwrite an existing review file")
        for name, data in images.items():
            with (args.output / name).open("xb") as destination:
                destination.write(data)
            width, height = validate_png(data)
            print(f"{name}: {len(data)} bytes, {width}x{height}, sha256={hashlib.sha256(data).hexdigest()}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error))
