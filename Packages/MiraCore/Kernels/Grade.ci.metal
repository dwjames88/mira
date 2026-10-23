// Core Image Metal kernels for Mira's colour grading stages.
//
// Compiled by scripts/build-kernels.sh into Sources/MiraCore/Resources/Grade.ci.metallib (checked in).
// Do not add this directory to a SwiftPM target: SwiftPM would compile it without -fcikernel.
//
// Pixels arrive in the Core Image working space (extended linear sRGB, premultiplied alpha).

#include <CoreImage/CoreImage.h>
using namespace metal;
using namespace coreimage;

// MARK: Shared helpers

static inline float3 miraUnpremultiply(float4 s) {
    return s.a > 0.0 ? s.rgb / s.a : s.rgb;
}

static inline float miraEncode1(float x) {
    float a = fabs(x);
    float e = a <= 0.0031308 ? 12.92 * a : 1.055 * pow(a, 1.0 / 2.4) - 0.055;
    return x < 0.0 ? -e : e;
}

static inline float miraDecode1(float x) {
    float a = fabs(x);
    float d = a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4);
    return x < 0.0 ? -d : d;
}

static inline float3 miraEncode(float3 c) { return float3(miraEncode1(c.r), miraEncode1(c.g), miraEncode1(c.b)); }
static inline float3 miraDecode(float3 c) { return float3(miraDecode1(c.r), miraDecode1(c.g), miraDecode1(c.b)); }

// MARK: Curves

// Row 0 of `lut` holds the composed RGB master + per-channel curves (one per colour channel),
// row 1 holds the luminance curve in all three channels. 1024 entries per row, indexed by the
// sRGB-encoded value. Values outside 0...1 pass through with their overshoot unchanged.
static inline float miraLookup(coreimage::sampler lut, float v, float row) {
    float c = clamp(v, 0.0, 1.0);
    float4 t = lut.sample(lut.transform(float2(c * 1023.0 + 0.5, row + 0.5)));
    return t.r;
}

static inline float3 miraLookup3(coreimage::sampler lut, float3 v) {
    float3 c = clamp(v, 0.0, 1.0);
    float4 r = lut.sample(lut.transform(float2(c.r * 1023.0 + 0.5, 0.5)));
    float4 g = lut.sample(lut.transform(float2(c.g * 1023.0 + 0.5, 0.5)));
    float4 b = lut.sample(lut.transform(float2(c.b * 1023.0 + 0.5, 0.5)));
    return float3(r.r, g.g, b.b) + (v - c);
}

extern "C" {
namespace coreimage {

float4 miraCurves(coreimage::sampler src, coreimage::sampler lut, float useLuma) {
    float4 s = src.sample(src.coord());
    if (s.a <= 0.0) { return s; }
    float3 e = miraEncode(miraUnpremultiply(s));
    e = miraLookup3(lut, e);
    if (useLuma > 0.5) {
        float y = dot(e, float3(0.2126, 0.7152, 0.0722));
        float y2 = miraLookup(lut, y, 1.0) + (y - clamp(y, 0.0, 1.0));
        if (y > 1.0e-4) {
            e *= y2 / y;
        } else {
            e += (y2 - y);
        }
    }
    return float4(miraDecode(e) * s.a, s.a);
}

} // namespace coreimage
} // extern "C"

// MARK: Colour mixer (OKLCh)

static inline float3 miraLinearToOklab(float3 c) {
    float l = 0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b;
    float m = 0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b;
    float s = 0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b;
    l = copysign(pow(fabs(l), 1.0 / 3.0), l);
    m = copysign(pow(fabs(m), 1.0 / 3.0), m);
    s = copysign(pow(fabs(s), 1.0 / 3.0), s);
    return float3(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                  1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                  0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s);
}

static inline float3 miraOklabToLinear(float3 lab) {
    float l = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z;
    float m = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z;
    float s = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z;
    l = l * l * l; m = m * m * m; s = s * s * s;
    return float3(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                  -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                  -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s);
}

// Hue centres of the eight ranges in OKLCh degrees: red, orange, yellow, green, aqua, blue,
// purple, magenta. Neighbouring ranges overlap with a raised-cosine ramp, so the weights always
// sum to 1.
constant float miraCentres[8] = {25.0, 55.0, 100.0, 145.0, 195.0, 258.0, 300.0, 340.0};

// Hue shift at slider = +-1, in degrees.
constant float miraMaxHueShift = 30.0;
// Luminance slider reach (fraction of the way to white / black).
constant float miraLumReach = 0.5;

extern "C" {
namespace coreimage {

// hue / sat / lum: ranges 0-3 in the first vector, 4-7 in the second; each value is -1...1.
float4 miraColorMixer(coreimage::sample_t s, float4 hue0, float4 hue1, float4 sat0, float4 sat1,
                      float4 lum0, float4 lum1) {
    if (s.a <= 0.0) { return s; }
    float3 rgb = miraUnpremultiply(s);
    float3 lab = miraLinearToOklab(rgb);
    float chroma = length(lab.yz);
    // Greys and near-greys are left alone, so a hue move can never tint a neutral.
    float cw = smoothstep(0.012, 0.07, chroma);
    if (cw <= 0.0) { return s; }

    float h = atan2(lab.z, lab.y) * (180.0 / M_PI_F);
    if (h < 0.0) { h += 360.0; }

    // Find the two ranges h falls between (wrapping from magenta back to red).
    int i0 = 7, i1 = 0;
    float c0 = miraCentres[7] - 360.0, c1 = miraCentres[0];
    for (int i = 0; i < 7; i++) {
        if (h >= miraCentres[i] && h < miraCentres[i + 1]) {
            i0 = i; i1 = i + 1; c0 = miraCentres[i]; c1 = miraCentres[i + 1];
        }
    }
    if (h >= miraCentres[7]) { i0 = 7; i1 = 0; c0 = miraCentres[7]; c1 = miraCentres[0] + 360.0; }
    float t = (h < c0 ? h + 360.0 - c0 : h - c0) / (c1 - c0);
    float w1 = 0.5 - 0.5 * cos(M_PI_F * clamp(t, 0.0, 1.0));
    float w0 = 1.0 - w1;

    float hueV[8] = {hue0.x, hue0.y, hue0.z, hue0.w, hue1.x, hue1.y, hue1.z, hue1.w};
    float satV[8] = {sat0.x, sat0.y, sat0.z, sat0.w, sat1.x, sat1.y, sat1.z, sat1.w};
    float lumV[8] = {lum0.x, lum0.y, lum0.z, lum0.w, lum1.x, lum1.y, lum1.z, lum1.w};
    float dh = (w0 * hueV[i0] + w1 * hueV[i1]) * cw;
    float ds = (w0 * satV[i0] + w1 * satV[i1]) * cw;
    float dl = (w0 * lumV[i0] + w1 * lumV[i1]) * cw;
    if (dh == 0.0 && ds == 0.0 && dl == 0.0) { return s; }

    float h2 = (h + dh * miraMaxHueShift) * (M_PI_F / 180.0);
    float c2 = chroma * (1.0 + ds);
    // Luminance moves toward white or black by a fraction of the remaining distance: no clipping.
    float l2 = dl >= 0.0 ? lab.x + (1.0 - lab.x) * dl * miraLumReach
                         : lab.x * (1.0 + dl * miraLumReach);

    float3 out = miraOklabToLinear(float3(l2, c2 * cos(h2), c2 * sin(h2)));
    // Gamut: pull chroma in (keeping hue and lightness) until nothing is negative.
    float lowest = min(out.r, min(out.g, out.b));
    if (lowest < 0.0) {
        float lo = 0.0, hi = 1.0;
        for (int k = 0; k < 6; k++) {
            float mid = 0.5 * (lo + hi);
            float3 test = miraOklabToLinear(float3(l2, mid * c2 * cos(h2), mid * c2 * sin(h2)));
            if (min(test.r, min(test.g, test.b)) < 0.0) { hi = mid; } else { lo = mid; }
        }
        out = miraOklabToLinear(float3(l2, lo * c2 * cos(h2), lo * c2 * sin(h2)));
        out = max(out, float3(0.0));
    }
    return float4(out * s.a, s.a);
}

} // namespace coreimage
} // extern "C"

// MARK: Tone (highlights, shadows, whites, blacks)

static inline float miraLuma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

// Applies a new luminance to an sRGB-encoded colour by scaling it (keeps hue and chroma ratio).
static inline float3 miraRelight(float3 e, float y, float y2) {
    if (y > 1.0e-4) { return e * (y2 / y); }
    return e + (y2 - y);
}

extern "C" {
namespace coreimage {

// `s` is the image, `b` the same image blurred (the local base the highlight/shadow masks follow).
// hl, sh, wh, bl are -1...1. Everything happens on sRGB-encoded luminance:
//   highlights / shadows: smooth masks on the blurred luminance, so they act locally;
//   whites / blacks: end-point curves y + 0.33 w y^3 and y + 0.2 b (1-y)^4 (monotonic for |w|,|b| <= 1).
float4 miraTone(coreimage::sample_t s, coreimage::sample_t b, float hl, float sh, float wh, float bl) {
    if (s.a <= 0.0) { return s; }
    float3 e = miraEncode(miraUnpremultiply(s));
    float y = miraLuma(e);
    float yb = miraLuma(miraEncode(miraUnpremultiply(b)));
    float y2 = y;
    float wS = 1.0 - smoothstep(0.05, 0.65, yb);
    float wH = smoothstep(0.35, 0.95, yb);
    if (sh > 0.0) { y2 += sh * wS * 0.3 * (1.0 - clamp(y2, 0.0, 1.0)); }
    else          { y2 += sh * wS * 0.6 * y2; }
    if (hl > 0.0) { y2 += hl * wH * 0.3 * (1.0 - clamp(y2, 0.0, 1.0)); }
    else          { y2 += hl * wH * 0.45 * y2; }
    float yc = clamp(y2, 0.0, 1.0);
    y2 += 0.33 * wh * yc * yc * yc;
    float ic = 1.0 - clamp(y2, 0.0, 1.0);
    y2 += 0.2 * bl * ic * ic * ic * ic;
    y2 = max(y2, 0.0);
    e = miraRelight(e, y, y2);
    return float4(miraDecode(e) * s.a, s.a);
}

// Local contrast: adds `amount` of the difference between the image and its blur to the
// luminance, weighted toward the midtones when `midtones` > 0.5 (clarity) or flat (texture).
float4 miraDetail(coreimage::sample_t s, coreimage::sample_t b, float amount, float midtones) {
    if (s.a <= 0.0) { return s; }
    float3 e = miraEncode(miraUnpremultiply(s));
    float y = miraLuma(e);
    float yb = miraLuma(miraEncode(miraUnpremultiply(b)));
    float t = 2.0 * clamp(y, 0.0, 1.0) - 1.0;
    float w = midtones > 0.5 ? 1.0 - t * t : 1.0;
    float y2 = max(y + amount * w * (y - yb), 0.0);
    e = miraRelight(e, y, y2);
    return float4(miraDecode(e) * s.a, s.a);
}

} // namespace coreimage
} // extern "C"

// MARK: Dodge and burn

extern "C" {
namespace coreimage {

// `m.r` is the painted mask (0...1, already multiplied by the stroke strength). `ev` is the signed
// stops at full mask (+ dodge, - burn). The change is a gain on linear light (like exposure), scaled
// by the tone-range weight (range 0 shadows, 1 midtones, 2 highlights) and an optional luminosity
// band [lo, hi] widened by `soft`, both measured on the sRGB-encoded luminance of the incoming pixel.
// The result is applied to RGB as a luma ratio, so hue and chroma ratios are kept. With `protect`,
// the change is compressed in the encoded domain (1 - exp) so dodge approaches but never reaches
// white and burn approaches but never reaches black, and no channel is pushed past 1.
float4 miraDodgeBurn(coreimage::sample_t s, coreimage::sample_t m, float ev, float range, float protect,
                     float lumaOn, float lo, float hi, float soft) {
    float amt = m.r;
    if (s.a <= 0.0 || amt <= 0.0005) { return s; }
    float3 c = miraUnpremultiply(s);
    float yl = max(miraLuma(c), 0.0);
    float ye = clamp(miraEncode1(yl), 0.0, 1.0);

    float w;
    if (range < 0.5)      { w = 1.0 - smoothstep(0.12, 0.62, ye); }
    else if (range < 1.5) { w = 1.0 - smoothstep(0.0, 0.55, fabs(ye - 0.5)); }
    else                  { w = smoothstep(0.38, 0.9, ye); }
    if (lumaOn > 0.5) {
        float a = soft > 0.0001 ? smoothstep(lo - soft, lo, ye) : (ye >= lo ? 1.0 : 0.0);
        float b = soft > 0.0001 ? 1.0 - smoothstep(hi, hi + soft, ye) : (ye <= hi ? 1.0 : 0.0);
        w *= a * b;
    }
    float k = amt * w;
    if (k <= 0.0001 || yl <= 1.0e-5) { return s; }

    float g = exp2(ev * k);
    float ratio = g;
    if (protect > 0.5) {
        float ye2 = miraEncode1(yl * g);
        float d = ye2 - ye;
        if (d > 0.0) {
            float h = max(1.0 - ye, 1.0e-4);
            d = h * (1.0 - exp(-d / h));
        } else {
            float l = max(ye, 1.0e-4);
            d = -l * (1.0 - exp(d / l));
        }
        ratio = miraDecode1(clamp(ye + d, 0.0, 1.0)) / yl;
        float mx = max(c.r, max(c.g, c.b));
        if (ratio > 1.0 && mx > 0.0) { ratio = min(ratio, max(1.0 / mx, 1.0)); }
    }
    return float4(c * ratio * s.a, s.a);
}

} // namespace coreimage
} // extern "C"
