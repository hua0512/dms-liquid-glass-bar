// Liquid glass for the DMS bar: a clear slab whose narrow, curved rim refracts the wallpaper.
// Distances are in logical pixels of the glass window.
#version 440

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 winSize;      // glass window size
    vec4 body;         // glass body rect: x, y, w, h
    vec4 radii;        // corner radii: tl, tr, br, bl
    vec4 wingA;        // goth wing square (w <= 0 disables it)
    vec4 wingAC;       // wing carving disc: cx, cy, rx, ry
    vec4 wingB;
    vec4 wingBC;
    vec4 sharpRect;    // area covered by sharpTex, relative to the window
    vec4 blurRect;     // area covered by blurTex, relative to the window
    vec4 tint;         // rgb + strength
    float pxRatio;     // device pixels per logical pixel
    float bevel;       // width of the curved rim (px)
    float depth;       // inward view offset at the very edge (px)
    float lensSign;    // 1 = physical (rim magnifies inward), -1 = rim pulls in what lies outside
    float frost;       // 0..1 blend towards the blurred texture
    float blurRadius;  // px
    float saturation;  // 1 = unchanged
    float dispersion;  // relative spread of the offset between colour channels
    float highlight;   // 0..1
    float lift;        // body brightening, 0..~0.05
    float fgLight;     // 1 when the bar's foreground is light, 0 when dark
    float scrim;       // 0..1 max legibility scrim strength
    float shadow;      // 0..1 drop shadow strength
    vec4 contentTint;  // average wallpaper colour behind the bar + strength
    vec2 hoverPos;     // pointer position over the bar (window coordinates)
    float hover;       // 0..1 pointer glow strength (0 when the pointer is elsewhere)
    float appear;      // 0..1 materialize progress when the bar shows or hides
} ubuf;

layout(binding = 1) uniform sampler2D sharpTex; // wallpaper under and around the window, 1:1
layout(binding = 2) uniform sampler2D blurTex;  // wider area, downscaled

float sdBody(vec2 p) {
    vec2 b = ubuf.body.zw * 0.5;
    vec2 q = p - ubuf.body.xy - b;
    float r = q.x > 0.0 ? (q.y > 0.0 ? ubuf.radii.z : ubuf.radii.y)
                        : (q.y > 0.0 ? ubuf.radii.w : ubuf.radii.x);
    r = min(r, min(b.x, b.y));
    vec2 d = abs(q) - b + r;
    return min(max(d.x, d.y), 0.0) + length(max(d, 0.0)) - r;
}

float sdBox(vec2 p, vec4 rect) {
    vec2 b = rect.zw * 0.5;
    vec2 d = abs(p - rect.xy - b) - b;
    return min(max(d.x, d.y), 0.0) + length(max(d, 0.0));
}

float sdDisc(vec2 p, vec4 rect, vec4 disc) {
    if (rect.z <= 0.0 || rect.w <= 0.0)
        return 1e5;
    return (length((p - disc.xy) / disc.zw) - 1.0) * min(disc.z, disc.w);
}

float sdWingBox(vec2 p, vec4 rect) {
    return (rect.z <= 0.0 || rect.w <= 0.0) ? 1e5 : sdBox(p, rect);
}

// Body plus the goth wing squares (which overlap into the body), minus the discs that carve
// the concave fillets. The discs only touch the body tangentially, so the body stays exact.
float sdf(vec2 p) {
    float d = min(sdBody(p), min(sdWingBox(p, ubuf.wingA), sdWingBox(p, ubuf.wingB)));
    return max(d, max(-sdDisc(p, ubuf.wingA, ubuf.wingAC), -sdDisc(p, ubuf.wingB, ubuf.wingBC)));
}

vec3 sharpAt(vec2 p) {
    return texture(sharpTex, (p - ubuf.sharpRect.xy) / ubuf.sharpRect.zw).rgb;
}

// Gaussian-weighted Vogel disk over the downscaled texture.
// Same 24 taps, with constant offsets and weights evaluated ahead of time.
vec3 blurAt(vec2 p, float radius) {
    vec2 uv = (p - ubuf.blurRect.xy) / ubuf.blurRect.zw;
    vec2 k = vec2(radius) / ubuf.blurRect.zw;
    vec3 acc = vec3(0.0);
    acc += texture(blurTex, uv + vec2(0.144337567, 0.000000000) * k).rgb * 0.949249759;
    acc += texture(blurTex, uv + vec2(-0.184342220, 0.168872574) * k).rgb * 0.855345327;
    acc += texture(blurTex, uv + vec2(0.028216531, -0.321512821) * k).rgb * 0.770730381;
    acc += texture(blurTex, uv + vec2(0.232351428, 0.303061293) * k).rgb * 0.694485960;
    acc += texture(blurTex, uv + vec2(-0.426393447, -0.075422997) * k).rgb * 0.625784010;
    acc += texture(blurTex, uv + vec2(0.403917096, -0.256938993) * k).rgb * 0.563878393;
    acc += texture(blurTex, uv + vec2(-0.135102365, 0.502574059) * k).rgb * 0.508096782;
    acc += texture(blurTex, uv + vec2(-0.257654859, -0.496098754) * k).rgb * 0.457833362;
    acc += texture(blurTex, uv + vec2(0.559007984, 0.204148820) * k).rgb * 0.412542245;
    acc += texture(blurTex, uv + vec2(-0.581554660, 0.240057308) * k).rgb * 0.371731547;
    acc += texture(blurTex, uv + vec2(0.280347776, -0.599086909) * k).rgb * 0.334958043;
    acc += texture(blurTex, uv + vec2(0.207169872, 0.660490205) * k).rgb * 0.301822354;
    acc += texture(blurTex, uv + vec2(-0.624412405, -0.361859755) * k).rgb * 0.271964609;
    acc += texture(blurTex, uv + vec2(0.732506831, -0.161039569) * k).rgb * 0.245060539;
    acc += texture(blurTex, uv + vec2(-0.447037518, 0.635864863) * k).rgb * 0.220817951;
    acc += texture(blurTex, uv + vec2(-0.103276014, -0.796973901) * k).rgb * 0.198973559;
    acc += texture(blurTex, uv + vec2(0.634013451, 0.534347213) * k).rgb * 0.179290121;
    acc += texture(blurTex, uv + vec2(-0.853183369, 0.035281807) * k).rgb * 0.161553864;
    acc += texture(blurTex, uv + vec2(0.622331776, -0.619303232) * k).rgb * 0.145572165;
    acc += texture(blurTex, uv + vec2(-0.041636411, 0.900425682) * k).rgb * 0.131171454;
    acc += texture(blurTex, uv + vec2(-0.592150676, -0.709594422) * k).rgb * 0.118195332;
    acc += texture(blurTex, uv + vec2(0.938032059, 0.126210892) * k).rgb * 0.106502871;
    acc += texture(blurTex, uv + vec2(-0.794792670, 0.552996032) * k).rgb * 0.095967086;
    acc += texture(blurTex, uv + vec2(0.217183078, -0.965400527) * k).rgb * 0.086473552;
    return acc * 0.113533135;
}

float luma(vec3 c) {
    return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

vec3 sampleScene(vec2 p) {
    vec3 c = sharpAt(p);
    if (ubuf.frost > 0.0)
        c = mix(c, blurAt(p, ubuf.blurRadius), ubuf.frost);
    return c;
}

void main() {
    vec2 p = qt_TexCoord0 * ubuf.winSize;
    float d = sdf(p);
    float cover = clamp(0.5 - d * ubuf.pxRatio, 0.0, 1.0);

    // Soft, wide, low drop shadow, a little below the slab, only outside it.
    float shadowA = 0.0;
    if (ubuf.shadow > 0.0 && cover < 1.0) {
        float ds = max(sdf(p - vec2(0.0, 3.0)), 0.0);
        shadowA = ubuf.shadow * 0.30 * exp(-ds * ds / 72.0) * (1.0 - cover);
    }
    // Materialize: the slab fades in while its lensing builds up, and the shadow follows.
    float appear = smoothstep(0.0, 1.0, ubuf.appear);
    cover *= appear;
    shadowA *= appear;
    if (cover <= 0.0) {
        fragColor = vec4(0.0, 0.0, 0.0, shadowA) * ubuf.qt_Opacity;
        return;
    }

    const float e = 0.5;
    vec2 g = vec2(sdf(p + vec2(e, 0.0)) - sdf(p - vec2(e, 0.0)),
                  sdf(p + vec2(0.0, e)) - sdf(p - vec2(0.0, e)));
    vec2 n = dot(g, g) > 1e-8 ? normalize(g) : vec2(0.0, -1.0); // outward normal in the plane

    // Narrow rim lens: across the bevel the slab's surface curves down to the edge, so the view
    // is bent inward by an amount that eases from `depth` at the edge to nothing at the inner end.
    // That magnifies what lies just inside the edge smoothly (about 2.5x at the very edge, 1x at
    // the inner end) without folding or smearing; the body inside the rim is untouched.
    float s = max(-d, 0.0);
    float x = clamp(s / max(ubuf.bevel, 1e-3), 0.0, 1.0);
    float u = 1.0 - x;
    vec2 off = -n * ubuf.depth * appear * pow(u, 1.5) * ubuf.lensSign;
    vec3 col;
    // The frost blur of the flat body, reused for the legibility scrim below.
    vec3 bodyBlur = vec3(-1.0);
    // Inside the flat body off is zero, so the three channel samples are identical.
    if (ubuf.dispersion > 0.0 && dot(off, off) > 0.0) {
        // Fringe grows with the bend, so it only shows right at the edge.
        col = vec3(sampleScene(p + off * (1.0 - ubuf.dispersion)).r,
                   sampleScene(p + off).g,
                   sampleScene(p + off * (1.0 + ubuf.dispersion)).b);
    } else if (ubuf.frost > 0.0 && dot(off, off) == 0.0) {
        bodyBlur = blurAt(p, ubuf.blurRadius);
        col = mix(sharpAt(p), bodyBlur, ubuf.frost);
    } else {
        col = sampleScene(p + off);
    }

    col = clamp(mix(vec3(luma(col)), col, ubuf.saturation), 0.0, 1.0);
    col = mix(col, ubuf.tint.rgb, ubuf.tint.a);

    // Pick up the colour of the surroundings: the average wallpaper colour, slightly richer.
    if (ubuf.contentTint.a > 0.0) {
        vec3 avg = clamp(mix(vec3(luma(ubuf.contentTint.rgb)), ubuf.contentTint.rgb, 1.4), 0.0, 1.0);
        col = mix(col, avg, ubuf.contentTint.a);
    }

    // A very slight lift of the body, compressed towards white so it never clips.
    col = col + (1.0 - col) * ubuf.lift;

    // Legibility scrim: only where the wallpaper behind fights the foreground, and only a little.
    if (ubuf.scrim > 0.0) {
        // The background behind the text: the body's frost blur, or one tap of the blurred copy.
        float bg = luma(bodyBlur.r >= 0.0 ? bodyBlur : texture(blurTex, (p - ubuf.blurRect.xy) / ubuf.blurRect.zw).rgb);
        float need = ubuf.fgLight > 0.5 ? smoothstep(0.35, 0.75, bg) : 1.0 - smoothstep(0.25, 0.65, bg);
        vec3 toward = ubuf.fgLight > 0.5 ? vec3(0.0) : vec3(1.0);
        col = mix(col, toward, need * ubuf.scrim * 0.12);
    }

    // Rim shading: the curved band is a touch darker, giving the slab some thickness.
    col *= 1.0 - 0.05 * ubuf.highlight * u * u;

    // Light gathers where the rim bends it: a thin bright refracted ring just inside the edge,
    // lit from the top left with a softer counter-light from the bottom right, over a faint
    // glow across the outer part of the bevel.
    float sd = s * ubuf.pxRatio;
    float hair = exp(-sd * sd / 1.2);
    float bt = (sd - 1.6) / 1.4;
    float band = exp(-bt * bt);
    float arc1 = pow(max(dot(n, normalize(vec2(-0.72, -0.69))), 0.0), 4.0);
    float arc2 = pow(max(dot(n, normalize(vec2(0.72, 0.69))), 0.0), 4.0);
    float ring = band * (0.16 + 0.70 * arc1 + 0.38 * arc2) + 0.20 * hair;
    float lensGlow = 0.07 * pow(u, 3.0) * (0.6 + 0.4 * arc1);
    // Pointer light: a soft glow on the glass under the pointer that also brightens the ring.
    float glow = 0.0;
    if (ubuf.hover > 0.0) {
        float r = max(min(ubuf.body.z, ubuf.body.w), 1.0); // the bar's thickness, also when vertical
        vec2 dp = p - ubuf.hoverPos;
        glow = ubuf.hover * exp(-dot(dp, dp) / (2.0 * r * r));
        ring += glow * band * 0.6;
    }
    float spec = ubuf.highlight * appear * (ring + lensGlow) + 0.09 * glow;
    spec = min(spec, 0.7);
    col = col + (1.0 - col) * spec;

    fragColor = vec4(col * cover, cover + shadowA) * ubuf.qt_Opacity;
}
