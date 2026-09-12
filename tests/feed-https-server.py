#!/usr/bin/env python3
"""feed-https-server.py — serve a feed tree over HTTPS with PRODUCTION cache headers.

Why this exists
---------------
The publish contract has two halves that only a live HTTPS fetch can prove:

  * the fetch-back assertion (scripts/feed-verify.sh) must run against a URL
    served over TLS, not a local file, so the bytes it hashes are the bytes a
    router would get;
  * the index must be served `no-cache`/`no-store` and the packages `immutable`.
    A cached index is the one lethal failure mode in the memo — it either hides
    an upgrade or lists a package that was removed. `feed-verify.sh --headers
    require` fails a publish whose index is cacheable.

This is the deploy/caddy-feed.Caddyfile.example header rules, without Caddy, so
the gate can be rehearsed on any host (CI, a laptop) before the real site exists
on the VPS. It is a TEST harness: it serves one directory, on loopback, with a
locally generated CA. Do not use it as the production server.

Usage
-----
    tests/feed-https-server.py --root DIR [--port 8443] [--certdir DIR]
                               [--bind 127.0.0.1]

On start it creates (once) a local CA plus a server certificate for
`localhost` / 127.0.0.1 inside --certdir, prints the URL and the CA path, then
serves until SIGINT/SIGTERM. Pass the printed CA to curl/feed-verify.sh:

    scripts/feed-publish.sh ... --base-url https://localhost:8443 \\
        --ca-cert <certdir>/ca.pem
    scripts/feed-verify.sh ... --base-url https://localhost:8443 \\
        --ca-cert <certdir>/ca.pem --headers require

Every request is logged to stderr as
`GET <path> -> <status> cache-control=<value>` so the header rules are visible
in the captured output instead of being asserted about.
"""

import argparse
import http.server
import os
import socket
import ssl
import subprocess
import sys

# Mutable paths: the index (and its signature/sidecar files). Never cached.
INDEX_NAMES = {
    "packages.adb",
    "packages.adb.sig",
    "packages.adb.asc",
    "Packages",
    "Packages.gz",
    "Packages.sig",
    "Packages.manifest",
    "index.json",
    "sha256sums",
}
# Immutable paths: versioned packages and public keys.
IMMUTABLE_SUFFIXES = (".apk", ".ipk")
KEY_SUFFIXES = (".pem", ".pub")

NO_CACHE = "no-cache, no-store, must-revalidate"
IMMUTABLE = "public, max-age=31536000, immutable"


def cache_control_for(path: str) -> str:
    """Return the Cache-Control value a production feed host must send."""
    name = os.path.basename(path)
    if name in INDEX_NAMES:
        return NO_CACHE
    if name.endswith(IMMUTABLE_SUFFIXES):
        return IMMUTABLE
    # keys/ hold the public trust anchors; their name must never change material
    parts = path.strip("/").split("/")
    if "keys" in parts and name.endswith(KEY_SUFFIXES):
        return IMMUTABLE
    return NO_CACHE


class Handler(http.server.SimpleHTTPRequestHandler):
    server_version = "tollgate-feed-rehearsal/1.0"

    def __init__(self, *args, directory=None, **kwargs):
        super().__init__(*args, directory=directory, **kwargs)

    def _send_headers(self, code, path, extra=None):
        self.send_response(code)
        self.send_header("Cache-Control", cache_control_for(path))
        if cache_control_for(path) == NO_CACHE:
            self.send_header("Pragma", "no-cache")
        self.send_header("Server", self.server_version)
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()

    def send_head(self):
        path = self.translate_path(self.path)
        # No directory listings: an index directory listing invites hand-downloads
        # that skip the trust chain (same rail as the Caddy example).
        if os.path.isdir(path):
            self._send_headers(404, self.path)
            self.wfile.write(b"directory listings are disabled\n")
            return None
        return super().send_head()

    def end_headers(self):
        # SimpleHTTPRequestHandler sends its own headers first; override after.
        if not self._headers_buffer_has_cache():
            self.send_header("Cache-Control", cache_control_for(self.path))
        super().end_headers()

    def _headers_buffer_has_cache(self):
        buf = getattr(self, "_headers_buffer", None) or []
        return any(b"Cache-Control" in h for h in buf)

    def log_message(self, format, *args):  # noqa: A002 — base class signature
        # One line per request, including the cache policy actually sent.
        status = args[1] if len(args) > 1 else "-"
        sys.stderr.write(
            "GET %s -> %s cache-control=%s\n"
            % (self.path, status, cache_control_for(self.path))
        )
        sys.stderr.flush()

    def log_error(self, format, *args):  # noqa: A002 — base class signature
        sys.stderr.write("ERROR %s\n" % (format % args))
        sys.stderr.flush()


def run(cmd):
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def ensure_certs(certdir: str) -> str:
    """Create a CA + localhost server cert if absent. Returns the CA path."""
    os.makedirs(certdir, exist_ok=True)
    ca = os.path.join(certdir, "ca.pem")
    ca_key = os.path.join(certdir, "ca.key")
    cert = os.path.join(certdir, "server.pem")
    key = os.path.join(certdir, "server.key")
    if not os.path.exists(ca):
        run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
             "-keyout", ca_key, "-out", ca, "-days", "3650",
             "-subj", "/CN=tollgate-feed-rehearsal-CA"])
    if not os.path.exists(cert):
        csr = os.path.join(certdir, "server.csr")
        ext = os.path.join(certdir, "server.ext")
        with open(ext, "w") as fh:
            fh.write("subjectAltName=DNS:localhost,IP:127.0.0.1\n")
        run(["openssl", "req", "-newkey", "rsa:2048", "-nodes", "-keyout", key,
             "-out", csr, "-subj", "/CN=localhost"])
        run(["openssl", "x509", "-req", "-in", csr, "-CA", ca, "-CAkey", ca_key,
             "-CAcreateserial", "-out", cert, "-days", "3650", "-extfile", ext])
        os.unlink(csr)
        os.unlink(ext)
    return ca


def main() -> int:
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--root", required=True, help="feed tree root to serve")
    ap.add_argument("--port", type=int, default=8443)
    ap.add_argument("--bind", default="127.0.0.1")
    ap.add_argument("--certdir", default="")
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    if not os.path.isdir(root):
        sys.stderr.write("FAIL: --root is not a directory: %s\n" % root)
        return 1
    certdir = args.certdir or os.path.join(root, ".tls")
    ca = ensure_certs(certdir)

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(os.path.join(certdir, "server.pem"),
                        os.path.join(certdir, "server.key"))

    handler = lambda *a, **kw: Handler(*a, directory=root, **kw)  # noqa: E731
    httpd = http.server.ThreadingHTTPServer((args.bind, args.port), handler)
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)

    sys.stderr.write("serving %s at https://%s:%d\n" % (root, args.bind, args.port))
    sys.stderr.write("CA certificate: %s\n" % ca)
    sys.stderr.flush()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
