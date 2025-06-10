// targil 2 Ester Ben-Shabat 211950290 yael novick 211526462

const std = @import("std");

pub const CommandType = enum {
    C_PUSH,
    C_POP,
    C_ARITHMETIC,
    C_LABEL,
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
        if (std.mem.startsWith(u8, self.current_command, "label")) return .C_LABEL;
        if (std.mem.startsWith(u8, self.current_command, "goto")) return .C_GOTO;
        if (std.mem.startsWith(u8, self.current_command, "if-goto")) return .C_IF;
        if (std.mem.startsWith(u8, self.current_command, "function")) return .C_FUNCTION;
        if (std.mem.startsWith(u8, self.current_command, "call")) return .C_CALL;
        if (std.mem.startsWith(u8, self.current_command, "return")) return .C_RETURN;
        return .C_ARITHMETIC;
    }

    pub fn arg1(self: *const Parser) []const u8 {
        // First, clean the command by removing comments
        var clean_command = self.current_command;
        if (std.mem.indexOf(u8, clean_command, "//")) |comment_start| {
            clean_command = std.mem.trim(u8, clean_command[0..comment_start], " \t\r\n");
        }

        var tokens = std.mem.tokenizeAny(u8, clean_command, " \t");

        if (self.commandType() == .C_ARITHMETIC) {
            // For arithmetic, return just the first token (the operation)
            return tokens.next().?;
        }

        _ = tokens.next(); // skip command
        return tokens.next().?;
    }

    pub fn arg2(self: *const Parser) u16 {
        // First, clean the command by removing comments
        var clean_command = self.current_command;
        if (std.mem.indexOf(u8, clean_command, "//")) |comment_start| {
            clean_command = std.mem.trim(u8, clean_command[0..comment_start], " \t\r\n");
        }

        var tokens = std.mem.tokenizeAny(u8, clean_command, " \t");
        _ = tokens.next(); // skip command
        _ = tokens.next(); // skip segment/function name

        if (tokens.next()) |arg2_str| {
            return std.fmt.parseInt(u16, arg2_str, 10) catch 0;
        }
        return 0;
    }
};
