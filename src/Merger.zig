const std = @import("std");
const arocc = @import("arocc");
const StringCollection = @import("StringCollection.zig");
const Expr = @import("Expr.zig");
const Tokenizer = arocc.Tokenizer;
const assert = std.debug.assert;

const Merger = @This();

// defines which are set when this target is chosen
pub const Define = struct {
    key: []const u8,
    value: ?[]const u8 = null,
};

pub const Input = struct {
    base_dir: []const u8,
    name: []const u8,
    defines: []const Define,
};

const InputMap = std.StringHashMap(struct {
    base_dir: []const u8,
    headers: std.StringArrayHashMapUnmanaged(void),
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
    dependents: std.ArrayListUnmanaged(PreprocessorBlockIndex) = .{},
    elifs: std.ArrayListUnmanaged(TokenRange) = .{},
    @"else": ?TokenRange = null,

    fn deinit(self: *InProgressPreprocessorBlock, allocator: std.mem.Allocator) void {
        self.dependents.deinit(allocator);
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

allocator: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
progress: std.Progress,
inputs: InputMap,
string_collection: StringCollection,
headers: HeaderMap,

pub fn init(allocator: std.mem.Allocator) !Merger {
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
    while (it.next()) |entry|
        entry.value_ptr.headers.deinit(self.allocator);

    self.inputs.deinit();
    self.string_collection.deinit();
}

pub fn addInput(self: *Merger, input: Input) !void {
    var headers = std.StringArrayHashMapUnmanaged(void){};
    errdefer headers.deinit(self.allocator);

    var dir = try std.fs.cwd().openIterableDir(input.base_dir, .{});
    defer dir.close();

    var walker = try dir.walk(self.allocator);
    defer walker.deinit();

    while (try walker.next()) |entry|
        if (entry.kind == .File) {
            try headers.put(self.allocator, try self.arena.allocator().dupe(u8, entry.path), {});
        };

    try self.inputs.putNoClobber(input.name, .{
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

    input_it = self.inputs.iterator();
    while (input_it.next()) |input_entry| {
        var header_it = input_entry.value_ptr.headers.iterator();
        while (header_it.next()) |header_entry| {
            const full_path = try std.fs.path.join(self.allocator, &.{
                input_entry.value_ptr.*.base_dir,
                header_entry.key_ptr.*,
            });
            defer self.allocator.free(full_path);

            try self.indexFile(input_entry.key_ptr.*, header_entry.key_ptr.*);
            node.completeOne();
        }
    }

    node.end();
}

pub fn merge(self: *Merger) !void {
    var unique_headers = std.StringArrayHashMap(void).init(self.allocator);
    defer unique_headers.deinit();

    var input_it = self.inputs.iterator();
    while (input_it.next()) |input_entry| {
        var header_it = input_entry.value_ptr.headers.iterator();
        while (header_it.next()) |header_entry|
            try unique_headers.put(header_entry.key_ptr.*, {});
    }

    const node = self.progress.start("merging headers", unique_headers.count());
    node.activate();

    var it = unique_headers.iterator();
    while (it.next()) |header_entry| {
        input_it = self.inputs.iterator();
        while (input_it.next()) |input_entry| {
            const full_path = try std.fs.path.join(self.allocator, &.{
                input_entry.value_ptr.*.base_dir,
                header_entry.key_ptr.*,
            });
            defer self.allocator.free(full_path);

            std.time.sleep(100 * std.time.ns_per_ms);
        }

        node.completeOne();
    }
}

fn indexFile(self: *Merger, input_name: []const u8, path: []const u8) !void {
    const base_dir = self.inputs.get(input_name).?.base_dir;
    const header_path = try std.fs.path.join(self.allocator, &.{
        base_dir,
        path,
    });
    defer self.allocator.free(header_path);

    var comp = arocc.Compilation.init(self.allocator);
    defer comp.deinit();

    try comp.addDefaultPragmaHandlers();
    //comp.langopts.setEmulatedCompiler(comp.systemCompiler());
    //comp.target = std.Target{
    //    .cpu = std.Target.Cpu.baseline(.x86_64),
    //    .os = std.Target.Os.Tag.linux.defaultVersionRange(.x86_64),
    //    .abi = .musl,
    //    .ofmt = .elf,
    //};

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

    // the "leaf" is the key
    var dependencies = std.AutoArrayHashMap(PreprocessorBlockIndex, PreprocessorBlockIndex).init(self.allocator);
    defer dependencies.deinit();

    // TODO: make index for mapping block_idx to a range of Elifs. This is fine for now though
    var elifs = std.ArrayList(ElifPair).init(self.allocator);
    defer elifs.deinit();

    var elses = std.AutoHashMap(PreprocessorBlockIndex, TokenRange).init(self.allocator);
    defer elses.deinit();

    var defines = StringCollection.init(self.allocator);
    defer defines.deinit();

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

                        // we've processed all the dependents by now, so we can
                        // throw them onto the table
                        for (in_progress.dependents.items) |dependent|
                            try dependencies.put(dependent, block_idx);

                        for (in_progress.elifs.items) |elif|
                            try elifs.append(.{
                                .block_idx = block_idx,
                                .elif = elif,
                            });

                        if (in_progress.@"else") |@"else"|
                            try elses.putNoClobber(block_idx, @"else");

                        // finally, now that our conditional has been
                        // instantiated, it can be added as a dependent to the
                        // top of the in_progress stack
                        if (in_progress_conditionals.items.len > 0)
                            try in_progress_conditionals.items[in_progress_conditionals.items.len - 1].dependents.append(self.allocator, block_idx);
                    },
                    .keyword_define,
                    .keyword_include,
                    .keyword_undef,
                    .keyword_warning,
                    .keyword_error,
                    .keyword_pragma,
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

            var it = dependencies.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* == block_idx)
                    _ = dependencies.swapRemove(entry.key_ptr.*);
            }

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
        const block_idx = @intCast(PreprocessorBlockIndex, idx);
        var expr = try Expr.fromTokens(
            self.allocator,
            tokens.items[cond.start.begin..cond.start.end],
            tokenizer.buf,
            &self.string_collection,
        );
        defer expr.deinit(self.allocator);

        for (elifs.items) |pair| {
            if (pair.block_idx == block_idx) {
                var elif_expr = try Expr.fromTokens(
                    self.allocator,
                    tokens.items[pair.elif.begin..pair.elif.end],
                    tokenizer.buf,
                    &self.string_collection,
                );
                defer elif_expr.deinit(self.allocator);
            }
        }
    }
}

pub fn saveTo(self: *Merger, out_path: []const u8) !void {
    _ = out_path;
    _ = self;
}

fn addTokenDefine(
    tokenizer: Tokenizer,
    defines: *StringCollection,
    define_interest: *std.AutoHashMap(PreprocessorBlockIndex, std.AutoArrayHashMapUnmanaged(DefineId, void)),
    block_idx: PreprocessorBlockIndex,
    tokens: []Tokenizer.Token,
    i: u32,
) !void {
    const define_str = tokenizer.buf[tokens[i].start..tokens[i].end];
    const define_id = try defines.getId(define_str);
    const allocator = define_interest.allocator;
    if (define_interest.getEntry(block_idx)) |entry| {
        try entry.value_ptr.put(allocator, define_id, {});
    } else {
        var define_ids = std.AutoArrayHashMapUnmanaged(DefineId, void){};
        errdefer define_ids.deinit(allocator);

        try define_ids.put(allocator, define_id, {});
        try define_interest.put(block_idx, define_ids);
    }
}

// TODO: find if defines are defined in the current file or in an included file
fn findDefinesInConditional(
    tokenizer: Tokenizer,
    defines: *StringCollection,
    define_interest: *std.AutoHashMap(PreprocessorBlockIndex, std.AutoArrayHashMapUnmanaged(DefineId, void)),
    block_idx: PreprocessorBlockIndex,
    tokens: []Tokenizer.Token,
) !void {
    // first token should always be a hash
    assert(tokens[0].id == .hash);
    var i: u32 = 1;
    while (i < tokens.len) : (i += 1) {
        const token = tokens[i];
        switch (token.id) {
            .ampersand_ampersand,
            .angle_bracket_left,
            .angle_bracket_left_equal,
            .angle_bracket_right_equal,
            .angle_bracket_right,
            .bang,
            .char_literal,
            .equal_equal,
            .keyword_elif,
            .keyword_if,
            .pipe_pipe,
            .pp_num,
            .whitespace,
            .l_paren,
            .r_paren,
            .plus,
            .char_literal_wide,
            .minus,
            .asterisk,
            .bang_equal,
            .period,
            .slash,
            .keyword_const2,
            => {},
            .keyword_ifdef,
            .keyword_ifndef,
            => {
                // consume whitespace
                i += 1;
                while (i < tokens.len and tokens[i].id == .whitespace) : (i += 1) {}

                assert(tokens[i].id == .identifier);
                try addTokenDefine(tokenizer, defines, define_interest, block_idx, tokens, i);
            },
            // first sighting of this was in a comparison
            .identifier => try addTokenDefine(tokenizer, defines, define_interest, block_idx, tokens, i),
            // some uses of this don't have brackets
            .keyword_defined => {
                i += 1;
                while (i < tokens.len and tokens[i].id == .whitespace) : (i += 1) {}
                if (tokens[i].id == .l_paren)
                    i += 1;

                while (i < tokens.len and tokens[i].id == .whitespace) : (i += 1) {}

                assert(tokens[i].id == .identifier);
                try addTokenDefine(tokenizer, defines, define_interest, block_idx, tokens, i);

                if (tokens[i].id == .r_paren)
                    i += 1;
            },
            else => {
                std.log.err("unexpected token: {}", .{token});
                std.log.err("text: {s}", .{tokenizer.buf[token.start..token.end]});
                return error.Unexpected;
            },
        }
    }
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
