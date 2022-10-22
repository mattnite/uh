const std = @import("std");

const StringCollection = @This();

pub const Id = u32;

mtx: std.Thread.RwLock,
allocator: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
list: std.ArrayList([]const u8),
map: std.StringHashMap(Id),

pub fn init(allocator: std.mem.Allocator) StringCollection {
    return StringCollection{
        .mtx = std.Thread.RwLock{},
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .list = std.ArrayList([]const u8).init(allocator),
        .map = std.StringHashMap(Id).init(allocator),
    };
}

pub fn deinit(self: *StringCollection) void {
    self.list.deinit();
    self.map.deinit();
    self.arena.deinit();
}

// get id for existing string, or create entry. Since we're using allocated
// files to back all the strings, we don't need to copy
pub fn getId(self: *StringCollection, str: []const u8) !Id {
    self.mtx.lock();
    defer self.mtx.unlock();

    return self.map.get(str) orelse blk: {
        const id = @intCast(Id, self.list.items.len);
        const str_copy = try self.arena.allocator().dupe(u8, str);
        try self.list.append(str_copy);
        try self.map.put(str_copy, id);
        break :blk id;
    };
}

// you shouldn't have a string id that doesn't exist in the collection
pub fn getString(self: *StringCollection, id: Id) []const u8 {
    self.mtx.lockShared();
    defer self.mtx.unlockShared();

    return self.list.items[id];
}
