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

const target_triple: [:0]const u8 = x: {
    var buf: [256]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    break :x (builtin.target.zigTriple(fba.allocator()) catch unreachable) ++ "";
};
const Saturation = 0.6;
const Luminance = 0.5;

const Window_Width = 720;
const Window_Height = 480;

const sdl_log = std.log.scoped(.sdl);
const gl_log = std.log.scoped(.gl);

const Vertex_Shader_Path = "shaders/vertex_shader.glsl";
const Fragment_Shader_Path = "shaders/fragment_shader.glsl";

const MeshList = std.ArrayList(Mesh);
const VertexList = std.ArrayList(Vertex);

const State = struct {
    window: ?*c.SDL_Window,
    screen_w: c_int,
    screen_h: c_int,

    allocator: std.mem.Allocator,

    gl_ctx: c.SDL_GLContext,
    gl_procs: ?gl.ProcTable,

    meshes: ?[]Mesh,
    vertices: ?[]Vertex,

    vao: ?c_uint, // alignment of the vertecies in vbo
    vbo_vert: ?c_uint, // vertices
    vbo_mesh: ?c_uint, // mesh
    ibo: ?c_uint, // indexes. Maps indices to vertices, to enable reusing vertex data.
    program: ?c_uint,
    vertex_shader_source: ?[]u8,
    fragment_shader_source: ?[]u8,
};

const Mesh = struct {
    origin: [3]f32,
    angle: f32,
};

const Vertex = extern struct {
    position: [3]f32,
    color: [3]f32,
};

var state: State = .{
    .window = null,
    .screen_w = Window_Width,
    .screen_h = Window_Height,
    .gl_ctx = null,
    .gl_procs = null,
    .vbo_mesh = null,
    .vbo_vert = null,
    .ibo = null,
    .vao = null,
    .program = null,
    .vertices = null,
    .meshes = null,
    .allocator = undefined,
    .fragment_shader_source = null,
    .vertex_shader_source = null,
};

fn vertex_specification() !void {
    const vertices: [3]Vertex = .{
        .{
            .position = .{ -0.5, -0.5, 0 },
            .color = .{ 1, 0, 0 },
        },
        .{
            .position = .{ 0.5, -0.5, 0 },
            .color = .{ 0, 0, 1 },
        },
        .{
            .position = .{ 0, 0.5, 0 },
            .color = .{ 0, 1, 0 },
        },
    };

    const meshes: [1]Mesh = .{
        Mesh{ .angle = 0, .origin = .{ 0, 0, 0 } },
    };

    var meshes_list = try MeshList.initCapacity(state.allocator, 1);
    var vertices_list = try VertexList.initCapacity(state.allocator, 3);

    try vertices_list.appendSlice(state.allocator, vertices[0..]);
    try meshes_list.appendSlice(state.allocator, meshes[0..]);

    state.meshes = try meshes_list.toOwnedSlice(state.allocator);
    state.vertices = try vertices_list.toOwnedSlice(state.allocator);

    vertices_list.deinit(state.allocator);
    meshes_list.deinit(state.allocator);

    state.vao = undefined;
    gl.GenVertexArrays(1, (&state.vao.?)[0..1]);
    gl.BindVertexArray(state.vao.?);
    defer gl.BindVertexArray(0);

    state.vbo_vert = undefined;
    gl.GenBuffers(1, (&state.vbo_vert.?)[0..1]);
    state.vbo_mesh = undefined;
    gl.GenBuffers(1, (&state.vbo_mesh.?)[0..1]);

    try check_gl_error();

    gl.BindBuffer(gl.ARRAY_BUFFER, state.vbo_vert.?);
    defer gl.BindBuffer(gl.ARRAY_BUFFER, 0);

    std.debug.print("len:{d} ; fancy:{d}\n", .{ state.vertices.?.len, @sizeOf(@TypeOf(state.vertices.?)) }); // prints 3 and 16
    gl.BufferData(gl.ARRAY_BUFFER, @sizeOf(@TypeOf(state.vertices.?)), @ptrCast(state.vertices.?), gl.STATIC_DRAW);
    try check_gl_error();

    {
        const position_attrib = gl.GetAttribLocation(state.program.?, "a_Position");
        if (position_attrib == -1) return error.GlPositionAttribInvalid;
        gl.EnableVertexAttribArray(@intCast(position_attrib));

        // zig fmt: off
        gl.VertexAttribPointer(
            @intCast(position_attrib),
            @typeInfo(@FieldType(Vertex, "position")).array.len,
            gl.FLOAT,
            gl.FALSE,
            @sizeOf(Vertex),
            @offsetOf(Vertex, "position"),
            );
        // zig fmt: on
    }

    {
        const color_attrib = gl.GetAttribLocation(state.program.?, "a_Color");
        if (color_attrib == -1) return error.GlColorAttribInvalid;

        gl.EnableVertexAttribArray(@intCast(color_attrib));
        // zig fmt: off
        gl.VertexAttribPointer(
            @intCast(color_attrib),
            @typeInfo(@FieldType(Vertex, "color")).array.len,
            gl.FLOAT,
            gl.FALSE,
            @sizeOf(Vertex),
            @offsetOf(Vertex, "color"),
            );
        // zig fmt: on
    }

    //    gl.BindBuffer(gl.ARRAY_BUFFER, state.vbo_mesh.?);
    //    gl.BufferData(gl.ARRAY_BUFFER, @sizeOf(@TypeOf(state.meshes.?)), @ptrCast(state.meshes.?), gl.STATIC_DRAW);
    //    try check_gl_error();
    //    {
    //        const origin_attrib = gl.GetAttribLocation(state.program.?, "a_Origin");
    //        if (origin_attrib == -1) return error.GlColorAttribInvalid;
    //        gl.EnableVertexAttribArray(@intCast(origin_attrib));
    //        // zig fmt: off
    //        gl.VertexAttribPointer(
    //            @intCast(origin_attrib),
    //            @typeInfo(@FieldType(Mesh, "origin")).array.len,
    //            gl.FLOAT,
    //            gl.FALSE,
    //            @sizeOf(Mesh),
    //            @offsetOf(Mesh, "origin"),
    //            );
    //        // zig fmt: on
    //    }
    //    {
    //        const angle_attrib = gl.GetAttribLocation(state.program.?, "a_Angle");
    //        if (angle_attrib == -1) return error.GlColorAttribInvalid;
    //        gl.EnableVertexAttribArray(@intCast(angle_attrib));
    //        // zig fmt: off
    //        gl.VertexAttribPointer(
    //            @intCast(angle_attrib),
    //            1,
    //            gl.FLOAT,
    //            gl.FALSE,
    //            @sizeOf(Mesh),
    //            @offsetOf(Mesh, "angle"),
    //            );
    //        // zig fmt: on
    //    }
    //
    //    gl.VertexAttribDivisor(2, 1);
    //    gl.VertexAttribDivisor(3, 1);
}

fn create_graphics_pipeline() !void {
    state.program = gl.CreateProgram();
    if (state.program == 0) return error.GlProgramFailed;

    const vertex_shader = compile_shader(gl.VERTEX_SHADER, state.vertex_shader_source.?);

    const fragment_shader = compile_shader(gl.FRAGMENT_SHADER, state.fragment_shader_source.?);
    if (vertex_shader == 0) return error.GlCreateVertexShaderFailed;
    if (fragment_shader == 0) return error.GlCreateFragmentShaderFailed;

    gl.AttachShader(state.program.?, vertex_shader);
    gl.AttachShader(state.program.?, fragment_shader);
    gl.LinkProgram(state.program.?);
    gl.ValidateProgram(state.program.?);

    gl.DetachShader(state.program.?, vertex_shader);
    gl.DeleteShader(vertex_shader);
    gl.DetachShader(state.program.?, fragment_shader);
    gl.DeleteShader(fragment_shader);
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

    try read_in_shader(gl.FRAGMENT_SHADER);
    try read_in_shader(gl.VERTEX_SHADER);

    try create_graphics_pipeline();
    try vertex_specification();

    return c.SDL_APP_CONTINUE;
}

fn sdlAppIterate(appstate: ?*anyopaque) !c.SDL_AppResult {
    _ = appstate;
    try check_gl_error();
    gl.Disable(gl.DEPTH_TEST);
    gl.Disable(gl.CULL_FACE);
    gl.Viewport(0, 0, state.screen_w, state.screen_h);

    //C = (1 − |2L − 1|) × S
    //X = C × (1 − |(H × 6 mod 2) − 1|)
    //m = L − C/2
    const hue: f32 = @floatFromInt(@mod((@divTrunc(std.time.milliTimestamp(), 100)), 360));
    // std.debug.print("hue:{d}\n", .{hue});

    const c_hsv = (1.0 - @abs(2.0 * Luminance - 1.0)) * Saturation;
    const x_hsv = c_hsv * (1 - @abs(@mod((hue / 60) * 6.0, 2.0)));
    const m_hsv = Luminance - c_hsv / 2.0;

    var red: f32, var green: f32, var blue: f32 = blk: {
        if (hue < 60.0) {
            break :blk .{ c_hsv, x_hsv, 0 };
        } else if (hue < 120) {
            break :blk .{ x_hsv, c_hsv, 0 };
        } else if (hue < 180) {
            break :blk .{ 0, c_hsv, x_hsv };
        } else if (hue < 240) {
            break :blk .{ 0, x_hsv, c_hsv };
        } else if (hue < 300) {
            break :blk .{ x_hsv, 0, c_hsv };
        } else if (hue <= 360) {
            break :blk .{ c_hsv, 0, x_hsv };
        } else {
            break :blk .{ c_hsv, x_hsv, 0 };
        }
    };

    red = (red + m_hsv);
    green = (green + m_hsv);
    blue = (blue + m_hsv);
    state.meshes.?[0].angle += 10;
    //std.debug.print("r:{d} g:{d} b:{d}\n", .{ red, green, blue });

    red = 100;
    green = 100;
    blue = 100;
    gl.ClearColor(red, green, blue, 1);
    gl.Clear(gl.COLOR_BUFFER_BIT);

    gl.UseProgram(state.program.?);
    try check_gl_error();

    gl.BindVertexArray(state.vao.?);
    //  gl.BindBuffer(gl.ARRAY_BUFFER, state.vbo_mesh.?);
    //   try check_gl_error();

    //std.debug.print("meshes:{any}\n", .{state.meshes.?});
    //std.debug.print("vertices:{any}\n", .{state.vertices.?});

    //    gl.BufferSubData(gl.ARRAY_BUFFER, 0, @sizeOf(@TypeOf(state.meshes.?)), @ptrCast(state.meshes.?));
    gl.BindBuffer(gl.ARRAY_BUFFER, state.vbo_vert.?);
    try check_gl_error();

    gl.DrawArrays(gl.TRIANGLES, 0, 3);

    try errify(c.SDL_GL_SwapWindow(state.window.?));
    try check_gl_error();
    return c.SDL_APP_CONTINUE;
}

fn sdlAppEvent(appstate: ?*anyopaque, event: *c.SDL_Event) !c.SDL_AppResult {
    _ = appstate;

    if (event.type == c.SDL_EVENT_QUIT) {
        return c.SDL_APP_SUCCESS;
    }

    return c.SDL_APP_CONTINUE;
}

fn sdlAppQuit(appstate: ?*anyopaque, result: anyerror!c.SDL_AppResult) void {
    sdl_log.warn("starting app quit\n", .{});
    _ = appstate;

    _ = result catch |err| if (err == error.SdlError) {
        sdl_log.err("{s}\n", .{c.SDL_GetError()});
    };

    if (state.fragment_shader_source != null)
        state.allocator.free(state.fragment_shader_source.?);
    if (state.vertex_shader_source != null)
        state.allocator.free(state.vertex_shader_source.?);
    if (state.vbo_vert != null)
        gl.DeleteBuffers(1, (&state.vbo_vert.?)[0..1]);
    if (state.vbo_mesh != null)
        gl.DeleteBuffers(1, (&state.vbo_mesh.?)[0..1]);
    if (state.vao != null)
        gl.DeleteVertexArrays(1, (&state.vao.?)[0..1]);
    if (state.ibo != null)
        gl.DeleteBuffers(1, (&state.ibo.?)[0..1]);
    if (state.program != null)
        gl.DeleteProgram(state.program.?);
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
    if (state.meshes != null)
        state.allocator.free(state.meshes.?);
    if (state.vertices != null)
        state.allocator.free(state.vertices.?);

    if (state.window != null)
        c.SDL_DestroyWindow(state.window.?);
    c.SDL_Quit();
    state = .{
        .window = null,
        .screen_w = Window_Width,
        .screen_h = Window_Height,
        .gl_ctx = null,
        .gl_procs = null,
        .vbo_mesh = null,
        .vbo_vert = null,
        .ibo = null,
        .vao = null,
        .program = null,
        .vertices = null,
        .meshes = null,
        .allocator = state.allocator,
        .fragment_shader_source = null,
        .vertex_shader_source = null,
    };
}
fn read_in_shader(shader_type: c_uint) !void {
    const shader_path = if (shader_type == gl.VERTEX_SHADER) blk: {
        break :blk Vertex_Shader_Path;
    } else if (shader_type == gl.FRAGMENT_SHADER) blk_b: {
        break :blk_b Fragment_Shader_Path;
    } else unreachable;

    const slice = try std.fs.cwd().readFileAlloc(state.allocator, shader_path, std.math.maxInt(usize));

    if (shader_type == gl.VERTEX_SHADER) state.vertex_shader_source = slice;
    if (shader_type == gl.FRAGMENT_SHADER) state.fragment_shader_source = slice;
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) @panic("gpa leaked");
    const allocator = gpa.allocator();
    state.allocator = allocator;
    //   var w = std.fs.File.stdout().writer(&.{});
    //   const writer = &w.interface;

    //   var w_err = std.fs.File.stderr().writer(&.{});
    //   const err_writer = &w_err.interface;

    //   state.writer = writer;
    //   state.err_writer = err_writer;

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
