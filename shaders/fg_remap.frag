// Re-colours the bar's widgets from the current theme palette to the opposite-mode palette, so the
// foreground can follow what is behind the bar instead of the global light/dark mode.
// Only pixels that lie on the palette (text, icons, pill fills and their anti-aliased mixes) move;
// anything else (app icons, album art, warning colours) is left alone.
#version 440

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 srcText;    // current palette
    vec4 srcVariant;
    vec4 srcPrimary;
    vec4 srcFill;
    vec4 dstText;    // opposite-mode palette
    vec4 dstVariant;
    vec4 dstPrimary;
    vec4 dstFill;
    float tolerance; // RGB distance still counted as "on the palette"
    float fillAlpha; // opacity of the pill fill behind widgets
} ubuf;

layout(binding = 1) uniform sampler2D source;

// Distance from c to segment a-b, with the segment parameter in t.
float segDist(vec3 c, vec3 a, vec3 b, out float t) {
    vec3 ab = b - a;
    float l2 = dot(ab, ab);
    t = l2 > 1e-6 ? clamp(dot(c - a, ab) / l2, 0.0, 1.0) : 0.0;
    return length(c - (a + ab * t));
}

void main() {
    vec4 px = texture(source, qt_TexCoord0);
    if (px.a <= 0.002) {
        fragColor = px * ubuf.qt_Opacity;
        return;
    }
    vec3 c = px.rgb / px.a;

    // A widget pixel is either a foreground colour over nothing (on its own colour, any alpha)
    // or a foreground colour over the pill fill. In the second case its alpha fixes how much fill
    // is in the mix, so a grey that merely happens to lie between the two colours (an app icon,
    // say) does not match. The mismatch counts towards the distance.
    float A = px.a;
    float fa = ubuf.fillAlpha;
    float at = clamp((A - fa) / max(1.0 - fa, 1e-3), 0.0, 1.0);
    float texp = min(1.0, fa * (1.0 - at) / max(A, 1e-3));

    float t, best = 1e3;
    vec3 mapped = c;
    float d = segDist(c, ubuf.srcText.rgb, ubuf.srcFill.rgb, t);
    d += 0.5 * min(t, abs(t - texp));
    if (d < best) { best = d; mapped = mix(ubuf.dstText.rgb, ubuf.dstFill.rgb, t); }
    d = segDist(c, ubuf.srcVariant.rgb, ubuf.srcFill.rgb, t);
    d += 0.5 * min(t, abs(t - texp));
    if (d < best) { best = d; mapped = mix(ubuf.dstVariant.rgb, ubuf.dstFill.rgb, t); }
    d = segDist(c, ubuf.srcPrimary.rgb, ubuf.srcFill.rgb, t);
    d += 0.5 * min(t, abs(t - texp));
    if (d < best) { best = d; mapped = mix(ubuf.dstPrimary.rgb, ubuf.dstFill.rgb, t); }

    // Un-premultiplying faint edge pixels amplifies 8-bit rounding, so widen the tolerance there.
    float tol = ubuf.tolerance + 2.5 / (255.0 * px.a);
    float w = 1.0 - smoothstep(tol * 0.6, tol, best);
    // Not on the palette: glyphs of a light source colour may still be text or icons, because the
    // rasteriser may use sub-pixel (per-channel) coverage or a gamma-adjusted alpha, either of
    // which takes the un-premultiplied colour off the palette. For a light colour the coverage can be read back per channel instead (over
    // nothing, or over the pill fill), and the glyph redrawn in the target colour.
    if (w < 0.5) {
        for (int i = 0; i < 2; i++) {
            vec3 S = i == 0 ? ubuf.srcText.rgb : ubuf.srcVariant.rgb;
            vec3 D = i == 0 ? ubuf.dstText.rgb : ubuf.dstVariant.rgb;
            if (min(S.r, min(S.g, S.b)) < 0.3)
                continue;
            vec3 Ff = ubuf.srcFill.rgb * ubuf.fillAlpha;
            vec3 kA = px.rgb / S;
            vec3 kB = (px.rgb - Ff) / max(S - Ff, vec3(0.05));
            bool okA = all(greaterThanEqual(kA, vec3(-0.1))) && all(lessThanEqual(kA, vec3(1.2)));
            bool okB = px.a >= ubuf.fillAlpha - 0.02 && all(greaterThanEqual(kB, vec3(-0.1))) && all(lessThanEqual(kB, vec3(1.2)));
            bool overFill = okB && (px.a > ubuf.fillAlpha + 0.01 || !okA);
            vec3 k = overFill ? kB : kA;
            float spread = max(k.r, max(k.g, k.b)) - min(k.r, min(k.g, k.b));
            // Opaque pixels only count when their channels differ (sub-pixel glyph cores);
            // a flat opaque colour that is not on the palette belongs to an image.
            bool glyphLike = px.a < 0.995 ? spread < 0.9 : (spread > 0.06 && spread < 0.6);
            if ((okA || okB) && glyphLike) {
                float cov = clamp((k.r + k.g + k.b) / 3.0, 0.0, 1.0);
                vec4 o = vec4(D * cov, cov);
                if (overFill)
                    o += vec4(ubuf.dstFill.rgb, 1.0) * ubuf.fillAlpha * (1.0 - cov);
                fragColor = o * ubuf.qt_Opacity;
                return;
            }
        }
    }

    vec3 outc = mix(c, mapped, w);
    fragColor = vec4(outc * px.a, px.a) * ubuf.qt_Opacity;
}
