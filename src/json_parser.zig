//! This parser is based from `std.json.innerParse` and `std.json.innerParseFromValue`
const std = @import("std");
const FnSrc = @import("debug.zig").FnSrc;
const Logger = @import("Logger.zig");
pub const Error = error{
    InvalidKey,
    InvalidValue,
    NoStartingCurlyBracket,
    NoEndingCurlyBracket,
    UnimplementedZigType,
    UnexpectedToken,
    RequiredMissingKey,
};
const DoScannerDebug: bool = true;
/// Wrapper of json_scanner.next() for debugging. FnName tries to tell where the function json_scanner_next_debug is called.
pub inline fn json_scanner_next_debug(comptime FnName: []const u8, json_scanner: *std.json.Scanner, logger: *Logger) !std.json.Token {
    const token = try json_scanner.next();
    if (DoScannerDebug) {
        switch (token) {
            .number, .string, .partial_string => |str| logger.print(.debug, .JSON, "{s:<80} {s}\n", .{ FnName, str }),
            else => logger.print(.debug, .JSON, "{s:<80} {any}\n", .{ FnName, token }),
        }
    }
    return token;
}
/// Parse json integers or optional integers.
inline fn json_try_parse_int(
    comptime IntT: type,
    assign_arr: []bool,
    assign_i: usize,
    parent_key: []const u8,
    json_scanner: *std.json.Scanner,
    json_key: []const u8,
    json_d: *std.json.Diagnostics,
    logger: *Logger,
) !IntT {
    const token_type = try json_scanner.peekNextTokenType();
    if (token_type != .number) {
        logger.print(.err, null, "For the parent key '{s}', Key '{s}' should be a number type\n(line {}, col {})\n", .{ parent_key, json_key, json_d.getLine(), json_d.getColumn() });
        return Error.InvalidValue;
    }
    assign_arr[assign_i] = true;
    const token = try json_scanner_next_debug(FnSrc(@This(), @src()), json_scanner, logger);
    return try std.fmt.parseInt(IntT, token.number, 10);
}
/// Parse json strings ([]const u8) or optional strings.
/// alloc is false if the string is used to assign a variable other than a string.
inline fn json_try_parse_string(
    assign_arr: []bool,
    assign_i: usize,
    parent_key: []const u8,
    arena: std.mem.Allocator,
    json_scanner: *std.json.Scanner,
    json_key: []const u8,
    json_d: *std.json.Diagnostics,
    logger: *Logger,
) ![]const u8 {
    const token_type = try json_scanner.peekNextTokenType();
    if (token_type != .string) {
        logger.print(.err, null, "For the parent key '{s}', Key '{s}' should be a string type\n(line {}, col {})\n", .{ parent_key, json_key, json_d.getLine(), json_d.getColumn() });
        return Error.InvalidValue;
    }
    var new_str = try arena.alloc(u8, 0);
    while (true) {
        const token = try json_scanner_next_debug(FnSrc(@This(), @src()), json_scanner, logger);
        switch (token) {
            .string => |s| {
                const old_new_str_len: usize = new_str.len;
                new_str = try arena.realloc(new_str, new_str.len + s.len);
                @memcpy(new_str[old_new_str_len..], s);
                assign_arr[assign_i] = true;
                return new_str;
            },
            .partial_string => |s| {
                const old_new_str_len: usize = new_str.len;
                new_str = try arena.realloc(new_str, new_str.len + s.len);
                @memcpy(new_str[old_new_str_len..], s);
            },
            else => return error.UnexpectedToken,
        }
    }
}
/// Similar to json_try_parse_string, but it requires that the string is one of the enum names.
inline fn json_try_parse_enum(
    comptime EnumT: type,
    assign_arr: []bool,
    assign_i: usize,
    parent_key: []const u8,
    json_scanner: *std.json.Scanner,
    json_key: []const u8,
    json_d: *std.json.Diagnostics,
    logger: *Logger,
) !EnumT {
    const token_type = try json_scanner.peekNextTokenType();
    if (token_type != .string) {
        logger.print(.err, null, "For the parent key '{s}', Key '{s}' should be a string type\n(line {}, col {})\n", .{
            parent_key,
            json_key,
            json_d.getLine(),
            json_d.getColumn(),
        });
        return Error.InvalidValue;
    }
    const token = try json_scanner_next_debug(FnSrc(@This(), @src()), json_scanner, logger);
    const e = std.meta.stringToEnum(EnumT, token.string) orelse {
        logger.print(.err, null, "For the parent key '{s}', Key '{s}' should only have the following values: {s}\n(line {}, col {})\n", .{
            parent_key,
            json_key,
            comptime std.meta.fieldNames(EnumT),
            json_d.getLine(),
            json_d.getColumn(),
        });
        return Error.InvalidValue;
    };
    assign_arr[assign_i] = true;
    return e;
}
/// Parse json boolean (true or false).
inline fn json_try_parse_bool(
    assign_arr: []bool,
    assign_i: usize,
    parent_key: []const u8,
    json_scanner: *std.json.Scanner,
    json_key: []const u8,
    json_d: *std.json.Diagnostics,
    logger: *Logger,
) !bool {
    const token_type = try json_scanner.peekNextTokenType();
    if (!(token_type == .true or token_type == .false)) {
        logger.print(.err, null, "For the parent key '{s}', Key '{s}' should be a boolean\n(line {}, col {})\n", .{
            parent_key,
            json_key,
            json_d.getLine(),
            json_d.getColumn(),
        });
        return Error.InvalidValue;
    }
    assign_arr[assign_i] = true;
    const token = try json_scanner_next_debug(FnSrc(@This(), @src()), json_scanner, logger);
    return switch (token) {
        .true => true,
        .false => false,
        else => unreachable,
    };
}
/// Parse json arrays.
inline fn json_try_parse_slice(
    comptime ArrayT: type,
    assign_arr: []bool,
    assign_i: usize,
    arena: std.mem.Allocator,
    json_scanner: *std.json.Scanner,
    json_to_parent_key: []const u8,
    json_d: *std.json.Diagnostics,
    logger: *Logger,
) !ArrayT {
    //json_try_parse already checked if this is a slice. Discarding token.
    _ = try json_scanner_next_debug(FnSrc(@This(), @src()), json_scanner, logger);
    const T = std.meta.Child(ArrayT);
    var array = try arena.alloc(T, 0);
    while (true) {
        if (try json_scanner.peekNextTokenType() == .array_end) {
            _ = try json_scanner_next_debug(FnSrc(@This(), @src()), json_scanner, logger); //Discard .array_end
            assign_arr[assign_i] = true;
            return array;
        } else {
            array = try arena.realloc(array, array.len + 1);
            array[array.len - 1] = try json_try_parse(T, assign_arr, assign_i, arena, json_to_parent_key, json_scanner, "(N/A)", json_d, logger);
        }
    }
}
/// Parse unions.
inline fn json_try_parse_union(
    comptime UnionT: type,
    assign_arr: []bool,
    assign_i: usize,
    arena: std.mem.Allocator,
    json_scanner: *std.json.Scanner,
    json_to_parent_key: []const u8,
    json_d: *std.json.Diagnostics,
    logger: *Logger,
) !UnionT {
    if (@typeInfo(UnionT).Union.tag_type == null) @compileError(std.fmt.comptimePrint("Type '{any}' must be a tagged union or union(enum) type", .{UnionT}));
    const token = try json_scanner_next_debug(FnSrc(@This(), @src()), json_scanner, logger);
    if (token != .object_begin) {
        logger.print(.err, null, "No starting curly backet '{{' found\n(line {}, col {})\n", .{ json_d.getLine(), json_d.getColumn() });
        return Error.NoStartingCurlyBracket;
    }
    const enum_key = try json_scanner_next_debug(FnSrc(@This(), @src()), json_scanner, logger);
    if (enum_key != .string) return Error.UnexpectedToken;
    var use_union: UnionT = undefined;
    inline for (std.meta.fields(UnionT)) |field| {
        if (std.mem.eql(u8, field.name, enum_key.string)) {
            if (field.type == void) {
                if (try json_scanner_next_debug(FnSrc(@This(), @src()), json_scanner, logger) != .object_begin or try json_scanner_next_debug(FnSrc(@This(), @src()), json_scanner, logger) != .object_end) {
                    logger.print(.err, null, "For the parent key '{s}', '{s}' should be an object with no parameters (only {{}})\n(line {}, col {})\n", .{
                        json_to_parent_key,
                        enum_key.string,
                        json_d.getLine(),
                        json_d.getColumn(),
                    });
                    return Error.UnexpectedToken;
                }
                use_union = @unionInit(UnionT, field.name, {});
            } else use_union = @unionInit(UnionT, field.name, try json_try_parse(field.type, assign_arr, assign_i, arena, json_to_parent_key, json_scanner, enum_key.string, json_d, logger));
            break;
        }
    } else {
        logger.print(.err, null, "For the parent key '{s}', '{s}' is not a valid key. The only valid keys are the following: {s}\n(line {}, col {})\n", .{
            json_to_parent_key,
            enum_key.string,
            comptime std.meta.fieldNames(UnionT),
            json_d.getLine(),
            json_d.getColumn(),
        });
        return Error.InvalidKey;
    }
    if (try json_scanner_next_debug(FnSrc(@This(), @src()), json_scanner, logger) != .object_end) {
        logger.print(.err, null, "No ending curly backet '}}' found\n(line {}, col {})\n", .{ json_d.getLine(), json_d.getColumn() });
        return Error.NoEndingCurlyBracket;
    }
    assign_arr[assign_i] = true;
    return use_union;
}
pub fn json_try_parse(
    comptime T: type,
    assign_arr: []bool,
    assign_i: usize,
    arena: std.mem.Allocator,
    parent_key: []const u8,
    json_scanner: *std.json.Scanner,
    json_key: []const u8,
    json_d: *std.json.Diagnostics,
    logger: *Logger,
) !T {
    switch (@typeInfo(T)) {
        .Int => return try json_try_parse_int(T, assign_arr, assign_i, parent_key, json_scanner, json_key, json_d, logger),
        .Bool => return try json_try_parse_bool(assign_arr, assign_i, parent_key, json_scanner, json_key, json_d, logger),
        .Enum => return try json_try_parse_enum(T, assign_arr, assign_i, parent_key, json_scanner, json_key, json_d, logger),
        .Pointer => |p| {
            if (p.size == .Slice) {
                const token_type = try json_scanner.peekNextTokenType();
                switch (token_type) {
                    .array_begin => {
                        if (p.child == u8) {
                            logger.print(.err, null, "For the parent key '{s}', it should be a string type\n(line {}, col {})\n", .{
                                parent_key,
                                json_d.getLine(),
                                json_d.getColumn(),
                            });
                            return Error.UnexpectedToken;
                        }
                        return try json_try_parse_slice(T, assign_arr, assign_i, arena, json_scanner, json_key, json_d, logger);
                    },
                    .string => {
                        if (p.child != u8) {
                            logger.print(.err, null, "For the parent key '{s}', it should be an array type\n(line {}, col {})\n", .{
                                parent_key,
                                json_d.getLine(),
                                json_d.getColumn(),
                            });
                            return Error.UnexpectedToken;
                        }
                        return try json_try_parse_string(assign_arr, assign_i, parent_key, arena, json_scanner, json_key, json_d, logger);
                    },
                    else => {
                        logger.print(.err, null, "For the parent key '{s}', it should be {s} type\n(line {}, col {})\n", .{
                            parent_key,
                            if (p.child == u8) "a string" else "an array",
                            json_d.getLine(),
                            json_d.getColumn(),
                        });
                        return Error.UnexpectedToken;
                    },
                }
            }
            return Error.UnimplementedZigType;
        },
        .Optional => |o| {
            const token_type = try json_scanner.peekNextTokenType();
            if (token_type == .null) {
                _ = try json_scanner_next_debug(FnSrc(@This(), @src()), json_scanner, logger);
                return null;
            } //Parse with the optional child type otherwise.
            return try json_try_parse(o.child, assign_arr, assign_i, arena, parent_key, json_scanner, json_key, json_d, logger);
        },
        .Struct => {
            if (!std.meta.hasMethod(T, "json_parse"))
                @compileError(std.fmt.comptimePrint("In json_try_parse(...), type '{any}' requires a pub fn json_parse(parent_key: []const u8, arena: std.mem.Allocator, json_scanner: *std.json.Scanner, json_d: *std.json.Diagnostics)", .{T}));
            return try T.json_parse(parent_key, arena, json_scanner, json_d, logger);
        },
        .Union => return try json_try_parse_union(T, assign_arr, assign_i, arena, json_scanner, json_key, json_d, logger),

        else => return Error.UnimplementedZigType,
    }
}
