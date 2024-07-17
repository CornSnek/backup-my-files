//! This implements only creating files and directories to a tar file. See `std.tar` for reference
const std = @import("std");
const date = @import("date.zig");
const Marker = @import("main.zig").Marker;
const copy_file = @import("main.zig").copy_file;
pub const FileProperty = union(enum) {
    create_dir: void,
    create_file: []const u8,
    dir: *const std.fs.Dir,
    file: *const std.fs.File,
};
const Split = struct { prefix: []const u8, name: []const u8 };
/// To handle long 'name' fields in tar headers
const SplitPath = union(enum) {
    /// 'name' field can be used normally
    ok: void,
    /// Use pax headers if path is unsplittable or >255 chars
    pax: void, //TODO
    /// Path needs to be split to 'name' (<=100) and 'prefix' (<=155) if path is >100 chars
    split: Split,
    fn init(path: []const u8) SplitPath {
        if (path.len > 255) {
            return .pax;
        } else if (path.len > 100) {
            var slash_i: usize = path.len;
            while (true) {
                if (slash_i == 0) return .pax; //255 characters without slashes
                slash_i -= 1;
                if (path[slash_i] == '/') {
                    const split_maybe: SplitPath = .{ .split = .{ .prefix = path[0..slash_i], .name = path[slash_i + 1 ..] } };
                    if (split_maybe.split.name.len > 100) return .pax; //Use pax instead as it would make 'name' >100
                    if (split_maybe.split.prefix.len > 155) continue; //Resolve if 'prefix' is still >155 characters
                    return split_maybe;
                }
            }
        } else return .ok;
    }
};
test "SplitPath.init ok" {
    try std.testing.expectEqual(.ok, SplitPath.init("a/b/c"));
}
test "SplitPath.init pax greater than 255" {
    try std.testing.expectEqual(.pax, SplitPath.init("a/bc/de/" ** 32 ++ "f"));
}
test "SplitPath.init split splittable" {
    const chars = "abcdefghi";
    const old_path = (chars ++ "/") ** 20 ++ "j";
    const sp = SplitPath.init(old_path);
    const sp_cmp = SplitPath{ .split = .{
        .prefix = (chars ++ "/") ** 14 ++ chars,
        .name = (chars ++ "/") ** 5 ++ "j",
    } };
    if (sp == .split and sp_cmp == .split) {
        try std.testing.expectEqualStrings(sp_cmp.split.prefix, sp.split.prefix);
        try std.testing.expectEqualStrings(sp_cmp.split.name, sp.split.name);
    } else {
        return error.UnionsExpectedEqual;
    }
}
test "SplitPath.init pax unsplittable without slashes" {
    try std.testing.expectEqual(.pax, SplitPath.init("12345" ** 51)); //Exactly 255 characters
}
test "SplitPath.init pax unspittable with slashes" {
    const chars = "abcdefghi";
    try std.testing.expectEqual(.pax, SplitPath.init((chars ++ "/") ** 25 ++ "j"));
}
pub fn write_to_tar(allocator: std.mem.Allocator, file_p: FileProperty, output_file: std.fs.File, path: []const []const u8, output_size: *usize) !void {
    if (path.len == 0) return;
    var path_adj = path;
    if (std.mem.eql(u8, path_adj[0], ".")) path_adj = path[1..path.len]; //Discard '.' as the first path because tar considers '.' a file
    if (path_adj.len == 0) return; //Skip creating any paths with just "."
    var header_buf: [512]u8 = undefined;
    const t_head = TarUstarHeader.init_windows(&header_buf, file_p);
    var path_str = try std.fs.path.join(allocator, path_adj);
    for (0..path_str.len) |i| {
        if (path_str[i] == '\\') path_str[i] = '/'; //Change to posix path since tar considers backslash a part of a directory name.
    }
    defer allocator.free(path_str);
    switch (file_p) {
        .create_dir, .dir => { //Append '/' to directories
            if (path_str[path_str.len - 1] != '/') {
                path_str = try allocator.realloc(path_str, path_str.len + 1);
                path_str[path_str.len - 1] = '/';
            }
        },
        .create_file, .file => {},
    }
    const split_path = SplitPath.init(path_str);
    switch (split_path) {
        .ok => {
            try t_head.write_file(path_str);
            try t_head.write_file_prefix("");
        },
        .split => |sp| {
            try t_head.write_file(sp.name);
            try t_head.write_file_prefix(sp.prefix);
        },
        .pax => @panic("TODO"),
    }
    try t_head.write_file_properties(file_p);
    try t_head.write_checksum(t_head.calculate_checksum());
    const copying_node_str = try std.fmt.allocPrint(allocator, "{s}", .{path_str});
    defer allocator.free(copying_node_str);
    try t_head.write_header_and_contents(file_p, output_file, output_size, copying_node_str);
}
const TarUstarHeader = struct {
    header: []u8,
    fn init_windows(s: []u8, file_p: FileProperty) @This() {
        const header: @This() = .{ .header = s };
        switch (file_p) {
            .create_dir, .dir => @memcpy(header.mode(), "0000644\x00"),
            .create_file, .file => @memcpy(header.mode(), "0000755\x00"),
        }
        @memcpy(header.uid(), "0000000\x00");
        @memcpy(header.gid(), "0000000\x00");
        @memset(header.linkname(), 0);
        @memcpy(header.magic(), "ustar\x00");
        @memcpy(header.version(), "00");
        @memset(header.uname(), 0);
        @memset(header.gname(), 0);
        @memset(header.devmajor(), 0);
        @memset(header.devminor(), 0);
        @memset(header.padding(), 0);
        return header;
    }
    fn write_file(self: @This(), fname: []const u8) !void {
        var filename_fbs = std.io.fixedBufferStream(self.name());
        try filename_fbs.writer().print("{[file]s:\x00<[w]}", .{ .file = fname, .w = self.name().len });
    }
    fn write_file_prefix(self: @This(), fprefix: []const u8) !void {
        var prefix_fbs = std.io.fixedBufferStream(self.prefix());
        try prefix_fbs.writer().print("{[p]s:\x00<[w]}", .{ .p = fprefix, .w = self.prefix().len });
    }
    fn write_file_properties(self: @This(), file_p: FileProperty) !void {
        var timestamp: i64 = undefined;
        var fsize: u64 = undefined;
        var file_type_c: u8 = undefined;
        switch (file_p) {
            .create_dir => {
                timestamp = std.time.timestamp();
                fsize = 0;
                file_type_c = '5';
            },
            .create_file => |s| {
                timestamp = std.time.timestamp();
                fsize = s.len;
                file_type_c = '0';
            },
            .dir => |d| {
                const dstat = try d.stat();
                timestamp = @truncate(@divFloor(dstat.mtime, std.time.ns_per_s));
                fsize = 0;
                file_type_c = '5';
            },
            .file => |f| {
                const fstat = try f.stat();
                timestamp = @truncate(@divFloor(fstat.mtime, std.time.ns_per_s));
                fsize = fstat.size;
                file_type_c = '0';
            },
        }
        if (timestamp < 0) return error.NegativeModificationTimeNotSupported;
        var fbs = std.io.fixedBufferStream(self.mtime());
        try fbs.writer().print("{[m]o:0>[w]}\x00", .{ .m = @as(u63, @intCast(@as(i63, @truncate(timestamp)))), .w = self.mtime().len - 1 });
        fbs.buffer = self.size();
        fbs.reset();
        try fbs.writer().print("{[s]o:0>[w]}\x00", .{ .s = fsize, .w = self.size().len - 1 });
        @memcpy(self.typeflag(), &[_]u8{file_type_c});
    }
    fn calculate_checksum(self: @This()) u64 {
        var c: u64 = 0;
        for (self.header, 0..) |b, i| {
            const adj_b = if (148 <= i and i < 156) 32 else b;
            c += adj_b;
        }
        return c;
    }
    fn write_checksum(self: @This(), c: u64) !void {
        var checksum_fbs = std.io.fixedBufferStream(self.chksum());
        //Write checksum with leading 0s including \0 and ' '
        try checksum_fbs.writer().print("{o:0>6}\x00 ", .{c});
    }
    /// Before writing, check checksum first and null-termination of required null-terminated fields.
    fn verify_header(self: @This()) !void {
        if (self.mode()[self.mode().len - 1] != 0) return error.NotNullTerminated;
        if (self.uid()[self.uid().len - 1] != 0) return error.NotNullTerminated;
        if (self.gid()[self.gid().len - 1] != 0) return error.NotNullTerminated;
        if (self.size()[self.size().len - 1] != 0) return error.NotNullTerminated;
        if (self.mtime()[self.mtime().len - 1] != 0) return error.NotNullTerminated;
        if (self.chksum()[6] != 0 or self.chksum()[7] != ' ') return error.BadTarChecksum;
        const c_str_calc = try std.fmt.parseInt(u64, self.chksum()[0..6], 8);
        if (self.calculate_checksum() != c_str_calc) return error.BadTarChecksum;
        if (self.devmajor()[self.devmajor().len - 1] != 0) return error.NotNullTerminated;
        if (self.devminor()[self.devminor().len - 1] != 0) return error.NotNullTerminated;
    }
    /// The file and offset is used to pad and check 512-byte alignments.
    fn write_header_and_contents(self: @This(), file_p: FileProperty, output_file: std.fs.File, output_size: *usize, path_str: []const u8) !void {
        try self.verify_header();
        output_size.* += 512;
        try output_file.writeAll(self.header);
        switch (file_p) {
            .create_dir, .dir => {},
            .create_file => |f| {
                try output_file.writeAll(f);
                output_size.* += f.len;
            },
            .file => |f| {
                const fstat = try f.stat();
                const fsize = fstat.size;
                try copy_file(path_str, f.handle, output_file.handle, fsize);
                output_size.* += fsize;
            },
        }
        _ = try add_512_padding(output_size, output_file.writer());
    }
    fn debug_fields(self: @This()) void {
        std.debug.print("TAR Header:\n", .{});
        // zig fmt: off
        inline for ([_][]const u8{"name", "mode", "uid", "gid", "size",
            "mtime", "chksum", "typeflag", "linkname", "magic", "version",
            "uname", "gname", "devmajor", "devminor", "prefix" }, 1..) |n, i| {
            // zig fmt: on
            std.debug.print("{[num]:0>2} '{[fn_n]s}' = {[slice]any}\n{[s]s: >[w]} string{{\"{[slice]s}\"}}\n", .{
                .fn_n = n,
                .num = i,
                .s = "=",
                .w = n.len + 7,
                .slice = @field(@This(), n)(self),
            });
        }
        std.debug.print("\n", .{});
    }
    inline fn slice(self: @This(), begin: usize, len: usize) []u8 {
        return self.header[begin .. begin + len];
    }
    inline fn name(self: @This()) []u8 {
        return self.slice(0, 100);
    }
    /// octal
    inline fn mode(self: @This()) []u8 {
        return self.slice(100, 8);
    }
    /// octal
    inline fn uid(self: @This()) []u8 {
        return self.slice(108, 8);
    }
    /// octal
    inline fn gid(self: @This()) []u8 {
        return self.slice(116, 8);
    }
    /// octal
    inline fn size(self: @This()) []u8 {
        return self.slice(124, 12);
    }
    /// octal
    inline fn mtime(self: @This()) []u8 {
        return self.slice(136, 12);
    }
    inline fn chksum(self: @This()) []u8 {
        return self.slice(148, 8);
    }
    inline fn typeflag(self: @This()) []u8 {
        return self.slice(156, 1);
    }
    inline fn linkname(self: @This()) []u8 {
        return self.slice(157, 100);
    }
    inline fn magic(self: @This()) []u8 {
        return self.slice(257, 6);
    }
    inline fn version(self: @This()) []u8 {
        return self.slice(263, 2);
    }
    inline fn uname(self: @This()) []u8 {
        return self.slice(265, 32);
    }
    inline fn gname(self: @This()) []u8 {
        return self.slice(297, 32);
    }
    inline fn devmajor(self: @This()) []u8 {
        return self.slice(329, 8);
    }
    inline fn devminor(self: @This()) []u8 {
        return self.slice(337, 8);
    }
    inline fn prefix(self: @This()) []u8 {
        return self.slice(345, 155);
    }
    inline fn padding(self: @This()) []u8 {
        return self.slice(500, 12);
    }
};
const Padding = struct {
    /// Old size of file_size_len before adding padding.
    old_fsize: usize,
    /// Padding size to make file_size_len (after adding psize) be divisible to 512.
    psize: u16,
};
/// Writes 0 bytes to a writer and returns the size written.
/// file_size_len should be divisible to 512
fn add_512_padding(file_size_len: *usize, writer: anytype) !Padding {
    var padding: Padding = undefined;
    const left_over: u16 = @intCast((512 - (file_size_len.* % 512)) % 512);
    padding.psize = left_over;
    padding.old_fsize = file_size_len.*;
    var zero_buf: [512]u8 = undefined;
    @memset(zero_buf[0..left_over], 0);
    try writer.writeAll(zero_buf[0..left_over]);
    file_size_len.* += left_over;
    return padding;
}
/// After all files are added for a tar file, add 1024 nul bytes to write to a file writer.
pub fn end_tar_file(file_size_len: *usize, writer: anytype) !void {
    if (file_size_len.* % 512 != 0) return error.NotDivisibleBy512;
    try writer.writeByteNTimes(0, 1024);
    file_size_len.* += 1024;
}
test {
    @import("main.zig").progress_root = std.Progress.start(.{});
}
test "add_512_padding 0 padding already divisible by 512" {
    var zero_buf: [512]u8 = [1]u8{1} ** 512; //Set all as 1 to test non-written bits
    var buf = std.io.fixedBufferStream(&zero_buf);
    var file_size_len: usize = 0;
    const padding = try add_512_padding(&file_size_len, buf.writer());
    try std.testing.expectEqual(file_size_len, padding.psize);
    try std.testing.expectEqual(file_size_len, padding.old_fsize);
    try std.testing.expect(std.mem.allEqual(u8, zero_buf[0..padding.psize], 0));
    try std.testing.expect(std.mem.allEqual(u8, zero_buf[padding.psize..], 1));
}
test "add_512_padding 512 total padding and file_size_len divisible by 512" {
    var zero_buf: [512]u8 = [1]u8{1} ** 512;
    var buf = std.io.fixedBufferStream(&zero_buf);
    var file_size_len: usize = 12345;
    const padding = try add_512_padding(&file_size_len, buf.writer());
    try std.testing.expect(file_size_len % 512 == 0);
    try std.testing.expectEqual(file_size_len, padding.old_fsize + padding.psize);
    try std.testing.expect(std.mem.allEqual(u8, zero_buf[0..padding.psize], 0));
    try std.testing.expect(std.mem.allEqual(u8, zero_buf[padding.psize..], 1));
}
test "end_tar_file added 1024 bytes" {
    var zero_buf: [1024]u8 = undefined;
    var buf = std.io.fixedBufferStream(&zero_buf);
    var file_size_len: usize = 0;
    try end_tar_file(&file_size_len, buf.writer());
    try std.testing.expect(std.mem.allEqual(u8, &zero_buf, 0));
}
test "end_tar_file error not divisible by 512" {
    var zero_buf: [1024]u8 = undefined;
    @memset(&zero_buf, 1);
    var buf = std.io.fixedBufferStream(&zero_buf);
    var file_size_len: usize = 1;
    try std.testing.expectError(error.NotDivisibleBy512, end_tar_file(&file_size_len, buf.writer()));
}
test "TarUstarHeader write_checksum" {
    var header: [512]u8 = undefined;
    const tar_header = TarUstarHeader.init_windows(&header, .create_dir);
    const c = tar_header.calculate_checksum();
    try tar_header.write_checksum(c);
}
