"""Serve a versão web do jogo sem cache (evita jogadores com versão antiga após atualizar o build).

Uso: python servidor_web.py [porta=8060] [pasta=build/web] [endereco=0.0.0.0]
"""
import functools
import http.server
import sys


class NoCacheHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
        self.send_header("Expires", "0")
        super().end_headers()

    def log_message(self, fmt, *args):
        pass  # silencioso


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8060
    folder = sys.argv[2] if len(sys.argv) > 2 else "build/web"
    bind = sys.argv[3] if len(sys.argv) > 3 else "0.0.0.0"
    handler = functools.partial(NoCacheHandler, directory=folder)
    print(f"Servindo {folder} em http://{bind}:{port}/", flush=True)
    http.server.ThreadingHTTPServer((bind, port), handler).serve_forever()


if __name__ == "__main__":
    main()
