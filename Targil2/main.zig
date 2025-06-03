// targil 2 Ester Ben-Shabat 211950290
const std = @import("std");
const fs = std.fs;
const process = std.process;
const Parser = @import("parser.zig");
const CodeWriter = @import("code_writer.zig").CodeWriter;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var args_iter = try process.argsWithAllocator(allocator);
    defer args_iter.deinit();

    _ = args_iter.next(); // שם הקובץ עצמו
    const dir_path = args_iter.next() orelse {
        std.debug.print("Usage: zig run main.zig -- <directory_path>\n", .{});
        return;
    };

    var dir = try fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    const last_slash_index = std.mem.lastIndexOfScalar(u8, dir_path, std.fs.path.sep) orelse 0;
    const folder_name = dir_path[(last_slash_index + 1)..];
    const final_name = try std.mem.concat(allocator, u8, &[_][]const u8{ folder_name, ".asm" });

    const output_file_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, final_name });

    defer allocator.free(output_file_path);

    const output_file = try fs.cwd().createFile(output_file_path, .{ .truncate = true });
    defer output_file.close();

    var code_writer = CodeWriter.init(allocator, output_file);
    //defer code_writer.deinit();

    // בדיקה האם קיים Sys.vm
    var has_sys_vm = false;
    {
        var check_it = dir.iterate();
        while (try check_it.next()) |entry| {
            if (entry.kind == .file and std.mem.eql(u8, entry.name, "Sys.vm")) {
                has_sys_vm = true;
                break;
            }
        }
    }

    // כתיבת קוד bootstrap אם נדרש
    if (has_sys_vm) {
        try code_writer.writeBootstrap();
    }

    var it = dir.iterate();

    // הוספה
    var vm_file_count: usize = 0; // מונה קבצי VM

    while (try it.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".vm")) {
            // הוספה
            vm_file_count += 1; // הגדל את המונה

            // חילוץ שם הקובץ ללא הסיומת .vm
            const file_name_without_ext = entry.name[0..(entry.name.len - 3)];

            // עדכון שם הקובץ הנוכחי ב-CodeWriter
            try code_writer.setFileName(file_name_without_ext);

            const file = try dir.openFile(entry.name, .{});
            defer file.close();

            const stat = try file.stat();
            const buffer = try allocator.alloc(u8, stat.size);
            defer allocator.free(buffer);

            _ = try file.readAll(buffer);

            var parser = Parser.Parser.init(buffer);
            while (parser.hasMoreCommands()) {
                try parser.advance();
                try code_writer.writeCommand(&parser);
            }
        }
    }

    std.debug.print("Translation complete: {s}\n", .{output_file_path});

    // הוספה
    std.debug.print("Total VM files processed: {d}\n", .{vm_file_count});
}
