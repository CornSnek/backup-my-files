const std = @import("std");
/// Outputs link of a function to a file for vscode
pub fn FileLink(comptime s: std.builtin.SourceLocation) [:0]const u8 {
    return std.fmt.comptimePrint("{[F]s}:{[L]}:{[C]}", .{ .F = s.file, .L = s.line, .C = s.column });
}
/// Outputs string of a function and its source location using FnSrc(@This(), @src())
pub fn FnSrc(comptime T: type, comptime s: std.builtin.SourceLocation) [:0]const u8 {
    return std.fmt.comptimePrint("File: [{[FL]s}] Fn: {[T]s}.{[Fn]s}", .{ .FL = FileLink(s), .T = @typeName(T), .Fn = s.fn_name });
}
