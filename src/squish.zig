const std = @import("std");
const Squisher = @import("Squisher.zig");

const inputs = &.{
    .{
        .base_dir = "x86_64-linux-musl",
        .target = "x86_64-linux-musl",
    },
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .stack_trace_frames = 10,
    }){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    var squisher = try Squisher.init(allocator, inputs);
    defer squisher.deinit();

    try squisher.saveTo("out");
}
