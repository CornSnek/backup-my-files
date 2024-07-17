const std = @import("std");
const date = @import("date.zig");
pub const ScopeEnumArray = std.EnumArray(LoggerScope, bool);
pub const BufferedWriter = std.io.BufferedWriter(512, std.fs.File.Writer);
stdout_writer: BufferedWriter,
stderr_writer: BufferedWriter,
timezone: i8,
scope: ScopeEnumArray,
disable: bool,
len_scope_print: usize,
pub fn init(stdout: std.fs.File, stderr: std.fs.File, scope: ?ScopeEnumArray, disable: ?bool) @This() {
    return .{
        .stdout_writer = .{ .unbuffered_writer = stdout.writer() },
        .stderr_writer = .{ .unbuffered_writer = stderr.writer() },
        .timezone = 0,
        .scope = scope orelse ScopeEnumArray.initFill(false),
        .disable = disable orelse false,
        .len_scope_print = 0,
    };
}
pub fn print(self: *@This(), comptime log_type: std.log.Level, comptime scope: ?LoggerScope, comptime format: []const u8, args: anytype) void {
    if (@import("builtin").is_test) {
        if (self.disable) return;
        if (scope) |s| if (!self.scope.get(s)) return;
        std.debug.print("[Test " ++ log_type.asText() ++ "] " ++ format, args);
    } else {
        if (self.disable) return;
        if (scope) |s| if (!self.scope.get(s)) return;
        const use_bw: *BufferedWriter = if (log_type != .err) &self.stdout_writer else &self.stderr_writer;
        if (log_type == .err) std.debug.lockStdErr();
        defer if (log_type == .err) std.debug.unlockStdErr();
        (b: {
            const date_now = date.Date.init_with_timezone(std.time.timestamp(), self.timezone);
            var time_buf: [8]u8 = undefined;
            use_bw.writer().print("[ {s}, ", .{std.fmt.bufPrint(&time_buf, "{:0>2}:{:0>2}:{:0>2}", .{
                date_now.hour,
                date_now.minute,
                date_now.second,
            }) catch |e| break :b e}) catch |e| break :b e;
            var scope_buf: [20]u8 = undefined;
            const scope_str = std.fmt.bufPrint(&scope_buf, "{s}", .{comptime log_type.asText() ++ std.fmt.comptimePrint("{s}", .{if (scope) |s| ", " ++ @tagName(s) else ""})}) catch |e| break :b e;
            self.len_scope_print = @max(scope_str.len, self.len_scope_print); //The code below widens the left alignment depending on the previous max length of the log_type and scope tagName() strings.
            use_bw.writer().print("{[scope]s:<[width]} ] ", .{ .scope = scope_str, .width = self.len_scope_print }) catch |e| break :b e;
            use_bw.writer().print(format, args) catch |e| break :b e;
            use_bw.flush() catch |e| break :b e;
        }) catch use_bw.flush() catch return;
    }
}
/// Partially set variables for tests with printing everything enabled by default.
pub fn partial_init(self: *@This()) void {
    self.disable = false;
    self.scope = std.EnumArray(LoggerScope, bool).initFill(true);
}
pub const LoggerScope = enum { JSON, FileExtra, Filters };
