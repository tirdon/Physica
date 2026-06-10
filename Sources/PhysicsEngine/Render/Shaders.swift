// WGSL shaders. One module, four entry-point pairs sharing the same bind layout:
// group 0 = per-frame globals, group 1 = per-draw uniforms (256-byte dynamic slots).

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

    // ---- Flat 2D (path stencil/cover/stroke) ----

    @vertex
    fn vs_flat(@location(0) position: vec3<f32>) -> @builtin(position) vec4<f32> {
        return globals.viewProjection * draw.model * vec4<f32>(position, 1.0);
    }

    @fragment
    fn fs_color() -> @location(0) vec4<f32> {
        // Premultiplied output for (one, one-minus-src-alpha) blending.
        return vec4<f32>(draw.color.rgb * draw.color.a, draw.color.a);
    }

    // ---- Lambert mesh ----

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
        let backLight = 0.15 * max(dot(n, -lightDir), 0.0);
        let lit = draw.color.rgb * (0.25 + 0.75 * lambert + backLight);
        return vec4<f32>(lit * draw.color.a, draw.color.a);
    }
    """
}
