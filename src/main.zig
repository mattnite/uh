const std = @import("std");
const arocc = @import("arocc");
const Tokenizer = arocc.Tokenizer;
const assert = std.debug.assert;

// one way we might want to consider the preprocessor we might want to
// preprocess the files _except_ for includes. This could be added as a special
// entry to the parser

// at the end of the day we have a list of inputs that turn into <arch>-<os>-<abi>
const TokenIndex = u32;

// I don't see there being more than 65k conditionals in a single file
const ConditionalIndex = u16;

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

const ConditionalDependency = struct {
    from: ConditionalIndex,
    to: ConditionalIndex,
};

/// NOTE: inclusive range, TODO: maybe rename to first and last?
const TokenRange = struct {
    begin: TokenIndex,
    end: TokenIndex,
};

const Conditional = struct {
    start: TokenRange,
    finish: TokenRange,
};

const Expression = struct {
    cond_idx: ConditionalIndex,
    branch_id: BranchId,
};

const InProgressConditional = struct {
    start: TokenRange,
    dependents: std.ArrayListUnmanaged(ConditionalIndex) = .{},
    elifs: std.ArrayListUnmanaged(TokenRange) = .{},
    @"else": ?TokenRange = null,

    fn deinit(self: *InProgressConditional, allocator: std.mem.Allocator) void {
        self.dependents.deinit(allocator);
        self.elifs.deinit(allocator);
    }
};

const ElifPair = struct {
    cond_idx: ConditionalIndex,
    elif: TokenRange,
};

// calling this Id since I might change it from an index later
const StringId = u32;
const StringCollection = struct {
    list: std.ArrayList([]const u8),
    map: std.StringHashMap(StringId),

    fn init(allocator: std.mem.Allocator) StringCollection {
        return StringCollection{
            .list = std.ArrayList([]const u8).init(allocator),
            .map = std.StringHashMap(StringId).init(allocator),
        };
    }

    fn deinit(self: *StringCollection) void {
        self.list.deinit();
        self.map.deinit();
    }

    // get id for existing string, or create entry. Since we're using allocated
    // files to back all the strings, we don't need to copy
    fn getId(self: *StringCollection, str: []const u8) !StringId {
        return self.map.get(str) orelse blk: {
            const id = @intCast(StringId, self.list.items.len);
            try self.list.append(str);
            break :blk id;
        };
    }

    // you shouldn't have a string id that doesn't exist in the collection
    fn getString(self: StringCollection, id: StringId) []const u8 {
        return self.list.items[id];
    }
};

/// just a string for now
const DefineId = StringId;

fn consumeTokensUntil(
    current: u32,
    tokens: []Tokenizer.Token,
    needle: Tokenizer.Token.Id,
) !u32 {
    var idx = current;
    while (idx < tokens.len - 1) {
        idx += 1;
        if (tokens[idx].id == needle or tokens[idx].id == .eof)
            return idx - 1;
    }

    std.log.err("was looking for {}, searched:", .{needle});
    for (tokens[current..]) |token|
        std.log.err("  {}", .{token});

    return error.NotFound;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .stack_trace_frames = 10,
    }){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    var comp = arocc.Compilation.init(allocator);
    defer comp.deinit();

    try comp.addDefaultPragmaHandlers();
    comp.langopts.setEmulatedCompiler(comp.systemCompiler());
    comp.target = std.Target{
        .cpu = std.Target.Cpu.baseline(.x86_64),
        .os = std.Target.Os.Tag.linux.defaultVersionRange(.x86_64),
        .abi = .musl,
        .ofmt = .elf,
    };

    var arg_it = std.process.ArgIteratorPosix.init();
    _ = arg_it.skip();
    const path = arg_it.next().?;

    const source = try comp.addSourceFromPath(path);
    try comp.include_dirs.append("x86_64-linux-musl");

    var tokenizer = arocc.Tokenizer{
        .buf = source.buf,
        .comp = &comp,
        .source = source.id,
    };

    var conditionals = std.ArrayList(Conditional).init(gpa.allocator());
    defer conditionals.deinit();

    // contains the start line of a conditional
    var in_progress_conditionals = std.ArrayList(InProgressConditional).init(gpa.allocator());
    defer {
        for (in_progress_conditionals.items) |*ipc|
            ipc.deinit(gpa.allocator());
        in_progress_conditionals.deinit();
    }

    var tokens = std.ArrayList(Tokenizer.Token).init(gpa.allocator());
    defer tokens.deinit();

    // the "leaf" is the key
    var dependencies = std.AutoArrayHashMap(ConditionalIndex, ConditionalIndex).init(gpa.allocator());
    defer dependencies.deinit();

    // TODO: make index for mapping cond_idx to a range of Elifs. This is fine for now though
    var elifs = std.ArrayList(ElifPair).init(gpa.allocator());
    defer elifs.deinit();

    var elses = std.AutoHashMap(ConditionalIndex, TokenRange).init(gpa.allocator());
    defer elses.deinit();

    var defines = StringCollection.init(gpa.allocator());
    defer defines.deinit();

    // TODO: make this into a set
    var define_interest = std.AutoHashMap(ConditionalIndex, std.AutoArrayHashMapUnmanaged(DefineId, void)).init(gpa.allocator());
    defer {
        var it = define_interest.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(gpa.allocator());
        }

        define_interest.deinit();
    }

    // TODO: drop comments and extraneous whitespace

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
                        try current.elifs.append(gpa.allocator(), .{
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
                        defer in_progress.deinit(gpa.allocator());

                        const cond_idx = @intCast(ConditionalIndex, conditionals.items.len);
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
                            try dependencies.put(dependent, cond_idx);

                        for (in_progress.elifs.items) |elif|
                            try elifs.append(.{
                                .cond_idx = cond_idx,
                                .elif = elif,
                            });

                        if (in_progress.@"else") |@"else"|
                            try elses.putNoClobber(cond_idx, @"else");

                        // finally, now that our conditional has been
                        // instantiated, it can be added as a dependent to the
                        // top of the in_progress stack
                        if (in_progress_conditionals.items.len > 0)
                            try in_progress_conditionals.items[in_progress_conditionals.items.len - 1].dependents.append(gpa.allocator(), cond_idx);
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

    const stdout = std.io.getStdOut().writer();
    if (conditionals.items.len > 0) {
        // TODO: if there's an include guard, it'll be the last conditional, check
        // if it covers almost all of the file (at least the useful bits). If it's
        // not there, assert that there's a #pragma once. Otherwise the file might
        // be an weird case and we should take a look at it.

        // TODO: another characteristic to check for an include  header is that
        // the first thing in the body should be a define for what it just
        // checked for

        // definitely an include guard: begins at first token, ends at last token
        const cond_idx = @intCast(ConditionalIndex, conditionals.items.len - 1);
        const maybe_include_guard = &conditionals.items[cond_idx];
        if (tokensAreOneOf(tokens.items[0..maybe_include_guard.start.begin], &.{.nl}) and
            tokensAreOneOf(tokens.items[maybe_include_guard.finish.end + 1 ..], &.{ .nl, .eof }) and
            tokens.items[maybe_include_guard.start.begin + 1].id == .keyword_ifndef and
            // include guards shouldn't have an else
            !elses.contains(cond_idx))
        {
            _ = conditionals.pop();

            var it = dependencies.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* == cond_idx)
                    _ = dependencies.swapRemove(entry.key_ptr.*);
            }

            assert(for (elifs.items) |pair| {
                if (pair.cond_idx == cond_idx)
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
    //
    // The other thing we're interested is a list of defines that are important
    // for the expression. As we continue to explore the problem space, we'll
    // collect different contraints for each define, such as the type, or if a
    // certain value causes an #error

    // traverse every conditional and its branches, find what defines they're interested in
    for (conditionals.items) |cond, idx| {
        const cond_idx = @intCast(ConditionalIndex, idx);

        // main expression
        try findDefinesInExpression(tokenizer, &defines, &define_interest, cond_idx, tokens.items[cond.start.begin .. cond.start.end + 1]);
        for (elifs.items) |pair| {
            if (pair.cond_idx == cond_idx) {
                try findDefinesInExpression(tokenizer, &defines, &define_interest, cond_idx, tokens.items[pair.elif.begin .. pair.elif.end + 1]);
            }
        }
    }

    // only do printing here, no analysis
    try stdout.print("count: {}\n", .{tokens.items.len});
    try stdout.writeAll("conditionals:\n");
    for (conditionals.items) |cond, idx| {
        const cond_idx = @intCast(ConditionalIndex, idx);
        const start_token = tokens.items[cond.start.begin];
        const end_token = tokens.items[cond.start.end];
        try stdout.print("  {}\n", .{cond});

        try stdout.print("    expr: {s}\n", .{tokenizer.buf[start_token.start..end_token.end]});
        for (elifs.items) |pair| {
            if (pair.cond_idx == cond_idx) {
                try stdout.print("          {s}\n", .{tokenizer.buf[tokens.items[pair.elif.begin].start..tokens.items[pair.elif.end].end]});
            }
        }
        if (elses.get(cond_idx) != null)
            try stdout.print("          #else\n", .{});

        if (define_interest.get(cond_idx)) |interested_defines| {
            try stdout.writeAll("    interested in defines:\n");
            var it = interested_defines.iterator();
            while (it.next()) |entry|
                try stdout.print("    - {s}\n", .{defines.getString(entry.key_ptr.*)});
        }
    }

    //for (tokens.items) |token|
    //    try stdout.print("  {}\n", .{token});

    //for (tokens.items) |token| {
    //    try stdout.writeAll(tokenizer.buf[token.start..token.end]);
    //}
}

fn addTokenDefine(
    tokenizer: Tokenizer,
    defines: *StringCollection,
    define_interest: *std.AutoHashMap(ConditionalIndex, std.AutoArrayHashMapUnmanaged(DefineId, void)),
    cond_idx: ConditionalIndex,
    tokens: []Tokenizer.Token,
    i: u32,
) !void {
    const define_str = tokenizer.buf[tokens[i].start..tokens[i].end];
    const define_id = try defines.getId(define_str);
    const allocator = define_interest.allocator;
    if (define_interest.getEntry(cond_idx)) |entry| {
        try entry.value_ptr.put(allocator, define_id, {});
    } else {
        var define_ids = std.AutoArrayHashMapUnmanaged(DefineId, void){};
        errdefer define_ids.deinit(allocator);

        try define_ids.put(allocator, define_id, {});
        try define_interest.put(cond_idx, define_ids);
    }
}

// TODO: find if defines are defined in the current file or in an included file
fn findDefinesInExpression(
    tokenizer: Tokenizer,
    defines: *StringCollection,
    define_interest: *std.AutoHashMap(ConditionalIndex, std.AutoArrayHashMapUnmanaged(DefineId, void)),
    cond_idx: ConditionalIndex,
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
                try addTokenDefine(tokenizer, defines, define_interest, cond_idx, tokens, i);
            },
            // first sighting of this was in a comparison
            .identifier => try addTokenDefine(tokenizer, defines, define_interest, cond_idx, tokens, i),
            // some uses of this don't have brackets
            .keyword_defined => {
                i += 1;
                while (i < tokens.len and tokens[i].id == .whitespace) : (i += 1) {}
                if (tokens[i].id == .l_paren)
                    i += 1;

                while (i < tokens.len and tokens[i].id == .whitespace) : (i += 1) {}

                assert(tokens[i].id == .identifier);
                try addTokenDefine(tokenizer, defines, define_interest, cond_idx, tokens, i);

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
