#!/usr/bin/env python3
"""Fetch one immutable public synthetic test input; never accept runtime URLs/keys."""
import hashlib
from pathlib import Path
import sys
import urllib.error
import urllib.request

REVISION = "9a60e783ec1ceaff6116b0462a2863f07f602a55"
URL = f"https://raw.githubusercontent.com/liguobao/ds-harness-remote/{REVISION}/fixtures/crypto/v1/noise-ik.json"
BLOB = "52e83a5de8444dbd13115ccd3d8131950907e302"
SIZE = 2960


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, new_url):
        raise ValueError("Fixture redirects are not permitted.")


def verify(data: bytes) -> None:
    digest = hashlib.sha1(b"blob " + str(len(data)).encode("ascii") + b"\0" + data).hexdigest()
    if len(data) != SIZE or digest != BLOB:
        raise ValueError("Pinned synthetic fixture provenance did not match.")


def main() -> int:
    if len(sys.argv) != 2:
        print("Expected one disposable output path.", file=sys.stderr)
        return 2
    destination = Path(sys.argv[1])
    try:
        request = urllib.request.Request(URL, headers={"User-Agent": "quenderin-remote-crypto-host-fixture"})
        # One request, 20 seconds, at most 4097 bytes; no credentials or retries.
        opener = urllib.request.build_opener(NoRedirect)
        with opener.open(request, timeout=20) as response:
            if response.url != URL or response.status != 200:
                raise ValueError("Unexpected fixture response.")
            data = response.read(4097)
        verify(data)
        # Never replace an existing file or leave a partial/unchecked fixture.
        with destination.open("xb") as output:
            output.write(data)
    except (OSError, ValueError, urllib.error.URLError):
        print("Pinned synthetic fixture fetch/verification failed.", file=sys.stderr)
        return 1
    print("Verified immutable DSH synthetic fixture (2960 bytes).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
