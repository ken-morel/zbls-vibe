const std = @import("std");
const types = @import("../lsp/types.zig");
const Allocator = std.mem.Allocator;

pub const RawMessage = struct {
    file_path: []const u8,
    line: u32,
    col: u32,
    severity: types.DiagnosticSeverity,
    message: []const u8,
    span_len: u32 = 1,
    notes: std.ArrayList(types.DiagnosticRelatedInformation),

    pub fn deinit(self: *RawMessage, allocator: Allocator) void {
        allocator.free(self.file_path);
        allocator.free(self.message);
        for (self.notes.items) |n| {
            allocator.free(n.location.uri);
            allocator.free(n.message);
        }
        self.notes.deinit(allocator);
    }
};

pub const BuildEvent = union(enum) {
    clean_success,
    diagnostics_ready: []RawMessage,
    none,
};

pub const DiagnosticsParser = struct {
    allocator: Allocator,
    current_messages: std.ArrayList(RawMessage),
    workspace_root: []const u8,
    /// What the last location line was, so a following `^~~` underline can
    /// be attributed to it.
    last_kind: enum { diag, note, other } = .other,
    in_reference_trace: bool = false,

    pub fn init(allocator: Allocator, workspace_root: []const u8) DiagnosticsParser {
        return .{
            .allocator = allocator,
            .current_messages = .empty,
            .workspace_root = workspace_root,
        };
    }

    pub fn deinit(self: *DiagnosticsParser) void {
        for (self.current_messages.items) |*msg| {
            msg.deinit(self.allocator);
        }
        self.current_messages.deinit(self.allocator);
    }

    pub fn clear(self: *DiagnosticsParser) void {
        for (self.current_messages.items) |*msg| {
            msg.deinit(self.allocator);
        }
        self.current_messages.clearRetainingCapacity();
    }

    /// Call when the build process exits. `zig build --watch` exits without
    /// printing a "Build Summary" when `build.zig` itself fails to compile,
    /// so any collected diagnostics must be emitted here.
    pub fn flush(self: *DiagnosticsParser) !BuildEvent {
        self.last_kind = .other;
        self.in_reference_trace = false;
        if (self.current_messages.items.len == 0) return .none;
        return .{ .diagnostics_ready = try self.current_messages.toOwnedSlice(self.allocator) };
    }

    pub fn processLine(self: *DiagnosticsParser, raw_line: []const u8) !BuildEvent {
        const line = std.mem.trimEnd(u8, raw_line, "\r\n");

        // End of a build cycle.
        if (std.mem.startsWith(u8, line, "Build Summary:")) {
            self.in_reference_trace = false;
            self.last_kind = .other;
            const failed = std.mem.indexOf(u8, line, "failed") != null;
            if (!failed) {
                self.clear();
                return .clean_success;
            }
            // Failed build: hand over whatever we collected (possibly
            // nothing, e.g. a test that failed at runtime) so the server can
            // replace the previous set of diagnostics.
            const result = try self.current_messages.toOwnedSlice(self.allocator);
            return .{ .diagnostics_ready = result };
        }

        // "      ^~~~" underline: applies to whatever diagnostic/note was
        // printed right before the source excerpt.
        if (parseUnderline(line)) |u| {
            switch (self.last_kind) {
                .diag => {
                    const m = self.lastMsg().?;
                    const r = applyUnderline(u, m.col);
                    m.col = r.start;
                    m.span_len = r.end - r.start;
                },
                .note => {
                    const notes = &self.lastMsg().?.notes;
                    const range = &notes.items[notes.items.len - 1].location.range;
                    const r = applyUnderline(u, range.start.character);
                    range.start.character = r.start;
                    range.end.character = r.end;
                },
                .other => {},
            }
            self.last_kind = .other;
            return .none;
        }

        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t"), "referenced by:")) {
            self.in_reference_trace = self.current_messages.items.len > 0;
            return .none;
        }

        // "    main: src/main.zig:169:30" inside a reference trace.
        if (self.in_reference_trace) {
            if (parseReferenceLine(line)) |ref| {
                try self.appendNote(ref.file_path, ref.line, ref.col, try std.fmt.allocPrint(self.allocator, "referenced by {s}", .{ref.name}));
                self.last_kind = .other;
                return .none;
            }
            self.in_reference_trace = false;
        }

        // "file:line:col: severity: message"
        if (parseDiagLine(line)) |parsed| {
            if (parsed.severity == .Information) {
                if (self.current_messages.items.len == 0) return .none;
                try self.appendNote(parsed.file_path, parsed.line, parsed.col, try self.allocator.dupe(u8, parsed.message));
                self.last_kind = .note;
            } else {
                const file_path = try self.allocator.dupe(u8, parsed.file_path);
                errdefer self.allocator.free(file_path);
                const message = try self.allocator.dupe(u8, parsed.message);
                errdefer self.allocator.free(message);
                try self.current_messages.append(self.allocator, .{
                    .file_path = file_path,
                    .line = parsed.line -| 1,
                    .col = parsed.col -| 1,
                    .severity = parsed.severity,
                    .message = message,
                    .span_len = 1,
                    .notes = .empty,
                });
                self.last_kind = .diag;
            }
            return .none;
        }

        // Source excerpt lines etc. keep the last_kind so the following caret
        // line is attributed correctly.
        return .none;
    }

    fn lastMsg(self: *DiagnosticsParser) ?*RawMessage {
        if (self.current_messages.items.len == 0) return null;
        return &self.current_messages.items[self.current_messages.items.len - 1];
    }

    /// Takes ownership of `message`.
    fn appendNote(self: *DiagnosticsParser, path: []const u8, line_1: u32, col_1: u32, message: []const u8) !void {
        errdefer self.allocator.free(message);
        const last = self.lastMsg() orelse {
            self.allocator.free(message);
            return;
        };
        const uri = try self.pathToUri(path);
        errdefer self.allocator.free(uri);
        const l = line_1 -| 1;
        const c = col_1 -| 1;
        try last.notes.append(self.allocator, .{
            .location = .{ .uri = uri, .range = .{
                .start = .{ .line = l, .character = c },
                .end = .{ .line = l, .character = c + 1 },
            } },
            .message = message,
        });
    }

    fn pathToUri(self: *DiagnosticsParser, path: []const u8) ![]const u8 {
        return pathToUriFree(self.allocator, self.workspace_root, path);
    }
};

const pathToUriFree = pathToUri;

/// Convert a (possibly workspace-relative) path into a `file://` URI.
/// Characters outside the unreserved set are percent-encoded.
pub fn pathToUri(gpa: Allocator, workspace_root: []const u8, path: []const u8) ![]const u8 {
    const abs = if (std.fs.path.isAbsolute(path))
        try gpa.dupe(u8, path)
    else
        try std.fs.path.resolve(gpa, &.{ workspace_root, path });
    defer gpa.free(abs);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "file://");
    for (abs) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~', '/' => try out.append(gpa, c),
            else => try out.print(gpa, "%{X:0>2}", .{c}),
        }
    }
    return out.toOwnedSlice(gpa);
}

test pathToUri {
    const gpa = std.testing.allocator;
    const u = try pathToUri(gpa, "/home/me/proj", "src/a b.zig");
    defer gpa.free(u);
    try std.testing.expectEqualStrings("file:///home/me/proj/src/a%20b.zig", u);
}

const ParsedLine = struct {
    file_path: []const u8,
    line: u32,
    col: u32,
    severity: types.DiagnosticSeverity,
    message: []const u8,
};

const Location = struct { path: []const u8, line: u32, col: u32 };

/// Parse `<path>:<line>:<col>` anchored at the end of `s`, so paths that
/// themselves contain ':' (e.g. `C:\foo`) still work.
fn parseLocation(s: []const u8) ?Location {
    const c_sep = std.mem.lastIndexOfScalar(u8, s, ':') orelse return null;
    const col = std.fmt.parseInt(u32, s[c_sep + 1 ..], 10) catch return null;
    const l_sep = std.mem.lastIndexOfScalar(u8, s[0..c_sep], ':') orelse return null;
    const line = std.fmt.parseInt(u32, s[l_sep + 1 .. c_sep], 10) catch return null;
    const path = s[0..l_sep];
    if (path.len == 0) return null;
    return .{ .path = path, .line = line, .col = col };
}

/// `<path>:<line>:<col>: <error|warning|note>: <message>`
fn parseDiagLine(line: []const u8) ?ParsedLine {
    const markers = [_]struct { []const u8, types.DiagnosticSeverity }{
        .{ ": error: ", .Error },
        .{ ": warning: ", .Warning },
        .{ ": note: ", .Information },
    };
    for (markers) |m| {
        const idx = std.mem.indexOf(u8, line, m[0]) orelse continue;
        const loc = parseLocation(line[0..idx]) orelse continue;
        // Reject indented lines (source excerpts / reference traces).
        if (loc.path[0] == ' ' or loc.path[0] == '\t') continue;
        return .{
            .file_path = loc.path,
            .line = loc.line,
            .col = loc.col,
            .severity = m[1],
            .message = std.mem.trim(u8, line[idx + m[0].len ..], " "),
        };
    }
    return null;
}

const RefLine = struct { name: []const u8, file_path: []const u8, line: u32, col: u32 };

/// `    <name>: <path>:<line>:<col>` (one entry of a "referenced by:" trace).
fn parseReferenceLine(line: []const u8) ?RefLine {
    if (line.len == 0 or (line[0] != ' ' and line[0] != '\t')) return null;
    const t = std.mem.trim(u8, line, " \t");
    const sep = std.mem.indexOf(u8, t, ": ") orelse return null;
    const loc = parseLocation(t[sep + 2 ..]) orelse return null;
    return .{ .name = t[0..sep], .file_path = loc.path, .line = loc.line, .col = loc.col };
}

const Underline = struct {
    /// 0-based column where the underline starts.
    start: u32,
    len: u32,
    /// 0-based column of the '^'.
    caret: u32,
};

/// Recognise Zig's source underline, e.g. `      ~~~~^~~~`. The line must
/// consist only of leading whitespace followed by '~'/'^' with exactly one '^'.
fn parseUnderline(line: []const u8) ?Underline {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    const body = std.mem.trimEnd(u8, trimmed, " \t");
    if (body.len == 0) return null;
    var caret: ?usize = null;
    for (body, 0..) |c, i| switch (c) {
        '^' => {
            if (caret != null) return null;
            caret = i;
        },
        '~' => {},
        else => return null,
    };
    const start: u32 = @intCast(line.len - trimmed.len);
    return .{
        .start = start,
        .len = @intCast(body.len),
        .caret = start + @as(u32, @intCast(caret orelse return null)),
    };
}

/// Apply an underline to a range anchored at `col` (0-based).
fn applyUnderline(u: Underline, col: u32) struct { start: u32, end: u32 } {
    // If the caret lines up with the reported column, trust the leading
    // whitespace for the start; otherwise anchor at the column.
    if (u.caret == col) return .{ .start = u.start, .end = u.start + u.len };
    return .{ .start = col, .end = col + (u.len - (u.caret - u.start)) };
}

pub fn freeMessages(gpa: Allocator, msgs: []RawMessage) void {
    for (msgs) |*m| m.deinit(gpa);
    gpa.free(msgs);
}

fn feedAll(p: *DiagnosticsParser, text: []const u8) !?[]RawMessage {
    var it = std.mem.splitScalar(u8, text, '\n');
    var result: ?[]RawMessage = null;
    while (it.next()) |l| switch (try p.processLine(l)) {
        .diagnostics_ready => |d| {
            if (result) |r| freeMessages(p.allocator, r);
            result = d;
        },
        else => {},
    };
    return result;
}

test "simple syntax error with underline" {
    const gpa = std.testing.allocator;
    var p = DiagnosticsParser.init(gpa, "/ws");
    defer p.deinit();

    const out =
        \\install
        \\+- install zig_test
        \\   +- compile exe zig_test debug native 1 errors
        \\src/main.zig:72:6: error: expected ',' after field
        \\this is a syntax error
        \\     ^~
        \\error: 1 compilation errors
        \\failed command: /zig build-exe -fincremental --listen=-
        \\
        \\Build Summary: 0/3 steps succeeded (1 failed)
        \\install transitive failure
    ;
    const d = (try feedAll(&p, out)).?;
    defer freeMessages(gpa, d);
    try std.testing.expectEqual(1, d.len);
    try std.testing.expectEqualStrings("src/main.zig", d[0].file_path);
    try std.testing.expectEqual(71, d[0].line);
    try std.testing.expectEqual(5, d[0].col);
    try std.testing.expectEqual(2, d[0].span_len);
    try std.testing.expectEqual(types.DiagnosticSeverity.Error, d[0].severity);

    try std.testing.expectEqual(BuildEvent.clean_success, try p.processLine("Build Summary: 3/3 steps succeeded"));
}

test "notes, reference traces and centered underlines" {
    const gpa = std.testing.allocator;
    var p = DiagnosticsParser.init(gpa, "/ws");
    defer p.deinit();

    const out =
        \\src/util/argz.zig:128:47: error: no field named 'fields' in struct 'lang.Type.Struct'
        \\    inline for (@typeInfo(HelpType).@"struct".fields) |f| {
        \\                                              ^~~~~~
        \\/zig/lib/std/lang.zig:750:24: note: struct declared here
        \\    pub const Struct = struct {
        \\                       ^~~~~~
        \\referenced by:
        \\    parse [inlined]: src/util/argz.zig:188:51
        \\    main: src/main.zig:169:30
        \\    4 reference(s) hidden; use '-freference-trace=6' to see all references
        \\src/util/zoto.zig:33:20: error: no field named 'fields' in struct 'lang.Type.Struct'
        \\            for (s.fields) |f| {
        \\                   ^~~~~~
        \\src/domain/proto.zig:192:31: note: called at comptime here
        \\pub const hash = zoto.hashType(@This());
        \\                 ~~~~~~~~~~~~~^~~~~~~~~
        \\error: 2 compilation errors
        \\Build Summary: 1/4 steps succeeded (1 failed)
    ;
    const d = (try feedAll(&p, out)).?;
    defer freeMessages(gpa, d);
    try std.testing.expectEqual(2, d.len);

    // First error: underline width 6 starting at the reported column.
    try std.testing.expectEqual(127, d[0].line);
    try std.testing.expectEqual(46, d[0].col);
    try std.testing.expectEqual(6, d[0].span_len);
    // One note + two reference-trace entries.
    try std.testing.expectEqual(3, d[0].notes.items.len);
    try std.testing.expectEqualStrings("struct declared here", d[0].notes.items[0].message);
    try std.testing.expectEqualStrings("file:///zig/lib/std/lang.zig", d[0].notes.items[0].location.uri);
    try std.testing.expectEqualStrings("referenced by parse [inlined]", d[0].notes.items[1].message);
    try std.testing.expectEqualStrings("file:///ws/src/main.zig", d[0].notes.items[2].location.uri);
    try std.testing.expectEqual(168, d[0].notes.items[2].location.range.start.line);

    // Second error's note has a centred underline `~~~~^~~~`.
    const n = d[1].notes.items[0];
    try std.testing.expectEqualStrings("called at comptime here", n.message);
    try std.testing.expectEqual(17, n.location.range.start.character);
    try std.testing.expectEqual(17 + 22, n.location.range.end.character);
}

test "failed build without locations yields empty set" {
    const gpa = std.testing.allocator;
    var p = DiagnosticsParser.init(gpa, "/ws");
    defer p.deinit();
    const d = (try feedAll(&p, "error: the following test command failed\nBuild Summary: 2/3 steps succeeded (1 failed)")).?;
    defer freeMessages(gpa, d);
    try std.testing.expectEqual(0, d.len);
}

test parseLocation {
    const l = parseLocation("C:\\proj\\src\\main.zig:10:4").?;
    try std.testing.expectEqualStrings("C:\\proj\\src\\main.zig", l.path);
    try std.testing.expectEqual(10, l.line);
    try std.testing.expectEqual(4, l.col);
    try std.testing.expect(parseLocation("Build Summary: 3/3") == null);
}
