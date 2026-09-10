float getSdfRectangle(in vec2 p, in vec2 xy, in vec2 b)
{
 vec2 d = abs(p - xy) - b;
 return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

// Based on Inigo Quilez's 2D distance functions article: https://iquilezles.org/articles/distfunctions2d/

float seg(in vec2 p, in vec2 a, in vec2 b, inout float s, float d) {
 vec2 e = b - a;
 vec2 w = p - a;
 vec2 proj = a + e * clamp(dot(w, e) / dot(e, e), 0.0, 1.0);
 float segd = dot(p - proj, p - proj);
 d = min(d, segd);

 float c0 = step(0.0, p.y - a.y);
 float c1 = 1.0 - step(0.0, p.y - b.y);
 float c2 = 1.0 - step(0.0, e.x * w.y - e.y * w.x);
 float allCond = c0 * c1 * c2;
 float noneCond = (1.0 - c0) * (1.0 - c1) * (1.0 - c2);
 float flip = mix(1.0, -1.0, step(0.5, allCond + noneCond));
 s *= flip;
 return d;
}

float getSdfParallelogram(in vec2 p, in vec2 v0, in vec2 v1, in vec2 v2, in vec2 v3) {
 float s = 1.0;
 float d = dot(p - v0, p - v0);

 d = seg(p, v0, v3, s, d);
 d = seg(p, v1, v0, s, d);
 d = seg(p, v2, v1, s, d);
 d = seg(p, v3, v2, s, d);

 return s * sqrt(d);
}

vec2 normalize(vec2 value, float isPosition) {
 return (value * 2.0 - (iResolution.xy * isPosition)) / iResolution.y;
}

float antialising(float distance) {
 return 1. - smoothstep(0., normalize(vec2(2., 2.), 0.).x, distance);
}

float glow(float d, float radius) {
 return exp(-max(d, 0.0) / radius) * step(0.0, d);
}

float determineStartVertexFactor(vec2 a, vec2 b) {
 float condition1 = step(b.x, a.x) * step(a.y, b.y);
 float condition2 = step(a.x, b.x) * step(b.y, a.y);
 return 1.0 - max(condition1, condition2);
}

vec2 getRectangleCenter(vec4 rectangle) {
 return vec2(rectangle.x + (rectangle.z / 2.), rectangle.y - (rectangle.w / 2.));
}
const float DURATION_SECONDS = 0.20;
const float EASE_POWER = 2.0;
const float GLOW_RADIUS = 0.02;
const float GLOW_STRENGTH = 0.25;

vec3 screenBlend(vec3 base, vec3 light) {
 return 1.0 - (1.0 - base) * (1.0 - light);
}

float ease(float x) {
 return pow(1.0 - x, EASE_POWER);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord)
{
 #if !defined(WEB)
 fragColor = texture(iChannel0, fragCoord.xy / iResolution.xy);
 #endif
 vec2 vu = normalize(fragCoord, 1.);
 vec2 offsetFactor = vec2(-.5, 0.5);

 vec4 currentCursor = vec4(normalize(iCurrentCursor.xy, 1.), normalize(iCurrentCursor.zw, 0.));
 vec4 previousCursor = vec4(normalize(iPreviousCursor.xy, 1.), normalize(iPreviousCursor.zw, 0.));

 float vertexFactor = determineStartVertexFactor(currentCursor.xy, previousCursor.xy);
 float invertedVertexFactor = 1.0 - vertexFactor;

 vec2 v0 = vec2(currentCursor.x + currentCursor.z * vertexFactor, currentCursor.y - currentCursor.w);
 vec2 v1 = vec2(currentCursor.x + currentCursor.z * invertedVertexFactor, currentCursor.y);
 vec2 v2 = vec2(previousCursor.x + currentCursor.z * invertedVertexFactor, previousCursor.y);
 vec2 v3 = vec2(previousCursor.x + currentCursor.z * vertexFactor, previousCursor.y - previousCursor.w);

 float sdfCurrentCursor = getSdfRectangle(vu, currentCursor.xy - (currentCursor.zw * offsetFactor), currentCursor.zw * 0.5);
 float sdfTrail = getSdfParallelogram(vu, v0, v1, v2, v3);

 float progress = clamp((iTime - iTimeCursorChange) / DURATION_SECONDS, 0.0, 1.0);
 float easedProgress = ease(progress);
 vec2 centerCC = getRectangleCenter(currentCursor);
 vec2 centerCP = getRectangleCenter(previousCursor);
 float lineLength = distance(centerCC, centerCP);

 vec4 newColor = vec4(fragColor);
 float fadeFactor = 1.0 - smoothstep(lineLength, sdfCurrentCursor, easedProgress * lineLength);

 float trailT = clamp(sdfCurrentCursor / max(lineLength, 1e-4), 0.0, 1.0);

 newColor = mix(newColor, iCurrentCursorColor, antialising(sdfTrail) * fadeFactor);
 newColor = mix(newColor, iCurrentCursorColor, antialising(sdfCurrentCursor));
 newColor = mix(newColor, fragColor, step(sdfCurrentCursor, 0.));
 fragColor = mix(fragColor, newColor, step(sdfCurrentCursor, easedProgress * lineLength));

 float glowTaper = 1.0 - trailT;
 float trailGlow = glow(sdfTrail, GLOW_RADIUS) * glowTaper;
 float cursorGlow = glow(sdfCurrentCursor, GLOW_RADIUS);
 vec3 glowColor = iCurrentCursorColor.rgb * (trailGlow + cursorGlow);
 glowColor = clamp(glowColor * GLOW_STRENGTH * easedProgress, 0.0, 1.0);
 fragColor.rgb = screenBlend(fragColor.rgb, glowColor);
}
