const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Transport = struct {
    io: Io,
    mutex: Io.Mutex = .init,

    pub fn init(io: Io) Transport {
        return .{
            .io = io,
        };
    }

    /// Read next JSON-RPC payload from stdin
    pub fn readMessage(self: *Transport, allocator: Allocator) !?[]u8 {
        const stdin = Io.File.stdin();
        var header_buf: [1024]u8 = undefined;
        var header_len: usize = 0;
        var content_length: ?usize = null;

        // Read until "\r\n\r\n" or "\n\n"
        while (true) {
            var byte: [1]u8 = undefined;
            const n = stdin.readStreaming(self.io, &.{&byte}) catch |err| {
                if (err == error.EndOfStream) return null;
                return err;
            };
            if (n == 0) return null;

            if (header_len < header_buf.len) {
                header_buf[header_len] = byte[0];
                header_len += 1;
            } else {
                return error.HeaderTooLarge;
            }

            const current = header_buf[0..header_len];
            if (std.mem.endsWith(u8, current, "\r\n\r\n") or std.mem.endsWith(u8, current, "\n\n")) {
                // Parse headers
                var lines = std.mem.splitSequence(u8, current, "\n");
                while (lines.next()) |raw_l| {
                    const l = std.mem.trim(u8, raw_l, "\r \t");
                    if (std.ascii.startsWithIgnoreCase(l, "content-length:")) {
                        const val_str = std.mem.trim(u8, l[15..], " \t");
                        content_length = std.fmt.parseInt(usize, val_str, 10) catch null;
                    }
                }
                break;
            }
        }

        const len = content_length orelse return error.MissingContentLength;
        const body = try allocator.alloc(u8, len);
        errdefer allocator.free(body);

        var total_read: usize = 0;
        while (total_read < len) {
            const chunk = body[total_read..];
            const n = stdin.readStreaming(self.io, &.{chunk}) catch |err| {
                if (err == error.EndOfStream) return error.UnexpectedEof;
                return err;
            };
            if (n == 0) return error.UnexpectedEof;
            total_read += n;
        }

        return body;
    }

    /// Write JSON-RPC payload to stdout with Content-Length header
    pub fn writeMessage(self: *Transport, payload: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const stdout = Io.File.stdout();
        var header_buf: [64]u8 = undefined;
        const header = try std.fmt.bufPrint(&header_buf, "Content-Length: {d}\r\n\r\n", .{payload.len});

        try stdout.writeStreamingAll(self.io, header);
        try stdout.writeStreamingAll(self.io, payload);
    }
};

test "protocol header parsing" {
    const raw = "Content-Length: 123\r\nContent-Type: application/vscode-jsonrpc\r\n\r\n";
    var lines = std.mem.splitSequence(u8, raw, "\n");
    var len: ?usize = null;
    while (lines.next()) |raw_l| {
        const l = std.mem.trim(u8, raw_l, "\r \t");
        if (std.ascii.startsWithIgnoreCase(l, "content-length:")) {
            const val_str = std.mem.trim(u8, l[15..], " \t");
            len = try std.fmt.parseInt(usize, val_str, 10);
        }
    }
    try std.testing.expectEqual(@as(?usize, 123), len);
}
