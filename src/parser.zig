const std = @import("std");
const builtin = @import("builtin");
const stdx = @import("stdx");
const t = stdx.testing;
const fatal = cy.fatal;
const fmt = @import("fmt.zig");
const v = fmt.v;
const cy = @import("cyber.zig");
const c = @import("capi.zig");
const Token = cy.tokenizer.Token;

const NodeId = cy.NodeId;
const TokenId = u32;
const log = cy.log.scoped(.parser);
const IndexSlice = cy.IndexSlice(u32);

const dumpParseErrorStackTrace = !cy.isFreestanding and builtin.mode == .Debug and !cy.isWasm and true;

const dirModifiers = std.ComptimeStringMap(cy.ast.DirModifierType, .{
    .{ "host", .host },
});

const Block = struct {
    vars: std.StringHashMapUnmanaged(void),

    fn deinit(self: *Block, alloc: std.mem.Allocator) void {
        self.vars.deinit(alloc);
    }
};

const ParseOptions = struct {
    parseComments: bool = false,
};

/// Parses source code into AST.
pub const Parser = struct {
    alloc: std.mem.Allocator,

    /// Context vars.
    next_pos: u32,
    savePos: u32,

    ast: cy.ast.Ast,
    tokens: []const Token,

    blockStack: std.ArrayListUnmanaged(Block),
    cur_indent: u32,

    /// Use the parser pass to record static declarations.
    staticDecls: std.ArrayListUnmanaged(StaticDecl),

    // TODO: This should be implemented by user callbacks.
    /// @name arg.
    name: []const u8,
    /// Variable dependencies.
    deps: std.StringHashMapUnmanaged(NodeId),

    inObjectDecl: bool,

    /// Whether to append to `ast.templateCtNodes` depending on the context.
    inTemplate: bool,
    collectCtNodes: bool,
    ctNodePatchIdx: u32,

    reportFn: *const fn(*anyopaque, format: []const u8, args: []const cy.fmt.FmtValue, pos: u32) anyerror,
    tokenizerReportFn: *const fn(*anyopaque, format: []const u8, args: []const cy.fmt.FmtValue, pos: u32) anyerror!void,
    ctx: *anyopaque,

    has_error: bool,

    /// For custom functions.
    user: struct {
        ctx: *anyopaque,
        advanceChar: *const fn (*anyopaque) void,
        peekChar: *const fn (*anyopaque) u8,
        peekCharAhead: *const fn (*anyopaque, u32) ?u8,
        isAtEndChar: *const fn (*anyopaque) bool,
        getSubStrFromDelta: *const fn (*anyopaque, u32) []const u8,
        savePos: *const fn (*anyopaque) void,
        restorePos: *const fn (*anyopaque) void,
    },

    pub fn init(alloc: std.mem.Allocator) !Parser {
        return .{
            .alloc = alloc,
            .ast = try cy.ast.Ast.init(alloc, ""),
            .next_pos = undefined,
            .savePos = undefined,
            .tokens = undefined,
            .blockStack = .{},
            .cur_indent = 0,
            .name = "",
            .deps = .{},
            .user = undefined,
            .staticDecls = .{},
            .inObjectDecl = false,
            .inTemplate = false,
            .collectCtNodes = false,
            .ctNodePatchIdx = 0,
            .reportFn = defaultReportFn,
            .tokenizerReportFn = cy.tokenizer.defaultReportFn,
            .ctx = undefined,
            .has_error = false,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.ast.deinit(self.alloc);
        for (self.blockStack.items) |*block| {
            block.deinit(self.alloc);
        }
        self.blockStack.deinit(self.alloc);
        self.deps.deinit(self.alloc);
        self.staticDecls.deinit(self.alloc);
    }

    pub fn parseNoErr(self: *Parser, src: []const u8, opts: ParseOptions) !ResultView {
        const res = try self.parse(src, opts);
        if (res.has_error) {
            return error.ParseError;
        }
        return res;
    }

    pub fn parse(self: *Parser, src: []const u8, opts: ParseOptions) !ResultView {
        self.ast.src = src;
        self.name = "";
        self.deps.clearRetainingCapacity();
        self.has_error = false;

        var tokenizer = cy.Tokenizer.init(self.alloc, src);
        defer tokenizer.deinit();

        tokenizer.parseComments = opts.parseComments;
        tokenizer.reportFn = self.tokenizerReportFn;
        tokenizer.ctx = self.ctx;
        try tokenizer.tokens.ensureTotalCapacityPrecise(self.alloc, 511);
        tokenizer.tokenize() catch |err| {
            log.tracev("tokenize error: {}", .{err});
            if (dumpParseErrorStackTrace and !c.silent()) {
                std.debug.dumpStackTrace(@errorReturnTrace().?.*);
            }
            if (err == error.TokenError) {
                return ResultView{
                    .has_error = true,
                    .root_id = cy.NullNode,
                    .ast = self.ast.view(),
                    .name = self.name,
                    .deps = &self.deps,
                };
            } else {
                return err;
            }
        };
        self.ast.comments = tokenizer.consumeComments();
        self.tokens = tokenizer.tokens.items;

        const root_id = self.parseRoot() catch |err| {
            if (dumpParseErrorStackTrace and !c.silent()) {
                std.debug.dumpStackTrace(@errorReturnTrace().?.*);
            }
            if (err == error.ParseError) {
                return ResultView{
                    .has_error = true,
                    .root_id = cy.NullNode,
                    .ast = self.ast.view(),
                    .name = self.name,
                    .deps = &self.deps,
                };
            } else {
                return err;
            }
        };
        return ResultView{
            .has_error = self.has_error or tokenizer.has_error,
            .root_id = root_id,
            .ast = self.ast.view(),
            .name = self.name,
            .deps = &self.deps,
        };
    }

    fn parseRoot(self: *Parser) !NodeId {
        self.next_pos = 0;
        try self.ast.nodes.ensureTotalCapacityPrecise(self.alloc, 127);
        try self.ast.clearNodes(self.alloc);
        self.blockStack.clearRetainingCapacity();
        self.cur_indent = 0;

        const root_id = try self.ast.pushNode(self.alloc, .root, 0);

        const indent = (try self.consumeIndentBeforeStmt()) orelse {
            self.ast.setNodeData(root_id, .{ .root = .{
                .bodyHead = cy.NullNode,
            }});
            return root_id;
        };
        if (indent != 0) {
            return self.reportError("Unexpected indentation.", &.{});
        }

        try self.pushBlock();
        const res = try self.parseBodyStatements(0);

        // Mark last expression stmt.
        const last = self.ast.nodePtr(res.last);
        if (last.type() == .exprStmt) {
            last.data.exprStmt.isLastRootStmt = true;
        }

        const block = self.popBlock();
        _ = block;

        self.ast.setNodeData(root_id, .{ .root = .{
            .bodyHead = res.first,
        }});
        return root_id;
    }

    /// Returns number of spaces that precedes a statement.
    /// The current line is consumed if there is no statement.
    fn consumeIndentBeforeStmt(self: *Parser) !?u32 {
        while (true) {
            // Spaces, count = 0.
            var res: u32 = 0;
            var token = self.peek();
            if (token.tag() == .indent) {
                res = token.data.indent;
                self.advance();
                token = self.peek();
            }
            if (token.tag() == .new_line) {
                self.advance();
                continue;
            } else if (token.tag() == .indent) {
                // If another indent token is encountered, it would be a different type.
                return self.reportError("Can not mix tabs and spaces for indentation.", &.{});
            } else if (token.tag() == .null) {
                return null;
            } else {
                return res;
            }
        }
    }

    fn pushBlock(self: *Parser) !void {
        try self.blockStack.append(self.alloc, .{
            .vars = .{},
        });
    }

    fn popBlock(self: *Parser) Block {
        var block = self.blockStack.pop();
        block.deinit(self.alloc);
        return block;
    }

    fn parseSingleOrIndentedBodyStmts(self: *Parser) !FirstLastStmt {
        var token = self.peek();
        if (token.tag() != .new_line) {
            // Parse single statement only.
            const stmt = try self.parseStatement();
            return .{
                .first = stmt,
                .last = stmt,
            };
        } else {
            self.advance();
            return self.parseIndentedBodyStatements();
        }
    }

    /// Indent is determined by the first body statement.
    fn parseIndentedBodyStatements(self: *Parser) !FirstLastStmt {
        const reqIndent = try self.parseFirstChildIndent(self.cur_indent);
        return self.parseBodyStatements(reqIndent);
    }

    // Assumes the first indent is already consumed.
    fn parseBodyStatements(self: *Parser, reqIndent: u32) !FirstLastStmt {
        const prevIndent = self.cur_indent;
        self.cur_indent = reqIndent;
        defer self.cur_indent = prevIndent;

        var first = try self.parseStatement();
        var last = first;

        // Parse body statements until indentation goes back to at least the previous indent.
        while (true) {
            const start = self.next_pos;
            const indent = (try self.consumeIndentBeforeStmt()) orelse break;
            if (indent == reqIndent) {
                const id = try self.parseStatement();
                self.ast.setNextNode(last, id);
                last = id;
            } else if (try isRecedingIndent(self, prevIndent, reqIndent, indent)) {
                self.next_pos = start;
                break;
            } else {
                return self.reportError("Unexpected indentation.", &.{});
            }
        }
        return .{
            .first = first,
            .last = last,
        };
    }

    /// Parses the first child indent and returns the indent size.
    fn parseFirstChildIndent(self: *Parser, fromIndent: u32) !u32 {
        const indent = (try self.consumeIndentBeforeStmt()) orelse {
            return self.reportError("Block requires an indented child statement. Use the `pass` statement as a placeholder.", &.{});
        };
        if ((fromIndent ^ indent < 0x80000000) or fromIndent == 0) {
            // Either same indent style or indenting from root.
            if (indent > fromIndent) {
                return indent;
            } else {
                return self.reportError("Block requires an indented child statement. Use the `pass` statement as a placeholder.", &.{});
            }
        } else {
            if (fromIndent & 0x80000000 == 0x80000000) {
                return self.reportError("Expected tabs for indentation.", &.{});
            } else {
                return self.reportError("Expected spaces for indentation.", &.{});
            }
        }
    }

    fn parseLambdaFuncWithParam(self: *Parser, paramIdent: NodeId) !NodeId {
        const start = self.next_pos;
        // Assumes first token is `=>`.
        self.advance();
        
        const id = try self.pushNode(.lambda_expr, start);

        // Parse body expr.
        try self.pushBlock();
        const expr = (try self.parseExpr(.{})) orelse {
            return self.reportError("Expected lambda body expression.", &.{});
        };
        const block = self.popBlock();
        _ = block;

        const identPos = self.ast.nodePos(paramIdent);
        const param = try self.ast.pushNode(self.alloc, .funcParam, identPos);
        self.ast.setNodeData(param, .{ .funcParam = .{
            .name = paramIdent,
            .typeSpec = cy.NullNode,
        }});

        const ret = cy.NullNode;
        const header = try self.ast.pushNode(self.alloc, .funcHeader, ret);
        self.ast.setNodeData(header, .{ .funcHeader = .{
            .name = cy.NullNode,
            .paramHead = param,
        }});

        self.ast.setNodeData(id, .{ .func = .{
            .header = header,
            .bodyHead = @intCast(expr),
            .sig_t = .my,
        }});
        return id;
    }

    fn parseNoParamLambdaFunc(self: *Parser) !NodeId {
        const start = self.next_pos;
        // Assumes first token is `=>`.
        self.advance();

        const id = try self.pushNode(.lambda_expr, start);

        // Parse body expr.
        try self.pushBlock();
        const expr = (try self.parseExpr(.{})) orelse {
            return self.reportError("Expected lambda body expression.", &.{});
        };
        _ = self.popBlock();
        
        const ret = cy.NullNode;
        const header = try self.ast.pushNode(self.alloc, .funcHeader, ret);
        self.ast.setNodeData(header, .{ .funcHeader = .{
            .name = cy.NullNode,
            .paramHead = cy.NullNode,
        }});

        self.ast.setNodeData(id, .{ .func = .{
            .header = header,
            .bodyHead = @intCast(expr),
            .sig_t = .my,
        }});
        return id;
    }

    fn parseLeftAssignLambdaFunction(self: *Parser) !NodeId {
        const start = self.next_pos;

        // Assume first token is `func`.
        self.advance();

        const params = try self.parseParenAndFuncParams();
        const ret = try self.parseFuncReturn();

        if (self.peek().tag() == .equal_greater) {
            self.advance();
            const id = try self.pushNode(.lambda_expr, start);

            // Parse body expr.
            try self.pushBlock();
            const expr = (try self.parseExpr(.{})) orelse {
                return self.reportError("Expected lambda body expression.", &.{});
            };
            _ = self.popBlock();

            const header = try self.ast.pushNode(self.alloc, .funcHeader, ret orelse cy.NullNode);
            self.ast.setNodeData(header, .{ .funcHeader = .{
                .name = cy.NullNode,
                .paramHead = params.head,
            }});
            
            self.ast.setNodeData(id, .{ .func = .{
                .header = header,
                .bodyHead = @intCast(expr),
                .sig_t = .func,
            }});
            return id;
        }

        if (self.peek().tag() == .colon) {
            self.advance();
        } else {
            return self.reportError("Expected `:` or `=>`.", &.{});
        }

        const id = try self.pushNode(.lambda_multi, start);

        try self.pushBlock();
        const res = try self.parseSingleOrIndentedBodyStmts();
        _ = self.popBlock();

        const header = try self.ast.pushNode(self.alloc, .funcHeader, ret orelse cy.NullNode);
        self.ast.setNodeData(header, .{ .funcHeader = .{
            .name = cy.NullNode,
            .paramHead = params.head,
        }});

        self.ast.setNodeData(id, .{ .func = .{
            .header = header,
            .bodyHead = @intCast(res.first),
            .sig_t = .func,
        }});
        return id;
    }

    fn parseLambdaFunction(self: *Parser) !NodeId {
        const start = self.next_pos;

        const params = try self.parseParenAndFuncParams();
        const ret = try self.parseFuncReturn();

        var token = self.peek();
        if (token.tag() != .equal_greater) {
            return self.reportError("Expected `=>`.", &.{});
        }
        self.advance();

        const id = try self.pushNode(.lambda_expr, start);

        // Parse body expr.
        try self.pushBlock();
        const expr = (try self.parseExpr(.{})) orelse {
            return self.reportError("Expected lambda body expression.", &.{});
        };
        _ = self.popBlock();

        const header = try self.ast.pushNode(self.alloc, .funcHeader, ret orelse cy.NullNode);
        self.ast.setNodeData(header, .{ .funcHeader = .{
            .name = cy.NullNode,
            .paramHead = params.head,
        }});
        
        self.ast.setNodeData(id, .{ .func = .{
            .header = header,
            .bodyHead = @intCast(expr),
            .sig_t = .my,
        }});
        return id;
    }

    const ListResult = struct {
        head: cy.NodeId,
        len: u32,
    };

    fn parseParenAndFuncParams(self: *Parser) !ListResult {
        const token = self.peek();
        if (token.tag() != .left_paren) {
            return self.reportError("Expected open parenthesis.", &.{});
        }
        self.advance();
        return self.parseFuncParams();
    }

    /// Assumes token at first param ident or right paren.
    /// Let sema check whether param types are required since it depends on the context.
    fn parseFuncParams(self: *Parser) !ListResult {
        var token = self.peek();
        if (token.tag() == .right_paren) {
            self.advance();
            return ListResult{
                .head = cy.NullNode,
                .len = 0,
            };
        }

        if (token.tag() != .ident) {
            return self.reportError("Unexpected token in function param list.", &.{});
        }
    
        // Parse params.
        var start = self.next_pos;
        var name = try self.pushSpanNode(.ident, start);

        self.advance();
        var type_spec = (try self.parseOptTypeSpec(false)) orelse cy.NullNode;

        const paramHead = try self.pushNode(.funcParam, start);
        self.ast.setNodeData(paramHead, .{ .funcParam = .{
            .name = name,
            .typeSpec = type_spec,
        }});

        var numParams: u32 = 1;
        var last = paramHead;
        while (true) {
            token = self.peek();
            switch (token.tag()) {
                .comma => {
                    self.advance();
                },
                .right_paren => {
                    self.advance();
                    break;
                },
                else => return self.reportError("Unexpected token {} in function param list.", &.{v(token.tag())}),
            }

            token = self.peek();
            start = self.next_pos;
            if (token.tag() != .ident) {
                return self.reportError("Expected param identifier.", &.{});
            }

            name = try self.pushSpanNode(.ident, start);
            self.advance();

            type_spec = (try self.parseOptTypeSpec(false)) orelse cy.NullNode;

            const param = try self.pushNode(.funcParam, start);
            self.ast.setNodeData(param, .{ .funcParam = .{
                .name = name,
                .typeSpec = type_spec,
            }});
            self.ast.setNextNode(last, param);
            numParams += 1;
            last = param;
        }
        return ListResult{
            .head = paramHead,
            .len = numParams,
        };
    }

    fn parseFuncReturn(self: *Parser) !?NodeId {
        return self.parseOptTypeSpec(false);
    }

    fn parseOptName(self: *Parser) !?NodeId {
        const start = self.next_pos;
        var token = self.peek();
        switch (token.tag()) {
            .void_k,
            .struct_k,
            .enum_k,
            .type_k,
            .error_k,
            .none_k,
            .ident => {
                self.advance();
                return try self.pushSpanNode(.ident, start);
            },
            .raw_string => {
                self.advance();
                return try self.pushSpanNode(.raw_string_lit, start);
            },
            .string => {
                self.advance();
                return try self.pushSpanNode(.stringLit, start);
            },
            else => return null,
        }
    }

    fn parseOptNamePath(self: *Parser) !?NodeId {
        const first = (try self.parseOptName()) orelse {
            return null;
        };

        var token = self.peek();
        if (token.tag() != .dot) {
            return first;
        }
        
        var last = first;
        while (token.tag() == .dot) {
            self.advance();
            const name = (try self.parseOptName()) orelse {
                return self.reportError("Expected name.", &.{});
            };
            self.ast.setNextNode(last, name);
            last = name;
            token = self.peek();
        }
        return first;
    }

    fn parseEnumMember(self: *Parser) !NodeId {
        const start = self.next_pos;
        if (self.peek().tag() != .case_k) {
            return self.reportError("Expected case keyword.", &.{});
        }
        self.advance();

        const name = (try self.parseOptName()) orelse {
            return self.reportError("Expected member identifier.", &.{});
        };

        var typeSpec: cy.NodeId = cy.NullNode;
        const token = self.peek();
        if (token.tag() != .new_line and token.tag() != .null) {
            if (try self.parseOptTypeSpec(true)) |res| {
                typeSpec = res;
            }
        } else {
            try self.consumeNewLineOrEnd();
        }

        const field = try self.pushNode(.enumMember, start);
        self.ast.setNodeData(field, .{ .enumMember = .{
            .name = name,
            .typeSpec = typeSpec,
        }});
        return field;
    }

    fn parseObjectField(self: *Parser) !?NodeId {
        const start = self.next_pos;

        const name = (try self.parseOptName()) orelse {
            return null;
        };

        const typeSpec = try self.parseOptTypeSpec(true) orelse {
            return self.reportError("Expected field type specifier.", &.{});
        };
        if (self.ast.nodeType(typeSpec) != .objectDecl) {
            try self.consumeNewLineOrEnd();
        }

        const field = try self.pushNode(.objectField, start);
        self.ast.setNodeData(field, .{ .objectField = .{
            .name = name,
            .typeSpec = @intCast(typeSpec),
        }});
        return field;
    }

    fn parseTemplate(self: *Parser) !NodeId {
        const start = self.next_pos;

        // Assumes first token is the `template` keyword.
        self.advance();

        const params = try self.parseParenAndFuncParams();
        self.consumeWhitespaceTokens();

        const ctNodeStart = self.ast.templateCtNodes.items.len;
        self.ctNodePatchIdx = 0;
        self.inTemplate = true;
        self.collectCtNodes = true;
        defer {
            self.inTemplate = false;
            self.collectCtNodes = false;
        }

        const token = self.peek();
        if (token.tag() == .type_k) {
            const id = try self.pushNode(.typeTemplate, start);

            const decl = try self.parseTypeDecl(cy.NullNode, false);
            const ctNodeEnd = self.ast.templateCtNodes.items.len;

            self.ast.setNodeData(id, .{ .typeTemplate = .{
                .paramHead = @intCast(params.head),
                .numParams = @intCast(params.len),
                .typeDecl = decl,
            }});

            try self.staticDecls.append(self.alloc, .{
                .declT = .typeTemplate,
                .nodeId = id,
                .data = .{ .typeTemplate = .{
                    .ctNodeStart = @intCast(ctNodeStart),
                    .ctNodeEnd = @intCast(ctNodeEnd),
                }},
            });
            return id;
        } else {
            return self.reportError("Unsupported template declaration.", &.{});
        }
    }

    fn parseTypeDecl(self: *Parser, modifierHead: cy.NodeId, appendDecl: bool) !NodeId {
        const start = self.next_pos;
        // Assumes first token is the `type` keyword.
        self.advance();

        // Parse name.
        const name = (try self.parseOptName()) orelse {
            return self.reportError("Expected type name identifier.", &.{});
        };

        var token = self.peek();
        switch (token.tag()) {
            .enum_k => {
                var decl_idx: usize = undefined;
                if (appendDecl) {
                    decl_idx = self.staticDecls.items.len;
                    try self.staticDecls.append(self.alloc, .{
                        .declT = .enum_t,
                        .nodeId = undefined,
                        .data = undefined,
                    });
                }

                const decl = try self.parseEnumDecl(start, name);
                if (appendDecl) {
                    self.staticDecls.items[decl_idx].nodeId = decl;
                }
                return decl;
            },
            .struct_k => {
                var decl_idx: usize = undefined;
                if (appendDecl) {
                    decl_idx = self.staticDecls.items.len;
                    try self.staticDecls.append(self.alloc, .{
                        .declT = .struct_t,
                        .nodeId = undefined,
                        .data = undefined,
                    });
                }

                const decl = try self.parseStructDecl(start, .{
                    .name = name,
                    .modHead = modifierHead,
                });
                if (appendDecl) {
                    self.staticDecls.items[decl_idx].nodeId = decl;
                }
                return decl;
            },
            // `object` is optional.
            .object_k,
            .new_line,
            .colon => {
                var decl_idx: usize = undefined;
                if (appendDecl) {
                    decl_idx = self.staticDecls.items.len;
                    try self.staticDecls.append(self.alloc, .{
                        .declT = .object,
                        .nodeId = undefined,
                        .data = undefined,
                    });
                }

                const decl = try self.parseObjectDecl(start, .{
                    .name = name,
                    .modHead = modifierHead,
                });

                if (appendDecl) {
                    self.staticDecls.items[decl_idx].nodeId = decl;
                }
                return decl;
            },
            .equal => {
                const decl = try self.parseTypeAliasDecl(start, name);
                if (appendDecl) {
                    try self.staticDecls.append(self.alloc, .{
                        .declT = .typeAlias,
                        .nodeId = decl,
                        .data = undefined,
                    });
                }
                return decl;
            },
            else => {
                var decl_idx: usize = undefined;
                if (appendDecl) {
                    decl_idx = self.staticDecls.items.len;
                    try self.staticDecls.append(self.alloc, .{
                        .declT = .type_copy,
                        .nodeId = undefined,
                        .data = undefined,
                    });
                }

                const decl = try self.parseTypeCopyDecl(start, name, modifierHead);

                if (appendDecl) {
                    self.staticDecls.items[decl_idx].nodeId = decl;
                }
                return decl;
            }
        }
    }

    fn parseOptTypeSpec(self: *Parser, allowUnnamedType: bool) !?NodeId {
        const token = self.peek();
        switch (token.tag()) {
            .object_k => {
                if (allowUnnamedType) {
                    const decl = try self.parseObjectDecl(token.pos(), .{
                        .name = null,
                        .modHead = cy.NullNode,
                    });
                    try self.staticDecls.append(self.alloc, .{
                        .declT = .object,
                        .nodeId = decl,
                        .data = undefined,
                    });
                    return decl;
                } else {
                    return self.reportError("Unnamed type is not allowed in this context.", &.{});
                }
            },
            .question,
            .pound,
            .void_k,
            .type_k,
            .none_k,
            .ident => {
                return try self.parseTermExpr();
            },
            else => {
                return null;
            },
        }
    }

    fn parseTypeCopyDecl(self: *Parser, start: TokenId, name: NodeId, attr_head: NodeId) !NodeId {
        self.inObjectDecl = true;
        defer self.inObjectDecl = false;

        const target = (try self.parseOptTypeSpec(false)) orelse {
            return self.reportError("Expected type specifier.", &.{});
        };

        var func_head: cy.NodeId = cy.NullNode;
        var num_funcs: u32 = 0;
        if (self.peek().tag() == .colon) {
            self.advance();
            const req_indent = try self.parseFirstChildIndent(self.cur_indent);
            const prev_indent = self.cur_indent;
            defer self.cur_indent = prev_indent;
            self.cur_indent = req_indent;

            const funcs = try self.parseTypeFuncs(req_indent);
            func_head = funcs.head;
            num_funcs = funcs.len;
        }

        const header = try self.pushNode(.type_copy_header, start);
        self.ast.setNodeData(header, .{ .type_copy_header = .{
            .target = target,
            .name = name,
        }});
        self.ast.nodePtr(header).head.data = .{ .type_copy_header = .{ .attr_head = @intCast(attr_head) }};

        const id = try self.pushNode(.type_copy_decl, start);
        self.ast.setNodeData(id, .{ .type_copy_decl = .{
            .header = header,
            .func_head = @intCast(func_head),
            .num_funcs = @intCast(num_funcs),
        }});
        return id;
    }

    /// Assumes current token is `=`.
    fn parseTypeAliasDecl(self: *Parser, start: TokenId, name: NodeId) !NodeId {
        self.advance();
        const typeSpec = (try self.parseOptTypeSpec(false)) orelse {
            return self.reportError("Expected type specifier.", &.{});
        };

        const id = try self.pushNode(.typeAliasDecl, start);
        self.ast.setNodeData(id, .{ .typeAliasDecl = .{
            .name = name,
            .typeSpec = typeSpec,
        }});
        return id;
    }

    fn parseEnumDecl(self: *Parser, start: TokenId, name: NodeId) !NodeId {
        // Assumes first token is the `enum` keyword.
        self.advance();

        var token = self.peek();
        if (token.tag() == .colon) {
            self.advance();
        } else {
            return self.reportError("Expected colon.", &.{});
        }

        const reqIndent = try self.parseFirstChildIndent(self.cur_indent);
        const prevIndent = self.cur_indent;
        self.cur_indent = reqIndent;
        defer self.cur_indent = prevIndent;

        var firstMember = try self.parseEnumMember();
        var lastMember = firstMember;
        var numMembers: u32 = 1;
        var isChoiceType = false;

        while (true) {
            const start2 = self.next_pos;
            const indent = (try self.consumeIndentBeforeStmt()) orelse break;
            if (indent == reqIndent) {
                const id = try self.parseEnumMember();
                if (!isChoiceType) {
                    const member = self.ast.nodePtr(id);
                    if (member.data.enumMember.typeSpec != cy.NullNode) {
                        isChoiceType = true;
                    }
                }
                self.ast.setNextNode(lastMember, id);
                lastMember = id;
                numMembers += 1;
            } else if (try isRecedingIndent(self, prevIndent, reqIndent, indent)) {
                self.next_pos = start2;
                break;
            } else {
                return self.reportError("Unexpected indentation.", &.{});
            }
        }
        const id = try self.pushNode(.enumDecl, start);
        self.ast.setNodeData(id, .{ .enumDecl = .{
            .name = @intCast(name),
            .memberHead = @intCast(firstMember),
            .numMembers = @intCast(numMembers),
            .isChoiceType = isChoiceType,
        }});
        return id;
    }

    fn pushObjectDecl(self: *Parser, start: TokenId, node_t: cy.NodeType, params: TypeDeclParams, fieldsHead: NodeId, numFields: u32, funcsHead: NodeId, numFuncs: u32) !NodeId {
        const id = try self.pushNode(node_t, start);

        const header = try self.pushNode(.objectHeader, start);
        if (params.name) |name| {
            self.ast.setNodeData(header, .{ .objectHeader = .{
                .name = @intCast(name),
                .fieldHead = @intCast(fieldsHead),
                .unnamed = false,
                .numFields = @intCast(numFields),
            }});
        } else {
            self.ast.setNodeData(header, .{ .objectHeader = .{
                .name = cy.NullNode,
                .fieldHead = @intCast(fieldsHead),
                .unnamed = true,
                .numFields = @intCast(numFields),
            }});
        }
        self.ast.nodePtr(header).head.data = .{ .objectHeader = .{ .modHead = @intCast(params.modHead) }};

        self.ast.setNodeData(id, .{ .objectDecl = .{
            .header = header,
            .funcHead = @intCast(funcsHead),
            .numFuncs = @intCast(numFuncs),
        }});
        return id;
    }

    const TypeDeclParams = struct {
        name: ?NodeId,
        modHead: cy.NodeId,
    };

    fn parseTypeFields(self: *Parser, req_indent: u32, has_more_members: *bool) !ListResult {
        const first = (try self.parseObjectField()) orelse {
            has_more_members.* = true;
            return ListResult{
                .head = cy.NullNode,
                .len = 0,
            };
        };
        var count: u32 = 1;
        var last = first;
        while (true) {
            const start = self.next_pos;
            const indent = (try self.consumeIndentBeforeStmt()) orelse {
                has_more_members.* = false;
                break;
            };
            if (indent == req_indent) {
                const id = (try self.parseObjectField()) orelse {
                    has_more_members.* = true;
                    break;
                };
                count += 1;
                self.ast.setNextNode(last, id);
                last = id;
            } else {
                self.next_pos = start;
                has_more_members.* = false;
                break;
            }
        }
        return ListResult{ .head = first, .len = count };
    }

    fn parseTypeFuncs(self: *Parser, req_indent: u32) !ListResult {
        if (self.isAtEnd()) {
            return ListResult{ .head = cy.NullNode, .len = 0 };
        }
        const first = try self.parseStatement();
        var node_t = self.ast.nodeType(first);
        if (node_t != .funcDecl) {
            return self.reportErrorAtSrc("Expected function.", &.{}, self.ast.nodePos(first));
        }

        var last = first;
        var count: u32 = 1;

        while (true) {
            const start = self.next_pos;
            const indent = (try self.consumeIndentBeforeStmt()) orelse break;
            if (indent == req_indent) {
                const func = try self.parseStatement();
                node_t = self.ast.nodeType(func);
                if (node_t != .funcDecl) {
                    return self.reportErrorAtSrc("Expected function.", &.{}, self.ast.nodePos(func));
                }
                self.ast.setNextNode(last, func);
                last = func;
                count += 1;
            } else {
                self.next_pos = start;
                break;
            }
        }
        return ListResult{ .head = first, .len = count };
    }

    fn parseStructDecl(self: *Parser, start: TokenId, params: TypeDeclParams) anyerror!NodeId {
        self.inObjectDecl = true;
        defer self.inObjectDecl = false;

        var token = self.peek();
        if (token.tag() != .struct_k) {
            return self.reportErrorAt("Expected `struct` keyword.", &.{}, self.next_pos);
        }
        self.advance();

        token = self.peek();
        if (token.tag() == .colon) {
            self.advance();
        } else {
            // Only declaration. No members.
            return self.pushObjectDecl(start, .structDecl, params, cy.NullNode, 0, cy.NullNode, 0);
        }

        const req_indent = try self.parseFirstChildIndent(self.cur_indent);
        const prev_indent = self.cur_indent;
        defer self.cur_indent = prev_indent;
        self.cur_indent = req_indent;

        var has_more_members: bool = undefined;
        const fields = try self.parseTypeFields(req_indent, &has_more_members);
        if (!has_more_members) {
            return self.pushObjectDecl(start, .structDecl, params, fields.head, fields.len, cy.NullNode, 0);
        }
        const funcs = try self.parseTypeFuncs(req_indent);
        return self.pushObjectDecl(start, .structDecl, params, fields.head, fields.len, funcs.head, funcs.len);
    }

    fn parseObjectDecl(self: *Parser, start: TokenId, params: TypeDeclParams) anyerror!NodeId {
        self.inObjectDecl = true;
        defer self.inObjectDecl = false;

        var token = self.peek();
        // Optional `object` keyword.
        if (token.tag() == .object_k) {
            self.advance();
        }

        token = self.peek();
        if (token.tag() == .colon) {
            self.advance();
        } else {
            // Only declaration. No members.
            return self.pushObjectDecl(start, .objectDecl, params, cy.NullNode, 0, cy.NullNode, 0);
        }

        const req_indent = try self.parseFirstChildIndent(self.cur_indent);
        const prev_indent = self.cur_indent;
        defer self.cur_indent = prev_indent;
        self.cur_indent = req_indent;

        var has_more_members: bool = undefined;
        const fields = try self.parseTypeFields(req_indent, &has_more_members);
        if (!has_more_members) {
            return self.pushObjectDecl(start, .objectDecl, params, fields.head, fields.len, cy.NullNode, 0);
        }
        const funcs = try self.parseTypeFuncs(req_indent);
        return self.pushObjectDecl(start, .objectDecl, params, fields.head, fields.len, funcs.head, funcs.len);
    }

    fn parseFuncDecl(self: *Parser, modifierHead: cy.NodeId) !NodeId {
        const start = self.next_pos;
        // Assumes first token is the `func` keyword.
        self.advance();

        // Parse function name.
        const name = (try self.parseOptNamePath()) orelse {
            return self.reportError("Expected function name identifier.", &.{});
        };

        const params = try self.parseParenAndFuncParams();
        const ret = try self.parseFuncReturn();

        if (self.inTemplate) self.collectCtNodes = false;
        defer {
            if (self.inTemplate) self.collectCtNodes = true;
        }

        const nameN = self.ast.nodePtr(name);
        const nameStr = self.ast.nodeString(nameN.*);
        const block = &self.blockStack.items[self.blockStack.items.len-1];
        try block.vars.put(self.alloc, nameStr, {});

        var token = self.peek();
        if (token.tag() == .colon) {
            self.advance();

            try self.pushBlock();
            const res = try self.parseSingleOrIndentedBodyStmts();
            _ = self.popBlock();

            const header = try self.ast.pushNode(self.alloc, .funcHeader, ret orelse cy.NullNode);
            self.ast.setNodeData(header, .{ .funcHeader = .{
                .name = name,
                .paramHead = params.head,
            }});
            self.ast.nodePtr(header).head.data = .{ .funcHeader = .{ .modHead = @intCast(modifierHead) }};

            const id = try self.pushNode(.funcDecl, start);
            self.ast.setNodeData(id, .{ .func = .{
                .header = header,
                .bodyHead = @intCast(res.first),
                .sig_t = .func,
            }});

            if (!self.inTemplate) {
                try self.staticDecls.append(self.alloc, .{
                    .declT = if (self.inObjectDecl) .implicit_method else .func,
                    .nodeId = id,
                    .data = undefined,
                });
            }
            return id;
        } else {
            // Just a declaration, no body.
            const header = try self.ast.pushNode(self.alloc, .funcHeader, ret orelse cy.NullNode);
            self.ast.setNodeData(header, .{ .funcHeader = .{
                .name = name,
                .paramHead = params.head,
            }});
            self.ast.nodePtr(header).head.data = .{ .funcHeader = .{ .modHead = @intCast(modifierHead) }};

            const id = try self.pushNode(.funcDecl, start);
            self.ast.setNodeData(id, .{ .func = .{
                .header = header,
                .bodyHead = cy.NullNode,
                .sig_t = .func,
            }});

            if (!self.inTemplate) {
                try self.staticDecls.append(self.alloc, .{
                    .declT = if (self.inObjectDecl) .implicit_method else .funcInit,
                    .nodeId = id,
                    .data = undefined,
                });
            }
            return id;
        }
    }

    fn parseElseStmt(self: *Parser) anyerror!NodeId {
        const save = self.next_pos;
        const indent = try self.consumeIndentBeforeStmt();
        if (indent != self.cur_indent) {
            self.next_pos = save;
            return cy.NullNode;
        }

        var token = self.peek();
        if (token.tag() != .else_k) {
            self.next_pos = save;
            return cy.NullNode;
        }

        const elseBlock = try self.pushNode(.else_block, self.next_pos);
        self.advance();

        token = self.peek();
        if (token.tag() == .colon) {
            // else block.
            self.advance();

            const res = try self.parseSingleOrIndentedBodyStmts();
            self.ast.setNodeData(elseBlock, .{ .else_block = .{
                .cond = cy.NullNode,
                .body_head = res.first,
            }});
            return elseBlock;
        } else {
            // else if block.
            const cond = (try self.parseExpr(.{})) orelse {
                return self.reportError("Expected else if condition.", &.{});
            };
            token = self.peek();
            if (token.tag() == .colon) {
                self.advance();

                const res = try self.parseSingleOrIndentedBodyStmts();
                self.ast.setNodeData(elseBlock, .{ .else_block = .{
                    .cond = cond,
                    .body_head = res.first,
                }});

                const nested_else = try self.parseElseStmt();
                if (nested_else != cy.NullNode) {
                    self.ast.setNextNode(elseBlock, nested_else);
                }
                return elseBlock;
            } else {
                return self.reportError("Expected colon after else if condition.", &.{});
            }
        }
    }

    fn consumeStmtIndentTo(self: *Parser, reqIndent: u32) !void {
        const indent = (try self.consumeIndentBeforeStmt()) orelse {
            return self.reportError("Expected statement.", &.{});
        };
        if (reqIndent != indent) {
            return self.reportError("Unexpected statement indentation.", &.{});
        }
    }

    fn tryConsumeStmtIndentTo(self: *Parser, reqIndent: u32) !bool {
        const save = self.next_pos;
        const indent = (try self.consumeIndentBeforeStmt()) orelse return false;
        if (reqIndent != indent) {
            self.next_pos = save;
            return false;
        }
        return true;
    }

    fn parseSwitch(self: *Parser, isStmt: bool) !NodeId {
        const start = self.next_pos;
        // Assumes first token is the `switch` keyword.
        self.advance();

        const expr = (try self.parseExpr(.{})) orelse {
            return self.reportError("Expected switch expression.", &.{});
        };

        var caseIndent = self.cur_indent;
        var isBlock = false;
        if (self.peek().tag() == .colon) {
            isBlock = true;
            self.advance();
            caseIndent = try self.parseFirstChildIndent(self.cur_indent);
        } else if (self.peek().tag() == .new_line) {
            try self.consumeStmtIndentTo(caseIndent);
        } else {
            return self.reportError("Expected colon after switch condition.", &.{});
        }

        var firstCase = (try self.parseCaseBlock()) orelse {
            return self.reportError("Expected case or else block.", &.{});
        };
        var lastCase = firstCase;
        var numCases: u32 = 1;

        // Parse body statements until no more case blocks indentation recedes.
        while (true) {
            const save = self.next_pos;
            if (!try self.tryConsumeStmtIndentTo(caseIndent)) {
                break;
            }
            const case = (try self.parseCaseBlock()) orelse {
                if (isBlock) {
                    return self.reportError("Expected case or else block.", &.{});
                }
                // Restore so that next statement outside switch can be parsed.
                self.next_pos = save;
                break;
            };
            numCases += 1;
            self.ast.setNextNode(lastCase, case);
            lastCase = case;
        }

        const nodet: cy.NodeType = if (isStmt) .switchStmt else .switchExpr;
        const switchBlock = try self.pushNode(nodet, start);
        self.ast.setNodeData(switchBlock, .{ .switchBlock = .{
            .expr = expr,
            .caseHead = @intCast(firstCase),
            .numCases = @intCast(numCases),
        }});
        return switchBlock;
    }

    fn parseTryStmt(self: *Parser) !NodeId {
        const start = self.next_pos;
        // Assumes first tokens are `try` and `:`.
        self.advance();
        self.advance();

        const stmt = try self.pushNode(.tryStmt, start);

        const tryStmts = try self.parseSingleOrIndentedBodyStmts();

        const indent = try self.consumeIndentBeforeStmt();
        if (indent != self.cur_indent) {
            return self.reportError("Expected catch block.", &.{});
        }

        var token = self.peek();
        if (token.tag() != .catch_k) {
            return self.reportError("Expected catch block.", &.{});
        }
        const catchStmt = try self.pushNode(.catchStmt, self.next_pos);
        self.advance();

        token = self.peek();
        var errorVar: NodeId = cy.NullNode;
        if (token.tag() == .ident) {
            errorVar = try self.pushSpanNode(.ident, self.next_pos);
            self.advance();
        }

        token = self.peek();
        if (token.tag() != .colon) {
            return self.reportError("Expected colon.", &.{});
        }
        self.advance();

        const catchBody = try self.parseSingleOrIndentedBodyStmts();

        self.ast.setNodeData(catchStmt, .{ .catchStmt = .{
            .errorVar = errorVar,
            .bodyHead = catchBody.first,
        }});

        self.ast.setNodeData(stmt, .{ .tryStmt = .{
            .bodyHead = tryStmts.first,
            .catchStmt = catchStmt,
        }});
        return stmt;
    }

    fn parseIfStatement(self: *Parser) !NodeId {
        const start = self.next_pos;
        // Assumes first token is the `if` keyword.
        self.advance();

        const cond = (try self.parseExpr(.{})) orelse {
            return self.reportError("Expected if condition.", &.{});
        };

        var token = self.peek();
        if (token.tag() == .colon) {
            self.advance();
            const ifStmt = try self.pushNode(.if_stmt, start);

            const res = try self.parseSingleOrIndentedBodyStmts();

            const else_block = try self.parseElseStmt();

            const if_branch = try self.pushNode(.if_branch, start);
            self.ast.setNodeData(if_branch, .{ .if_branch = .{
                .cond = cond,
                .body_head = res.first,
            }});

            self.ast.setNodeData(ifStmt, .{ .if_stmt = .{
                .if_branch = if_branch,
                .else_block = else_block,
            }});
            return ifStmt;
        } else if (token.tag() == .capture) {
            self.advance();

            const unwrap = (try self.parseExpr(.{})) orelse {
                return self.reportError("Expected unwrap variable.", &.{});
            };

            if (self.peek().tag() != .colon) {
                return self.reportError("Expected colon.", &.{});
            }
            self.advance();

            const ifStmt = try self.pushNode(.if_unwrap_stmt, start);

            const res = try self.parseSingleOrIndentedBodyStmts();

            const else_block = try self.parseElseStmt();

            const if_unwrap = try self.pushNode(.if_unwrap, start);
            self.ast.setNodeData(if_unwrap, .{ .if_unwrap = .{
                .opt = cond,
                .unwrap = unwrap,
            }});
            self.ast.nodePtr(if_unwrap).head.data = .{ .if_unwrap = .{ .body_head = @intCast(res.first) }};

            self.ast.setNodeData(ifStmt, .{ .if_unwrap_stmt = .{
                .if_unwrap = if_unwrap,
                .else_block = else_block,
            }});
            return ifStmt;
        } else {
            return self.reportError("Expected colon after if condition.", &.{});
        }
    }

    fn parseImportStmt(self: *Parser) !NodeId {
        const start = self.next_pos;
        // Assumes first token is the `import` keyword.
        self.advance();

        var token = self.peek();
        if (token.tag() == .ident) {
            const ident = try self.pushSpanNode(.ident, self.next_pos);
            self.advance();

            token = self.peek();
            var spec: cy.NodeId = cy.NullNode;
            if (token.tag() != .new_line) {
                spec = (try self.parseExpr(.{})) orelse {
                    return self.reportError("Expected import specifier.", &.{});
                };
                const spec_t = self.ast.nodeType(spec);
                if (spec_t == .raw_string_lit) {
                    try self.consumeNewLineOrEnd();
                } else {
                    return self.reportError("Expected import specifier to be a string. {}", &.{fmt.v(spec_t)});
                }
            } else {
                self.advance();
            }

            const import = try self.pushNode(.importStmt, start);
            self.ast.setNodeData(import, .{ .importStmt = .{
                .name = ident,
                .spec = spec,
            }});

            try self.staticDecls.append(self.alloc, .{
                .declT = .import,
                .nodeId = import,
                .data = undefined,
            });
            return import;
        } else {
            return self.reportError("Expected import clause.", &.{});
        }
    }

    fn parseWhileStatement(self: *Parser) !NodeId {
        const start = self.next_pos;
        // Assumes first token is the `while` keyword.
        self.advance();

        var token = self.peek();
        if (token.tag() == .colon) {
            self.advance();

            // Infinite loop.
            const res = try self.parseSingleOrIndentedBodyStmts();

            const whileStmt = try self.pushNode(.whileInfStmt, start);
            self.ast.setNodeData(whileStmt, .{ .whileInfStmt = .{
                .bodyHead = res.first,
            }});
            return whileStmt;
        }

        // Parse next token as expression.
        const expr_id = (try self.parseExpr(.{})) orelse {
            return self.reportError("Expected condition expression.", &.{});
        };

        token = self.peek();
        if (token.tag() == .colon) {
            self.advance();
            const res = try self.parseSingleOrIndentedBodyStmts();

            const whileStmt = try self.pushNode(.whileCondStmt, start);
            self.ast.setNodeData(whileStmt, .{ .whileCondStmt = .{
                .cond = expr_id,
                .bodyHead = res.first,
            }});
            return whileStmt;
        } else if (token.tag() == .capture) {
            self.advance();
            token = self.peek();
            const ident = (try self.parseExpr(.{})) orelse {
                return self.reportError("Expected ident.", &.{});
            };
            if (self.ast.nodeType(ident) != .ident) {
                return self.reportError("Expected ident.", &.{});
            }
            token = self.peek();
            if (token.tag() != .colon) {
                return self.reportError("Expected :.", &.{});
            }
            self.advance();
            const res = try self.parseSingleOrIndentedBodyStmts();

            const whileStmt = try self.pushNode(.whileOptStmt, start);
            const header = try self.pushNode(.whileOptHeader, start);
            self.ast.setNodeData(header, .{ .whileOptHeader = .{
                .opt = expr_id,
                .capture = ident,
            }});
            self.ast.setNodeData(whileStmt, .{ .whileOptStmt = .{
                .header = header,
                .bodyHead = res.first,
            }});
            return whileStmt;
        } else {
            return self.reportError("Expected :.", &.{});
        }
    }

    fn parseForStatement(self: *Parser) !NodeId {
        const start = self.next_pos;
        // Assumes first token is the `for` keyword.
        self.advance();

        var token = self.peek();
        // Parse next token as expression.
        const expr_pos = self.next_pos;
        const expr_id = (try self.parseExpr(.{})) orelse {
            return self.reportError("Expected condition expression.", &.{});
        };

        const iter = self.ast.node(expr_id);
        if (iter.type() == .range) {
            if (iter.data.range.end == cy.NullNode) {
                return self.reportError("Expected right range expression.", &.{});
            }

            const header = try self.pushNode(.forRangeHeader, expr_pos);
            self.ast.setNodeData(header, .{ .forRangeHeader = .{
                .start = iter.data.range.start,
                .end = iter.data.range.end,
                .increment = iter.data.range.inc,
            }});

            token = self.peek();
            if (token.tag() == .colon) {
                self.advance();

                const res = try self.parseSingleOrIndentedBodyStmts();

                const for_stmt = try self.pushNode(.forRangeStmt, start);
                self.ast.setNodeData(for_stmt, .{ .forRangeStmt = .{
                    .header = header,
                    .bodyHead = res.first,
                }});
                self.ast.nodePtr(header).head.data = .{ .forRangeHeader = .{ .eachClause = cy.NullNode }};
                return for_stmt;
            } else if (token.tag() == .capture) {
                self.advance();

                token = self.peek();
                const ident = (try self.parseExpr(.{})) orelse {
                    return self.reportError("Expected ident.", &.{});
                };
                if (self.ast.nodeType(ident) != .ident) {
                    return self.reportErrorAt("Expected ident.", &.{}, token.pos());
                }
                token = self.peek();
                if (token.tag() != .colon) {
                    return self.reportError("Expected :.", &.{});
                }
                self.advance();

                const res = try self.parseSingleOrIndentedBodyStmts();

                const for_stmt = try self.pushNode(.forRangeStmt, start);
                self.ast.setNodeData(for_stmt, .{ .forRangeStmt = .{
                    .header = header,
                    .bodyHead = res.first,
                }});
                self.ast.nodePtr(header).head.data = .{ .forRangeHeader = .{ .eachClause = @intCast(ident) }};
                return for_stmt;
            } else {
                return self.reportError("Expected :.", &.{});
            }
        }

        token = self.peek();
        if (token.tag() == .colon) {
            self.advance();
            const res = try self.parseSingleOrIndentedBodyStmts();

            const header = try self.pushNode(.forIterHeader, start);
            self.ast.setNodeData(header, .{ .forIterHeader = .{
                .iterable = expr_id,
                .eachClause = cy.NullNode,
            }});
            self.ast.nodePtr(header).head.data = .{ .forIterHeader = .{ .count = cy.NullNode }};

            const forStmt = try self.pushNode(.forIterStmt, start);
            self.ast.setNodeData(forStmt, .{ .forIterStmt = .{
                .header = header,
                .bodyHead = res.first,
            }});
            return forStmt;
        } else if (token.tag() == .capture) {
            self.advance();
            token = self.peek();
            var eachClause: NodeId = undefined;
            if (token.tag() == .left_bracket) {
                eachClause = try self.parseSeqDestructure();
            } else {
                eachClause = (try self.parseExpr(.{})) orelse {
                    return self.reportError("Expected each clause.", &.{});
                };
            }

            // Optional count var.
            var count: NodeId = cy.NullNode;
            if (self.peek().tag() == .comma) {
                self.advance();
                count = (try self.parseExpr(.{})) orelse {
                    return self.reportError("Expected count declaration.", &.{});
                };
            }

            if (self.peek().tag() == .colon) {
                self.advance();
            } else {
                return self.reportError("Expected :.", &.{});
            }

            const res = try self.parseSingleOrIndentedBodyStmts();

            const header = try self.pushNode(.forIterHeader, start);
            self.ast.setNodeData(header, .{ .forIterHeader = .{
                .iterable = expr_id,
                .eachClause = eachClause,
            }});
            self.ast.nodePtr(header).head.data = .{ .forIterHeader = .{ .count = @intCast(count) }};

            const forStmt = try self.pushNode(.forIterStmt, start);
            self.ast.setNodeData(forStmt, .{ .forIterStmt = .{
                .header = header,
                .bodyHead = res.first,
            }});
            return forStmt;
        } else {
            return self.reportError("Expected :.", &.{});
        }
    }

    // fn parseBlock(self: *Parser) !NodeId {
    //     const start = self.next_pos;
    //     // Assumes first token is the ident.
    //     const name = try self.pushSpanNode(.ident, start);
    //     self.advance();
    //     // Assumes second token is colon.
    //     self.advance();

    //     // Parse body.
    //     try self.pushBlock();
    //     const res = try self.parseIndentedBodyStatements();
    //     _ = self.popBlock();
        
    //     const id = try self.pushNode(.label_decl, start);
    //     self.nodes.items[id].head = .{
    //         .left_right = .{
    //             .left = name,
    //             .right = res.first,
    //         },
    //     };
    //     return id;
    // }

    fn parseCaseBlock(self: *Parser) !?NodeId {
        const start = self.next_pos;
        var token = self.peek();
        var firstCond: NodeId = undefined;
        var isElse: bool = false;
        var numConds: u32 = 0;
        var bodyExpr: bool = false;
        var capture: u24 = cy.NullNode;
        if (token.tag() == .case_k) {
            self.advance();
            firstCond = (try self.parseTightTermExpr()) orelse {
                return self.reportError("Expected case condition.", &.{});
            };
            numConds += 1;

            var lastCond = firstCond;
            while (true) {
                token = self.peek();
                if (token.tag() == .colon) {
                    self.advance();
                    break;
                } else if (token.tag() == .equal_greater) {
                    self.advance();
                    bodyExpr = true;
                    break;
                } else if (token.tag() == .comma) {
                    self.advance();
                    self.consumeWhitespaceTokens();
                    const cond = (try self.parseTightTermExpr()) orelse {
                        return self.reportError("Expected case condition.", &.{});
                    };
                    self.ast.setNextNode(lastCond, cond);
                    lastCond = cond;
                    numConds += 1;
                } else if (token.tag() == .capture) {
                    self.advance();

                    // Parse next token as expression.
                    capture = @intCast(try self.parseTermExpr());

                    token = self.peek();
                    if (token.tag() == .colon) {
                        self.advance();
                        break;
                    } else if (token.tag() == .equal_greater) {
                        self.advance();
                        bodyExpr = true;
                        break;
                    } else {
                        return self.reportError("Expected comma or colon.", &.{});
                    }
                } else {
                    return self.reportError("Expected comma or colon.", &.{});
                }
            }
        } else if (token.tag() == .else_k) {
            self.advance();
            isElse = true;
            firstCond = cy.NullNode;

            if (self.peek().tag() == .colon) {
                self.advance();
            } else if (self.peek().tag() == .equal_greater) {
                self.advance();
                bodyExpr = true;
            } else {
                return self.reportError("Expected colon or `=>`.", &.{});
            }
        } else return null;

        // Parse body.
        var bodyHead: cy.NodeId = undefined;
        if (bodyExpr) {
            bodyHead = (try self.parseExpr(.{})) orelse {
                return self.reportError("Expected expression.", &.{});
            };
        } else {
            const res = try self.parseSingleOrIndentedBodyStmts();
            bodyHead = res.first;
        }

        const case = try self.pushNode(.caseBlock, start);

        var header: NodeId = cy.NullNode;
        if (!isElse) {
            header = try self.pushNode(.caseHeader, start);
            self.ast.setNodeData(header, .{ .caseHeader = .{
                .condHead = firstCond,
                .capture = capture,
                .numConds = @intCast(numConds),
            }});
        }

        self.ast.setNodeData(case, .{ .caseBlock = .{
            .header = header,
            .bodyHead = @intCast(bodyHead),
            .bodyIsExpr = bodyExpr,
        }});
        return case;
    }

    fn parseStatement(self: *Parser) anyerror!NodeId {
        var token = self.peek();
        switch (token.tag()) {
            .ident => {
                const token2 = self.peekAhead(1);
                if (token2.tag() == .colon) {
                    // return try self.parseBlock();
                    return self.reportError("Unsupported block statement.", &.{});
                } else {
                    if (try self.parseExprOrAssignStatement()) |id| {
                        return id;
                    }
                }
            },
            .at => {
                const start = self.next_pos;
                _ = start;
                self.advance();
                token = self.peek();

                if (token.tag() == .ident) {
                    return self.reportError("Unsupported @.", &.{});
                } else {
                    return self.reportError("Expected ident after @.", &.{});
                }
            },
            .pound => {
                const start = self.next_pos;
                self.advance();
                token = self.peek();

                if (token.tag() == .ident) {
                    const name = self.ast.src[token.pos()..token.data.end_pos];

                    if (dirModifiers.get(name)) |dir| {
                        const modifier = try self.pushNode(.dirModifier, self.next_pos);
                        self.ast.setNodeData(modifier, .{ .dirModifier = .{
                            .type = dir,
                        }});
                        self.advance();
                        self.consumeWhitespaceTokens();

                        if (self.peek().tag() == .func_k) {
                            return try self.parseFuncDecl(modifier);
                        } else if (self.peek().tag() == .var_k) {
                            return try self.parseVarDecl(modifier, true);
                        } else if (self.peek().tag() == .my_k) {
                            return try self.parseVarDecl(modifier, false);
                        } else if (self.peek().tag() == .type_k) {
                            return try self.parseTypeDecl(modifier, true);
                        } else {
                            return self.reportError("Expected declaration statement.", &.{});
                        }
                    } else {
                        const ident = try self.pushSpanNode(.ident, self.next_pos);
                        self.advance();

                        if (self.peek().tag() != .left_paren) {
                            return self.reportError("Expected ( after ident.", &.{});
                        }

                        const callExpr = try self.parseCallExpression(ident);
                        try self.consumeNewLineOrEnd();

                        const stmt = try self.pushNode(.comptimeStmt, start);
                        self.ast.setNodeData(stmt, .{ .comptimeStmt = .{
                            .expr = callExpr,
                        }});
                        return stmt;
                    }
                } else {
                    return self.reportError("Expected ident after #.", &.{});
                }
            },
            .template_k => {
                return self.parseTemplate();
            },
            .type_k => {
                return try self.parseTypeDecl(cy.NullNode, true);
            },
            .func_k => {
                return try self.parseFuncDecl(cy.NullNode);
            },
            .if_k => {
                return try self.parseIfStatement();
            },
            .try_k => {
                if (self.peekAhead(1).tag() == .colon) {
                    return try self.parseTryStmt();
                }
            },
            .switch_k => {
                return try self.parseSwitch(true);
            },
            .for_k => {
                return try self.parseForStatement();
            },
            .while_k => {
                return try self.parseWhileStatement();
            },
            .import_k => {
                return try self.parseImportStmt();
            },
            .pass_k => {
                const id = try self.pushNode(.passStmt, self.next_pos);
                self.advance();
                token = self.peek();
                try self.consumeNewLineOrEnd();
                return id;
            },
            .continue_k => {
                const id = try self.pushNode(.continueStmt, self.next_pos);
                self.advance();
                try self.consumeNewLineOrEnd();
                return id;
            },
            .break_k => {
                const id = try self.pushNode(.breakStmt, self.next_pos);
                self.advance();
                try self.consumeNewLineOrEnd();
                return id;
            },
            .return_k => {
                return try self.parseReturnStatement();
            },
            .var_k => {
                return try self.parseVarDecl(cy.NullNode, true);
            },
            .my_k => {
                return try self.parseMyDecl(cy.NullNode);
            },
            else => {},
        }
        if (try self.parseExprOrAssignStatement()) |id| {
            return id;
        }
        return self.reportErrorAtSrc("Unknown token: {}", &.{v(token.tag())}, token.pos());
    }

    fn reportError(self: *Parser, format: []const u8, args: []const fmt.FmtValue) anyerror {
        return self.reportErrorAt(format, args, self.next_pos);
    }

    fn reportErrorAt(self: *Parser, format: []const u8, args: []const fmt.FmtValue, tokenPos: u32) anyerror {
        var srcPos: u32 = undefined;
        if (tokenPos >= self.tokens.len) {
            srcPos = @intCast(self.ast.src.len);
        } else {
            srcPos = self.tokens[tokenPos].pos();
        }
        return self.reportErrorAtSrc(format, args, srcPos);
    }

    fn reportErrorAtSrc(self: *Parser, format: []const u8, args: []const fmt.FmtValue, srcPos: u32) anyerror {
        self.has_error = true;
        return self.reportFn(self.ctx, format, args, srcPos);
    }

    fn consumeNewLineOrEnd(self: *Parser) !void {
        var tag = self.peek().tag();
        if (tag == .new_line) {
            self.advance();
            return;
        }
        if (tag == .null) {
            return;
        }
        return self.reportError("Expected end of line or file. Got {}.", &.{v(tag)});
    }

    fn consumeWhitespaceTokens(self: *Parser) void {
        var token = self.peek();
        while (token.tag() != .null) {
            switch (token.tag()) {
                .new_line,
                .indent => {
                    self.advance();
                    token = self.peek();
                    continue;
                },
                else => return,
            }
        }
    }

    fn parseSeqDestructure(self: *Parser) !NodeId {
        const start = self.next_pos;
        // Assume first token is left bracket.
        self.advance();

        var lastEntry: NodeId = undefined;
        var firstEntry: NodeId = cy.NullNode;
        var numArgs: u32 = 0;
        outer: {
            self.consumeWhitespaceTokens();
            var token = self.peek();

            if (token.tag() == .right_bracket) {
                // Empty.
                return self.reportError("Expected at least one identifier.", &.{});
            } else {
                firstEntry = (try self.parseExpr(.{})) orelse {
                    return self.reportError("Expected array item.", &.{});
                };
                if (self.ast.nodeType(firstEntry) != .ident) {
                    return self.reportError("Expected ident.", &.{});
                }
                lastEntry = firstEntry;
                numArgs += 1;
            }

            while (true) {
                self.consumeWhitespaceTokens();
                token = self.peek();
                if (token.tag() == .comma) {
                    self.advance();
                    if (self.peek().tag() == .new_line) {
                        self.advance();
                        self.consumeWhitespaceTokens();
                    }
                } else if (token.tag() == .right_bracket) {
                    break :outer;
                }

                token = self.peek();
                if (token.tag() == .right_bracket) {
                    break :outer;
                } else {
                    const ident = (try self.parseExpr(.{})) orelse {
                        return self.reportError("Expected array item.", &.{});
                    };
                    if (self.ast.nodeType(ident) != .ident) {
                        return self.reportError("Expected ident.", &.{});
                    }
                    self.ast.setNextNode(lastEntry, ident);
                    lastEntry = ident;
                    numArgs += 1;
                }
            }
        }

        const seqDestr = try self.pushNode(.seqDestructure, start);
        self.ast.setNodeData(seqDestr, .{ .seqDestructure = .{
            .head = firstEntry,
            .numArgs = @intCast(numArgs),
        }});

        // Parse closing bracket.
        const token = self.peek();
        if (token.tag() == .right_bracket) {
            self.advance();
            return seqDestr;
        } else return self.reportError("Expected closing bracket.", &.{});
    }

    fn parseBracketLiteral(self: *Parser) !NodeId {
        const start = self.next_pos;
        // Assume first token is left bracket.
        self.advance();

        // Check for empty map literal.
        if (self.peek().tag() == .colon) {
            self.advance();
            if (self.peek().tag() != .right_bracket) {
                return self.reportError("Expected closing bracket.", &.{});
            }

            self.advance();
            const record = try self.pushNode(.recordLit, start);
            self.ast.setNodeData(record, .{ .recordLit = .{
                .argHead = cy.NullNode,
                .argTail = cy.NullNode,
                .numArgs = 0,
            }});
            return record;
        } else if (self.peek().tag() == .right_bracket) {
            self.advance();
            const array = try self.pushNode(.arrayLit, start);
            self.ast.setNodeData(array, .{ .arrayLit = .{
                .argHead = cy.NullNode,
                .numArgs = 0,
            }});
            return array;
        }

        // Assume there is at least one argument.

        // If `typeName` is set, then this is a object initializer.
        var typeName: NodeId = cy.NullNode;

        self.consumeWhitespaceTokens();

        const res = try self.parseEmptyTypeInitOrBracketArg();
        if (res.isEmptyTypeInit) {
            // Empty object init. Can assume arg is the type name.
            const dataLit = try self.pushNode(.recordLit, start);
            self.ast.setNodeData(dataLit, .{ .recordLit = .{
                .argHead = cy.NullNode,
                .argTail = cy.NullNode,
                .numArgs = 0,
            }});

            const initN = try self.pushNode(.objectInit, start);
            self.ast.setNodeData(initN, .{ .objectInit = .{
                .name = res.res,
                .initializer = dataLit,
            }});

            return initN;
        }

        var arg = res.res;
        var isRecordArg = res.isRecordArg;

        self.consumeWhitespaceTokens();
        var token = self.peek();
        if (token.tag() == .right_bracket) {
            // One arg literal.
            self.advance();
            if (isRecordArg) {
                const record = try self.pushNode(.recordLit, start);
                self.ast.setNodeData(record, .{ .recordLit = .{
                    .argHead = arg,
                    .argTail = @intCast(arg),
                    .numArgs = 1,
                }});
                return record;
            } else {
                const array = try self.pushNode(.arrayLit, start);
                self.ast.setNodeData(array, .{ .arrayLit = .{
                    .argHead = arg,
                    .numArgs = 1,
                }});
                return array;
            }
        } else if (token.tag() == .comma) {
            // Continue.
        } else {
            if (!isRecordArg) {
                // Assume object initializer. `arg` becomes typename. Parse arg again.
                typeName = arg;
                arg = try self.parseBracketArg(&isRecordArg) orelse return error.Unexpected;
            } else {
                return self.reportError("Expected comma or closing bracket.", &.{});
            }
        }

        const first = arg;
        var last: NodeId = first;
        var numArgs: u32 = 1;
        var isRecord: bool = isRecordArg;

        while (true) {
            self.consumeWhitespaceTokens();
            token = self.peek();
            if (token.tag() == .comma) {
                self.advance();
                if (self.peek().tag() == .new_line) {
                    self.advance();
                    self.consumeWhitespaceTokens();
                }
            } else if (token.tag() == .right_bracket) {
                break;
            } else {
                return self.reportErrorAt("Expected comma or closing bracket.", &.{}, self.next_pos);
            }

            if (try self.parseBracketArg(&isRecordArg)) |entry| {
                // Check that arg kind is the same.
                if (isRecord != isRecordArg) {
                    const argStart = self.ast.nodePos(entry);
                    if (isRecord) {
                        return self.reportErrorAtSrc("Expected key/value pair.", &.{}, argStart);
                    } else {
                        return self.reportErrorAtSrc("Expected data element.", &.{}, argStart);
                    }
                }
                self.ast.setNextNode(last, entry);
                last = entry;
                numArgs += 1;
            } else {
                break;
            }
        }

        // Parse closing bracket.
        if (self.peek().tag() != .right_bracket) {
            return self.reportError("Expected closing bracket.", &.{});
        }
        self.advance();

        if (typeName == cy.NullNode) {
            if (isRecord) {
                const record = try self.pushNode(.recordLit, start);
                self.ast.setNodeData(record, .{ .recordLit = .{
                    .argHead = first,
                    .argTail = @intCast(last),
                    .numArgs = @intCast(numArgs),
                }});
                return record;
            } else {
                const array = try self.pushNode(.arrayLit, start);
                self.ast.setNodeData(array, .{ .arrayLit = .{
                    .argHead = first,
                    .numArgs = @intCast(numArgs),
                }});
                return array;
            }
        } else {
            if (!isRecord) {
                return self.reportError("Expected map literal for object initializer.", &.{});
            }

            const record = try self.pushNode(.recordLit, start);
            self.ast.setNodeData(record, .{ .recordLit = .{
                .argHead = first,
                .argTail = @intCast(last),
                .numArgs = @intCast(numArgs),
            }});

            const initN = try self.pushNode(.objectInit, start);
            self.ast.setNodeData(initN, .{ .objectInit = .{
                .name = typeName,
                .initializer = record,
            }});
            return initN;
        }
    }

    const EmptyTypeInitOrBracketArg = struct {
        res: cy.NodeId,
        isEmptyTypeInit: bool,
        isRecordArg: bool,
    };

    fn parseEmptyTypeInitOrBracketArg(self: *Parser) !EmptyTypeInitOrBracketArg {
        const start = self.next_pos;

        const arg = (try self.parseExpr(.{ .parseShorthandCallExpr = false })) orelse {
            return self.reportError("Expected data argument.", &.{});
        };

        self.consumeWhitespaceTokens();

        if (self.peek().tag() != .colon) {
            return EmptyTypeInitOrBracketArg{
                .res = arg,
                .isEmptyTypeInit = false,
                .isRecordArg = false,
            };
        }
        self.advance();

        self.consumeWhitespaceTokens();
        if (self.peek().tag() == .right_bracket) {
            self.advance();
            return EmptyTypeInitOrBracketArg{
                .res = arg,
                .isEmptyTypeInit = true,
                .isRecordArg = true,
            };
        }

        // Parse key value pair.
        const arg_t = self.ast.nodeType(arg);
        if (!isRecordKeyNodeType(arg_t)) {
            return self.reportError("Expected map key.", &.{});
        }

        const val = (try self.parseExpr(.{})) orelse {
            return self.reportError("Expected map value.", &.{});
        };
        const pair = try self.pushNode(.keyValue, start);
        self.ast.setNodeData(pair, .{ .keyValue = .{
            .key = arg,
            .value = val,
        }});
        return EmptyTypeInitOrBracketArg{
            .res = pair,
            .isEmptyTypeInit = false,
            .isRecordArg = true,
        };
    }

    fn parseBracketArg(self: *Parser, outIsPair: *bool) !?NodeId {
        const start = self.next_pos;

        if (self.peek().tag() == .right_bracket) {
            return null;
        }

        const arg = (try self.parseTightTermExpr()) orelse {
            return self.reportError("Expected data argument.", &.{});
        };

        if (self.peek().tag() != .colon) {
            outIsPair.* = false;
            return arg;
        }
        self.advance();

        // Parse key value pair.
        const arg_t = self.ast.nodeType(arg);
        if (!isRecordKeyNodeType(arg_t)) {
            return self.reportError("Expected map key.", &.{});
        }

        const val = (try self.parseExpr(.{})) orelse {
            return self.reportError("Expected map value.", &.{});
        };
        const pair = try self.pushNode(.keyValue, start);
        self.ast.setNodeData(pair, .{ .keyValue = .{
            .key = arg,
            .value = val,
        }});
        outIsPair.* = true;
        return pair;
    }

    fn parseCallArg(self: *Parser) !?NodeId {
        self.consumeWhitespaceTokens();
        const start = self.next_pos;
        const token = self.peek();
        if (token.tag() == .ident) {
            if (self.peekAhead(1).tag() == .colon) {
                // Named arg.
                const name = try self.pushSpanNode(.ident, start);
                _ = self.consume();
                _ = self.consume();
                var arg = (try self.parseExpr(.{})) orelse {
                    return self.reportError("Expected arg expression.", &.{});
                };
                const namedArg = try self.pushNode(.namedArg, start);
                self.ast.setNodeData(namedArg, .{ .namedArg = .{
                    .name = name,
                    .arg = arg,
                }});
                return namedArg;
            } 
        }

        return try self.parseExpr(.{});
    }

    fn parseAnyCallExpr(self: *Parser, callee: NodeId) !NodeId {
        const token = self.peek();
        if (token.tag() == .left_paren) {
            return try self.parseCallExpression(callee);
        } else {
            return try self.parseNoParenCallExpression(callee);
        }
    }

    fn parseCallArgs(self: *Parser, hasNamedArg: *bool) !ListResult {
        // Assume first token is left paren.
        self.advance();

        var has_named_arg = false;
        var numArgs: u32 = 0;
        var first: NodeId = cy.NullNode;
        inner: {
            first = (try self.parseCallArg()) orelse {
                break :inner;
            };
            numArgs += 1;
            if (self.ast.nodeType(first) == .namedArg) {
                has_named_arg = true;
            }
            var last_arg_id = first;
            while (true) {
                const token = self.peek();
                if (token.tag() != .comma and token.tag() != .new_line) {
                    break;
                }
                self.advance();
                const arg_id = (try self.parseCallArg()) orelse {
                    break;
                };
                numArgs += 1;
                self.ast.setNextNode(last_arg_id, arg_id);
                last_arg_id = arg_id;
                if (self.ast.nodeType(last_arg_id) == .namedArg) {
                    has_named_arg = true;
                }
            }
        }

        hasNamedArg.* = has_named_arg;

        self.consumeWhitespaceTokens();
        if (self.peek().tag() != .right_paren) {
            return self.reportError("Expected closing parenthesis.", &.{});
        }
        self.advance();

        return ListResult{
            .head = first,
            .len = numArgs,
        };
    }

    fn parseCallExpression(self: *Parser, left_id: NodeId) !NodeId {
        const expr_start = self.ast.nodePos(left_id);
        const callExpr = try self.ast.pushNode(self.alloc, .callExpr, expr_start);

        var hasNamedArg: bool = undefined;
        const res = try self.parseCallArgs(&hasNamedArg);

        self.ast.setNodeData(callExpr, .{ .callExpr = .{
            .callee = @intCast(left_id),
            .argHead = @intCast(res.head),
            .hasNamedArg = hasNamedArg,
            .numArgs = @intCast(res.len),
        }});
        return callExpr;
    }

    /// Assumes first arg exists.
    fn parseNoParenCallExpression(self: *Parser, left_id: NodeId) !NodeId {
        const expr_start = self.ast.nodePos(left_id);
        const callExpr = try self.ast.pushNode(self.alloc, .callExpr, expr_start);

        const firstArg = (try self.parseExpr(.{})) orelse {
            return self.reportError("Expected call arg.", &.{});
        };
        var numArgs: u32 = 1;
        var last_arg_id = firstArg;

        while (true) {
            const token = self.peek();
            switch (token.tag()) {
                .right_bracket,
                .right_paren,
                .new_line,
                .null => break,
                .comma => {
                    self.advance();
                    const arg = (try self.parseExpr(.{})) orelse {
                        return self.reportError("Expected call arg.", &.{});
                    };
                    self.ast.setNextNode(last_arg_id, arg);
                    last_arg_id = arg;
                    numArgs += 1;
                },
                else => {
                    return self.reportError("Expected comma.", &.{});
                },
            }
        }

        self.ast.setNodeData(callExpr, .{ .callExpr = .{
            .callee = @intCast(left_id),
            .argHead = @intCast(firstArg),
            .hasNamedArg = false,
            .numArgs = @intCast(numArgs),
        }});
        return callExpr;
    }

    /// Parses the right expression of a BinaryExpression.
    fn parseRightExpr(self: *Parser, left_op: cy.ast.BinaryExprOp) anyerror!NodeId {
        var start = self.next_pos;
        var token = self.peek();

        switch (token.tag()) {
            .null => {
                return self.reportError("Expected right operand.", &.{});
            },
            .indent,
            .new_line => {
                self.advance();
                self.consumeWhitespaceTokens();
                start = self.next_pos;
                token = self.peek();
                if (token.tag() == .null) {
                    return self.reportError("Expected right operand.", &.{});
                }
            },
            else => {},
        }

        const expr_id = try self.parseTermExpr();
        return self.parseRightExpr2(left_op, expr_id);
    }

    fn parseRightExpr2(self: *Parser, left_op: cy.ast.BinaryExprOp, right_id: cy.NodeId) anyerror!NodeId {
        // Check if next token is an operator with higher precedence.
        var token = self.peek();

        var rightOp: cy.ast.BinaryExprOp = undefined;
        switch (token.tag()) {
            .operator => rightOp = toBinExprOp(token.data.operator_t),
            .and_k => rightOp = .and_op,
            .or_k => rightOp = .or_op,
            else => return right_id,
        }

        const op_prec = getBinOpPrecedence(left_op);
        const right_op_prec = getBinOpPrecedence(rightOp);
        if (right_op_prec > op_prec) {
            // Continue parsing right.
            _ = self.consume();
            var start = self.next_pos;
            const next_right = try self.parseRightExpr(rightOp);

            const binExpr = try self.pushNode(.binExpr, start);
            self.ast.setNodeData(binExpr, .{ .binExpr = .{
                .left = right_id,
                .right = @intCast(next_right),
                .op = rightOp,
            }});

            // Before returning the expr, perform left recursion if the op prec greater than the starting op.
            // eg. a + b * c * d
            //         ^ parseRightExpr starts here
            // Returns ((b * c) * d).
            // eg. a < b * c - d
            //         ^ parseRightExpr starts here
            // Returns ((b * c) - d).
            var left = binExpr;
            while (true) {
                token = self.peek();

                var rightOp2: cy.ast.BinaryExprOp = undefined;
                switch (token.tag()) {
                    .operator => rightOp2 = toBinExprOp(token.data.operator_t),
                    .and_k => rightOp2 = .and_op,
                    .or_k => rightOp2 = .or_op,
                    else => return left,
                }
                const right2_op_prec = getBinOpPrecedence(rightOp2);
                if (right2_op_prec > op_prec) {
                    self.advance();
                    const rightExpr = try self.parseRightExpr(rightOp);
                    const newBinExpr = try self.pushNode(.binExpr, start);
                    self.ast.setNodeData(newBinExpr, .{ .binExpr = .{
                        .left = left,
                        .right = @intCast(rightExpr),
                        .op = rightOp2,
                    }});
                    left = newBinExpr;
                    continue;
                } else {
                    return left;
                }
            }
        }
        return right_id;
    }

    fn isVarDeclaredFromScope(self: *Parser, name: []const u8) bool {
        var i = self.blockStack.items.len;
        while (i > 0) {
            i -= 1;
            if (self.blockStack.items[i].vars.contains(name)) {
                return true;
            }
        }
        return false;
    }

    // Assume at `if` token.
    fn parseIfExpr(self: *Parser, start: u32) !NodeId {
        self.advance();
        if (self.peek().tag() != .left_paren) {
            return self.reportError("Expected `(` for `if` expression.", &.{});
        }
        self.advance();
        const cond = (try self.parseExpr(.{})) orelse {
            return self.reportError("Expected condition for `if` expression.", &.{});
        };
        if (self.peek().tag() != .right_paren) {
            return self.reportError("Expected `)` for `if` expression.", &.{});
        }
        self.advance();

        const res = try self.pushNode(.if_expr, start);

        const body = (try self.parseExpr(.{})) orelse {
            return self.reportError("Expected conditional true expression.", &.{});
        };

        const ifBranch = try self.pushNode(.if_branch, start);
        self.ast.setNodeData(ifBranch, .{ .if_branch = .{
            .cond = cond,
            .body_head = body,
        }});

        self.ast.setNodeData(res, .{ .if_expr = .{
            .if_branch = ifBranch,
            .else_expr = cy.NullNode,
        }});

        const token = self.peek();
        if (token.tag() != .else_k) {
            return self.reportError("Expected else body.", &.{});
        }
        self.advance();

        const elseExpr = (try self.parseExpr(.{})) orelse {
            return self.reportError("Expected else body.", &.{});
        };
        self.ast.nodePtr(res).data.if_expr.else_expr = elseExpr;
        return res;
    }

    /// A string template begins and ends with .templateString token.
    /// Inside the template, two template expressions can be adjacent to each other.
    fn parseStringTemplate(self: *Parser) !NodeId {
        const start = self.next_pos;

        const id = try self.pushNode(.stringTemplate, start);

        var firstString: NodeId = undefined;
        var token = self.peek();
        if (token.tag() == .templateString) {
            firstString = try self.pushSpanNode(.stringLit, start);
        } else return self.reportError("Expected template string or expression.", &.{});

        var lastWasStringPart = true;
        var lastString = firstString;
        var firstExpr: NodeId = cy.NullNode;
        var lastExpr: NodeId = cy.NullNode;

        self.advance();
        token = self.peek();

        var numExprs: u32 = 0;
        while (true) {
            const tag = token.tag();
            if (tag == .templateString) {
                if (lastWasStringPart) {
                    // End of this template.
                    break;
                }
                const str = try self.pushSpanNode(.stringLit, self.next_pos);
                self.ast.setNextNode(lastString, str);
                lastString = str;
                lastWasStringPart = true;
            } else if (tag == .templateExprStart) {
                self.advance();
                const expr = (try self.parseExpr(.{})) orelse {
                    return self.reportError("Expected expression.", &.{});
                };
                token = self.peek();
                if (token.tag() != .right_paren) {
                    return self.reportError("Expected right paren.", &.{});
                }
                if (firstExpr == cy.NullNode) {
                    firstExpr = expr;
                } else {
                    self.ast.setNextNode(lastExpr, expr);
                }
                lastExpr = expr;
                lastWasStringPart = false;
                numExprs += 1;
            } else {
                break;
            }
            self.advance();
            token = self.peek();
        }

        self.ast.setNodeData(id, .{ .stringTemplate = .{
            .strHead = @intCast(firstString),
            .exprHead = firstExpr,
            .numExprs = @intCast(numExprs),
        }});
        return id;
    }

    fn parseTermExpr(self: *Parser) anyerror!NodeId {
        return (try self.parseTermExprOpt()) orelse {
            return self.reportError("Expected term expr. Got: {}.", &.{v(self.peek().tag())});
        };
    }

    /// An expression term doesn't contain a binary expression at the top.
    fn parseTermExprOpt(self: *Parser) anyerror!?NodeId {
        const start = self.next_pos;
        var token = self.peek();
        switch (token.tag()) {
            // .await_k => {
            //     // Await expression.
            //     const expr_id = try self.pushNode(.await_expr, start);
            //     self.advance();
            //     const term_id = try self.parseTermExpr();
            //     self.nodes.items[expr_id].head = .{
            //         .child_head = term_id,
            //     };
            //     return expr_id;
            // },
            .not_k => {
                self.advance();
                const expr = try self.pushNode(.unary_expr, start);
                const child = try self.parseTermExpr();
                self.ast.setNodeData(expr, .{ .unary = .{
                    .child = child,
                    .op = .not,
                }});
                return expr;
            },
            .throw_k => {
                self.advance();
                const child = try self.parseTermExpr();
                const expr = try self.pushNode(.throwExpr, start);
                self.ast.setNodeData(expr, .{ .throwExpr = .{
                    .child = child,
                }});
                return expr;
            },
            .try_k => {
                self.advance();
                const tryExpr = try self.pushNode(.tryExpr, start);
                const expr = try self.parseTermExpr();

                token = self.peek();
                var catchExpr: cy.NodeId = cy.NullNode;
                if (token.tag() == .catch_k) {
                    self.advance();
                    catchExpr = try self.parseTermExpr();
                }

                self.ast.setNodeData(tryExpr, .{ .tryExpr = .{
                    .expr = expr,
                    .catchExpr = catchExpr,
                }});
                return tryExpr;
            },
            .if_k => {
                return try self.parseIfExpr(start);
            },
            .coresume_k => {
                self.advance();
                const coresume = try self.pushNode(.coresume, start);
                const fiberExpr = try self.parseTermExpr();
                self.ast.setNodeData(coresume, .{ .coresume = .{
                    .child = fiberExpr,
                }});
                return coresume;
            },
            .coyield_k => {
                self.advance();
                const coyield = try self.pushNode(.coyield, start);
                return coyield;
            },
            .coinit_k => {
                self.advance();

                if (self.peek().tag() != .left_paren) {
                    return self.reportError("Expected ( after coinit.", &.{});
                }
                self.advance();

                const callee = (try self.parseCallArg()) orelse {
                    return self.reportError("Expected entry function callee.", &.{});
                };

                var numArgs: u32 = 0;
                var first: NodeId = cy.NullNode;
                if (self.peek().tag() == .comma) {
                    self.advance();
                    inner: {
                        first = (try self.parseCallArg()) orelse {
                            break :inner;
                        };
                        numArgs += 1;
                        var last = first;
                        while (true) {
                            self.consumeWhitespaceTokens();

                            if (self.peek().tag() != .comma) {
                                break;
                            }
                            self.advance();
                            const arg = (try self.parseCallArg()) orelse {
                                break;
                            };
                            numArgs += 1;
                            self.ast.setNextNode(last, arg);
                            last = arg;
                        }
                    }
                }

                self.consumeWhitespaceTokens();
                token = self.peek();
                if (token.tag() != .right_paren) {
                    return self.reportError("Expected closing `)`.", &.{});
                }
                self.advance();

                const callExpr = try self.pushNode(.callExpr, start);
                self.ast.setNodeData(callExpr, .{ .callExpr = .{
                    .callee = @intCast(callee),
                    .argHead = @intCast(first),
                    .hasNamedArg = false,
                    .numArgs = @intCast(numArgs),
                }});

                const coinit = try self.pushNode(.coinit, start);
                self.ast.setNodeData(coinit, .{ .coinit = .{
                    .child = callExpr,
                }});
                return coinit;
            },
            .minusDotDot => {
                // Start omitted.
                self.advance();
                const end = (try self.parseExpr(.{})) orelse {
                    return self.reportError("Expected range end.", &.{});
                };

                const range = try self.pushNode(.range, start);
                self.ast.setNodeData(range, .{ .range = .{
                    .start = cy.NullNode,
                    .end = @intCast(end),
                    .inc = false,
                }});
                return range;
            },
            .dot_dot => {
                // Start omitted.
                self.advance();
                const end = (try self.parseExpr(.{})) orelse {
                    return self.reportError("Expected range end.", &.{});
                };

                const range = try self.pushNode(.range, start);
                self.ast.setNodeData(range, .{ .range = .{
                    .start = cy.NullNode,
                    .end = @intCast(end),
                    .inc = true,
                }});
                return range;
            },
            else => {},
        }
        return self.parseTightTermExpr();
    }

    /// A tight term expr also doesn't include various top expressions
    /// that are separated by whitespace. eg. coinit <expr>
    fn parseTightTermExpr(self: *Parser) anyerror!?NodeId {
        var start = self.next_pos;
        var token = self.peek();
        var left_id = switch (token.tag()) {
            .ident => b: {
                self.advance();
                const id = try self.pushSpanNode(.ident, start);

                const name_token = self.tokens[start];
                const name = self.ast.src[name_token.pos()..name_token.data.end_pos];
                if (!self.isVarDeclaredFromScope(name)) {
                    try self.deps.put(self.alloc, name, id);
                }

                break :b id;
            },
            .type_k => b: {
                self.advance();
                const id = try self.pushSpanNode(.ident, start);
                break :b id;
            },
            .struct_k => b: {
                self.advance();
                const id = try self.pushSpanNode(.ident, start);
                break :b id;
            },
            .error_k => b: {
                self.advance();
                token = self.peek();
                if (token.tag() == .dot) {
                    // Error symbol literal.
                    self.advance();
                    token = self.peek();
                    if (token.tag() == .ident) {
                        const symbol = try self.pushSpanNode(.ident, self.next_pos);
                        self.advance();
                        const id = try self.pushNode(.errorSymLit, start);
                        self.ast.setNodeData(id, .{ .errorSymLit = .{
                            .symbol = symbol,
                        }});
                        break :b id;
                    } else {
                        return self.reportError("Expected symbol identifier.", &.{});
                    }
                } else {
                    // Becomes an ident.
                    const id = try self.pushSpanNode(.ident, start);
                    break :b id;
                }
            },
            .question => {
                self.advance();
                const param = try self.parseTermExpr();
                const id = try self.pushNode(.expandOpt, start);
                self.ast.setNodeData(id, .{ .expandOpt = .{
                    .param = param,
                }});
                return id;
            },
            .dot => {
                self.advance();
                const name = (try self.parseOptName()) orelse {
                    return self.reportError("Expected symbol identifier.", &.{});
                };
                self.ast.nodePtr(name).head.type = .symbolLit;
                return name;
            },
            .true_k => {
                self.advance();
                return try self.pushNode(.trueLit, start);
            },
            .false_k => {
                self.advance();
                return try self.pushNode(.falseLit, start);
            },
            .none_k => {
                self.advance();
                return try self.pushNode(.noneLit, start);
            },
            .void_k => {
                self.advance();
                return try self.pushNode(.void, start);
            },
            .dec => b: {
                self.advance();
                break :b try self.pushSpanNode(.decLit, start);
            },
            .float => b: {
                self.advance();
                break :b try self.pushSpanNode(.floatLit, start);
            },
            .bin => b: {
                self.advance();
                break :b try self.pushSpanNode(.binLit, start);
            },
            .oct => b: {
                self.advance();
                break :b try self.pushSpanNode(.octLit, start);
            },
            .hex => b: {
                self.advance();
                break :b try self.pushSpanNode(.hexLit, start);
            },
            .rune => b: {
                self.advance();
                break :b try self.pushSpanNode(.runeLit, start);
            },
            .raw_string => b: {
                self.advance();
                break :b try self.pushSpanNode(.raw_string_lit, start);
            },
            .string => b: {
                self.advance();
                break :b try self.pushSpanNode(.stringLit, start);
            },
            .templateString => b: {
                break :b try self.parseStringTemplate();
            },
            .pound => b: {
                break :b try self.parseComptimeExpr();
            },
            .left_paren => b: {
                _ = self.consume();
                token = self.peek();

                const expr_id = (try self.parseExpr(.{})) orelse {
                    token = self.peek();
                    if (token.tag() == .right_paren) {
                        _ = self.consume();
                    } else {
                        return self.reportError("Expected expression.", &.{});
                    }
                    // Assume empty args for lambda.
                    token = self.peek();
                    if (token.tag() == .equal_greater) {
                        return try self.parseNoParamLambdaFunc();
                    } else {
                        return self.reportError("Unexpected paren.", &.{});
                    }
                };
                token = self.peek();
                if (token.tag() == .right_paren) {
                    _ = self.consume();

                    token = self.peek();
                    if (self.ast.nodeType(expr_id) == .ident and token.tag() == .equal_greater) {
                        return try self.parseLambdaFuncWithParam(expr_id);
                    }

                    const group = try self.pushNode(.group, start);
                    self.ast.setNodeData(group, .{ .group = .{
                        .child = expr_id,
                    }});
                    break :b group;
                } else if (token.tag() == .comma) {
                    self.next_pos = start;
                    return try self.parseLambdaFunction();
                } else {
                    return self.reportError("Expected right parenthesis.", &.{});
                }
            },
            .left_bracket => b: {
                const lit = try self.parseBracketLiteral();
                break :b lit;
            },
            .operator => {
                if (token.data.operator_t == .minus) {
                    self.advance();
                    const expr_id = try self.pushNode(.unary_expr, start);
                    const term_id = try self.parseTermExpr();
                    self.ast.setNodeData(expr_id, .{ .unary = .{
                        .child = term_id,
                        .op = .minus,
                    }});
                    return expr_id;
                } else if (token.data.operator_t == .tilde) {
                    self.advance();
                    const expr_id = try self.pushNode(.unary_expr, start);
                    const term_id = try self.parseTermExpr();
                    self.ast.setNodeData(expr_id, .{ .unary = .{
                        .child = term_id,
                        .op = .bitwiseNot,
                    }});
                    return expr_id;
                } else if (token.data.operator_t == .bang) {
                    self.advance();
                    const expr = try self.pushNode(.unary_expr, start);
                    const child = try self.parseTermExpr();
                    self.ast.setNodeData(expr, .{ .unary = .{
                        .child = child,
                        .op = .not,
                    }});
                    return expr;
                } else return self.reportError("Unexpected operator.", &.{});
            },
            else => {
                return null;
            }
        };

        while (true) {
            const next = self.peek();
            switch (next.tag()) {
                .dot => {
                    // Access expr.
                    self.advance();

                    const right = (try self.parseOptName()) orelse {
                        return self.reportError("Expected ident", &.{});
                    };

                    const expr_id = try self.pushNode(.accessExpr, start);
                    self.ast.setNodeData(expr_id, .{ .accessExpr = .{
                        .left = left_id,
                        .right = right,
                    }});
                    left_id = expr_id;
                },
                .dot_question => {
                    self.advance();
                    const expr = try self.pushNode(.unwrap, start);
                    self.ast.setNodeData(expr, .{ .unwrap = .{
                        .opt = left_id,
                    }});
                    left_id = expr;
                },
                .left_bracket => {
                    // Index expr.
                    self.advance();
                    const index = (try self.parseExpr(.{})) orelse {
                        return self.reportError("Expected index.", &.{});
                    };

                    if (self.peek().tag() != .right_bracket) {
                        return self.reportError("Expected right bracket.", &.{});                            
                    }
                    self.advance();

                    const expr = try self.pushNode(.indexExpr, start);
                    self.ast.setNodeData(expr, .{ .indexExpr = .{
                        .left = left_id,
                        .right = index,
                    }});
                    left_id = expr;
                },
                .left_paren => {
                    const call_id = try self.parseCallExpression(left_id);
                    left_id = call_id;
                },
                .minusDotDot,
                .dot_dot,
                .right_bracket,
                .right_paren,
                .right_brace,
                .else_k,
                .catch_k,
                .comma,
                .colon,
                .equal,
                .operator,
                .or_k,
                .and_k,
                .as_k,
                .capture,
                .raw_string,
                .string,
                .bin,
                .oct,
                .hex,
                .dec,
                .float,
                .if_k,
                .ident,
                .templateString,
                .equal_greater,
                .new_line,
                .null => break,
                else => break,
            }
        }
        return left_id;
    }

    fn returnLeftAssignExpr(self: *Parser, leftId: NodeId, outIsAssignStmt: *bool) !NodeId {
        switch (self.ast.nodeType(leftId)) {
            .accessExpr,
            .indexExpr,
            .ident => {
                outIsAssignStmt.* = true;
                return leftId;
            },
            else => {
                return self.reportError("Expected variable to left of assignment operator.", &.{});
            },
        }
    }

    fn parseBinExpr(self: *Parser, left: NodeId, op: cy.ast.BinaryExprOp) !NodeId {
        const opStart = self.next_pos;
        // Assumes current token is the operator.
        self.advance();

        const right = try self.parseRightExpr(op);
        const expr = try self.pushNode(.binExpr, opStart);
        self.ast.setNodeData(expr, .{ .binExpr = .{
            .left = left,
            .right = @intCast(right),
            .op = op,
        }});
        return expr;
    }

    fn parseComptimeExpr(self: *Parser) !NodeId {
        const start = self.next_pos;
        // Assumes current token is `#`.
        self.advance();

        const expr = try self.pushNode(.comptimeExpr, start);
        const child = (try self.parseExpr(.{})) orelse {
            return self.reportError("Expected expression.", &.{});
        };

        var patchIdx: u32 = cy.NullId;
        if (self.collectCtNodes) {
            patchIdx = self.ctNodePatchIdx;
            self.ctNodePatchIdx += 1;
            try self.ast.templateCtNodes.append(self.alloc, expr);
        }

        self.ast.setNodeData(expr, .{ .comptimeExpr = .{
            .child = child,
            .patchIdx = patchIdx,
        }});

        return expr;
    }

    /// An error can be returned during the expr parsing.
    /// If null is returned instead, no token begins an expression
    /// and the caller can assume next_pos did not change. Instead of reporting
    /// a generic error message, it delegates that to the caller.
    fn parseExpr(self: *Parser, opts: ParseExprOptions) anyerror!?NodeId {
        var start = self.next_pos;
        var token = self.peek();

        var left_id: NodeId = undefined;
        switch (token.tag()) {
            .null => return null,
            .right_paren => return null,
            .right_bracket => return null,
            .indent,
            .new_line => {
                self.advance();
                self.consumeWhitespaceTokens();
                start = self.next_pos;
                token = self.peek();
                if (token.tag() == .null) {
                    return null;
                }
            },
            else => {},
        }
        left_id = try self.parseTermExpr();

        while (true) {
            const next = self.peek();
            switch (next.tag()) {
                .equal_greater => {
                    if (self.ast.nodeType(left_id) == .ident) {
                        // Lambda.
                        return try self.parseLambdaFuncWithParam(left_id);
                    } else {
                        return self.reportError("Unexpected `=>` token", &.{});
                    }
                },
                .equal => {
                    // If left is an accessor expression or identifier, parse as assignment statement.
                    if (opts.returnLeftAssignExpr) {
                        return try self.returnLeftAssignExpr(left_id, opts.outIsAssignStmt);
                    } else {
                        break;
                    }
                },
                .operator => {
                    const op_t = next.data.operator_t;
                    switch (op_t) {
                        .plus,
                        .minus,
                        .star,
                        .slash => {
                            if (self.peekAhead(1).tag() == .equal) {
                                if (opts.returnLeftAssignExpr) {
                                    return try self.returnLeftAssignExpr(left_id, opts.outIsAssignStmt);
                                } else {
                                    break;
                                }
                            }
                        },
                        else => {},
                    }
                    const bin_op = toBinExprOp(op_t);
                    left_id = try self.parseBinExpr(left_id, bin_op);
                },
                .minusDotDot => {
                    self.advance();
                    const end: cy.NodeId = if (try self.parseTermExprOpt()) |right| b: {
                        break :b try self.parseRightExpr2(.reverse_range, right);
                    } else cy.NullNode;
                    const range = try self.pushNode(.range, start);
                    self.ast.setNodeData(range, .{ .range = .{
                        .start = left_id,
                        .end = @intCast(end),
                        .inc = false,
                    }});
                    left_id = range;
                },
                .dot_dot => {
                    self.advance();
                    const end: cy.NodeId = if (try self.parseTermExprOpt()) |right| b: {
                        break :b try self.parseRightExpr2(.range, right);
                    } else cy.NullNode;
                    const range = try self.pushNode(.range, start);
                    self.ast.setNodeData(range, .{ .range = .{
                        .start = left_id,
                        .end = @intCast(end),
                        .inc = true,
                    }});
                    left_id = range;
                },
                .as_k => {
                    const opStart = self.next_pos;
                    self.advance();

                    const typeSpec = (try self.parseOptTypeSpec(false)) orelse {
                        return self.reportError("Expected type specifier.", &.{});
                    };
                    const expr = try self.pushNode(.castExpr, opStart);
                    self.ast.setNodeData(expr, .{ .castExpr = .{
                        .expr = left_id,
                        .typeSpec = typeSpec,
                    }});
                    left_id = expr;
                },
                .and_k => {
                    left_id = try self.parseBinExpr(left_id, .and_op);
                },
                .or_k => {
                    left_id = try self.parseBinExpr(left_id, .or_op);
                },
                .question => {
                    self.advance();
                    if (self.peek().tag() != .else_k) {
                        return self.reportError("Expected `else`.", &.{});
                    }
                    self.advance();
                    const default = (try self.parseExpr(.{})) orelse {
                        return self.reportError("Expected default expression.", &.{});
                    };
                    const expr = try self.pushNode(.unwrap_or, start);
                    self.ast.setNodeData(expr, .{ .unwrap_or = .{
                        .opt = left_id,
                        .default = default,
                    }});
                    left_id = expr;
                },
                .right_bracket,
                .right_paren,
                .right_brace,
                .else_k,
                .comma,
                .colon,
                .capture,
                .new_line,
                .null => break,
                else => {
                    if (!opts.parseShorthandCallExpr) {
                        return left_id;
                    }
                    // Attempt to parse as no paren call expr.
                    switch (self.ast.nodeType(left_id)) {
                        .accessExpr,
                        .ident => {
                            return try self.parseNoParenCallExpression(left_id);
                        },
                        else => {
                            return left_id;
                        }
                    }
                }
            }
        }
        return left_id;
    }

    /// Consumes the an expression or a expression block.
    fn parseEndingExpr(self: *Parser) anyerror!cy.NodeId {
        switch (self.peek().tag()) {
            .func_k => {
                return self.parseLeftAssignLambdaFunction();
            },
            .switch_k => {
                return self.parseSwitch(false);
            },
            else => {
                return (try self.parseExpr(.{})) orelse {
                    return self.reportError("Expected expression.", &.{});
                };
            },
        }
    }

    fn parseMyDecl(self: *Parser, attr_head: cy.NodeId) !cy.NodeId {
        const start = self.next_pos;
        self.advance();

        const root = self.peek().tag() == .dot;
        if (root) {
            self.advance();
        }

        const name = (try self.parseOptNamePath()) orelse {
            return self.reportError("Expected local name identifier.", &.{});
        };

        if (self.peek().tag() == .left_paren) {
            self.advance();
            
            // Parse as untyped function.
            const params = try self.parseFuncParams();
            if (self.peek().tag() != .colon) {
                return self.reportError("Expected colon.", &.{});
            }
            self.advance();

            try self.pushBlock();
            const res = try self.parseSingleOrIndentedBodyStmts();
            _ = self.popBlock();

            const ret = cy.NullNode;
            const header = try self.ast.pushNode(self.alloc, .funcHeader, ret);
            self.ast.setNodeData(header, .{ .funcHeader = .{
                .name = name,
                .paramHead = params.head,
            }});
            self.ast.nodePtr(header).head.data = .{ .funcHeader = .{ .modHead = @intCast(attr_head) }};

            const id = try self.pushNode(.funcDecl, start);
            self.ast.setNodeData(id, .{ .func = .{
                .header = header,
                .bodyHead = @intCast(res.first),
                .sig_t = .my,
            }});

            if (!self.inTemplate) {
                try self.staticDecls.append(self.alloc, .{
                    .declT = if (self.inObjectDecl) .implicit_method else .func,
                    .nodeId = id,
                    .data = undefined,
                });
            }
            return id;
        }

        // Parse as dynamic var decl.
        const has_name_path = self.ast.node(name).next() != cy.NullNode;
        const is_static = has_name_path or root;
        return self.parseVarDecl2(start, name, cy.NullNode, attr_head, is_static, root, false);
    }

    fn parseVarDecl(self: *Parser, modifierHead: cy.NodeId, typed: bool) !cy.NodeId {
        const start = self.next_pos;
        self.advance();

        const root = self.peek().tag() == .dot;
        if (root) {
            self.advance();
        }

        // Var name.
        const name = (try self.parseOptNamePath()) orelse {
            return self.reportError("Expected local name identifier.", &.{});
        };
        const hasNamePath = self.ast.node(name).next() != cy.NullNode;
        const isStatic = hasNamePath or root;

        var typeSpec: cy.NodeId = cy.NullNode;
        if (typed) {
            typeSpec = (try self.parseOptTypeSpec(false)) orelse cy.NullNode;
        }

        return self.parseVarDecl2(start, name, typeSpec, modifierHead, isStatic, root, typed);
    }

    fn parseVarDecl2(self: *cy.Parser, start: u32, name: cy.NodeId, type_spec: cy.NodeId, attr_head: cy.NodeId, is_static: bool, root: bool, typed: bool) !cy.NodeId {
        const varSpec = try self.pushNode(.varSpec, start);
        self.ast.setNodeData(varSpec, .{ .varSpec = .{
            .name = name,
            .typeSpec = type_spec,
        }});
        self.ast.nodePtr(varSpec).head.data = .{ .varSpec = .{ .modHead = @intCast(attr_head) }};

        var decl: cy.NodeId = undefined;
        if (is_static) {
            decl = try self.pushNode(.staticDecl, start);
        } else {
            if (attr_head != cy.NullNode) {
                return self.reportErrorAt("Attributes are not allowed for local var declarations.", &.{}, start);
            }
            decl = try self.pushNode(.localDecl, start);
        }

        var right: cy.NodeId = cy.NullNode;
        inner: {
            var token = self.peek();
            if (token.tag() == .new_line or token.tag() == .null) {
                break :inner;
            }

            if (self.peek().tag() != .equal) {
                return self.reportError("Expected `=` after variable name.", &.{});
            }
            self.advance();

            // Continue parsing right expr.
            right = try self.parseEndingExpr();
        }

        if (is_static) {
            self.ast.setNodeData(decl, .{ .staticDecl = .{
                .varSpec = varSpec,
                .right = @intCast(right),
                .typed = typed,
                .root = root,
            }});
            try self.staticDecls.append(self.alloc, .{
                .declT = .variable,
                .nodeId = decl,
                .data = undefined,
            });
        } else {
            self.ast.setNodeData(decl, .{ .localDecl = .{
                .varSpec = varSpec,
                .right = @intCast(right),
                .typed = typed,
            }});
        }
        return decl;
    }

    /// Assumes next token is the return token.
    fn parseReturnStatement(self: *Parser) !NodeId {
        const start = self.next_pos;
        self.advance();
        const token = self.peek();
        switch (token.tag()) {
            .new_line,
            .null => {
                return try self.pushNode(.returnStmt, start);
            },
            else => {
                const right = try self.parseEndingExpr();

                const id = try self.pushNode(.returnExprStmt, start);
                self.ast.setNodeData(id, .{ .returnExprStmt = .{
                    .child = right,
                }});
                return id;
            },
        }
    }

    fn parseExprOrAssignStatement(self: *Parser) !?NodeId {
        var is_assign_stmt = false;
        const expr_id = (try self.parseExpr(.{
            .returnLeftAssignExpr = true,
            .outIsAssignStmt = &is_assign_stmt
        })) orelse {
            return null;
        };

        if (is_assign_stmt) {
            var token = self.peek();
            const opStart = self.next_pos;
            const assignTag = token.tag();
            // Assumes next token is an assignment operator: =, +=.
            self.advance();

            const start = self.ast.nodePos(expr_id);
            var assignStmt: NodeId = undefined;

            // Right can be an expr or stmt.
            var right: NodeId = undefined;
            switch (assignTag) {
                .equal => {
                    assignStmt = try self.ast.pushNode(self.alloc, .assignStmt, start);

                    right = try self.parseEndingExpr();
                    self.ast.setNodeData(assignStmt, .{ .assignStmt = .{
                        .left = expr_id,
                        .right = right,
                    }});
                },
                .operator => {
                    const op_t = token.data.operator_t;
                    switch (op_t) {
                        .plus,
                        .minus,
                        .star,
                        .slash => {
                            self.advance();
                            right = (try self.parseExpr(.{})) orelse {
                                return self.reportError("Expected right expression for assignment statement.", &.{});
                            };
                            assignStmt = try self.ast.pushNode(self.alloc, .opAssignStmt, start);
                            self.ast.setNodeData(assignStmt, .{ .opAssignStmt = .{
                                .left = expr_id,
                                .right = @intCast(right),
                                .op = toBinExprOp(op_t),
                            }});
                        },
                        else => fmt.panic("Unexpected operator assignment.", &.{}),
                    }
                },
                else => return self.reportErrorAt("Unsupported assignment operator.", &.{}, opStart),
            }

            const left = self.ast.nodePtr(expr_id);
            if (left.type() == .ident) {
                const name = self.ast.nodeString(left.*);
                const block = &self.blockStack.items[self.blockStack.items.len-1];
                if (self.deps.get(name)) |node_id| {
                    if (node_id == expr_id) {
                        // Remove dependency now that it's recognized as assign statement.
                        _ = self.deps.remove(name);
                    }
                }
                try block.vars.put(self.alloc, name, {});
            }

            if (self.ast.nodeType(right) != .lambda_multi) {
                token = self.peek();
                try self.consumeNewLineOrEnd();
                return assignStmt;
            } else {
                return assignStmt;
            }
        } else {
            const start = self.ast.nodePos(expr_id);
            const id = try self.ast.pushNode(self.alloc, .exprStmt, start);
            self.ast.setNodeData(id, .{ .exprStmt = .{
                .child = expr_id,
            }});

            const token = self.peek();
            if (token.tag() == .new_line) {
                self.advance();
                return id;
            } else if (token.tag() == .null) {
                return id;
            } else return self.reportError("Expected end of line or file", &.{});
        }
    }

    fn pushNode(self: *Parser, node_t: cy.NodeType, start: u32) !NodeId {
        return self.ast.pushNode(self.alloc, node_t, self.tokens[start].pos());
    }

    fn pushSpanNode(self: *Parser, node_t: cy.NodeType, start: u32) !NodeId {
        const token = self.tokens[start];
        return self.ast.pushSpanNode(self.alloc, node_t, token.pos(), token.data.end_pos);
    }

    /// When n=0, this is equivalent to peek.
    inline fn peekAhead(self: Parser, n: u32) Token {
        if (self.next_pos + n < self.tokens.len) {
            return self.tokens[self.next_pos + n];
        } else {
            return Token.init(.null, self.next_pos, .{
                .end_pos = cy.NullNode,
            });
        }
    }

    inline fn peek(self: Parser) Token {
        if (!self.isAtEnd()) {
            return self.tokens[self.next_pos];
        } else {
            return Token.init(.null, @intCast(self.ast.src.len), .{
                .end_pos = cy.NullNode,
            });
        }
    }

    inline fn advance(self: *Parser) void {
        self.next_pos += 1;
    }

    inline fn isAtEnd(self: Parser) bool {
        return self.tokens.len == self.next_pos;
    }

    inline fn consume(self: *Parser) Token {
        const token = self.tokens[self.next_pos];
        self.next_pos += 1;
        return token;
    }
};

pub const Result = struct {
    inner: ResultView,
    
    pub fn init(alloc: std.mem.Allocator, view: ResultView) !Result {
        const arr = try view.nodes.clone(alloc);
        const nodes = try alloc.create(std.ArrayListUnmanaged(cy.Node));
        nodes.* = arr;

        const new_src = try alloc.dupe(u8, view.src);

        const deps = try alloc.create(std.StringHashMapUnmanaged(NodeId));
        deps.* = .{};
        var iter = view.deps.iterator();
        while (iter.next()) |entry| {
            const dep = entry.key_ptr.*;
            const offset = @intFromPtr(dep.ptr) - @intFromPtr(view.src.ptr);
            try deps.put(alloc, new_src[offset..offset+dep.len], entry.value_ptr.*);
        }

        return Result{
            .inner = .{
                .has_error = view.has_error,
                .err_msg = try alloc.dupe(u8, view.err_msg),
                .root_id = view.root_id,
                .nodes = nodes,
                .src = new_src,
                .name = try alloc.dupe(u8, view.name),
                .deps = deps,
            },
        };
    }

    pub fn deinit(self: Result, alloc: std.mem.Allocator) void {
        alloc.free(self.inner.err_msg);
        self.inner.nodes.deinit(alloc);
        alloc.destroy(self.inner.nodes);
        alloc.free(self.inner.tokens);
        alloc.free(self.inner.src);
        self.inner.func_decls.deinit(alloc);
        alloc.destroy(self.inner.func_decls);
        alloc.free(self.inner.func_params);
        alloc.free(self.inner.name);
        self.inner.deps.deinit(alloc);
        alloc.destroy(self.inner.deps);
    }
};

/// Result data is not owned.
pub const ResultView = struct {
    root_id: NodeId,
    has_error: bool,

    ast: cy.ast.AstView,

    name: []const u8,
    deps: *std.StringHashMapUnmanaged(NodeId),

    pub fn dupe(self: ResultView, alloc: std.mem.Allocator) !Result {
        return try Result.init(alloc, self);
    }

    pub fn assertOnlyOneStmt(self: ResultView, node_id: NodeId) ?NodeId {
        var count: u32 = 0;
        var stmt_id: NodeId = undefined;
        var cur_id = node_id;
        while (cur_id != cy.NullNode) {
            const cur = self.nodes.items[cur_id];
            if (cur.node_t == .at_stmt and cur.head.at_stmt.skip_compile) {
                cur_id = cur.next;
                continue;
            }
            count += 1;
            stmt_id = cur_id;
            if (count > 1) {
                return null;
            }
            cur_id = cur.next;
        }
        if (count == 1) {
            return stmt_id;
        } else return null;
    }
};

fn toBinExprOp(op: cy.tokenizer.OperatorType) cy.ast.BinaryExprOp {
    return switch (op) {
        .plus => .plus,
        .minus => .minus,
        .star => .star,
        .caret => .caret,
        .slash => .slash,
        .percent => .percent,
        .ampersand => .bitwiseAnd,
        .verticalBar => .bitwiseOr,
        .doubleVerticalBar => .bitwiseXor,
        .lessLess => .bitwiseLeftShift,
        .greaterGreater => .bitwiseRightShift,
        .bang_equal => .bang_equal,
        .less => .less,
        .less_equal => .less_equal,
        .greater => .greater,
        .greater_equal => .greater_equal,
        .equal_equal => .equal_equal,
        .bang,
        .tilde => unreachable,
    };
}

pub fn getBinOpPrecedence(op: cy.ast.BinaryExprOp) u8 {
    switch (op) {
        .bitwiseLeftShift,
        .bitwiseRightShift => return 10,

        .bitwiseAnd => return 9,

        .bitwiseXor,
        .bitwiseOr => return 8,

        .caret => return 7,

        .slash,
        .percent,
        .star => {
            return 6;
        },

        .minus,
        .plus => {
            return 5;
        },

        .cast => return 4,

        .greater,
        .greater_equal,
        .less,
        .less_equal,
        .bang_equal,
        .equal_equal => {
            return 3;
        },

        .and_op => return 2,

        .or_op => return 1,

        .range,
        .reverse_range => return 0,

        else => return 0,
    }
}

pub fn getLastStmt(nodes: []const cy.Node, head: NodeId, out_prev: *NodeId) NodeId {
    var prev: NodeId = cy.NullNode;
    var cur_id = head;
    while (cur_id != cy.NullNode) {
        const node = nodes[cur_id];
        if (node.next == cy.NullNode) {
            out_prev.* = prev;
            return cur_id;
        }
        prev = cur_id;
        cur_id = node.next;
    }
    out_prev.* = cy.NullNode;
    return cy.NullNode;
}

test "Parse dependency variables" {
    var parser = try Parser.init(t.alloc);
    defer parser.deinit();

    var res = try parser.parseNoErr(
        \\foo
    , .{});
    try t.eq(res.deps.size, 1);
    try t.eq(res.deps.contains("foo"), true);

    // Assign statement.
    res = try parser.parseNoErr(
        \\foo = 123
        \\foo
    , .{});
    try t.eq(res.deps.size, 0);

    // Function call.
    res = try parser.parseNoErr(
        \\foo()
    , .{});
    try t.eq(res.deps.size, 1);
    try t.eq(res.deps.contains("foo"), true);

    // Function call after declaration.
    res = try parser.parseNoErr(
        \\func foo():
        \\  pass
        \\foo()
    , .{});
    try t.eq(res.deps.size, 0);
}

pub fn logSrcPos(src: []const u8, start: u32, len: u32) void {
    if (start + len > src.len) {
        log.tracev("{s}", .{ src[start..] });
    } else {
        log.tracev("{s}", .{ src[start..start+len] });
    }
}

const ParseExprOptions = struct {
    returnLeftAssignExpr: bool = false,
    outIsAssignStmt: *bool = undefined,
    parseShorthandCallExpr: bool = true,
};

const StaticDeclType = enum {
    variable,
    typeAlias,
    type_copy,
    implicit_method,
    func,
    funcInit,
    import,
    object,
    struct_t,
    enum_t,
    typeTemplate,
};

pub const StaticDecl = struct {
    declT: StaticDeclType,
    nodeId: cy.NodeId,
    data: union {
        implicit_method: *cy.Func,
        func: *cy.Func,
        sym: *cy.Sym,
        typeTemplate: struct {
            ctNodeStart: u32,
            ctNodeEnd: u32,
        },
    },
};

fn isRecedingIndent(p: *Parser, prevIndent: u32, curIndent: u32, indent: u32) !bool {
    if (indent ^ curIndent < 0x80000000) {
        return indent <= prevIndent;
    } else {
        if (indent == 0) {
            return true;
        } else {
            if (curIndent & 0x80000000 == 0x80000000) {
                return p.reportError("Expected tabs for indentation.", &.{});
            } else {
                return p.reportError("Expected spaces for indentation.", &.{});
            }
        }
    }
}

fn isRecordKeyNodeType(node_t: cy.NodeType) bool {
    switch (node_t) {
        .ident,
        .raw_string_lit,
        .decLit,
        .binLit,
        .octLit,
        .hexLit => {
            return true;
        },
        else => {
            return false;
        }
    }
}

const FirstLastStmt = struct {
    first: NodeId,
    last: NodeId,
};

fn defaultReportFn(ctx: *anyopaque, format: []const u8, args: []const cy.fmt.FmtValue, pos: u32) anyerror {
    _ = ctx;
    _ = format;
    _ = args;
    _ = pos;
    return error.ParseError;
}