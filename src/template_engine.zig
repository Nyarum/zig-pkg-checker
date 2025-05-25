const std = @import("std");
const Allocator = std.mem.Allocator;

pub const TemplateError = error{
    SyntaxError,
    UnknownHelper,
    MissingVariable,
    InvalidContext,
    OutOfMemory,
};

pub const TokenType = enum {
    text,
    variable,
    block_start,
    block_end,
    else_block,
    comment,
};

pub const Token = struct {
    type: TokenType,
    content: []const u8,
    line: usize,
    column: usize,
};

pub const NodeType = enum {
    text,
    variable,
    each_block,
    if_block,
    unless_block,
    helper_call,
    fragment,
};

pub const ASTNode = struct {
    type: NodeType,
    content: []const u8,
    children: []ASTNode,
    helper_args: [][]const u8,
    else_block: ?*ASTNode,

    pub fn deinit(self: *ASTNode, allocator: Allocator) void {
        for (self.children) |*child| {
            child.deinit(allocator);
        }
        allocator.free(self.children);

        for (self.helper_args) |arg| {
            allocator.free(arg);
        }
        allocator.free(self.helper_args);

        if (self.else_block) |else_node| {
            else_node.deinit(allocator);
            allocator.destroy(else_node);
        }
    }
};

pub const Template = struct {
    ast: ASTNode,
    allocator: Allocator,

    pub fn deinit(self: *Template) void {
        self.ast.deinit(self.allocator);
    }

    pub fn render(self: Template, allocator: Allocator, data: anytype) ![]const u8 {
        const context = Context.init(allocator, data);
        var renderer = Renderer.init(allocator);
        return renderer.render(self.ast, context);
    }
};

pub const Context = struct {
    allocator: Allocator,
    data: std.json.Value,
    parent: ?*const Context,

    const Self = @This();

    pub fn init(allocator: Allocator, data: anytype) Self {
        // Convert the data to a JSON value for uniform access
        const json_data = dataToJsonValue(allocator, data) catch std.json.Value{ .null = {} };
        return Self{
            .allocator = allocator,
            .data = json_data,
            .parent = null,
        };
    }

    pub fn initWithParent(allocator: Allocator, data: anytype, parent: *const Context) Self {
        var ctx = init(allocator, data);
        ctx.parent = parent;
        return ctx;
    }

    pub fn getValue(self: Self, key: []const u8) ?std.json.Value {
        // Handle nested property access (e.g., "object.property")
        if (std.mem.indexOf(u8, key, ".")) |dot_index| {
            const first_key = key[0..dot_index];
            const rest_key = key[dot_index + 1 ..];

            if (self.getDirectValue(first_key)) |value| {
                switch (value) {
                    .object => |_| {
                        const nested_ctx = Context{
                            .allocator = self.allocator,
                            .data = value,
                            .parent = &self,
                        };
                        return nested_ctx.getValue(rest_key);
                    },
                    else => return null,
                }
            }
        }

        return self.getDirectValue(key);
    }

    fn getDirectValue(self: Self, key: []const u8) ?std.json.Value {
        switch (self.data) {
            .object => |obj| {
                return obj.get(key);
            },
            else => {
                // Check parent context if available
                if (self.parent) |parent| {
                    return parent.getValue(key);
                }
                return null;
            },
        }
    }

    fn dataToJsonValue(allocator: Allocator, data: anytype) !std.json.Value {
        const T = @TypeOf(data);

        switch (@typeInfo(T)) {
            .@"struct" => {
                var object = std.json.ObjectMap.init(allocator);

                inline for (std.meta.fields(T)) |field| {
                    const field_value = @field(data, field.name);
                    const json_value = try dataToJsonValue(allocator, field_value);
                    try object.put(field.name, json_value);
                }

                return std.json.Value{ .object = object };
            },
            .array => {
                var array = std.json.Array.init(allocator);

                for (data) |item| {
                    const json_value = try dataToJsonValue(allocator, item);
                    try array.append(json_value);
                }

                return std.json.Value{ .array = array };
            },
            .pointer => |ptr_info| {
                if (ptr_info.size == .slice) {
                    // Check if this is a string slice ([]const u8 or []u8)
                    if (ptr_info.child == u8) {
                        return std.json.Value{ .string = data };
                    } else {
                        // This is a slice of other types, treat as array
                        var array = std.json.Array.init(allocator);

                        for (data) |item| {
                            const json_value = try dataToJsonValue(allocator, item);
                            try array.append(json_value);
                        }

                        return std.json.Value{ .array = array };
                    }
                } else {
                    return std.json.Value{ .string = data };
                }
            },
            .optional => {
                if (data) |value| {
                    return dataToJsonValue(allocator, value);
                } else {
                    return std.json.Value{ .null = {} };
                }
            },
            .int => {
                return std.json.Value{ .integer = @intCast(data) };
            },
            .float => {
                return std.json.Value{ .float = @floatCast(data) };
            },
            .bool => {
                return std.json.Value{ .bool = data };
            },
            else => {
                // Try to convert to string as fallback
                if (comptime std.meta.trait.hasFn("len")(T)) {
                    return std.json.Value{ .string = data };
                }
                return std.json.Value{ .null = {} };
            },
        }
    }
};

pub const Lexer = struct {
    input: []const u8,
    position: usize,
    line: usize,
    column: usize,
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator, input: []const u8) Self {
        return Self{
            .input = input,
            .position = 0,
            .line = 1,
            .column = 1,
            .allocator = allocator,
        };
    }

    pub fn tokenize(self: *Self) ![]Token {
        var tokens = std.ArrayList(Token).init(self.allocator);
        defer tokens.deinit();

        var last_pos: usize = 0;

        while (self.position < self.input.len) {
            if (self.peekString("{{")) {
                // Add text before the expression if any
                if (last_pos < self.position) {
                    const text_content = self.input[last_pos..self.position];
                    if (text_content.len > 0) {
                        try tokens.append(Token{
                            .type = .text,
                            .content = text_content,
                            .line = self.line,
                            .column = self.column,
                        });
                    }
                }

                const token = try self.readExpression();
                try tokens.append(token);
                last_pos = self.position;
            } else {
                self.advance();
            }
        }

        // Add remaining text
        if (last_pos < self.input.len) {
            const text_content = self.input[last_pos..];
            if (text_content.len > 0) {
                try tokens.append(Token{
                    .type = .text,
                    .content = text_content,
                    .line = self.line,
                    .column = self.column,
                });
            }
        }

        return tokens.toOwnedSlice();
    }

    fn peekString(self: Self, str: []const u8) bool {
        if (self.position + str.len > self.input.len) return false;
        return std.mem.eql(u8, self.input[self.position .. self.position + str.len], str);
    }

    fn advance(self: *Self) void {
        if (self.position < self.input.len) {
            if (self.input[self.position] == '\n') {
                self.line += 1;
                self.column = 1;
            } else {
                self.column += 1;
            }
            self.position += 1;
        }
    }

    fn readExpression(self: *Self) !Token {
        const start_line = self.line;
        const start_column = self.column;

        // Skip opening {{
        self.position += 2;
        self.column += 2;

        // Skip whitespace
        while (self.position < self.input.len and std.ascii.isWhitespace(self.input[self.position])) {
            self.advance();
        }

        const content_start = self.position;

        // Find closing }}
        while (self.position < self.input.len) {
            if (self.peekString("}}")) {
                break;
            }
            self.advance();
        }

        if (self.position >= self.input.len) {
            return TemplateError.SyntaxError;
        }

        const content_end = self.position;

        // Skip closing }}
        self.position += 2;
        self.column += 2;

        const content = std.mem.trim(u8, self.input[content_start..content_end], " \t\n\r");

        // Determine token type
        const token_type = if (content.len > 0 and content[0] == '#')
            TokenType.block_start
        else if (content.len > 0 and content[0] == '/')
            TokenType.block_end
        else if (std.mem.eql(u8, content, "else"))
            TokenType.else_block
        else if (content.len > 2 and std.mem.startsWith(u8, content, "!--"))
            TokenType.comment
        else
            TokenType.variable;

        return Token{
            .type = token_type,
            .content = content,
            .line = start_line,
            .column = start_column,
        };
    }

    fn wasLastTokenExpression(self: Self) bool {
        // Look backwards to see if the last non-whitespace was "}}"
        var pos = self.position;
        while (pos > 1) {
            pos -= 1;
            if (!std.ascii.isWhitespace(self.input[pos])) {
                return pos > 0 and self.input[pos - 1] == '}' and self.input[pos] == '}';
            }
        }
        return false;
    }

    fn getLastTextPosition(self: Self) usize {
        // Find the last "}}" to know where text should start
        var pos = self.position;
        while (pos > 1) {
            pos -= 1;
            if (self.input[pos - 1] == '}' and self.input[pos] == '}') {
                return pos + 1;
            }
        }
        return 0;
    }
};

pub const Parser = struct {
    tokens: []Token,
    position: usize,
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator, tokens: []Token) Self {
        return Self{
            .tokens = tokens,
            .position = 0,
            .allocator = allocator,
        };
    }

    pub fn parse(self: *Self) TemplateError!ASTNode {
        var children = std.ArrayList(ASTNode).init(self.allocator);
        defer children.deinit();

        while (self.position < self.tokens.len) {
            const node = self.parseNode() catch |err| {
                return err;
            };
            if (node) |n| {
                children.append(n) catch return TemplateError.OutOfMemory;
            } else {
                break;
            }
        }

        return ASTNode{
            .type = .fragment,
            .content = "",
            .children = children.toOwnedSlice() catch return TemplateError.OutOfMemory,
            .helper_args = &[_][]const u8{},
            .else_block = null,
        };
    }

    fn parseNode(self: *Self) TemplateError!?ASTNode {
        if (self.position >= self.tokens.len) return null;

        const token = self.tokens[self.position];

        switch (token.type) {
            .text => {
                self.position += 1;
                return ASTNode{
                    .type = .text,
                    .content = token.content,
                    .children = &[_]ASTNode{},
                    .helper_args = &[_][]const u8{},
                    .else_block = null,
                };
            },
            .variable => {
                self.position += 1;
                return ASTNode{
                    .type = .variable,
                    .content = token.content,
                    .children = &[_]ASTNode{},
                    .helper_args = &[_][]const u8{},
                    .else_block = null,
                };
            },
            .block_start => {
                const block_node = self.parseBlock() catch |err| return err;
                return block_node;
            },
            .comment => {
                self.position += 1;
                return null; // Skip comments
            },
            else => {
                return null;
            },
        }
    }

    fn parseBlock(self: *Self) TemplateError!ASTNode {
        const start_token = self.tokens[self.position];
        self.position += 1;

        // Parse helper name and arguments
        const helper_content = start_token.content[1..]; // Remove '#'
        var helper_parts = std.mem.splitSequence(u8, helper_content, " ");
        const helper_name = helper_parts.next() orelse return TemplateError.SyntaxError;

        // Collect arguments
        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();

        while (helper_parts.next()) |arg| {
            const trimmed_arg = std.mem.trim(u8, arg, " \t\n\r");
            if (trimmed_arg.len > 0) {
                args.append(self.allocator.dupe(u8, trimmed_arg) catch return TemplateError.OutOfMemory) catch return TemplateError.OutOfMemory;
            }
        }

        // Parse block children
        var children = std.ArrayList(ASTNode).init(self.allocator);
        defer children.deinit();

        var else_block: ?*ASTNode = null;
        var in_else = false;

        while (self.position < self.tokens.len) {
            const token = self.tokens[self.position];

            if (token.type == .block_end) {
                const end_helper = token.content[1..]; // Remove '/'
                if (std.mem.eql(u8, end_helper, helper_name)) {
                    self.position += 1;
                    break;
                }
            } else if (token.type == .else_block and !in_else) {
                self.position += 1;
                in_else = true;

                // Create else block
                else_block = self.allocator.create(ASTNode) catch return TemplateError.OutOfMemory;
                var else_children = std.ArrayList(ASTNode).init(self.allocator);

                while (self.position < self.tokens.len) {
                    const else_token = self.tokens[self.position];
                    if (else_token.type == .block_end) {
                        const end_helper = else_token.content[1..];
                        if (std.mem.eql(u8, end_helper, helper_name)) {
                            break;
                        }
                    }

                    if (self.parseNode() catch |err| return err) |node| {
                        else_children.append(node) catch return TemplateError.OutOfMemory;
                    }
                }

                else_block.?.* = ASTNode{
                    .type = .fragment,
                    .content = "",
                    .children = else_children.toOwnedSlice() catch return TemplateError.OutOfMemory,
                    .helper_args = &[_][]const u8{},
                    .else_block = null,
                };

                continue;
            }

            if (in_else) continue;

            if (self.parseNode() catch |err| return err) |node| {
                children.append(node) catch return TemplateError.OutOfMemory;
            }
        }

        // Determine node type based on helper name
        const node_type = if (std.mem.eql(u8, helper_name, "each"))
            NodeType.each_block
        else if (std.mem.eql(u8, helper_name, "if"))
            NodeType.if_block
        else if (std.mem.eql(u8, helper_name, "unless"))
            NodeType.unless_block
        else
            NodeType.helper_call;

        return ASTNode{
            .type = node_type,
            .content = helper_name,
            .children = children.toOwnedSlice() catch return TemplateError.OutOfMemory,
            .helper_args = args.toOwnedSlice() catch return TemplateError.OutOfMemory,
            .else_block = else_block,
        };
    }
};

pub const Renderer = struct {
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{ .allocator = allocator };
    }

    pub fn render(self: Self, node: ASTNode, context: Context) TemplateError![]const u8 {
        switch (node.type) {
            .text => return self.allocator.dupe(u8, node.content) catch return TemplateError.OutOfMemory,
            .variable => return self.renderVariable(node.content, context),
            .each_block => return self.renderEach(node, context),
            .if_block => return self.renderIf(node, context),
            .unless_block => return self.renderUnless(node, context),
            .helper_call => return self.renderHelper(node, context),
            .fragment => return self.renderFragment(node, context),
        }
    }

    fn renderVariable(self: Self, variable_name: []const u8, context: Context) TemplateError![]const u8 {
        std.log.debug("renderVariable: Looking for variable '{s}'", .{variable_name});

        if (context.getValue(variable_name)) |value| {
            std.log.debug("renderVariable: Found value for '{s}', type: {s}", .{ variable_name, @tagName(value) });
            return switch (value) {
                .string => |s| {
                    std.log.debug("renderVariable: Returning string value '{s}' for '{s}'", .{ s, variable_name });
                    return self.allocator.dupe(u8, s) catch return TemplateError.OutOfMemory;
                },
                .integer => |i| std.fmt.allocPrint(self.allocator, "{d}", .{i}) catch return TemplateError.OutOfMemory,
                .float => |f| std.fmt.allocPrint(self.allocator, "{d}", .{f}) catch return TemplateError.OutOfMemory,
                .bool => |b| std.fmt.allocPrint(self.allocator, "{}", .{b}) catch return TemplateError.OutOfMemory,
                .null => self.allocator.dupe(u8, "") catch return TemplateError.OutOfMemory,
                .number_string => |s| self.allocator.dupe(u8, s) catch return TemplateError.OutOfMemory,
                else => {
                    std.log.debug("renderVariable: Unsupported value type for '{s}': {s}", .{ variable_name, @tagName(value) });
                    return self.allocator.dupe(u8, "") catch return TemplateError.OutOfMemory;
                },
            };
        }
        std.log.debug("renderVariable: No value found for variable '{s}'", .{variable_name});
        return self.allocator.dupe(u8, "") catch return TemplateError.OutOfMemory;
    }

    fn renderEach(self: Self, node: ASTNode, context: Context) TemplateError![]const u8 {
        if (node.helper_args.len == 0) return TemplateError.SyntaxError;

        const collection_name = node.helper_args[0];

        if (context.getValue(collection_name)) |value| {
            switch (value) {
                .array => |array| {
                    var result = std.ArrayList(u8).init(self.allocator);
                    defer result.deinit();

                    for (array.items) |item| {
                        const item_context = Context{
                            .allocator = context.allocator,
                            .data = item,
                            .parent = &context,
                        };

                        // Render children with item context
                        for (node.children) |child| {
                            const child_output = self.render(child, item_context) catch |err| return err;
                            defer self.allocator.free(child_output);
                            result.appendSlice(child_output) catch return TemplateError.OutOfMemory;
                        }
                    }

                    return result.toOwnedSlice() catch return TemplateError.OutOfMemory;
                },
                else => {
                    // If not an array, render else block if available
                    if (node.else_block) |else_node| {
                        return self.render(else_node.*, context);
                    }
                    return self.allocator.dupe(u8, "") catch return TemplateError.OutOfMemory;
                },
            }
        }

        // No data found, render else block if available
        if (node.else_block) |else_node| {
            return self.render(else_node.*, context);
        }

        return self.allocator.dupe(u8, "") catch return TemplateError.OutOfMemory;
    }

    fn renderIf(self: Self, node: ASTNode, context: Context) TemplateError![]const u8 {
        const condition = self.evaluateCondition(node, context) catch |err| return err;

        if (condition) {
            return self.renderFragment(ASTNode{
                .type = .fragment,
                .content = "",
                .children = node.children,
                .helper_args = &[_][]const u8{},
                .else_block = null,
            }, context);
        } else if (node.else_block) |else_node| {
            return self.render(else_node.*, context);
        }

        return self.allocator.dupe(u8, "") catch return TemplateError.OutOfMemory;
    }

    fn renderUnless(self: Self, node: ASTNode, context: Context) TemplateError![]const u8 {
        const condition = self.evaluateCondition(node, context) catch |err| return err;

        if (!condition) {
            return self.renderFragment(ASTNode{
                .type = .fragment,
                .content = "",
                .children = node.children,
                .helper_args = &[_][]const u8{},
                .else_block = null,
            }, context);
        } else if (node.else_block) |else_node| {
            return self.render(else_node.*, context);
        }

        return self.allocator.dupe(u8, "") catch return TemplateError.OutOfMemory;
    }

    fn renderHelper(self: Self, node: ASTNode, context: Context) TemplateError![]const u8 {
        // Handle custom helpers like {{#if (eq value1 value2)}}
        if (std.mem.eql(u8, node.content, "eq")) {
            return self.handleEqHelper(node, context);
        }

        return TemplateError.UnknownHelper;
    }

    fn renderFragment(self: Self, node: ASTNode, context: Context) TemplateError![]const u8 {
        var result = std.ArrayList(u8).init(self.allocator);
        defer result.deinit();

        for (node.children) |child| {
            const child_output = self.render(child, context) catch |err| return err;
            defer self.allocator.free(child_output);
            result.appendSlice(child_output) catch return TemplateError.OutOfMemory;
        }

        return result.toOwnedSlice() catch return TemplateError.OutOfMemory;
    }

    fn evaluateCondition(self: Self, node: ASTNode, context: Context) TemplateError!bool {
        _ = self;
        if (node.helper_args.len == 0) return false;

        // Simple variable truthiness check
        const var_name = node.helper_args[0];

        // Handle helper function calls like (eq value1 value2)
        if (var_name.len > 2 and var_name[0] == '(' and var_name[var_name.len - 1] == ')') {
            const helper_call = var_name[1 .. var_name.len - 1];
            var parts = std.mem.splitSequence(u8, helper_call, " ");
            const helper_name = parts.next() orelse return false;

            if (std.mem.eql(u8, helper_name, "eq")) {
                const val1_name = parts.next() orelse return false;
                const val2_name = parts.next() orelse return false;

                const val1 = context.getValue(val1_name);
                const val2_str = std.mem.trim(u8, val2_name, "\"'");

                if (val1) |v1| {
                    switch (v1) {
                        .string => |s| return std.mem.eql(u8, s, val2_str),
                        else => return false,
                    }
                }
                return false;
            }
        }

        if (context.getValue(var_name)) |value| {
            return switch (value) {
                .bool => |b| b,
                .null => false,
                .string => |s| s.len > 0,
                .number_string => |s| s.len > 0,
                .integer => |i| i != 0,
                .float => |f| f != 0.0,
                .array => |a| a.items.len > 0,
                .object => |o| o.count() > 0,
            };
        }

        return false;
    }

    fn handleEqHelper(self: Self, node: ASTNode, context: Context) TemplateError![]const u8 {
        _ = self;
        _ = node;
        _ = context;
        return TemplateError.UnknownHelper;
    }
};

pub const TemplateEngine = struct {
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{ .allocator = allocator };
    }

    pub fn compile(self: Self, template_content: []const u8) TemplateError!Template {
        var lexer = Lexer.init(self.allocator, template_content);
        const tokens = lexer.tokenize() catch return TemplateError.OutOfMemory;
        defer self.allocator.free(tokens);

        var parser = Parser.init(self.allocator, tokens);
        const ast = parser.parse() catch |err| return err;

        return Template{
            .ast = ast,
            .allocator = self.allocator,
        };
    }

    pub fn renderTemplate(self: Self, template_content: []const u8, data: anytype) TemplateError![]const u8 {
        var template = self.compile(template_content) catch |err| return err;
        defer template.deinit();

        return template.render(self.allocator, data);
    }
};
