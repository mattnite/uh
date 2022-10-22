const std = @import("std");
const Merger = @import("Merger.zig");

const inputs: []const Merger.Input = &.{
    .{
        .base_dir = "headers/aarch64-linux-gnu.2.33",
        .name = "aarch64-linux-gnu.2.33",
        .defines = &.{
            .{ .key = "__linux__" },
            .{ .key = "__aarch64__" },
            .{ .key = "__GNUC__", .value = "2" },
            .{ .key = "__GNUC_MINOR__", .value = "33" },
        },
    },
    .{
        .base_dir = "headers/aarch64-linux-gnu.2.34",
        .name = "aarch64-linux-gnu.2.34",
        .defines = &.{
            .{ .key = "__linux__" },
            .{ .key = "__aarch64__" },
            .{ .key = "__GNUC__", .value = "2" },
            .{ .key = "__GNUC_MINOR__", .value = "34" },
        },
    },
    .{
        .base_dir = "headers/x86_64-macos.10-none",
        .name = "x86_64-macos.10-none",
        .defines = &.{
            .{ .key = "__linux__" },
            .{ .key = "__x86_64__" },
            .{ .key = "__macos_sdk__", .value = "10" },
        },
    },
    .{
        .base_dir = "headers/x86_64-macos.11-none",
        .name = "x86_64-macos.11-none",
        .defines = &.{
            .{ .key = "__linux__" },
            .{ .key = "__x86_64__" },
            .{ .key = "__macos_sdk__", .value = "11" },
        },
    },
    .{
        .base_dir = "headers/x86_64-macos.12-none",
        .name = "x86_64-macos.12-none",
        .defines = &.{
            .{ .key = "__linux__" },
            .{ .key = "__x86_64__" },
            .{ .key = "__macos_sdk__", .value = "12" },
        },
    },
    .{
        .base_dir = "headers/riscv64-linux-musl",
        .name = "riscv64-linux-musl",
        .defines = &.{
            .{ .key = "__linux__" },
            .{ .key = "__riscv64__" },
            .{ .key = "__zig_musl__" },
        },
    },
    .{
        .base_dir = "headers/powerpc64-linux-musl",
        .name = "powerpc64-linux-musl",
        .defines = &.{
            .{ .key = "__linux__" },
            .{ .key = "__powerpc64__" },
            .{ .key = "__zig_musl__" },
        },
    },
    .{
        .base_dir = "headers/powerpc-linux-musl",
        .name = "powerpc-linux-musl",
        .defines = &.{
            .{ .key = "__linux__" },
            .{ .key = "__powerpc__" },
            .{ .key = "__zig_musl__" },
        },
    },
    .{
        .base_dir = "headers/mips64-linux-musl",
        .name = "mips64-linux-musl",
        .defines = &.{
            .{ .key = "__linux__" },
            .{ .key = "__mips64__" },
            .{ .key = "__zig_musl__" },
        },
    },
    .{
        .base_dir = "headers/mips-linux-musl",
        .name = "mips-linux-musl",
        .defines = &.{
            .{ .key = "__linux__" },
            .{ .key = "__mips__" },
            .{ .key = "__zig_musl__" },
        },
    },
    .{
        .base_dir = "headers/arm-linux-musl",
        .name = "arm-linux-musl",
        .defines = &.{
            .{ .key = "__linux__" },
            .{ .key = "__arm__" },
            .{ .key = "__zig_musl__" },
        },
    },
    .{
        .base_dir = "headers/aarch64-linux-musl",
        .name = "aarch64-linux-musl",
        .defines = &.{
            .{ .key = "__linux__" },
            .{ .key = "__aarch64__" },
            .{ .key = "__zig_musl__" },
        },
    },
    .{
        .base_dir = "headers/aarch64-macos.11-none",
        .name = "aarch64-macos.11-none",
        .defines = &.{
            .{ .key = "__macos__" },
            .{ .key = "__aarch64__" },
            .{ .key = "__macos_sdk__", .value = "11" },
        },
    },
    .{
        .base_dir = "headers/aarch64-macos.12-none",
        .name = "aarch64-macos.12-none",
        .defines = &.{
            .{ .key = "__macos__" },
            .{ .key = "__aarch64__" },
            .{ .key = "__macos_sdk__", .value = "12" },
        },
    },
    .{
        .base_dir = "headers/x86_64-linux-musl",
        .name = "x86_64-linux-musl",
        .defines = &.{
            .{ .key = "__linux__" },
            .{ .key = "__x86_64__" },
            .{ .key = "__zig_musl__" },
        },
    },
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .stack_trace_frames = 10,
    }){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    var merger = try Merger.init(allocator);
    defer merger.deinit();

    for (inputs) |input|
        try merger.addInput(input);

    try merger.index();
    try std.io.getStdErr().writer().print("index is roughly {} bytes\n", .{merger.getByteSize()});
    try merger.merge();

    try merger.saveTo("out");
}

test "all" {
    std.testing.refAllDeclsRecursive(Merger);
}
