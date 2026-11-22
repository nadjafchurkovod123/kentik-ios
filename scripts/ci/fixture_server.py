#!/usr/bin/env python3
"""Сервер фикстур для UI-тестов: как `python3 -m http.server`, но с запросами Range.

WebKit на iOS (AVFoundation) не играет MP4 с сервера без Range («206 Partial Content»), а
стандартный http.server их не умеет. Слушает IPv4 и IPv6 (localhost и 127.0.0.1 — разные
сайты для проверок со сторонним iframe).

Использование: fixture_server.py <порт> <папка>
"""
import http.server
import os
import re
import socket
import sys

RANGE = re.compile(r"bytes=(\d*)-(\d*)$")


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".m3u8": "application/vnd.apple.mpegurl",
        ".ts": "video/mp2t",
        ".mp4": "video/mp4",
        ".js": "text/javascript",
        ".json": "application/json",
    }

    def end_headers(self):
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Cache-Control", "no-store")
        # Плееры во фреймах ходят за VAST на «чужие» имена (в CI их указывает /etc/hosts сюда):
        # без CORS XHR падал бы и без блокировщика — не отличить блокировку от ошибки.
        self.send_header("Access-Control-Allow-Origin", "*")
        super().end_headers()

    def send_head(self):
        header = self.headers.get("Range")
        path = self.translate_path(self.path)
        if not header or os.path.isdir(path) or not os.path.isfile(path):
            return super().send_head()
        match = RANGE.match(header.strip())
        if not match:
            return super().send_head()
        size = os.path.getsize(path)
        first, last = match.group(1), match.group(2)
        if first == "":
            start, end = max(0, size - int(last or 0)), size - 1
        else:
            start = int(first)
            end = min(int(last), size - 1) if last else size - 1
        if start >= size or start > end:
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{size}")
            self.end_headers()
            return None
        f = open(path, "rb")
        f.seek(start)
        self.send_response(206)
        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Content-Length", str(end - start + 1))
        self.end_headers()
        self._remaining = end - start + 1
        return f

    def copyfile(self, source, outputfile):
        remaining = getattr(self, "_remaining", None)
        if remaining is None:
            return super().copyfile(source, outputfile)
        try:
            while remaining > 0:
                chunk = source.read(min(64 * 1024, remaining))
                if not chunk:
                    break
                outputfile.write(chunk)
                remaining -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            self._remaining = None

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))


class DualStack(http.server.ThreadingHTTPServer):
    address_family = socket.AF_INET6
    daemon_threads = True

    def server_bind(self):
        try:
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        except OSError:
            pass
        super().server_bind()


def main() -> int:
    port, root = int(sys.argv[1]), sys.argv[2]
    os.chdir(root)
    with DualStack(("::", port), Handler) as server:
        print(f"фикстуры: http://127.0.0.1:{port}/ и http://localhost:{port}/ из {root}", flush=True)
        server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
