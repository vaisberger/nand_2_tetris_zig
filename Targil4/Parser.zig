const std = @import("std");
const print = std.debug.print;
const ArrayList = std.ArrayList;

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
};

const Parser = struct {
    tokens: ArrayList(Token),
    current_token: usize,
    output: ArrayList(u8),
    allocator: std.mem.Allocator,
    indent_level: usize,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        // הקצאת זיכרון אלורטור
        return Self{
            .tokens = ArrayList(Token).init(allocator),
            .output = ArrayList(u8).init(allocator),
            .current_token = 0,
            .allocator = allocator,
            .indent_level = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        // שחרור זיכרון עבור ערכי הטוקנים
        for (self.tokens.items) |token| {
            self.allocator.free(token.value);
        }
        self.tokens.deinit();
        self.output.deinit();
    }

    fn writeIndent(self: *Self) !void {
        var i: usize = 0;
        while (i < self.indent_level) : (i += 1) {
            try self.output.writer().writeAll("  "); // 2 spaces per indent level
        }
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

    pub fn writeOpenTag(self: *Self, tag: []const u8) ParseError!void {
        try self.writeIndent();
        try self.output.writer().print("<{s}>\n", .{tag});
        self.indent_level += 1;
    }

    pub fn writeCloseTag(self: *Self, tag: []const u8) ParseError!void {
        self.indent_level -= 1;
        try self.writeIndent();
        try self.output.writer().print("</{s}>\n", .{tag});
    }

    pub fn writeCurrentToken(self: *Self) ParseError!void {
        if (self.getCurrentToken()) |token| {
            const type_name = switch (token.type) {
                .keyword => "keyword",
                .symbol => "symbol",
                .identifier => "identifier",
                .integerConstant => "integerConstant",
                .stringConstant => "stringConstant",
            };

            // טיפול בתווים מיוחדים ב-XML
            var escaped_value = token.value;
            if (std.mem.eql(u8, token.value, "<")) {
                escaped_value = "&lt;";
            } else if (std.mem.eql(u8, token.value, ">")) {
                escaped_value = "&gt;";
            } else if (std.mem.eql(u8, token.value, "&")) {
                escaped_value = "&amp;";
            } else if (std.mem.eql(u8, token.value, "\"")) {
                escaped_value = "&quot;";
            }

            // Special handling for stringConstant - use normal indentation
            try self.writeIndent();

            if (token.type == .stringConstant) {
                try self.output.writer().print("<{s}> {s}  </{s}>\n", .{ type_name, escaped_value, type_name });
            } else {
                try self.output.writer().print("<{s}> {s} </{s}>\n", .{ type_name, escaped_value, type_name });
            }
        }
    }

    // ===== פונקציות הפרשינג המלאות =====

    pub fn parseClass(self: *Self) ParseError!void {
        try self.writeOpenTag("class");

        // class
        try self.writeCurrentToken(); // keyword: class
        self.advance();

        // className
        try self.writeCurrentToken(); // identifier: שם הקלאס
        self.advance();

        // {
        try self.writeCurrentToken(); // symbol: {
        self.advance();

        // classVarDec*
        while (self.isKeyword("static") or self.isKeyword("field")) {
            try self.parseClassVarDec();
        }

        // subroutineDec*
        while (self.isKeyword("constructor") or self.isKeyword("function") or self.isKeyword("method")) {
            try self.parseSubroutineDec();
        }

        // }
        try self.writeCurrentToken(); // symbol: }
        self.advance();

        try self.writeCloseTag("class");
    }

    pub fn parseClassVarDec(self: *Self) ParseError!void {
        try self.writeOpenTag("classVarDec");

        // static | field
        try self.writeCurrentToken();
        self.advance();

        // type
        try self.writeCurrentToken();
        self.advance();

        // varName
        try self.writeCurrentToken();
        self.advance();

        // (, varName)*
        while (self.isSymbol(",")) {
            try self.writeCurrentToken(); // ,
            self.advance();
            try self.writeCurrentToken(); // varName
            self.advance();
        }

        // ;
        try self.writeCurrentToken();
        self.advance();

        try self.writeCloseTag("classVarDec");
    }

    pub fn parseSubroutineDec(self: *Self) ParseError!void {
        try self.writeOpenTag("subroutineDec");

        // constructor | function | method
        try self.writeCurrentToken();
        self.advance();

        // void | type
        try self.writeCurrentToken();
        self.advance();

        // subroutineName
        try self.writeCurrentToken();
        self.advance();

        // (
        try self.writeCurrentToken();
        self.advance();

        // parameterList
        try self.parseParameterList();

        // )
        try self.writeCurrentToken();
        self.advance();

        // subroutineBody
        try self.parseSubroutineBody();

        try self.writeCloseTag("subroutineDec");
    }

    pub fn parseParameterList(self: *Self) ParseError!void {
        try self.writeOpenTag("parameterList");

        // בדיקה אם יש פרמטרים
        if (!self.isSymbol(")")) {
            // type
            try self.writeCurrentToken();
            self.advance();

            // varName
            try self.writeCurrentToken();
            self.advance();

            // (, type varName)*
            while (self.isSymbol(",")) {
                try self.writeCurrentToken(); // ,
                self.advance();
                try self.writeCurrentToken(); // type
                self.advance();
                try self.writeCurrentToken(); // varName
                self.advance();
            }
        }

        try self.writeCloseTag("parameterList");
    }

    pub fn parseSubroutineBody(self: *Self) ParseError!void {
        try self.writeOpenTag("subroutineBody");

        // {
        try self.writeCurrentToken();
        self.advance();

        // varDec*
        while (self.isKeyword("var")) {
            try self.parseVarDec();
        }

        // statements
        try self.parseStatements();

        // }
        try self.writeCurrentToken();
        self.advance();

        try self.writeCloseTag("subroutineBody");
    }

    pub fn parseVarDec(self: *Self) ParseError!void {
        try self.writeOpenTag("varDec");

        // var
        try self.writeCurrentToken();
        self.advance();

        // type
        try self.writeCurrentToken();
        self.advance();

        // varName
        try self.writeCurrentToken();
        self.advance();

        // (, varName)*
        while (self.isSymbol(",")) {
            try self.writeCurrentToken(); // ,
            self.advance();
            try self.writeCurrentToken(); // varName
            self.advance();
        }

        // ;
        try self.writeCurrentToken();
        self.advance();

        try self.writeCloseTag("varDec");
    }

    pub fn parseStatements(self: *Self) ParseError!void {
        try self.writeOpenTag("statements");

        while (true) {
            if (self.isKeyword("let")) {
                try self.parseLetStatement();
            } else if (self.isKeyword("if")) {
                try self.parseIfStatement();
            } else if (self.isKeyword("while")) {
                try self.parseWhileStatement();
            } else if (self.isKeyword("do")) {
                try self.parseDoStatement();
            } else if (self.isKeyword("return")) {
                try self.parseReturnStatement();
            } else {
                break;
            }
        }

        try self.writeCloseTag("statements");
    }

    pub fn parseLetStatement(self: *Self) ParseError!void {
        try self.writeOpenTag("letStatement");

        // let
        try self.writeCurrentToken();
        self.advance();

        // varName
        try self.writeCurrentToken();
        self.advance();

        // [expression]?
        if (self.isSymbol("[")) {
            try self.writeCurrentToken(); // [
            self.advance();
            try self.parseExpression();
            try self.writeCurrentToken(); // ]
            self.advance();
        }

        // =
        try self.writeCurrentToken();
        self.advance();

        // expression
        try self.parseExpression();

        // ;
        try self.writeCurrentToken();
        self.advance();

        try self.writeCloseTag("letStatement");
    }

    pub fn parseIfStatement(self: *Self) ParseError!void {
        try self.writeOpenTag("ifStatement");

        // if
        try self.writeCurrentToken();
        self.advance();

        // (
        try self.writeCurrentToken();
        self.advance();

        // expression
        try self.parseExpression();

        // )
        try self.writeCurrentToken();
        self.advance();

        // {
        try self.writeCurrentToken();
        self.advance();

        // statements
        try self.parseStatements();

        // }
        try self.writeCurrentToken();
        self.advance();

        // (else { statements })?
        if (self.isKeyword("else")) {
            try self.writeCurrentToken(); // else
            self.advance();
            try self.writeCurrentToken(); // {
            self.advance();
            try self.parseStatements();
            try self.writeCurrentToken(); // }
            self.advance();
        }

        try self.writeCloseTag("ifStatement");
    }

    pub fn parseWhileStatement(self: *Self) ParseError!void {
        try self.writeOpenTag("whileStatement");

        // while
        try self.writeCurrentToken();
        self.advance();

        // (
        try self.writeCurrentToken();
        self.advance();

        // expression
        try self.parseExpression();

        // )
        try self.writeCurrentToken();
        self.advance();

        // {
        try self.writeCurrentToken();
        self.advance();

        // statements
        try self.parseStatements();

        // }
        try self.writeCurrentToken();
        self.advance();

        try self.writeCloseTag("whileStatement");
    }

    pub fn parseDoStatement(self: *Self) ParseError!void {
        try self.writeOpenTag("doStatement");

        // do
        try self.writeCurrentToken();
        self.advance();

        // subroutineCall
        try self.parseSubroutineCall();

        // ;
        try self.writeCurrentToken();
        self.advance();

        try self.writeCloseTag("doStatement");
    }

    pub fn parseReturnStatement(self: *Self) ParseError!void {
        try self.writeOpenTag("returnStatement");

        // return
        try self.writeCurrentToken();
        self.advance();

        // expression?
        if (!self.isSymbol(";")) {
            try self.parseExpression();
        }

        // ;
        try self.writeCurrentToken();
        self.advance();

        try self.writeCloseTag("returnStatement");
    }

    pub fn parseExpression(self: *Self) ParseError!void {
        try self.writeOpenTag("expression");

        // term
        try self.parseTerm();

        // (op term)*
        while (self.isOp()) {
            try self.writeCurrentToken(); // op
            self.advance();
            try self.parseTerm();
        }

        try self.writeCloseTag("expression");
    }
    //מטפלת בביטויים מתמתטים ולוגים
    pub fn parseTerm(self: *Self) ParseError!void {
        try self.writeOpenTag("term");

        if (self.getCurrentToken()) |token| {
            if (token.type == .integerConstant) {
                // integerConstant
                try self.writeCurrentToken();
                self.advance();
            } else if (token.type == .stringConstant) {
                // stringConstant
                try self.writeCurrentToken();
                self.advance();
            } else if (self.isKeyword("true") or self.isKeyword("false") or
                self.isKeyword("null") or self.isKeyword("this"))
            {
                // keywordConstant
                try self.writeCurrentToken();
                self.advance();
            } else if (token.type == .identifier) {
                // varName | varName[expression] | subroutineCall
                if (self.peekToken(1)) |next_token| {
                    if (next_token.type == .symbol and std.mem.eql(u8, next_token.value, "[")) {
                        // varName[expression]
                        try self.writeCurrentToken(); // varName
                        self.advance();
                        try self.writeCurrentToken(); // [
                        self.advance();
                        try self.parseExpression();
                        try self.writeCurrentToken(); // ]
                        self.advance();
                    } else if ((next_token.type == .symbol and std.mem.eql(u8, next_token.value, "(")) or
                        (next_token.type == .symbol and std.mem.eql(u8, next_token.value, ".")))
                    {
                        // subroutineCall
                        try self.parseSubroutineCall();
                    } else {
                        // varName
                        try self.writeCurrentToken();
                        self.advance();
                    }
                } else {
                    // varName
                    try self.writeCurrentToken();
                    self.advance();
                }
            } else if (self.isSymbol("(")) {
                // (expression)
                try self.writeCurrentToken(); // (
                self.advance();
                try self.parseExpression();
                try self.writeCurrentToken(); // )
                self.advance();
            } else if (self.isUnaryOp()) {
                // unaryOp term
                try self.writeCurrentToken(); // unaryOp
                self.advance();
                try self.parseTerm();
            }
        }

        try self.writeCloseTag("term");
    }
    // מטפלת בקריאות של פונקציות
    pub fn parseSubroutineCall(self: *Self) ParseError!void {
        // subroutineName(expressionList) |
        // (className | varName).subroutineName(expressionList)

        try self.writeCurrentToken(); // subroutineName או className/varName
        self.advance();

        if (self.isSymbol(".")) {
            try self.writeCurrentToken(); // .
            self.advance();
            try self.writeCurrentToken(); // subroutineName
            self.advance();
        }

        // (
        try self.writeCurrentToken();
        self.advance();

        // expressionList
        try self.parseExpressionList();

        // )
        try self.writeCurrentToken();
        self.advance();
    }
    //טיפול בפרמטרים שמתקבלים לפונקציב
    pub fn parseExpressionList(self: *Self) ParseError!void {
        try self.writeOpenTag("expressionList");

        // expression?
        if (!self.isSymbol(")")) {
            try self.parseExpression();

            // (, expression)*
            while (self.isSymbol(",")) {
                try self.writeCurrentToken(); // ,
                self.advance();
                try self.parseExpression();
            }
        }

        try self.writeCloseTag("expressionList");
    }

    // פונקציות עזר לזיהוי אופרטורים
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

    pub fn isUnaryOp(self: *Self) bool {
        if (self.getCurrentToken()) |token| {
            if (token.type == .symbol) {
                return std.mem.eql(u8, token.value, "-") or
                    std.mem.eql(u8, token.value, "~");
            }
        }
        return false;
    }

    pub fn saveOutput(self: *Self, filename: []const u8) !void {
        const file = try std.fs.cwd().createFile(filename, .{});
        defer file.close();
        try file.writeAll(self.output.items);
    }
};

pub fn main() !void {
    // ניהול זיכרון
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // קבלת ארגומנטים מה command line
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        print("Usage: {s} <input_file_T.xml>\n", .{args[0]});
        print("Note: Input should be xxxT.xml (tokenized file from Part 1)\n", .{});
        return;
    }

    const input_file = args[1];

    // בדיקה שהקלט הוא קובץ T.xml
    if (!std.mem.endsWith(u8, input_file, "T.xml")) {
        print("Error: Input file must end with 'T.xml' (tokenized file from Part 1)\n", .{});
        print("Expected format: xxxT.xml\n", .{});
        return;
    }

    // יצירת שם קובץ הפלט - החלפת T.xml ב-.xml
    const output_file = try std.fmt.allocPrint(allocator, "{s}1.xml", .{input_file[0 .. input_file.len - 5]});
    defer allocator.free(output_file);

    var parser = Parser.init(allocator);
    defer parser.deinit();

    // טעינת הטוקנים מקובץ ה-XML
    try parser.loadTokensFromXML(input_file);
    print("Loaded {d} tokens from {s}\n", .{ parser.tokens.items.len, input_file });

    try parser.parseClass();
    try parser.saveOutput(output_file);

    print("Parsing completed! Parse tree saved to: {s}\n", .{output_file});
}
