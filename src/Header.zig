const std = @import("std");
const Allocator = std.mem.Allocator;

const StringCollection = @import("StringCollection.zig");
const Expr = @import("Expr.zig");

pub const Define = struct {
    key: StringCollection.Id,
    value: ?StringCollection.Id,
};

pub const EntityId = u32;

pub const Entity = union(enum) {
    include: StringCollection.Id,
    define: Define,
};

const Header = @This();

entities: std.ArrayListUnmanaged(Expr) = .{},
dependencies: std.AutoHashMapUnmanaged(EntityId, std.AutoHashMapUnmanaged(EntityId, void)) = .{},
targets: std.ArrayListUnmanaged(std.DynamicBitSetUnmanaged) = .{},

// types of entities
defines: std.AutoArrayHashMapUnmanaged(EntityId, Define) = .{},
function_prototypes: std.AutoArrayHashMapUnmanaged(EntityId, void) = .{},
includes: std.AutoArrayHashMapUnmanaged(EntityId, StringCollection.Id) = .{},
inline_functions: std.AutoArrayHashMapUnmanaged(EntityId, void) = .{},
macro_invocations: std.AutoArrayHashMapUnmanaged(EntityId, void) = .{},
macros: std.AutoArrayHashMapUnmanaged(EntityId, void) = .{},
typedefs: std.AutoArrayHashMapUnmanaged(EntityId, void) = .{},
undefs: std.AutoArrayHashMapUnmanaged(EntityId, void) = .{},
variables: std.AutoArrayHashMapUnmanaged(EntityId, void) = .{},

pub fn deinit(self: *Header, allocator: std.mem.Allocator) void {
    for (self.entities.items) |*expr| {
        expr.deinit(allocator);
    }

    for (self.targets.items) |*target|
        target.deinit(allocator);

    var dep_it = self.dependencies.iterator();
    while (dep_it.next()) |entry|
        entry.value_ptr.deinit(allocator);

    self.entities.deinit(allocator);
    self.dependencies.deinit(allocator);
    self.targets.deinit(allocator);

    // TODO: others
    self.includes.deinit(allocator);
    self.defines.deinit(allocator);
}

pub fn addEntity(header: *Header, allocator: Allocator, expr: Expr, entity: Entity) !void {
    const id = @intCast(u32, header.entities.items.len);
    try header.entities.append(allocator, expr);
    errdefer _ = header.entities.orderedRemove(header.entities.items.len - 1);

    switch (entity) {
        .include => |str| try header.includes.put(allocator, id, str),
        .define => |define| try header.defines.put(allocator, id, define),
    }
}

fn getEntity(header: Header, id: EntityId) Entity {
    return if (header.includes.get(id)) |include| .{
        .include = include,
    } else if (header.defines.get(id)) |define| .{
        .define = define,
    } else unreachable;
}

pub fn merge(self: *Header, allocator: Allocator, other: Header, num: usize) !void {
    // first iteration: worst case scenario: just appending
    {
        var other_it = other.includes.iterator();
        while (other_it.next()) |entry| {
            const new_entity_id = @intCast(EntityId, self.entities.items.len);
            var expr = try other.entities.items[entry.key_ptr.*].copy(allocator);
            errdefer expr.deinit(allocator);

            try self.entities.append(allocator, expr);
            errdefer _ = self.entities.pop();

            var target = std.DynamicBitSetUnmanaged{};
            errdefer target.deinit(allocator);

            try target.resize(allocator, num + 1, false);
            target.set(num);
            try self.targets.append(allocator, target);
            errdefer _ = self.targets.pop();

            try self.includes.put(allocator, new_entity_id, entry.value_ptr.*);
        }
    }

    {
        var other_it = other.defines.iterator();
        while (other_it.next()) |entry| {
            const new_entity_id = @intCast(EntityId, self.entities.items.len);
            var expr = try other.entities.items[entry.key_ptr.*].copy(allocator);
            errdefer expr.deinit(allocator);

            try self.entities.append(allocator, expr);
            errdefer _ = self.entities.pop();

            var target = std.DynamicBitSetUnmanaged{};
            errdefer target.deinit(allocator);

            try target.resize(allocator, num + 1, false);
            target.set(num);
            try self.targets.append(allocator, target);
            errdefer _ = self.targets.pop();

            try self.defines.put(allocator, new_entity_id, entry.value_ptr.*);
        }
    }
}

pub fn write(self: Header, writer: anytype, string_collection: *StringCollection) !void {
    // also do naive implementation: just write them out in order of the
    // entities table. Later we will be using constraints from the dependencies
    // table and analyzing targets + exprs to find an optimal order

    try writer.writeAll("#pragma once\n\n");

    for (self.entities.items) |expr, id| {
        const wrote_if = try expr.write(string_collection, writer);
        if (wrote_if)
            try writer.writeByte('\n');

        switch (self.getEntity(@intCast(EntityId, id))) {
            .include => |str_id| try writer.print("#include {s}", .{string_collection.getString(str_id)}),
            .define => |define| if (define.value) |value_id|
                try writer.print("#define {s} {s}\n", .{
                    string_collection.getString(define.key),
                    string_collection.getString(value_id),
                })
            else
                try writer.print("#define {s}\n", .{
                    string_collection.getString(define.key),
                }),
        }

        if (wrote_if)
            try writer.writeAll("#endif\n");
    }
}

/// estimated byte size of memory used by header
pub fn getByteSize(header: Header) usize {
    var ret: usize = 0;

    for (header.entities.items) |expr| {
        ret += expr.getByteSize();
        ret += @sizeOf(std.DynamicBitSetUnmanaged);
    }

    ret += header.defines.count() * (@sizeOf(EntityId) + @sizeOf(Define));

    // TODO: includes, defines

    return ret;
}
