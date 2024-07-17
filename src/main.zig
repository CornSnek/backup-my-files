const std = @import("std");
const date = @import("date.zig");
const json_struct = @import("json_struct.zig");
const Logger = @import("Logger.zig");
const tar = @import("tar.zig");
const args = @import("args.zig");
var logger: Logger = undefined;
const FileTimestamp = struct {
    timestamp: i128,
    file: []const u8,
    kind: std.fs.Dir.Entry.Kind,
    /// Writes to writer in the form of `[timestamp]/[file]/[0 (directory) or 1 (file)]\n`
    pub fn write_data(self: FileTimestamp, writer: anytype) !void {
        try std.fmt.formatBuf(self.file, .{}, writer);
        try writer.writeByte('/');
        try std.fmt.formatInt(self.timestamp, 10, .lower, .{}, writer);
        try writer.writeByte('/');
        try writer.writeByte(
            switch (self.kind) {
                .directory => '0',
                .file => '1',
                else => return error.UnsupportedFileType,
            },
        );
        try writer.writeByte('\n');
    }
};
const DirOrFile = union(enum) {
    file: std.fs.File,
    dir: std.fs.Dir,
    fn close(self: *DirOrFile) void {
        switch (self.*) {
            .file => |f| f.close(),
            .dir => |*d| d.close(),
        }
    }
    fn stat(self: DirOrFile) !std.fs.File.Stat {
        return switch (self) {
            .file => |f| try f.stat(),
            .dir => |d| try d.stat(),
        };
    }
    fn init(open_dir: std.fs.Dir, sub_path: []const u8, file_flags: std.fs.File.OpenFlags) !DirOrFile {
        return .{ .dir = open_dir.openDir(sub_path, .{ .iterate = true }) catch return .{ .file = try open_dir.openFile(sub_path, file_flags) } };
    }
};
pub var progress_root: std.Progress.Node = undefined;
pub fn main() !void {
    progress_root = std.Progress.start(.{});
    defer progress_root.end();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args_options: args.ArgsOptions = .{};
    defer args_options.deinit(allocator);
    if (try args.parse_args(allocator, &args_options) == true) return;
    if (args_options.json_file == null) return;
    logger = Logger.init(std.io.getStdOut(), std.io.getStdErr(), args_options.scope_array, args_options.disable);
    if (try date.get_timezone(allocator)) |tz| {
        logger.timezone = tz;
    }
    var backup_struct: json_struct.JSONStruct = undefined;
    var json_arena = std.heap.ArenaAllocator.init(allocator);
    defer json_arena.deinit();
    {
        var scanner = std.json.Scanner.initStreaming(allocator);
        defer scanner.deinit();
        const json_file = try std.fs.cwd().openFile(args_options.json_file.?, .{});
        defer json_file.close();
        const json_str = try json_file.readToEndAlloc(allocator, 1073741824);
        defer allocator.free(json_str);
        scanner.feedInput(json_str);
        scanner.endInput();
        var json_d: std.json.Diagnostics = .{};
        scanner.enableDiagnostics(&json_d);
        backup_struct = try json_struct.JSONStruct.json_parse(json_arena.allocator(), &scanner, &json_d, &logger);
    }
    std.fs.cwd().makeDir(backup_struct.output_dir) catch {};
    var output_dir = try std.fs.cwd().openDir(backup_struct.output_dir, .{ .iterate = true });
    defer output_dir.close();
    const backups_progress = progress_root.start("Backups", backup_struct.backups.len);
    defer backups_progress.end();
    var newest_file_timestamp: FileTimestamp = undefined;
    next_backup: for (backup_struct.backups) |*b| {
        defer backups_progress.completeOne();
        if (args_options.filter_backup) |filter_b| {
            logger.print(.info, null, "-b option is used. Filtering backup object to include '{s}'.\n", .{filter_b});
            if (std.mem.indexOf(u8, b.name, filter_b) == null) {
                logger.print(.info, null, "'{s}' backup object has been skipped.\n", .{b.name});
                continue;
            }
            logger.print(.info, null, "'{s}' backup object is allowed.\n", .{b.name});
        }
        var search_dir = try std.fs.cwd().openDir(b.search_dir, .{});
        defer search_dir.close();
        const date_now = date.Date.init_with_timezone(std.time.timestamp(), logger.timezone);
        var new_output_name: []u8 = try date_now.to_str_format(b.output_name, allocator);
        if (b.type == .directory) { //Create either a directory or tar file.
            output_dir.makeDir(new_output_name) catch {};
        } else { //Append .tar to new_output_name
            new_output_name = try allocator.realloc(new_output_name, new_output_name.len + 4);
            @memcpy(new_output_name[new_output_name.len - 4 .. new_output_name.len], ".tar");
            const f = try output_dir.createFile(new_output_name, .{});
            f.close();
        }
        defer allocator.free(new_output_name);
        const backup_path_arr: [3][]const u8 = .{ ".", backup_struct.output_dir, new_output_name };
        const backup_path = try std.fs.path.join(allocator, &backup_path_arr);
        defer allocator.free(backup_path);
        logger.print(.info, null, "Creating {s} {s} '{s}' for backup '{s}'\n", .{
            @tagName(b.type),
            if (b.type == .directory) "folder" else "file",
            backup_path,
            b.name,
        });
        var output_dir_or_tar = try DirOrFile.init(output_dir, new_output_name, .{ .mode = .write_only });
        defer if (args_options.print_only) {
            if (output_dir_or_tar == .dir) {
                output_dir.deleteDir(new_output_name) catch {};
            } else output_dir.deleteFile(new_output_name) catch {};
        };
        defer output_dir_or_tar.close();
        if (output_dir_or_tar == .dir) {
            var it = output_dir_or_tar.dir.iterate();
            if (try it.next()) |_| {
                logger.print(.warn, null, "File directory '{s}' is not empty. Unable to delete. Skipping '{s}'.\n", .{ backup_path, b.name });
                continue :next_backup;
            }
        }

        const backup_for_str = try std.fmt.allocPrint(allocator, "Backup object name: '{s}'", .{b.name});
        defer allocator.free(backup_for_str);
        const backup_name_progress = backups_progress.start(backup_for_str, 0);
        defer backup_name_progress.end();
        var output_size: usize = 0; //Used with .tar files
        var files_seen: usize = 0; //Used with .scan to see total number of files/directories not skipped by filters.
        for (b.backup_files) |*bf| try backup_fn(.scan, &files_seen, backup_name_progress, allocator, &output_size, search_dir, &output_dir_or_tar, bf, args_options.print_only);
        logger.print(.info, null, "Total of {} files and directories will be copied.\n", .{files_seen});
        for (b.backup_files) |*bf| {
            try backup_fn(.copy, &files_seen, backup_name_progress, allocator, &output_size, search_dir, &output_dir_or_tar, bf, args_options.print_only);
            backup_name_progress.completeOne();
        }
        if (args_options.print_only) {
            logger.print(.warn, null, "You are in print only mode (-p). No files have been copied.\n", .{});
            continue;
        }
        if (output_dir_or_tar == .file) try tar.end_tar_file(&output_size, output_dir_or_tar.file.writer());

        newest_file_timestamp.file = new_output_name;
        if (output_dir_or_tar == .file) {
            const new_file = try output_dir.openFile(new_output_name, .{}); //Reopen as .read_only
            output_dir_or_tar.file.close(); //Close the same write_only file before replacing.
            output_dir_or_tar.file = new_file;
            if (b.type == .tar) {
                if (b.type.tar) |compression| {
                    { //Store output tar to timestampts file.
                        const stat = try output_dir_or_tar.file.stat();
                        newest_file_timestamp.timestamp = stat.mtime;
                        newest_file_timestamp.kind = stat.kind;
                        var backup_cfg_file = try output_dir.createFile("backup_timestamps.dat", .{ .truncate = false });
                        defer backup_cfg_file.close();
                        try backup_cfg_file.seekFromEnd(0);
                        try newest_file_timestamp.write_data(backup_cfg_file.writer());
                    }
                    logger.print(.info, null, "Compression '{s}' is being applied to this tar file.\n", .{@tagName(compression)});
                    const compression_progress = backups_progress.start(@tagName(compression), 0);
                    defer compression_progress.end();
                    const compressed_output_name = try allocator.alloc(u8, new_output_name.len + compression.ext_name().len);
                    errdefer allocator.free(compressed_output_name);
                    @memcpy(compressed_output_name[0..new_output_name.len], new_output_name);
                    @memcpy(compressed_output_name[new_output_name.len..], compression.ext_name());
                    const compressed_f = try output_dir.createFile(compressed_output_name, .{ .read = true });
                    errdefer compressed_f.close();
                    switch (compression) {
                        .gzip => |gz_c| try std.compress.gzip.compress(output_dir_or_tar.file.reader(), compressed_f.writer(), .{ .level = gz_c }),
                        .zlib => |zl_c| try std.compress.zlib.compress(output_dir_or_tar.file.reader(), compressed_f.writer(), .{ .level = zl_c }),
                    }
                    output_dir_or_tar.file.close(); //I tried `std.compress.gz.compress` to compress files to a `.gz` file. Sometimes the file gets corrupted and I'm not sure why (`CRC failed`). I would change `zig build -Doptimize=ReleaseSafe` or use a lower compression level for some compressed files to not get `CRC failed`.
                    output_dir_or_tar.file = compressed_f; //Replace output file with compressed file instead.
                    allocator.free(new_output_name);
                    newest_file_timestamp.file = compressed_output_name; //Replace output name with the compressed to be deleted later
                    new_output_name = compressed_output_name;
                }
            }
        }
        //Write output mtime timestamp to backup_timestamps.dat
        const stat = try output_dir_or_tar.stat();
        newest_file_timestamp.timestamp = stat.mtime;
        newest_file_timestamp.kind = stat.kind;
        var backup_cfg_file = try output_dir.createFile("backup_timestamps.dat", .{ .truncate = false }); //Write backup_timestamps.dat to delete any old backup files.
        defer backup_cfg_file.close();
        try backup_cfg_file.seekFromEnd(0);
        try newest_file_timestamp.write_data(backup_cfg_file.writer());
    }
    if (args_options.print_only) return;
    var file_timestamps = try allocator.alloc(FileTimestamp, 0);
    defer {
        for (file_timestamps) |f| allocator.free(f.file);
        allocator.free(file_timestamps);
    }
    var backup_cfg_file = try output_dir.openFile("backup_timestamps.dat", .{ .mode = .read_only });
    defer backup_cfg_file.close();
    try backup_cfg_file.seekTo(0);
    while (try backup_cfg_file.reader().readUntilDelimiterOrEofAlloc(allocator, '\n', 1024)) |line| {
        defer allocator.free(line);
        var token_it = std.mem.tokenizeAny(u8, line, "/\r");
        const file = token_it.next() orelse return error.CorruptedTimestampsFile;
        const timestamp_str = token_it.next() orelse return error.CorruptedTimestampsFile;
        const kind = token_it.next() orelse return error.CorruptedTimestampsFile;
        const timestamp = try std.fmt.parseInt(i128, timestamp_str, 10);
        file_timestamps = try allocator.realloc(file_timestamps, file_timestamps.len + 1);
        const last_len = file_timestamps.len - 1;
        file_timestamps[last_len].file = try allocator.dupe(u8, file);
        file_timestamps[last_len].timestamp = timestamp;
        if (std.mem.eql(u8, kind, "0")) {
            file_timestamps[last_len].kind = .directory;
        } else if (std.mem.eql(u8, kind, "1")) {
            file_timestamps[last_len].kind = .file;
        } else return error.UnsupportedFileType;
    }
    defer logger.print(.info, null, "Backups completed\n", .{});
    if (file_timestamps.len <= backup_struct.max_backups) return;
    logger.print(.info, null, "Number of backups ({}) has exceeded the maximum number of {}. Deleting old backups.\n", .{ file_timestamps.len, backup_struct.max_backups });
    std.sort.block(FileTimestamp, file_timestamps, {}, struct {
        fn f(_: void, lhs: FileTimestamp, rhs: FileTimestamp) bool {
            return lhs.timestamp < rhs.timestamp;
        }
    }.f);
    for (0..file_timestamps.len - backup_struct.max_backups) |i| {
        const file_to_delete = file_timestamps[i].file; //Delete oldest files.
        if (file_timestamps[i].kind == .directory) {
            output_dir.deleteTree(file_to_delete) catch {};
        } else output_dir.deleteFile(file_to_delete) catch {};
        logger.print(.info, null, "Deleted oldest backup file '{s}' ({s})\n", .{ file_to_delete, @tagName(file_timestamps[i].kind) });
    }
    const new_backup_cfg_file = try output_dir.createFile("backup_timestamps.dat", .{}); //Rewrite the recent non-deleted backups to the .dat file.
    backup_cfg_file.close();
    backup_cfg_file = new_backup_cfg_file;
    for (file_timestamps[file_timestamps.len - backup_struct.max_backups .. file_timestamps.len]) |ft| try ft.write_data(backup_cfg_file.writer());
}
pub const Marker = enum {
    FileCopying,
    FileCopied,
    FileFilterSkip,
    DirCopied,
    DirDepthSkip,
    DirFilterSkip,
    Skipped,
    const Strs = [_][]const u8{
        "Copying File",
        "File Copied",
        "File Filter Skip",
        "Dir Copied",
        "Dir Depth Exceeded",
        "Dir Filter Skip",
        "Skipped",
    };
    pub fn str(self: @This()) []const u8 {
        return Strs[@intFromEnum(self)];
    }
    pub const MaxMarkerLen = m: {
        var max = 0;
        for (Strs) |s| max = @max(max, s.len);
        break :m max + 2;
    };
    pub const MaxLenStr = std.fmt.comptimePrint("{}", .{Marker.MaxMarkerLen});
};
fn backup_fn(comptime do: enum { scan, copy }, files_seen: *usize, parent_node: std.Progress.Node, allocator: std.mem.Allocator, output_size: *usize, search_dir: std.fs.Dir, output_dir_or_tar: *DirOrFile, bf: *const json_struct.BackupFile, print_only_option: bool) !void {
    const files_seen_progress = if (do == .copy) parent_node.start("Files and Directories Copied", files_seen.*) else {};
    defer if (do == .copy) files_seen_progress.end();
    var reading_file_arr = try allocator.alloc([]const u8, 0);
    var reading_file_len: usize = 0;
    defer allocator.free(reading_file_arr);
    var reading_file_alloc = try allocator.alloc(bool, 0); //Checks if string used dupe() from Dir iterator()
    defer {
        for (0..reading_file_len) |i| if (reading_file_alloc[i]) allocator.free(reading_file_arr[i]);
        allocator.free(reading_file_alloc);
    }
    if (output_dir_or_tar.* == .dir) {
        if (!print_only_option) {
            if (std.fs.path.dirname(bf.name)) |subdirs| { //If bf.name has a path, make subdirectories if they don't exist yet.
                try output_dir_or_tar.dir.makePath(subdirs);
            }
        }
    }
    var comp_it = try std.fs.path.componentIterator(bf.name);
    var offset_depth: usize = 0; //Used to offset dir_limit so that components before searching bf.name aren't counted.
    while (comp_it.next()) |comp| { //If bf.name is a path, separate each component and mark as not allocated.
        reading_file_arr = try allocator.realloc(reading_file_arr, reading_file_arr.len + 1);
        reading_file_alloc = try allocator.realloc(reading_file_alloc, reading_file_alloc.len + 1);
        reading_file_arr[reading_file_arr.len - 1] = comp.name;
        reading_file_alloc[reading_file_alloc.len - 1] = false;
        reading_file_len += 1;
        offset_depth += 1;
    }
    if (do == .copy) logger.print(.debug, .FileExtra, "Relative path now (Depth=0): {s}\n", .{reading_file_arr});
    const bf_name_dir_or_file: DirOrFile = try DirOrFile.init(search_dir, bf.name, .{}); //const because .close() is used individually instead of DirOrFile.close(*self)
    if (do == .copy) {
        if (!print_only_option) {
            if (output_dir_or_tar.* == .file) {
                var adj_reading_file_arr = reading_file_arr;
                if (bf_name_dir_or_file == .file) adj_reading_file_arr = reading_file_arr[0 .. reading_file_arr.len - 1]; //Only get subdirectories
                for (0..adj_reading_file_arr.len) |i| {
                    const sub_subdir_path = adj_reading_file_arr[0 .. i + 1];
                    const sub_subdir_str = try std.fs.path.join(allocator, sub_subdir_path);
                    defer allocator.free(sub_subdir_str);
                    var sub_subdir = try search_dir.openDir(sub_subdir_str, .{});
                    defer sub_subdir.close();
                    try tar.write_to_tar(allocator, .{ .dir = &sub_subdir }, output_dir_or_tar.file, sub_subdir_path, output_size);
                }
            }
        }
    }
    switch (bf_name_dir_or_file) {
        .file => |bf_file| {
            defer bf_file.close();
            const relative_file_str = try std.fs.path.join(allocator, reading_file_arr);
            defer allocator.free(relative_file_str);
            if (try filter_filename(0, .file, bf.name, bf.filters)) {
                if (do == .copy) {
                    logger.print(.debug, .FileExtra, "[{s:^" ++ Marker.MaxLenStr ++ "}] {s}\n", .{ Marker.FileCopying.str(), relative_file_str });
                    if (output_dir_or_tar.* == .dir) {
                        if (!print_only_option) try copy_and_progress(allocator, bf.name, search_dir, output_dir_or_tar.dir);
                        logger.print(.info, .FileExtra, "[{s:^" ++ Marker.MaxLenStr ++ "}] {s}\n", .{ Marker.FileCopied.str(), relative_file_str });
                    } else {
                        if (!print_only_option) {
                            const source_file = try search_dir.openFile(relative_file_str, .{});
                            defer source_file.close();
                            try tar.write_to_tar(allocator, .{ .file = &source_file }, output_dir_or_tar.file, reading_file_arr[0..reading_file_len], output_size);
                        }
                        logger.print(.info, null, "[{s:^" ++ Marker.MaxLenStr ++ "}] {s}\n", .{ Marker.FileCopied.str(), relative_file_str });
                    }
                    files_seen_progress.completeOne();
                } else {
                    files_seen.* += 1;
                }
            } else {
                if (do == .copy) logger.print(.info, null, "[{s:^" ++ Marker.MaxLenStr ++ "}] {s}\n", .{ Marker.FileFilterSkip.str(), relative_file_str });
            }
        },
        .dir => |bf_dir| { //bf.name is directory => Search all files and subdirectories of bf.name
            var dirs: []std.fs.Dir = try allocator.alloc(std.fs.Dir, 1);
            defer allocator.free(dirs);
            dirs[0] = bf_dir;
            defer for (dirs) |*_dir| _dir.close(); //Don't run this defer close code if openDir above errors.
            var dirs_iters: []std.fs.Dir.Iterator = try allocator.alloc(std.fs.Dir.Iterator, 1);
            defer allocator.free(dirs_iters);
            dirs_iters[0] = dirs[0].iterate();
            var dir_i: usize = 0;
            while (true) {
                //Removes the current directory component. Example: a/b/c after calling pop_component(...) becomes a/b
                //true if exiting backup_fn, or false if continuing directory walking
                const pop_component = struct {
                    inline fn f(
                        _allocator: std.mem.Allocator,
                        _dir_i: *usize,
                        _backup_len: *usize,
                        _reading_file_arr: []const []const u8,
                        _dirs: *[]std.fs.Dir,
                        _dirs_iters: *[]std.fs.Dir.Iterator,
                    ) !bool {
                        if (_dir_i.* == 0) return true;
                        _dir_i.* -= 1;
                        _allocator.free(_reading_file_arr[_backup_len.* - 1]);
                        _backup_len.* -= 1;
                        _dirs.*[_dirs.len - 1].close();
                        _dirs.* = try _allocator.realloc(_dirs.*, _dirs.len - 1);
                        _dirs_iters.* = try _allocator.realloc(_dirs_iters.*, _dirs_iters.len - 1);
                        return false;
                    }
                }.f;
                const entry: std.fs.Dir.Entry = try dirs_iters[dir_i].next() orelse
                    if (try pop_component(allocator, &dir_i, &reading_file_len, reading_file_arr, &dirs, &dirs_iters)) return else continue;
                if (do == .copy) {
                    //Counting entry.name directory as + 1 because it hasn't been added to reading_file_arr yet.
                    if (entry.kind == .directory and !try filter_filename(reading_file_len - offset_depth + 1, .directory, entry.name, bf.filters)) {
                        const relative_file_str = try std.fs.path.join(allocator, reading_file_arr[0..reading_file_len]);
                        defer allocator.free(relative_file_str);
                        logger.print(.info, null, "[{s:^" ++ Marker.MaxLenStr ++ "}] {s}{c}{s}\n", .{
                            Marker.DirFilterSkip.str(),
                            relative_file_str,
                            std.fs.path.sep,
                            entry.name,
                        });
                        files_seen_progress.completeOne();
                        continue;
                    } else {
                        files_seen.* += 1;
                    }
                }
                if (reading_file_len == reading_file_arr.len) {
                    reading_file_arr = try allocator.realloc(reading_file_arr, reading_file_arr.len + 1);
                    reading_file_alloc = try allocator.realloc(reading_file_alloc, reading_file_alloc.len + 1);
                }
                reading_file_len += 1;
                reading_file_arr[reading_file_len - 1] = try allocator.dupe(u8, entry.name);
                reading_file_alloc[reading_file_len - 1] = true;
                defer if (entry.kind != .directory) { //Non-directory components are just used once and then freed.
                    allocator.free(reading_file_arr[reading_file_len - 1]);
                    reading_file_len -= 1;
                };
                const relative_file_str = try std.fs.path.join(allocator, reading_file_arr[0..reading_file_len]);
                defer allocator.free(relative_file_str);
                switch (entry.kind) {
                    .directory => {
                        dir_i += 1;
                        dirs = try allocator.realloc(dirs, dirs.len + 1);
                        dirs[dir_i] = try dirs[dir_i - 1].openDir(entry.name, .{ .iterate = true });
                        dirs_iters = try allocator.realloc(dirs_iters, dirs_iters.len + 1); //Moving this above segfaults. Probably because entry was moved due to realloc.
                        dirs_iters[dir_i] = dirs[dir_i].iterate();
                        if (bf.dir_limit) |limit| {
                            if (reading_file_len - offset_depth > limit) {
                                if (do == .copy) logger.print(.info, null, "[{s:^" ++ Marker.MaxLenStr ++ "}] {s}\n", .{ Marker.DirDepthSkip.str(), relative_file_str });
                                if (try pop_component(allocator, &dir_i, &reading_file_len, reading_file_arr, &dirs, &dirs_iters)) return else continue;
                            } else {
                                if (do == .copy) {
                                    if (output_dir_or_tar.* == .dir) {
                                        if (!print_only_option) try output_dir_or_tar.dir.makePath(relative_file_str);
                                        logger.print(.debug, .FileExtra, "[{s:^" ++ Marker.MaxLenStr ++ "}] {s}\n", .{ Marker.DirCopied.str(), relative_file_str });
                                    } else {
                                        if (!print_only_option) try tar.write_to_tar(allocator, .{ .dir = &dirs[dir_i] }, output_dir_or_tar.file, reading_file_arr[0..reading_file_len], output_size);
                                        logger.print(.debug, .FileExtra, "[{s:^" ++ Marker.MaxLenStr ++ "}] {s}\n", .{ Marker.DirCopied.str(), relative_file_str });
                                    }
                                }
                            }
                        } else {
                            if (do == .copy) {
                                if (output_dir_or_tar.* == .dir) {
                                    if (!print_only_option) try output_dir_or_tar.dir.makePath(relative_file_str);
                                    logger.print(.debug, .FileExtra, "[{s:^" ++ Marker.MaxLenStr ++ "}] {s}\n", .{ Marker.DirCopied.str(), relative_file_str });
                                } else {
                                    if (!print_only_option) try tar.write_to_tar(allocator, .{ .dir = &dirs[dir_i] }, output_dir_or_tar.file, reading_file_arr[0..reading_file_len], output_size);
                                    logger.print(.debug, .FileExtra, "[{s:^" ++ Marker.MaxLenStr ++ "}] {s}\n", .{ Marker.DirCopied.str(), relative_file_str });
                                }
                            }
                        }
                    },
                    .file => {
                        //(-1 directory depth because of backup_len+=1)
                        if (try filter_filename(reading_file_len - offset_depth - 1, .file, entry.name, bf.filters)) {
                            if (do == .copy) {
                                logger.print(.debug, .FileExtra, "[{s:^" ++ Marker.MaxLenStr ++ "}] {s}\n", .{ Marker.FileCopying.str(), relative_file_str });
                                if (output_dir_or_tar.* == .dir) {
                                    if (!print_only_option) try copy_and_progress(allocator, relative_file_str, search_dir, output_dir_or_tar.dir);
                                    logger.print(.info, null, "[{s:^" ++ Marker.MaxLenStr ++ "}] {s}\n", .{ Marker.FileCopied.str(), relative_file_str });
                                } else {
                                    if (!print_only_option) {
                                        const source_file = try search_dir.openFile(relative_file_str, .{});
                                        defer source_file.close();
                                        try tar.write_to_tar(allocator, .{ .file = &source_file }, output_dir_or_tar.file, reading_file_arr[0..reading_file_len], output_size);
                                    }
                                    logger.print(.info, null, "[{s:^" ++ Marker.MaxLenStr ++ "}] {s}\n", .{ Marker.FileCopied.str(), relative_file_str });
                                }
                                files_seen_progress.completeOne();
                            } else {
                                files_seen.* += 1;
                            }
                        } else {
                            if (do == .copy) logger.print(.info, null, "[{s:^" ++ Marker.MaxLenStr ++ "}] {s}\n", .{ Marker.FileFilterSkip.str(), relative_file_str });
                        }
                    },
                    else => if (do == .copy) logger.print(.warn, null, "[{s:^" ++ Marker.MaxLenStr ++ "}] {s} is not a file or directory. Copying is not supported.\n", .{ Marker.Skipped.str(), relative_file_str }),
                }
            }
        },
    }
}
fn copy_and_progress(allocator: std.mem.Allocator, path: []const u8, source_dir: std.fs.Dir, dest_dir: std.fs.Dir) !void {
    const source_file = try source_dir.openFile(path, .{});
    defer source_file.close();
    var dest_file = try dest_dir.atomicFile(path, .{});
    defer dest_file.deinit();
    const source_stat = try source_file.stat();
    const copying_node_str = try std.fmt.allocPrint(allocator, "{s}", .{path});
    defer allocator.free(copying_node_str);
    try copy_file(copying_node_str, source_file.handle, dest_file.file.handle, source_stat.size);
    try dest_file.finish();
}
/// Copied/Modified `std.fs.Dir.copy_file` (Zig version 0.13.0) in order to print bytes for the progress bar progress_root.
pub fn copy_file(node_str: []const u8, fd_in: std.posix.fd_t, fd_out: std.posix.fd_t, size: u64) !void {
    const copying_node: std.Progress.Node = progress_root.start(node_str, size);
    defer copying_node.end();
    if (@import("builtin").os.tag == .linux) {
        // Try copy_file_range first as that works at the FS level and is the
        // most efficient method (if available).
        var offset: u64 = 0;
        cfr_loop: while (true) {
            // The kernel checks the u64 value `offset+count` for overflow, use
            // a 32 bit value so that the syscall won't return EINVAL except for
            // impossibly large files (> 2^64-1 - 2^32-1).
            const amt = try std.posix.copy_file_range(fd_in, offset, fd_out, offset, std.math.maxInt(u32), 0);
            copying_node.setCompletedItems(offset);
            // Terminate as soon as we have copied size bytes or no bytes
            if (size == amt) break :cfr_loop;
            if (amt == 0) break :cfr_loop;
            offset += amt;
        }
        return;
    }
    // Sendfile is a zero-copy mechanism iff the OS supports it, otherwise the
    // fallback code will copy the contents chunk by chunk.
    const empty_iovec = [0]std.posix.iovec_const{};
    var offset: u64 = 0;
    sendfile_loop: while (true) {
        const amt = try std.posix.sendfile(fd_out, fd_in, offset, 0, &empty_iovec, &empty_iovec, 0);
        copying_node.setCompletedItems(offset);
        // Terminate as soon as we have copied size bytes or no bytes
        if (size == amt) break :sendfile_loop;
        if (amt == 0) break :sendfile_loop;
        offset += amt;
    }
}
/// To use only filters exclusive to files or directories.
const Component = enum {
    file,
    directory,
    fn is_part_of(self: Component, component: json_struct.Filter.Component) bool {
        return switch (component) {
            .file => self == .file,
            .directory => self == .directory,
            .all => true,
        };
    }
};
const Filter = json_struct.Filter;
fn filter_filename(dir_depth: usize, component: Component, filename: []const u8, filters: ?[]const Filter) !bool {
    logger.print(.debug, .Filters, "Filtering filename '{[f]s}' (depth={[d]}, .{[c]s})\n", .{ .d = dir_depth, .c = @tagName(component), .f = filename });
    if (filters == null) return true;
    for (filters.?) |filter| {
        if (!component.is_part_of(filter.component)) {
            logger.print(.debug, .Filters, "{s:<8} {s:^11} filter {}\n", .{ "Skipping", "(component)", filter });
            continue;
        }
        const depth_skip_filter = switch (filter.depth_limit) { //Check if current file's depth matches the filter's depth.
            .lte => |v| dir_depth > v,
            .gte => |v| dir_depth < v,
            .range => |fr| dir_depth < fr.min or dir_depth > fr.max,
            .none => false,
        };
        if (depth_skip_filter) {
            logger.print(.debug, .Filters, "{s:<8} {s:^11} filter {}\n", .{ "Skipping", "(depth)", filter });
            continue;
        }
        logger.print(.debug, .Filters, "{s:<8} {s:^11} filter {}\n", .{ "Using", "", filter });
        var anchor_begin: bool = false;
        var anchor_end: bool = false;
        var adj_filter = filter.value; //Exclude filters.
        if (filter.value[0] == '^') {
            adj_filter = adj_filter[1..];
            anchor_begin = true;
        }
        if (filter.value[filter.value.len - 1] == '$') {
            adj_filter = adj_filter[0 .. adj_filter.len - 1];
            anchor_end = true;
        }
        const left_p = adj_filter[0] == '(';
        const right_p = adj_filter[adj_filter.len - 1] == ')';
        if ((left_p and !right_p) or (right_p and !left_p)) return error.MismatchedParenthesis;
        if (left_p and right_p) adj_filter = adj_filter[1 .. adj_filter.len - 1];
        var words_to_find = if (left_p and right_p) std.mem.tokenizeAny(u8, adj_filter, "|") else std.mem.tokenizeAny(u8, adj_filter, &.{});
        if (filter.type == .include) {
            while (words_to_find.next()) |word| {
                const index = std.mem.indexOf(u8, filename, word);
                if (index == null) continue; //Include filter fails
                if (anchor_begin) if (index.? != 0) continue; //Not anchored at beginning
                if (anchor_end) if (filename.len - index.? != word.len) continue; //Not anchored at end
                break;
            } else {
                logger.print(.debug, .Filters, "Filename '{s}' is disallowed (No matches in .include filter)\n", .{filename});
                return false; // Fail (All words don't match in a group).
            }
        } else { //.exclude is just .include, but fails filenam if all indices and anchors pass.
            while (words_to_find.next()) |word| {
                const index = std.mem.indexOf(u8, filename, word);
                if (index == null) continue;
                if (anchor_begin) if (index.? != 0) continue;
                if (anchor_end) if (filename.len - index.? != word.len) continue;
                logger.print(.debug, .Filters, "Filename '{s}' is disallowed (Matched .exclude filter)\n", .{filename});
                return false; //Fail (At least one word matched in a group).
            }
        }
    }
    logger.print(.debug, .Filters, "Filename '{s}' is allowed\n", .{filename});
    return true;
}
comptime {
    _ = @import("date.zig");
    _ = @import("tar.zig");
    _ = @import("json_struct.zig");
}
test {
    logger.partial_init();
    logger.scope.set(.Filters, false);
}
test "filter_filename allow no filter" {
    try std.testing.expect(try filter_filename(0, .file, "no_filters.txt", null));
}
test "filter_filename allow include" {
    try std.testing.expect(try filter_filename(0, .file, "thisshouldpass.txt", &[_]Filter{
        .{ .type = .include, .value = "shouldp" },
    }));
}
test "filter_filename disallow include" {
    try std.testing.expect(!try filter_filename(0, .file, "thisshouldnotpass.txt", &[_]Filter{
        .{ .type = .include, .value = "shoulds" },
    }));
}
test "filter_filename allow include anchor begin" {
    try std.testing.expect(try filter_filename(0, .file, "REQUIREDWORD.PNG", &[_]Filter{
        .{ .type = .include, .value = "^REQUIRED" },
    }));
}
test "filter_filename disallow include anchor begin not begin" {
    try std.testing.expect(!try filter_filename(0, .file, "BadGoodFile.jpg", &[_]Filter{
        .{ .type = .include, .value = "^Good" },
    }));
}
test "filter_filename allow include anchor end" {
    try std.testing.expect(try filter_filename(0, .file, "mustbe.txt", &[_]Filter{
        .{ .type = .include, .value = ".txt$" },
    }));
}
test "filter_filename disallow include anchor end not end" {
    try std.testing.expect(!try filter_filename(0, .file, "not_a_picture.bmp.txt", &[_]Filter{
        .{ .type = .include, .value = ".bmp$" },
    }));
}
test "filter_filename allow include anchor exact" {
    try std.testing.expect(try filter_filename(0, .file, "must_be_exact.ini", &[_]Filter{
        .{ .type = .include, .value = "^must_be_exact.ini$" },
    }));
}
test "filter_filename allow multiple include" {
    try std.testing.expect(try filter_filename(0, .file, "meets_expectations.json", &[_]Filter{
        .{ .type = .include, .value = "^meets" },
        .{ .type = .include, .value = ".json$" },
        .{ .type = .include, .value = "expectations" },
    }));
}
test "filter_filename disallow exclude" {
    try std.testing.expect(!try filter_filename(0, .file, "IAmRansomware.txt.exe", &[_]Filter{
        .{ .type = .exclude, .value = "Ransomware" },
    }));
}
test "filter_filename allow exclude" {
    try std.testing.expect(try filter_filename(0, .file, "IAmAGoodFile.json", &[_]Filter{
        .{ .type = .exclude, .value = "Bad" },
    }));
}
test "filter_filename disallow exclude anchor begin" {
    try std.testing.expect(!try filter_filename(0, .file, "Testfile_main.zig", &[_]Filter{
        .{ .type = .exclude, .value = "^Testfile_" },
    }));
}
test "filter_filename allow exclude anchor begin" {
    try std.testing.expect(try filter_filename(0, .file, "ThisIsNotATestfile_main.zig", &[_]Filter{
        .{ .type = .exclude, .value = "^Testfile_" },
    }));
}
test "filter_filename disallow exclude anchor end" {
    try std.testing.expect(!try filter_filename(0, .file, "no_bmps_allowed.bmp", &[_]Filter{
        .{ .type = .exclude, .value = ".bmp$" },
    }));
}
test "filter_filename allow exclude anchor end" {
    try std.testing.expect(try filter_filename(0, .file, "this_is_just_txt.bmp.txt", &[_]Filter{
        .{ .type = .exclude, .value = ".bmp$" },
    }));
}
test "filter_filename allow multiple exclude all fails" {
    try std.testing.expect(try filter_filename(0, .file, "not_test_script_that_steals_things.py.txt", &[_]Filter{
        .{ .type = .exclude, .value = "^test_" },
        .{ .type = .exclude, .value = ".py$" },
        .{ .type = .exclude, .value = "password_stealer" },
    }));
}
test "filter_filename allow multiple includes and excludes" {
    try std.testing.expect(try filter_filename(0, .file, "picture_that_doesnt_brick_phone.png", &[_]Filter{
        .{ .type = .include, .value = "^picture" },
        .{ .type = .include, .value = ".png$" },
        .{ .type = .exclude, .value = "bricks_phone" },
    }));
}
test "filter_filename allow include group" {
    try std.testing.expect(try filter_filename(0, .file, "confirm_true.txt", &[_]Filter{
        .{ .type = .include, .value = "(yes|true|1)" },
    }));
}
test "filter_filename disallow include group anchor end" {
    try std.testing.expect(!try filter_filename(0, .file, "not_a_picture.bmp.txt", &[_]Filter{
        .{ .type = .include, .value = "(.png|.gif|.jpg|.bmp)$" },
    }));
}
test "filter_filename allow exclude group" {
    try std.testing.expect(try filter_filename(0, .file, "normal_file.txt", &[_]Filter{
        .{ .type = .exclude, .value = "(virus|malware|exploit|ransomware)" },
    }));
}
test "filter_filename disallow exclude group anchor begin" {
    try std.testing.expect(!try filter_filename(0, .file, "8beginning_with_number.html", &[_]Filter{
        .{ .type = .exclude, .value = "^(1|2|3|4|5|6|7|8|9|0)" },
    }));
}
test "filter_filename allow include group anchor exact" {
    try std.testing.expect(try filter_filename(0, .file, "build.zig", &[_]Filter{
        .{ .type = .include, .value = "^(main.zig|build.zig|root.zig)$" },
    }));
}
test "filter_filename allow include group only one word" {
    try std.testing.expect(try filter_filename(0, .file, "should_be_ok", &[_]Filter{
        .{ .component = .file, .type = .include, .value = "(should_be_ok)" },
    }));
}
test "filter_filename allow include component only directory" {
    try std.testing.expect(try filter_filename(0, .directory, "folder_name", &[_]Filter{
        .{ .component = .directory, .type = .include, .value = "^folder_name$" },
    }));
}
test "filter_filename allow mixed exclusive to file/directory filters only" {
    try std.testing.expect(try filter_filename(0, .file, "not_virus", &[_]Filter{
        .{ .component = .directory, .type = .exclude, .value = "virus$" },
        .{ .component = .file, .type = .include, .value = "^not_" },
        .{ .component = .all, .type = .include, .value = "_" },
    }));
    try std.testing.expect(try filter_filename(0, .directory, "allowable", &[_]Filter{
        .{ .component = .directory, .type = .include, .value = "^allowable$" },
        .{ .component = .file, .type = .include, .value = "no" },
        .{ .component = .all, .type = .include, .value = "able$" },
        .{ .component = .file, .type = .include, .value = "^disallowable$" },
    }));
}
test "filter_filename allow include depth_limit lte" {
    try std.testing.expect(try filter_filename(0, .file, "filter_will_work", &[_]Filter{
        .{ .depth_limit = .{ .lte = 2 }, .type = .include, .value = "filter_will_work" },
    }));
    try std.testing.expect(try filter_filename(3, .file, "filter_will_not_work", &[_]Filter{
        .{ .depth_limit = .{ .lte = 2 }, .type = .include, .value = "filter_will_work" },
        .{ .depth_limit = .{ .lte = 3 }, .type = .include, .value = "filter_will" },
    }));
}
test "filter_filename allow include depth_limit gte" {
    try std.testing.expect(try filter_filename(2, .file, "filter_will_work", &[_]Filter{
        .{ .depth_limit = .{ .gte = 0 }, .type = .include, .value = "filter_will_work" },
    }));
    try std.testing.expect(try filter_filename(2, .file, "filter_will_not_work", &[_]Filter{
        .{ .depth_limit = .{ .gte = 4 }, .type = .include, .value = "filter_will_work" },
        .{ .depth_limit = .{ .gte = 2 }, .type = .include, .value = "filter_will" },
    }));
}
test "filter_filename allow include depth_limit range" {
    try std.testing.expect(try filter_filename(2, .file, "filter_will_work", &[_]Filter{
        .{ .depth_limit = .{ .range = .{ .min = 1, .max = 3 } }, .type = .include, .value = "filter_will_work" },
    }));
    try std.testing.expect(try filter_filename(4, .file, "filter_will_not_work", &[_]Filter{
        .{ .depth_limit = .{ .range = .{ .min = 1, .max = 3 } }, .type = .include, .value = "filter_will_work" },
        .{ .depth_limit = .{ .range = .{ .min = 2, .max = 4 } }, .type = .include, .value = "filter_will" },
        .{ .depth_limit = .{ .range = .{ .min = 4, .max = 5 } }, .type = .include, .value = "_will_" },
    }));
}
