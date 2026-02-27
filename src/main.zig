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

    camera_target: zm.Vec3f = .zero(),
    camera_pos: zm.Vec3f = .{ .data = .{ 1, 0, 0 } },

    matrix: zm.Mat4f = .identity(),
    projection: zm.Mat4f = .identity(),
    scaling: zm.Mat4f = .identity(),
    view: zm.Mat4f = .identity(),

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

        for (state.renderer.?.verts.?.items) |vert| {
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
        r.matrix = r.matrix.multiply(r.view);
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

    pub fn rotate(drw: Drawable, rot: zm.Vec3f, allocator: Allocator) !Drawable {
        var new_obj: Drawable = .{ .index_start = null, .verts = undefined, .indices = undefined };
        const rotation_mat: zm.Mat4f = .rotationRH(rot.norm(), deg2rad(rot.len()));
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
        const rotation_mat: zm.Mat4f = .rotationRH(rot.norm(), deg2rad(rot.len()));
        for (drw.verts) |*v| {
            const pos4 = zm.Vec4f{ .data = .{ v.position.data[0], v.position.data[1], v.position.data[2], 1.0 } };
            const rotated = rotation_mat.multiplyVec(pos4);
            v.position = zm.Vec3f{ .data = .{ rotated.data[0], rotated.data[1], rotated.data[2] } };
        }
    }

    pub fn move_to(drw: *Drawable, target: zm.Vec3f) void {
        for (drw.verts) |*vert| {
            vert.*.position = target;
        }
    }
    pub fn move_by(drw: *Drawable, target: zm.Vec3f) void {
        for (drw.verts) |*vert| {
            vert.*.position.addAssign(target);
        }
    }
};

const Vertex = struct {
    position: zm.Vec3f,
    color: zm.Vec3f,
};

var state: State = .{
    .renderer = null,
    .allocator = undefined,
    .window = null,
    .screen_w = Window_Width,
    .screen_h = Window_Height,
    .gl_ctx = null,
    .gl_procs = null,
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
fn sdlAppInit(appstate: ?*?*anyopaque, argv: [][*:0]u8) !c.SDL_AppResult {
    _ = appstate;
    _ = argv;

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
    state.renderer.?.view = .lookAtRH(state.renderer.?.camera_pos, state.renderer.?.camera_target, zm.Vec3f{ .data = .{ 0, 1, 0 } });

    //   var quad: Drawable = try .gen_quad(state.allocator);
    //   try state.renderer.?.queue(&quad);

    //    var quad_side: Drawable = try .rotate(quad, .{ .data = .{ 0, 45, 0 } }, state.renderer.?.allocator);
    //    try state.renderer.?.queue(&quad_side);

    var cube: Drawable = try .gen_cube(state.renderer.?.allocator);
    try state.renderer.?.queue(&cube);
    var cube_2: Drawable = try .gen_cube(state.renderer.?.allocator);
    cube_2.move_by(.{ .data = .{ 2, 1, 1 } });
    try state.renderer.?.queue(&cube_2);

    try state.renderer.?.flush();
    return c.SDL_APP_CONTINUE;
}

fn pre_draw() !void {
    try check_gl_error();
    gl.Enable(gl.DEPTH_TEST);
    gl.Disable(gl.CULL_FACE);
    gl.Viewport(0, 0, state.screen_w, state.screen_h);

    gl.ClearColor(0.1, 0.1, 0.1, 1);
    gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
}

fn sdlAppIterate(appstate: ?*anyopaque) !c.SDL_AppResult {
    _ = appstate;

    try pre_draw();
    if (state.renderer) |*renderer| {
        //for (state.renderer.?.drawables.?.items) |*drw| {
        //    try renderer.update(drw);
        //}
        try renderer.draw();
    }

    try errify(c.SDL_GL_SwapWindow(state.window.?));
    try check_gl_error();
    return c.SDL_APP_CONTINUE;
}

fn sdlAppEvent(appstate: ?*anyopaque, event: *c.SDL_Event) !c.SDL_AppResult {
    _ = appstate;

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

    if (event.type == c.SDL_EVENT_KEY_DOWN or event.type == c.SDL_EVENT_KEY_UP) {
        const keyboard = c.SDL_GetKeyboardState(null);

        var delta: zm.Vec3f = .zero();
        if (keyboard[c.SDL_SCANCODE_W]) {
            delta.addAssign(.{ .data = .{ 0, 0.1, 0 } });
        }
        if (keyboard[c.SDL_SCANCODE_S]) {
            delta.addAssign(.{ .data = .{ 0, -0.1, 0 } });
        }
        if (keyboard[c.SDL_SCANCODE_A]) {
            delta.addAssign(.{ .data = .{ -0.1, 0, 0 } });
        }
        if (keyboard[c.SDL_SCANCODE_D]) {
            delta.addAssign(.{ .data = .{ 0.1, 0, 0 } });
        }
        if (keyboard[c.SDL_SCANCODE_UP]) {
            delta.addAssign(.{ .data = .{ 0, 0, -0.1 } });
        }
        if (keyboard[c.SDL_SCANCODE_DOWN]) {
            delta.addAssign(.{ .data = .{ 0, 0, 0.1 } });
        }
        // if (keyboard[c.SDL_SCANCODE_LEFT]) {}
        //if (keyboard[c.SDL_SCANCODE_RIGHT]) {}

        state.renderer.?.camera_pos.addAssign(delta);
        state.renderer.?.camera_target = state.renderer.?.camera_pos.add(.{ .data = .{ 0, 0, -1 } });
        state.renderer.?.view = .lookAtRH(state.renderer.?.camera_pos, state.renderer.?.camera_target, zm.Vec3f{ .data = .{ 0, 1, 0 } });
    }
    return c.SDL_APP_CONTINUE;
}

fn sdlAppQuit(appstate: ?*anyopaque, result: anyerror!c.SDL_AppResult) void {
    sdl_log.warn("starting app quit\n", .{});
    _ = appstate;

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

    if (state.window != null)
        c.SDL_DestroyWindow(state.window.?);
    c.SDL_Quit();
    state = State{
        .renderer = undefined,
        .window = null,
        .screen_w = Window_Width,
        .screen_h = Window_Height,
        .gl_ctx = null,
        .gl_procs = null,
        .allocator = state.allocator,
    };
}

fn read_in_shader(alloc: Allocator, shader_path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(alloc, shader_path, std.math.maxInt(usize));
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) @panic("gpa leaked");
    const allocator = gpa.allocator();
    state.allocator = allocator;

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
    return sdlAppIterate(appstate) catch |err| app_err.store(err);
}

fn sdlAppEventC(appstate: ?*anyopaque, event: ?*c.SDL_Event) callconv(.c) c.SDL_AppResult {
    return sdlAppEvent(appstate, event.?) catch |err| app_err.store(err);
}

fn sdlAppQuitC(appstate: ?*anyopaque, result: c.SDL_AppResult) callconv(.c) void {
    sdlAppQuit(appstate, app_err.load() orelse result);
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
