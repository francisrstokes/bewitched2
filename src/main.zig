const std = @import("std");
const Allocator = @import("std").mem.Allocator;
const ansi = @import("./ansi.zig");

const yazap = @import("yazap");

const HEX_LINE_LEN = 2048;
const HexLineData = struct { offset: usize, end_offset: usize, buf: []u8, valid_bytes: usize };
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

pub fn get_bin_filepath(allocator: Allocator, path: []const u8) ![]u8 {
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

pub fn format_hex_line(data: *HexLineData, out_str: *HexLineStr) !void {
    // Clear the buffer
    @memset(out_str, 0);

    var formatter = SequentialLineFormatter(*HexLineStr){ .out_str = out_str };

    // Offset
    _ = try formatter.bufPrint("{s}{x:0>8} |{s}", .{ ansi.BOLD, data.offset, ansi.NORMAL });

    // Hex bytes
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        if (i < data.valid_bytes and data.offset + i <= data.end_offset) {
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
        if (i < data.valid_bytes and data.offset + i <= data.end_offset) {
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

    var app = yazap.App.init(allocator, "bw2", "Bewitched2 Hex Dumper");
    defer app.deinit();
    var bw2 = app.rootCommand();

    try bw2.addArg(yazap.Arg.positional("input", null, null));
    try bw2.addArg(yazap.Arg.singleValueOption("start", 's', "Start offset (hex)"));
    try bw2.addArg(yazap.Arg.singleValueOption("end", 'e', "End offset (hex)"));

    const matches = try app.parseProcess();

    if (!matches.containsArgs() or matches.getSingleValue("input") == null) {
        try app.displayHelp();
        return;
    }

    var offset: usize = 0;
    if (matches.getSingleValue("start")) |start| {
        offset = std.fmt.parseInt(usize, start, 16) catch brk: {
            std.debug.print("Error: Invalid start offset supplied: {s}\n", .{start});
            try app.displayHelp();
            std.os.exit(1);
            break :brk 0;
        };
    }

    var end_offset: usize = std.math.maxInt(usize);
    if (matches.getSingleValue("end")) |end| {
        end_offset = std.fmt.parseInt(usize, end, 16) catch brk: {
            std.debug.print("Error: Invalid end offset supplied: {s}\n", .{end});
            try app.displayHelp();
            std.os.exit(1);
            break :brk 0;
        };
    }

    if (end_offset < offset) {
        std.debug.print("Error: End offset cannot come before the start (start={x} end={x})\n", .{ offset, end_offset });
        std.os.exit(1);
    }

    const absolute_path = try get_bin_filepath(allocator, matches.getSingleValue("input").?);
    defer allocator.free(absolute_path);

    const file = try std.fs.openFileAbsolute(absolute_path, .{ .lock = std.fs.File.Lock.exclusive });
    defer file.close();

    var buf16 = try allocator.alloc(u8, 16);
    defer allocator.free(buf16);

    var hex_line: HexLineStr = std.mem.zeroes(HexLineStr);

    const out = std.io.getStdOut().writer();
    var buffered = std.io.bufferedWriter(out);
    var writer = buffered.writer();

    try file.seekTo(offset);
    const file_reader = file.reader();

    var hex_line_data = HexLineData{ .offset = offset, .end_offset = end_offset, .buf = buf16, .valid_bytes = 0 };
    while (true) {
        if (offset > end_offset) {
            break;
        }

        const bytes_read = try file_reader.read(buf16);
        if (bytes_read == 0) {
            break;
        }

        hex_line_data.valid_bytes = bytes_read;
        hex_line_data.offset = offset;

        try format_hex_line(&hex_line_data, &hex_line);
        try writer.print("{s}\n", .{hex_line});

        offset += bytes_read;
    }
    try buffered.flush();
}
