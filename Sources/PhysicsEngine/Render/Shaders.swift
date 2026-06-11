// WGSL shaders. One module, five entry-point pairs sharing the same bind layout:
// group 0 = per-frame globals, group 1 = per-draw uniforms (256-byte dynamic slots).
// draw.params is the free vec4: paths use x = texture (0 flat / 1 chalk / 2 pencil /
// 3 blackboard backdrop); meshes use x = shading (0 lambert / 1 toon), y = toon
// bands, z = outline inflate.

enum Shaders {
    static let module = """
    struct Globals {
        viewProjection: mat4x4<f32>,
    };

    struct DrawUniforms {
        model: mat4x4<f32>,
        color: vec4<f32>,
        params: vec4<f32>,
    };

    @group(0) @binding(0) var<uniform> globals: Globals;
    @group(1) @binding(0) var<uniform> draw: DrawUniforms;

    fn hash21(p: vec2<f32>) -> f32 {
        var q = fract(p * vec2<f32>(123.34, 456.21));
        q = q + dot(q, q + vec2<f32>(45.32, 45.32));
        return fract(q.x * q.y);
    }

    // Smooth 2D value noise (bilinear hash blend) — blackboard smudge.
    fn vnoise(p: vec2<f32>) -> f32 {
        let cell = floor(p);
        let f = fract(p);
        let u = f * f * (3.0 - 2.0 * f);
        let a = hash21(cell);
        let b = hash21(cell + vec2<f32>(1.0, 0.0));
        let c = hash21(cell + vec2<f32>(0.0, 1.0));
        let d = hash21(cell + vec2<f32>(1.0, 1.0));
        return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
    }

    // ---- Flat 2D (path stencil/cover/stroke) ----

    struct FlatOut {
        @builtin(position) clip: vec4<f32>,
        // World-space xy: anchors the procedural grain to the geometry.
        @location(0) world: vec2<f32>,
    };

    @vertex
    fn vs_flat(@location(0) position: vec3<f32>) -> FlatOut {
        var out: FlatOut;
        let world = draw.model * vec4<f32>(position, 1.0);
        out.clip = globals.viewProjection * world;
        out.world = world.xy;
        return out;
    }

    @fragment
    fn fs_color(in: FlatOut) -> @location(0) vec4<f32> {
        var alpha = draw.color.a;
        if (draw.params.x > 2.5) {
            // Blackboard: low-frequency eraser smudge + fine chalk dust,
            // brightening up from the slate tint. Opaque backdrop.
            let smudge = 0.6 * vnoise(in.world * 0.45)
                       + 0.4 * vnoise(in.world * 1.6 + vec2<f32>(13.7, 7.1));
            let dust = hash21(floor(in.world * 240.0));
            let lift = 0.05 * smudge * smudge + 0.012 * dust;
            return vec4<f32>(draw.color.rgb + vec3<f32>(lift), 1.0);
        }
        if (draw.params.x > 1.5) {
            // Pencil: fine graphite striations along one diagonal + grain.
            let dir = vec2<f32>(0.876, 0.482);   // normalized ~29° hatch
            let across = dot(in.world, vec2<f32>(-dir.y, dir.x));
            let along = dot(in.world, dir);
            let line = hash21(vec2<f32>(floor(across * 90.0), floor(along * 7.0)));
            let grain = hash21(floor(in.world * 160.0));
            alpha = alpha * clamp(0.25 + 0.55 * line + 0.30 * grain, 0.0, 1.0);
        } else if (draw.params.x > 0.5) {
            // Chalk: coarse slate grain with voids where the chalk skipped.
            let grain = hash21(floor(in.world * 220.0));
            let clump = hash21(floor(in.world * 55.0) + vec2<f32>(7.0, 3.0));
            alpha = alpha * clamp(0.30 + 0.85 * grain * (0.45 + 0.75 * clump), 0.0, 1.0);
        }
        // Premultiplied output for (one, one-minus-src-alpha) blending.
        return vec4<f32>(draw.color.rgb * alpha, alpha);
    }

    // ---- Meshes (Lambert / toon) ----

    struct MeshIn {
        @location(0) position: vec3<f32>,
        @location(1) normal: vec3<f32>,
    };

    struct MeshOut {
        @builtin(position) clip: vec4<f32>,
        @location(0) normal: vec3<f32>,
    };

    @vertex
    fn vs_mesh(in: MeshIn) -> MeshOut {
        var out: MeshOut;
        out.clip = globals.viewProjection * draw.model * vec4<f32>(in.position, 1.0);
        // Rigid + uniform scale assumption: rotate normals with the model matrix.
        out.normal = (draw.model * vec4<f32>(in.normal, 0.0)).xyz;
        return out;
    }

    @fragment
    fn fs_mesh(in: MeshOut) -> @location(0) vec4<f32> {
        let n = normalize(in.normal);
        let lightDir = normalize(vec3<f32>(0.4, 0.8, 0.6));
        let lambert = max(dot(n, lightDir), 0.0);
        var lit: vec3<f32>;
        if (draw.params.x > 0.5) {
            // Cel: diffuse quantized into flat bands, no fill light.
            let bands = max(draw.params.y, 2.0);
            let leveled = floor(min(lambert, 0.999) * bands) / (bands - 1.0);
            lit = draw.color.rgb * (0.30 + 0.70 * min(leveled, 1.0));
        } else {
            let backLight = 0.15 * max(dot(n, -lightDir), 0.0);
            lit = draw.color.rgb * (0.25 + 0.75 * lambert + backLight);
        }
        return vec4<f32>(lit * draw.color.a, draw.color.a);
    }

    // ---- Toon outline: inverted hull, drawn with front-face culling ----

    @vertex
    fn vs_outline(in: MeshIn) -> @builtin(position) vec4<f32> {
        let inflated = in.position + normalize(in.normal) * draw.params.z;
        return globals.viewProjection * draw.model * vec4<f32>(inflated, 1.0);
    }

    @fragment
    fn fs_outline() -> @location(0) vec4<f32> {
        return vec4<f32>(draw.color.rgb * draw.color.a, draw.color.a);
    }
    """
}
