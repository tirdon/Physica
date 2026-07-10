// MSL shaders — the Metal port of `Sources/WASM/Renderer/Shaders.swift` (WGSL).
// One source, the same five entry-point pairs sharing one binding scheme:
//   vertex   buffer(0) = per-vertex stream, buffer(1) = Globals, buffer(2) = DrawUniforms
//   fragment buffer(2) = DrawUniforms, buffer(3) = sprite texture aspect,
//            texture(0)/sampler(0) = sprite/image bitmap
// draw.params is the free vec4: paths use x = texture (0 flat / 1 chalk /
// 2 pencil / 3 blackboard backdrop), yz = grain seed; meshes use x = shading
// (0 lambert / 1 toon), y = toon bands, z = outline inflate.
//
// WebGPU and Metal share [0,1] NDC depth and top-left framebuffer origin, so the
// hand-rolled camera matrices project identically — no coordinate fixups.

#if os(macOS)

enum MetalShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Globals {
        float4x4 viewProjection;
    };

    struct DrawUniforms {
        float4x4 model;
        float4 color;
        float4 params;
    };

    static inline float hash21(float2 p) {
        float2 q = fract(p * float2(123.34, 456.21));
        q = q + dot(q, q + float2(45.32, 45.32));
        return fract(q.x * q.y);
    }

    // Smooth 2D value noise (bilinear hash blend) — blackboard smudge.
    static inline float vnoise(float2 p) {
        float2 cell = floor(p);
        float2 f = fract(p);
        float2 u = f * f * (3.0 - 2.0 * f);
        float a = hash21(cell);
        float b = hash21(cell + float2(1.0, 0.0));
        float c = hash21(cell + float2(0.0, 1.0));
        float d = hash21(cell + float2(1.0, 1.0));
        return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
    }

    // ---- Flat 2D (path stencil/cover/stroke) ----

    struct FlatIn {
        float3 position [[attribute(0)]];
    };

    struct FlatOut {
        float4 clip [[position]];
        float2 world;
    };

    vertex FlatOut vs_flat(FlatIn in [[stage_in]],
                           constant Globals& globals [[buffer(1)]],
                           constant DrawUniforms& draw [[buffer(2)]]) {
        FlatOut out;
        float4 world = draw.model * float4(in.position, 1.0);
        out.clip = globals.viewProjection * world;
        out.world = world.xy;
        return out;
    }

    fragment float4 fs_color(FlatOut in [[stage_in]],
                             constant DrawUniforms& draw [[buffer(2)]]) {
        float alpha = draw.color.a;
        if (draw.params.x > 2.5) {
            // Blackboard: low-frequency eraser smudge + fine chalk dust.
            float smudge = 0.6 * vnoise(in.world * 0.45)
                         + 0.4 * vnoise(in.world * 1.6 + float2(13.7, 7.1));
            float dust = hash21(floor(in.world * 240.0));
            float lift = 0.05 * smudge * smudge + 0.012 * dust;
            return float4(draw.color.rgb + float3(lift), 1.0);
        }
        // Entity position (params.yz) seeds the grain: the noise rides a moving
        // entity instead of letting it swim through world-pinned static.
        float2 seeded = in.world - draw.params.yz;
        if (draw.params.x > 1.5) {
            // Pencil: fine graphite striations along one diagonal + grain.
            float2 dir = float2(0.876, 0.482);
            float across = dot(seeded, float2(-dir.y, dir.x));
            float along = dot(seeded, dir);
            float line = hash21(float2(floor(across * 90.0), floor(along * 7.0)));
            float grain = hash21(floor(seeded * 160.0));
            alpha = alpha * clamp(0.25 + 0.55 * line + 0.30 * grain, 0.0, 1.0);
        } else if (draw.params.x > 0.5) {
            // Chalk: coarse slate grain with voids where the chalk skipped.
            float grain = hash21(floor(seeded * 220.0));
            float clump = hash21(floor(seeded * 55.0) + float2(7.0, 3.0));
            alpha = alpha * clamp(0.30 + 0.85 * grain * (0.45 + 0.75 * clump), 0.0, 1.0);
        }
        // Premultiplied output for (one, one-minus-src-alpha) blending.
        return float4(draw.color.rgb * alpha, alpha);
    }

    // ---- Sprites / images: textured quads ----

    struct SpriteOut {
        float4 clip [[position]];
        float2 uv;
    };

    // Sprite/image draws are always draw(6) with the vertex buffer bound at the
    // quad's byte offset, so vertex_id is 0..5 and indexes the UV table matching
    // the uploader's corner order (TL BL BR, TL BR TR).
    vertex SpriteOut vs_sprite(FlatIn in [[stage_in]],
                               uint vid [[vertex_id]],
                               constant Globals& globals [[buffer(1)]],
                               constant DrawUniforms& draw [[buffer(2)]]) {
        float2 uvs[6] = {
            float2(0.0, 0.0), float2(0.0, 1.0), float2(1.0, 1.0),
            float2(0.0, 0.0), float2(1.0, 1.0), float2(1.0, 0.0)
        };
        SpriteOut out;
        out.clip = globals.viewProjection * draw.model * float4(in.position, 1.0);
        out.uv = uvs[vid];
        return out;
    }

    fragment float4 fs_sprite(SpriteOut in [[stage_in]],
                              constant DrawUniforms& draw [[buffer(2)]],
                              constant float& texAspect [[buffer(3)]],
                              texture2d<float> spriteTexture [[texture(0)]],
                              sampler spriteSampler [[sampler(0)]]) {
        // Contain-fit letterbox: params.x = quad w/h, texAspect = texture w/h.
        float2 uv = in.uv;
        float quadAspect = max(draw.params.x, 1e-4);
        float ta = max(texAspect, 1e-4);
        if (quadAspect > ta) {
            uv.x = (uv.x - 0.5) * (quadAspect / ta) + 0.5;
        } else {
            uv.y = (uv.y - 0.5) * (ta / quadAspect) + 0.5;
        }
        float4 texel = spriteTexture.sample(spriteSampler, uv);
        if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
            return float4(0.0);   // letterbox bar: blend no-op
        }
        // Texture uploaded premultiplied; draw.color.a carries entity opacity.
        return texel * draw.color.a;
    }

    // ---- Meshes (Lambert / toon) ----

    struct MeshIn {
        float3 position [[attribute(0)]];
        float3 normal [[attribute(1)]];
    };

    struct MeshOut {
        float4 clip [[position]];
        float3 normal;
    };

    vertex MeshOut vs_mesh(MeshIn in [[stage_in]],
                           constant Globals& globals [[buffer(1)]],
                           constant DrawUniforms& draw [[buffer(2)]]) {
        MeshOut out;
        out.clip = globals.viewProjection * draw.model * float4(in.position, 1.0);
        out.normal = (draw.model * float4(in.normal, 0.0)).xyz;
        return out;
    }

    fragment float4 fs_mesh(MeshOut in [[stage_in]],
                            constant DrawUniforms& draw [[buffer(2)]]) {
        float3 n = normalize(in.normal);
        float3 lightDirection = normalize(float3(0.4, 0.8, 0.6));
        float lambert = max(dot(n, lightDirection), 0.0);
        float3 lit;
        if (draw.params.x > 0.5) {
            float bands = max(draw.params.y, 2.0);
            float leveled = floor(min(lambert, 0.999) * bands) / (bands - 1.0);
            lit = draw.color.rgb * (0.30 + 0.70 * min(leveled, 1.0));
        } else {
            float backLight = 0.15 * max(dot(n, -lightDirection), 0.0);
            lit = draw.color.rgb * (0.25 + 0.75 * lambert + backLight);
        }
        return float4(lit * draw.color.a, draw.color.a);
    }

    // ---- Toon outline: inverted hull, drawn with far-face survival ----

    struct OutlineOut {
        float4 clip [[position]];
    };

    vertex OutlineOut vs_outline(MeshIn in [[stage_in]],
                                 constant Globals& globals [[buffer(1)]],
                                 constant DrawUniforms& draw [[buffer(2)]]) {
        OutlineOut out;
        float3 inflated = in.position + normalize(in.normal) * draw.params.z;
        out.clip = globals.viewProjection * draw.model * float4(inflated, 1.0);
        return out;
    }

    fragment float4 fs_outline(constant DrawUniforms& draw [[buffer(2)]]) {
        return float4(draw.color.rgb * draw.color.a, draw.color.a);
    }
    """
}
#endif
