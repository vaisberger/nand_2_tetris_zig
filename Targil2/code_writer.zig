// targil 2  Ester Ben-Shabat 211950290 yael novick 211526462
const std = @import("std");
const Parser = @import("parser.zig");

pub const CodeWriter = struct {
    allocator: std.mem.Allocator,
    writer: std.fs.File.Writer,
    label_count: usize,
    current_file: []const u8, // שדה לשמירת שם הקובץ הנוכחי

    pub fn init(allocator: std.mem.Allocator, file: std.fs.File) CodeWriter {
        return CodeWriter{
            .allocator = allocator,
            .writer = file.writer(),
            .label_count = 0,
            .current_file = "Static", // ערך ברירת מחדל
        };
    }

    pub fn deinit(self: *CodeWriter) void {
        _ = self;
    }

    // פונקציה להגדרת שם הקובץ הנוכחי
    pub fn setFileName(self: *CodeWriter, filename: []const u8) !void {
        // שמירת שם הקובץ ללא עיבוד נוסף (כבר מועבר ללא סיומת)
        self.current_file = filename;
    }

    // הוספת פונקציה לכתיבת קוד האתחול
    // הוספת פונקציה לכתיבת קוד האתחול
    pub fn writeBootstrap(self: *CodeWriter) !void {
        // log:
        try self.writer.print("// Enter writeBootstrap\n", .{});

        try self.writer.writeAll("// Bootstrap code\n");
        try self.writer.writeAll("@256\nD=A\n@SP\nM=D\n");

        // קריאה ל Sys.init 0
        try self.writeCall("Sys.init", 0);

        // Since Sys.init should never return (infinite loop),
        // add safety halt after the return address
        try self.writer.writeAll("// Safety halt - should never reach here\n");
        try self.writer.writeAll("(END)\n@END\n0;JMP\n");

        // log:
        try self.writer.print("// Exit writeBootstrap\n", .{});
    }

    pub fn writeCommand(self: *CodeWriter, parser: *Parser.Parser) !void {
        switch (parser.commandType()) {
            .C_PUSH => try self.writePush(parser.arg1(), parser.arg2()),
            .C_POP => try self.writePop(parser.arg1(), parser.arg2()),
            .C_ARITHMETIC => try self.writeArithmetic(parser.arg1()),
            .C_LABEL => try self.writeLabel(parser.arg1()),
            .C_GOTO => try self.writeGoto(parser.arg1()),
            .C_IF => try self.writeIfGoto(parser.arg1()),
            .C_FUNCTION => try self.writeFunction(parser.arg1(), parser.arg2()),
            .C_CALL => try self.writeCall(parser.arg1(), parser.arg2()),
            .C_RETURN => try self.writeReturn(),
        }
    }
    fn writeArithmetic(self: *CodeWriter, command: []const u8) !void {
        // log:
        try self.writer.print("// Enter writeArithmetic\n", .{});

        // Trim whitespace and remove comments
        var trimmed_command = std.mem.trim(u8, command, " \t\r\n");

        // Find comment start and truncate if found
        if (std.mem.indexOf(u8, trimmed_command, "//")) |comment_start| {
            trimmed_command = std.mem.trim(u8, trimmed_command[0..comment_start], " \t\r\n");
        }

        try self.writer.print("// {s}\n", .{trimmed_command});

        // Debug: print command details
        try self.writer.print("// DEBUG: command='{s}', len={d}\n", .{ trimmed_command, trimmed_command.len });

        // Handle each arithmetic command explicitly
        if (std.mem.eql(u8, trimmed_command, "add")) {
            try self.writer.writeAll("@SP\nAM=M-1\nD=M\nA=A-1\nM=M+D\n");
        } else if (std.mem.eql(u8, trimmed_command, "sub")) {
            try self.writer.writeAll("@SP\nAM=M-1\nD=M\nA=A-1\nM=M-D\n");
        } else if (std.mem.eql(u8, trimmed_command, "neg")) {
            try self.writer.writeAll("@SP\nA=M-1\nM=-M\n");
        } else if (std.mem.eql(u8, trimmed_command, "and")) {
            try self.writer.writeAll("@SP\nAM=M-1\nD=M\nA=A-1\nM=M&D\n");
        } else if (std.mem.eql(u8, trimmed_command, "or")) {
            try self.writer.writeAll("@SP\nAM=M-1\nD=M\nA=A-1\nM=M|D\n");
        } else if (std.mem.eql(u8, trimmed_command, "not")) {
            try self.writer.writeAll("@SP\nA=M-1\nM=!M\n");
        } else if (std.mem.eql(u8, trimmed_command, "eq") or
            std.mem.eql(u8, trimmed_command, "gt") or
            std.mem.eql(u8, trimmed_command, "lt"))
        {
            const jump = if (std.mem.eql(u8, trimmed_command, "eq")) "JEQ" else if (std.mem.eql(u8, trimmed_command, "gt")) "JGT" else "JLT";
            const label_true = try std.fmt.allocPrint(self.allocator, "LABEL_TRUE_{d}", .{self.label_count});
            const label_end = try std.fmt.allocPrint(self.allocator, "LABEL_END_{d}", .{self.label_count});
            self.label_count += 1;
            try self.writer.print("@SP\nAM=M-1\nD=M\nA=A-1\nD=M-D\n@{s}\nD;{s}\n@SP\nA=M-1\nM=0\n@{s}\n0;JMP\n({s})\n@SP\nA=M-1\nM=-1\n({s})\n", .{ label_true, jump, label_end, label_true, label_end });
            self.allocator.free(label_true);
            self.allocator.free(label_end);
        } else {
            // Debug: unknown command
            try self.writer.print("// ERROR: Unknown arithmetic command: '{s}' (bytes: ", .{trimmed_command});
            for (trimmed_command) |byte| {
                try self.writer.print("{d} ", .{byte});
            }
            try self.writer.print(")\n", .{});
        }

        try self.writer.print("// Exit writeArithmetic\n", .{});
    }
    fn writePush(self: *CodeWriter, segment: []const u8, index: u16) !void {
        // log:
        try self.writer.print("// Enter writePush\n", .{});

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
            try self.writer.print("@{s}.{d}\nD=M\n@SP\nA=M\nM=D\n@SP\nM=M+1\n", .{ self.current_file, index });
        }

        // log:
        try self.writer.print("// Exit writePush\n", .{});
    }

    fn writePop(self: *CodeWriter, segment: []const u8, index: u16) !void {
        // log:
        try self.writer.print("// Enter writePop\n", .{});

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
            try self.writer.print("@SP\nAM=M-1\nD=M\n@{s}.{d}\nM=D\n", .{ self.current_file, index });
        }

        // log:
        try self.writer.print("// Exit writePop\n", .{});
    }

    fn writePushFromSegment(self: *CodeWriter, base: []const u8, index: u16) !void {
        // log:
        try self.writer.print("// Enter writePushFromSegment\n", .{});

        try self.writer.print("@{s}\nD=M\n@{d}\nA=D+A\nD=M\n@SP\nA=M\nM=D\n@SP\nM=M+1\n", .{ base, index });

        // log:
        try self.writer.print("// Exit writePushFromSegment\n", .{});
    }

    fn writePopToSegment(self: *CodeWriter, base: []const u8, index: u16) !void {
        try self.writer.print("// Enter writePopToSegment\n", .{});

        // גישה ישירה במקום שימוש ב-R13
        try self.writer.print("@SP\nAM=M-1\nD=M\n@{s}\nA=M\n", .{base});

        // התקדמות לאינדקס הרצוי
        var i: u16 = 0;
        while (i < index) : (i += 1) {
            try self.writer.writeAll("A=A+1\n");
        }

        try self.writer.writeAll("M=D\n");
        try self.writer.print("// Exit writePopToSegment\n", .{});
    }

    fn writeLabel(self: *CodeWriter, label: []const u8) !void {
        try self.writer.print("// Enter writeLabel\n", .{});
        try self.writer.print("// label {s}\n", .{label});

        // תמיד להוסיף את שם הקובץ הנוכחי כקידומת לתווית
        // אלא אם כן התווית כבר מכילה נקודה (כלומר שם קובץ)
        if (std.mem.indexOf(u8, label, ".") != null) {
            // התווית כבר מכילה שם קובץ
            try self.writer.print("({s})\n", .{label});
        } else {
            // הוסף את שם הקובץ הנוכחי כקידומת
            try self.writer.print("({s}.{s})\n", .{ self.current_file, label });
        }

        try self.writer.print("// Exit writeLabel\n", .{});
    }

    fn writeGoto(self: *CodeWriter, label: []const u8) !void {
        // log:
        try self.writer.print("// Enter writeGoto\n", .{});

        try self.writer.print("// goto {s}\n", .{label});

        // תמיד להוסיף את שם הקובץ הנוכחי כקידומת לתווית
        // אלא אם כן התווית כבר מכילה נקודה (כלומר שם קובץ)
        if (std.mem.indexOf(u8, label, ".") != null) {
            // התווית כבר מכילה שם קובץ
            try self.writer.print("@{s}\n0;JMP\n", .{label});
        } else {
            // הוסף את שם הקובץ הנוכחי כקידומת
            try self.writer.print("@{s}.{s}\n0;JMP\n", .{ self.current_file, label });
        }

        // log:
        try self.writer.print("// Exit writeGoto\n", .{});
    }

    fn writeIfGoto(self: *CodeWriter, label: []const u8) !void {
        // log:
        try self.writer.print("// Enter writeIfGoto\n", .{});

        try self.writer.print("// if-goto {s}\n", .{label});
        try self.writer.writeAll("@SP\nAM=M-1\nD=M\n"); // Pop the top value from the stack

        // תמיד להוסיף את שם הקובץ הנוכחי כקידומת לתווית
        // אלא אם כן התווית כבר מכילה נקודה (כלומר שם קובץ)
        if (std.mem.indexOf(u8, label, ".") != null) {
            // התווית כבר מכילה שם קובץ
            try self.writer.print("@{s}\nD;JNE\n", .{label});
        } else {
            // הוסף את שם הקובץ הנוכחי כקידומת
            try self.writer.print("@{s}.{s}\nD;JNE\n", .{ self.current_file, label });
        }

        // log:
        try self.writer.print("// Exit writeIfGoto\n", .{});
    }

    fn writeFunction(self: *CodeWriter, functionName: []const u8, numLocals: u16) !void {
        // log:
        try self.writer.print("// Enter writeFunction\n", .{});

        try self.writer.print("// function {s} {d}\n", .{ functionName, numLocals });
        try self.writer.print("({s})\n", .{functionName});

        // אתחול משתנים לוקליים
        var i: u16 = 0;
        while (i < numLocals) : (i += 1) {
            try self.writer.writeAll("@0\nD=A\n@SP\nA=M\nM=D\n@SP\nM=M+1\n");
        }

        // log:
        try self.writer.print("// Exit writeFunction\n", .{});
    }

    fn writeCall(self: *CodeWriter, functionName: []const u8, numArgs: u16) !void {
        // log:
        try self.writer.print("// Enter writeCall\n", .{});

        // יצירת תווית חזרה ייחודית עם שם הפונקציה ומזהה ייחודי
        const returnLabel = try std.fmt.allocPrint(self.allocator, "{s}.ReturnAddress{d}", .{ functionName, self.label_count });
        defer self.allocator.free(returnLabel);
        self.label_count += 1;

        try self.writer.print("// call {s} {d}\n", .{ functionName, numArgs });

        // Push return address
        try self.writer.print("@{s}\nD=A\n@SP\nA=M\nM=D\n@SP\nM=M+1\n", .{returnLabel});

        // Push LCL, ARG, THIS, THAT
        for ([_][]const u8{ "LCL", "ARG", "THIS", "THAT" }) |segment| {
            try self.writer.print("@{s}\nD=M\n@SP\nA=M\nM=D\n@SP\nM=M+1\n", .{segment});
        }

        // ARG = SP - numArgs - 5
        try self.writer.print("@SP\nD=M\n@{d}\nD=D-A\n@5\nD=D-A\n@ARG\nM=D\n", .{numArgs});

        // LCL = SP
        try self.writer.writeAll("@SP\nD=M\n@LCL\nM=D\n");

        // goto functionName
        try self.writer.print("@{s}\n0;JMP\n", .{functionName});

        // (returnLabel)
        try self.writer.print("({s})\n", .{returnLabel});

        // log:
        try self.writer.print("// Exit writeCall\n", .{});
    }

    fn writeReturn(self: *CodeWriter) !void {
        try self.writer.print("// Enter writeReturn\n", .{});
        try self.writer.print("// return\n", .{});

        // FRAME = LCL
        try self.writer.writeAll("@LCL\nD=M\n");

        // RET = *(FRAME - 5), שמירה ישירה בכתובת 13
        try self.writer.writeAll("@5\nA=D-A\nD=M\n@13\nM=D\n");

        // *ARG = pop()
        try self.writer.writeAll("@SP\nA=M-1\nD=M\n@ARG\nA=M\nM=D\n@SP\nM=M-1\n");

        // SP = ARG + 1
        try self.writer.writeAll("@ARG\nD=M\n@SP\nM=D+1\n");

        // שחזור רגיסטרים בשיטה של הקובץ שעובד
        try self.writer.writeAll("@LCL\nM=M-1\nA=M\nD=M\n@THAT\nM=D\n");
        try self.writer.writeAll("@LCL\nM=M-1\nA=M\nD=M\n@THIS\nM=D\n");
        try self.writer.writeAll("@LCL\nM=M-1\nA=M\nD=M\n@ARG\nM=D\n");
        try self.writer.writeAll("@LCL\nM=M-1\nA=M\nD=M\n@LCL\nM=D\n");

        // קפיצה לכתובת החזרה
        try self.writer.writeAll("@13\nA=M\n0;JMP\n");

        try self.writer.print("// Exit writeReturn\n", .{});
    }
};
