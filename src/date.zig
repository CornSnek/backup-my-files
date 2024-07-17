//! To convert a unix timestamp to a date using `Date.to_str_format`
const std = @import("std");
const windows = @import("std").os.windows;
pub fn get_timezone(allocator: std.mem.Allocator) !?i8 {
    if (@import("builtin").os.tag == .windows) {
        const lm = windows.HKEY_LOCAL_MACHINE;
        const tzistr = try std.unicode.utf8ToUtf16LeAllocZ(allocator, "SYSTEM\\CurrentControlSet\\Control\\TimeZoneInformation");
        defer allocator.free(tzistr);
        var tzi: windows.HKEY = undefined;
        var res = windows.advapi32.RegOpenKeyExW(lm, tzistr, 0, windows.KEY_READ, &tzi);
        if (res != 0) return null;
        defer _ = windows.advapi32.RegCloseKey(tzi);
        const biasstr = try std.unicode.utf8ToUtf16LeAllocZ(allocator, "ActiveTimeBias");
        defer allocator.free(biasstr);
        var data: i32 = undefined;
        var data_len: windows.DWORD = undefined; //'data' is 4 bytes, but ReQueryValueExW requires it to get data.
        res = windows.advapi32.RegQueryValueExW(tzi, biasstr, null, null, @ptrCast(&data), &data_len);
        if (res != 0) return null;
        return @truncate(@divTrunc(data, -60)); //ActiveTimeBias/-60 = Hours in Timezone
    } else { //TODO: Timezone for other os
        return null;
    }
}
pub const Date = struct {
    pub const DayNames = enum { // zig fmt: off
        Sunday, Monday, Tuesday, Wednesday, Thursday, Friday, Saturday,
        // zig fmt: on
        pub fn str(self: DayNames) []const u8 {
            return std.meta.fieldNames(DayNames)[@intFromEnum(self)];
        }
        pub fn abr(self: DayNames) []const u8 {
            return std.meta.fieldNames(DayNames)[@intFromEnum(self)][0..3];
        }
    };
    pub const MonthNames = enum { // zig fmt: off
        January, February, March, April, May, June, July, August, September, October, November, December,
        // zig fmt: on
        pub fn str(self: MonthNames) []const u8 {
            return std.meta.fieldNames(MonthNames)[@intFromEnum(self)];
        }
        pub fn abr(self: MonthNames) []const u8 {
            return std.meta.fieldNames(MonthNames)[@intFromEnum(self)][0..3];
        }
    };
    /// Valid month numbers from 0 (January) to 11 (December).
    pub fn ToMonthEnum(self: Date) ?MonthNames {
        return if (self.month < std.meta.fields(MonthNames).len)
            @enumFromInt(self.month)
        else
            null;
    }
    /// Valid day name numbers from 0 (Sunday) to 6 (Saturday).
    pub fn ToWeekdayEnum(self: Date) ?DayNames {
        return if (self.weekday_i < std.meta.fields(DayNames).len)
            @enumFromInt(self.weekday_i)
        else
            null;
    }
    year: u32 = 0,
    month: u8 = 0,
    day: u8 = 0,
    hour: u8 = 0,
    minute: u8 = 0,
    second: u8 = 0,
    /// 0 (Sunday) to 6 (Saturday)
    weekday_i: u8 = 0,
    /// Order is year to second from most to least significance, excluding weekday_i.
    pub fn order(self: Date, rhs: Date) std.math.Order {
        inline for (std.meta.fields(Date)) |f| {
            comptime if (std.mem.eql(u8, f.name, "weekday_i")) break;
            const cmp_order = std.math.order(@field(self, f.name), @field(rhs, f.name));
            if (cmp_order != .eq) return cmp_order;
        }
        return .eq;
    }
    /// Enum to make month/day adjust by +1 or -1 using Date.adj().
    pub const Indexing = enum { zero_to_one, one_to_zero };
    /// Add month and day by +1 (.zero_to_one) or by -1 (.one_to_zero).
    pub fn adj(self: Date, indexing: Indexing) Date {
        return .{
            .year = self.year,
            .month = if (indexing == .zero_to_one) self.month + 1 else self.month - 1,
            .day = if (indexing == .zero_to_one) self.day + 1 else self.day - 1,
            .hour = self.hour,
            .minute = self.minute,
            .second = self.second,
            .weekday_i = self.weekday_i,
        };
    }
    pub fn init(timestamp: i64) Date {
        return init_with_timezone(timestamp, 0);
    }
    pub fn init_with_timezone(timestamp: i64, timezone: i8) Date {
        const SECONDS_PER_MINUTE = 60;
        const SECONDS_PER_HOUR = 60 * SECONDS_PER_MINUTE;
        const SECONDS_PER_DAY = 24 * SECONDS_PER_HOUR;
        const DAYS_IN_MONTH = [_]u8{ 31, 0, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        const adj_timestamp: i64 = timestamp + @as(i64, timezone) * SECONDS_PER_HOUR;
        var remaining = adj_timestamp;
        var date: Date = .{ .year = 1970 };
        if (remaining >= 0) {
            while (true) : (date.year += 1) { //year if positive timestamp
                const days_in_year: i64 = if (is_leap_year(date.year)) 366 else 365;
                const seconds_in_year: i64 = days_in_year * SECONDS_PER_DAY;
                if (remaining < seconds_in_year) break;
                remaining -= seconds_in_year;
            }
        } else {
            while (true) { //year if negative timestamp
                date.year -= 1;
                const days_in_year: i64 = if (is_leap_year(date.year)) 366 else 365;
                const seconds_in_year: i64 = days_in_year * SECONDS_PER_DAY;
                if (-remaining < seconds_in_year) break;
                remaining += seconds_in_year;
            }
            remaining += @as(i64, if (is_leap_year(date.year)) 366 else 365) * SECONDS_PER_DAY;
        }
        while (true) : (date.month += 1) { //month
            var days_in_month: i64 = DAYS_IN_MONTH[date.month];
            if (days_in_month == 0) days_in_month = if (is_leap_year(date.year)) 29 else 28;
            if (remaining < days_in_month * SECONDS_PER_DAY) break;
            remaining -= days_in_month * SECONDS_PER_DAY;
            if (date.month == 11) { //Readjust year/month if december (=11)
                date.year += 1;
                date.month = 0;
                break;
            }
        }
        date.day = @intCast(@divFloor(remaining, SECONDS_PER_DAY));
        remaining = @rem(remaining, SECONDS_PER_DAY);
        date.hour = @intCast(@divFloor(remaining, SECONDS_PER_HOUR));
        remaining = @rem(remaining, SECONDS_PER_HOUR);
        date.minute = @intCast(@divFloor(remaining, SECONDS_PER_MINUTE));
        date.second = @intCast(@rem(remaining, SECONDS_PER_MINUTE));
        //weekday_i
        const total_days: i64 = @divFloor(adj_timestamp, SECONDS_PER_DAY);
        const weekday_i: u8 = @intCast(@rem((@rem(total_days + 4, 7) + 7), 7)); //If negative for the first @rem, add by 7 and @rem 7 again.
        date.weekday_i = weekday_i;
        return date;
    }
    fn is_leap_year(year: i64) bool {
        return if (@rem(year, 4) != 0) false else if (@rem(year, 100) == 0 and @rem(year, 400) != 0) false else true;
    }
    /// Valid format specifiers based from https://linux.die.net/man/1/date
    /// - `%%` a literal %
    /// - `%a` abbreviated weekday name (e.g., Sun)
    /// - `%A` full weekday name (e.g. Sunday)
    /// - `%b` abbreviated month name (e.g., Jan)
    /// - `%B` full month name (e.g., January)
    /// - `%d` day of month (e.g, 01)
    /// - `%H` hour (00..23)
    /// - `%I` hour (01..12)
    /// - `%m` month (01..12)
    /// - `%M` minute (00..59)
    /// - `%p` AM or PM
    /// - `%P` am or pm
    /// - `%S` second (00..60)
    /// - `%Y` year
    ///
    /// Caller owns string memory.
    pub fn to_str_format(date: Date, format: []const u8, allocator: std.mem.Allocator) ![]u8 {
        const stderr = std.io.getStdErr().writer();
        var replace_arr = try allocator.alloc(Replace, 0);
        defer {
            for (replace_arr) |r| r.deinit(allocator);
            allocator.free(replace_arr);
        }
        var w: usize = 0;
        while (w < format.len - 1) {
            if (format[w] == '%') {
                switch (format[w + 1]) {
                    '%', 'a', 'A', 'b', 'B', 'd', 'H', 'I', 'm', 'M', 'p', 'P', 'S', 'Y' => |c| {
                        replace_arr = try allocator.realloc(replace_arr, replace_arr.len + 1);
                        switch (c) {
                            //&[2]u8{ '%', c2 } because comptime with inline '(character)' => |c2|. Example: &[2]u8{'%','a'} becomes "%a", excluding sentiel :0
                            inline '%' => |c2| replace_arr[replace_arr.len - 1] = Replace.init_static(&[2]u8{ '%', c2 }, "%"),
                            inline 'a' => |c2| {
                                const wd_str = try allocator.dupe(u8, date.ToWeekdayEnum().?.abr());
                                replace_arr[replace_arr.len - 1] = Replace.init_alloc(&[2]u8{ '%', c2 }, wd_str);
                            },
                            inline 'A' => |c2| {
                                const wd_str = try allocator.dupe(u8, date.ToWeekdayEnum().?.str());
                                replace_arr[replace_arr.len - 1] = Replace.init_alloc(&[2]u8{ '%', c2 }, wd_str);
                            },
                            inline 'b' => |c2| {
                                const month_str = try allocator.dupe(u8, date.ToMonthEnum().?.abr());
                                replace_arr[replace_arr.len - 1] = Replace.init_alloc(&[2]u8{ '%', c2 }, month_str);
                            },
                            inline 'B' => |c2| {
                                const month_str = try allocator.dupe(u8, date.ToMonthEnum().?.str());
                                replace_arr[replace_arr.len - 1] = Replace.init_alloc(&[2]u8{ '%', c2 }, month_str);
                            },
                            inline 'd' => |c2| {
                                //Adjust .day because it is zero-indexed
                                const day_str = try std.fmt.allocPrint(allocator, "{:0>2}", .{date.day + 1});
                                replace_arr[replace_arr.len - 1] = Replace.init_alloc(&[2]u8{ '%', c2 }, day_str);
                            },
                            inline 'H' => |c2| {
                                const hr_str = try std.fmt.allocPrint(allocator, "{:0>2}", .{date.hour});
                                replace_arr[replace_arr.len - 1] = Replace.init_alloc(&[2]u8{ '%', c2 }, hr_str);
                            },
                            inline 'I' => |c2| {
                                const adj_date_hr: u8 = if (date.hour % 12 != 0) date.hour % 12 else 12;
                                const hr_str = try std.fmt.allocPrint(allocator, "{:0>2}", .{adj_date_hr});
                                replace_arr[replace_arr.len - 1] = Replace.init_alloc(&[2]u8{ '%', c2 }, hr_str);
                            },
                            inline 'm' => |c2| {
                                //Adjust .month because it is zero-indexed
                                const month_str = try std.fmt.allocPrint(allocator, "{:0>2}", .{date.month + 1});
                                replace_arr[replace_arr.len - 1] = Replace.init_alloc(&[2]u8{ '%', c2 }, month_str);
                            },
                            inline 'M' => |c2| {
                                const m_str = try std.fmt.allocPrint(allocator, "{:0>2}", .{date.minute});
                                replace_arr[replace_arr.len - 1] = Replace.init_alloc(&[2]u8{ '%', c2 }, m_str);
                            },
                            inline 'p' => |c2| replace_arr[replace_arr.len - 1] = Replace.init_static(&[2]u8{ '%', c2 }, if (date.hour >= 12) "PM" else "AM"),
                            inline 'P' => |c2| replace_arr[replace_arr.len - 1] = Replace.init_static(&[2]u8{ '%', c2 }, if (date.hour >= 12) "pm" else "am"),
                            inline 'S' => |c2| {
                                const s_str = try std.fmt.allocPrint(allocator, "{:0>2}", .{date.second});
                                replace_arr[replace_arr.len - 1] = Replace.init_alloc(&[2]u8{ '%', c2 }, s_str);
                            },
                            inline 'Y' => |c2| {
                                const y_str = try std.fmt.allocPrint(allocator, "{:0>4}", .{date.year});
                                replace_arr[replace_arr.len - 1] = Replace.init_alloc(&[2]u8{ '%', c2 }, y_str);
                            },
                            else => unreachable,
                        }
                        w += replace_arr[replace_arr.len - 1].replace.len;
                    },
                    else => |c| {
                        try stderr.print("%{c} is an invalid or unimplemented format specifier.\n", .{c});
                        return error.InvalidFormatSpecifier;
                    },
                }
            } else w += 1;
        }
        var new_str_len: usize = format.len;
        for (replace_arr) |r| {
            const diff = r.diff();
            if (diff.neg) {
                new_str_len -= diff.value;
            } else new_str_len += diff.value;
        }
        const new_str = try allocator.alloc(u8, new_str_len);
        errdefer allocator.free(new_str);
        var new_str_begin: usize = 0;
        var non_rep_begin: usize = 0;
        var non_rep_end: usize = 0;
        var old_non_rep_end: usize = 0;
        for (0..replace_arr.len) |i| {
            const replacement = replace_arr[i];
            //format[old_non_rep_end..] to get the new index of a format specifier (If more than one).
            non_rep_begin = std.mem.indexOf(u8, format[old_non_rep_end..], replacement.replace).? + old_non_rep_end;
            non_rep_end = non_rep_begin + replacement.replace.len;
            //Non-replacement slice copy.
            @memcpy(new_str[new_str_begin .. new_str_begin + (non_rep_begin - old_non_rep_end)], format[old_non_rep_end..non_rep_begin]);
            new_str_begin += non_rep_begin - old_non_rep_end;
            //Replacement slice copy.
            @memcpy(new_str[new_str_begin .. new_str_begin + replacement.with.len], replacement.with);
            new_str_begin += replacement.with.len;
            old_non_rep_end = non_rep_end;
        }
        //Last non-replacement slice copy (Should be equal).
        @memcpy(new_str[new_str_begin..], format[non_rep_end..]);
        return new_str;
    }
    const Replace = struct {
        replace: []const u8,
        with: []const u8,
        is_alloc: bool,
        /// Replace.deinit() will not deallocate the 'with' string.
        fn init_static(replace: []const u8, with: []const u8) Replace {
            return .{ .replace = replace, .with = with, .is_alloc = false };
        }
        /// Replace.deinit() will deallocate the 'with' string.
        fn init_alloc(replace: []const u8, with: []const u8) Replace {
            return .{ .replace = replace, .with = with, .is_alloc = true };
        }
        fn diff(self: Replace) Difference {
            return if (self.replace.len >= self.with.len) .{ .value = self.replace.len - self.with.len, .neg = true } else .{ .value = self.with.len - self.replace.len };
        }
        /// Will .deinit() 'with' allocated strings only.
        fn deinit(self: Replace, allocator: std.mem.Allocator) void {
            if (self.is_alloc) allocator.free(self.with);
        }
        const Difference = struct { neg: bool = false, value: usize };
    };
};
fn assert_dates_equal(timestamp: i64, date_cmp: Date) !void {
    std.testing.expectEqual(date_cmp, Date.init(timestamp)) catch |e| {
        std.debug.print("Test failed:\n\tTimestamp: {}\n\tTimestamp to Date: {any}\n\tDate to compare: {any}\n", .{ timestamp, Date.init(timestamp), date_cmp });
        return e;
    };
}
test "Date order eq" {
    const date1 = Date.init(123456789);
    const date2 = Date.init(123456789);
    try std.testing.expect(date1.order(date2) == .eq);
}
test "Date order lt ge" {
    const date1 = Date.init(123456789);
    const date2 = Date.init(234567890);
    try std.testing.expect(date1.order(date2) == .lt);
    try std.testing.expect(date2.order(date1) == .gt);
}
test "Date order eq weekday_i different" {
    const date1 = Date{ .year = 1234, .month = 5, .day = 6, .hour = 7, .minute = 8, .second = 9, .weekday_i = 1 };
    const date2 = Date{ .year = 1234, .month = 5, .day = 6, .hour = 7, .minute = 8, .second = 9, .weekday_i = 2 };
    try std.testing.expect(date1.order(date2) == .eq);
}
test "Date epoch start" {
    try assert_dates_equal(0, Date{ .year = 1970, .weekday_i = 4 });
}
test "Date start of leap day" {
    try assert_dates_equal(1582934400, (Date{ .year = 2020, .month = 2, .day = 29, .weekday_i = 6 }).adj(.one_to_zero));
}
test "Date end of february no leap day" {
    try assert_dates_equal(1551398399, (Date{ .year = 2019, .month = 2, .day = 28, .hour = 23, .minute = 59, .second = 59, .weekday_i = 4 }).adj(.one_to_zero));
}
test "Date end of february leap day" {
    try assert_dates_equal(1583020799, (Date{ .year = 2020, .month = 2, .day = 29, .hour = 23, .minute = 59, .second = 59, .weekday_i = 6 }).adj(.one_to_zero));
}
test "Date start of no leap year" {
    try assert_dates_equal(1609459200, (Date{ .year = 2021, .month = 1, .day = 1, .weekday_i = 5 }).adj(.one_to_zero));
}
test "Date start of leap year" {
    try assert_dates_equal(1451606400, (Date{ .year = 2016, .month = 1, .day = 1, .weekday_i = 5 }).adj(.one_to_zero));
}
test "Date end of a month" {
    try assert_dates_equal(996623999, (Date{ .year = 2001, .month = 7, .day = 31, .hour = 23, .minute = 59, .second = 59, .weekday_i = 2 }).adj(.one_to_zero));
}
test "Date start of a month" {
    try assert_dates_equal(1283299200, (Date{ .year = 2010, .month = 9, .day = 1, .weekday_i = 3 }).adj(.one_to_zero));
}
test "Date negative" {
    try assert_dates_equal(-1, (Date{ .year = 1969, .month = 12, .day = 31, .hour = 23, .minute = 59, .second = 59, .weekday_i = 3 }).adj(.one_to_zero));
}
test "Date year begin 1000" {
    try assert_dates_equal(-30610224000, (Date{ .year = 1000, .month = 1, .day = 1, .weekday_i = 3 }).adj(.one_to_zero));
}
test "Date year end 1000" {
    try assert_dates_equal(-30578688001, (Date{ .year = 1000, .month = 12, .day = 31, .hour = 23, .minute = 59, .second = 59, .weekday_i = 3 }).adj(.one_to_zero));
}
test "Date start of leap day negative" {
    try assert_dates_equal(-29974060800, (Date{ .year = 1020, .month = 2, .day = 29, .weekday_i = 2 }).adj(.one_to_zero));
}
test "Date end of february no leap day negative" {
    try assert_dates_equal(-30005596801, (Date{ .year = 1019, .month = 2, .day = 28, .hour = 23, .minute = 59, .second = 59, .weekday_i = 0 }).adj(.one_to_zero));
}
test "Date end of february leap day negative" {
    try assert_dates_equal(-29973974401, (Date{ .year = 1020, .month = 2, .day = 29, .hour = 23, .minute = 59, .second = 59, .weekday_i = 2 }).adj(.one_to_zero));
}
test "Date start of no leap year negative" {
    try assert_dates_equal(-29947536000, (Date{ .year = 1021, .month = 1, .day = 1, .weekday_i = 1 }).adj(.one_to_zero));
}
test "Date start of leap year negative" {
    try assert_dates_equal(-29852928000, (Date{ .year = 1024, .month = 1, .day = 1, .weekday_i = 4 }).adj(.one_to_zero));
}
test "Date end of a month negative" {
    try assert_dates_equal(-30560371201, (Date{ .year = 1001, .month = 7, .day = 31, .hour = 23, .minute = 59, .second = 59, .weekday_i = 5 }).adj(.one_to_zero));
}
test "Date start of a month negative" {
    try assert_dates_equal(-30273696000, (Date{ .year = 1010, .month = 9, .day = 1, .weekday_i = 6 }).adj(.one_to_zero));
}
test "Replace static" {
    const replace = Date.Replace.init_static("a", "b");
    replace.deinit(std.testing.allocator);
}
test "Replace allocated" {
    const alloc_string = try std.testing.allocator.dupe(u8, "c");
    const replace = Date.Replace.init_alloc("a", alloc_string);
    replace.deinit(std.testing.allocator);
}
test "Replace diff" {
    const replace = Date.Replace.init_static("abcd", "e");
    const replace2 = Date.Replace.init_static("a", "bcd");
    const replace3 = Date.Replace.init_static("abc", "def");
    try std.testing.expectEqual(Date.Replace.Difference{ .value = 3, .neg = true }, replace.diff());
    try std.testing.expectEqual(Date.Replace.Difference{ .value = 2, .neg = false }, replace2.diff());
    try std.testing.expectEqual(Date.Replace.Difference{ .value = 0, .neg = true }, replace3.diff());
}
test "Date to_str_format No format" {
    const date = Date.init(0);
    const str = try date.to_str_format("ABC", std.testing.allocator);
    defer std.testing.allocator.free(str);
    try std.testing.expectEqualStrings("ABC", str);
}
test "Date to_str_format percent format" {
    const date = Date.init(0);
    const str = try date.to_str_format("%%AB%%%%C%%", std.testing.allocator);
    defer std.testing.allocator.free(str);
    try std.testing.expectEqualStrings("%AB%%C%", str);
}
test "Date to_str_format b B format" {
    const date = (Date{ .month = 2, .day = 1 }).adj(.one_to_zero);
    const str = try date.to_str_format("Month abr=%b full=%B", std.testing.allocator);
    defer std.testing.allocator.free(str);
    try std.testing.expectEqualStrings("Month abr=Feb full=February", str);
}
test "Date to_str_format d format" {
    const date1 = (Date{ .month = 1, .day = 2 }).adj(.one_to_zero);
    const str1 = try date1.to_str_format("day=%d", std.testing.allocator);
    defer std.testing.allocator.free(str1);
    try std.testing.expectEqualStrings("day=02", str1);
    const date2 = (Date{ .month = 1, .day = 23 }).adj(.one_to_zero);
    const str2 = try date2.to_str_format("day=%d", std.testing.allocator);
    defer std.testing.allocator.free(str2);
    try std.testing.expectEqualStrings("day=23", str2);
}
test "Date to_str_format H I p P format" {
    const date = Date{ .hour = 13 };
    const str = try date.to_str_format("hour (military)=%H (am/pm)=%I %p %P", std.testing.allocator);
    defer std.testing.allocator.free(str);
    try std.testing.expectEqualStrings("hour (military)=13 (am/pm)=01 PM pm", str);
    const date2 = Date{ .hour = 5 };
    const str2 = try date2.to_str_format("hour (military)=%H (am/pm)=%I %p %P", std.testing.allocator);
    defer std.testing.allocator.free(str2);
    try std.testing.expectEqualStrings("hour (military)=05 (am/pm)=05 AM am", str2);
}
test "Date to_str_format H I p P format 2" {
    const date = Date{ .hour = 12 };
    const str = try date.to_str_format("hour (military)=%H (am/pm)=%I %p %P", std.testing.allocator);
    defer std.testing.allocator.free(str);
    try std.testing.expectEqualStrings("hour (military)=12 (am/pm)=12 PM pm", str);
    const date2 = Date{ .hour = 0 };
    const str2 = try date2.to_str_format("hour (military)=%H (am/pm)=%I %p %P", std.testing.allocator);
    defer std.testing.allocator.free(str2);
    try std.testing.expectEqualStrings("hour (military)=00 (am/pm)=12 AM am", str2);
}
test "Date to_str_format m format" {
    const date = (Date{ .month = 7, .day = 1 }).adj(.one_to_zero);
    const str = try date.to_str_format("month=%m", std.testing.allocator);
    defer std.testing.allocator.free(str);
    try std.testing.expectEqualStrings("month=07", str);
    const date2 = (Date{ .month = 12, .day = 1 }).adj(.one_to_zero);
    const str2 = try date2.to_str_format("month=%m", std.testing.allocator);
    defer std.testing.allocator.free(str2);
    try std.testing.expectEqualStrings("month=12", str2);
    const date3 = (Date{ .month = 1, .day = 1 }).adj(.one_to_zero);
    const str3 = try date3.to_str_format("month=%m", std.testing.allocator);
    defer std.testing.allocator.free(str3);
    try std.testing.expectEqualStrings("month=01", str3);
}
test "Date to_str_format H M S format" {
    const date = Date{ .hour = 12, .minute = 34, .second = 56 };
    const str = try date.to_str_format("%H:%M:%S", std.testing.allocator);
    defer std.testing.allocator.free(str);
    try std.testing.expectEqualStrings("12:34:56", str);
}
test "Date to_str_format Y format" {
    const date = Date{ .year = 1234 };
    const str = try date.to_str_format("%Y", std.testing.allocator);
    defer std.testing.allocator.free(str);
    try std.testing.expectEqualStrings("1234", str);
}
test "Date to_str_format A a format" {
    const date = Date{ .weekday_i = 6 };
    const str = try date.to_str_format("%A %a", std.testing.allocator);
    defer std.testing.allocator.free(str);
    try std.testing.expectEqualStrings("Saturday Sat", str);
}
