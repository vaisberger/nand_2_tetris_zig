const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const print = std.debug.print;

// Token types
const TokenType = enum {
    keyword,
    symbol,
    identifier,
    integerConstant,
    stringConstant,
};

// Token structure
const Token = struct {
    type: TokenType,
    value: []const u8,
};

// Jack language keywords
const keywords = [_][]const u8{
    "class", "constructor", "function", "method",
    "field", "static",      "var",      "int",
    "char",  "boolean",     "void",     "true",
    "false", "null",        "this",     "let",
    "do",    "if",          "else",     "while",
    "for",   "return",
};

// Jack language symbols
const symbols = [_]u8{
    '{', '}', '(', ')', '[', ']', '.', ',', ';', '+',
    '-', '*', '/', '&', '|', '<', '>', '=', '~',
};

const Tokenizer = struct {
    allocator: Allocator,
    input: []const u8,
    position: usize,
    current_char: ?u8,
    tokens: ArrayList(Token),

    const Self = @This();

    pub fn init(allocator: Allocator, input: []const u8) Self {
        const tokenizer = Self{
            .allocator = allocator,
            .input = input,
            .position = 0,
            .current_char = if (input.len > 0) input[0] else null,
            .tokens = ArrayList(Token).init(allocator),
        };
        return tokenizer;
    }

    pub fn deinit(self: *Self) void {
        // Free all token values
        for (self.tokens.items) |token| {
            self.allocator.free(token.value);
        }
        self.tokens.deinit();
    }

    fn advance(self: *Self) void {
        self.position += 1;
        if (self.position >= self.input.len) {
            self.current_char = null;
        } else {
            self.current_char = self.input[self.position];
        }
    }

    fn peek(self: *Self) ?u8 {
        const peek_pos = self.position + 1;
        if (peek_pos >= self.input.len) {
            return null;
        }
        return self.input[peek_pos];
    }

    fn skipWhitespace(self: *Self) void {
        while (self.current_char != null and std.ascii.isWhitespace(self.current_char.?)) {
            self.advance();
        }
    }

    fn skipLineComment(self: *Self) void {
        // Skip // comment - read until newline
        while (self.current_char != null and self.current_char.? != '\n') {
            self.advance();
        }
    }

    fn skipBlockComment(self: *Self) void {
        // Skip /* */ comment
        self.advance(); // skip '*'
        while (self.current_char != null) {
            if (self.current_char.? == '*' and self.peek() == '/') {
                self.advance(); // skip '*'
                self.advance(); // skip '/'
                break;
            }
            self.advance();
        }
    }

    fn readString(self: *Self) ![]const u8 {
        var string_chars = ArrayList(u8).init(self.allocator);
        defer string_chars.deinit();

        self.advance(); // skip opening quote

        while (self.current_char != null and self.current_char.? != '"') {
            try string_chars.append(self.current_char.?);
            self.advance();
        }

        if (self.current_char == '"') {
            self.advance(); // skip closing quote
        }

        return try self.allocator.dupe(u8, string_chars.items);
    }

    fn readNumber(self: *Self) ![]const u8 {
        var number_chars = ArrayList(u8).init(self.allocator);
        defer number_chars.deinit();

        while (self.current_char != null and std.ascii.isDigit(self.current_char.?)) {
            try number_chars.append(self.current_char.?);
            self.advance();
        }

        return try self.allocator.dupe(u8, number_chars.items);
    }

    fn readIdentifier(self: *Self) ![]const u8 {
        var identifier_chars = ArrayList(u8).init(self.allocator);
        defer identifier_chars.deinit();

        while (self.current_char != null and
            (std.ascii.isAlphanumeric(self.current_char.?) or self.current_char.? == '_'))
        {
            try identifier_chars.append(self.current_char.?);
            self.advance();
        }

        return try self.allocator.dupe(u8, identifier_chars.items);
    }

    fn isKeyword(word: []const u8) bool {
        for (keywords) |keyword| {
            if (std.mem.eql(u8, word, keyword)) {
                return true;
            }
        }
        return false;
    }

    fn isSymbol(char: u8) bool {
        for (symbols) |symbol| {
            if (char == symbol) {
                return true;
            }
        }
        return false;
    }

    fn symbolToString(self: *Self, char: u8) ![]const u8 {
        // Handle XML special characters
        return switch (char) {
            '<' => try self.allocator.dupe(u8, "&lt;"),
            '>' => try self.allocator.dupe(u8, "&gt;"),
            '&' => try self.allocator.dupe(u8, "&amp;"),
            '"' => try self.allocator.dupe(u8, "&quot;"),
            else => try self.allocator.dupe(u8, &[_]u8{char}),
        };
    }

    pub fn tokenize(self: *Self) !void {
        while (self.current_char != null) {
            // Skip whitespace
            if (std.ascii.isWhitespace(self.current_char.?)) {
                self.skipWhitespace();
                continue;
            }

            // Handle comments
            if (self.current_char.? == '/') {
                const next_char = self.peek();
                if (next_char == '/') {
                    self.advance(); // skip first '/'
                    self.skipLineComment();
                    continue;
                } else if (next_char == '*') {
                    self.advance(); // skip '/'
                    self.skipBlockComment();
                    continue;
                } else {
                    // It's a division symbol
                    const symbol_value = try self.symbolToString('/');
                    try self.tokens.append(Token{ .type = .symbol, .value = symbol_value });
                    self.advance();
                    continue;
                }
            }

            // Handle string constants
            if (self.current_char.? == '"') {
                const string_value = try self.readString();
                try self.tokens.append(Token{ .type = .stringConstant, .value = string_value });
                continue;
            }

            // Handle integer constants
            if (std.ascii.isDigit(self.current_char.?)) {
                const number_value = try self.readNumber();
                try self.tokens.append(Token{ .type = .integerConstant, .value = number_value });
                continue;
            }

            // Handle symbols
            if (isSymbol(self.current_char.?)) {
                const symbol_value = try self.symbolToString(self.current_char.?);
                try self.tokens.append(Token{ .type = .symbol, .value = symbol_value });
                self.advance();
                continue;
            }

            // Handle identifiers and keywords
            if (std.ascii.isAlphabetic(self.current_char.?) or self.current_char.? == '_') {
                const identifier_value = try self.readIdentifier();
                const token_type = if (isKeyword(identifier_value)) TokenType.keyword else TokenType.identifier;
                try self.tokens.append(Token{ .type = token_type, .value = identifier_value });
                continue;
            }

            // Unknown character, skip it
            self.advance();
        }
    }

    pub fn writeXML(self: *Self, writer: anytype) !void {
        try writer.writeAll("<tokens>\n");

        for (self.tokens.items) |token| {
            const tag_name = switch (token.type) {
                .keyword => "keyword",
                .symbol => "symbol",
                .identifier => "identifier",
                .integerConstant => "integerConstant",
                .stringConstant => "stringConstant",
            };

            try writer.print("<{s}> {s} </{s}>\n", .{ tag_name, token.value, tag_name });
        }

        try writer.writeAll("</tokens>\n");
    }
};

fn processJackFile(allocator: Allocator, jack_path: []const u8) !void {
    print("Processing: {s}\n", .{jack_path});

    // Read the .jack file
    const file = std.fs.cwd().openFile(jack_path, .{}) catch |err| {
        print("Error opening file {s}: {}\n", .{ jack_path, err });
        return;
    };
    defer file.close();

    const file_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(file_content);

    // Create tokenizer
    var tokenizer = Tokenizer.init(allocator, file_content);
    defer tokenizer.deinit();

    // Tokenize
    try tokenizer.tokenize();

    // Generate output filename (replace .jack with T.xml)
    var output_path = ArrayList(u8).init(allocator);
    defer output_path.deinit();

    const base_name = jack_path[0 .. jack_path.len - 5]; // remove ".jack"
    try output_path.appendSlice(base_name);
    try output_path.appendSlice("C.xml");

    // Write XML output
    const output_file = try std.fs.cwd().createFile(output_path.items, .{});
    defer output_file.close();

    const writer = output_file.writer();
    try tokenizer.writeXML(writer);

    print("Generated: {s}\n", .{output_path.items});
}

fn processDirectory(allocator: Allocator, dir_path: []const u8) !void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        print("Error opening directory {s}: {}\n", .{ dir_path, err });
        return;
    };
    defer dir.close();

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".jack")) {
            var full_path = ArrayList(u8).init(allocator);
            defer full_path.deinit();

            try full_path.appendSlice(dir_path);
            if (!std.mem.endsWith(u8, dir_path, "/")) {
                try full_path.append('/');
            }
            try full_path.appendSlice(entry.name);

            try processJackFile(allocator, full_path.items);
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 2) {
        print("Usage: {s} <directory_or_file>\n", .{args[0]});
        return;
    }

    const path = args[1];

    // Check if it's a file or directory
    // First try to open it as a directory
    if (std.fs.cwd().openDir(path, .{})) |dir| {
        var mut_dir = dir;
        mut_dir.close();
        try processDirectory(allocator, path);
    } else |_| {
        // If it fails, try as a file
        if (std.mem.endsWith(u8, path, ".jack")) {
            try processJackFile(allocator, path);
        } else {
            print("Error: {s} is not a .jack file or directory\n", .{path});
        }
    }

    print("Tokenization complete!\n", .{});
}
