// targil 1 Hadas Gamliel 214855330 Ester Ben-Shabat 211950290
const std = @import("std");

pub const CommandType = enum {
    C_PUSH,
    C_POP,
    C_ARITHMETIC,
    C_LABEL, // הוסף את השדה הזה אם חסר
    C_GOTO,
    C_IF,
    C_FUNCTION,
    C_CALL,
    C_RETURN,
};

pub const Parser = struct {
    lines: [][]const u8,
    current: usize,
    current_command: []const u8,

    pub fn init(input: []const u8) Parser {
        var lines = std.mem.tokenizeScalar(u8, input, '\n');
        var list = std.ArrayList([]const u8).init(std.heap.page_allocator);

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "//")) continue;
            list.append(trimmed) catch unreachable;
        }

        return Parser{
            .lines = list.toOwnedSlice() catch unreachable,
            .current = 0,
            .current_command = "",
        };
    }

    pub fn hasMoreCommands(self: *Parser) bool {
        return self.current < self.lines.len;
    }

    pub fn advance(self: *Parser) !void {
        self.current_command = self.lines[self.current];
        self.current += 1;
    }

    pub fn commandType(self: *const Parser) CommandType {
        if (std.mem.startsWith(u8, self.current_command, "push")) return .C_PUSH;
        if (std.mem.startsWith(u8, self.current_command, "pop")) return .C_POP;
        return .C_ARITHMETIC;
    }

    pub fn arg1(self: *const Parser) []const u8 {
        var tokens = std.mem.tokenizeScalar(u8, self.current_command, ' ');
        if (self.commandType() == .C_ARITHMETIC) return self.current_command;
        _ = tokens.next(); // skip command
        return tokens.next().?;
    }

    pub fn arg2(self: *const Parser) u16 {
        var tokens = std.mem.tokenizeScalar(u8, self.current_command, ' ');
        _ = tokens.next(); // skip command
        _ = tokens.next(); // skip segment
        return std.fmt.parseInt(u16, tokens.next().?, 10) catch 0;
    }
};
