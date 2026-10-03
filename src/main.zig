const std = @import("std");
const zbls = @import("zbls_vibe");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var config = zbls.types.Config{};
    var extra_args: std.ArrayList([]const u8) = .empty;
    defer extra_args.deinit(arena);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            std.debug.print("zbls-vibe 0.1.0\n", .{});
            return;
        } else if (std.mem.eql(u8, arg, "--zig")) {
            i += 1;
            if (i < args.len) {
                config.zig_path = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            while (i < args.len) : (i += 1) {
                try extra_args.append(arena, args[i]);
            }
            break;
        } else {
            try extra_args.append(arena, arg);
        }
    }

    config.extra_args = extra_args.items;

    var server = zbls.server.Server.init(arena, init.io, config);
    defer server.deinit();

    try server.run();
}

fn printUsage() void {
    const usage =
        \\zbls-vibe: Companion LSP server running `zig build -fincremental --watch`
        \\
        \\Usage:
        \\  zbls-vibe [options] [-- <extra zig build args...>]
        \\
        \\Options:
        \\  -h, --help       Show this help message
        \\  -v, --version    Show version information
        \\  --zig <path>     Path to zig executable (default: "zig")
        \\
    ;
    std.debug.print("{s}", .{usage});
}
