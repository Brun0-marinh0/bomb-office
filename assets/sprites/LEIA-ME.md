# Sprites (32x32)

Tudo que não tiver PNG continua sendo desenhado como bloco colorido gerado pelo código,
então dá para trocar a arte aos poucos. O filtro de textura do projeto é "Nearest" (pixel art nítida).

## Jogador — `player/<animação>/frame_01.png, frame_02.png, ...`

Desenhe em **tons de cinza**: a cor de cada jogador é aplicada por cima (modulate).
O jogo carrega todos os quadros em sequência (`frame_01`, `frame_02`...) até não achar o próximo,
então pode ter qualquer quantidade de quadros por animação.

| Pasta | Quando toca | Quadros | Velocidade |
|---|---|---|---|
| `walk_down/` | andando para baixo (o 1º quadro é o parado) | 8 | 12 fps, repete |
| `walk_up/` | andando para cima | 8 | 12 fps, repete |
| `walk_right/` | andando para a direita | 8 | 12 fps, repete |
| `walk_left/` | andando para a esquerda | 8 | 12 fps, repete |
| `place_bomb/` | ao soltar uma bomba | 5 | 16 fps, uma vez |
| `throw/` | ao arremessar uma bomba com a Luva | 8 | 18 fps, uma vez |
| `dizzy/` | parado com doença da Caveira | 8 | 8 fps, repete |
| `death/` | ao morrer (o corpo fica no último quadro, desbotando) | 8 | 12 fps, uma vez |
| `victory/` | vencedor no fim da rodada | 3 | 6 fps, vai e volta |

As velocidades ficam em `ANIM_FPS`, em `scripts/game_view.gd`.

## Arena e itens — arquivos soltos nesta pasta

| Arquivo | O que é |
|---|---|
| `floor.png` / `floor_alt.png` | Chão (alternado em xadrez) |
| `hard.png` | Bloco indestrutível (bordas e pilares) |
| `soft.png` | Bloco destrutível |
| `fallen.png` | Bloco que cai na morte súbita |
| `bomb.png` | Bomba |
| `flame.png` | Fogo da explosão |
| `item_bomb_up.png` | Bomba +1 |
| `item_fire_up.png` | Fogo +1 |
| `item_full_fire.png` | Fogo Máximo |
| `item_speed_up.png` | Patins |
| `item_kick.png` | Chute |
| `item_punch.png` | Luva |
| `item_remote.png` | Controle Remoto |
| `item_pierce.png` | Bomba Perfurante |
| `item_line.png` | Bomba em Linha |
| `item_power.png` | Super Bomba |
| `item_wall_pass.png` | Atravessa Paredes |
| `item_bomb_pass.png` | Atravessa Bombas |
| `item_vest.png` | Colete |
| `item_heart.png` | Coração |
| `item_skull.png` | Caveira |
