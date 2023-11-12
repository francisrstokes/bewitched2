const std = @import("std");

pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "bw2",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    });

    exe.addAnonymousModule("yazap", .{
        .source_file = .{ .path = "libs/yazap/src/lib.zig" },
    });

    b.installArtifact(exe);
}
