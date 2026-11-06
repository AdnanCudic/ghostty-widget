// Glyph fog — faint streams of flickering monospace characters that meander
// across the screen like water (inspired by the Claude app's new-chat screen).
// Blue by day, warm red in the evening, red-leaning over SSH, and a faint
// ripple where you click. Uses iDate, iMouse and iRemote, which this fork of
// Ghostty fills in.
//
// The widget service installs it for you (WIDGET_FOG / WIDGET_RIPPLE in
// %LOCALAPPDATA%\ghostty-widget\env). By hand instead:
//   custom-shader = C:/path/to/glyph_fog.glsl
//   custom-shader-animation = always

// --- CONFIGURATION ---
const float GLYPH_PX     = 1.25;  // size of one font dot in pixels (1.0 = smallest, 5x7 px letters)
const vec2  CELL         = vec2(10.0, 14.0);       // spacing between letters in pixels (cell size)
const vec3  TINT         = vec3(0.55, 0.54, 0.52); // glyph color
const float INTENSITY    = 0.075;  // brightness of the brightest glyphs
const float STREAM_SCALE = 520.0; // pixels per noise unit (bigger = longer, wider streams)
const float STREAM_WIDTH = 0.13;  // half-width of a stream in noise units (bigger = wider)
const float COVERAGE     = 0.60;  // 0..1, how much of the screen has streams at all
const float MEANDER      = 0.020; // how fast the streams change shape
const float FLOW_SPEED   = 2.2;   // how fast brightness ripples down the streams (cells/sec)
const float CHANGE_RATE  = 0.8;   // average glyph changes per second, per cell
const float CENTER_CLEAR = 0.45;  // 0 = no clearing, 1 = strong empty center
const float TEXT_PROTECT = 1.0;   // hide the effect behind terminal text

// --- TIME OF DAY (needs the patched Ghostty, which fills in iDate) ---
// Cool blue for the morning, warming to clay red through the afternoon and
// staying red overnight. Stock Ghostty falls back to TINT.
const vec3  TINT_DAY   = vec3(0.45, 0.60, 0.80); // cool blue
const vec3  TINT_NIGHT = vec3(0.86, 0.45, 0.33); // warm clay red
const float BLUE_FROM  = 5.0;   // 5:00  red starts fading to blue...
const float BLUE_BY    = 8.0;   // 8:00  ...fully blue
const float RED_FROM   = 13.0;  // 13:00 blue starts warming...
const float RED_BY     = 16.5;  // 16:30 ...fully red, until BLUE_FROM

// --- SSH SESSIONS (needs the patched Ghostty, which fills in iRemote) ---
const vec3  REMOTE_TINT  = vec3(0.90, 0.30, 0.29); // red
const float REMOTE_MIX   = 0.55;  // how far the fog leans red over SSH (0..1)

// --- CLICK RIPPLE (needs the patched Ghostty, which fills in iMouse) ---
const float CLICK_RIPPLE    = 1.0;   // 0 = off
const float CLICK_RADIUS    = 120.0; // px the ring grows to
const float CLICK_DURATION  = 0.9;   // seconds
const float CLICK_STRENGTH  = 0.05;  // brightness of ripple glyphs (kept faint)

// 5x7 bitmap font: 0-9, a-z. Rows 0-3 in LO, rows 4-6 in HI (bit = row*5 + col).
const int FONT_LO[36] = int[36](714286, 135364, 279086, 266527, 305544, 539711, 492620, 139807, 476718, 1001006, 538624, 635937, 47104, 842256, 571392, 232012, 575424, 635937, 137220, 274440, 173089, 135302, 699392, 635904, 571392, 572416, 841728, 635904, 47104, 72770, 574464, 574464, 574464, 345088, 574464, 293888);
const int FONT_HI[36] = int[36](14899, 14468, 31812, 14896, 8479, 14896, 14897, 2114, 14897, 6416, 31294, 15921, 14881, 31281, 14399, 2114, 14878, 17969, 14468, 6440, 9379, 14468, 17973, 17969, 14897, 1071, 16926, 1057, 15886, 12866, 23345, 4433, 10933, 17732, 14878, 31812);

float hash12(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float hash13(vec3 p) {
    p = fract(p * 0.1031);
    p += dot(p, p.zyx + 31.32);
    return fract((p.x + p.y) * p.z);
}

float vnoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    float a = hash12(i);
    float b = hash12(i + vec2(1.0, 0.0));
    float c = hash12(i + vec2(0.0, 1.0));
    float d = hash12(i + vec2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(vec2 p) {
    float v = 0.0;
    float a = 0.5;
    mat2 rot = mat2(0.8, 0.6, -0.6, 0.8);
    for (int i = 0; i < 5; i++) {
        v += a * vnoise(p);
        p = rot * p * 2.03 + 17.1;
        a *= 0.5;
    }
    return v;
}

// fbm stretched to use the full 0..1 range (raw fbm clusters around 0.5)
float fbmN(vec2 p) {
    return clamp((fbm(p) - 0.48) * 2.6 + 0.5, 0.0, 1.0);
}

// Font dot at integer dot coords g (x 0..4, y 0..6, y up).
float glyphDot(int idx, vec2 g) {
    int col = int(g.x);
    int row = 6 - int(g.y); // flip so row 0 is the top
    if (g.x < 0.0 || g.y < 0.0 || col > 4 || row < 0) return 0.0;
    int bits = row < 4 ? FONT_LO[idx] : FONT_HI[idx];
    int bit = row < 4 ? row * 5 + col : (row - 4) * 5 + col;
    return float((bits >> bit) & 1);
}

// Glyph coverage at pixel position lp inside the cell, centred in the cell.
// 4 sub-samples keep strokes even when GLYPH_PX is not a whole number.
float glyph(int idx, vec2 lp) {
    vec2 org = floor((CELL - vec2(5.0, 7.0) * GLYPH_PX) * 0.5);
    float cov = 0.0;
    for (int i = 0; i < 4; i++) {
        vec2 o = vec2(float(i & 1), float(i >> 1)) * 0.5 - 0.25;
        cov += glyphDot(idx, floor((lp + 0.5 + o - org) / GLYPH_PX));
    }
    return cov * 0.25;
}

// Glyph colour for the local time of day (iDate.w = seconds since midnight).
vec3 timeTint() {
    if (iDate.x < 1.0) return TINT;   // iDate not provided
    float h = iDate.w / 3600.0;
    float red = h < RED_FROM
        ? 1.0 - smoothstep(BLUE_FROM, BLUE_BY, h)   // night -> morning
        : smoothstep(RED_FROM, RED_BY, h);          // afternoon -> evening
    return mix(TINT_DAY, TINT_NIGHT, red);
}

// Faint ring that grows out of the last click (iMouse = x, y, click time, 1).
float clickRipple(vec2 pos) {
    if (iMouse.w < 0.5) return 0.0;
    float age = iTime - iMouse.z;
    if (age < 0.0 || age > CLICK_DURATION) return 0.0;
    float p = age / CLICK_DURATION;
    float front = CLICK_RADIUS * (1.0 - pow(1.0 - p, 2.0));
    float ring = 1.0 - smoothstep(0.0, 18.0, abs(distance(pos, iMouse.xy) - front));
    return ring * (1.0 - p) * CLICK_RIPPLE;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec4 term = texture(iChannel0, uv);

    vec2 cellId = floor(fragCoord / CELL);
    vec2 local  = fragCoord - cellId * CELL;   // pixel offset inside the cell
    float t = iTime;

    // sample every field at the cell centre so each glyph has one brightness
    vec2 cc = (cellId + 0.5) * CELL;
    vec2 p = cc / STREAM_SCALE;
    float m = t * MEANDER;

    // --- streams: ridges of a domain-warped fbm = long winding ribbons ---
    vec2 q = vec2(fbm(p * 0.8 + vec2(0.0, m * 3.0)),
                  fbm(p * 0.8 + vec2(5.2, 1.3) - vec2(m * 2.5, 0.0)));
    // difference of two warped fbms is centred on 0; its zero contour gives
    // thin, winding, continuous lines — the streams
    float n = fbm(p + 1.7 * q + vec2(m, -m * 1.5))
            - fbm(p * 1.1 + 1.7 * q.yx + vec2(9.1, 4.7) - vec2(m * 1.2, m));
    float stream = 1.0 - smoothstep(0.0, STREAM_WIDTH, abs(n));
    stream = stream * stream * (3.0 - 2.0 * stream);         // soft shoulders, no edge

    // only some regions carry streams; fade them in/out over a wide band
    float region = fbmN(p * 0.9 + vec2(17.0, 3.0) + vec2(m * 0.7, m));
    stream *= smoothstep(1.0 - COVERAGE - 0.12, 1.0 - COVERAGE + 0.18, region);

    // keep the middle of the screen calmer
    vec2 c = (uv - 0.5) * vec2(iResolution.x / iResolution.y, 1.0);
    stream *= mix(1.0, smoothstep(0.1, 0.8, length(c * vec2(0.8, 1.3))), CENTER_CLEAR);

    // --- current: brightness pulses travelling down the streams ---
    float current = vnoise(cellId * vec2(0.09, 0.22) + vec2(q.x * 4.0, t * FLOW_SPEED * 0.22));
    current = 0.35 + 0.65 * smoothstep(0.2, 0.9, current);

    float b = stream * current;                              // 0..1, continuous

    // --- glyph choice: cells re-roll at random moments ---
    float rCell = hash12(cellId);
    float rate = CHANGE_RATE * (0.3 + 1.4 * hash12(cellId + 71.3));
    float slot = floor(t * rate + rCell * 100.0);
    int idx = int(hash13(vec3(cellId, slot)) * 36.0) % 36;

    // sparse at the faint fringes, nearly solid text in the bright core,
    // with word-like gaps along each row
    float present = step(rCell, 0.25 + 0.75 * smoothstep(0.0, 0.5, b));
    float word = hash12(vec2(floor(cellId.x / 5.0 + hash12(vec2(cellId.y, 3.0)) * 5.0), cellId.y));
    present *= step(0.1, word) * step(0.08, hash13(vec3(cellId + 5.0, slot)));

    // a click briefly fills the ring's cells with glyphs
    float rp = clickRipple(cc);
    float pClick = step(hash12(cellId + 13.7), rp * 1.5);

    float glyphInk = glyph(idx, local);
    float ink = glyphInk * present;

    float base = 0.7 + 0.3 * hash13(vec3(cellId, slot + 0.5));
    float age = fract(t * rate + rCell * 100.0);
    float glow = b * base * (1.0 + 0.3 * exp(-age * 8.0));

    vec3 tint = mix(timeTint(), REMOTE_TINT, REMOTE_MIX * step(0.5, iRemote.x));
    vec3 effect = tint * (ink * glow * INTENSITY + glyphInk * pClick * rp * CLICK_STRENGTH);

    // don't paint over actual terminal text
    float lum = dot(term.rgb, vec3(0.299, 0.587, 0.114));
    float bgLum = 0.0;   // background is pure black
    float onText = smoothstep(bgLum + 0.05, bgLum + 0.25, lum) * TEXT_PROTECT;

    fragColor = vec4(term.rgb + effect * (1.0 - onText), term.a);
}
