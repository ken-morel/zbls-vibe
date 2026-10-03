const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const types = @import("types.zig");
const protocol = @import("protocol.zig");
const diagnostics = @import("../parser/diagnostics.zig");
const runner = @import("../runner/watcher.zig");

pub const Server = struct {
    allocator: Allocator,
    io: Io,
    transport: protocol.Transport,
    config: types.Config,
    workspace_root: ?[]const u8 = null,
    watcher: ?runner.Watcher = null,
    current_diagnostics: std.StringHashMap([]const u8),
    diagnosed_mutex: Io.Mutex = .init,
    shutdown_requested: bool = false,
    is_building: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: Allocator, io: Io, config: types.Config) Server {
        return .{
            .allocator = allocator,
            .io = io,
            .transport = protocol.Transport.init(io),
            .config = config,
            .current_diagnostics = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Server) void {
        if (self.watcher) |*w| {
            w.deinit();
        }
        if (self.workspace_root) |ws| {
            self.allocator.free(ws);
        }
        var it = self.current_diagnostics.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.current_diagnostics.deinit();
    }

    pub fn run(self: *Server) !void {
        while (!self.shutdown_requested) {
            const raw_msg = self.transport.readMessage(self.allocator) catch |err| {
                if (err == error.EndOfStream) break;
                continue;
            };
            if (raw_msg == null) break;
            const body = raw_msg.?;
            defer self.allocator.free(body);

            try self.handleMessage(body);
        }
    }

    fn handleMessage(self: *Server, body: []const u8) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch return;
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return;

        const obj = root.object;
        const method_val = obj.get("method");
        const id_val = obj.get("id");

        if (method_val) |m_val| {
            if (m_val == .string) {
                const method = m_val.string;
                if (std.mem.eql(u8, method, "initialize")) {
                    try self.handleInitialize(id_val, obj.get("params"));
                } else if (std.mem.eql(u8, method, "initialized")) {
                    try self.handleInitialized();
                } else if (std.mem.eql(u8, method, "textDocument/didOpen")) {
                    self.handleDidOpen(obj.get("params"));
                } else if (std.mem.eql(u8, method, "textDocument/didSave")) {
                    self.handleDidSave();
                } else if (std.mem.eql(u8, method, "shutdown")) {
                    try self.handleShutdown(id_val);
                } else if (std.mem.eql(u8, method, "exit")) {
                    self.shutdown_requested = true;
                } else if (std.mem.eql(u8, method, "workspace/didChangeConfiguration")) {
                    self.handleConfigChange(obj.get("params"));
                } else {
                    if (id_val) |id| {
                        try self.sendResult(id, "null");
                    }
                }
            }
        }
    }

    fn handleDidOpen(self: *Server, params_val: ?std.json.Value) void {
        const params = params_val orelse return;
        if (params != .object) return;
        const td = params.object.get("textDocument") orelse return;
        if (td != .object) return;
        const uri_val = td.object.get("uri") orelse return;
        if (uri_val != .string) return;
        const uri = uri_val.string;

        self.diagnosed_mutex.lockUncancelable(self.io);
        defer self.diagnosed_mutex.unlock(self.io);

        if (self.current_diagnostics.get(uri)) |cached_json| {
            self.sendPublishDiagnostics(uri, cached_json) catch {};
        }
    }

    fn handleDidSave(self: *Server) void {
        if (!self.is_building.swap(true, .acq_rel)) {
            self.sendShowMessage(3, "[zbls-vibe] Building...") catch {};
        }
        if (self.watcher) |*w| {
            w.wake();
        }
    }

    pub fn sendShowMessage(self: *Server, msg_type: u8, msg: []const u8) !void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"window/showMessage\",\"params\":{\"type\":");
        try buf.print(self.allocator, "{d},\"message\":", .{msg_type});
        try appendJsonString(&buf, self.allocator, msg);
        try buf.appendSlice(self.allocator, "}}");
        try self.transport.writeMessage(buf.items);
    }

    fn handleInitialize(self: *Server, id_val: ?std.json.Value, params_val: ?std.json.Value) !void {
        const id = id_val orelse return;

        if (params_val) |p| {
            if (p == .object) {
                const p_obj = p.object;
                if (p_obj.get("rootUri")) |r_uri| {
                    if (r_uri == .string and std.mem.startsWith(u8, r_uri.string, "file://")) {
                        self.workspace_root = try self.allocator.dupe(u8, r_uri.string[7..]);
                    }
                } else if (p_obj.get("rootPath")) |r_path| {
                    if (r_path == .string) {
                        self.workspace_root = try self.allocator.dupe(u8, r_path.string);
                    }
                }

                if (p_obj.get("initializationOptions")) |init_opts| {
                    self.parseConfigJson(init_opts);
                }
            }
        }

        if (self.workspace_root == null) {
            var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const cwd_len = std.Io.Dir.cwd().realPath(self.io, &cwd_buf) catch 0;
            const cwd_path = if (cwd_len > 0) cwd_buf[0..cwd_len] else ".";
            self.workspace_root = try self.allocator.dupe(u8, cwd_path);
        }

        const result_json =
            \\{"capabilities":{"textDocumentSync":{"openClose":true,"change":0,"save":true}},"serverInfo":{"name":"zbls-vibe","version":"0.1.0"}}
        ;

        try self.sendResult(id, result_json);
    }

    fn handleInitialized(self: *Server) !void {
        if (self.workspace_root) |ws| {
            self.watcher = try runner.Watcher.init(
                self.allocator,
                self.io,
                ws,
                self.config,
                self,
                onBuildEvent,
                onLogMessage,
            );
            try self.watcher.?.start();
            self.sendShowMessage(3, "[zbls-vibe] Watching zig build...") catch {};
        }
    }

    fn handleShutdown(self: *Server, id_val: ?std.json.Value) !void {
        if (self.watcher) |*w| {
            w.stop();
        }
        if (id_val) |id| {
            try self.sendResult(id, "null");
        }
    }

    fn handleConfigChange(self: *Server, params_val: ?std.json.Value) void {
        if (params_val) |p| {
            if (p == .object) {
                if (p.object.get("settings")) |s| {
                    self.parseConfigJson(s);
                }
            }
        }
    }

    fn parseConfigJson(self: *Server, json_val: std.json.Value) void {
        if (json_val != .object) return;
        const target_obj = if (json_val.object.get("zbls")) |z| (if (z == .object) z.object else json_val.object) else json_val.object;

        if (target_obj.get("zigPath")) |zp| {
            if (zp == .string) {
                self.config.zig_path = self.allocator.dupe(u8, zp.string) catch self.config.zig_path;
            }
        }
        if (target_obj.get("debounceMs")) |db| {
            if (db == .integer and db.integer >= 0) {
                self.config.debounce_ms = @intCast(db.integer);
            }
        }
        if (target_obj.get("buildArgs")) |ba| {
            if (ba == .array) {
                var list: std.ArrayList([]const u8) = .empty;
                for (ba.array.items) |item| {
                    if (item == .string) {
                        if (self.allocator.dupe(u8, item.string)) |s| {
                            list.append(self.allocator, s) catch {};
                        } else |_| {}
                    }
                }
                if (list.items.len > 0) {
                    self.config.build_args = list.toOwnedSlice(self.allocator) catch self.config.build_args;
                }
            }
        }
        if (target_obj.get("extraArgs")) |ea| {
            if (ea == .array) {
                var list: std.ArrayList([]const u8) = .empty;
                for (ea.array.items) |item| {
                    if (item == .string) {
                        if (self.allocator.dupe(u8, item.string)) |s| {
                            list.append(self.allocator, s) catch {};
                        } else |_| {}
                    }
                }
                self.config.extra_args = list.toOwnedSlice(self.allocator) catch self.config.extra_args;
            }
        }
    }

    fn sendResult(self: *Server, id: std.json.Value, result_json: []const u8) !void {
        var id_buf: [64]u8 = undefined;
        var id_str: []const u8 = "";
        switch (id) {
            .integer => |i| {
                id_str = try std.fmt.bufPrint(&id_buf, "{d}", .{i});
            },
            .string => |s| {
                id_str = try std.fmt.bufPrint(&id_buf, "\"{s}\"", .{s});
            },
            else => {
                id_str = "null";
            },
        }

        var msg_buf: std.ArrayList(u8) = .empty;
        defer msg_buf.deinit(self.allocator);

        try msg_buf.print(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_str, result_json });
        try self.transport.writeMessage(msg_buf.items);
    }

    fn onLogMessage(ctx: *anyopaque, msg: []const u8) void {
        const self: *Server = @ptrCast(@alignCast(ctx));
        self.sendLogMessage(msg) catch {};
    }

    fn sendLogMessage(self: *Server, msg: []const u8) !void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"window/logMessage\",\"params\":{\"type\":3,\"message\":");
        try appendJsonString(&buf, self.allocator, msg);
        try buf.appendSlice(self.allocator, "}}");
        try self.transport.writeMessage(buf.items);
    }

    fn onBuildEvent(ctx: *anyopaque, event: diagnostics.BuildEvent) void {
        const self: *Server = @ptrCast(@alignCast(ctx));
        switch (event) {
            .build_started => {
                if (!self.is_building.swap(true, .acq_rel)) {
                    self.sendShowMessage(3, "[zbls-vibe] Building...") catch {};
                }
            },
            .clean_success => {
                _ = self.is_building.swap(false, .acq_rel);
                self.clearAllDiagnostics();
                self.sendShowMessage(3, "[zbls-vibe] Build succeeded (clean)") catch {};
            },
            .diagnostics_ready => |diags| {
                defer self.allocator.free(diags);
                _ = self.is_building.swap(false, .acq_rel);
                const count = diags.len;
                self.publishDiagnosticsList(diags);
                for (diags) |*d| {
                    var mut_d = d.*;
                    mut_d.deinit(self.allocator);
                }
                if (count == 0) {
                    self.sendShowMessage(3, "[zbls-vibe] Build succeeded") catch {};
                } else {
                    var msg_buf: [128]u8 = undefined;
                    const msg = if (count == 1)
                        "[zbls-vibe] Build failed (1 diagnostic)"
                    else
                        std.fmt.bufPrint(&msg_buf, "[zbls-vibe] Build failed ({d} diagnostics)", .{count}) catch "[zbls-vibe] Build failed";
                    self.sendShowMessage(2, msg) catch {};
                }
            },
            .none => {},
        }
    }

    fn clearAllDiagnostics(self: *Server) void {
        self.diagnosed_mutex.lockUncancelable(self.io);
        defer self.diagnosed_mutex.unlock(self.io);

        var it = self.current_diagnostics.iterator();
        while (it.next()) |entry| {
            self.sendPublishDiagnostics(entry.key_ptr.*, "[]") catch {};
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.current_diagnostics.clearRetainingCapacity();
    }

    fn publishDiagnosticsList(self: *Server, diags: []diagnostics.RawMessage) void {
        self.diagnosed_mutex.lockUncancelable(self.io);
        defer self.diagnosed_mutex.unlock(self.io);

        var files_in_build = std.StringHashMap(std.ArrayList(diagnostics.RawMessage)).init(self.allocator);
        defer {
            var it = files_in_build.valueIterator();
            while (it.next()) |list| {
                list.deinit(self.allocator);
            }
            files_in_build.deinit();
        }

        for (diags) |d| {
            const res = files_in_build.getOrPut(d.file_path) catch continue;
            if (!res.found_existing) {
                res.value_ptr.* = .empty;
            }
            res.value_ptr.append(self.allocator, d) catch {};
        }

        var current_uris = std.StringHashMap(void).init(self.allocator);
        defer current_uris.deinit();

        var file_it = files_in_build.iterator();
        while (file_it.next()) |entry| {
            const path = entry.key_ptr.*;
            const items = entry.value_ptr.items;

            const uri = self.pathToUri(path) catch continue;
            defer self.allocator.free(uri);

            current_uris.put(uri, {}) catch {};

            const json = self.serializeDiagnostics(items) catch continue;

            const gop = self.current_diagnostics.getOrPut(uri) catch {
                self.allocator.free(json);
                continue;
            };

            if (gop.found_existing) {
                self.allocator.free(gop.value_ptr.*);
                gop.value_ptr.* = json;
            } else {
                gop.key_ptr.* = self.allocator.dupe(u8, uri) catch {
                    self.allocator.free(json);
                    _ = self.current_diagnostics.remove(uri);
                    continue;
                };
                gop.value_ptr.* = json;
            }

            self.sendPublishDiagnostics(uri, json) catch {};
        }

        var files_to_remove: std.ArrayList([]const u8) = .empty;
        defer files_to_remove.deinit(self.allocator);

        var old_it = self.current_diagnostics.iterator();
        while (old_it.next()) |entry| {
            if (!current_uris.contains(entry.key_ptr.*)) {
                self.sendPublishDiagnostics(entry.key_ptr.*, "[]") catch {};
                files_to_remove.append(self.allocator, entry.key_ptr.*) catch {};
            }
        }

        for (files_to_remove.items) |rem| {
            if (self.current_diagnostics.fetchRemove(rem)) |kv| {
                self.allocator.free(kv.key);
                self.allocator.free(kv.value);
            }
        }
    }

    fn serializeDiagnostics(self: *Server, items: []const diagnostics.RawMessage) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.allocator);

        try buf.append(self.allocator, '[');

        for (items, 0..) |item, i| {
            if (i > 0) try buf.append(self.allocator, ',');
            const end_col = item.col + item.span_len;
            const sev_num = @intFromEnum(item.severity);

            try buf.print(
                self.allocator,
                \\{{"range":{{"start":{{"line":{d},"character":{d}}},"end":{{"line":{d},"character":{d}}}}},"severity":{d},"source":"zig-build","message":
            ,
                .{ item.line, item.col, item.line, end_col, sev_num },
            );

            try appendJsonString(&buf, self.allocator, item.message);

            if (item.notes.items.len > 0) {
                try buf.appendSlice(self.allocator, ",\"relatedInformation\":[");
                for (item.notes.items, 0..) |note, ni| {
                    if (ni > 0) try buf.append(self.allocator, ',');
                    try buf.print(
                        self.allocator,
                        \\{{"location":{{"uri":"{s}","range":{{"start":{{"line":{d},"character":{d}}},"end":{{"line":{d},"character":{d}}}}}}},"message":
                    ,
                        .{
                            note.location.uri,
                            note.location.range.start.line,
                            note.location.range.start.character,
                            note.location.range.end.line,
                            note.location.range.end.character,
                        },
                    );

                    try appendJsonString(&buf, self.allocator, note.message);

                    try buf.append(self.allocator, '}');
                }
                try buf.append(self.allocator, ']');
            }

            try buf.append(self.allocator, '}');
        }

        try buf.append(self.allocator, ']');
        return buf.toOwnedSlice(self.allocator);
    }

    fn sendPublishDiagnostics(self: *Server, uri: []const u8, diags_json: []const u8) !void {
        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(self.allocator);

        try msg.print(
            self.allocator,
            \\{{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{{"uri":"{s}","diagnostics":{s}}}}}
        ,
            .{ uri, diags_json },
        );

        try self.transport.writeMessage(msg.items);
    }

    fn pathToUri(self: *Server, path: []const u8) ![]const u8 {
        return diagnostics.pathToUri(self.allocator, self.workspace_root orelse ".", path);
    }
};

/// Append `s` to `buf` as a quoted, escaped JSON string.
pub fn appendJsonString(buf: *std.ArrayList(u8), gpa: Allocator, s: []const u8) !void {
    try buf.append(gpa, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(gpa, "\\\""),
            '\\' => try buf.appendSlice(gpa, "\\\\"),
            '\n' => try buf.appendSlice(gpa, "\\n"),
            '\r' => try buf.appendSlice(gpa, "\\r"),
            '\t' => try buf.appendSlice(gpa, "\\t"),
            0...0x08, 0x0b, 0x0c, 0x0e...0x1f => try buf.print(gpa, "\\u{x:0>4}", .{c}),
            else => try buf.append(gpa, c),
        }
    }
    try buf.append(gpa, '"');
}

test appendJsonString {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try appendJsonString(&buf, gpa, "a \"b\"\n\\");
    try std.testing.expectEqualStrings("\"a \\\"b\\\"\\n\\\\\"", buf.items);
}
