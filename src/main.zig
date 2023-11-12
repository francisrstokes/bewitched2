const std = @import("std");
const Allocator = @import("std").mem.Allocator;
const ansi = @import("./ansi.zig");

const HEX_LINE_LEN = 2048;
const HexLineData = struct { offset: usize, buf: []u8, valid_bytes: usize };
const HexLineStr = [HEX_LINE_LEN]u8;

fn SequentialLineFormatter(comptime T: type) type {
    return struct {
        const Self = @This();

        cursor: usize = 0,
        out_str: T,

        pub fn bufPrint(self: *Self, comptime fmt: []const u8, args: anytype) !void {
            var slice_written = try std.fmt.bufPrint(self.out_str[self.cursor..], fmt, args);
            self.cursor += slice_written.len;
        }
    };
}

pub fn get_bin_filepath(allocator: Allocator, path: []u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        const absolute_path = try allocator.alloc(u8, path.len);
        @memcpy(absolute_path, path);
        return absolute_path;
    } else {
        const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
        defer allocator.free(cwd);
        return std.fs.path.resolve(allocator, &.{ cwd, path });
    }
}

pub fn print_usage_and_exit(prog_name: []u8, exit_code: u8) void {
    std.debug.print("usage: {s} <file> [--start=offset]\n", .{prog_name});
    std.os.exit(exit_code);
}

pub fn write_hex_line(data: HexLineData, out_str: *HexLineStr) !void {
    // Clear the buffer
    out_str.* = std.mem.zeroes(HexLineStr);

    var formatter = SequentialLineFormatter(*HexLineStr){ .out_str = out_str };

    // Offset
    _ = try formatter.bufPrint("{s}{x:0>8} |{s}", .{ ansi.BOLD, data.offset, ansi.NORMAL });

    // Hex bytes
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        if (i < data.valid_bytes) {
            switch (data.buf[i]) {
                0x00...0x19 => _ = try formatter.bufPrint(" {x:0>2}", .{data.buf[i]}),
                0x20...0x7e => _ = try formatter.bufPrint(" {s}{s}{x:0>2}{s}", .{ ansi.UNDERLINE, ansi.YELLOW, data.buf[i], ansi.NORMAL }),
                else => _ = try formatter.bufPrint(" {s}{x:0>2}{s}", .{ ansi.BLUE, data.buf[i], ansi.NORMAL }),
            }
        } else {
            _ = try formatter.bufPrint("   ", .{});
        }
    }
    _ = try formatter.bufPrint(" {s}|{s}", .{ ansi.BOLD, ansi.NORMAL });

    // ASCII section
    i = 0;
    while (i < 16) : (i += 1) {
        if (i < data.valid_bytes) {
            switch (data.buf[i]) {
                0x00...0x19 => _ = try formatter.bufPrint(".", .{}),
                0x20...0x7e => _ = try formatter.bufPrint("{s}{c}{s}", .{ ansi.YELLOW, data.buf[i], ansi.NORMAL }),
                else => _ = try formatter.bufPrint("{s}.{s}", .{ ansi.BLUE, ansi.NORMAL }),
            }
        } else {
            _ = try formatter.bufPrint(" ", .{});
        }
    }
    _ = try formatter.bufPrint("{s}|{s}", .{ ansi.BOLD, ansi.NORMAL });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        _ = gpa.deinit();
    }

    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 2) {
        print_usage_and_exit(args[0], 1);
    }

    const absolute_path = try get_bin_filepath(allocator, args[1]);
    defer allocator.free(absolute_path);

    const file = try std.fs.openFileAbsolute(absolute_path, .{ .lock = std.fs.File.Lock.exclusive });
    defer file.close();

    var buf16 = try allocator.alloc(u8, 16);
    defer allocator.free(buf16);

    var hex_line: HexLineStr = std.mem.zeroes(HexLineStr);

    const out = std.io.getStdOut().writer();
    var buffered = std.io.bufferedWriter(out);
    var writer = buffered.writer();

    var offset: usize = 0;
    try file.seekTo(offset);
    const file_reader = file.reader();
    while (true) {
        const bytes_read = try file_reader.read(buf16);
        if (bytes_read == 0) {
            break;
        }

        try write_hex_line(.{ .offset = offset, .buf = buf16, .valid_bytes = bytes_read }, &hex_line);
        try writer.print("{s}\n", .{hex_line});
        offset += bytes_read;
    }
    try buffered.flush();
}
