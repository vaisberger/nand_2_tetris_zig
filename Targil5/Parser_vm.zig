const std = @import("std");
const print = std.debug.print;
const ArrayList = std.ArrayList;
const SymbolTable = @import("symbol_table.zig").SymbolTable;
const SubroutineType = @import("symbol_table.zig").SubroutineType;

const TokenType = enum {
    keyword,
    symbol,
    identifier,
    integerConstant,
    stringConstant,
};

const Token = struct {
    type: TokenType,
    value: []const u8,
};

const ParseError = error{
    OutOfMemory,
    WriteError,
    AccessDenied,
    SystemResources,
    Unexpected,
    UnknownType,
    ExpectedIdentifier,
    ExpectedOpenParen,
    ExpectedCloseParen,
};

const Parser = struct {
    tokens: ArrayList(Token),
    current_token: usize,
    allocator: std.mem.Allocator,
    symbol_table: SymbolTable,
    vm_writer: std.fs.File.Writer,
    current_class_name: []const u8,
    current_function_name: []const u8,
    current_function_type: SubroutineType,
    label_counter: u32, // for generating unique labels
    current_file_name: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, vm_writer: std.fs.File.Writer) Self {
        // הקצאת זיכרון אלורטור
        return Self{
            .tokens = ArrayList(Token).init(allocator),
            .current_token = 0,
            .allocator = allocator,
            .symbol_table = SymbolTable.init(allocator),
            .vm_writer = vm_writer,
            .current_class_name = "",
            .current_function_name = "",
            .current_function_type = .function,
            .label_counter = 0,
            .current_file_name = "",
        };
    }

    pub fn deinit(self: *Self) void {
        // שחרור זיכרון עבור ערכי הטוקנים
        for (self.tokens.items) |token| {
            self.allocator.free(token.value);
        }
        self.tokens.deinit();
    }

    // קריאת קובץ הטוקנים מקובץ XML (xxxT.xml - כבר מטוקן!)
    pub fn loadTokensFromXML(self: *Self, filename: []const u8) !void {
        const file = try std.fs.cwd().openFile(filename, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            // עבור כל טוקן שזוהה אנחנו שולחים אותו לPARSER
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) continue;
            if (std.mem.eql(u8, trimmed, "<tokens>") or std.mem.eql(u8, trimmed, "</tokens>")) continue;

            if (std.mem.indexOf(u8, trimmed, "<keyword>")) |_| {
                try self.parseTokenLine(trimmed, .keyword);
            } else if (std.mem.indexOf(u8, trimmed, "<identifier>")) |_| {
                try self.parseTokenLine(trimmed, .identifier);
            } else if (std.mem.indexOf(u8, trimmed, "<symbol>")) |_| {
                try self.parseTokenLine(trimmed, .symbol);
            } else if (std.mem.indexOf(u8, trimmed, "<integerConstant>")) |_| {
                try self.parseTokenLine(trimmed, .integerConstant);
            } else if (std.mem.indexOf(u8, trimmed, "<stringConstant>")) |_| {
                try self.parseTokenLine(trimmed, .stringConstant);
            }
        }
    }

    fn parseTokenLine(self: *Self, line: []const u8, token_type: TokenType) !void {
        const start = std.mem.indexOf(u8, line, ">").? + 1;
        const end = std.mem.lastIndexOf(u8, line, "<").?;
        var value = line[start..end];
        value = std.mem.trim(u8, value, " ");

        // טיפול בתווים מיוחדים
        var final_value: []const u8 = undefined;
        if (std.mem.eql(u8, value, "&lt;")) {
            final_value = try self.allocator.dupe(u8, "<");
        } else if (std.mem.eql(u8, value, "&gt;")) {
            final_value = try self.allocator.dupe(u8, ">");
        } else if (std.mem.eql(u8, value, "&amp;")) {
            final_value = try self.allocator.dupe(u8, "&");
        } else if (std.mem.eql(u8, value, "&quot;")) {
            final_value = try self.allocator.dupe(u8, "\"");
        } else {
            final_value = try self.allocator.dupe(u8, value);
        }

        try self.tokens.append(Token{
            .type = token_type,
            .value = final_value,
        });
    }

    // פונקציות עזר
    pub fn getCurrentToken(self: *Self) ?Token {
        if (self.current_token >= self.tokens.items.len) return null;
        return self.tokens.items[self.current_token];
    } // מחזיר את הטוקן הנוכחי עליו עובד ה parser

    pub fn peekToken(self: *Self, offset: usize) ?Token {
        const index = self.current_token + offset;
        if (index >= self.tokens.items.len) return null;
        return self.tokens.items[index];
    } // נחליט על offset שיגיד לנו כמה lookahead אנחנו יכולים לראות בטוקנים

    pub fn advance(self: *Self) void {
        self.current_token += 1;
    } // התקדמות לטוקן הבא

    pub fn isKeyword(self: *Self, keyword: []const u8) bool {
        if (self.getCurrentToken()) |token| {
            return token.type == .keyword and std.mem.eql(u8, token.value, keyword);
        }
        return false;
    }

    pub fn isSymbol(self: *Self, symbol: []const u8) bool {
        if (self.getCurrentToken()) |token| {
            return token.type == .symbol and std.mem.eql(u8, token.value, symbol);
        }
        return false;
    }

    pub fn isType(self: *Self) bool {
        if (self.getCurrentToken()) |token| {
            if (token.type == .keyword) {
                return std.mem.eql(u8, token.value, "int") or
                    std.mem.eql(u8, token.value, "char") or
                    std.mem.eql(u8, token.value, "boolean");
            } else if (token.type == .identifier) {
                return true; // class name
            }
        }
        return false;
    }

    pub fn isOp(self: *Self) bool {
        if (self.getCurrentToken()) |token| {
            if (token.type == .symbol) {
                return std.mem.eql(u8, token.value, "+") or
                    std.mem.eql(u8, token.value, "-") or
                    std.mem.eql(u8, token.value, "*") or
                    std.mem.eql(u8, token.value, "/") or
                    std.mem.eql(u8, token.value, "&") or
                    std.mem.eql(u8, token.value, "|") or
                    std.mem.eql(u8, token.value, "<") or
                    std.mem.eql(u8, token.value, ">") or
                    std.mem.eql(u8, token.value, "=");
            }
        }
        return false;
    }
    fn writeVMCommand(self: *Self, command: []const u8) !void {
        try self.vm_writer.writeAll(command);
        try self.vm_writer.writeAll("\n");
    }

    fn writePush(self: *Self, segment: []const u8, index: u16) !void {
        try self.vm_writer.print("push {s} {d}\n", .{ segment, index });
    }

    fn writePop(self: *Self, segment: []const u8, index: u16) !void {
        try self.vm_writer.print("pop {s} {d}\n", .{ segment, index });
    }

    fn writeArithmetic(self: *Self, command: []const u8) !void {
        try self.vm_writer.print("{s}\n", .{command});
    }

    fn writeLabel(self: *Self, label: []const u8) !void {
        try self.vm_writer.print("label {s}\n", .{label});
    }

    fn writeGoto(self: *Self, label: []const u8) !void {
        try self.vm_writer.print("goto {s}\n", .{label});
    }

    fn writeIf(self: *Self, label: []const u8) !void {
        try self.vm_writer.print("if-goto {s}\n", .{label});
    }

    fn writeCall(self: *Self, name: []const u8, nArgs: u16) !void {
        try self.vm_writer.print("call {s} {d}\n", .{ name, nArgs });
    }

    fn writeFunction(self: *Self, name: []const u8, nLocals: u16) !void {
        try self.vm_writer.print("function {s} {d}\n", .{ name, nLocals });
    }

    fn writeReturn(self: *Self) !void {
        try self.vm_writer.writeAll("return\n");
    }
    fn writeConditionJump(self: *Self, jump_label: []const u8) !void {
        try self.writeIf(jump_label);
    }
    fn getUniqueLabel(self: *Self, prefix: []const u8) ![]const u8 {
        const label = try std.fmt.allocPrint(self.allocator, "{s}.{s}_{s}_{d}", .{ self.current_class_name, self.current_function_name, prefix, self.label_counter });
        self.label_counter += 1;
        return label;
    }

    // ===== פונקציות הפרשינג המלאות =====
    pub fn compileClass(self: *Self) !void {
        // class
        self.advance(); // skip 'class'

        // className
        if (self.getCurrentToken()) |token| {
            self.current_class_name = token.value;
        }
        self.advance();

        // {
        self.advance();

        // classVarDec*
        while (self.isKeyword("static") or self.isKeyword("field")) {
            try self.compileClassVarDec();
        }

        // subroutineDec*
        while (self.isKeyword("constructor") or self.isKeyword("function") or self.isKeyword("method")) {
            std.debug.print("className: '{s}'", .{self.current_class_name});
            try self.compileSubroutineDec();
        }

        // }
        self.advance();
    }

    pub fn compileClassVarDec(self: *Self) !void {
        var kind: []const u8 = undefined;
        var var_type: []const u8 = undefined;

        // static | field
        if (self.getCurrentToken()) |token| {
            kind = token.value;
        }
        self.advance();

        // type
        if (self.getCurrentToken()) |token| {
            var_type = token.value;
        }
        self.advance();

        // varName
        if (self.getCurrentToken()) |token| {
            if (std.mem.eql(u8, kind, "static")) {
                try self.symbol_table.define(token.value, var_type, .static);
            } else {
                try self.symbol_table.define(token.value, var_type, .field);
            }
        }
        self.advance();

        // (, varName)*
        while (self.isSymbol(",")) {
            self.advance(); // ,
            if (self.getCurrentToken()) |token| {
                if (std.mem.eql(u8, kind, "static")) {
                    try self.symbol_table.define(token.value, var_type, .static);
                } else {
                    try self.symbol_table.define(token.value, var_type, .field);
                }
            }
            self.advance();
        }

        // ;
        self.advance();
    }

    pub fn compileSubroutineDec(self: *Self) !void {
        var subroutine_type: SubroutineType = undefined;
        var return_type: []const u8 = undefined;
        var function_name: []const u8 = undefined;

        // constructor | function | method
        if (self.getCurrentToken()) |token| {
            if (std.mem.eql(u8, token.value, "constructor")) {
                subroutine_type = .constructor;
            } else if (std.mem.eql(u8, token.value, "function")) {
                subroutine_type = .function;
            } else {
                subroutine_type = .method;
            }
        }
        self.current_function_type = subroutine_type;
        self.advance();

        // void | type
        if (self.getCurrentToken()) |token| {
            return_type = token.value;
        }
        self.advance();

        // subroutineName
        if (self.getCurrentToken()) |token| {
            function_name = token.value;
            self.current_function_name = function_name;
        }
        self.advance();

        // Start new subroutine scope BEFORE parsing parameters
        std.debug.print("SUBROUTINE='{s}'\n", .{self.current_class_name});
        try self.symbol_table.startSubroutine(subroutine_type, self.current_class_name);
        std.debug.print("SUBROUTINE: startSubroutine completed\n", .{});

        // (
        self.advance();

        // parameterList
        try self.compileParameterList();
        std.debug.print("SUBROUTINE: compileParameterList completed\n", .{});

        // )
        self.advance();

        // subroutineBody
        try self.compileSubroutineBody(function_name, subroutine_type);
    }
    pub fn compileParameterList(self: *Self) !void {
        // בדיקה אם יש פרמטרים
        if (!self.isSymbol(")")) {
            // type
            var param_type: []const u8 = undefined;
            if (self.getCurrentToken()) |token| {
                param_type = token.value;
            }
            self.advance();

            // varName
            if (self.getCurrentToken()) |token| {
                try self.symbol_table.define(token.value, param_type, .argument);
            }
            self.advance();

            // (, type varName)*
            while (self.isSymbol(",")) {
                self.advance(); // ,
                if (self.getCurrentToken()) |token| {
                    param_type = token.value;
                }
                self.advance(); // type
                if (self.getCurrentToken()) |token| {
                    try self.symbol_table.define(token.value, param_type, .argument);
                }
                self.advance(); // varName
            }
        }
    }

    pub fn compileSubroutineBody(self: *Self, function_name: []const u8, subroutine_type: SubroutineType) !void {
        // {
        self.advance();

        // varDec*
        while (self.isKeyword("var")) {
            try self.compileVarDec();
        }

        // כתיבת הפונקציה ל-VM
        const full_name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ self.current_class_name, function_name });
        defer self.allocator.free(full_name);
        const nLocals = self.symbol_table.varCount(.local);
        try self.writeFunction(full_name, @intCast(nLocals));

        // טיפול מיוחד ל-constructor
        if (subroutine_type == .constructor) {
            const nFields = self.symbol_table.varCount(.field);
            try self.writePush("constant", @intCast(nFields));
            try self.writeCall("Memory.alloc", 1);
            try self.writePop("pointer", 0);
        } else if (subroutine_type == .method) {
            // method - טעינת this
            try self.writePush("argument", 0);
            try self.writePop("pointer", 0);
        }

        // statements
        try self.compileStatements();

        // }
        self.advance();
    }

    pub fn compileVarDec(self: *Self) !void {
        // var
        self.advance();

        // type
        var var_type: []const u8 = undefined;
        if (self.getCurrentToken()) |token| {
            var_type = token.value;
        }
        self.advance();

        // varName
        if (self.getCurrentToken()) |token| {
            try self.symbol_table.define(token.value, var_type, .local);
        }
        self.advance();

        // (, varName)*
        while (self.isSymbol(",")) {
            self.advance(); // ,
            if (self.getCurrentToken()) |token| {
                try self.symbol_table.define(token.value, var_type, .local);
            }
            self.advance();
        }

        // ;
        self.advance();
    }

    pub fn compileStatements(self: *Self) anyerror!void {
        while (true) {
            if (self.isKeyword("let")) {
                try self.compileLetStatement();
            } else if (self.isKeyword("if")) {
                try self.compileIfStatement();
            } else if (self.isKeyword("while")) {
                try self.compileWhileStatement();
            } else if (self.isKeyword("do")) {
                try self.compileDoStatement();
            } else if (self.isKeyword("return")) {
                try self.compileReturnStatement();
            } else {
                break;
            }
        }
    }

    pub fn compileLetStatement(self: *Self) !void {
        // let
        self.advance();

        // varName
        var var_name: []const u8 = undefined;
        if (self.getCurrentToken()) |token| {
            var_name = token.value;
        }
        self.advance();

        var is_array = false;
        // [expression]?
        if (self.isSymbol("[")) {
            is_array = true;
            self.advance(); // [

            // טעינת כתובת המערך
            if (self.symbol_table.kindOf(var_name)) |kind| {
                const index = self.symbol_table.indexOf(var_name) orelse return error.UnknownType;
                const segment = kindToSegment(kind);
                try self.writePush(segment, @intCast(index));
            }

            try self.compileExpression(); // אינדקס
            try self.writeArithmetic("add"); // כתובת + אינדקס

            self.advance(); // ]
        }

        // =
        self.advance();

        // expression
        try self.compileExpression();

        if (is_array) {
            try self.writePop("temp", 0); // שמירת הערך
            try self.writePop("pointer", 1); // קביעת THAT
            try self.writePush("temp", 0); // החזרת הערך
            try self.writePop("that", 0);
        } else {
            // משתנה רגיל
            if (self.symbol_table.kindOf(var_name)) |kind| {
                const index = self.symbol_table.indexOf(var_name) orelse return error.UnknownType;
                const segment = kindToSegment(kind);
                try self.writePop(segment, @intCast(index));
            }
        }

        // ;
        self.advance();
    }

    pub fn compileIfStatement(self: *Self) !void {
        const if_false = try self.getUniqueLabel("IF_FALSE");
        defer self.allocator.free(if_false);
        const if_end = try self.getUniqueLabel("IF_TRUE");
        defer self.allocator.free(if_end);

        self.advance(); // 'if'
        self.advance(); // '('

        try self.compileExpression();

        // Always negate the condition to jump to false branch
        try self.writeArithmetic("not");
        try self.writeIf(if_false);

        self.advance(); // ')'
        self.advance(); // '{'

        try self.compileStatements();
        self.advance(); // '}'

        if (self.isKeyword("else")) {
            try self.writeGoto(if_end);
            try self.writeLabel(if_false);

            self.advance(); // 'else'
            self.advance(); // '{'

            try self.compileStatements();
            self.advance(); // '}'

            try self.writeLabel(if_end);
        } else {
            try self.writeLabel(if_false);
        }
    }

    pub fn compileWhileStatement(self: *Self) !void {
        const while_start = try self.getUniqueLabel("WHILE_START");
        defer self.allocator.free(while_start);
        const while_end = try self.getUniqueLabel("WHILE_END");
        defer self.allocator.free(while_end);

        try self.writeLabel(while_start);

        self.advance(); // 'while'
        self.advance(); // '('

        try self.compileExpression();

        // Always negate the condition to jump to end when false
        try self.writeArithmetic("not");
        try self.writeIf(while_end);

        self.advance(); // ')'
        self.advance(); // '{'

        try self.compileStatements();
        self.advance(); // '}'

        try self.writeGoto(while_start);
        try self.writeLabel(while_end);
    }

    pub fn compileDoStatement(self: *Self) !void {
        // do
        self.advance();

        // subroutineCall
        try self.compileSubroutineCall();

        // do statement זורק את הערך המוחזר
        try self.writePop("temp", 0);

        // ;
        self.advance();
    }

    pub fn compileReturnStatement(self: *Self) !void {
        // return
        self.advance();

        // expression?
        if (!self.isSymbol(";")) {
            try self.compileExpression();
        } else {
            // void function מחזיר 0
            try self.writePush("constant", 0);
        }

        try self.writeReturn();

        // ;
        self.advance();
    }

    pub fn compileExpression(self: *Self) anyerror!void {
        // term
        try self.compileTerm();

        // (op term)*
        while (self.isOp()) {
            var op: []const u8 = undefined;
            if (self.getCurrentToken()) |token| {
                op = token.value;
            }
            self.advance();

            try self.compileTerm();

            // כתיבת הפעולה
            if (std.mem.eql(u8, op, "+")) {
                try self.writeArithmetic("add");
            } else if (std.mem.eql(u8, op, "-")) {
                try self.writeArithmetic("sub");
            } else if (std.mem.eql(u8, op, "*")) {
                try self.writeCall("Math.multiply", 2);
            } else if (std.mem.eql(u8, op, "/")) {
                try self.writeCall("Math.divide", 2);
            } else if (std.mem.eql(u8, op, "&")) {
                try self.writeArithmetic("and");
            } else if (std.mem.eql(u8, op, "|")) {
                try self.writeArithmetic("or");
            } else if (std.mem.eql(u8, op, "<")) {
                try self.writeArithmetic("lt");
            } else if (std.mem.eql(u8, op, ">")) {
                try self.writeArithmetic("gt");
            } else if (std.mem.eql(u8, op, "=")) {
                try self.writeArithmetic("eq");
            }
        }
    }

    pub fn compileTerm(self: *Self) anyerror!void {
        if (self.getCurrentToken()) |token| {
            if (token.type == .integerConstant) {
                const value = std.fmt.parseInt(u16, token.value, 10) catch 0;
                try self.writePush("constant", value);
                self.advance();
            } else if (token.type == .stringConstant) {
                try self.compileStringConstant(token.value);
                self.advance();
            } else if (self.isKeyword("true")) {
                try self.writePush("constant", 0);
                try self.writeArithmetic("not");
                self.advance();
            } else if (self.isKeyword("false") or self.isKeyword("null")) {
                try self.writePush("constant", 0);
                self.advance();
            } else if (self.isKeyword("this")) {
                try self.writePush("pointer", 0);
                self.advance();
            } else if (token.type == .identifier) {
                if (self.peekToken(1)) |next_token| {
                    if (next_token.type == .symbol and std.mem.eql(u8, next_token.value, "[")) {
                        // varName[expression]
                        try self.compileArrayAccess(token.value);
                    } else if ((next_token.type == .symbol and std.mem.eql(u8, next_token.value, "(")) or
                        (next_token.type == .symbol and std.mem.eql(u8, next_token.value, ".")))
                    {
                        // subroutineCall
                        try self.compileSubroutineCall();
                    } else {
                        // varName
                        try self.compileVarName(token.value);
                    }
                } else {
                    try self.compileVarName(token.value);
                }
            } else if (self.isSymbol("(")) {
                // (expression)
                self.advance(); // (
                try self.compileExpression();
                self.advance(); // )
            } else if (self.isUnaryOp()) {
                // unaryOp term
                var op: []const u8 = undefined;
                if (self.getCurrentToken()) |current| {
                    op = current.value;
                }
                self.advance();
                try self.compileTerm();

                if (std.mem.eql(u8, op, "-")) {
                    try self.writeArithmetic("neg");
                } else if (std.mem.eql(u8, op, "~")) {
                    try self.writeArithmetic("not");
                }
            }
        }
    }

    fn compileStringConstant(self: *Self, str: []const u8) !void {
        try self.writePush("constant", @intCast(str.len));
        try self.writeCall("String.new", 1);

        for (str) |char| {
            try self.writePush("constant", @intCast(char));
            try self.writeCall("String.appendChar", 2);
        }
    }

    fn compileVarName(self: *Self, var_name: []const u8) !void {
        if (self.symbol_table.lookup(var_name)) |symbol| {
            const segment = kindToSegment(symbol.kind);
            try self.writePush(segment, symbol.index);
        } else {
            std.debug.print("ERROR: Variable '{s}' not found!\n", .{var_name});
            return error.UndefinedVariable;
        }
        self.advance();
    }

    fn compileArrayAccess(self: *Self, var_name: []const u8) anyerror!void {
        self.advance(); // varName
        self.advance(); // [

        // טעינת כתובת המערך
        if (self.symbol_table.kindOf(var_name)) |kind| {
            const index = self.symbol_table.indexOf(var_name) orelse return error.UnknownType;
            const segment = kindToSegment(kind);
            try self.writePush(segment, @intCast(index));
        }

        try self.compileExpression(); // אינדקס
        try self.writeArithmetic("add"); // כתובת + אינדקס
        try self.writePop("pointer", 1); // קביעת THAT
        try self.writePush("that", 0); // טעינת הערך

        self.advance(); // ]
    }

    pub fn compileSubroutineCall(self: *Self) anyerror!void {
        var nArgs: u16 = 0;
        var function_name: []const u8 = undefined;
        var allocated_name = false; // Track if we need to free memory

        if (self.getCurrentToken()) |token| {
            const first_name = token.value;
            self.advance();

            if (self.isSymbol(".")) {
                // obj.method() or Class.function()
                self.advance(); // .

                if (self.getCurrentToken()) |second_token| {
                    const second_name = second_token.value;
                    self.advance();

                    // Check if it's a variable (object instance) or class name
                    if (self.symbol_table.kindOf(first_name)) |kind| {
                        // It's an object variable - method call on that object
                        const var_type = self.symbol_table.typeOf(first_name) orelse return error.UnknownType;
                        const index = self.symbol_table.indexOf(first_name) orelse return error.UnknownType;
                        const segment = kindToSegment(kind);

                        // Push the object reference as 'this' for the method call
                        try self.writePush(segment, @intCast(index));
                        nArgs += 1;

                        function_name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ var_type, second_name });
                        allocated_name = true;
                    } else {
                        // It's a class name - static function call (no 'this' needed)
                        function_name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ first_name, second_name });
                        allocated_name = true;
                        // Note: nArgs remains 0 since no 'this' is pushed for static calls
                    }
                } else {
                    return error.ExpectedIdentifier;
                }
            } else {
                // Method call without dot - it's a method of current class
                // Push current object's 'this' pointer
                try self.writePush("pointer", 0);
                nArgs += 1;
                function_name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ self.current_class_name, first_name });
                allocated_name = true;
            }
        } else {
            return error.ExpectedIdentifier;
        }

        // (
        if (!self.isSymbol("(")) return error.ExpectedOpenParen;
        self.advance();

        // expressionList
        nArgs += try self.compileExpressionList();

        // )
        if (!self.isSymbol(")")) return error.ExpectedCloseParen;
        self.advance();

        try self.writeCall(function_name, nArgs);

        // Clean up allocated memory
        if (allocated_name) {
            self.allocator.free(function_name);
        }
    }

    pub fn compileExpressionList(self: *Self) anyerror!u16 {
        var nArgs: u16 = 0;

        // expression?
        if (!self.isSymbol(")")) {
            try self.compileExpression();
            nArgs += 1;

            // (, expression)*
            while (self.isSymbol(",")) {
                self.advance(); // ,
                try self.compileExpression();
                nArgs += 1;
            }
        }

        return nArgs;
    }

    // פונקציות עזר
    fn kindToSegment(kind: @import("symbol_table.zig").SymbolKind) []const u8 {
        return switch (kind) {
            .static => "static",
            .field => "this",
            .argument => "argument",
            .local => "local",
        };
    }

    pub fn isUnaryOp(self: *Self) bool {
        if (self.getCurrentToken()) |token| {
            if (token.type == .symbol) {
                return std.mem.eql(u8, token.value, "-") or
                    std.mem.eql(u8, token.value, "~");
            }
        }
        return false;
    }
};

fn getFileNameFromPath(path: []const u8) []const u8 {
    const basename = std.fs.path.basename(path);
    if (std.mem.lastIndexOf(u8, basename, ".")) |dot_index| {
        return basename[0..dot_index];
    }
    return basename;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        print("Usage: {s} <input_file_T.xml>\n", .{args[0]});
        return;
    }

    const input_file = args[1];
    if (!std.mem.endsWith(u8, input_file, "T.xml")) {
        print("Error: Input file must end with 'T.xml'\n", .{});
        return;
    }

    const output_file = try std.fmt.allocPrint(allocator, "{s}.vm", .{input_file[0 .. input_file.len - 5]});
    defer allocator.free(output_file);

    const output_file_handle = try std.fs.cwd().createFile(output_file, .{});
    defer output_file_handle.close();

    // תיקון: העבר את vm_writer ל-init
    var parser = Parser.init(allocator, output_file_handle.writer());
    parser.current_file_name = getFileNameFromPath(input_file);
    defer parser.symbol_table.deinit();
    defer parser.deinit();

    try parser.loadTokensFromXML(input_file);
    print("Loaded {d} tokens from {s}\n", .{ parser.tokens.items.len, input_file });

    try parser.compileClass();
    print("Compilation completed! VM code saved to: {s}\n", .{output_file});
}
