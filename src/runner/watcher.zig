//! Supervises a long-running `zig build ... --watch` child process.
//!
//! A single worker thread owns the child: it spawns it, streams its stderr
//! line-by-line into a `DiagnosticsParser`, waits for it to exit, and then
//! restarts it (with backoff) until `stop` is called. `zig build --watch`
//! exits on its own when `build.zig` itself fails to compile, so the restart
//! loop is what keeps diagnostics flowing after you fix `build.zig`.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const types = @import("../lsp/types.zig");
const diagnostics = @import("../parser/diagnostics.zig");

pub const EventFn = *const fn (ctx: *anyopaque, event: diagnostics.BuildEvent) void;
pub const LogFn = *const fn (ctx: *anyopaque, msg: []const u8) void;

pub const Watcher = struct {
    gpa: Allocator,
    io: Io,
    workspace_root: []const u8,
    /// Fully resolved argv (owned).
    argv: []const []const u8,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = .init(false),
    /// pid of the currently running child, 0 if none.
    child_pid: std.atomic.Value(i32) = .init(0),
    wake_flag: std.atomic.Value(bool) = .init(false),
    ctx: *anyopaque,
    on_event: EventFn,
    on_log: LogFn,

    pub fn init(
        gpa: Allocator,
        io: Io,
        workspace_root: []const u8,
        config: types.Config,
        ctx: *anyopaque,
        on_event: EventFn,
        on_log: LogFn,
    ) !Watcher {
        return .{
            .gpa = gpa,
            .io = io,
            .workspace_root = workspace_root,
            .argv = try buildArgv(gpa, config),
            .ctx = ctx,
            .on_event = on_event,
            .on_log = on_log,
        };
    }

    pub fn deinit(self: *Watcher) void {
        self.stop();
        for (self.argv) |a| self.gpa.free(a);
        self.gpa.free(self.argv);
    }

    pub fn start(self: *Watcher) !void {
        if (self.running.swap(true, .acq_rel)) return;
        self.thread = try std.Thread.spawn(.{}, worker, .{self});
    }

    pub fn stop(self: *Watcher) void {
        if (!self.running.swap(false, .acq_rel)) return;
        self.killChild();
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn killChild(self: *Watcher) void {
        if (builtin.os.tag == .windows) return; // TODO
        const pid = self.child_pid.load(.acquire);
        if (pid <= 0) return;
        // The child was spawned as a process-group leader, so signal the
        // whole group: this also reaps the `zig build-exe --listen=-`
        // compiler servers that the build runner spawned.
        std.posix.kill(-pid, .TERM) catch {
            std.posix.kill(pid, .TERM) catch {};
        };
    }

    fn worker(self: *Watcher) void {
        var backoff_ms: u32 = 500;
        while (self.running.load(.acquire)) {
            const started = Io.Timestamp.now(self.io, .awake).toMilliseconds();
            self.runOnce() catch |err| {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "zbls: failed to run zig build: {t}", .{err}) catch "zbls: failed to run zig build";
                self.on_log(self.ctx, msg);
            };
            if (!self.running.load(.acquire)) break;

            // Reset backoff if the child lived for a while.
            const elapsed = Io.Timestamp.now(self.io, .awake).toMilliseconds() - started;
            if (elapsed > 10_000) backoff_ms = 500;
            self.sleepInterruptible(backoff_ms);
            backoff_ms = @min(backoff_ms * 2, 10_000);
        }
    }

    fn sleepInterruptible(self: *Watcher, ms: u32) void {
        var left = ms;
        while (left > 0 and self.running.load(.acquire)) {
            if (self.wake_flag.swap(false, .acq_rel)) return;
            const step = @min(left, 100);
            self.io.sleep(.fromMilliseconds(step), .awake) catch return;
            left -= step;
        }
    }

    /// Ask the worker to restart `zig build` right away if it is currently
    /// waiting out a restart backoff (e.g. after `build.zig` was saved).
    pub fn wake(self: *Watcher) void {
        if (self.child_pid.load(.acquire) == 0) self.wake_flag.store(true, .release);
    }

    fn runOnce(self: *Watcher) !void {
        var child = try std.process.spawn(self.io, .{
            .argv = self.argv,
            .cwd = .{ .path = self.workspace_root },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .pipe,
            .pgid = if (builtin.os.tag == .windows) null else 0,
        });
        if (builtin.os.tag != .windows) {
            if (child.id) |pid| self.child_pid.store(pid, .release);
        }
        defer self.child_pid.store(0, .release);

        // Race: stop() may have been called between spawn and storing the pid.
        if (!self.running.load(.acquire)) self.killChild();

        var parser = diagnostics.DiagnosticsParser.init(self.gpa, self.workspace_root);
        defer parser.deinit();

        const stderr_file = child.stderr.?;
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.gpa);
        var chunk: [4096]u8 = undefined;

        while (true) {
            const n = stderr_file.readStreaming(self.io, &.{&chunk}) catch break;
            if (n == 0) break;
            for (chunk[0..n]) |c| {
                if (c == '\n') {
                    self.feed(&parser, line.items);
                    line.clearRetainingCapacity();
                } else if (line.items.len < 64 * 1024) {
                    try line.append(self.gpa, c);
                }
            }
        }
        if (line.items.len > 0) self.feed(&parser, line.items);
        if (parser.flush() catch null) |ev| {
            if (ev != .none) self.on_event(self.ctx, ev);
        }

        const term = child.wait(self.io) catch return;
        if (self.running.load(.acquire)) {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "zbls: zig build {f}; restarting", .{term}) catch "zbls: zig build exited; restarting";
            self.on_log(self.ctx, msg);
        }
    }

    fn feed(self: *Watcher, parser: *diagnostics.DiagnosticsParser, raw: []const u8) void {
        const event = parser.processLine(raw) catch return;
        if (event != .none) self.on_event(self.ctx, event);
    }
};

/// `[zig_path] ++ build_args ++ extra_args ++ [--debounce N]`, all owned by `gpa`.
pub fn buildArgv(gpa: Allocator, config: types.Config) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |a| gpa.free(a);
        list.deinit(gpa);
    }
    try list.append(gpa, try gpa.dupe(u8, config.zig_path));
    for (config.build_args) |a| try list.append(gpa, try gpa.dupe(u8, a));
    for (config.extra_args) |a| try list.append(gpa, try gpa.dupe(u8, a));
    if (config.debounce_ms) |ms| {
        try list.append(gpa, try gpa.dupe(u8, "--debounce"));
        try list.append(gpa, try std.fmt.allocPrint(gpa, "{d}", .{ms}));
    }
    return list.toOwnedSlice(gpa);
}

test buildArgv {
    const gpa = std.testing.allocator;
    const argv = try buildArgv(gpa, .{ .extra_args = &.{"-Dfoo"}, .debounce_ms = 50 });
    defer {
        for (argv) |a| gpa.free(a);
        gpa.free(argv);
    }
    try std.testing.expectEqualStrings("zig", argv[0]);
    try std.testing.expectEqualStrings("build", argv[1]);
    try std.testing.expectEqualStrings("-Dfoo", argv[argv.len - 3]);
    try std.testing.expectEqualStrings("--debounce", argv[argv.len - 2]);
    try std.testing.expectEqualStrings("50", argv[argv.len - 1]);
}
