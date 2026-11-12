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
vec3 blurAt(vec2 p, float radius) {
    vec2 uv = (p - ubuf.blurRect.xy) / ubuf.blurRect.zw;
    vec2 k = vec2(radius) / ubuf.blurRect.zw;
    vec3 acc = vec3(0.0);
    float wsum = 0.0;
    for (int i = 0; i < 24; i++) {
        float r = sqrt((float(i) + 0.5) / 24.0);
        float a = float(i) * 2.39996323;
        float w = exp(-2.5 * r * r);
        acc += texture(blurTex, uv + vec2(cos(a), sin(a)) * r * k).rgb * w;
        wsum += w;
    }
    return acc / wsum;
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

    // Soft drop shadow, slightly below the slab, only outside it.
    float shadowA = 0.0;
    if (ubuf.shadow > 0.0 && cover < 1.0) {
        float ds = sdf(p - vec2(0.0, 1.5));
        shadowA = ubuf.shadow * 0.18 * exp(-max(ds, 0.0) / 3.0) * (1.0 - cover);
    }
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
    vec2 off = -n * ubuf.depth * pow(u, 1.5) * ubuf.lensSign;
    vec3 col;
    if (ubuf.dispersion > 0.0) {
        // Fringe grows with the bend, so it only shows right at the edge.
        col = vec3(sampleScene(p + off * (1.0 - ubuf.dispersion)).r,
                   sampleScene(p + off).g,
                   sampleScene(p + off * (1.0 + ubuf.dispersion)).b);
    } else {
        col = sampleScene(p + off);
    }

    col = clamp(mix(vec3(luma(col)), col, ubuf.saturation), 0.0, 1.0);
    col = mix(col, ubuf.tint.rgb, ubuf.tint.a);

    // A very slight lift of the body, compressed towards white so it never clips.
    col = col + (1.0 - col) * ubuf.lift;

    // Legibility scrim: only where the wallpaper behind fights the foreground, and only a little.
    if (ubuf.scrim > 0.0) {
        float bg = luma(blurAt(p, 18.0));
        float need = ubuf.fgLight > 0.5 ? smoothstep(0.35, 0.75, bg) : 1.0 - smoothstep(0.25, 0.65, bg);
        vec3 toward = ubuf.fgLight > 0.5 ? vec3(0.0) : vec3(1.0);
        col = mix(col, toward, need * ubuf.scrim * 0.12);
    }

    // Rim shading: the curved band is a touch darker, giving the slab some thickness.
    col *= 1.0 - 0.05 * ubuf.highlight * u * u;

    // Specular: a crisp arc just inside the edge, brightest on the top-left and bottom-right
    // curves and tapering along the straight edges, plus a faint hairline all round.
    float sd = s * ubuf.pxRatio;
    float hair = exp(-sd * sd / 1.2);
    float band = exp(-pow((sd - 1.3) / 1.1, 2.0));
    float arc1 = pow(max(dot(n, normalize(vec2(-0.72, -0.69))), 0.0), 6.0);
    float arc2 = pow(max(dot(n, normalize(vec2(0.72, 0.69))), 0.0), 6.0);
    float spec = ubuf.highlight * (band * (0.75 * arc1 + 0.45 * arc2) + 0.22 * hair);
    spec = min(spec, 0.7);
    col = col + (1.0 - col) * spec;

    fragColor = vec4(col * cover, cover + shadowA) * ubuf.qt_Opacity;
}
