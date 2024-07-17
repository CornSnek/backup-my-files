//! Structs where the .json file is parsed to.
const std = @import("std");
const FnSrc = @import("debug.zig").FnSrc;
const Logger = @import("Logger.zig");
const json_parser = @import("json_parser.zig");
const Error = json_parser.Error;
const json_scanner_next_debug = json_parser.json_scanner_next_debug;
const json_try_parse = json_parser.json_try_parse;
/// Assigns just the default values in a struct. Also returns an array to determine which fields have been assigned using a bool array.
pub fn init_partial(comptime T: type) struct { T, [std.meta.fields(T).len]bool } {
    var t: T = undefined;
    var b_arr: [std.meta.fields(T).len]bool = undefined;
    inline for (std.meta.fields(T), 0..) |field, i| {
        if (field.default_value) |dv| {
            @field(t, field.name) = @as(*const field.type, @alignCast(@ptrCast(dv))).*;
            b_arr[i] = true;
        } else b_arr[i] = false;
    }
    return .{ t, b_arr };
}
/// Gets a struct's field index number or return an error if not a valid key.
inline fn json_get_index_struct(comptime StructT: type, parent_key: []const u8, json_key: []const u8, json_d: *std.json.Diagnostics, logger: *Logger) !usize {
    const fields = comptime std.meta.fieldNames(StructT);
    for (0..fields.len) |i| {
        if (std.mem.eql(u8, json_key, fields[i])) return i;
    }
    logger.print(.err, null, "For the parent key '{s}', '{s}' is not a valid key. The only valid keys are the following: {s}\n(line {}, col {})\n", .{ parent_key, json_key, fields, json_d.getLine(), json_d.getColumn() });
    return Error.InvalidKey;
}
pub const JSONStruct = struct {
    /// The global output directory where the directory/tar files will be placed.
    output_dir: []const u8,
    /// Maximum number of backups that are stored in the output_dir before it deletes old files.
    max_backups: usize = 10,
    backups: []Backup,
    pub fn json_parse(arena: std.mem.Allocator, json_scanner: *std.json.Scanner, json_d: *std.json.Diagnostics, logger: *Logger) !@This() {
        var self: @This(), var b_arr: [std.meta.fields(@This()).len]bool = comptime init_partial(@This());
        if (try json_scanner_next_debug(FnSrc(@This(), @src()), json_scanner, logger) != .object_begin) {
            logger.print(.err, null, "No starting curly backet '{{' found\n(line {}, col {})\n", .{ json_d.getLine(), json_d.getColumn() });
            return Error.NoStartingCurlyBracket;
        }
        done_parse: while (true) {
            switch (try json_scanner_next_debug(FnSrc(@This(), @src()), json_scanner, logger)) {
                .string => |json_key| {
                    switch (try json_get_index_struct(@This(), "root", json_key, json_d, logger)) {
                        0 => |i| self.output_dir = try json_try_parse(@TypeOf(self.output_dir), &b_arr, i, arena, "root", json_scanner, json_key, json_d, logger),
                        1 => |i| {
                            self.max_backups = try json_try_parse(@TypeOf(self.max_backups), &b_arr, i, arena, "root", json_scanner, json_key, json_d, logger);
                            if (self.max_backups <= 5) {
                                logger.print(.err, null, "'{s}' may be too low. Recent old backups may be deleted too quickly.\n(line {}, col {})\n", .{ json_key, json_d.getLine(), json_d.getColumn() });
                            }
                        },
                        2 => |i| self.backups = try json_try_parse(@TypeOf(self.backups), &b_arr, i, arena, "root", json_scanner, json_key, json_d, logger),
                        else => unreachable,
                    }
                },
                .object_end => break :done_parse,
                else => return Error.UnexpectedToken,
            }
        }
        var missing_key = false;
        for (std.meta.fieldNames(@This()), 0..) |name, i| {
            if (!b_arr[i]) {
                logger.print(.err, null, "For the parent key (root), '{s}' is a missing required key.\n", .{name});
                missing_key = true;
            }
        }
        return if (missing_key) Error.RequiredMissingKey else self;
    }
};
pub const Backup = struct {
    pub const Type = union(enum) { directory: void, tar: ?CompressionType };
    name: []const u8,
    type: Type,
    /// The root directory where BackupFiles will find files/directories to backup.
    search_dir: []const u8,
    /// The output file name where the files are stored in the JSONStruct.output_dir
    /// Date format specifiers can be used. See `@import("date.zig").Date.to_str_format`
    /// This will be a directory or tar file based on 'type'
    output_name: []const u8,
    backup_files: []BackupFile,
    pub fn json_parse(parent_key: []const u8, arena: std.mem.Allocator, json_scanner: *std.json.Scanner, json_d: *std.json.Diagnostics, logger: *Logger) !@This() {
        var self: @This(), var b_arr: [std.meta.fields(@This()).len]bool = comptime init_partial(@This());
        if (try json_scanner_next_debug(FnSrc(@This(), @src()), json_scanner, logger) != .object_begin) {
            logger.print(.err, null, "For the parent key '{s}', No starting curly backet '{{' found\n(line {}, col {})\n", .{ parent_key, json_d.getLine(), json_d.getColumn() });
            return Error.NoStartingCurlyBracket;
        }
        done_parse: while (true) {
            switch (try json_scanner_next_debug(FnSrc(@This(), @src()), json_scanner, logger)) {
                .string => |json_key| {
                    switch (try json_get_index_struct(@This(), parent_key, json_key, json_d, logger)) { //TODO: Input validation
                        0 => |i| self.name = try json_try_parse(@TypeOf(self.name), &b_arr, i, arena, parent_key, json_scanner, json_key, json_d, logger),
                        1 => |i| self.type = try json_try_parse(@TypeOf(self.type), &b_arr, i, arena, parent_key, json_scanner, json_key, json_d, logger),
                        2 => |i| self.search_dir = try json_try_parse(@TypeOf(self.search_dir), &b_arr, i, arena, parent_key, json_scanner, json_key, json_d, logger),
                        3 => |i| self.output_name = try json_try_parse(@TypeOf(self.output_name), &b_arr, i, arena, parent_key, json_scanner, json_key, json_d, logger),
                        4 => |i| self.backup_files = try json_try_parse(@TypeOf(self.backup_files), &b_arr, i, arena, parent_key, json_scanner, json_key, json_d, logger),
                        else => unreachable,
                    }
                },
                .object_end => break :done_parse,
                else => return Error.UnexpectedToken,
            }
        }
        var missing_key = false;
        for (std.meta.fieldNames(@This()), 0..) |name, i| {
            if (!b_arr[i]) {
                logger.print(.err, null, "For the parent key '{s}', '{s}' is a missing required key.\n", .{ parent_key, name });
                missing_key = true;
            }
        }
        return if (missing_key) Error.RequiredMissingKey else self;
    }
};
pub const CompressionType = union(enum) {
    gzip: std.compress.flate.deflate.Level,
    zlib: std.compress.flate.deflate.Level,
    pub fn ext_name(self: CompressionType) []const u8 {
        return switch (self) {
            .gzip => ".gz",
            .zlib => ".zlib",
        };
    }
};
///Assuming this isn't an absolute path or symlinks are not used
fn path_is_outside(rel_path: []const u8) bool {
    var path_it = std.mem.tokenizeAny(u8, rel_path, "/\\");
    var depth: usize = 0;
    while (path_it.next()) |comp| {
        if (std.mem.eql(u8, comp, "..")) {
            if (depth == 0) return true;
            depth -= 1;
        } else depth += 1;
    }
    return false;
}
test path_is_outside {
    try std.testing.expect(path_is_outside(".."));
    try std.testing.expect(!path_is_outside("a/.."));
    try std.testing.expect(path_is_outside("a\\..\\.."));
    try std.testing.expect(!path_is_outside("a/b/c/../../def/../.."));
}
pub const BackupFile = struct {
    /// The file or directory releative to JSONStruct.search_dir where it is copied to JSONStruct.output_dir.
    /// It must be a relative path.
    name: []const u8,
    /// The number of nested components this backup should limit in searching.
    /// e.g. If dir_limit is 4, a/b/c/d will be searched, but a/b/c/d/e will not be searched.
    /// Default is null (no limit).
    dir_limit: ?u16 = null,
    filters: ?[]Filter = null,
    pub fn json_parse(parent_key: []const u8, arena: std.mem.Allocator, json_scanner: *std.json.Scanner, json_d: *std.json.Diagnostics, logger: *Logger) !@This() {
        var self: @This(), var b_arr: [std.meta.fields(@This()).len]bool = comptime init_partial(@This());
        if (try json_scanner_next_debug(FnSrc(@This(), @src()), json_scanner, logger) != .object_begin) {
            logger.print(.err, null, "For the parent key '{s}', No starting curly backet '{{' found\n(line {}, col {})\n", .{ parent_key, json_d.getLine(), json_d.getColumn() });
            return Error.NoStartingCurlyBracket;
        }
        done_parse: while (true) {
            switch (try json_scanner_next_debug(FnSrc(@This(), @src()), json_scanner, logger)) {
                .string => |json_key| {
                    switch (try json_get_index_struct(@This(), parent_key, json_key, json_d, logger)) {
                        0 => |i| {
                            self.name = try json_try_parse(@TypeOf(self.name), &b_arr, i, arena, parent_key, json_scanner, json_key, json_d, logger);
                            if (std.fs.path.isAbsolute(self.name)) {
                                logger.print(.err, null, "'name' must be a path relative to 'search_dir' only. \n(line {}, col {})\n", .{ json_d.getLine(), json_d.getColumn() });
                                return error.PathShouldBeRelative;
                            }
                            if (path_is_outside(self.name)) {
                                logger.print(.err, null, "'name' cannot be a path outside 'search_dir. \n(line {}, col {})\n", .{ json_d.getLine(), json_d.getColumn() });
                                return error.PathOutsideSearchDirectory;
                            }
                        },
                        1 => |i| self.dir_limit = try json_try_parse(@TypeOf(self.dir_limit), &b_arr, i, arena, parent_key, json_scanner, json_key, json_d, logger),
                        2 => |i| self.filters = try json_try_parse(@TypeOf(self.filters), &b_arr, i, arena, parent_key, json_scanner, json_key, json_d, logger),
                        else => unreachable,
                    }
                },
                .object_end => break :done_parse,
                else => return Error.UnexpectedToken,
            }
        }
        var missing_key = false;
        for (std.meta.fieldNames(@This()), 0..) |name, i| {
            if (!b_arr[i]) {
                logger.print(.err, null, "For the parent key '{s}', '{s}' is a missing required key.\n", .{ parent_key, name });
                missing_key = true;
            }
        }
        return if (missing_key) Error.RequiredMissingKey else self;
    }
};
pub const Filter = struct {
    pub const Type = enum { include, exclude };
    pub const Component = enum { file, directory, all };
    pub const DepthLimit = union(enum) {
        none: void,
        gte: u16,
        lte: u16,
        range: FilterRange,
    };
    /// The types of files the filter would affect when searching. Valid types "file", "directory", "all". Default is "file"
    component: Component = .file,
    /// "include" will allow the file to be copied if it matches the filter, while "exclude" disallows if it matches.
    type: Type,
    /// String to include/exclude for a filename. Limited regular expressions are included and described below:
    /// - `^` can be appended at the beginning to let the filter search only at the beginning of the filename.
    /// - `$` can be appended at the end to let the filter search only at the end of the filename.
    /// - `|` can be used to allow multiple or alternating values. If at least one word has been accepted, pass the filter if .include, or fail if .exclude.
    ///     - Parenthesis enclosing the alternating values are required for `|`. Example `(ab|cde|fghi)` in an .include filter allows filenames containing either ab, cde, or fghi.
    ///     - Can be combined with both `^` and `$` anchors to allow either one filename exactly specified in the group.
    ///
    /// Value examples using special characters: `word`, `^prefix`, `.txt$`, `(one|two|three)`, `(.py|.zig|.c)$`, `^(main.zig|build.zig)$`
    value: []const u8,
    /// Determines the directory depth of when the filter should be active. For example, .none allows all depths, .gte and .lte affects the
    /// directories greater or equal than or less than or equal to the current depth respectively. .range is a combination of both.
    depth_limit: DepthLimit = .none,
    pub fn json_parse(parent_key: []const u8, arena: std.mem.Allocator, json_scanner: *std.json.Scanner, json_d: *std.json.Diagnostics, logger: *Logger) !@This() {
        var self: @This(), var b_arr: [std.meta.fields(@This()).len]bool = comptime init_partial(@This());
        if (try json_scanner_next_debug(FnSrc(@This(), @src()), json_scanner, logger) != .object_begin) {
            logger.print(.err, null, "For the parent key '{s}', No starting curly backet '{{' found\n(line {}, col {})\n", .{ parent_key, json_d.getLine(), json_d.getColumn() });
            return Error.NoStartingCurlyBracket;
        }
        done_parse: while (true) {
            switch (try json_scanner_next_debug(FnSrc(@This(), @src()), json_scanner, logger)) {
                .string => |json_key| {
                    switch (try json_get_index_struct(@This(), parent_key, json_key, json_d, logger)) {
                        0 => |i| self.component = try json_try_parse(@TypeOf(self.component), &b_arr, i, arena, parent_key, json_scanner, json_key, json_d, logger),
                        1 => |i| self.type = try json_try_parse(@TypeOf(self.type), &b_arr, i, arena, parent_key, json_scanner, json_key, json_d, logger),
                        2 => |i| self.value = try json_try_parse(@TypeOf(self.value), &b_arr, i, arena, parent_key, json_scanner, json_key, json_d, logger),
                        3 => |i| self.depth_limit = try json_try_parse(@TypeOf(self.depth_limit), &b_arr, i, arena, parent_key, json_scanner, json_key, json_d, logger),
                        else => unreachable,
                    }
                },
                .object_end => break :done_parse,
                else => return Error.UnexpectedToken,
            }
        }
        var missing_key = false;
        for (std.meta.fieldNames(@This()), 0..) |name, i| {
            if (!b_arr[i]) {
                logger.print(.err, null, "For the parent key '{s}', '{s}' is a missing required key.\n", .{ parent_key, name });
                missing_key = true;
            }
        }
        return if (missing_key) Error.RequiredMissingKey else self;
    }
    pub fn format(self: @This(), comptime _: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.writeAll(@typeName(@This()) ++ "{ ");
        try std.fmt.format(writer, ".{s}", .{@tagName(self.component)});
        try writer.writeAll(", ");
        try std.fmt.format(writer, ".{s}", .{@tagName(self.type)});
        try writer.writeAll(", '");
        try std.fmt.formatBuf(self.value, options, writer);
        try writer.writeAll("', depth_limit = ");
        try std.fmt.format(writer, ".{s}", .{@tagName(self.depth_limit)});
        try writer.writeByte('{');
        switch (self.depth_limit) {
            .none => {},
            .lte, .gte => |v| try std.fmt.format(writer, " [{}] ", .{v}),
            .range => |fr| try std.fmt.format(writer, " [{}, {}] ", .{ fr.min, fr.max }),
        }
        try writer.writeAll("} }");
    }
};
pub const FilterRange = struct {
    min: u16,
    max: u16,
    pub fn json_parse(parent_key: []const u8, arena: std.mem.Allocator, json_scanner: *std.json.Scanner, json_d: *std.json.Diagnostics, logger: *Logger) !@This() {
        var self: @This(), var b_arr: [std.meta.fields(@This()).len]bool = comptime init_partial(@This());
        if (try json_scanner_next_debug(FnSrc(@This(), @src()), json_scanner, logger) != .object_begin) {
            logger.print(.err, null, "For the parent key '{s}', No starting curly backet '{{' found\n(line {}, col {})\n", .{ parent_key, json_d.getLine(), json_d.getColumn() });
            return Error.NoStartingCurlyBracket;
        }
        done_parse: while (true) {
            switch (try json_scanner_next_debug(FnSrc(@This(), @src()), json_scanner, logger)) {
                .string => |json_key| {
                    switch (try json_get_index_struct(@This(), parent_key, json_key, json_d, logger)) {
                        0 => |i| self.min = try json_try_parse(@TypeOf(self.min), &b_arr, i, arena, parent_key, json_scanner, json_key, json_d, logger),
                        1 => |i| self.max = try json_try_parse(@TypeOf(self.max), &b_arr, i, arena, parent_key, json_scanner, json_key, json_d, logger),
                        else => unreachable,
                    }
                },
                .object_end => break :done_parse,
                else => return Error.UnexpectedToken,
            }
        }
        var missing_key = false;
        for (std.meta.fieldNames(@This()), 0..) |name, i| {
            if (!b_arr[i]) {
                logger.print(.err, null, "For the parent key '{s}', '{s}' is a missing required key.\n", .{ parent_key, name });
                missing_key = true;
            }
        }
        return if (missing_key) Error.RequiredMissingKey else self;
    }
};
