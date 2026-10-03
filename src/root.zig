pub const types = @import("lsp/types.zig");
pub const protocol = @import("lsp/protocol.zig");
pub const server = @import("lsp/server.zig");
pub const diagnostics = @import("parser/diagnostics.zig");
pub const watcher = @import("runner/watcher.zig");

test {
    _ = types;
    _ = protocol;
    _ = server;
    _ = diagnostics;
    _ = watcher;
}
