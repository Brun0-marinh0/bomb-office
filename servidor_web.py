"""Serve a versão web do jogo com cache revalidado (o navegador confere a cada visita se o
arquivo mudou: não baixa tudo de novo, e ninguém fica com versão antiga após atualizar o build).

Uso: python servidor_web.py [porta=8060] [pasta=build/web] [endereco=0.0.0.0]
"""
import functools
import http.server
import json
import os
import sys


PROJECT_ROOT = os.path.dirname(os.path.abspath(__file__))


class NoCacheHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        # lista das músicas de entrada (no Docker o build gera esse arquivo)
        if self.path.split("?", 1)[0] == "/assets/sounds/intro/index.json":
            folder = os.path.join(PROJECT_ROOT, "assets", "sounds", "intro")
            names = sorted(f for f in os.listdir(folder) if f.lower().endswith((".ogg", ".mp3")))
            body = json.dumps(names).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        super().do_GET()

    def translate_path(self, path):
        # sons soltos (usados pelo web_audio.gd em http://) vêm direto da pasta do projeto
        clean = path.split("?", 1)[0].split("#", 1)[0]
        if clean.startswith("/assets/sounds/"):
            local = os.path.normpath(os.path.join(PROJECT_ROOT, *clean.lstrip("/").split("/")))
            if local.startswith(os.path.join(PROJECT_ROOT, "assets", "sounds")):
                return local
        return super().translate_path(path)

    def end_headers(self):
        # guarda, mas confere a cada visita (If-Modified-Since -> 304): não baixa tudo de novo
        self.send_header("Cache-Control", "no-cache")
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
