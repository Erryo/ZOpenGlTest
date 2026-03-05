const std = @import("std");
const builtin = @import("builtin");
const gl = @import("gl");
const c = @cImport({
    @cDefine("SDL_DISABLE_OLD_NAMES", {});
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_revision.h");
    @cDefine("SDL_MAIN_HANDLED", {}); // We are providing our own entry point
    @cInclude("SDL3/SDL_main.h");
});
const zm = @import("zm");
const rand = std.crypto.random;

const target_triple: [:0]const u8 = x: {
    var buf: [256]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    break :x (builtin.target.zigTriple(fba.allocator()) catch unreachable) ++ "";
};

const Allocator = std.mem.Allocator;

const FAR = 100.0;
const NEAR = 0.1;

const Window_Width = 480;
const Window_Height = 480;

const sdl_log = std.log.scoped(.sdl);
const gl_log = std.log.scoped(.gl);

const Vertex_Shader_Path = "shaders/vertex_shader.glsl";
const Fragment_Shader_Path = "shaders/fragment_shader.glsl";

var gpa = std.heap.GeneralPurposeAllocator(.{}).init;

const deg2rad = std.math.degreesToRadians;
var Perspective_Mat_idx: usize = 0;

const VertexList = std.ArrayList(Vertex);
const DrawableList = std.ArrayList(Drawable);
const ByteList = std.ArrayList(u8);

const State = struct {
    window: ?*c.SDL_Window,
    screen_w: c_int,
    screen_h: c_int,

    allocator: std.mem.Allocator,
    renderer: ?Renderer,

    gl_ctx: c.SDL_GLContext,
    gl_procs: ?gl.ProcTable,

    const Config = struct {
        screen_w: c_int,
        screen_h: c_int,
        allocator: Allocator,
    };

    pub fn init(cfg: State.Config) !*State {
        const state: *State = try cfg.allocator.create(State);
        state.* = .{
            .renderer = null,
            .allocator = cfg.allocator,
            .window = null,
            .screen_w = cfg.screen_w,
            .screen_h = cfg.screen_h,
            .gl_ctx = null,
            .gl_procs = null,
        };
        return state;
    }
};

const RenderError = error{
    AlreadyFlushed,
};

const Renderer = struct {
    const self = @This();
    drawables: ?DrawableList = null,
    verts: ?VertexList = null,
    indices: ?ByteList = null,
    program: ?Program = null,

    cam: Camera = .{},
    matrix: zm.Mat4f = .identity(),
    projection: zm.Mat4f = .identity(),
    scaling: zm.Mat4f = .identity(),

    no_verts: u8 = 0,
    allocator: Allocator,
    flushed: bool = false,

    pub const Config = struct {
        allocator: Allocator,
        program: Program,
    };
    /// initialize all requiered values,rest null
    pub fn init(cfg: Config) !self {
        var renderer: Renderer = .{
            .allocator = cfg.allocator,
        };
        renderer.drawables = try DrawableList.initCapacity(renderer.allocator, 2);
        errdefer renderer.drawables.?.deinit(renderer.allocator);

        renderer.verts = try VertexList.initCapacity(renderer.allocator, 6);
        errdefer renderer.verts.?.deinit(renderer.allocator);

        renderer.indices = try ByteList.initCapacity(renderer.allocator, 12);
        errdefer renderer.indices.?.deinit(renderer.allocator);

        renderer.program = cfg.program;

        return renderer;
    }
    pub fn queue(r: *self, drw: *Drawable) !void {
        drw.index_start = r.no_verts;
        defer r.no_verts += @intCast(drw.verts.len);

        for (drw.indices) |*idx| {
            idx.* += r.no_verts;
        }

        try r.drawables.?.append(r.allocator, drw.*);
        try r.indices.?.appendSlice(r.allocator, drw.indices);
        try r.verts.?.appendSlice(r.allocator, drw.verts);
    }
    pub fn flush(r: *self) !void {
        if (r.flushed) return RenderError.AlreadyFlushed;

        for (r.verts.?.items) |vert| {
            gl_log.debug("verts:{any}\n", .{vert.position});
        }

        gl.BindVertexArray(r.program.?.vao.?);
        gl.BindBuffer(gl.ARRAY_BUFFER, r.program.?.vbo.?);
        gl.BufferData(gl.ARRAY_BUFFER, @intCast(r.verts.?.items.len * @sizeOf(Vertex)), @ptrCast(r.verts.?.items), gl.DYNAMIC_DRAW);

        gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, r.program.?.ibo.?);
        gl.BufferData(gl.ELEMENT_ARRAY_BUFFER, @intCast(r.indices.?.items.len * @sizeOf(u8)), @ptrCast(r.indices.?.items), gl.STATIC_DRAW);

        defer r.flushed = true;
    }

    pub fn update(r: *self, drw: *Drawable) !void {
        r.verts.?.replaceRangeAssumeCapacity(drw.index_start.?, drw.verts.len, drw.verts);
    }
    pub fn draw(r: *self) !void {
        try check_gl_error();
        gl.UseProgram(r.program.?.program.?);
        gl.BindVertexArray(r.program.?.vao.?);
        gl.BindBuffer(gl.ARRAY_BUFFER, r.program.?.vbo.?);
        gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, r.program.?.ibo.?);
        gl.BufferSubData(gl.ARRAY_BUFFER, 0, @intCast(r.verts.?.items.len * @sizeOf(Vertex)), @ptrCast(r.verts.?.items));

        r.matrix = r.matrix.multiply(r.projection);
        r.matrix = r.matrix.multiply(r.cam.view);
        r.matrix = r.matrix.multiply(r.scaling);

        const flat: [*]const [16]f32 =
            @ptrCast(&r.matrix.data);
        gl.UniformMatrix4fv(r.program.?.matrix_location.?, 1, gl.TRUE, flat);
        r.matrix = .identity();

        gl.DrawElements(gl.TRIANGLES, @intCast(r.indices.?.items.len), gl.UNSIGNED_BYTE, 0);
    }

    pub fn deinit(r: *self) !void {
        if (r.indices != null)
            r.indices.?.deinit(r.allocator);
        r.indices = null;
        if (r.verts != null)
            r.verts.?.deinit(r.allocator);

        if (r.drawables != null) {
            for (r.drawables.?.items) |drw| {
                r.allocator.free(drw.verts);
                r.allocator.free(drw.indices);
            }
            r.drawables.?.deinit(r.allocator);
        }
        r.drawables = null;
        r.verts = null;
        r.program = null;
        r.no_verts = 0;
        r.flushed = false;
    }
};

const Program = struct {
    program: ?c_uint = null,
    vao: ?c_uint = null,
    vbo: ?c_uint = null,
    ibo: ?c_uint = null,
    matrix_location: ?c_int = null,

    pub const Config = struct {
        vertex_src_path: []const u8,
        fragment_src_path: []const u8,
        program: ?c_uint = null,
    };

    pub fn init_program_only(allocator: Allocator, cfg: Config) !Program {
        var program = Program{};

        const vertex_glsl_src = try read_in_shader(allocator, cfg.vertex_src_path);
        defer allocator.free(vertex_glsl_src);
        const fragment_glsl_src = try read_in_shader(allocator, cfg.fragment_src_path);
        defer allocator.free(fragment_glsl_src);
        program.program = try create_graphics_pipeline(vertex_glsl_src, fragment_glsl_src);
    }

    pub fn init(allocator: Allocator, cfg: Config) !Program {
        var program = Program{};

        if (cfg.program) |prg| {
            program.program = prg;
        } else {
            const vertex_glsl_src = try read_in_shader(allocator, cfg.vertex_src_path);
            defer allocator.free(vertex_glsl_src);
            const fragment_glsl_src = try read_in_shader(allocator, cfg.fragment_src_path);
            defer allocator.free(fragment_glsl_src);
            program.program = try create_graphics_pipeline(vertex_glsl_src, fragment_glsl_src);
        }

        program.vao = undefined;
        gl.GenVertexArrays(1, @ptrCast((&program.vao.?)));
        gl.BindVertexArray(program.vao.?);
        defer gl.BindVertexArray(0);

        program.ibo = undefined;
        program.vbo = undefined;
        gl.GenBuffers(1, @ptrCast((&program.vbo.?)));
        gl.GenBuffers(1, @ptrCast((&program.ibo.?)));
        gl.BindBuffer(gl.ARRAY_BUFFER, program.vbo.?);
        try check_gl_error();

        program.matrix_location = gl.GetUniformLocation(program.program.?, "u_Matrix");

        {
            const attrib_location: c_uint = @intCast(gl.GetAttribLocation(program.program.?, "a_Position"));
            gl.EnableVertexAttribArray(attrib_location);
            gl.VertexAttribPointer(
                // zig fmt: off
                attrib_location,
                @typeInfo(@FieldType(zm.Vec3f, "data")).array.len,
                gl.FLOAT,
                gl.FALSE,
                @sizeOf(Vertex),
                @offsetOf(Vertex, "position"));
                // zig fmt: on
        }
        try check_gl_error(); // no error
        {
            const attrib_location: c_uint = @intCast(gl.GetAttribLocation(program.program.?, "a_Color"));
            gl.EnableVertexAttribArray(attrib_location);
            try check_gl_error(); // no error
            gl.VertexAttribPointer(
                // zig fmt: off
                attrib_location,
                @typeInfo(@FieldType(zm.Vec3f, "data")).array.len,
                gl.FLOAT,
                gl.FALSE,
                @sizeOf(Vertex),
                @offsetOf(Vertex, "color"));
                // zig fmt: on
        }

        try check_gl_error(); // error 1282
        return program;
    }
    pub fn deinit(p: *Program) !void {
        if (p.vao != null)
            gl.DeleteVertexArrays(1, (&p.vbo.?)[0..1]);
        p.vao = null;
        if (p.ibo != null)
            gl.DeleteBuffers(1, (&p.ibo.?)[0..1]);
        p.ibo = null;
        if (p.vbo != null)
            gl.DeleteBuffers(1, (&p.vbo.?)[0..1]);
        p.vbo = null;
        if (p.program != null)
            gl.DeleteProgram(p.program.?);
        p.program = null;
    }
};

const Camera = struct {
    from: zm.Vec3f = .zero(),
    to: zm.Vec3f = .zero(),
    forward: zm.Vec3f = .zero(),
    side: zm.Vec3f = .zero(),
    up: zm.Vec3f = .{ .data = .{ 0, 1, 0 } },
    // pitch, yaw, roll
    rotation: zm.Vec3f = .zero(),
    view: zm.Mat4f = .identity(),

    pub fn update(cam: *Camera, left_right_px: f32, up_down_px: f32) void {
        // should be inverted (dy,dx,0)
        const delta_rot: zm.Vec3f = .{ .data = .{ Camera.px2deg(-up_down_px), Camera.px2deg(left_right_px), 0 } };
        cam.rotation.addAssign(delta_rot);

        const pitch_limit = std.math.pi / 2.0 - 0.01;
        cam.rotation.data[0] = std.math.clamp(cam.rotation.data[0], -pitch_limit, pitch_limit);

        const pitch = cam.rotation.data[0];
        const yaw = cam.rotation.data[1];

        const cos_pitch = @cos(pitch);
        const sin_pitch = @sin(pitch);
        const cos_yaw = @cos(yaw);
        const sin_yaw = @sin(yaw);

        const forward: zm.Vec3f = .{
            .data = .{
                cos_pitch * sin_yaw, // X: strafe component
                sin_pitch, // Y: up/down component
                -cos_pitch * cos_yaw, // Z: negative because OpenGL looks down -Z
            },
        };

        // Calculate real target position
        const real_target: zm.Vec3f = cam.from.add(forward);

        cam.view = .lookAtRH(cam.from, real_target, cam.up);

        cam.to = real_target;
        cam.forward = real_target.sub(cam.from).norm();
        cam.side = cam.forward.crossRH(cam.up).norm();
    }
    pub fn move(cam: *Camera, deltas: zm.Vec3f) void {
        var delta_pos: zm.Vec3f = .zero();
        delta_pos.addAssign(cam.forward.scale(deltas.data[2]));
        delta_pos.addAssign(cam.up.scale(deltas.data[1]));
        delta_pos.addAssign(cam.side.scale(deltas.data[0]));

        cam.from.addAssign(delta_pos);
        cam.update(0, 0);
    }

    pub fn px2deg(delta: f32) f32 {
        return delta * 0.005;
    }
};

const Drawable = struct {
    verts: []Vertex,
    indices: []u8,
    index_start: ?usize,

    pub fn gen_quad(allocator: Allocator) !Drawable {
        var drw: Drawable = undefined;
        const vertices = [_]Vertex{
            Vertex{ .position = .{ .data = .{ -1, 1, 1 } }, .color = .{ .data = .{ 1, 0, 0 } } },
            Vertex{ .position = .{ .data = .{ -1, -1, 1 } }, .color = .{ .data = .{ 1, 1, 0 } } },
            Vertex{ .position = .{ .data = .{ 1, -1, 1 } }, .color = .{ .data = .{ 0, 1, 0 } } },
            Vertex{ .position = .{ .data = .{ 1, 1, 1 } }, .color = .{ .data = .{ 0, 0, 1 } } },
        };

        const indices = [_]u8{ 0, 1, 2, 0, 2, 3 };

        drw.verts = try allocator.dupe(Vertex, &vertices);
        drw.indices = try allocator.dupe(u8, &indices);
        drw.index_start = null;
        return drw;
    }

    pub fn gen_pyramid(allocator: Allocator, side_len: f32, height: f32, no_sides: u8) !Drawable {
        var body: Drawable = undefined;
        var verts = try VertexList.initCapacity(allocator, no_sides + 1);
        var indices = try ByteList.initCapacity(allocator, (no_sides + 1) * 2);

        const top_face: Drawable = try .gen_polygon(allocator, side_len, no_sides);
        defer allocator.free(top_face.verts);
        defer allocator.free(top_face.indices);

        try verts.appendSlice(allocator, top_face.verts);
        try indices.appendSlice(allocator, top_face.indices);

        try verts.append(allocator, Vertex{
            .color = .{ .data = .{ 1, 0, 0 } },
            .position = .{ .data = .{ 0, 0, height } },
        });
        const point_idx: u8 = @as(u8, @intCast(verts.items.len)) - 1;

        var current_idx: u8 = 1;
        while (current_idx + 1 < top_face.verts.len) : (current_idx += 1) {
            const idcs: [3]u8 = .{ point_idx, current_idx, current_idx + 1 };
            try indices.appendSlice(allocator, &idcs);
        }

        body.verts = try verts.toOwnedSlice(allocator);
        body.indices = try indices.toOwnedSlice(allocator);
        body.index_start = null;
        return body;
    }

    pub fn gen_body(allocator: Allocator, side_len: f32, height: f32, no_sides: u8) !Drawable {
        var body: Drawable = undefined;
        var verts = try VertexList.initCapacity(allocator, no_sides + 1);
        var indices = try ByteList.initCapacity(allocator, (no_sides + 1) * 2);

        const top_face: Drawable = try .gen_polygon(allocator, side_len, no_sides);
        defer allocator.free(top_face.verts);
        defer allocator.free(top_face.indices);
        var bottom_face: Drawable = try .gen_polygon(allocator, side_len, no_sides);
        defer allocator.free(bottom_face.verts);
        defer allocator.free(bottom_face.indices);
        bottom_face.move_by(.{ .data = .{ 0, 0, -height } });

        const offset: u8 = @intCast(top_face.verts.len);
        for (bottom_face.indices) |*idx| {
            idx.* += offset;
        }
        for (bottom_face.verts) |*v| {
            v.color = .{ .data = .{ 1, 0, 0 } };
        }

        try verts.appendSlice(allocator, top_face.verts);
        try indices.appendSlice(allocator, top_face.indices);

        try verts.appendSlice(allocator, bottom_face.verts);
        try indices.appendSlice(allocator, bottom_face.indices);

        var current_idx: u8 = 1;
        while (current_idx + 1 < top_face.verts.len) : (current_idx += 1) {
            const idcs: [3]u8 = .{ current_idx, current_idx + offset, current_idx + offset + 1 };
            try indices.appendSlice(allocator, &idcs);
            const idcs_2: [3]u8 = .{ current_idx, current_idx + offset + 1, current_idx + 1 };
            try indices.appendSlice(allocator, &idcs_2);
        }

        body.verts = try verts.toOwnedSlice(allocator);
        body.indices = try indices.toOwnedSlice(allocator);
        body.index_start = null;
        return body;
    }

    pub fn gen_polygon(allocator: Allocator, side_len: f32, no_sides: u8) !Drawable {
        var drw: Drawable = undefined;
        var verts = try VertexList.initCapacity(allocator, no_sides + 1);
        var indices = try ByteList.initCapacity(allocator, (no_sides + 1) * 2);

        const origin: Vertex = .{
            .color = .{ .data = .{ 0, 1, 0 } },
            .position = .{ .data = .{ 0, 0, 0 } },
        };
        try verts.append(allocator, origin);

        const angle: f32 = 360.0 / @as(f32, @floatFromInt(no_sides));
        for (0..no_sides + 1) |idx| {
            const current_angle: f32 = angle * @as(f32, @floatFromInt(idx));
            const dx = @cos(deg2rad(current_angle)) * side_len;
            const dy = @sin(deg2rad(current_angle)) * side_len;
            const vert: Vertex = .{
                .color = .{ .data = .{ 0, 1, 0 } },
                .position = .{ .data = .{ dx, dy, 0 } },
            };
            try verts.append(allocator, vert);
        }

        var current_idx: u8 = 1;
        while (current_idx + 1 < verts.items.len) : (current_idx += 1) {
            const idcs: [3]u8 = .{ 0, current_idx, current_idx + 1 };
            try indices.appendSlice(allocator, &idcs);
        }
        drw.verts = try verts.toOwnedSlice(allocator);
        defer verts.deinit(allocator);
        drw.indices = try indices.toOwnedSlice(allocator);
        defer indices.deinit(allocator);

        drw.index_start = null;
        return drw;
    }

    pub fn gen_cube(allocator: Allocator) !Drawable {
        var drw: Drawable = undefined;
        const vertices = [_]Vertex{
            Vertex{ .position = .{ .data = .{ -1, 1, 1 } }, .color = .{ .data = .{ 1, 0, 0 } } }, // V0
            Vertex{ .position = .{ .data = .{ -1, -1, 1 } }, .color = .{ .data = .{ 1, 1, 0 } } }, // V1
            Vertex{ .position = .{ .data = .{ 1, -1, 1 } }, .color = .{ .data = .{ 0, 1, 0 } } }, // V2
            Vertex{ .position = .{ .data = .{ 1, 1, 1 } }, .color = .{ .data = .{ 0, 0, 1 } } }, // V3
            //
            Vertex{ .position = .{ .data = .{ -1, 1, -1 } }, .color = .{ .data = .{ 1, 0, 0 } } }, // V4
            Vertex{ .position = .{ .data = .{ -1, -1, -1 } }, .color = .{ .data = .{ 1, 1, 0 } } }, // V5
            Vertex{ .position = .{ .data = .{ 1, -1, -1 } }, .color = .{ .data = .{ 0, 1, 0 } } }, // V6
            Vertex{ .position = .{ .data = .{ 1, 1, -1 } }, .color = .{ .data = .{ 0, 0, 1 } } }, // V7
        };

        const indices = [_]u8{
            // Front Face
            0, 1, 2,
            0, 2, 3,
            // Right Face
            3, 2, 6,
            3, 6, 7,
            // Left Face
            0, 1, 5,
            0, 5, 4,
            // Back Face
            4, 5, 6,
            4, 6, 7,
            // Down Face
            5, 1, 2,
            5, 2, 6,
            // Up Face
            4, 0, 3,
            4, 3, 7,
        };

        drw.verts = try allocator.dupe(Vertex, &vertices);
        drw.indices = try allocator.dupe(u8, &indices);
        drw.index_start = null;
        return drw;
    }

    fn rotation_from_euler_degrees(rot: zm.Vec3f) zm.Mat4f {
        const x_axis: zm.Vec3f = .{ .data = .{ 1, 0, 0 } };
        const y_axis: zm.Vec3f = .{ .data = .{ 0, 1, 0 } };
        const z_axis: zm.Vec3f = .{ .data = .{ 0, 0, 1 } };

        const x_rot: zm.Mat4f = rotation_rh(x_axis, deg2rad(rot.data[0]));
        const y_rot: zm.Mat4f = rotation_rh(y_axis, deg2rad(rot.data[1]));
        const z_rot: zm.Mat4f = rotation_rh(z_axis, deg2rad(rot.data[2]));

        return z_rot.multiply(y_rot).multiply(x_rot);
    }

    pub fn rotate(drw: Drawable, rot: zm.Vec3f, allocator: Allocator) !Drawable {
        var new_obj: Drawable = .{ .index_start = null, .verts = undefined, .indices = undefined };
        const rotation_mat = rotation_from_euler_degrees(rot);
        new_obj.verts = try allocator.dupe(Vertex, drw.verts);
        new_obj.indices = try allocator.dupe(u8, drw.indices);
        for (new_obj.verts) |*v| {
            const pos4 = zm.Vec4f{ .data = .{ v.position.data[0], v.position.data[1], v.position.data[2], 1.0 } };
            const rotated = rotation_mat.multiplyVec(pos4);
            v.position = zm.Vec3f{ .data = .{ rotated.data[0], rotated.data[1], rotated.data[2] } };
        }
        return new_obj;
    }

    pub fn rotate_assign(drw: *Drawable, rot: zm.Vec3f) void {
        const rotation_mat = rotation_from_euler_degrees(rot);
        for (drw.verts) |*v| {
            const pos4 = zm.Vec4f{ .data = .{ v.position.data[0], v.position.data[1], v.position.data[2], 1.0 } };
            const rotated = rotation_mat.multiplyVec(pos4);
            v.position = zm.Vec3f{ .data = .{ rotated.data[0], rotated.data[1], rotated.data[2] } };
        }
    }

    pub fn scale_assign(drw: *Drawable, scaler: f32) void {
        for (drw.verts) |*vert| {
            vert.*.position.scaleAssign(scaler);
        }
    }

    pub fn set_color(drw: *Drawable, color: zm.Vec3f) void {
        for (drw.verts) |*vert| {
            vert.color = color;
        }
    }

    pub fn move_to(drw: *Drawable, axis: zm.Vec3f) void {
        for (drw.verts) |*vert| {
            if (axis.data[0] != std.math.inf(f32))
                vert.*.position.data[0] = axis.data[0];
            if (axis.data[1] != std.math.inf(f32))
                vert.*.position.data[1] = axis.data[1];
            if (axis.data[2] != std.math.inf(f32))
                vert.*.position.data[2] = axis.data[2];
        }
    }
    pub fn move_by(drw: *Drawable, target: zm.Vec3f) void {
        for (drw.verts) |*vert| {
            vert.*.position.addAssign(target);
        }
    }
};

fn rotation_rh(axis: zm.Vec3f, angle_rads: f32) zm.Mat4f {
    const normalized = axis.norm();
    const x = normalized.data[0];
    const y = normalized.data[1];
    const z = normalized.data[2];

    const cos_rads = std.math.cos(angle_rads);
    const s = std.math.sin(angle_rads);
    const omc = 1.0 - cos_rads;

    return zm.Mat4f{
        .data = .{
            .{ x * x * omc + cos_rads, x * y * omc - z * s, x * z * omc + y * s, 0 },
            .{ y * x * omc + z * s, y * y * omc + cos_rads, y * z * omc - x * s, 0 },
            .{ z * x * omc - y * s, z * y * omc + x * s, z * z * omc + cos_rads, 0 },
            .{ 0, 0, 0, 1 },
        },
    };
}

const Vertex = struct {
    position: zm.Vec3f,
    color: zm.Vec3f,
};

fn create_graphics_pipeline(vertex_shader_src: []const u8, fragment_shader_src: []const u8) !c_uint {
    const program = gl.CreateProgram();
    if (program == 0) return error.GlProgramFailed;

    const vertex_shader = compile_shader(gl.VERTEX_SHADER, vertex_shader_src);

    const fragment_shader = compile_shader(gl.FRAGMENT_SHADER, fragment_shader_src);
    if (vertex_shader == 0) return error.GlCreateVertexShaderFailed;
    if (fragment_shader == 0) return error.GlCreateFragmentShaderFailed;

    gl.AttachShader(program, vertex_shader);
    gl.AttachShader(program, fragment_shader);
    gl.LinkProgram(program);
    gl.ValidateProgram(program);

    gl.DetachShader(program, vertex_shader);
    gl.DeleteShader(vertex_shader);
    gl.DetachShader(program, fragment_shader);
    gl.DeleteShader(fragment_shader);
    return program;
}

fn compile_shader(shader_type: comptime_int, shader_source: []const u8) c_uint {
    var shader_obj: c_uint = undefined;

    if (shader_type == gl.VERTEX_SHADER) {
        shader_obj = gl.CreateShader(gl.VERTEX_SHADER);
    } else if (shader_type == gl.FRAGMENT_SHADER) {
        shader_obj = gl.CreateShader(gl.FRAGMENT_SHADER);
    }

    std.debug.print("shader_len:{d}\n", .{shader_source.len});
    gl.ShaderSource(shader_obj, 1, &.{shader_source.ptr}, &[1]c_int{@intCast(shader_source.len)});
    gl.CompileShader(shader_obj);

    var success: c_int = 0;
    gl.GetShaderiv(shader_obj, gl.COMPILE_STATUS, (&success)[0..1]);
    if (success == 0) {
        var log: [512]u8 = undefined;
        var len: c_int = 0;
        gl.GetShaderInfoLog(shader_obj, log.len, &len, &log);
        std.debug.print("Shader error:\n{s}\n", .{log[0..@intCast(len)]});
    }
    return shader_obj;
}
fn sdlAppInit(appstate: *?*anyopaque, argv: [][*:0]u8) !c.SDL_AppResult {
    _ = argv;

    const allocator = gpa.allocator();

    appstate.* = try State.init(.{ .screen_w = Window_Width, .screen_h = Window_Height, .allocator = allocator });
    const state: *State = cptr(*State, appstate.*.?);

    std.log.debug("{s} {s}", .{ target_triple, @tagName(builtin.mode) });
    const platform: [*:0]const u8 = c.SDL_GetPlatform();
    sdl_log.debug("SDL platform: {s}", .{platform});
    sdl_log.debug("SDL build time version: {d}.{d}.{d}", .{
        c.SDL_MAJOR_VERSION,
        c.SDL_MINOR_VERSION,
        c.SDL_MICRO_VERSION,
    });

    sdl_log.debug("SDL build time revision: {s}", .{c.SDL_REVISION});
    {
        const version = c.SDL_GetVersion();
        sdl_log.debug("SDL runtime version: {d}.{d}.{d}", .{
            c.SDL_VERSIONNUM_MAJOR(version),
            c.SDL_VERSIONNUM_MINOR(version),
            c.SDL_VERSIONNUM_MICRO(version),
        });
        const revision: [*:0]const u8 = c.SDL_GetRevision();
        sdl_log.debug("SDL runtime revision: {s}", .{revision});
    }

    try errify(c.SDL_SetAppMetadata("OpenGL Test", "0.0.0", "test.zig-phys.test"));
    try errify(c.SDL_Init(c.SDL_INIT_VIDEO));

    try errify(c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MAJOR_VERSION, 4));
    try errify(c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MINOR_VERSION, 1));

    try errify(c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_PROFILE_MASK, c.SDL_GL_CONTEXT_PROFILE_CORE));
    try errify(c.SDL_GL_SetAttribute(c.SDL_GL_DOUBLEBUFFER, 1));
    try errify(c.SDL_GL_SetAttribute(c.SDL_GL_DEPTH_SIZE, 24));

    state.window = try errify(c.SDL_CreateWindow("Test", Window_Width, Window_Height, c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_OPENGL));

    state.gl_ctx = try errify(c.SDL_GL_CreateContext(state.window));
    try errify(c.SDL_GL_MakeCurrent(state.window, state.gl_ctx));

    state.gl_procs = undefined;
    if (!state.gl_procs.?.init(&c.SDL_GL_GetProcAddress)) {
        state.gl_procs = null;
        return error.GlInitFailed;
    }

    gl.makeProcTableCurrent(&state.gl_procs.?);

    gl_log.info("Vendor:{s}", .{gl.GetString(gl.VENDOR) orelse "null"});
    gl_log.info("Renderer:{s}", .{gl.GetString(gl.RENDERER) orelse "null"});
    gl_log.info("Version:{s}", .{gl.GetString(gl.VERSION) orelse "null"});
    gl_log.info("Shading language:{s}", .{gl.GetString(gl.SHADING_LANGUAGE_VERSION) orelse "null"});

    const program: Program = try .init(state.allocator, Program.Config{
        // zig fmt: off
        .fragment_src_path = Fragment_Shader_Path,
        .vertex_src_path = Vertex_Shader_Path }
        // zig fmt: on
    );

    state.renderer = try Renderer.init(.{ .allocator = state.allocator, .program = program });

    state.renderer.?.projection = .perspectiveRH(std.math.degreesToRadians(45.0), 16.0 / 9.0, NEAR, FAR);
    state.renderer.?.scaling = .scale(state.renderer.?.scaling, 1);
    state.renderer.?.cam.update(0, 0);

    var quad: Drawable = try .gen_quad(allocator);
    try state.renderer.?.queue(&quad);

    // var cube: Drawable = try .gen_cube(state.renderer.?.allocator);
    // try state.renderer.?.queue(&cube);
    // var cube_2: Drawable = try .gen_cube(state.renderer.?.allocator);
    // cube_2.move_by(.{ .data = .{ 2, 2, 1 } });
    // try state.renderer.?.queue(&cube_2);
    //
    var plane = try Drawable.gen_quad(allocator);
    plane.rotate_assign(.{ .data = .{ 90, 0, 0 } });
    plane.scale_assign(3);
    plane.move_to(.{ .data = .{ std.math.inf(f32), 0, std.math.inf(f32) } });
    plane.set_color(.{ .data = .{ 0.53, 0.53, 0.53 } });
    try state.renderer.?.queue(&plane);

    //    var pyramid = try Drawable.gen_pyramid(allocator, 1, 2, 12);
    //    pyramid.scale_assign(0.2);
    //
    //    try state.renderer.?.queue(&pyramid);
    //    var cylinder: Drawable = try .gen_body(allocator, 1, 3, 20);
    //    try state.renderer.?.queue(&cylinder);
    //
    //    var cube: Drawable = try .gen_body(allocator, 1, 2, 4);
    //    cube.move_by(.{ .data = .{ 3, 0, 1 } });
    //    try state.renderer.?.queue(&cube);
    //    // var poly_12: Drawable = try Drawable.gen_polygon(state.renderer.?.allocator, 1, 12);
    // try state.renderer.?.queue(&poly_12);

    // var poly_4: Drawable = try Drawable.gen_polygon(state.renderer.?.allocator, 1, 4);
    // poly_4.move_by(.{ .data = .{ 2, 2, 1 } });
    // try state.renderer.?.queue(&poly_4);

    try state.renderer.?.flush();
    try errify(c.SDL_SetWindowRelativeMouseMode(state.window, true));
    return c.SDL_APP_CONTINUE;
}

fn pre_draw(state: *State) !void {
    try check_gl_error();
    gl.Enable(gl.DEPTH_TEST);
    gl.Disable(gl.CULL_FACE);
    gl.Viewport(0, 0, state.screen_w, state.screen_h);

    gl.ClearColor(0.1, 0.1, 0.1, 1);
    gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
}

fn sdlAppIterate(state: *State) !c.SDL_AppResult {
    try pre_draw(state);
    if (state.renderer) |*renderer| {
        for (state.renderer.?.drawables.?.items) |*drw| {
            try renderer.update(drw);
        }
        try renderer.draw();
    }

    try errify(c.SDL_GL_SwapWindow(state.window.?));
    try check_gl_error();
    return c.SDL_APP_CONTINUE;
}

fn sdlAppEvent(state: *State, event: *c.SDL_Event) !c.SDL_AppResult {
    // std.debug.print("clearing...\x1b[2J \n", .{});

    if (event.type == c.SDL_EVENT_QUIT) {
        return c.SDL_APP_SUCCESS;
    }

    if (event.type == c.SDL_EVENT_WINDOW_RESIZED) {
        _ = c.SDL_GetWindowSize(state.window, &state.screen_w, &state.screen_h);
        const aspect: f32 = @as(f32, @floatFromInt(state.screen_w)) / @as(f32, @floatFromInt(state.screen_h));
        const perspective: zm.Mat4f = .perspectiveRH(std.math.degreesToRadians(45.0), aspect, NEAR, FAR);
        state.renderer.?.projection = perspective;
        sdl_log.debug(":window resized{d};{d}\n", .{ state.screen_w, state.screen_h });
    }

    if (event.type == c.SDL_EVENT_MOUSE_MOTION) {
        var m_x: f32 = undefined;
        var m_y: f32 = undefined;
        _ = c.SDL_GetRelativeMouseState(&m_x, &m_y);

        state.renderer.?.cam.update(m_x, m_y);
        std.debug.print("rotation:{any}\n", .{state.renderer.?.cam.rotation});
        std.debug.print("cam.to:{any}\n", .{state.renderer.?.cam.to});
    }

    if (event.type == c.SDL_EVENT_KEY_DOWN or event.type == c.SDL_EVENT_KEY_UP) {
        const keyboard = c.SDL_GetKeyboardState(null);

        var delta: zm.Vec3f = .zero();
        if (keyboard[c.SDL_SCANCODE_W]) {
            delta.addAssign(.{ .data = .{ 0, 0, 0.1 } });
        }
        if (keyboard[c.SDL_SCANCODE_S]) {
            delta.addAssign(.{ .data = .{ 0, 0, -0.1 } });
        }
        if (keyboard[c.SDL_SCANCODE_A]) {
            delta.addAssign(.{ .data = .{ -0.1, 0, 0 } });
        }
        if (keyboard[c.SDL_SCANCODE_D]) {
            delta.addAssign(.{ .data = .{ 0.1, 0, 0 } });
        }
        if (keyboard[c.SDL_SCANCODE_UP]) {
            delta.addAssign(.{ .data = .{ 0, 0.1, 0 } });
        }
        if (keyboard[c.SDL_SCANCODE_DOWN]) {
            delta.addAssign(.{ .data = .{ 0, -0.1, 0 } });
        }
        if (keyboard[c.SDL_SCANCODE_LEFT]) {
            state.renderer.?.cam.update(-10, 0);
        }
        if (keyboard[c.SDL_SCANCODE_RIGHT]) {
            state.renderer.?.cam.update(10, 0);
        }

        state.renderer.?.cam.move(delta);
        std.debug.print("position:{any}\n", .{state.renderer.?.cam.from});
    }
    return c.SDL_APP_CONTINUE;
}

fn sdlAppQuit(state: *State, result: anyerror!c.SDL_AppResult) void {
    sdl_log.warn("starting app quit\n", .{});

    _ = result catch |err| if (err == error.SdlError) {
        sdl_log.err("{s}\n", .{c.SDL_GetError()});
    };

    check_gl_error() catch |err| {
        gl_log.err("error code while qutting{any}\n", .{@errorName(err)});
    };

    if (state.renderer != null) {
        if (state.renderer.?.program != null)
            try state.renderer.?.program.?.deinit();
        try state.renderer.?.deinit();
    }
    if (state.gl_procs != null)
        gl.makeProcTableCurrent(null);
    if (state.gl_ctx != null)
        errify(c.SDL_GL_MakeCurrent(state.window.?, null)) catch {};
    if (state.gl_ctx != null)
        errify(c.SDL_GL_DestroyContext(state.gl_ctx.?)) catch {
            gl_log.err("failed to destory context\n", .{});
        };

    if (state.window != null)
        c.SDL_DestroyWindow(state.window.?);

    c.SDL_Quit();

    state.allocator.destroy(state);
}

fn read_in_shader(alloc: Allocator, shader_path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(alloc, shader_path, std.math.maxInt(usize));
}

pub fn main() !u8 {
    defer if (gpa.deinit() == .leak) @panic("GeneralPurposeAllocator leaked");

    app_err.reset();
    var empty_argv: [0:null]?[*:0]u8 = .{};
    const status: u8 = @truncate(@as(c_uint, @bitCast(c.SDL_RunApp(empty_argv.len, @ptrCast(&empty_argv), sdlMainC, null))));
    return app_err.load() orelse status;
}
fn sdlMainC(argc: c_int, argv: ?[*:null]?[*:0]u8) callconv(.c) c_int {
    return c.SDL_EnterAppMainCallbacks(argc, @ptrCast(argv), sdlAppInitC, sdlAppIterateC, sdlAppEventC, sdlAppQuitC);
}

fn sdlAppInitC(appstate: ?*?*anyopaque, argc: c_int, argv: ?[*:null]?[*:0]u8) callconv(.c) c.SDL_AppResult {
    return sdlAppInit(appstate.?, @ptrCast(argv.?[0..@intCast(argc)])) catch |err| app_err.store(err);
}

fn sdlAppIterateC(appstate: ?*anyopaque) callconv(.c) c.SDL_AppResult {
    const state: *State = cptr(*State, appstate.?);
    return sdlAppIterate(state) catch |err| app_err.store(err);
}

fn sdlAppEventC(appstate: ?*anyopaque, event: ?*c.SDL_Event) callconv(.c) c.SDL_AppResult {
    const state: *State = cptr(*State, appstate.?);
    return sdlAppEvent(state, event.?) catch |err| app_err.store(err);
}

fn sdlAppQuitC(appstate: ?*anyopaque, result: c.SDL_AppResult) callconv(.c) void {
    const state: *State = cptr(*State, appstate.?);
    sdlAppQuit(state, app_err.load() orelse result);
}

inline fn c_errify(value: c_int) !void {
    if (value < 0) return error.CError;
}

/// Converts the return value of an SDL function to an error union.
inline fn errify(value: anytype) error{SdlError}!switch (@typeInfo(@TypeOf(value))) {
    .bool => void,
    .pointer, .optional => @TypeOf(value.?),
    .int => |info| switch (info.signedness) {
        .signed => @TypeOf(@max(0, value)),
        .unsigned => @TypeOf(value),
    },
    else => @compileError("unerrifiable type: " ++ @typeName(@TypeOf(value))),
} {
    return switch (@typeInfo(@TypeOf(value))) {
        .bool => if (!value) error.SdlError,
        .pointer, .optional => value orelse error.SdlError,
        .int => |info| switch (info.signedness) {
            .signed => if (value >= 0) @max(0, value) else error.SdlError,
            .unsigned => if (value != 0) value else error.SdlError,
        },
        else => comptime unreachable,
    };
}

var app_err: ErrorStore = .{};

fn check_gl_error() !void {
    var errored: bool = false;
    while (true) {
        const err = gl.GetError();

        if (err == gl.NO_ERROR) break;
        errored = true;
        std.debug.print("err:{d}\n", .{err});
    }
    return if (errored) error.GlError else {};
}

const ErrorStore = struct {
    const status_not_stored = 0;
    const status_storing = 1;
    const status_stored = 2;

    status: c.SDL_AtomicInt = .{},
    err: anyerror = undefined,
    trace_index: usize = undefined,
    trace_addrs: [32]usize = undefined,

    fn reset(es: *ErrorStore) void {
        _ = c.SDL_SetAtomicInt(&es.status, status_not_stored);
    }

    fn store(es: *ErrorStore, err: anyerror) c.SDL_AppResult {
        if (c.SDL_CompareAndSwapAtomicInt(&es.status, status_not_stored, status_storing)) {
            es.err = err;
            if (@errorReturnTrace()) |src_trace| {
                es.trace_index = src_trace.index;
                const len = @min(es.trace_addrs.len, src_trace.instruction_addresses.len);
                @memcpy(es.trace_addrs[0..len], src_trace.instruction_addresses[0..len]);
            }
            _ = c.SDL_SetAtomicInt(&es.status, status_stored);
        }
        return c.SDL_APP_FAILURE;
    }

    fn load(es: *ErrorStore) ?anyerror {
        if (c.SDL_GetAtomicInt(&es.status) != status_stored) return null;
        if (@errorReturnTrace()) |dst_trace| {
            dst_trace.index = es.trace_index;
            const len = @min(dst_trace.instruction_addresses.len, es.trace_addrs.len);
            @memcpy(dst_trace.instruction_addresses[0..len], es.trace_addrs[0..len]);
        }
        return es.err;
    }
};

fn cptr(comptime T: type, data: ?*anyopaque) T {
    return @ptrCast(@alignCast(data));
}
