const std = @import("std");
const Logger = @import("Logger.zig");
pub const ArgsOptions = struct {
    scope_array: Logger.ScopeEnumArray = Logger.ScopeEnumArray.initFill(false),
    json_file: ?[]const u8 = null,
    filter_backup: ?[]const u8 = null,
    disable: bool = false,
    print_only: bool = false,
    pub fn deinit(self: ArgsOptions, allocator: std.mem.Allocator) void {
        if (self.json_file) |jf| allocator.free(jf);
        if (self.filter_backup) |fb| allocator.free(fb);
    }
};
const ArgsState = enum { continue_loop, exit_loop, abort_program };
const StdOutBW = std.io.BufferedWriter(4096, @TypeOf(std.io.getStdOut().writer()));
const ArgsFns = std.StaticStringMap(*const fn (
    allocator: std.mem.Allocator,
    output: *StdOutBW,
    arg: []const u8,
    args: []const []const u8,
    args_i: *usize,
    args_options: *ArgsOptions,
) anyerror!ArgsState).initComptime(.{
    .{ "-h", arg_usage },   .{ "--help", arg_usage },
    .{ "-i", arg_input },   .{ "--input", arg_input },
    .{ "-l", arg_logs },    .{ "--logs", arg_logs },
    .{ "-q", arg_quiet },   .{ "--quiet", arg_quiet },
    .{ "-v", arg_verbose }, .{ "--verbose", arg_verbose },
    .{ "-k", arg_keys },    .{ "--keys", arg_keys },
    .{ "-p", arg_print },   .{ "--print", arg_print },
    .{ "-b", arg_backup },  .{ "--backup", arg_backup },
});
fn discard_non_options(args: []const []const u8, args_i: *usize) void {
    while (true) {
        const str = args[args_i.*];
        if (ArgsFns.has(str)) return;
        args_i.* += 1;
        if (args_i.* == args.len) return;
    }
}
fn next_arg(e: enum { exc_opt, inc_opt, peek }, args: []const []const u8, args_i: *usize) ?[]const u8 {
    if (args_i.* == args.len) return null;
    const str = args[args_i.*];
    if (e == .exc_opt) if (ArgsFns.has(str)) return null;
    if (e != .peek) args_i.* += 1;
    return str;
}
fn arg_usage(_: std.mem.Allocator, output: *StdOutBW, _: []const u8, _: []const []const u8, _: *usize, _: *ArgsOptions) !ArgsState {
    try output.writer().print(@embedFile("arg_input/usage.txt"), .{});
    return .abort_program;
}
fn arg_keys(_: std.mem.Allocator, output: *StdOutBW, _: []const u8, _: []const []const u8, _: *usize, _: *ArgsOptions) !ArgsState {
    try output.writer().print(@embedFile("arg_input/keys.txt"), .{});
    return .abort_program;
}
fn arg_input(allocator: std.mem.Allocator, output: *StdOutBW, arg: []const u8, args: []const []const u8, args_i: *usize, args_options: *ArgsOptions) !ArgsState {
    if (args_options.json_file != null) {
        try output.writer().print("Warning: {s} is already set. Currently set to '{s}'\n", .{ arg, args_options.json_file.? });
        discard_non_options(args, args_i);
        return .continue_loop;
    }
    const json_file = next_arg(.exc_opt, args, args_i) orelse {
        try output.writer().print("json argument for {s} is required, found '{s}' (An option or null)\n", .{ arg, next_arg(.peek, args, args_i) orelse "null" });
        return .abort_program;
    };
    args_options.json_file = try allocator.dupe(u8, json_file);
    return .continue_loop;
}
fn arg_backup(allocator: std.mem.Allocator, output: *StdOutBW, arg: []const u8, args: []const []const u8, args_i: *usize, args_options: *ArgsOptions) !ArgsState {
    if (args_options.filter_backup != null) {
        try output.writer().print("Warning: {s} is already set. Currently set to '{s}'\n", .{ arg, args_options.filter_backup.? });
        discard_non_options(args, args_i);
        return .continue_loop;
    }
    const filter_backup = next_arg(.exc_opt, args, args_i) orelse {
        try output.writer().print("Backup name for {s} is required, found '{s}' (An option or null)\n", .{ arg, next_arg(.peek, args, args_i) orelse "null" });
        return .abort_program;
    };
    args_options.filter_backup = try allocator.dupe(u8, filter_backup);
    return .continue_loop;
}
fn arg_logs(_: std.mem.Allocator, output: *StdOutBW, arg: []const u8, args: []const []const u8, args_i: *usize, args_options: *ArgsOptions) !ArgsState {
    const logs = next_arg(.exc_opt, args, args_i) orelse {
        try output.writer().print("{s} values for {s} are required, found '{s}' (An option or null)\\n", .{ std.meta.fieldNames(Logger.LoggerScope), arg, next_arg(.peek, args, args_i) orelse "null" });
        return .abort_program;
    };
    var logs_it = std.mem.tokenizeScalar(u8, logs, '/');
    while (logs_it.next()) |log| {
        var is_valid: bool = false;
        inline for (std.meta.fields(Logger.LoggerScope)) |f| {
            if (std.mem.eql(u8, f.name, log)) {
                args_options.scope_array.set(@enumFromInt(f.value), true);
                is_valid = true;
            }
        }
        if (!is_valid) try output.writer().print("Warning: '{s}' is not a valid scope field for {s}\n", .{ log, arg });
    }
    return .continue_loop;
}
fn arg_verbose(_: std.mem.Allocator, _: *StdOutBW, _: []const u8, _: []const []const u8, _: *usize, args_options: *ArgsOptions) !ArgsState {
    args_options.scope_array = Logger.ScopeEnumArray.initFill(true);
    return .continue_loop;
}
fn arg_quiet(_: std.mem.Allocator, _: *StdOutBW, _: []const u8, _: []const []const u8, _: *usize, args_options: *ArgsOptions) !ArgsState {
    args_options.disable = true;
    return .continue_loop;
}
fn arg_print(_: std.mem.Allocator, _: *StdOutBW, _: []const u8, _: []const []const u8, _: *usize, args_options: *ArgsOptions) !ArgsState {
    args_options.print_only = true;
    return .continue_loop;
}
fn arg_invalid(allocator: std.mem.Allocator, output: *StdOutBW, arg: []const u8, args: []const []const u8, args_i: *usize, args_options: *ArgsOptions) !ArgsState {
    try output.writer().print("Invalid option '{s}' at argument #{}. See -h for help\n", .{ arg, args_i.* - 1 });
    return arg_usage(allocator, output, &.{}, args, args_i, args_options);
}
/// true if exiting the program immediately
pub fn parse_args(allocator: std.mem.Allocator, args_options: *ArgsOptions) !bool {
    var output = std.io.bufferedWriter(std.io.getStdOut().writer());
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    var args_i: usize = 1; //Skip binary path.
    if (args.len == 1) {
        _ = try arg_usage(allocator, &output, &.{}, args, &args_i, args_options);
        try output.flush();
        return true;
    }
    while (true) {
        const arg = next_arg(.inc_opt, args, &args_i) orelse return false;
        const status = try (ArgsFns.get(arg) orelse arg_invalid)(allocator, &output, arg, args, &args_i, args_options);
        try output.flush();
        switch (status) {
            .continue_loop => {},
            .exit_loop => return false,
            .abort_program => return true,
        }
    }
}
