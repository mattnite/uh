const std = @import("std");
const Merger = @import("Merger.zig");

//const inputs: []const Merger.Input = &.{
//    .{
//        .base_dir = "headers/aarch64-linux-gnu.2.33",
//        .name = "aarch64-linux-gnu.2.33",
//        .defines = &.{
//            .{ .key = "__linux__" },
//            .{ .key = "__aarch64__" },
//            .{ .key = "__GNUC__", .value = "2" },
//            .{ .key = "__GNUC_MINOR__", .value = "33" },
//        },
//    },
//    .{
//        .base_dir = "headers/aarch64-linux-gnu.2.34",
//        .name = "aarch64-linux-gnu.2.34",
//        .defines = &.{
//            .{ .key = "__linux__" },
//            .{ .key = "__aarch64__" },
//            .{ .key = "__GNUC__", .value = "2" },
//            .{ .key = "__GNUC_MINOR__", .value = "34" },
//        },
//    },
//    .{
//        .base_dir = "headers/x86_64-macos.10-none",
//        .name = "x86_64-macos.10-none",
//        .defines = &.{
//            .{ .key = "__linux__" },
//            .{ .key = "__x86_64__" },
//            .{ .key = "__macos_sdk__", .value = "10" },
//        },
//    },
//    .{
//        .base_dir = "headers/x86_64-macos.11-none",
//        .name = "x86_64-macos.11-none",
//        .defines = &.{
//            .{ .key = "__linux__" },
//            .{ .key = "__x86_64__" },
//            .{ .key = "__macos_sdk__", .value = "11" },
//        },
//    },
//    .{
//        .base_dir = "headers/x86_64-macos.12-none",
//        .name = "x86_64-macos.12-none",
//        .defines = &.{
//            .{ .key = "__linux__" },
//            .{ .key = "__x86_64__" },
//            .{ .key = "__macos_sdk__", .value = "12" },
//        },
//    },
//    .{
//        .base_dir = "headers/riscv64-linux-musl",
//        .name = "riscv64-linux-musl",
//        .defines = &.{
//            .{ .key = "__linux__" },
//            .{ .key = "__riscv64__" },
//            .{ .key = "__zig_musl__" },
//        },
//    },
//    .{
//        .base_dir = "headers/powerpc64-linux-musl",
//        .name = "powerpc64-linux-musl",
//        .defines = &.{
//            .{ .key = "__linux__" },
//            .{ .key = "__powerpc64__" },
//            .{ .key = "__zig_musl__" },
//        },
//    },
//    .{
//        .base_dir = "headers/powerpc-linux-musl",
//        .name = "powerpc-linux-musl",
//        .defines = &.{
//            .{ .key = "__linux__" },
//            .{ .key = "__powerpc__" },
//            .{ .key = "__zig_musl__" },
//        },
//    },
//    .{
//        .base_dir = "headers/mips64-linux-musl",
//        .name = "mips64-linux-musl",
//        .defines = &.{
//            .{ .key = "__linux__" },
//            .{ .key = "__mips64__" },
//            .{ .key = "__zig_musl__" },
//        },
//    },
//    .{
//        .base_dir = "headers/mips-linux-musl",
//        .name = "mips-linux-musl",
//        .defines = &.{
//            .{ .key = "__linux__" },
//            .{ .key = "__mips__" },
//            .{ .key = "__zig_musl__" },
//        },
//    },
//    .{
//        .base_dir = "headers/arm-linux-musl",
//        .name = "arm-linux-musl",
//        .defines = &.{
//            .{ .key = "__linux__" },
//            .{ .key = "__arm__" },
//            .{ .key = "__zig_musl__" },
//        },
//    },
//    .{
//        .base_dir = "headers/aarch64-linux-musl",
//        .name = "aarch64-linux-musl",
//        .defines = &.{
//            .{ .key = "__linux__" },
//            .{ .key = "__aarch64__" },
//            .{ .key = "__zig_musl__" },
//        },
//    },
//    .{
//        .base_dir = "headers/aarch64-macos.11-none",
//        .name = "aarch64-macos.11-none",
//        .defines = &.{
//            .{ .key = "__macos__" },
//            .{ .key = "__aarch64__" },
//            .{ .key = "__macos_sdk__", .value = "11" },
//        },
//    },
//    .{
//        .base_dir = "headers/aarch64-macos.12-none",
//        .name = "aarch64-macos.12-none",
//        .defines = &.{
//            .{ .key = "__macos__" },
//            .{ .key = "__aarch64__" },
//            .{ .key = "__macos_sdk__", .value = "12" },
//        },
//    },
//    .{
//        .base_dir = "headers/x86_64-linux-musl",
//        .name = "x86_64-linux-musl",
//        .defines = &.{
//            .{ .key = "__linux__" },
//            .{ .key = "__x86_64__" },
//            .{ .key = "__zig_musl__" },
//        },
//    },
//};

const Config = struct {
    defines: []Merger.InputDefine,
};

fn parseJsonInputConfigs(
    base_dir: []const u8,
    allocator: std.mem.Allocator,
) ![]Merger.Input {
    var dir = try std.fs.cwd().openIterableDir(base_dir, .{});
    defer dir.close();

    var ret = std.ArrayList(Merger.Input).init(allocator);
    errdefer ret.deinit();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        const extension = std.fs.path.extension(entry.name);
        if (entry.kind == .File and
            std.mem.eql(u8, ".json", extension))
        {
            const file = try dir.dir.openFile(entry.name, .{});
            defer file.close();

            const text = try file.readToEndAlloc(allocator, 0x1000);
            defer allocator.free(text);

            var token_stream = std.json.TokenStream.init(text);
            const config = try std.json.parse(Config, &token_stream, .{
                .allocator = allocator,
            });
            defer std.json.parseFree(Config, config, .{
                .allocator = allocator,
            });

            const name = try allocator.dupe(u8, entry.name);
            errdefer allocator.free(entry.name);

            const input_base_dir = try std.fs.path.join(allocator, &.{
                base_dir,
                entry.name[0 .. entry.name.len - extension.len],
            });
            errdefer allocator.free(base_dir);

            var defines = std.ArrayList(Merger.InputDefine).init(allocator);
            errdefer {
                for (defines.items) |define| {
                    allocator.free(define.key);
                    if (define.value) |value|
                        allocator.free(value);
                }

                defines.deinit();
            }

            try ret.append(.{
                .name = name,
                .base_dir = input_base_dir,
                .defines = defines.toOwnedSlice(),
            });
        }
    }

    return ret.toOwnedSlice();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .stack_trace_frames = 10,
    }){};
    defer _ = gpa.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    var merger = try Merger.init(gpa.allocator());
    defer merger.deinit();

    const inputs = try parseJsonInputConfigs("headers", arena.allocator());
    for (inputs) |input|
        try merger.addInput(input);

    try merger.index();
    try std.io.getStdErr().writer().print("index is roughly {} bytes\n", .{merger.getByteSize()});
    var merged_headers = try merger.merge();
    defer {
        var it = merged_headers.iterator();
        while (it.next()) |entry|
            entry.value_ptr.deinit(merger.allocator);
        merged_headers.deinit();
    }

    try std.fs.cwd().deleteTree("out");
    var out_dir = try std.fs.cwd().makeOpenPath("out", .{});

    var it = merged_headers.iterator();
    while (it.next()) |entry| {
        const merged_header = entry.value_ptr;
        const path = entry.key_ptr.*;
        if (std.fs.path.dirname(path)) |dirname|
            try out_dir.makePath(dirname);

        std.log.info("outputting file: {s}", .{entry.key_ptr.*});
        const file = try out_dir.createFile(path, .{});
        defer file.close();

        try merged_header.write(file.writer(), &merger.string_collection);
    }
}

test "all" {
    std.testing.refAllDeclsRecursive(Merger);
}
