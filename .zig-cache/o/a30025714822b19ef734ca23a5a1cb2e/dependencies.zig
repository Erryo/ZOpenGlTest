pub const packages = struct {
    pub const @"sdl-0.2.0+3.2.8-7uIn9FxHfQE325TK7b0qpgt10G3x1xl-3ZMOfTzxUg3C" = struct {
        pub const build_root = "/home/infy/.cache/zig/p/sdl-0.2.0+3.2.8-7uIn9FxHfQE325TK7b0qpgt10G3x1xl-3ZMOfTzxUg3C";
        pub const build_zig = @import("sdl-0.2.0+3.2.8-7uIn9FxHfQE325TK7b0qpgt10G3x1xl-3ZMOfTzxUg3C");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "sdl_linux_deps", "sdl_linux_deps-0.0.0-Vy5_h4AlfwBtG7MIPe7ZNUANhmYLek_SA140uYk9SrED" },
        };
    };
    pub const @"sdl_linux_deps-0.0.0-Vy5_h4AlfwBtG7MIPe7ZNUANhmYLek_SA140uYk9SrED" = struct {
        pub const available = true;
        pub const build_root = "/home/infy/.cache/zig/p/sdl_linux_deps-0.0.0-Vy5_h4AlfwBtG7MIPe7ZNUANhmYLek_SA140uYk9SrED";
        pub const build_zig = @import("sdl_linux_deps-0.0.0-Vy5_h4AlfwBtG7MIPe7ZNUANhmYLek_SA140uYk9SrED");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
    pub const @"zigglgen-0.5.0-zigglr_CLwBs1aABtYVtxNPo1SB8AzgKMVouoqULqkDQ" = struct {
        pub const build_root = "/home/infy/.cache/zig/p/zigglgen-0.5.0-zigglr_CLwBs1aABtYVtxNPo1SB8AzgKMVouoqULqkDQ";
        pub const build_zig = @import("zigglgen-0.5.0-zigglr_CLwBs1aABtYVtxNPo1SB8AzgKMVouoqULqkDQ");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "sdl", "sdl-0.2.0+3.2.8-7uIn9FxHfQE325TK7b0qpgt10G3x1xl-3ZMOfTzxUg3C" },
    .{ "zigglgen", "zigglgen-0.5.0-zigglr_CLwBs1aABtYVtxNPo1SB8AzgKMVouoqULqkDQ" },
};
