const std = @import("std");
const arocc = @import("arocc");
const Tokenizer = arocc.Tokenizer;
const assert = std.debug.assert;

const Squisher = @This();

pub const Input = struct {
    base_dir: []const u8,
    target: []const u8,
};

const InputMap = std.StringHashMap(struct {
    base_dir: []const u8,
    headers: std.StringArrayHashMapUnmanaged(void),
});

allocator: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
inputs: InputMap,

pub fn init(allocator: std.mem.Allocator, inputs: []const Input) !Squisher {
    var ret = Squisher{
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .inputs = InputMap.init(allocator),
    };
    errdefer ret.deinit();

    for (inputs) |input| {
        var headers = std.StringArrayHashMapUnmanaged(void){};
        errdefer headers.deinit(allocator);

        var dir = try std.fs.cwd().openIterableDir(input.base_dir, .{});
        defer dir.close();

        var walker = try dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next()) |entry|
            if (entry.kind == .File)
                try headers.put(allocator, try ret.arena.allocator().dupe(u8, entry.path), {});

        try ret.inputs.putNoClobber(input.target, .{
            .base_dir = input.base_dir,
            .headers = headers,
        });
    }

    return ret;
}

pub fn deinit(self: *Squisher) void {
    self.arena.deinit();

    var it = self.inputs.iterator();
    while (it.next()) |entry|
        entry.value_ptr.headers.deinit(self.allocator);
    self.inputs.deinit();
}

pub fn saveTo(self: *Squisher, out_path: []const u8) !void {
    _ = self;
    _ = out_path;
}
