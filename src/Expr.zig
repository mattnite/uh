const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const arocc = @import("arocc");
const Tokenizer = arocc.Tokenizer;
const Token = Tokenizer.Token;

const StringCollection = @import("StringCollection.zig");

const Expr = @This();

pub const Operator = enum(u7) {
    // value "operators"
    defined,
    identifier,
    num_literal,
    char_literal,
    macro_invocation,

    // logical operators
    @"and",
    @"or",
    ternary,

    // comparison operators
    equal,
    less_than,
    less_than_equal_to,
    greater_than,
    greater_than_equal_to,

    // arithmetic operators
    add,
    subtract,
    multiply,
    divide,

    // only for use in compare function
    fn rank(op: Operator) u2 {
        return if (op.isValue())
            0
        else if (op.isArithmetic())
            1
        else if (op.isComparison())
            2
        else if (op.isLogical())
            3
        else
            unreachable;
    }

    pub fn compare(lhs: Operator, rhs: Operator) std.math.Order {
        const lhs_rank = rank(lhs);
        const rhs_rank = rank(rhs);

        return if (lhs_rank < rhs_rank)
            .lt
        else if (lhs_rank == rhs_rank)
            .eq
        else if (lhs_rank > rhs_rank)
            .gt
        else
            unreachable;
    }

    pub fn isValue(op: Operator) bool {
        return switch (op) {
            .defined,
            .identifier,
            .num_literal,
            .char_literal,
            .macro_invocation,
            => true,
            else => false,
        };
    }

    pub fn isLogical(op: Operator) bool {
        return switch (op) {
            .@"and", .@"or", .ternary => true,
            else => false,
        };
    }

    pub fn isComparison(op: Operator) bool {
        return switch (op) {
            .equal,
            .less_than,
            .less_than_equal_to,
            .greater_than,
            .greater_than_equal_to,
            => true,
            else => false,
        };
    }

    pub fn isArithmetic(op: Operator) bool {
        return switch (op) {
            .add,
            .subtract,
            .multiply,
            .divide,
            => true,
            else => false,
        };
    }

    pub fn numOpArgs(op: Operator) usize {
        return switch (op) {
            .@"and", .@"or" => 2,
            .defined,
            .equal,
            .less_than,
            .less_than_equal_to,
            .greater_than,
            .greater_than_equal_to,
            => 0,
        };
    }

    pub fn numValueArgs(op: Operator) usize {
        return switch (op) {
            .@"and", .@"or" => 0,
            .defined, .equal => 1,
            .less_than,
            .less_than_equal_to,
            .greater_than,
            .greater_than_equal_to,
            => 2,
        };
    }
};

const OpWithNot = packed struct {
    // `not` can be merged into the operator enum if we need to more efficiently pack stuff
    not: bool,
    op: Operator,
};

op_with_not: std.ArrayListUnmanaged(OpWithNot) = .{},

// string id
values: std.ArrayListUnmanaged(StringCollection.Id) = .{},

pub fn getByteSize(expr: Expr) usize {
    return (expr.op_with_not.items.len * @sizeOf(OpWithNot)) +
        (expr.values.items.len * @sizeOf(StringCollection.Id));
}

pub fn deinit(self: *Expr, allocator: Allocator) void {
    self.op_with_not.deinit(allocator);
    self.values.deinit(allocator);
}

pub fn fromTokens(
    allocator: Allocator,
    tokens: []Token,
    buf: []const u8,
    string_collection: *StringCollection,
) !Expr {
    var ret = Expr{};
    errdefer ret.deinit(allocator);

    assert(tokens.len > 0);
    assert(tokens[0].id == .hash);

    var i: usize = 1;
    skipWhitespace(tokens, &i);
    const first_id = tokens[i].id;
    switch (tokens[i].id) {
        .keyword_ifdef, .keyword_ifndef => {
            i += 1;

            skipWhitespace(tokens, &i);
            try ret.op_with_not.append(allocator, .{
                .not = switch (first_id) {
                    .keyword_ifdef => false,
                    .keyword_ifndef => true,
                    else => unreachable,
                },
                .op = .defined,
            });

            if (tokens[i].id != .identifier)
                return error.NotIdentifierAfterIfDef;

            skipWhitespace(tokens, &i);
            const define = buf[tokens[i].start..tokens[i].end];
            try ret.values.append(
                allocator,
                try string_collection.getId(define),
            );

            return ret;
        },
        .keyword_if, .keyword_elif => {
            i += 1;
            skipWhitespace(tokens, &i);

            try recursiveParseExpr(
                allocator,
                tokens[i..],
                buf,
                string_collection,
                &ret,
                false,
            );
        },
        else => unreachable,
    }

    return ret;
}

fn skipWhitespace(haystack: []Token, i: *usize) void {
    while (i.* < haystack.len) : (i.* += 1) {
        if (haystack[i.*].id != .whitespace) {
            break;
        }
    }
}

const OpResult = struct {
    op: Operator,
    idx: usize,
};

fn recursiveParseExpr(
    allocator: Allocator,
    tokens: []Token,
    buf: []const u8,
    string_collection: *StringCollection,
    expr: *Expr,
    not: bool,
) error{ OutOfMemory, Malformed }!void {
    if (tokens.len == 0)
        return error.Malformed;

    std.log.debug("recursively parsing: '{s}'", .{buf[tokens[0].start..tokens[tokens.len - 1].end]});
    std.log.debug("tokens:", .{});
    for (tokens) |token, i| {
        std.log.debug("  {}: {}", .{ i, token });
    }
    std.log.debug("", .{});

    // move for ward to next operator
    var invert = not;
    var paren_depth: usize = 0;
    var cursor = @intCast(isize, tokens.len - 1);

    var logical: ?OpResult = null;
    var comparison: ?OpResult = null;
    var arithmetic: ?OpResult = null;

    // precidence goes: logical > comparison > arithmetic > value
    while (cursor > 0) : (cursor -= 1) {
        switch (tokens[@intCast(usize, cursor)].id) {
            .r_paren => paren_depth += 1,
            .l_paren => paren_depth -= 1,
            .question_mark => {
                std.log.debug("found question mark", .{});
                // this is for a ternary expression, so we have a lhs, rhs, and condition
                if (paren_depth == 0) {
                    try expr.op_with_not.append(allocator, .{
                        .not = invert,
                        .op = .ternary,
                    });

                    // TODO: nested parens and ternary expressions
                    const question_idx = @intCast(usize, cursor);
                    var i = question_idx;
                    while (i < tokens.len and tokens[i].id != .colon) : (i += 1) {}
                    const colon_idx = i;
                    try recursiveParseExpr(allocator, tokens[colon_idx + 1 ..], buf, string_collection, expr, false);
                    try recursiveParseExpr(allocator, tokens[question_idx + 1 .. colon_idx], buf, string_collection, expr, false);
                    try recursiveParseExpr(allocator, tokens[0..question_idx], buf, string_collection, expr, false);
                    return;
                }
            },
            .ampersand_ampersand,
            .pipe_pipe,
            .equal_equal,
            .bang_equal,
            .angle_bracket_left,
            .angle_bracket_right,
            .angle_bracket_left_equal,
            .angle_bracket_right_equal,
            .plus,
            .minus,
            .slash,
            .asterisk,
            => {
                if (paren_depth == 0) {
                    const idx = @intCast(usize, cursor);
                    const op: Operator = switch (tokens[idx].id) {
                        .ampersand_ampersand => .@"and",
                        .pipe_pipe => .@"or",
                        .equal_equal => .equal,
                        .bang_equal => blk: {
                            invert = !invert;
                            break :blk .equal;
                        },
                        .angle_bracket_left => .less_than,
                        .angle_bracket_right => .greater_than,
                        .angle_bracket_left_equal => .less_than_equal_to,
                        .angle_bracket_right_equal => .greater_than_equal_to,
                        .plus => .add,
                        .minus => .subtract,
                        .slash => .divide,
                        .asterisk => .multiply,
                        else => unreachable,
                    };

                    const result = OpResult{ .op = op, .idx = idx };
                    if (op.isLogical() and logical == null)
                        logical = result
                    else if (op.isComparison() and comparison == null)
                        comparison = result
                    else if (op.isArithmetic() and arithmetic == null)
                        arithmetic = result;
                }
            },
            else => {},
        }
    }

    if (logical != null or comparison != null or arithmetic != null) {
        const result = logical orelse comparison orelse arithmetic orelse unreachable;
        try expr.op_with_not.append(allocator, .{
            .not = invert,
            .op = result.op,
        });

        try recursiveParseExpr(allocator, tokens[result.idx + 1 ..], buf, string_collection, expr, false);
        try recursiveParseExpr(allocator, tokens[0..result.idx], buf, string_collection, expr, false);
    } else {
        // no operator was found, so now this is parsed as a basic comparison or a define check
        // TODO

        // go until you hit defined or a parenthesis
        std.log.debug("it:", .{});
        var i: usize = 0;
        while (i < tokens.len) : (i += 1) {
            std.log.debug("  {}", .{tokens[i].id});
            switch (tokens[i].id) {
                .bang => invert = !invert,
                .keyword_defined => {
                    i += 1;

                    skipWhitespace(tokens, &i);
                    // go until we hit identifier
                    // TODO: assert open/closing brace if they're here
                    var open_bracket = false;
                    while (i < tokens.len) : (i += 1) {
                        switch (tokens[i].id) {
                            .l_paren => open_bracket = true,
                            // identifiers and a bunch of special define checks it seems
                            .identifier,
                            .keyword_restrict,
                            .keyword_restrict1,
                            .keyword_noreturn,
                            .keyword_static_assert,
                            => {
                                try expr.op_with_not.append(allocator, .{
                                    .not = invert,
                                    .op = .defined,
                                });

                                const identifier = buf[tokens[i].start..tokens[i].end];
                                try expr.values.append(allocator, try string_collection.getId(identifier));

                                if (open_bracket) {
                                    i += 1;
                                    assert(tokens[i].id == .r_paren);
                                }
                                break;
                            },
                            .whitespace => {},
                            else => {
                                unreachable;
                            },
                        }
                    } else return error.Malformed;
                },
                // if we hit a parenthesis, then that means we could have
                // nested logical operators. Strip the outer parens and parse
                // that as an expression
                //
                // TODO: figure out if we want to keep parenthesis around as part of the string
                .l_paren => {
                    const target_depth = paren_depth;
                    paren_depth += 1;
                    i += 1;
                    const begin = i;
                    while (i < tokens.len) : (i += 1) {
                        switch (tokens[i].id) {
                            .l_paren => paren_depth += 1,
                            .r_paren => {
                                paren_depth -= 1;
                                if (paren_depth == target_depth) {
                                    try recursiveParseExpr(allocator, tokens[begin..i], buf, string_collection, expr, invert);
                                    break;
                                }
                            },
                            else => {},
                        }
                    } else return error.Malformed;
                },
                .identifier, .pp_num, .char_literal, .char_literal_wide => {
                    const is_macro = blk: {
                        if (tokens[i].id != .identifier and i + 1 < tokens.len)
                            break :blk false;

                        var j = i + 1;
                        skipWhitespace(tokens, &j);

                        // TODO: handle more edge cases
                        break :blk j < tokens.len and tokens[j].id == .l_paren;
                    };

                    if (is_macro) {
                        // a macro invocation is an identifier followed by a left paren, arguments, then a right paren

                        const start_idx = i;
                        i += 1;
                        skipWhitespace(tokens, &i);
                        const l_paren_idx = i;

                        // TODO: handle nested parenthesis
                        while (i < tokens.len and tokens[i].id != .r_paren) : (i += 1) {
                            if (i > l_paren_idx)
                                assert(tokens[i].id != .l_paren);
                        }

                        assert(tokens[i].id == .r_paren);
                        const contents = buf[tokens[start_idx].start..tokens[i].end];
                        try expr.values.append(allocator, try string_collection.getId(contents));
                        try expr.op_with_not.append(allocator, .{
                            .not = invert,
                            .op = .macro_invocation,
                        });
                    } else {
                        const str = buf[tokens[i].start..tokens[i].end];
                        try expr.values.append(allocator, try string_collection.getId(str));
                        try expr.op_with_not.append(allocator, .{
                            .not = false,
                            .op = switch (tokens[i].id) {
                                .identifier => .identifier,
                                .pp_num => .num_literal,
                                .char_literal, .char_literal_wide => .char_literal,
                                else => unreachable,
                            },
                        });
                    }
                },
                .whitespace, .nl => {},
                else => {
                    std.log.err("unhandled: {}", .{tokens[i]});
                    unreachable;
                },
            }
        }
    }
}

pub fn copy(allocator: Allocator, expr: Expr) !Expr {
    var ret = Expr{};
    try ret.op_with_not.appendSlice(allocator, expr.op_with_not.items);
    try ret.values.appendSlice(allocator, expr.values.items);
    return ret;
}

/// this creates a new expression by combining `lhs` and `rhs` with the operator
pub fn fromExprs(
    allocator: Allocator,
    op: enum { @"and", @"or" },
    lhs: Expr,
    rhs: Expr,
) !Expr {
    var ret = Expr{};
    try ret.op_with_not.append(allocator, .{
        .not = false,
        // looks odd, but needed so that the input enum is reduced to just and or or.
        .op = switch (op) {
            .@"and" => .@"and",
            .@"or" => .@"or",
        },
    });

    try ret.op_with_not.appendSlice(allocator, lhs.op_with_not.items);
    try ret.op_with_not.appendSlice(allocator, rhs.op_with_not.items);

    try ret.values.appendSlice(allocator, lhs.values.items);
    try ret.values.appendSlice(allocator, rhs.values.items);

    return ret;
}

pub fn write(
    expr: Expr,
    string_collection: *StringCollection,
    writer: anytype,
) !void {
    try writer.writeAll("#if ");
    try expr.recursiveWrite(0, false, string_collection, writer);
}

fn getValueIdx(expr: Expr, op_idx: u32) u32 {
    var idx: u32 = 0;
    for (expr.op_with_not.items[0..op_idx]) |own|
        idx += if (own.op.isValue()) 1 else 0;

    return idx;
}

fn opCount(expr: Expr, op_idx: u32) u32 {
    if (expr.op_with_not.items[op_idx].op.isValue())
        return 1;

    var count: u32 = 1;
    var budget: u32 = 2;
    while (budget > 0) : (count += 1) {
        if (expr.op_with_not.items[op_idx + count].op.isValue())
            budget -= 1
        else
            budget += 1;
    }

    return count;
}

fn recursiveWrite(
    expr: Expr,
    op_idx: u32,
    parens: bool,
    string_collection: *StringCollection,
    writer: anytype,
) !void {
    const not = expr.op_with_not.items[op_idx].not;
    const op = expr.op_with_not.items[op_idx].op;
    if (op.isValue()) {
        if (not)
            try writer.writeAll("!");

        const value_idx = expr.getValueIdx(op_idx);
        const string_id = expr.values.items[value_idx];
        switch (op) {
            .defined => try writer.print("defined({s})", .{string_collection.getString(string_id)}),
            else => try writer.print("{s}", .{string_collection.getString(string_id)}),
        }

        return;
    }

    if (not and op != .equal)
        try writer.writeAll("!");

    if (parens or (not and op != .equal))
        try writer.writeAll("(");

    assert(!op.isValue());
    const rhs_idx = op_idx + 1;
    const lhs_idx = rhs_idx + expr.opCount(rhs_idx);
    const operator: []const u8 = if (not and op == .equal) "!=" else switch (op) {
        .@"and" => "&&",
        .@"or" => "||",
        .equal => "==",
        .less_than => "<",
        .less_than_equal_to => "<=",
        .greater_than => ">",
        .greater_than_equal_to => ">=",
        .add => "+",
        .subtract => "-",
        .divide => "/",
        .multiply => "*",
        else => unreachable,
    };

    const lhs_op = expr.op_with_not.items[lhs_idx].op;
    const lhs_needs_parens = op.compare(lhs_op) == .lt;
    try expr.recursiveWrite(lhs_idx, lhs_needs_parens, string_collection, writer);
    try writer.print(" {s} ", .{operator});

    const rhs_op = expr.op_with_not.items[rhs_idx].op;
    const rhs_needs_parens = switch (op.compare(rhs_op)) {
        .lt, .eq => true,
        .gt => false,
    };
    try expr.recursiveWrite(rhs_idx, rhs_needs_parens, string_collection, writer);

    if (parens or not and op != .equal)
        try writer.writeAll(")");
}

const TokenTestContext = struct {
    comp: *arocc.Compilation,
    buf: []const u8,
    tokens: std.ArrayList(Token),
    string_collection: StringCollection,

    fn deinit(self: *TokenTestContext) void {
        self.tokens.deinit();
        self.comp.deinit();
        self.string_collection.deinit();

        std.testing.allocator.destroy(self.comp);
    }

    fn getFirstIfExpression(ctx: TokenTestContext) []Token {
        assert(ctx.tokens.items[0].id == .hash);

        return for (ctx.tokens.items) |token, i| {
            if (i > 0 and token.id == .nl)
                break ctx.tokens.items[0..i];
        } else unreachable;
    }
};

fn getTokenTestContext(text: []const u8) !TokenTestContext {
    const comp = try std.testing.allocator.create(arocc.Compilation);
    errdefer std.testing.allocator.destroy(comp);

    comp.* = arocc.Compilation.init(std.testing.allocator);
    errdefer comp.deinit();

    const source = try comp.addSourceFromBuffer("test.h", text);
    var tokenizer = arocc.Tokenizer{
        .buf = source.buf,
        .comp = comp,
        .source = source.id,
    };

    var tokens = std.ArrayList(Token).init(std.testing.allocator);
    errdefer tokens.deinit();

    var string_collection = StringCollection.init(std.testing.allocator);
    errdefer string_collection.deinit();

    while (true) {
        const tok = tokenizer.next();
        try tokens.append(tok);

        switch (tok.id) {
            .eof => break,
            .identifier => {
                const identifier = tokenizer.buf[tok.start..tok.end];
                _ = try string_collection.getId(identifier); // TODO: probably put in string collection
            },
            else => {},
        }
    }

    return TokenTestContext{
        .comp = comp,
        .buf = tokenizer.buf,
        .tokens = tokens,
        .string_collection = string_collection,
    };
}

fn indexOfTokenId(haystack: []const Token, needle: []const Token.Id) ?usize {
    for (haystack) |h, i| {
        for (needle) |n| {
            if (h.id == n)
                return i;
        }
    }

    return null;
}

const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectEqualSlices = std.testing.expectEqualSlices;

fn expectValues(
    expected: []const []const u8,
    actual: []const u32,
    string_collection: *StringCollection,
) !void {
    try expectEqual(expected.len, actual.len);

    for (expected) |e, i|
        try expectEqualStrings(e, string_collection.getString(actual[i]));
}

test "ifdef" {
    var ctx = try getTokenTestContext(
        \\#ifdef SOME_DEFINE
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    try expectEqualSlices(OpWithNot, &.{
        .{ .not = false, .op = .defined },
    }, expr.op_with_not.items);

    try expectValues(&.{"SOME_DEFINE"}, expr.values.items, &ctx.string_collection);
}

test "ifndef" {
    var ctx = try getTokenTestContext(
        \\#ifndef SOME_DEFINE
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    try expectEqualSlices(OpWithNot, &.{
        .{ .not = true, .op = .defined },
    }, expr.op_with_not.items);

    try expectValues(&.{"SOME_DEFINE"}, expr.values.items, &ctx.string_collection);
}

// this test should equate to #if SOME_DEFINE != 0. TODO: are there any other behaviors?
test "if nonzero" {
    var ctx = try getTokenTestContext(
        \\#if SOME_DEFINE
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    try expectEqualSlices(OpWithNot, &.{
        .{ .not = false, .op = .identifier },
    }, expr.op_with_not.items);

    try expectValues(&.{"SOME_DEFINE"}, expr.values.items, &ctx.string_collection);
}

test "if defined" {
    var ctx = try getTokenTestContext(
        \\#if defined(SOME_DEFINE)
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    try expectEqualSlices(OpWithNot, &.{
        .{ .not = false, .op = .defined },
    }, expr.op_with_not.items);

    try expectValues(&.{"SOME_DEFINE"}, expr.values.items, &ctx.string_collection);
}

test "if defined no parenthesis" {
    var ctx = try getTokenTestContext(
        \\#if defined SOME_DEFINE
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    try expectEqualSlices(OpWithNot, &.{
        .{ .not = false, .op = .defined },
    }, expr.op_with_not.items);

    try expectValues(&.{"SOME_DEFINE"}, expr.values.items, &ctx.string_collection);
}

test "if not defined" {
    var ctx = try getTokenTestContext(
        \\#if !defined(SOME_DEFINE)
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    try expectEqualSlices(OpWithNot, &.{
        .{ .not = true, .op = .defined },
    }, expr.op_with_not.items);

    try expectValues(&.{"SOME_DEFINE"}, expr.values.items, &ctx.string_collection);
}

test "if equal" {
    var ctx = try getTokenTestContext(
        \\#if SOME_DEFINE == 1
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    try expectEqualSlices(OpWithNot, &.{
        .{ .not = false, .op = .equal },
        .{ .not = false, .op = .num_literal },
        .{ .not = false, .op = .identifier },
    }, expr.op_with_not.items);

    try expectValues(&.{
        "1",
        "SOME_DEFINE",
    }, expr.values.items, &ctx.string_collection);
}

test "if not equal" {
    var ctx = try getTokenTestContext(
        \\#if SOME_DEFINE != 1
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    try expectEqualSlices(OpWithNot, &.{
        .{ .not = true, .op = .equal },
        .{ .not = false, .op = .num_literal },
        .{ .not = false, .op = .identifier },
    }, expr.op_with_not.items);

    try expectValues(&.{
        "1",
        "SOME_DEFINE",
    }, expr.values.items, &ctx.string_collection);
}

test "if less than" {
    var ctx = try getTokenTestContext(
        \\#if SOME_DEFINE < 1
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    try expectEqualSlices(OpWithNot, &.{
        .{ .not = false, .op = .less_than },
        .{ .not = false, .op = .num_literal },
        .{ .not = false, .op = .identifier },
    }, expr.op_with_not.items);

    try expectValues(&.{
        "1",
        "SOME_DEFINE",
    }, expr.values.items, &ctx.string_collection);
}

test "if greater than" {
    var ctx = try getTokenTestContext(
        \\#if SOME_DEFINE > 1
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    try expectEqualSlices(OpWithNot, &.{
        .{ .not = false, .op = .greater_than },
        .{ .not = false, .op = .num_literal },
        .{ .not = false, .op = .identifier },
    }, expr.op_with_not.items);

    try expectValues(&.{
        "1",
        "SOME_DEFINE",
    }, expr.values.items, &ctx.string_collection);
}

test "if less than equal to" {
    var ctx = try getTokenTestContext(
        \\#if SOME_DEFINE <= 1
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    try expectEqualSlices(OpWithNot, &.{
        .{ .not = false, .op = .less_than_equal_to },
        .{ .not = false, .op = .num_literal },
        .{ .not = false, .op = .identifier },
    }, expr.op_with_not.items);

    try expectValues(&.{
        "1",
        "SOME_DEFINE",
    }, expr.values.items, &ctx.string_collection);
}

test "if greater than equal to" {
    var ctx = try getTokenTestContext(
        \\#if SOME_DEFINE >= 1
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    try expectEqualSlices(OpWithNot, &.{
        .{ .not = false, .op = .greater_than_equal_to },
        .{ .not = false, .op = .num_literal },
        .{ .not = false, .op = .identifier },
    }, expr.op_with_not.items);

    try expectValues(&.{
        "1",
        "SOME_DEFINE",
    }, expr.values.items, &ctx.string_collection);
}

test "if ((A))" {
    var ctx = try getTokenTestContext(
        \\#if ((defined(SOME_DEFINE)))
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    try expectEqualSlices(OpWithNot, &.{
        .{ .not = false, .op = .defined },
    }, expr.op_with_not.items);

    try expectValues(&.{
        "SOME_DEFINE",
    }, expr.values.items, &ctx.string_collection);
}

test "if !!A" {
    var ctx = try getTokenTestContext(
        \\#if !!defined(SOME_DEFINE)
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    try expectEqualSlices(OpWithNot, &.{
        .{ .not = false, .op = .defined },
    }, expr.op_with_not.items);

    try expectValues(&.{
        "SOME_DEFINE",
    }, expr.values.items, &ctx.string_collection);
}

test "if !(!A)" {
    var ctx = try getTokenTestContext(
        \\#if !(!(defined(SOME_DEFINE)))
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    try expectEqualSlices(OpWithNot, &.{
        .{ .not = false, .op = .defined },
    }, expr.op_with_not.items);

    try expectValues(&.{
        "SOME_DEFINE",
    }, expr.values.items, &ctx.string_collection);
}

test "if (!(!A))" {
    var ctx = try getTokenTestContext(
        \\#if (!(!defined(SOME_DEFINE)))
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    try expectEqualSlices(OpWithNot, &.{
        .{ .not = false, .op = .defined },
    }, expr.op_with_not.items);

    try expectValues(&.{
        "SOME_DEFINE",
    }, expr.values.items, &ctx.string_collection);
}

test "if A and B" {
    var ctx = try getTokenTestContext(
        \\#if defined(SOME_DEFINE) && defined(SOMETHING_ELSE)
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    try expectEqualSlices(OpWithNot, &.{
        .{ .not = false, .op = .@"and" },
        .{ .not = false, .op = .defined },
        .{ .not = false, .op = .defined },
    }, expr.op_with_not.items);

    try expectValues(&.{
        "SOMETHING_ELSE",
        "SOME_DEFINE",
    }, expr.values.items, &ctx.string_collection);
}

test "if (A and B)" {
    var ctx = try getTokenTestContext(
        \\#if (defined(SOME_DEFINE) && defined(SOMETHING_ELSE))
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    try expectEqualSlices(OpWithNot, &.{
        .{ .not = false, .op = .@"and" },
        .{ .not = false, .op = .defined },
        .{ .not = false, .op = .defined },
    }, expr.op_with_not.items);

    try expectValues(&.{
        "SOMETHING_ELSE",
        "SOME_DEFINE",
    }, expr.values.items, &ctx.string_collection);
}

test "if A or B" {
    var ctx = try getTokenTestContext(
        \\#if defined(SOME_DEFINE) || defined(SOMETHING_ELSE)
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    try expectEqualSlices(OpWithNot, &.{
        .{ .not = false, .op = .@"or" },
        .{ .not = false, .op = .defined },
        .{ .not = false, .op = .defined },
    }, expr.op_with_not.items);

    try expectValues(&.{
        "SOMETHING_ELSE",
        "SOME_DEFINE",
    }, expr.values.items, &ctx.string_collection);
}

test "if (A or B)" {
    var ctx = try getTokenTestContext(
        \\#if (defined(SOME_DEFINE) || defined(SOMETHING_ELSE))
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    try expectEqualSlices(OpWithNot, &.{
        .{ .not = false, .op = .@"or" },
        .{ .not = false, .op = .defined },
        .{ .not = false, .op = .defined },
    }, expr.op_with_not.items);

    try expectValues(&.{
        "SOMETHING_ELSE",
        "SOME_DEFINE",
    }, expr.values.items, &ctx.string_collection);
}

test "if !(A or B)" {
    var ctx = try getTokenTestContext(
        \\#if !(defined(SOME_DEFINE) || defined(SOMETHING_ELSE))
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    try expectEqualSlices(OpWithNot, &.{
        .{ .not = true, .op = .@"or" },
        .{ .not = false, .op = .defined },
        .{ .not = false, .op = .defined },
    }, expr.op_with_not.items);

    try expectValues(&.{
        "SOMETHING_ELSE",
        "SOME_DEFINE",
    }, expr.values.items, &ctx.string_collection);
}

test "if !(A or !B)" {
    var ctx = try getTokenTestContext(
        \\#if !(defined(SOME_DEFINE) || !defined(SOMETHING_ELSE))
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    try expectEqualSlices(OpWithNot, &.{
        .{ .not = true, .op = .@"or" },
        .{ .not = true, .op = .defined },
        .{ .not = false, .op = .defined },
    }, expr.op_with_not.items);

    try expectValues(&.{
        "SOMETHING_ELSE",
        "SOME_DEFINE",
    }, expr.values.items, &ctx.string_collection);
}

test "if A or (!B and !(C or D)) and !E" {
    var ctx = try getTokenTestContext(
        \\#if defined(FOO) || (!(FOO == 5) && !(defined(BAR) || SUPERJOE < 6)) && !defined(WHATDIDYOUSAY)
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    try expectEqualSlices(OpWithNot, &.{
        .{ .not = false, .op = .@"and" },
        .{ .not = true, .op = .defined },
        .{ .not = false, .op = .@"or" },
        .{ .not = false, .op = .@"and" },
        .{ .not = true, .op = .@"or" },
        .{ .not = false, .op = .less_than },
        .{ .not = false, .op = .num_literal },
        .{ .not = false, .op = .identifier },
        .{ .not = false, .op = .defined },
        .{ .not = true, .op = .equal },
        .{ .not = false, .op = .num_literal },
        .{ .not = false, .op = .identifier },
        .{ .not = false, .op = .defined },
    }, expr.op_with_not.items);

    try expectValues(&.{
        "WHATDIDYOUSAY",
        "6",
        "SUPERJOE",
        "BAR",
        "5",
        "FOO",
        "FOO",
    }, expr.values.items, &ctx.string_collection);
}

test "if A || B > 2" {
    var ctx = try getTokenTestContext(
        \\#if defined(SOME_DEFINE) || MY_NUM > 2
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    try expectEqualSlices(OpWithNot, &.{
        .{ .not = false, .op = .@"or" },
        .{ .not = false, .op = .greater_than },
        .{ .not = false, .op = .num_literal },
        .{ .not = false, .op = .identifier },
        .{ .not = false, .op = .defined },
    }, expr.op_with_not.items);

    try expectValues(&.{
        "2",
        "MY_NUM",
        "SOME_DEFINE",
    }, expr.values.items, &ctx.string_collection);
}

test "if (A || B) > 2" {
    var ctx = try getTokenTestContext(
        \\#if (defined(SOME_DEFINE) || MY_NUM) > 2
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    try expectEqualSlices(OpWithNot, &.{
        .{ .not = false, .op = .greater_than },
        .{ .not = false, .op = .num_literal },
        .{ .not = false, .op = .@"or" },
        .{ .not = false, .op = .identifier },
        .{ .not = false, .op = .defined },
    }, expr.op_with_not.items);

    try expectValues(&.{
        "2",
        "MY_NUM",
        "SOME_DEFINE",
    }, expr.values.items, &ctx.string_collection);
}

test "if A < 2 * 3" {
    var ctx = try getTokenTestContext(
        \\#if MY_NUM < 2 * 3
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    try expectEqualSlices(OpWithNot, &.{
        .{ .not = false, .op = .less_than },
        .{ .not = false, .op = .multiply },
        .{ .not = false, .op = .num_literal },
        .{ .not = false, .op = .num_literal },
        .{ .not = false, .op = .identifier },
    }, expr.op_with_not.items);

    try expectValues(&.{
        "3",
        "2",
        "MY_NUM",
    }, expr.values.items, &ctx.string_collection);
}

test "if (A < 2) * 3 == 0" {
    var ctx = try getTokenTestContext(
        \\#if (MY_NUM < 2) * 3 == 0
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    try expectEqualSlices(OpWithNot, &.{
        .{ .not = false, .op = .equal },
        .{ .not = false, .op = .num_literal },
        .{ .not = false, .op = .multiply },
        .{ .not = false, .op = .num_literal },
        .{ .not = false, .op = .less_than },
        .{ .not = false, .op = .num_literal },
        .{ .not = false, .op = .identifier },
    }, expr.op_with_not.items);

    try expectValues(&.{
        "0",
        "3",
        "2",
        "MY_NUM",
    }, expr.values.items, &ctx.string_collection);
}

test "if (A && B) * 3 == 3" {
    var ctx = try getTokenTestContext(
        \\#if (MY_NUM && defined(FOO)) * 3 == 3
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    try expectEqualSlices(OpWithNot, &.{
        .{ .not = false, .op = .equal },
        .{ .not = false, .op = .num_literal },
        .{ .not = false, .op = .multiply },
        .{ .not = false, .op = .num_literal },
        .{ .not = false, .op = .@"and" },
        .{ .not = false, .op = .defined },
        .{ .not = false, .op = .identifier },
    }, expr.op_with_not.items);

    try expectValues(&.{
        "3",
        "3",
        "FOO",
        "MY_NUM",
    }, expr.values.items, &ctx.string_collection);
}

test "if defined(_XOPEN_SOURCE) && _XOPEN_SOURCE+0 < 700" {
    var ctx = try getTokenTestContext(
        \\#if defined(_XOPEN_SOURCE) && _XOPEN_SOURCE+0 < 700
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    try expectEqualSlices(OpWithNot, &.{
        .{ .not = false, .op = .@"and" },
        .{ .not = false, .op = .less_than },
        .{ .not = false, .op = .num_literal },
        .{ .not = false, .op = .add },
        .{ .not = false, .op = .num_literal },
        .{ .not = false, .op = .identifier },
        .{ .not = false, .op = .defined },
    }, expr.op_with_not.items);

    try expectValues(&.{
        "700",
        "0",
        "_XOPEN_SOURCE",
        "_XOPEN_SOURCE",
    }, expr.values.items, &ctx.string_collection);
}

test "if defined __cplusplus ? __cplusplus >= 201402L : defined __USE_ISOC11" {
    var ctx = try getTokenTestContext(
        \\#if defined __cplusplus ? __cplusplus >= 201402L : defined __USE_ISOC11
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    try expectEqualSlices(OpWithNot, &.{
        .{ .not = false, .op = .ternary },
        .{ .not = false, .op = .defined },
        .{ .not = false, .op = .greater_than_equal_to },
        .{ .not = false, .op = .num_literal },
        .{ .not = false, .op = .identifier },
        .{ .not = false, .op = .defined },
    }, expr.op_with_not.items);

    try expectValues(&.{
        "__USE_ISOC11",
        "201402L",
        "__cplusplus",
        "__cplusplus",
    }, expr.values.items, &ctx.string_collection);
}

test "write.ifdef" {
    var ctx = try getTokenTestContext(
        \\#ifdef SOME_DEFINE
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();

    try expr.write(&ctx.string_collection, out.writer());
    try expectEqualStrings(
        "#if defined(SOME_DEFINE)",
        out.items,
    );
}

test "write.ifndef" {
    var ctx = try getTokenTestContext(
        \\#ifndef SOME_DEFINE
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();

    try expr.write(&ctx.string_collection, out.writer());
    try expectEqualStrings(
        "#if !defined(SOME_DEFINE)",
        out.items,
    );
}

test "write.if equal" {
    var ctx = try getTokenTestContext(
        \\#if SOME_DEFINE == 1
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();

    try expr.write(&ctx.string_collection, out.writer());
    try expectEqualStrings(
        "#if SOME_DEFINE == 1",
        out.items,
    );
}

test "write.if not equal" {
    var ctx = try getTokenTestContext(
        \\#if SOME_DEFINE != 1
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();

    try expr.write(&ctx.string_collection, out.writer());
    try expectEqualStrings(
        "#if SOME_DEFINE != 1",
        out.items,
    );
}

test "write.if less than" {
    var ctx = try getTokenTestContext(
        \\#if SOME_DEFINE < 1
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();

    try expr.write(&ctx.string_collection, out.writer());
    try expectEqualStrings(
        "#if SOME_DEFINE < 1",
        out.items,
    );
}

test "write.if greater than" {
    var ctx = try getTokenTestContext(
        \\#if SOME_DEFINE > 1
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();

    try expr.write(&ctx.string_collection, out.writer());
    try expectEqualStrings(
        "#if SOME_DEFINE > 1",
        out.items,
    );
}

test "write.if greater than equal to" {
    var ctx = try getTokenTestContext(
        \\#if SOME_DEFINE >= 1
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();

    try expr.write(&ctx.string_collection, out.writer());
    try expectEqualStrings(
        "#if SOME_DEFINE >= 1",
        out.items,
    );
}

test "write.if ((A))" {
    var ctx = try getTokenTestContext(
        \\#if ((defined(SOME_DEFINE)))
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();

    try expr.write(&ctx.string_collection, out.writer());
    try expectEqualStrings(
        "#if defined(SOME_DEFINE)",
        out.items,
    );
}

test "write.if !!A" {
    var ctx = try getTokenTestContext(
        \\#if !!defined(SOME_DEFINE)
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();

    try expr.write(&ctx.string_collection, out.writer());
    try expectEqualStrings(
        "#if defined(SOME_DEFINE)",
        out.items,
    );
}

test "write.if (!(!A))" {
    var ctx = try getTokenTestContext(
        \\#if (!(!defined(SOME_DEFINE)))
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();

    try expr.write(&ctx.string_collection, out.writer());
    try expectEqualStrings(
        "#if defined(SOME_DEFINE)",
        out.items,
    );
}

test "write.if A and B" {
    var ctx = try getTokenTestContext(
        \\#if defined(SOME_DEFINE) && defined(SOMETHING_ELSE)
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();

    try expr.write(&ctx.string_collection, out.writer());
    try expectEqualStrings(
        "#if defined(SOME_DEFINE) && defined(SOMETHING_ELSE)",
        out.items,
    );
}

test "write.if !(A or B)" {
    var ctx = try getTokenTestContext(
        \\#if !(defined(SOME_DEFINE) || defined(SOMETHING_ELSE))
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();

    try expr.write(&ctx.string_collection, out.writer());
    try expectEqualStrings(
        "#if !(defined(SOME_DEFINE) || defined(SOMETHING_ELSE))",
        out.items,
    );
}

test "write.if A or (!B and !(C or D)) and !E" {
    var ctx = try getTokenTestContext(
        \\#if defined(FOO) || (!(FOO == 5) && !(defined(BAR) || SUPERJOE < 6)) && !defined(WHATDIDYOUSAY)
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();

    try expr.write(&ctx.string_collection, out.writer());
    try expectEqualStrings(
        "#if defined(FOO) || (FOO != 5 && !(defined(BAR) || SUPERJOE < 6)) && !defined(WHATDIDYOUSAY)",
        out.items,
    );
}

test "write.if defined(_XOPEN_SOURCE) && _XOPEN_SOURCE+0 < 700" {
    var ctx = try getTokenTestContext(
        \\#if defined(_XOPEN_SOURCE) && _XOPEN_SOURCE+0 < 700
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();

    try expr.write(&ctx.string_collection, out.writer());
    try expectEqualStrings(
        "#if defined(_XOPEN_SOURCE) && _XOPEN_SOURCE + 0 < 700",
        out.items,
    );
}

test "write.if A || B > 2" {
    var ctx = try getTokenTestContext(
        \\#if defined(SOME_DEFINE) || MY_NUM > 2
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();

    try expr.write(&ctx.string_collection, out.writer());
    try expectEqualStrings(
        "#if defined(SOME_DEFINE) || MY_NUM > 2",
        out.items,
    );
}

test "write.if (A || B) > 2" {
    var ctx = try getTokenTestContext(
        \\#if (defined(SOME_DEFINE) || MY_NUM) > 2
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();

    try expr.write(&ctx.string_collection, out.writer());
    try expectEqualStrings(
        "#if (defined(SOME_DEFINE) || MY_NUM) > 2",
        out.items,
    );
}

test "write.if A < 2 * 3" {
    var ctx = try getTokenTestContext(
        \\#if MY_NUM < 2 * 3
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();

    try expr.write(&ctx.string_collection, out.writer());
    try expectEqualStrings(
        "#if MY_NUM < 2 * 3",
        out.items,
    );
}

test "write.if (A < 2) * 3 == 0" {
    var ctx = try getTokenTestContext(
        \\#if (MY_NUM < 2) * 3 == 0
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();

    try expr.write(&ctx.string_collection, out.writer());
    try expectEqualStrings(
        "#if (MY_NUM < 2) * 3 == 0",
        out.items,
    );
}

test "write.if (A && B) * 3 == 3" {
    var ctx = try getTokenTestContext(
        \\#if (MY_NUM && defined(FOO)) * 3 == 3
        \\#endif
        \\
    );
    defer ctx.deinit();

    const tokens = ctx.getFirstIfExpression();
    var expr = try Expr.fromTokens(std.testing.allocator, tokens, ctx.buf, &ctx.string_collection);
    defer expr.deinit(std.testing.allocator);

    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();

    try expr.write(&ctx.string_collection, out.writer());
    try expectEqualStrings(
        "#if (MY_NUM && defined(FOO)) * 3 == 3",
        out.items,
    );
}
