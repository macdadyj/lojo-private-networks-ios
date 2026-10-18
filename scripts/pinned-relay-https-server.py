#!/usr/bin/env python3
"""HTTPS stand-in for the site gateway's /v1/phones route.

The certificate file is a leaf plus the site CA. The process speaks TLS and then
HTTP; it does not implement pinning. The iOS test uses PinnedRelayTransport.
"""
import http.server
import ssl
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    expect = ""

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path != "/v1/phones":
            self.respond(404, b'{"error":"not found"}')
            return
        code = (self.headers.get("X-Lojo-Network") or "").strip().lower()
        if code != self.expect:
            self.respond(401, b'{"error":"network code does not match this site"}')
            return
        self.respond(200, b'{"phones":[]}')

    def respond(self, status, body):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def log_message(self, fmt, *args):
        sys.stderr.write("%s\n" % (fmt % args))


def main():
    port = int(sys.argv[1])
    cert = sys.argv[2]
    key = sys.argv[3]
    Handler.expect = sys.argv[4].strip().lower()
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(certfile=cert, keyfile=key)
    http.server.HTTPServer.allow_reuse_address = True
    httpd = http.server.HTTPServer(("127.0.0.1", port), Handler)
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
