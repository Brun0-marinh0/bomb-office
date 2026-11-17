# BombOffice

Batalha de bombas PvP online para 2 a 8 jogadores, feita em Godot 4.3+, jogável no navegador por um link.
Projeto sem fins comerciais, para apresentação.

## Como funciona

- **Servidor autoritativo** (Godot rodando sem janela): calcula toda a partida e envia o estado 30x por segundo.
- **Clientes** (navegador, PC ou celular): enviam só os comandos (direção, bomba, ação) e desenham a arena.
- Comunicação por **WebSocket** (`ws://` local, `wss://` na internet).
- Tudo é desenhado com blocos 32x32 — para trocar por sprites, veja [assets/sprites/LEIA-ME.md](assets/sprites/LEIA-ME.md).

## Testar no PC (sem exportar)

1. Abra o projeto no Godot 4.3 ou mais novo e aperte **F5**.
2. Clique em **Hospedar e jogar**.
3. Para outros jogadores no mesmo PC: *Depurar > Personalizar Instâncias de Execução* → 2 ou mais instâncias, e na outra janela clique em **ENTRAR** (`ws://localhost:9080`).
4. No lobby, o líder pode adicionar **bots** para testar sozinho.

Servidor pela linha de comando:

```
godot --headless --path . -- --server --port=9080
```

Teste automático (partida só de bots, sai no final):

```
godot --headless --path . -- --test-bots=6 --speed=8
```

## Docker (recomendado)

Configuração em `.env` (copie de `.env.example`; o `.env` não vai para o git):

| Variável | Para quê |
|---|---|
| `GODOT_VERSION` | versão do Godot usada no build (padrão 4.3) |
| `WEB_PORT` | porta do site (padrão 8060) |
| `GAME_PORT` | porta do servidor do jogo (mantenha 9080) |
| `SHARE_URL` | link exibido no lobby em "Convide pelo link", ex.: `http://SEU-IP:8060/` |
| `DOMAIN` | domínio da VPS (só no perfil `https`) |

**Rede local** (este PC):

```
docker compose up -d --build
```

Os outros abrem `http://SEU-IP:8060`. O firewall do Windows precisa liberar as portas 8060 e 9080 (veja abaixo).
O primeiro build baixa o Godot e os modelos de exportação (~1 GB) e exporta a versão web sozinho; os próximos usam cache.

**VPS com domínio (HTTPS automático):** aponte o domínio para o servidor, preencha `DOMAIN` no `.env` e rode:

```
docker compose --profile https up -d --build
```

O Caddy gera o certificado e serve tudo em `https://DOMINIO` (jogo conecta em `wss://DOMINIO/ws`). É um link só.

Comandos úteis: `docker compose logs -f game` (log do servidor), `docker compose restart game` (zera todas as salas), `docker compose down`.

## Jogar na rede local sem Docker

1. Exporte para Web em `build/web` (veja abaixo).
2. Suba o servidor do jogo e os arquivos, aceitando conexões da rede:

   ```
   godot --headless --path . -- --server --port=9080 --share-url=http://SEU-IP:8060/
   python servidor_web.py 8060 build/web
   ```

   `--share-url` é o link exibido no lobby em "Convide pelo link" (sem ele, o servidor tenta adivinhar o IP).
   O `servidor_web.py` usa cache revalidado: o navegador guarda os arquivos, mas confere a cada visita se mudaram,
   assim ninguém fica com uma versão antiga depois de reexportar.

3. Libere as portas no Firewall do Windows (PowerShell **como administrador**, uma vez só):

   ```
   New-NetFirewallRule -DisplayName "BombOffice" -Direction Inbound -Protocol TCP -LocalPort 8060,9080 -Action Allow -Profile Any
   ```

4. Os outros abrem `http://SEU-IP:8060` (veja o IP com `ipconfig`). O servidor já vem preenchido.

> O preset Web inclui um ajuste (`html/head_include`) que permite rodar via `http://` na rede local.
> Sem ele, o Godot exige HTTPS fora do `localhost`.
>
> **Som na web:** as músicas de entrada ficam **fora** do pacote do jogo (`index.pck`), para ele abrir
> mais rápido, e tocam em streaming pelo `scripts/web_audio.gd`, a partir de `assets/sounds/intro/index.json`.
> O Docker gera essa lista no build e o `servidor_web.py` lista a pasta na hora.
> Os efeitos tocam pelo Godot, exceto em `http://IP-DA-REDE`: lá o navegador não libera o AudioWorklet, e
> eles também vão pela Web Audio API, lendo os arquivos soltos de `assets/sounds/`.

## Desempenho online

- **Carregamento:** o site usa cache com revalidação (`Cache-Control: no-cache` + ETag). Da segunda visita
  em diante, o navegador só baixa de novo o que mudou no build. Sem as músicas, o pacote caiu de 3,6 MB para 0,2 MB.
- **Rede:** os snapshots vão em bytes (`scripts/snapshot_codec.gd`), e o mapa só é enviado quando muda.
  Cada snapshot tem ~200–300 B (antes ~1,6 KB), 30 vezes por segundo.
- **Movimento:** o cliente desenha ~100 ms atrás do servidor e interpola entre dois snapshots
  (`INTERP_DELAY` em `scripts/game_view.gd`). Atrasos irregulares da rede não viram trancos.
  Chão, pilares e paredes são desenhados uma vez só, numa camada própria.
- **Ping** no canto inferior direito da partida (verde < 80 ms, amarelo < 160 ms, vermelho acima).
- **Diagnóstico:**
  - `--net-stats` no cliente imprime snapshots/s, bytes, buffer e "engasgos".
  - `--fake-jitter=60` no servidor simula uma rede ruim.
  - `--test-bots` mostra o tamanho médio do snapshot.

## Publicar para a apresentação (um link para a plateia)

1. No Godot: *Editor > Gerenciar Modelos de Exportação > Baixar e Instalar*.
2. *Projeto > Exportar... > Web > Exportar Projeto* → salve em `build/web/index.html`.
3. Instale o Python 3 e o cloudflared (`winget install --id Cloudflare.cloudflared`).
4. Rode:

   ```
   .\publicar.ps1 -Godot "C:\caminho\Godot_v4.3-stable_win64_console.exe"
   ```

   O script sobe o servidor do jogo, serve os arquivos e abre dois túneis HTTPS gratuitos.
   Ele imprime (e copia) um link no formato
   `https://xxxx.trycloudflare.com/?server=wss://yyyy.trycloudflare.com` — é só mandar ou gerar um QR Code.
   O link muda a cada execução, e o PC precisa ficar ligado durante a apresentação.

**Alternativa permanente:** suba `build/web` no itch.io (projeto HTML5) e o servidor (preset *Servidor Linux*)
numa VPS com TLS (`--cert=fullchain.pem --key=privkey.pem` ativa `wss://`). O link fica
`https://seu-jogo.itch.io/...?server=wss://seu-servidor:9080`.

> Navegadores só rodam jogos Godot em HTTPS (ou `localhost`), por isso o túnel/hospedagem é necessário.

## Controles

| | Teclado | Controle | Celular |
|---|---|---|---|
| Mover | Setas / WASD | D-pad / analógico | analógico virtual (esquerda) |
| Bomba | Espaço, J, Z, Enter | A | botão BOMBA |
| Ação (luva / remoto) | Shift, E, K, X | B / X | botão AÇÃO |

## Regras

- Arena 17x13 com pilares indestrutíveis e blocos destrutíveis aleatórios; cada jogador começa num canto ou no meio de um lado (até 8).
- Bomba explode em cruz após 2,5 s; o fogo para no primeiro bloco destrutível (e o destrói), destrói itens e detona outras bombas em cadeia.
- Começa com 1 bomba e fogo 2. Não dá para atravessar bombas (exceto a que você acabou de soltar).
- Ao morrer, os itens coletados se espalham pela arena.
- **Morte súbita:** no último minuto, blocos caem em espiral de fora para dentro e esmagam quem estiver embaixo.
- Rodada termina quando sobra 1 (vitória) ou 0 (empate); quem chegar a N vitórias (padrão 3) é o campeão.
- No modal de vitória aparece o vencedor comemorando. Se for um jogador (não bot), ele pode escrever uma
  mensagem de até 20 caracteres (Enter), que aparece para todos acima do personagem, em maiúsculas, com onda e arco-íris.
- O líder do lobby (primeiro a entrar) escolhe vitórias, tempo da rodada, adiciona bots e inicia/encerra a partida.

### Salas

- Depois de **ENTRAR**, aparece a lista de salas: dá para **entrar** em uma sala existente ou **criar** uma
  (nome obrigatório, senha opcional). Salas com senha pedem a senha ao entrar.
- Até **8 salas** ao mesmo tempo no servidor, cada uma com até 8 jogadores e sua própria partida.
- Se o líder sair, a liderança passa para o próximo jogador da sala. Quando todos saem, a sala é excluída.
- **SAIR** volta para a lista de salas; **ENCERRAR SALA** (líder) manda todos de volta para a lista e exclui a sala.
- O link de convite leva o código da sala (`?sala=K7QX`): quem abre entra direto nela (pedindo a senha, se tiver).
  O código também aparece no log do servidor quando a sala é criada.

### Itens

| Sigla | Item | Efeito |
|---|---|---|
| B+ | Bomba +1 | +1 bomba simultânea (máx. 10) |
| F+ | Fogo +1 | +1 de alcance (máx. 10) |
| FM | Fogo Máximo | alcance máximo |
| S+ | Patins | mais velocidade |
| CH | Chute | andar contra uma bomba a chuta até bater em algo |
| LV | Luva | AÇÃO arremessa a bomba à frente 3 casas (quica e dá a volta na arena) |
| RC | Controle Remoto | bombas só explodem com AÇÃO (exclusivo com Perfurante) |
| PF | Bomba Perfurante | fogo atravessa blocos destrutíveis |
| LN | Bomba em Linha | BOMBA em cima de uma bomba solta todas em linha |
| SB | Super Bomba | a primeira bomba tem alcance máximo |
| AP | Atravessa Paredes | passa por blocos destrutíveis |
| AB | Atravessa Bombas | passa por cima de bombas |
| CL | Colete | invencível por 10 s |
| CR | Coração | aguenta uma explosão |
| :( | Caveira | doença por 15 s, contagiosa: lentidão, hiper velocidade, diarreia de bombas, não solta bombas, fogo fraco, controles invertidos ou pavio curto |

## Estrutura

```
scenes/main.tscn          cena única (nó "Main")
scripts/main.gd           menu, lista de salas, lobby, HUD, RPCs (roteia cada jogador para a sua sala)
scripts/room.gd           uma sala no servidor: lobby, placar, rodadas e a simulação
scripts/server_game.gd    simulação autoritativa + IA dos bots
scripts/game_view.gd      desenho da arena (buffer de interpolação dos snapshots)
scripts/snapshot_codec.gd snapshot compacto em bytes (servidor -> clientes)
scripts/web_audio.gd      música em streaming e efeitos pela Web Audio API (navegador)
scripts/g.gd              constantes e regras (ajuste o balanceamento aqui)
scripts/net.gd            conexão WebSocket (autoload Net)
scripts/sprites.gd        carrega PNGs ou gera blocos (autoload Sprites)
scripts/touch_controls.gd controles de toque
docker-compose.yml        servidor do jogo + site (+ Caddy no perfil https)
docker/                   Dockerfile, nginx.conf, Caddyfile
.env.example              modelo de configuração (copie para .env)
servidor_web.py           servidor web sem cache (alternativa sem Docker)
publicar.ps1              publica com um link público via túnel Cloudflare
```
