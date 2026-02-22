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

const Triangles_Vertex_Shader_Path = "shaders/vertex_shader.glsl";
const Triangles_Fragment_Shader_Path = "shaders/fragment_shader.glsl";

const Lines_Vertex_Shader_Path = "shaders/vertex_shader.glsl";
const Lines_Fragment_Shader_Path = "shaders/fragment_shader.glsl";

const VertexList = std.ArrayList(Vertex);

const State = struct {
    window: ?*c.SDL_Window,
    screen_w: c_int,
    screen_h: c_int,

    allocator: std.mem.Allocator,

    gl_ctx: c.SDL_GLContext,
    gl_procs: ?gl.ProcTable,

    objects: ?[]Drawable,
};

const Drawable = struct {
    draw_fn: *const fn (*Drawable) anyerror!void,

    vertices: ?[]Vertex,
    indices: ?[]u8,

    vbo: ?c_uint,
    program: ?c_uint,
    vertex_shader_source: ?[]u8,
    fragment_shader_source: ?[]u8,
    vao: ?c_uint, // alignment of the vertecies in vbo
    ibo: ?c_uint, // indexes. Maps indices to vertices, to enable reusing vertex data.
};

const Vertex = extern struct {
    position: [3]f32,
    color: [3]f32,
};

var state: State = .{
    .allocator = undefined,
    .window = null,
    .screen_w = Window_Width,
    .screen_h = Window_Height,
    .gl_ctx = null,
    .gl_procs = null,
    .objects = null,
};

fn line_draw(obj: *Drawable) anyerror!void {
    gl.UseProgram(obj.program.?);
    try check_gl_error();
    defer gl.UseProgram(0);

    gl.BindVertexArray(obj.vao.?);
    defer gl.BindVertexArray(0);

    gl.BindBuffer(gl.ARRAY_BUFFER, obj.vbo.?);
    defer gl.BindBuffer(gl.ARRAY_BUFFER, 0);

    //    gl.BufferSubData(gl.ARRAY_BUFFER, 0, @intCast(state.vertices.?.len * @sizeOf(Vertex)), @ptrCast(state.vertices.?));
    gl.DrawArrays(gl.LINES, 0, @intCast(obj.vertices.?.len));

    //    gl.DrawElements(gl.TRIANGLES, @intCast(state.indices.?.len), gl.UNSIGNED_BYTE, 0);
}

fn lines_init() !Drawable {
    var obj: Drawable = .{
        // zif fmt: off
        .program = null,
        .fragment_shader_source = null,
        .vertex_shader_source = null,
        .vao = null,
        .vertices = null,
        .vbo = null,
        .draw_fn = line_draw,
        .ibo = null,
        .indices = null,
        // zif fmt: on
    };

    obj.vertex_shader_source = try read_in_shader(Lines_Vertex_Shader_Path);
    obj.fragment_shader_source = try read_in_shader(Lines_Fragment_Shader_Path);

    obj.program = try create_graphics_pipeline(obj.vertex_shader_source.?, obj.fragment_shader_source.?);

    const vertices = [_]Vertex{
        Vertex{ .color = .{ 1, 0, 0 }, .position = .{ -1, 0, 0 } },
        Vertex{ .color = .{ 0, 0, 1 }, .position = .{ 1, 0, 0 } },
        Vertex{ .color = .{ 1, 0, 0 }, .position = .{ 0, -1, 0 } },
        Vertex{ .color = .{ 0, 0, 1 }, .position = .{ 0, 1, 0 } },
    };

    var vertices_list = try VertexList.initCapacity(state.allocator, vertices.len);

    try vertices_list.appendSlice(state.allocator, vertices[0..]);

    obj.vertices = try vertices_list.toOwnedSlice(state.allocator);

    vertices_list.deinit(state.allocator);

    obj.vao = undefined;

    gl.GenVertexArrays(1, (&obj.vao.?)[0..1]);
    gl.BindVertexArray(obj.vao.?);
    defer gl.BindVertexArray(0);

    obj.vbo = undefined;
    gl.GenBuffers(1, (&obj.vbo.?)[0..1]);

    gl.BindBuffer(gl.ARRAY_BUFFER, obj.vbo.?);
    defer gl.BindBuffer(gl.ARRAY_BUFFER, 0);

    gl.BufferData(
        gl.ARRAY_BUFFER,
        @intCast(obj.vertices.?.len * @sizeOf(Vertex)),
        @ptrCast(obj.vertices.?.ptr),
        gl.STATIC_DRAW,
    );
    try check_gl_error();

    {
        const position_attrib = gl.GetAttribLocation(obj.program.?, "a_Position");
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
        const color_attrib = gl.GetAttribLocation(obj.program.?, "a_Color");
        if (color_attrib == -1) return error.GlPositionAttribInvalid;
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

    //    gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, state.ibo.?);
    //    gl.BufferData(
    //        gl.ELEMENT_ARRAY_BUFFER,
    //        @intCast(state.indices.?.len * @sizeOf(u8)),
    //        @ptrCast(state.indices.?.ptr),
    //        gl.STATIC_DRAW,
    //    );
    try check_gl_error();
    return obj;
}

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

    //    try read_in_shader(gl.FRAGMENT_SHADER);
    //    try read_in_shader(gl.VERTEX_SHADER);
    //
    //    try create_graphics_pipeline();
    //    try vertex_specification();

    state.objects = try state.allocator.alloc(Drawable, 1);

    state.objects.?[0] = try lines_init();

    return c.SDL_APP_CONTINUE;
}

fn sdlAppIterate(appstate: ?*anyopaque) !c.SDL_AppResult {
    _ = appstate;

    try check_gl_error();
    try errify(c.SDL_GetWindowSize(state.window, &state.screen_w, &state.screen_h));
    gl.Disable(gl.DEPTH_TEST);
    gl.Disable(gl.CULL_FACE);
    gl.Viewport(0, 0, state.screen_w, state.screen_h);

    gl.ClearColor(0.1, 0.1, 0.1, 1);
    gl.Clear(gl.COLOR_BUFFER_BIT);

    if (state.objects) |_| {
        for (state.objects.?) |*obj| {
            try obj.draw_fn(obj);
        }
    }

    //    gl.UseProgram(program.?);
    //    try check_gl_error();
    //
    //    gl.BindVertexArray(state.vao.?);
    //    gl.BindBuffer(gl.ARRAY_BUFFER, state.vbo_vert.?);
    //
    //    gl.BufferSubData(gl.ARRAY_BUFFER, 0, @intCast(state.vertices.?.len * @sizeOf(Vertex)), @ptrCast(state.vertices.?));
    //
    //    gl.DrawElements(gl.TRIANGLES, @intCast(state.indices.?.len), gl.UNSIGNED_BYTE, 0);
    //    gl.DrawArrays(gl.TRIANGLES, 0, @intCast(state.vertices.?.len));

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

    for (state.objects.?) |*obj| {
        if (obj.fragment_shader_source != null)
            state.allocator.free(obj.fragment_shader_source.?);
        if (obj.vertex_shader_source != null)
            state.allocator.free(obj.vertex_shader_source.?);
        if (obj.vbo != null)
            gl.DeleteBuffers(1, (&obj.vbo.?)[0..1]);
        if (obj.ibo != null)
            gl.DeleteBuffers(1, (&obj.ibo.?)[0..1]);
        if (obj.vao != null)
            gl.DeleteVertexArrays(1, (&obj.vao.?)[0..1]);
        if (obj.ibo != null)
            gl.DeleteBuffers(1, (&obj.ibo.?)[0..1]);
        if (obj.program != null)
            gl.DeleteProgram(obj.program.?);
        if (obj.vertices != null)
            state.allocator.free(obj.vertices.?);
        if (obj.indices != null)
            state.allocator.free(obj.indices.?);

        obj.* = Drawable{
            .fragment_shader_source = null,
            .ibo = null,
            .vertex_shader_source = null,
            .draw_fn = undefined,
            .indices = null,
            .program = null,
            .vao = null,
            .vbo = null,
            .vertices = null,
        };
    }
    if (state.objects != null) state.allocator.free(state.objects.?);

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
        .objects = null,
        .window = null,
        .screen_w = Window_Width,
        .screen_h = Window_Height,
        .gl_ctx = null,
        .gl_procs = null,
        .allocator = state.allocator,
    };
}

fn read_in_shader(shader_path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(state.allocator, shader_path, std.math.maxInt(usize));
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
