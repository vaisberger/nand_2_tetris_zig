// targil 1 Hadas Gamliel 214855330 Ester Ben-Shabat 211950290
const std = @import("std");
const Parser = @import("parser.zig");

pub const CodeWriter = struct {
    allocator: std.mem.Allocator,
    writer: std.fs.File.Writer,
    label_count: usize,

    pub fn init(allocator: std.mem.Allocator, file: std.fs.File) CodeWriter {
        return CodeWriter{
            .allocator = allocator,
            .writer = file.writer(),
            .label_count = 0,
        };
    }

    pub fn deinit(self: *CodeWriter) void {
        _ = self;
    }

    pub fn writeCommand(self: *CodeWriter, parser: *Parser.Parser) !void {
        switch (parser.commandType()) {
            .C_PUSH => try self.writePush(parser.arg1(), parser.arg2()),
            .C_POP => try self.writePop(parser.arg1(), parser.arg2()),
            .C_ARITHMETIC => try self.writeArithmetic(parser.arg1()),
            else => {},
        }
    }

    fn writeArithmetic(self: *CodeWriter, command: []const u8) !void {
        try self.writer.print("// {s}\n", .{command});
        if (std.mem.eql(u8, command, "add")) {
            try self.writer.writeAll("@SP\nAM=M-1\nD=M\nA=A-1\nM=M+D\n");
        } else if (std.mem.eql(u8, command, "sub")) {
            try self.writer.writeAll("@SP\nAM=M-1\nD=M\nA=A-1\nM=M-D\n");
        } else if (std.mem.eql(u8, command, "neg")) {
            try self.writer.writeAll("@SP\nA=M-1\nM=-M\n");
        } else if (std.mem.eql(u8, command, "and")) {
            try self.writer.writeAll("@SP\nAM=M-1\nD=M\nA=A-1\nM=M&D\n");
        } else if (std.mem.eql(u8, command, "or")) {
            try self.writer.writeAll("@SP\nAM=M-1\nD=M\nA=A-1\nM=M|D\n");
        } else if (std.mem.eql(u8, command, "not")) {
            try self.writer.writeAll("@SP\nA=M-1\nM=!M\n");
        } else if (std.mem.eql(u8, command, "eq") or std.mem.eql(u8, command, "gt") or std.mem.eql(u8, command, "lt")) {
            const jump = if (std.mem.eql(u8, command, "eq")) "JEQ" else if (std.mem.eql(u8, command, "gt")) "JGT" else "JLT";

            const label_true = try std.fmt.allocPrint(self.allocator, "LABEL_TRUE_{d}", .{self.label_count});
            const label_end = try std.fmt.allocPrint(self.allocator, "LABEL_END_{d}", .{self.label_count});
            self.label_count += 1;

            try self.writer.print("@SP\nAM=M-1\nD=M\nA=A-1\nD=M-D\n@{s}\nD;{s}\n@SP\nA=M-1\nM=0\n@{s}\n0;JMP\n({s})\n@SP\nA=M-1\nM=-1\n({s})\n", .{ label_true, jump, label_end, label_true, label_end });
        }
    }

    fn writePush(self: *CodeWriter, segment: []const u8, index: u16) !void {
        try self.writer.print("// push {s} {d}\n", .{ segment, index });
        if (std.mem.eql(u8, segment, "constant")) {
            try self.writer.print("@{d}\nD=A\n@SP\nA=M\nM=D\n@SP\nM=M+1\n", .{index});
        } else if (std.mem.eql(u8, segment, "local")) {
            try self.writePushFromSegment("LCL", index);
        } else if (std.mem.eql(u8, segment, "argument")) {
            try self.writePushFromSegment("ARG", index);
        } else if (std.mem.eql(u8, segment, "this")) {
            try self.writePushFromSegment("THIS", index);
        } else if (std.mem.eql(u8, segment, "that")) {
            try self.writePushFromSegment("THAT", index);
        } else if (std.mem.eql(u8, segment, "temp")) {
            try self.writer.print("@{d}\nD=M\n@SP\nA=M\nM=D\n@SP\nM=M+1\n", .{5 + index});
        } else if (std.mem.eql(u8, segment, "pointer")) {
            const pointer_base = if (index == 0) "THIS" else "THAT";
            try self.writer.print("@{s}\nD=M\n@SP\nA=M\nM=D\n@SP\nM=M+1\n", .{pointer_base});
        } else if (std.mem.eql(u8, segment, "static")) {
            try self.writer.print("@Static.{d}\nD=M\n@SP\nA=M\nM=D\n@SP\nM=M+1\n", .{index});
        }
    }

    fn writePop(self: *CodeWriter, segment: []const u8, index: u16) !void {
        try self.writer.print("// pop {s} {d}\n", .{ segment, index });
        if (std.mem.eql(u8, segment, "local")) {
            try self.writePopToSegment("LCL", index);
        } else if (std.mem.eql(u8, segment, "argument")) {
            try self.writePopToSegment("ARG", index);
        } else if (std.mem.eql(u8, segment, "this")) {
            try self.writePopToSegment("THIS", index);
        } else if (std.mem.eql(u8, segment, "that")) {
            try self.writePopToSegment("THAT", index);
        } else if (std.mem.eql(u8, segment, "temp")) {
            try self.writer.print("@SP\nAM=M-1\nD=M\n@{d}\nM=D\n", .{5 + index});
        } else if (std.mem.eql(u8, segment, "pointer")) {
            const pointer_base = if (index == 0) "THIS" else "THAT";
            try self.writer.print("@SP\nAM=M-1\nD=M\n@{s}\nM=D\n", .{pointer_base});
        } else if (std.mem.eql(u8, segment, "static")) {
            try self.writer.print("@SP\nAM=M-1\nD=M\n@Static.{d}\nM=D\n", .{index});
        }
    }

    fn writePushFromSegment(self: *CodeWriter, base: []const u8, index: u16) !void {
        try self.writer.print("@{s}\nD=M\n@{d}\nA=D+A\nD=M\n@SP\nA=M\nM=D\n@SP\nM=M+1\n", .{ base, index });
    }

    fn writePopToSegment(self: *CodeWriter, base: []const u8, index: u16) !void {
        try self.writer.print("\n@{s}\nD=M\n@{d}\nD=D+A\n@R13\nM=D\n@SP\nAM=M-1\nD=M\n@R13\nA=M\nM=D\n", .{ base, index });
    }
};
