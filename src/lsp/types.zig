const std = @import("std");

pub const Position = struct {
    line: u32,
    character: u32,
};

pub const Range = struct {
    start: Position,
    end: Position,
};

pub const Location = struct {
    uri: []const u8,
    range: Range,
};

pub const DiagnosticSeverity = enum(u8) {
    Error = 1,
    Warning = 2,
    Information = 3,
    Hint = 4,
};

pub const DiagnosticRelatedInformation = struct {
    location: Location,
    message: []const u8,
};

pub const Diagnostic = struct {
    range: Range,
    severity: DiagnosticSeverity = .Error,
    source: []const u8 = "zig-build",
    message: []const u8,
    relatedInformation: ?[]const DiagnosticRelatedInformation = null,
};

pub const PublishDiagnosticsParams = struct {
    uri: []const u8,
    diagnostics: []const Diagnostic,
};

pub const Config = struct {
    zig_path: []const u8 = "zig",
    build_args: []const []const u8 = &.{ "build", "-fincremental", "--watch" },
    extra_args: []const []const u8 = &.{},
    debounce_ms: ?u32 = null,
};
