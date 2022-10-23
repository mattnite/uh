const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const arocc = @import("arocc");
const Tokenizer = arocc.Tokenizer;
const Token = Tokenizer.Token;

const StringCollection = @import("StringCollection.zig");
const Expr = @import("Expr.zig");
const Header = @import("Header.zig");

const Merger = @This();

/// defines which are set when this target is chosen
pub const InputDefine = struct {
    key: []const u8,
    value: ?[]const u8 = null,
};

pub const Input = struct {
    base_dir: []const u8,
    name: []const u8,
    defines: []const InputDefine,
};

const InputMap = std.StringHashMap(struct {
    num: usize,
    base_dir: []const u8,
    headers: std.StringArrayHashMapUnmanaged(Header),
});

const DefineId = StringCollection.Id;
const TokenIndex = u32;
const PreprocessorBlockIndex = u16;
const BranchId = enum(u8) {
    main = 0xff,
    _,

    // don't call this on main
    fn toIndex(self: BranchId) u8 {
        return switch (self) {
            .main => unreachable,
            _ => @enumToInt(self),
        };
    }
};

const PreprocessorBlockDependency = struct {
    from: PreprocessorBlockIndex,
    to: PreprocessorBlockIndex,
};

/// NOTE: inclusive range, TODO: maybe rename to first and last?
const TokenRange = struct {
    begin: TokenIndex,
    end: TokenIndex,
};

const PreprocessorBlock = struct {
    start: TokenRange,
    finish: TokenRange,
};

const Conditional = struct {
    block_idx: PreprocessorBlockIndex,
    branch_id: BranchId,
};

const InProgressPreprocessorBlock = struct {
    start: TokenRange,
    elifs: std.ArrayListUnmanaged(TokenRange) = .{},
    @"else": ?TokenRange = null,

    fn deinit(self: *InProgressPreprocessorBlock, allocator: Allocator) void {
        self.elifs.deinit(allocator);
    }
};

const ElifPair = struct {
    block_idx: PreprocessorBlockIndex,
    elif: TokenRange,
};

const HeaderMap = std.StringHashMap(struct {
    tokens: []Tokenizer.Token,
});

allocator: Allocator,
arena: std.heap.ArenaAllocator,
progress: std.Progress,
inputs: InputMap,
string_collection: StringCollection,
headers: HeaderMap,

pub fn init(allocator: Allocator) !Merger {
    return Merger{
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .progress = std.Progress{},
        .inputs = InputMap.init(allocator),
        .string_collection = StringCollection.init(allocator),
        .headers = HeaderMap.init(allocator),
    };
}

pub fn deinit(self: *Merger) void {
    self.arena.deinit();

    var it = self.inputs.iterator();
    while (it.next()) |entry| {
        var header_it = entry.value_ptr.headers.iterator();
        while (header_it.next()) |header_entry|
            header_entry.value_ptr.deinit(self.allocator);
        entry.value_ptr.headers.deinit(self.allocator);
    }

    self.inputs.deinit();
    self.string_collection.deinit();
}

pub fn addInput(self: *Merger, input: Input) !void {
    var headers = std.StringArrayHashMapUnmanaged(Header){};
    errdefer headers.deinit(self.allocator);

    var dir = try std.fs.cwd().openIterableDir(input.base_dir, .{});
    defer dir.close();

    var walker = try dir.walk(self.allocator);
    defer walker.deinit();

    while (try walker.next()) |entry|
        if (entry.kind == .File) {
            try headers.put(self.allocator, try self.arena.allocator().dupe(u8, entry.path), .{});
        };

    try self.inputs.putNoClobber(input.name, .{
        .num = self.inputs.count(),
        .base_dir = input.base_dir,
        .headers = headers,
    });
}

pub fn index(self: *Merger) !void {
    var count: usize = 0;
    var input_it = self.inputs.iterator();
    while (input_it.next()) |entry|
        count += entry.value_ptr.headers.count();

    const node = self.progress.start("indexing headers", count);
    node.activate();

    // TODO: thread pool
    input_it = self.inputs.iterator();
    while (input_it.next()) |input_entry| {
        var header_it = input_entry.value_ptr.headers.iterator();
        while (header_it.next()) |header_entry| {
            try self.indexHeader(input_entry.key_ptr.*, header_entry.key_ptr.*, header_entry.value_ptr);
            node.completeOne();
        }
    }

    node.end();
}

/// get size in bytes of indexed headers, not perfect since it misses indexing structures, but good enough
pub fn getByteSize(self: Merger) usize {
    var ret: usize = 0;

    var input_it = self.inputs.iterator();
    while (input_it.next()) |input_entry| {
        var header_it = input_entry.value_ptr.headers.iterator();
        while (header_it.next()) |header_entry| {
            ret += header_entry.value_ptr.getByteSize();
        }
    }

    for (self.string_collection.list.items) |string|
        ret += string.len;

    return ret;
}

pub fn merge(self: *Merger) !std.StringArrayHashMap(Header) {
    var final_headers = std.StringArrayHashMap(Header).init(self.allocator);
    errdefer final_headers.deinit();

    var input_it = self.inputs.iterator();
    while (input_it.next()) |input_entry| {
        var header_it = input_entry.value_ptr.headers.iterator();
        while (header_it.next()) |header_entry|
            try final_headers.put(header_entry.key_ptr.*, .{});
    }

    const node = self.progress.start("merging headers", final_headers.count());
    node.activate();

    var it = final_headers.iterator();
    while (it.next()) |header_entry| {
        const header_name = header_entry.key_ptr.*;
        const final_header = header_entry.value_ptr;

        input_it = self.inputs.iterator();
        while (input_it.next()) |input_entry| {
            if (input_entry.value_ptr.headers.get(header_name)) |header|
                try final_header.merge(self.allocator, header, input_entry.value_ptr.num);
        }

        node.completeOne();
    }

    return final_headers;
}

fn indexHeader(self: *Merger, input_name: []const u8, path: []const u8, header: *Header) !void {
    const base_dir = self.inputs.get(input_name).?.base_dir;
    const header_path = try std.fs.path.join(self.allocator, &.{
        base_dir,
        path,
    });
    defer self.allocator.free(header_path);

    var comp = arocc.Compilation.init(self.allocator);
    defer comp.deinit();

    const source = try comp.addSourceFromPath(header_path);
    try comp.include_dirs.append(base_dir);

    var tokenizer = arocc.Tokenizer{
        .buf = source.buf,
        .comp = &comp,
        .source = source.id,
    };

    var conditionals = std.ArrayList(PreprocessorBlock).init(self.allocator);
    defer conditionals.deinit();

    // contains the start line of a conditional
    var in_progress_conditionals = std.ArrayList(InProgressPreprocessorBlock).init(self.allocator);
    defer {
        for (in_progress_conditionals.items) |*ipc|
            ipc.deinit(self.allocator);
        in_progress_conditionals.deinit();
    }

    var tokens = std.ArrayList(Tokenizer.Token).init(self.allocator);
    defer tokens.deinit();

    // TODO: make index for mapping block_idx to a range of Elifs. This is fine for now though
    var elifs = std.ArrayList(ElifPair).init(self.allocator);
    defer elifs.deinit();

    var elses = std.AutoHashMap(PreprocessorBlockIndex, TokenRange).init(self.allocator);
    defer elses.deinit();

    while (true) {
        const tok = tokenizer.next();
        try tokens.append(tok);

        if (tok.id == .eof)
            break;
    }

    var i: u32 = 0;
    while (i < tokens.items.len) : (i += 1) {
        const tok_idx = i;
        const tok = tokens.items[i];

        switch (tok.id) {
            .hash => {
                // TODO: whitespace

                // eat through whitespace
                const sub_tok = blk: {
                    while (true) {
                        i += 1;
                        var ret = tokens.items[i];
                        switch (ret.id) {
                            .whitespace => {},
                            .eof => return error.HitEof,
                            else => break :blk ret,
                        }
                    }
                };

                switch (sub_tok.id) {
                    .keyword_ifdef,
                    .keyword_ifndef,
                    .keyword_if,
                    => {
                        i = try consumeTokensUntil(i, tokens.items, .nl);
                        try in_progress_conditionals.append(.{
                            .start = .{
                                .begin = tok_idx,
                                .end = i,
                            },
                        });
                    },
                    .keyword_elif => {
                        i = try consumeTokensUntil(i, tokens.items, .nl);
                        const current = &in_progress_conditionals.items[in_progress_conditionals.items.len - 1];
                        try current.elifs.append(self.allocator, .{
                            .begin = tok_idx,
                            .end = i,
                        });
                    },
                    .keyword_else => {
                        i = try consumeTokensUntil(i, tokens.items, .nl);
                        const current = &in_progress_conditionals.items[in_progress_conditionals.items.len - 1];
                        if (current.@"else") |@"else"| {
                            std.log.err("Already have an else branch for this conditional: {}", .{@"else"});
                            return error.AlreadyHaveElse;
                        }
                        current.@"else" = .{
                            .begin = tok_idx,
                            .end = i,
                        };
                    },
                    .keyword_endif => {
                        i = try consumeTokensUntil(i, tokens.items, .nl);
                        var in_progress = in_progress_conditionals.pop();
                        defer in_progress.deinit(self.allocator);

                        const block_idx = @intCast(PreprocessorBlockIndex, conditionals.items.len);
                        try conditionals.append(.{
                            .start = in_progress.start,
                            .finish = .{
                                .begin = tok_idx,
                                .end = i,
                            },
                        });

                        for (in_progress.elifs.items) |elif|
                            try elifs.append(.{
                                .block_idx = block_idx,
                                .elif = elif,
                            });

                        if (in_progress.@"else") |@"else"|
                            try elses.putNoClobber(block_idx, @"else");
                    },
                    .keyword_include => {
                        i += 1;
                        // skip whitespace
                        while (i < tokens.items.len and tokens.items[i].id == .whitespace) : (i += 1) {}

                        const first_idx = i;
                        i = try consumeTokensUntil(i, tokens.items, .nl);
                        const include_str = tokenizer.buf[tokens.items[first_idx].start..tokens.items[i].end];
                        var expr = try getCurrentExpr(
                            self.allocator,
                            tokens.items,
                            in_progress_conditionals.items,
                            tokenizer.buf,
                            &self.string_collection,
                        );
                        errdefer expr.deinit(self.allocator);

                        try header.addEntity(self.allocator, expr, .{ .include = try self.string_collection.getId(include_str) });
                        std.log.debug("found header in {s}/{s}: {s}", .{ input_name, path, include_str });
                    },
                    .keyword_define => {
                        i += 1;
                        const start_idx = i;
                        while (i < tokens.items.len and tokens.items[i].id != .nl) : (i += 1) {}
                        const end_idx = i;

                        assert(tokens.items[end_idx].id == .nl);

                        std.log.debug("parsing define: {s}", .{tokenizer.buf[tokens.items[start_idx].start..tokens.items[end_idx - 1].end]});
                        var cursor = start_idx;

                        // skip whitespace
                        while (cursor < end_idx and tokens.items[cursor].id == .whitespace) : (cursor += 1) {}

                        const define_key = tokenizer.buf[tokens.items[cursor].start..tokens.items[cursor].end];
                        cursor += 1;

                        if (tokens.items[cursor].id == .l_paren) {
                            // TODO: macros

                        } else {
                            std.log.debug("define key: '{s}'", .{define_key});

                            const value_tokens = trimTokens(tokens.items[cursor..end_idx]);

                            // this to the end is now the value
                            const value_str: ?[]const u8 = if (value_tokens.len > 0)
                                tokenizer.buf[value_tokens[0].start..value_tokens[value_tokens.len - 1].end]
                            else
                                null;

                            if (value_str) |value| {
                                std.log.debug("define: key='{s}' value='{s}'", .{ define_key, value });
                            } else {
                                std.log.debug("define: key='{s}'", .{define_key});
                            }

                            var expr = try getCurrentExpr(
                                self.allocator,
                                tokens.items,
                                in_progress_conditionals.items,
                                tokenizer.buf,
                                &self.string_collection,
                            );
                            errdefer expr.deinit(self.allocator);

                            try header.addEntity(self.allocator, expr, .{
                                .define = .{
                                    .key = try self.string_collection.getId(define_key),
                                    .value = if (value_str) |value|
                                        try self.string_collection.getId(value)
                                    else
                                        null,
                                },
                            });
                        }

                        while (i < tokens.items.len and tokens.items[i].id != .nl) : (i += 1) {}
                    },
                    .keyword_undef,
                    .keyword_warning,
                    .keyword_error,
                    .keyword_pragma,
                    .keyword_include_next,
                    // so far this is used in tokenizing a define so skip it
                    .identifier,
                    => {},
                    // unhandled preprocessor directives
                    else => {
                        std.log.err("unexpected token: {}", .{sub_tok});
                        std.log.err("text: {s}", .{tokenizer.buf[sub_tok.start..sub_tok.end]});
                        return error.Unexpected;
                    },
                }
            },

            .eof => break,
            else => {},
        }
    }

    //const stdout = std.io.getStdOut().writer();
    if (conditionals.items.len > 0) {
        // TODO: if there's an include guard, it'll be the last conditional, check
        // if it covers almost all of the file (at least the useful bits). If it's
        // not there, assert that there's a #pragma once. Otherwise the file might
        // be an weird case and we should take a look at it.

        // TODO: another characteristic to check for an include  header is that
        // the first thing in the body should be a define for what it just
        // checked for

        // definitely an include guard: begins at first token, ends at last token
        const block_idx = @intCast(PreprocessorBlockIndex, conditionals.items.len - 1);
        const maybe_include_guard = &conditionals.items[block_idx];
        if (tokensAreOneOf(tokens.items[0..maybe_include_guard.start.begin], &.{.nl}) and
            tokensAreOneOf(tokens.items[maybe_include_guard.finish.end + 1 ..], &.{ .nl, .eof }) and
            tokens.items[maybe_include_guard.start.begin + 1].id == .keyword_ifndef and
            // include guards shouldn't have an else
            !elses.contains(block_idx))
        {
            _ = conditionals.pop();

            assert(for (elifs.items) |pair| {
                if (pair.block_idx == block_idx)
                    break false;
            } else true);
        }
    }

    // now that we're here, time for some expression analysis. On top of there
    // being an expression for the initial branch, we can optionally have more
    // expressions as elif branches or an else.
    //
    // For now I'm just going to leave the elses, we already have that table,
    // and we have all the information we need: what condition it relates to,
    // and what tokens it's made up of
    //
    // We'll use an non-exhaustive num for the Id of an expression, 0xff will
    // be the main expression, and then the rest will be for indexing the
    // elifs. Initially we'll back the enum with a u8 since I don't think we'll
    // run into a conditional with that many branches

    // only do parsing here, no analysis
    for (conditionals.items) |cond, idx| {
        _ = cond;
        const block_idx = @intCast(PreprocessorBlockIndex, idx);
        //try header.exprs.append(
        //    self.allocator,
        //    try Expr.fromTokens(
        //        self.allocator,
        //        tokens.items[cond.start.begin..cond.start.end],
        //        tokenizer.buf,
        //        &self.string_collection,
        //    ),
        //);

        for (elifs.items) |pair| {
            if (pair.block_idx == block_idx) {
                //try header.exprs.append(
                //    self.allocator,
                //    try Expr.fromTokens(
                //        self.allocator,
                //        tokens.items[pair.elif.begin..pair.elif.end],
                //        tokenizer.buf,
                //        &self.string_collection,
                //    ),
                //);
            }
        }
    }
}

/// remove preceding and trailing whitespace as well as comments, assume all on one line
fn trimTokens(tokens: []Tokenizer.Token) []Tokenizer.Token {
    if (tokens.len == 0)
        return tokens;

    // assume all on one line
    for (tokens) |token|
        assert(token.id != .nl);

    // find first occurence of a non-whitespace character
    var i: usize = 0;
    while (i < tokens.len and tokens[i].id == .whitespace) : (i += 1) {}
    const begin = i;

    i = tokens.len - 1;
    while (i > begin - 1 and tokens[i].id == .whitespace) : (i -= 1) {}

    return tokens[begin .. i + 1];
}

fn getCurrentExpr(
    allocator: Allocator,
    tokens: []const Token,
    in_progress_conditionals: []const InProgressPreprocessorBlock,
    buf: []const u8,
    string_collection: *StringCollection,
) !Expr {
    if (in_progress_conditionals.len == 0)
        return .{};

    // let's cheese it for now and only go one deep.
    const cond = &in_progress_conditionals[in_progress_conditionals.len - 1];

    return Expr.fromTokens(allocator, tokens[cond.start.begin..cond.start.end], buf, string_collection);
}

fn tokensAreOneOf(tokens: []Tokenizer.Token, ids: []const Tokenizer.Token.Id) bool {
    return for (tokens) |token| {
        var found = for (ids) |id| {
            if (token.id == id)
                break true;
        } else false;

        if (!found)
            break false;
    } else true;
}

fn consumeTokensUntil(
    current: u32,
    tokens: []Tokenizer.Token,
    needle: Tokenizer.Token.Id,
) !u32 {
    var idx = current;
    while (idx < tokens.len - 1) {
        idx += 1;
        if (tokens[idx].id == needle or tokens[idx].id == .eof)
            return idx;
    }

    std.log.err("was looking for {}, searched:", .{needle});
    for (tokens[current..]) |token|
        std.log.err("  {}", .{token});

    return error.NotFound;
}
