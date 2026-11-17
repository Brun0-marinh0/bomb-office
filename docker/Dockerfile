# syntax=docker/dockerfile:1
# Imagens do BombOffice:
#   server -> servidor autoritativo do jogo (Godot headless, WebSocket na porta 9080)
#   web    -> nginx servindo a versão web exportada
ARG GODOT_VERSION=4.3

# ------------------------------------------------------------------ Godot (Linux, headless)
FROM debian:bookworm-slim AS godot
ARG GODOT_VERSION
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates wget unzip libfontconfig1 \
 && rm -rf /var/lib/apt/lists/*
RUN wget -q "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip" -O /tmp/godot.zip \
 && unzip -q /tmp/godot.zip -d /tmp \
 && mv "/tmp/Godot_v${GODOT_VERSION}-stable_linux.x86_64" /usr/local/bin/godot \
 && chmod +x /usr/local/bin/godot \
 && rm /tmp/godot.zip
WORKDIR /app

# ------------------------------------------------------------------ exportação web
FROM godot AS export
ARG GODOT_VERSION
# o pacote de templates tem ~1 GB; extrai só o necessário para a web e apaga no mesmo passo
RUN TPL="/root/.local/share/godot/export_templates/${GODOT_VERSION}.stable" \
 && mkdir -p "$TPL" \
 && wget -q "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_export_templates.tpz" -O /tmp/templates.tpz \
 && unzip -q -j /tmp/templates.tpz templates/web_nothreads_release.zip templates/web_nothreads_debug.zip templates/version.txt -d "$TPL" \
 && rm /tmp/templates.tpz
COPY . /app
RUN godot --headless --path /app --editor --quit \
 && mkdir -p /out \
 && godot --headless --path /app --export-release "Web" /out/index.html \
 && test -f /out/index.wasm \
 && gzip -k -9 /out/index.wasm /out/index.pck /out/index.js \
 && mkdir -p /out/assets \
 && cp -r /app/assets/sounds /out/assets/sounds \
 && find /out/assets/sounds -type f ! -name '*.ogg' ! -name '*.mp3' -delete \
 && (cd /out/assets/sounds/intro && ls -1 | grep -Ei '\.(ogg|mp3)$' | sed 's/.*/"&"/' | paste -sd, - \
     | sed 's/^/[/; s/$/]/' > index.json) \
 && cat /out/assets/sounds/intro/index.json
# ^ sons soltos no site, usados pelo scripts/web_audio.gd: as músicas de entrada
#   (que ficam fora do index.pck, para o jogo abrir mais rápido) tocam em streaming
#   a partir da lista index.json; os efeitos, quando o navegador não tem AudioWorklet
#   (jogo aberto por http://IP-DA-REDE)

# ------------------------------------------------------------------ servidor do jogo
FROM godot AS server
ENV BOMB_IN_DOCKER=1
COPY . /app
RUN godot --headless --path /app --editor --quit
EXPOSE 9080
ENTRYPOINT ["godot", "--headless", "--path", "/app", "--", "--server"]
CMD ["--port=9080"]

# ------------------------------------------------------------------ site (versão web)
FROM nginx:1.27-alpine AS web
COPY docker/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=export /out /usr/share/nginx/html
EXPOSE 80
