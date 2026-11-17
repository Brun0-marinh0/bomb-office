"""Serve a versão web do jogo sem cache (evita jogadores com versão antiga após atualizar o build).

Uso: python servidor_web.py [porta=8060] [pasta=build/web] [endereco=0.0.0.0]
"""
import functools
import http.server
import os
import sys


PROJECT_ROOT = os.path.dirname(os.path.abspath(__file__))


class NoCacheHandler(http.server.SimpleHTTPRequestHandler):
    def translate_path(self, path):
        # sons soltos (usados pelo web_audio.gd em http://) vêm direto da pasta do projeto
        clean = path.split("?", 1)[0].split("#", 1)[0]
        if clean.startswith("/assets/sounds/"):
            local = os.path.normpath(os.path.join(PROJECT_ROOT, *clean.lstrip("/").split("/")))
            if local.startswith(os.path.join(PROJECT_ROOT, "assets", "sounds")):
                return local
        return super().translate_path(path)

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
