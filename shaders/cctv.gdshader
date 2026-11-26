// Imagem de câmera de vigilância por cima da arena (scripts/cctv.gd).
// Um único passe na tela: olho-de-peixe, aberração cromática, linhas de TV,
// faixa de VHS descendo, granulado, vinheta, glitch (explosões) e chuvisco (troca de câmera).
// As cores não mudam: elas identificam os jogadores.
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform float glitch : hint_range(0.0, 1.0) = 0.0;   // explosões
uniform float snow : hint_range(0.0, 1.0) = 0.0;     // chuvisco (sem sinal)
uniform float barrel = 0.10;        // olho-de-peixe
uniform float aberration = 1.6;     // separação de cor nas bordas (px)
uniform float grain = 0.05;
uniform float vignette = 0.45;
uniform float line_dark = 0.13;     // linhas de TV (como no menu: 1 a cada 4 px)
uniform float vhs_bar = 0.035;      // faixa clara de fita VHS descendo

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 px = SCREEN_PIXEL_SIZE;
	vec2 c = uv - 0.5;

	// lente: distorção de barril (o que sai da imagem vira a borda preta do monitor)
	vec2 duv = 0.5 + c * (1.0 + barrel * dot(c, c) * 2.0);

	// glitch: faixas horizontais deslocadas + tremida de linha
	if (glitch > 0.001) {
		float frame = floor(TIME * 30.0);
		float band = floor(uv.y * 22.0);
		float on = step(1.0 - glitch * 0.8, hash(vec2(band * 1.31, frame + 1.0)));
		duv.x += (hash(vec2(band, frame)) - 0.5) * 0.08 * glitch * on;
		duv.x += (hash(vec2(floor(uv.y / px.y), frame)) - 0.5) * 0.006 * glitch;
	}

	// aberração cromática: mais forte nas bordas e no glitch
	vec2 dir = length(c) > 0.0001 ? normalize(c) : vec2(0.0);
	vec2 off = dir * px * (aberration * length(c) * 2.0 + glitch * 7.0);
	vec3 col;
	col.r = texture(screen_tex, duv + off).r;
	col.g = texture(screen_tex, duv).g;
	col.b = texture(screen_tex, duv - off).b;

	// linhas de TV e a faixa clara que desce devagar (fita VHS)
	float line = mod(floor(uv.y / px.y), 4.0) < 1.0 ? 1.0 - line_dark : 1.0;
	col *= line;
	float bar_y = fract(TIME * 0.11) * 1.3 - 0.15;
	col += step(bar_y, uv.y) * step(uv.y, bar_y + 0.055) * vhs_bar;

	// granulado fino
	col += (hash(uv * vec2(1131.0, 771.0) + fract(TIME * 7.0) * 91.0) - 0.5) * grain;

	// vinheta
	col *= 1.0 - vignette * smoothstep(0.32, 0.78, length(c));

	// chuvisco (troca de câmera / sem sinal)
	if (snow > 0.001) {
		float s = hash(floor(uv / px / 2.0) + vec2(floor(TIME * 24.0) * 1.7, floor(TIME * 24.0) * 3.1));
		col = mix(col, vec3(s * 0.9), snow);
	}

	// fora da imagem distorcida: preto, com a borda suavizada
	vec2 e = min(duv, 1.0 - duv);
	float inside = smoothstep(0.0, 0.004, min(e.x, e.y));
	COLOR = vec4(col * inside, 1.0);
}
