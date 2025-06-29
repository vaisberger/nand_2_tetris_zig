const std = @import("std");
const Allocator = std.mem.Allocator;

// Symbol kinds as specified in the requirements
pub const SymbolKind = enum {
    static, // Class-level static variables
    field, // Class-level instance fields
    argument, // Function/method parameters
    local, // Local variables (var/local)

    pub fn toString(self: SymbolKind) []const u8 {
        return switch (self) {
            .static => "static",
            .field => "field",
            .argument => "argument",
            .local => "local",
        };
    }
};

// Individual symbol entry
pub const Symbol = struct {
    name: []const u8, // Variable name as written in JACK
    type: []const u8, // int, String, MyClass, etc.
    kind: SymbolKind, // static, field, argument, var
    index: u16, // Index within its kind (starts from 0)

    pub fn init(name: []const u8, symbol_type: []const u8, kind: SymbolKind, index: u16) Symbol {
        return Symbol{
            .name = name,
            .type = symbol_type,
            .kind = kind,
            .index = index,
        };
    }
};

// Main Symbol Table implementation
pub const SymbolTable = struct {
    // Two separate tables as specified
    class_scope: std.StringHashMap(Symbol), // For static and field variables
    method_scope: std.StringHashMap(Symbol), // For argument and local variables

    allocator: Allocator,

    // Separate counters for each kind within each scope
    // Class scope counters
    static_count: u16,
    field_count: u16,

    // Method scope counters (reset for each method)
    argument_count: u16,
    local_count: u16,

    // Current class name (needed for 'this' parameter in methods)
    current_class_name: ?[]const u8,

    pub fn init(allocator: Allocator) SymbolTable {
        return SymbolTable{
            .class_scope = std.StringHashMap(Symbol).init(allocator),
            .method_scope = std.StringHashMap(Symbol).init(allocator),
            .allocator = allocator,
            .static_count = 0,
            .field_count = 0,
            .argument_count = 0,
            .local_count = 0,
            .current_class_name = null,
        };
    }

    pub fn deinit(self: *SymbolTable) void {
        self.class_scope.deinit();
        self.method_scope.deinit();
    }

    // Start a new class - reset class scope table
    pub fn startClass(self: *SymbolTable, class_name: []const u8) void {
        self.class_scope.clearAndFree();
        self.static_count = 0;
        self.field_count = 0;
        self.current_class_name = class_name;
    }

    // Start a new subroutine - reset method scope table
    pub fn startSubroutine(self: *SymbolTable, subroutine_type: SubroutineType) !void {
        self.method_scope.clearAndFree();
        self.argument_count = 0;
        self.local_count = 0;

        // For methods only: add 'this' as first argument (index 0)
        if (subroutine_type == .method) {
            if (self.current_class_name) |class_name| {
                const this_symbol = Symbol.init("this", class_name, .argument, 0);
                try self.method_scope.put("this", this_symbol);
                self.argument_count = 1; // Start from 1 for other arguments
            }
        }
    }

    // Define a new symbol
    pub fn define(self: *SymbolTable, name: []const u8, symbol_type: []const u8, kind: SymbolKind) !void {
        // Check if symbol already exists in current scope
        switch (kind) {
            .static, .field => {
                if (self.class_scope.contains(name)) {
                    return error.SymbolAlreadyDefined;
                }
            },
            .argument, .local => {
                if (self.method_scope.contains(name)) {
                    return error.SymbolAlreadyDefined;
                }
            },
        }
        const index = switch (kind) {
            .static => blk: {
                const idx = self.static_count;
                self.static_count += 1;
                break :blk idx;
            },
            .field => blk: {
                const idx = self.field_count;
                self.field_count += 1;
                break :blk idx;
            },
            .argument => blk: {
                const idx = self.argument_count;
                self.argument_count += 1;
                break :blk idx;
            },
            .local => blk: {
                const idx = self.local_count;
                self.local_count += 1;
                break :blk idx;
            },
        };

        const symbol = Symbol.init(name, symbol_type, kind, index);

        // Add to appropriate scope table
        switch (kind) {
            .static, .field => try self.class_scope.put(name, symbol),
            .argument, .local => try self.method_scope.put(name, symbol),
        }
    }

    // Look up a symbol by name (searches both scopes)
    pub fn lookup(self: *SymbolTable, name: []const u8) ?Symbol {
        // First check method scope (local variables have precedence)
        if (self.method_scope.get(name)) |symbol| {
            return symbol;
        }

        // Then check class scope
        if (self.class_scope.get(name)) |symbol| {
            return symbol;
        }

        return null;
    }

    // Check if symbol exists in any scope
    pub fn contains(self: *SymbolTable, name: []const u8) bool {
        return self.lookup(name) != null;
    }

    // Get count of symbols of a specific kind
    pub fn varCount(self: *SymbolTable, kind: SymbolKind) u16 {
        return switch (kind) {
            .static => self.static_count,
            .field => self.field_count,
            .argument => self.argument_count,
            .local => self.local_count,
        };
    }

    // Get the kind of a symbol
    pub fn kindOf(self: *SymbolTable, name: []const u8) ?SymbolKind {
        if (self.lookup(name)) |symbol| {
            return symbol.kind;
        }
        return null;
    }

    // Get the type of a symbol
    pub fn typeOf(self: *SymbolTable, name: []const u8) ?[]const u8 {
        if (self.lookup(name)) |symbol| {
            return symbol.type;
        }
        return null;
    }

    // Get the index of a symbol
    pub fn indexOf(self: *SymbolTable, name: []const u8) ?u16 {
        if (self.lookup(name)) |symbol| {
            return symbol.index;
        }
        return null;
    }

    // Debug: print all symbols in both scopes
    pub fn debugPrint(self: *SymbolTable) void {
        std.debug.print("\n=== Symbol Table Debug ===\n");
        std.debug.print("Class Scope:\n");
        var class_iter = self.class_scope.iterator();
        while (class_iter.next()) |entry| {
            const symbol = entry.value_ptr.*;
            std.debug.print("  {s}: {s} {s} {d}\n", .{ symbol.name, symbol.type, symbol.kind.toString(), symbol.index });
        }

        std.debug.print("Method Scope:\n");
        var method_iter = self.method_scope.iterator();
        while (method_iter.next()) |entry| {
            const symbol = entry.value_ptr.*;
            std.debug.print("  {s}: {s} {s} {d}\n", .{ symbol.name, symbol.type, symbol.kind.toString(), symbol.index });
        }
        std.debug.print("=========================\n");
    }
};

// Helper enum for subroutine types
pub const SubroutineType = enum {
    constructor,
    function,
    method,
};

pub fn getVMSegment(self: *SymbolTable, name: []const u8) ?[]const u8 {
    if (self.lookup(name)) |symbol| {
        return switch (symbol.kind) {
            .static => "static",
            .field => "this",
            .argument => "argument",
            .local => "local",
        };
    }
    return null;
}
