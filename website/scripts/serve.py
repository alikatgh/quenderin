#!/usr/bin/env python3
"""Static server for the marketing site that works inside restricted sandboxes.

Built to catch: the preview sandbox blocks `os.getcwd()`, so
`python3 -m http.server --directory website` crashes at argparse time. This
serves the site by passing an ABSOLUTE `directory` to the handler, never
calling getcwd. Run from anywhere:  python3 website/scripts/serve.py [port]

Does NOT catch: anything about the rendered page — it's just a file server.
"""
import functools
import http.server
import os
import socketserver
import sys

# website/ is the parent of this scripts/ dir — resolved absolutely, no getcwd.
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8099

Handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=ROOT)
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", PORT), Handler) as httpd:
    print(f"serving {ROOT} at http://127.0.0.1:{PORT}")
    httpd.serve_forever()
