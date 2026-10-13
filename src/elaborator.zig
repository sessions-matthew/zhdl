const std = @import("std");
const builtin = @import("builtin");
const ArrayList = std.array_list.Managed;
const ast = @import("ast.zig");
const hir = @import("hir.zig");
const TokenType = @import("token.zig").TokenType;
const parser_mod = @import("parser.zig");

pub const ImportedPackage = struct {
    name: []const u8,
    path: []const u8,
    modules: std.StringHashMap(ast.Decl),
    generic_modules: std.StringHashMap(ast.FnDecl),
    types: std.StringHashMap(hir.HirType),
    constants: std.StringHashMap(u64),
    fn_decls: std.StringHashMap(ast.FnDecl),
};

pub const LoadedFile = struct {
    canonical_path: []const u8,
    source: []const u8,
    ast_tree: ast.AST,
    is_virtual: bool,
};

pub const Elaborator = struct {
    allocator: std.mem.Allocator,
    ast_tree: *const ast.AST,
    types: std.StringHashMap(hir.HirType),
    constants: std.StringHashMap(u64),
    allocated_struct_fields: ArrayList([]hir.HirStructField),
    allocated_union_fields: ArrayList([]hir.HirUnionField),
    allocated_enum_variants: ArrayList([]hir.HirEnumVariant),
    enum_variants: std.StringHashMap(u64),
    fn_decls: std.StringHashMap(ast.FnDecl),
    type_methods: std.StringHashMap(std.StringHashMap(ast.FnDecl)),
    param_env: ?*std.StringHashMap(*hir.HirExpr) = null,
    specialized_modules: std.StringHashMap(void),
    module_foreign_names: std.StringHashMap([]const u8),
    external_sources: std.StringHashMap(void),

    // Multi-file @import state
    io: ?std.Io = null,
    base_dir: ?[]const u8 = null,
    virtual_files: ?*const std.StringHashMap([]const u8) = null,
    packages: std.StringHashMap(*ImportedPackage),
    all_packages: ArrayList(*ImportedPackage),
    loaded_files: std.StringHashMap(LoadedFile),
    loaded_trees: ArrayList(ast.AST),
    loaded_sources: ArrayList([]const u8),
    loading_stack: ArrayList([]const u8),
    all_module_decls: std.StringHashMap(ast.Decl),
    str_arena: std.heap.ArenaAllocator,

    // Active elaboration state for dynamic register/signal injection (e.g. @sync2ff)
    active_registers: ?*ArrayList(hir.HirRegister) = null,
    active_local_signals: ?*ArrayList(hir.HirSignal) = null,
    active_comb_stmts: ?*ArrayList(hir.HirStatement) = null,
    active_reg_map: ?*std.StringHashMap(hir.HirRegister) = null,
    active_signal_types: ?*std.StringHashMap(hir.HirType) = null,
    next_sync_id: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, ast_tree: *const ast.AST) Elaborator {
        return .{
            .allocator = allocator,
            .ast_tree = ast_tree,
            .types = std.StringHashMap(hir.HirType).init(allocator),
            .constants = std.StringHashMap(u64).init(allocator),
            .allocated_struct_fields = ArrayList([]hir.HirStructField).init(allocator),
            .allocated_union_fields = ArrayList([]hir.HirUnionField).init(allocator),
            .allocated_enum_variants = ArrayList([]hir.HirEnumVariant).init(allocator),
            .enum_variants = std.StringHashMap(u64).init(allocator),
            .fn_decls = std.StringHashMap(ast.FnDecl).init(allocator),
            .type_methods = std.StringHashMap(std.StringHashMap(ast.FnDecl)).init(allocator),
            .specialized_modules = std.StringHashMap(void).init(allocator),
            .module_foreign_names = std.StringHashMap([]const u8).init(allocator),
            .external_sources = std.StringHashMap(void).init(allocator),
            .packages = std.StringHashMap(*ImportedPackage).init(allocator),
            .all_packages = ArrayList(*ImportedPackage).init(allocator),
            .loaded_files = std.StringHashMap(LoadedFile).init(allocator),
            .loaded_trees = ArrayList(ast.AST).init(allocator),
            .loaded_sources = ArrayList([]const u8).init(allocator),
            .loading_stack = ArrayList([]const u8).init(allocator),
            .all_module_decls = std.StringHashMap(ast.Decl).init(allocator),
            .str_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Elaborator) void {
        for (self.allocated_struct_fields.items) |sf| {
            self.allocator.free(sf);
        }
        self.allocated_struct_fields.deinit();
        for (self.allocated_union_fields.items) |uf| {
            self.allocator.free(uf);
        }
        self.allocated_union_fields.deinit();
        for (self.allocated_enum_variants.items) |ev| {
            self.allocator.free(ev);
        }
        self.allocated_enum_variants.deinit();
        self.enum_variants.deinit();
        var tit = self.type_methods.valueIterator();
        while (tit.next()) |m_map| {
            m_map.deinit();
        }
        self.type_methods.deinit();
        self.specialized_modules.deinit();
        self.module_foreign_names.deinit();
        self.external_sources.deinit();
        self.fn_decls.deinit();
        self.types.deinit();
        self.constants.deinit();

        for (self.loaded_trees.items) |*t| {
            t.deinit();
        }
        self.loaded_trees.deinit();
        for (self.loaded_sources.items) |s| {
            self.allocator.free(s);
        }
        self.loaded_sources.deinit();
        var lf_it = self.loaded_files.valueIterator();
        while (lf_it.next()) |lf| {
            self.allocator.free(lf.canonical_path);
        }
        self.loaded_files.deinit();
        self.loading_stack.deinit();
        for (self.all_packages.items) |pkg_ptr| {
            self.allocator.free(pkg_ptr.name);
            self.allocator.free(pkg_ptr.path);
            pkg_ptr.modules.deinit();
            pkg_ptr.generic_modules.deinit();
            pkg_ptr.types.deinit();
            pkg_ptr.constants.deinit();
            pkg_ptr.fn_decls.deinit();
            self.allocator.destroy(pkg_ptr);
        }
        self.all_packages.deinit();
        self.packages.deinit();
        self.all_module_decls.deinit();
        self.str_arena.deinit();
    }

    pub fn setIo(self: *Elaborator, io: std.Io) void {
        self.io = io;
    }

    pub fn setBaseDir(self: *Elaborator, dir: []const u8) void {
        self.base_dir = dir;
    }

    pub fn setVirtualFiles(self: *Elaborator, vfiles: *const std.StringHashMap([]const u8)) void {
        self.virtual_files = vfiles;
    }

    fn isModuleElaborated(self: *Elaborator, modules: *ArrayList(hir.HirModule), name: []const u8) bool {
        _ = self;
        for (modules.items) |m| {
            if (std.mem.eql(u8, m.name, name)) return true;
            if (m.foreign_name) |fnm| {
                if (std.mem.eql(u8, fnm, name)) return true;
            }
        }
        return false;
    }

    fn findModuleDecl(self: *Elaborator, name: []const u8) ?ast.Decl {
        if (self.all_module_decls.get(name)) |d| return d;
        for (self.ast_tree.decls) |d| {
            if (d.tag == .module_decl and std.mem.eql(u8, d.data.module_decl.name, name)) {
                return d;
            }
        }
        return null;
    }

    fn resolvePath(self: *Elaborator, alloc: std.mem.Allocator, import_path: []const u8, current_dir: ?[]const u8) ![]const u8 {
        _ = self;
        if (std.fs.path.isAbsolute(import_path)) {
            return try alloc.dupe(u8, import_path);
        }
        if (current_dir) |dir| {
            if (dir.len > 0 and !std.mem.eql(u8, dir, ".")) {
                return try std.fs.path.join(alloc, &.{ dir, import_path });
            }
        }
        return try alloc.dupe(u8, import_path);
    }

    fn readFileContent(self: *Elaborator, path: []const u8) !struct { content: []const u8, is_virtual: bool } {
        if (self.virtual_files) |vf| {
            if (vf.get(path)) |v_src| {
                return .{ .content = v_src, .is_virtual = true };
            }
            const base = std.fs.path.basename(path);
            if (vf.get(base)) |v_src| {
                return .{ .content = v_src, .is_virtual = true };
            }
        }

        if (self.io) |io| {
            const cwd = std.Io.Dir.cwd();
            const content = cwd.readFileAlloc(io, path, self.allocator, .unlimited) catch |err| {
                std.debug.print(
                    \\
                    \\======================================================================
                    \\COMPILE ERROR: Cannot Open Imported File '{s}'
                    \\======================================================================
                    \\Failed to open file: {s}
                    \\======================================================================
                    \\
                , .{ path, @errorName(err) });
                return error.FileNotFound;
            };
            return .{ .content = content, .is_virtual = false };
        }

        if (builtin.is_test) {
            const cwd = std.Io.Dir.cwd();
            const content = cwd.readFileAlloc(std.testing.io, path, self.allocator, .unlimited) catch |err| {
                std.debug.print(
                    \\
                    \\======================================================================
                    \\COMPILE ERROR: Cannot Open Imported File '{s}'
                    \\======================================================================
                    \\Failed to open file: {s}
                    \\======================================================================
                    \\
                , .{ path, @errorName(err) });
                return error.FileNotFound;
            };
            return .{ .content = content, .is_virtual = false };
        }

        return error.FileNotFound;
    }

    fn exprToDottedString(alloc: std.mem.Allocator, expr: *const ast.Expr) ?[]const u8 {
        switch (expr.tag) {
            .identifier => return alloc.dupe(u8, expr.data.identifier) catch null,
            .member_access => {
                const ma = expr.data.member_access;
                const parent = exprToDottedString(alloc, ma.target) orelse return null;
                defer alloc.free(parent);
                return std.fmt.allocPrint(alloc, "{s}.{s}", .{ parent, ma.field }) catch null;
            },
            else => return null,
        }
    }

    fn aliasPackageMember(
        self: *Elaborator,
        pkg: *const ImportedPackage,
        member_name: []const u8,
        alias_name: []const u8,
        module_ports: ?*std.StringHashMap([]hir.HirPort),
        alloc: std.mem.Allocator,
    ) !void {
        _ = alloc;
        if (pkg.modules.get(member_name)) |md| {
            try self.all_module_decls.put(alias_name, md);
            if (module_ports) |mp| {
                if (mp.get(member_name)) |ports| {
                    try mp.put(alias_name, ports);
                }
            }
            return;
        }
        if (pkg.generic_modules.get(member_name)) |fd| {
            try self.fn_decls.put(alias_name, fd);
            return;
        }
        if (pkg.types.get(member_name)) |ht| {
            var alias_ht = ht;
            alias_ht.name = alias_name;
            try self.types.put(alias_name, alias_ht);
            if (self.type_methods.get(member_name)) |methods| {
                try self.type_methods.put(alias_name, methods);
            }
            return;
        }
        if (pkg.constants.get(member_name)) |val| {
            try self.constants.put(alias_name, val);
            return;
        }
        if (pkg.fn_decls.get(member_name)) |fd| {
            try self.fn_decls.put(alias_name, fd);
            return;
        }
        const full_sub_ns = std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ pkg.name, member_name }) catch return;
        defer self.allocator.free(full_sub_ns);
        if (self.packages.get(full_sub_ns)) |sub_pkg| {
            try self.packages.put(alias_name, sub_pkg);
            return;
        }
        if (self.constants.get(full_sub_ns)) |val| {
            try self.constants.put(alias_name, val);
            return;
        }
        if (self.enum_variants.get(full_sub_ns)) |val| {
            try self.constants.put(alias_name, val);
            return;
        }
    }

    fn processConstDeclForImport(
        self: *Elaborator,
        name: []const u8,
        val: *ast.Expr,
        current_dir: ?[]const u8,
        module_ports: ?*std.StringHashMap([]hir.HirPort),
        alloc: std.mem.Allocator,
    ) !bool {
        if (val.tag == .builtin_call and val.data.builtin_call.tag == .builtin_import) {
            if (val.data.builtin_call.args.len > 0 and val.data.builtin_call.args[0].tag == .string) {
                const import_path = val.data.builtin_call.args[0].data.string;
                _ = try self.loadImport(import_path, name, current_dir, module_ports, alloc);
                return true;
            }
        }

        if (val.tag == .member_access) {
            const ma = val.data.member_access;
            if (ma.target.tag == .builtin_call and ma.target.data.builtin_call.tag == .builtin_import) {
                if (ma.target.data.builtin_call.args.len > 0 and ma.target.data.builtin_call.args[0].tag == .string) {
                    const import_path = ma.target.data.builtin_call.args[0].data.string;
                    const pkg = try self.loadImport(import_path, null, current_dir, module_ports, alloc);
                    try self.aliasPackageMember(pkg, ma.field, name, module_ports, alloc);
                    return true;
                }
            } else {
                if (exprToDottedString(self.allocator, ma.target)) |pkg_id| {
                    defer self.allocator.free(pkg_id);
                    if (self.packages.get(pkg_id)) |pkg| {
                        try self.aliasPackageMember(pkg, ma.field, name, module_ports, alloc);
                        return true;
                    }
                }
                if (exprToDottedString(self.allocator, val)) |dotted| {
                    defer self.allocator.free(dotted);
                    if (self.constants.get(dotted)) |c_val| {
                        try self.constants.put(name, c_val);
                        return true;
                    }
                    if (self.enum_variants.get(dotted)) |v_val| {
                        try self.constants.put(name, v_val);
                        return true;
                    }
                }
            }
        }

        return false;
    }

    fn extractAndRegisterModulePorts(
        self: *Elaborator,
        items: []const ast.ModuleItem,
        short_name: []const u8,
        full_name: ?[]const u8,
        mp: *std.StringHashMap([]hir.HirPort),
        alloc: std.mem.Allocator,
    ) !void {
        var mports = ArrayList(hir.HirPort).init(alloc);
        for (items) |item| {
            if (item.tag == .port) {
                const p = item.data.port;
                const h_type = try self.lowerType(p.type_expr);
                try mports.append(.{
                    .name = p.name,
                    .dir = switch (p.dir) {
                        .in => .in,
                        .out => .out,
                        .inout => .inout,
                    },
                    .hir_type = h_type,
                });
            }
        }
        const owned_ports = try mports.toOwnedSlice();
        try mp.put(short_name, owned_ports);
        if (full_name) |fnm| {
            try mp.put(fnm, owned_ports);
        }
    }

    fn registerTypeConstantsAndVariants(self: *Elaborator, type_name: []const u8, te: *ast.Type) !void {
        const str_alloc = self.str_arena.allocator();
        if (te.tag == .enum_type) {
            var cur_val: u64 = 0;
            for (te.data.enum_type.fields) |f| {
                if (f.value) |v| {
                    cur_val = self.evalConst(v);
                }
                const full_var = try std.fmt.allocPrint(str_alloc, "{s}.{s}", .{ type_name, f.name });
                try self.enum_variants.put(full_var, cur_val);
                cur_val += 1;
            }
            for (te.data.enum_type.constants) |cd| {
                if (cd.tag == .const_decl) {
                    const c = cd.data.const_decl;
                    const val = self.evalConst(c.val);
                    try self.constants.put(c.name, val);
                    const full_c = try std.fmt.allocPrint(str_alloc, "{s}.{s}", .{ type_name, c.name });
                    try self.constants.put(full_c, val);
                }
            }
        } else if (te.tag == .packed_struct) {
            for (te.data.packed_struct.constants) |cd| {
                if (cd.tag == .const_decl) {
                    const c = cd.data.const_decl;
                    const val = self.evalConst(c.val);
                    try self.constants.put(c.name, val);
                    const full_c = try std.fmt.allocPrint(str_alloc, "{s}.{s}", .{ type_name, c.name });
                    try self.constants.put(full_c, val);
                }
            }
        } else if (te.tag == .tagged_union) {
            for (te.data.tagged_union.constants) |cd| {
                if (cd.tag == .const_decl) {
                    const c = cd.data.const_decl;
                    const val = self.evalConst(c.val);
                    try self.constants.put(c.name, val);
                    const full_c = try std.fmt.allocPrint(str_alloc, "{s}.{s}", .{ type_name, c.name });
                    try self.constants.put(full_c, val);
                }
            }
        }
    }

    fn registerTypeMethods(self: *Elaborator, type_name: []const u8, te: *ast.Type) !void {
        if (te.tag == .packed_struct) {
            var m_map = std.StringHashMap(ast.FnDecl).init(self.allocator);
            for (te.data.packed_struct.methods) |m| {
                try m_map.put(m.name, m);
            }
            try self.type_methods.put(type_name, m_map);
        } else if (te.tag == .tagged_union) {
            var m_map = std.StringHashMap(ast.FnDecl).init(self.allocator);
            for (te.data.tagged_union.methods) |m| {
                try m_map.put(m.name, m);
            }
            try self.type_methods.put(type_name, m_map);
        } else if (te.tag == .enum_type) {
            var m_map = std.StringHashMap(ast.FnDecl).init(self.allocator);
            for (te.data.enum_type.methods) |m| {
                try m_map.put(m.name, m);
            }
            try self.type_methods.put(type_name, m_map);
        }
    }

    fn registerNamespace(
        self: *Elaborator,
        ns_name: []const u8,
        decls: []const ast.Decl,
        module_ports: ?*std.StringHashMap([]hir.HirPort),
        alloc: std.mem.Allocator,
    ) anyerror!*ImportedPackage {
        const str_alloc = self.str_arena.allocator();
        const pkg = try self.allocator.create(ImportedPackage);
        pkg.* = .{
            .name = try self.allocator.dupe(u8, ns_name),
            .path = try self.allocator.dupe(u8, ns_name),
            .modules = std.StringHashMap(ast.Decl).init(self.allocator),
            .generic_modules = std.StringHashMap(ast.FnDecl).init(self.allocator),
            .types = std.StringHashMap(hir.HirType).init(self.allocator),
            .constants = std.StringHashMap(u64).init(self.allocator),
            .fn_decls = std.StringHashMap(ast.FnDecl).init(self.allocator),
        };
        try self.all_packages.append(pkg);
        try self.packages.put(pkg.name, pkg);

        // Pre-scan imports & aliases inside the namespace
        for (decls) |decl| {
            if (decl.tag == .const_decl) {
                _ = try self.processConstDeclForImport(decl.data.const_decl.name, decl.data.const_decl.val, null, module_ports, alloc);
            }
        }

        // First pass: sub-namespaces, types, constants
        for (decls) |decl| {
            if (decl.tag == .const_decl) {
                const c = decl.data.const_decl;
                if (c.val.tag == .type_expr and c.val.data.type_expr.tag == .struct_type) {
                    const full_sub_ns = try std.fmt.allocPrint(str_alloc, "{s}.{s}", .{ ns_name, c.name });
                    _ = try self.registerNamespace(full_sub_ns, c.val.data.type_expr.data.struct_type.decls, module_ports, alloc);
                } else if (c.val.tag == .type_expr) {
                    var h_type = try self.lowerType(c.val.data.type_expr);
                    h_type.name = c.name;
                    try pkg.types.put(c.name, h_type);
                    try self.registerTypeMethods(c.name, c.val.data.type_expr);
                    try self.registerTypeConstantsAndVariants(c.name, c.val.data.type_expr);

                    const full_id = try std.fmt.allocPrint(str_alloc, "{s}.{s}", .{ ns_name, c.name });
                    var h_type_namespaced = h_type;
                    h_type_namespaced.name = full_id;
                    try self.types.put(full_id, h_type_namespaced);
                    try self.types.put(c.name, h_type);
                    try self.registerTypeMethods(full_id, c.val.data.type_expr);
                    try self.registerTypeConstantsAndVariants(full_id, c.val.data.type_expr);
                } else if (c.val.tag == .number) {
                    const val = c.val.data.number.val;
                    try pkg.constants.put(c.name, val);
                    const full_id = try std.fmt.allocPrint(str_alloc, "{s}.{s}", .{ ns_name, c.name });
                    try self.constants.put(full_id, val);
                } else if (c.val.tag != .module_literal and c.val.tag != .member_access) {
                    const val = self.evalConst(c.val);
                    try pkg.constants.put(c.name, val);
                    const full_id = try std.fmt.allocPrint(str_alloc, "{s}.{s}", .{ ns_name, c.name });
                    try self.constants.put(full_id, val);
                }
            }
        }

        // Second pass: modules, generic functions, helper functions
        for (decls) |decl| {
            if (decl.tag == .const_decl) {
                const c = decl.data.const_decl;
                if (c.val.tag == .module_literal) {
                    const mod_decl = ast.Decl{
                        .tag = .module_decl,
                        .is_pub = decl.is_pub,
                        .loc = decl.loc,
                        .data = .{
                            .module_decl = .{
                                .name = c.name,
                                .params = c.val.data.module_literal.params,
                                .items = c.val.data.module_literal.items,
                                .is_extern = c.val.data.module_literal.is_extern,
                                .foreign_name = c.val.data.module_literal.foreign_name,
                                .include_path = c.val.data.module_literal.include_path,
                            },
                        },
                    };
                    try pkg.modules.put(c.name, mod_decl);
                    try self.all_module_decls.put(c.name, mod_decl);
                    const full_id = try std.fmt.allocPrint(str_alloc, "{s}.{s}", .{ ns_name, c.name });
                    try self.all_module_decls.put(full_id, mod_decl);
                    if (module_ports) |mp| {
                        try self.extractAndRegisterModulePorts(c.val.data.module_literal.items, c.name, full_id, mp, alloc);
                    }
                }
            } else if (decl.tag == .module_decl) {
                const md = decl.data.module_decl;
                try pkg.modules.put(md.name, decl);
                try self.all_module_decls.put(md.name, decl);
                const full_id = try std.fmt.allocPrint(str_alloc, "{s}.{s}", .{ ns_name, md.name });
                try self.all_module_decls.put(full_id, decl);
                if (module_ports) |mp| {
                    try self.extractAndRegisterModulePorts(md.items, md.name, full_id, mp, alloc);
                }
            } else if (decl.tag == .fn_decl) {
                const fd = decl.data.fn_decl;
                if (fd.body_expr.tag == .module_literal) {
                    try pkg.generic_modules.put(fd.name, fd);
                    try self.fn_decls.put(fd.name, fd);
                    const full_id = try std.fmt.allocPrint(str_alloc, "{s}.{s}", .{ ns_name, fd.name });
                    try self.fn_decls.put(full_id, fd);
                } else {
                    try pkg.fn_decls.put(fd.name, fd);
                    try self.fn_decls.put(fd.name, fd);
                    const full_id = try std.fmt.allocPrint(str_alloc, "{s}.{s}", .{ ns_name, fd.name });
                    try self.fn_decls.put(full_id, fd);
                }
            }
        }

        return pkg;
    }

    fn loadImport(
        self: *Elaborator,
        import_path: []const u8,
        pkg_name: ?[]const u8,
        current_dir: ?[]const u8,
        module_ports: ?*std.StringHashMap([]hir.HirPort),
        alloc: std.mem.Allocator,
    ) anyerror!*ImportedPackage {
        const full_path = try self.resolvePath(self.allocator, import_path, current_dir orelse self.base_dir);
        defer self.allocator.free(full_path);

        if (pkg_name) |pname| {
            if (self.packages.get(pname)) |existing_pkg| {
                return existing_pkg;
            }
        }
        if (self.packages.get(full_path)) |existing_pkg| {
            if (pkg_name) |pname| {
                try self.packages.put(pname, existing_pkg);
            }
            return existing_pkg;
        }

        for (self.loading_stack.items) |stk_path| {
            if (std.mem.eql(u8, stk_path, full_path) or (pkg_name != null and std.mem.eql(u8, stk_path, pkg_name.?))) {
                std.debug.print(
                    \\
                    \\======================================================================
                    \\COMPILE ERROR: Circular @import Detected
                    \\======================================================================
                    \\Circular dependency in imported files:
                    \\
                , .{});
                for (self.loading_stack.items) |p| {
                    std.debug.print("  {s} ->\n", .{p});
                }
                std.debug.print("  {s}\n======================================================================\n", .{full_path});
                return error.CircularImport;
            }
        }

        const path_dupe = try self.allocator.dupe(u8, full_path);
        try self.loading_stack.append(path_dupe);
        defer {
            _ = self.loading_stack.pop();
            self.allocator.free(path_dupe);
        }

        var ast_tree: *const ast.AST = undefined;
        if (self.loaded_files.get(full_path)) |lf| {
            ast_tree = &lf.ast_tree;
        } else {
            const file_res = try self.readFileContent(full_path);
            if (!file_res.is_virtual) {
                try self.loaded_sources.append(file_res.content);
            }
            var parser = parser_mod.Parser.init(self.allocator, file_res.content);
            const parsed_tree = parser.parse() catch |err| {
                std.debug.print("Parse error in imported file '{s}': {s}\n", .{ full_path, @errorName(err) });
                return err;
            };
            try self.loaded_trees.append(parsed_tree);
            const saved_tree = &self.loaded_trees.items[self.loaded_trees.items.len - 1];
            try self.loaded_files.put(full_path, .{
                .canonical_path = try self.allocator.dupe(u8, full_path),
                .source = file_res.content,
                .ast_tree = saved_tree.*,
                .is_virtual = file_res.is_virtual,
            });
            ast_tree = saved_tree;
        }

        const pkg = try self.allocator.create(ImportedPackage);
        pkg.* = .{
            .name = if (pkg_name) |pname| try self.allocator.dupe(u8, pname) else try self.allocator.dupe(u8, full_path),
            .path = try self.allocator.dupe(u8, full_path),
            .modules = std.StringHashMap(ast.Decl).init(self.allocator),
            .generic_modules = std.StringHashMap(ast.FnDecl).init(self.allocator),
            .types = std.StringHashMap(hir.HirType).init(self.allocator),
            .constants = std.StringHashMap(u64).init(self.allocator),
            .fn_decls = std.StringHashMap(ast.FnDecl).init(self.allocator),
        };
        try self.all_packages.append(pkg);

        const new_dir = std.fs.path.dirname(full_path);

        for (ast_tree.decls) |decl| {
            if (decl.tag == .const_decl) {
                _ = try self.processConstDeclForImport(decl.data.const_decl.name, decl.data.const_decl.val, new_dir, module_ports, alloc);
            }
        }

        for (ast_tree.decls) |decl| {
            if (!decl.is_pub) continue;

            if (decl.tag == .const_decl) {
                const c = decl.data.const_decl;
                if (c.val.tag == .number) {
                    const val = c.val.data.number.val;
                    try pkg.constants.put(c.name, val);
                    if (pkg_name) |pname| {
                        const full_id = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ pname, c.name });
                        try self.constants.put(full_id, val);
                    }
                } else if (c.val.tag == .type_expr) {
                    if (c.val.data.type_expr.tag == .struct_type) {
                        const ns_id = if (pkg_name) |pname|
                            try std.fmt.allocPrint(self.str_arena.allocator(), "{s}.{s}", .{ pname, c.name })
                        else
                            c.name;
                        _ = try self.registerNamespace(ns_id, c.val.data.type_expr.data.struct_type.decls, module_ports, alloc);
                    } else {
                        var h_type = try self.lowerType(c.val.data.type_expr);
                        h_type.name = c.name;
                        try pkg.types.put(c.name, h_type);
                        try self.registerTypeMethods(c.name, c.val.data.type_expr);
                        try self.registerTypeConstantsAndVariants(c.name, c.val.data.type_expr);
                        if (pkg_name) |pname| {
                            const full_id = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ pname, c.name });
                            var h_type_namespaced = h_type;
                            h_type_namespaced.name = full_id;
                            try self.types.put(full_id, h_type_namespaced);
                            try self.registerTypeMethods(full_id, c.val.data.type_expr);
                            try self.registerTypeConstantsAndVariants(full_id, c.val.data.type_expr);
                        }
                    }
                } else if (c.val.tag == .module_literal) {
                    const mod_decl = ast.Decl{
                        .tag = .module_decl,
                        .is_pub = decl.is_pub,
                        .loc = decl.loc,
                        .data = .{
                            .module_decl = .{
                                .name = c.name,
                                .params = c.val.data.module_literal.params,
                                .items = c.val.data.module_literal.items,
                                .is_extern = c.val.data.module_literal.is_extern,
                                .foreign_name = c.val.data.module_literal.foreign_name,
                                .include_path = c.val.data.module_literal.include_path,
                            },
                        },
                    };
                    try pkg.modules.put(c.name, mod_decl);
                    try self.all_module_decls.put(c.name, mod_decl);
                    const full_id = if (pkg_name) |pname| try std.fmt.allocPrint(alloc, "{s}.{s}", .{ pname, c.name }) else null;
                    if (full_id) |fid| {
                        try self.all_module_decls.put(fid, mod_decl);
                    }
                    if (module_ports) |mp| {
                        try self.extractAndRegisterModulePorts(c.val.data.module_literal.items, c.name, full_id, mp, alloc);
                    }
                }
            } else if (decl.tag == .module_decl) {
                const md = decl.data.module_decl;
                try pkg.modules.put(md.name, decl);
                try self.all_module_decls.put(md.name, decl);
                const full_id = if (pkg_name) |pname| try std.fmt.allocPrint(alloc, "{s}.{s}", .{ pname, md.name }) else null;
                if (full_id) |fid| {
                    try self.all_module_decls.put(fid, decl);
                }
                if (module_ports) |mp| {
                    try self.extractAndRegisterModulePorts(md.items, md.name, full_id, mp, alloc);
                }
            } else if (decl.tag == .fn_decl) {
                const fd = decl.data.fn_decl;
                if (fd.body_expr.tag == .module_literal) {
                    try pkg.generic_modules.put(fd.name, fd);
                    try self.fn_decls.put(fd.name, fd);
                    if (pkg_name) |pname| {
                        const full_id = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ pname, fd.name });
                        try self.fn_decls.put(full_id, fd);
                    }
                } else {
                    try pkg.fn_decls.put(fd.name, fd);
                    try self.fn_decls.put(fd.name, fd);
                    if (pkg_name) |pname| {
                        const full_id = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ pname, fd.name });
                        try self.fn_decls.put(full_id, fd);
                    }
                }
            }
        }

        try self.packages.put(pkg.name, pkg);
        if (pkg_name != null and !std.mem.eql(u8, pkg.path, pkg.name)) {
            try self.packages.put(pkg.path, pkg);
        }
        return pkg;
    }

    const ParamValue = union(enum) {
        int_val: u64,
        type_val: *ast.Type,
        expr_val: *ast.Expr,
    };

    const ParamSubst = struct {
        name: []const u8,
        value: ParamValue,
    };

    fn cloneModuleItems(
        self: *Elaborator,
        alloc: std.mem.Allocator,
        items: []const ast.ModuleItem,
        substs: []const ParamSubst,
    ) std.mem.Allocator.Error![]ast.ModuleItem {
        var cloned = try alloc.alloc(ast.ModuleItem, items.len);
        for (items, 0..) |item, i| {
            cloned[i] = try self.cloneModuleItem(alloc, item, substs);
        }
        return cloned;
    }

    fn cloneModuleItem(
        self: *Elaborator,
        alloc: std.mem.Allocator,
        item: ast.ModuleItem,
        substs: []const ParamSubst,
    ) std.mem.Allocator.Error!ast.ModuleItem {
        switch (item.tag) {
            .port => {
                const p = item.data.port;
                return .{
                    .tag = .port,
                    .loc = item.loc,
                    .data = .{
                        .port = .{
                            .dir = p.dir,
                            .name = try alloc.dupe(u8, p.name),
                            .type_expr = try self.cloneType(alloc, p.type_expr, substs),
                        },
                    },
                };
            },
            .reg_decl => {
                const r = item.data.reg_decl;
                return .{
                    .tag = .reg_decl,
                    .loc = item.loc,
                    .data = .{
                        .reg_decl = .{
                            .name = try alloc.dupe(u8, r.name),
                            .type_expr = try self.cloneType(alloc, r.type_expr, substs),
                            .clk = if (r.clk) |c| try self.cloneExpr(alloc, c, substs) else null,
                            .rst = if (r.rst) |rst| try self.cloneExpr(alloc, rst, substs) else null,
                            .rst_polarity = r.rst_polarity,
                            .init_val = try self.cloneExpr(alloc, r.init_val, substs),
                        },
                    },
                };
            },
            .instance => {
                const inst = item.data.instance;
                var bindings = try alloc.alloc(ast.PortBinding, inst.bindings.len);
                for (inst.bindings, 0..) |b, i| {
                    bindings[i] = .{
                        .port_name = try alloc.dupe(u8, b.port_name),
                        .expr = try self.cloneExpr(alloc, b.expr, substs),
                        .loc = b.loc,
                    };
                }
                var parameters = try alloc.alloc(ast.PortBinding, inst.parameters.len);
                for (inst.parameters, 0..) |p, i| {
                    parameters[i] = .{
                        .port_name = try alloc.dupe(u8, p.port_name),
                        .expr = try self.cloneExpr(alloc, p.expr, substs),
                        .loc = p.loc,
                    };
                }
                return .{
                    .tag = .instance,
                    .loc = item.loc,
                    .data = .{
                        .instance = .{
                            .name = try alloc.dupe(u8, inst.name),
                            .module_expr = try self.cloneExpr(alloc, inst.module_expr, substs),
                            .parameters = parameters,
                            .bindings = bindings,
                        },
                    },
                };
            },
            .comb_block => {
                return .{
                    .tag = .comb_block,
                    .loc = item.loc,
                    .data = .{
                        .comb_block = .{
                            .stmts = try self.cloneStatements(alloc, item.data.comb_block.stmts, substs),
                        },
                    },
                };
            },
            .const_decl => {
                const c = item.data.const_decl;
                return .{
                    .tag = .const_decl,
                    .loc = item.loc,
                    .data = .{
                        .const_decl = .{
                            .name = try alloc.dupe(u8, c.name),
                            .type_annot = if (c.type_annot) |t| try self.cloneType(alloc, t, substs) else null,
                            .val = try self.cloneExpr(alloc, c.val, substs),
                        },
                    },
                };
            },
            .sim_block => {
                return .{
                    .tag = .sim_block,
                    .loc = item.loc,
                    .data = .{
                        .sim_block = .{
                            .stmts = try self.cloneStatements(alloc, item.data.sim_block.stmts, substs),
                        },
                    },
                };
            },
            .stmt => {
                var single = [1]ast.Statement{item.data.stmt};
                const cloned = try self.cloneStatements(alloc, &single, substs);
                return .{
                    .tag = .stmt,
                    .loc = item.loc,
                    .data = .{
                        .stmt = cloned[0],
                    },
                };
            },
        }
    }

    fn cloneStatements(
        self: *Elaborator,
        alloc: std.mem.Allocator,
        stmts: []const ast.Statement,
        substs: []const ParamSubst,
    ) std.mem.Allocator.Error![]ast.Statement {
        var cloned = try alloc.alloc(ast.Statement, stmts.len);
        for (stmts, 0..) |s, i| {
            cloned[i] = try self.cloneStatement(alloc, s, substs);
        }
        return cloned;
    }

    fn cloneStatement(
        self: *Elaborator,
        alloc: std.mem.Allocator,
        stmt: ast.Statement,
        substs: []const ParamSubst,
    ) std.mem.Allocator.Error!ast.Statement {
        switch (stmt.tag) {
            .assign => {
                const a = stmt.data.assign;
                return .{
                    .tag = .assign,
                    .loc = stmt.loc,
                    .data = .{
                        .assign = .{
                            .target = try self.cloneExpr(alloc, a.target, substs),
                            .value = try self.cloneExpr(alloc, a.value, substs),
                            .is_reg_assign = a.is_reg_assign,
                        },
                    },
                };
            },
            .var_decl => {
                const v = stmt.data.var_decl;
                return .{
                    .tag = .var_decl,
                    .loc = stmt.loc,
                    .data = .{
                        .var_decl = .{
                            .name = try alloc.dupe(u8, v.name),
                            .type_annot = if (v.type_annot) |t| try self.cloneType(alloc, t, substs) else null,
                            .init_val = try self.cloneExpr(alloc, v.init_val, substs),
                        },
                    },
                };
            },
            .if_stmt => {
                const ifs = stmt.data.if_stmt;
                return .{
                    .tag = .if_stmt,
                    .loc = stmt.loc,
                    .data = .{
                        .if_stmt = .{
                            .cond = try self.cloneExpr(alloc, ifs.cond, substs),
                            .capture = if (ifs.capture) |cap| try alloc.dupe(u8, cap) else null,
                            .then_stmts = try self.cloneStatements(alloc, ifs.then_stmts, substs),
                            .else_stmts = if (ifs.else_stmts) |es| try self.cloneStatements(alloc, es, substs) else null,
                        },
                    },
                };
            },
            .switch_stmt => {
                const ss = stmt.data.switch_stmt;
                var cases = try alloc.alloc(ast.SwitchCase, ss.cases.len);
                for (ss.cases, 0..) |c, i| {
                    var patterns = try alloc.alloc(*ast.Expr, c.patterns.len);
                    for (c.patterns, 0..) |p, pi| {
                        patterns[pi] = try self.cloneExpr(alloc, p, substs);
                    }
                    cases[i] = .{
                        .patterns = patterns,
                        .capture = if (c.capture) |cap| try alloc.dupe(u8, cap) else null,
                        .is_else = c.is_else,
                        .body = try self.cloneStatements(alloc, c.body, substs),
                        .loc = c.loc,
                    };
                }
                return .{
                    .tag = .switch_stmt,
                    .loc = stmt.loc,
                    .data = .{
                        .switch_stmt = .{
                            .expr = try self.cloneExpr(alloc, ss.expr, substs),
                            .cases = cases,
                        },
                    },
                };
            },
            .inline_for => {
                const inf = stmt.data.inline_for;
                return .{
                    .tag = .inline_for,
                    .loc = stmt.loc,
                    .data = .{
                        .inline_for = .{
                            .var_name = try alloc.dupe(u8, inf.var_name),
                            .start = try self.cloneExpr(alloc, inf.start, substs),
                            .end = try self.cloneExpr(alloc, inf.end, substs),
                            .body = try self.cloneStatements(alloc, inf.body, substs),
                        },
                    },
                };
            },
            .expr_stmt => {
                return .{
                    .tag = .expr_stmt,
                    .loc = stmt.loc,
                    .data = .{
                        .expr_stmt = try self.cloneExpr(alloc, stmt.data.expr_stmt, substs),
                    },
                };
            },
        }
    }

    fn cloneType(
        self: *Elaborator,
        alloc: std.mem.Allocator,
        t: *ast.Type,
        substs: []const ParamSubst,
    ) std.mem.Allocator.Error!*ast.Type {
        const new_t = try alloc.create(ast.Type);
        switch (t.tag) {
            .named => {
                for (substs) |s| {
                    if (std.mem.eql(u8, s.name, t.data.named)) {
                        switch (s.value) {
                            .type_val => |tv| return try self.cloneType(alloc, tv, substs),
                            .int_val => {},
                            .expr_val => {},
                        }
                    }
                }
                new_t.* = .{
                    .tag = .named,
                    .loc = t.loc,
                    .data = .{
                        .named = try alloc.dupe(u8, t.data.named),
                    },
                };
                return new_t;
            },
            .int => {
                new_t.* = .{
                    .tag = .int,
                    .loc = t.loc,
                    .data = .{
                        .int = .{
                            .is_signed = t.data.int.is_signed,
                            .width = try self.cloneExpr(alloc, t.data.int.width, substs),
                        },
                    },
                };
                return new_t;
            },
            .array => {
                new_t.* = .{
                    .tag = .array,
                    .loc = t.loc,
                    .data = .{
                        .array = .{
                            .len = try self.cloneExpr(alloc, t.data.array.len, substs),
                            .elem_type = try self.cloneType(alloc, t.data.array.elem_type, substs),
                        },
                    },
                };
                return new_t;
            },
            .optional => {
                new_t.* = .{
                    .tag = .optional,
                    .loc = t.loc,
                    .data = .{
                        .optional = try self.cloneType(alloc, t.data.optional, substs),
                    },
                };
                return new_t;
            },
            .enum_type => {
                var fields = try alloc.alloc(ast.EnumField, t.data.enum_type.fields.len);
                for (t.data.enum_type.fields, 0..) |f, i| {
                    fields[i] = .{
                        .name = try alloc.dupe(u8, f.name),
                        .value = if (f.value) |v| try self.cloneExpr(alloc, v, substs) else null,
                        .loc = f.loc,
                    };
                }
                new_t.* = .{
                    .tag = .enum_type,
                    .loc = t.loc,
                    .data = .{
                        .enum_type = .{
                            .tag_type = if (t.data.enum_type.tag_type) |tt| try self.cloneType(alloc, tt, substs) else null,
                            .fields = fields,
                            .methods = t.data.enum_type.methods,
                            .constants = t.data.enum_type.constants,
                        },
                    },
                };
                return new_t;
            },
            .packed_struct => {
                var fields = try alloc.alloc(ast.StructField, t.data.packed_struct.fields.len);
                for (t.data.packed_struct.fields, 0..) |f, i| {
                    fields[i] = .{
                        .name = try alloc.dupe(u8, f.name),
                        .type_expr = try self.cloneType(alloc, f.type_expr, substs),
                        .loc = f.loc,
                    };
                }
                new_t.* = .{
                    .tag = .packed_struct,
                    .loc = t.loc,
                    .data = .{
                        .packed_struct = .{
                            .fields = fields,
                            .methods = t.data.packed_struct.methods,
                            .constants = t.data.packed_struct.constants,
                        },
                    },
                };
                return new_t;
            },
            .tagged_union => {
                var fields = try alloc.alloc(ast.UnionField, t.data.tagged_union.fields.len);
                for (t.data.tagged_union.fields, 0..) |f, i| {
                    fields[i] = .{
                        .name = try alloc.dupe(u8, f.name),
                        .type_expr = if (f.type_expr) |te| try self.cloneType(alloc, te, substs) else null,
                        .loc = f.loc,
                    };
                }
                new_t.* = .{
                    .tag = .tagged_union,
                    .loc = t.loc,
                    .data = .{
                        .tagged_union = .{
                            .tag_type = if (t.data.tagged_union.tag_type) |tt| try self.cloneType(alloc, tt, substs) else null,
                            .fields = fields,
                            .methods = t.data.tagged_union.methods,
                            .constants = t.data.tagged_union.constants,
                        },
                    },
                };
                return new_t;
            },
            .reset => {
                new_t.* = .{
                    .tag = .reset,
                    .loc = t.loc,
                    .data = .{
                        .reset = .{
                            .is_active_low = t.data.reset.is_active_low,
                        },
                    },
                };
                return new_t;
            },
            .struct_type => {
                new_t.* = .{
                    .tag = .struct_type,
                    .loc = t.loc,
                    .data = .{
                        .struct_type = .{
                            .decls = t.data.struct_type.decls,
                        },
                    },
                };
                return new_t;
            },
        }
    }

    fn cloneExpr(
        self: *Elaborator,
        alloc: std.mem.Allocator,
        expr: *ast.Expr,
        substs: []const ParamSubst,
    ) std.mem.Allocator.Error!*ast.Expr {
        const new_e = try alloc.create(ast.Expr);
        switch (expr.tag) {
            .number => {
                new_e.* = .{
                    .tag = .number,
                    .loc = expr.loc,
                    .data = .{
                        .number = .{
                            .val = expr.data.number.val,
                            .raw = try alloc.dupe(u8, expr.data.number.raw),
                        },
                    },
                };
                return new_e;
            },
            .time_literal => {
                new_e.* = .{
                    .tag = .time_literal,
                    .loc = expr.loc,
                    .data = .{
                        .time_literal = .{
                            .val = expr.data.time_literal.val,
                            .unit = expr.data.time_literal.unit,
                            .raw = try alloc.dupe(u8, expr.data.time_literal.raw),
                        },
                    },
                };
                return new_e;
            },
            .freq_literal => {
                new_e.* = .{
                    .tag = .freq_literal,
                    .loc = expr.loc,
                    .data = .{
                        .freq_literal = .{
                            .val = expr.data.freq_literal.val,
                            .unit = expr.data.freq_literal.unit,
                            .raw = try alloc.dupe(u8, expr.data.freq_literal.raw),
                        },
                    },
                };
                return new_e;
            },
            .boolean => {
                new_e.* = .{
                    .tag = .boolean,
                    .loc = expr.loc,
                    .data = .{ .boolean = expr.data.boolean },
                };
                return new_e;
            },
            .string => {
                new_e.* = .{
                    .tag = .string,
                    .loc = expr.loc,
                    .data = .{ .string = try alloc.dupe(u8, expr.data.string) },
                };
                return new_e;
            },
            .identifier => {
                for (substs) |s| {
                    if (std.mem.eql(u8, s.name, expr.data.identifier)) {
                        switch (s.value) {
                            .int_val => |iv| {
                                new_e.* = .{
                                    .tag = .number,
                                    .loc = expr.loc,
                                    .data = .{
                                        .number = .{
                                            .val = iv,
                                            .raw = try std.fmt.allocPrint(alloc, "{d}", .{iv}),
                                        },
                                    },
                                };
                                return new_e;
                            },
                            .type_val => |tv| {
                                if (tv.tag == .named) {
                                    new_e.* = .{
                                        .tag = .identifier,
                                        .loc = expr.loc,
                                        .data = .{
                                            .identifier = try alloc.dupe(u8, tv.data.named),
                                        },
                                    };
                                    return new_e;
                                } else if (tv.tag == .int) {
                                    const w = self.evalConst(tv.data.int.width);
                                    new_e.* = .{
                                        .tag = .identifier,
                                        .loc = expr.loc,
                                        .data = .{
                                            .identifier = if (tv.data.int.is_signed)
                                                try std.fmt.allocPrint(alloc, "i{d}", .{w})
                                            else
                                                try std.fmt.allocPrint(alloc, "u{d}", .{w}),
                                        },
                                    };
                                    return new_e;
                                } else {
                                    const cloned_tv = try self.cloneType(alloc, tv, substs);
                                    new_e.* = .{
                                        .tag = .type_expr,
                                        .loc = expr.loc,
                                        .data = .{
                                            .type_expr = cloned_tv,
                                        },
                                    };
                                    return new_e;
                                }
                            },
                            .expr_val => |ev| {
                                return try self.cloneExpr(alloc, ev, substs);
                            },
                        }
                    }
                }
                new_e.* = .{
                    .tag = .identifier,
                    .loc = expr.loc,
                    .data = .{
                        .identifier = try alloc.dupe(u8, expr.data.identifier),
                    },
                };
                return new_e;
            },
            .enum_literal => {
                new_e.* = .{
                    .tag = .enum_literal,
                    .loc = expr.loc,
                    .data = .{ .enum_literal = try alloc.dupe(u8, expr.data.enum_literal) },
                };
                return new_e;
            },
            .null_lit => {
                new_e.* = .{
                    .tag = .null_lit,
                    .loc = expr.loc,
                    .data = .{ .null_lit = {} },
                };
                return new_e;
            },
            .unary => {
                new_e.* = .{
                    .tag = .unary,
                    .loc = expr.loc,
                    .data = .{
                        .unary = .{
                            .op = expr.data.unary.op,
                            .operand = try self.cloneExpr(alloc, expr.data.unary.operand, substs),
                        },
                    },
                };
                return new_e;
            },
            .binary => {
                new_e.* = .{
                    .tag = .binary,
                    .loc = expr.loc,
                    .data = .{
                        .binary = .{
                            .op = expr.data.binary.op,
                            .left = try self.cloneExpr(alloc, expr.data.binary.left, substs),
                            .right = try self.cloneExpr(alloc, expr.data.binary.right, substs),
                        },
                    },
                };
                return new_e;
            },
            .index => {
                new_e.* = .{
                    .tag = .index,
                    .loc = expr.loc,
                    .data = .{
                        .index = .{
                            .target = try self.cloneExpr(alloc, expr.data.index.target, substs),
                            .index = try self.cloneExpr(alloc, expr.data.index.index, substs),
                        },
                    },
                };
                return new_e;
            },
            .slice => {
                const sl = expr.data.slice;
                new_e.* = .{
                    .tag = .slice,
                    .loc = expr.loc,
                    .data = .{
                        .slice = .{
                            .target = try self.cloneExpr(alloc, sl.target, substs),
                            .start = try self.cloneExpr(alloc, sl.start, substs),
                            .end = try self.cloneExpr(alloc, sl.end, substs),
                            .is_downward = sl.is_downward,
                        },
                    },
                };
                return new_e;
            },
            .member_access => {
                const ma = expr.data.member_access;
                new_e.* = .{
                    .tag = .member_access,
                    .loc = expr.loc,
                    .data = .{
                        .member_access = .{
                            .target = try self.cloneExpr(alloc, ma.target, substs),
                            .field = try alloc.dupe(u8, ma.field),
                        },
                    },
                };
                return new_e;
            },
            .call => {
                const c = expr.data.call;
                var args = try alloc.alloc(*ast.Expr, c.args.len);
                for (c.args, 0..) |arg, i| {
                    args[i] = try self.cloneExpr(alloc, arg, substs);
                }
                new_e.* = .{
                    .tag = .call,
                    .loc = expr.loc,
                    .data = .{
                        .call = .{
                            .callee = try self.cloneExpr(alloc, c.callee, substs),
                            .args = args,
                        },
                    },
                };
                return new_e;
            },
            .builtin_call => {
                const bc = expr.data.builtin_call;
                var args = try alloc.alloc(*ast.Expr, bc.args.len);
                for (bc.args, 0..) |arg, i| {
                    args[i] = try self.cloneExpr(alloc, arg, substs);
                }
                new_e.* = .{
                    .tag = .builtin_call,
                    .loc = expr.loc,
                    .data = .{
                        .builtin_call = .{
                            .tag = bc.tag,
                            .args = args,
                        },
                    },
                };
                return new_e;
            },
            .struct_init => {
                const si = expr.data.struct_init;
                var fields = try alloc.alloc(ast.NamedExpr, si.fields.len);
                for (si.fields, 0..) |f, i| {
                    fields[i] = .{
                        .name = try alloc.dupe(u8, f.name),
                        .value = try self.cloneExpr(alloc, f.value, substs),
                        .loc = f.loc,
                    };
                }
                new_e.* = .{
                    .tag = .struct_init,
                    .loc = expr.loc,
                    .data = .{
                        .struct_init = .{
                            .type_expr = if (si.type_expr) |te| try self.cloneType(alloc, te, substs) else null,
                            .fields = fields,
                        },
                    },
                };
                return new_e;
            },
            .array_init => {
                const ai = expr.data.array_init;
                var elements = try alloc.alloc(*ast.Expr, ai.elements.len);
                for (ai.elements, 0..) |elem, i| {
                    elements[i] = try self.cloneExpr(alloc, elem, substs);
                }
                new_e.* = .{
                    .tag = .array_init,
                    .loc = expr.loc,
                    .data = .{
                        .array_init = .{
                            .type_expr = if (ai.type_expr) |te| try self.cloneType(alloc, te, substs) else null,
                            .elements = elements,
                        },
                    },
                };
                return new_e;
            },
            .part_select => {
                const ps = expr.data.part_select;
                new_e.* = .{
                    .tag = .part_select,
                    .loc = expr.loc,
                    .data = .{
                        .part_select = .{
                            .target = try self.cloneExpr(alloc, ps.target, substs),
                            .base = try self.cloneExpr(alloc, ps.base, substs),
                            .width = try self.cloneExpr(alloc, ps.width, substs),
                            .is_up = ps.is_up,
                        },
                    },
                };
                return new_e;
            },
            .if_expr => {
                const ife = expr.data.if_expr;
                new_e.* = .{
                    .tag = .if_expr,
                    .loc = expr.loc,
                    .data = .{
                        .if_expr = .{
                            .cond = try self.cloneExpr(alloc, ife.cond, substs),
                            .then_branch = try self.cloneExpr(alloc, ife.then_branch, substs),
                            .else_branch = try self.cloneExpr(alloc, ife.else_branch, substs),
                        },
                    },
                };
                return new_e;
            },
            .type_expr => {
                new_e.* = .{
                    .tag = .type_expr,
                    .loc = expr.loc,
                    .data = .{
                        .type_expr = try self.cloneType(alloc, expr.data.type_expr, substs),
                    },
                };
                return new_e;
            },
            .module_literal => {
                new_e.* = .{
                    .tag = .module_literal,
                    .loc = expr.loc,
                    .data = .{
                        .module_literal = .{
                            .items = try self.cloneModuleItems(alloc, expr.data.module_literal.items, substs),
                            .is_extern = expr.data.module_literal.is_extern,
                            .foreign_name = if (expr.data.module_literal.foreign_name) |fnm| try alloc.dupe(u8, fnm) else null,
                            .include_path = if (expr.data.module_literal.include_path) |inc| try alloc.dupe(u8, inc) else null,
                        },
                    },
                };
                return new_e;
            },
        }
    }

    fn resolveGenericCall(
        self: *Elaborator,
        expr: *ast.Expr,
        local_items: ?[]const ast.ModuleItem,
    ) ?*ast.Expr {
        if (expr.tag == .call) {
            if (expr.data.call.callee.tag == .identifier) {
                if (self.fn_decls.get(expr.data.call.callee.data.identifier)) |fd| {
                    if (fd.body_expr.tag == .module_literal) {
                        return expr;
                    }
                }
            } else if (expr.data.call.callee.tag == .member_access) {
                const ma = expr.data.call.callee.data.member_access;
                if (exprToDottedString(self.allocator, expr.data.call.callee)) |full_name| {
                    defer self.allocator.free(full_name);
                    if (self.fn_decls.get(full_name)) |fd| {
                        if (fd.body_expr.tag == .module_literal) {
                            return expr;
                        }
                    }
                }
                if (self.fn_decls.get(ma.field)) |fd| {
                    if (fd.body_expr.tag == .module_literal) {
                        return expr;
                    }
                }
            }
            return null;
        }
        if (expr.tag == .identifier) {
            const id_name = expr.data.identifier;
            if (local_items) |items| {
                for (items) |item| {
                    if (item.tag == .const_decl and std.mem.eql(u8, item.data.const_decl.name, id_name)) {
                        return self.resolveGenericCall(item.data.const_decl.val, local_items);
                    }
                }
            }
            for (self.ast_tree.decls) |decl| {
                if (decl.tag == .const_decl and std.mem.eql(u8, decl.data.const_decl.name, id_name)) {
                    return self.resolveGenericCall(decl.data.const_decl.val, local_items);
                }
            }
        }
        return null;
    }

    fn isTypeExprOrName(self: *Elaborator, expr: *ast.Expr) bool {
        if (expr.tag == .type_expr) return true;
        if (expr.tag == .member_access) {
            if (exprToDottedString(self.allocator, expr)) |dotted| {
                defer self.allocator.free(dotted);
                if (self.types.contains(dotted)) return true;
            }
        }
        if (expr.tag == .call and expr.data.call.callee.tag == .identifier) {
            const cname = expr.data.call.callee.data.identifier;
            if ((std.mem.eql(u8, cname, "u") or std.mem.eql(u8, cname, "i")) and expr.data.call.args.len == 1) {
                return true;
            }
            if (std.mem.eql(u8, cname, "reset") and expr.data.call.args.len <= 1) {
                return true;
            }
        }
        if (expr.tag == .identifier) {
            const name = expr.data.identifier;
            if (std.mem.eql(u8, name, "clock") or std.mem.eql(u8, name, "reset") or std.mem.eql(u8, name, "reset_n") or std.mem.eql(u8, name, "reset_low")) return true;
            if (self.types.contains(name)) return true;
            if ((name[0] == 'u' or name[0] == 'i') and name.len > 1) {
                var all_digits = true;
                for (name[1..]) |ch| {
                    if (!std.ascii.isDigit(ch)) {
                        all_digits = false;
                        break;
                    }
                }
                if (all_digits) return true;
            }
        }
        return false;
    }

    fn exprToType(self: *Elaborator, alloc: std.mem.Allocator, expr: *ast.Expr) !*ast.Type {
        _ = self;
        if (expr.tag == .type_expr) {
            return expr.data.type_expr;
        }
        if (expr.tag == .call and expr.data.call.callee.tag == .identifier) {
            const cname = expr.data.call.callee.data.identifier;
            if ((std.mem.eql(u8, cname, "u") or std.mem.eql(u8, cname, "i")) and expr.data.call.args.len == 1) {
                const t = try alloc.create(ast.Type);
                t.* = .{
                    .tag = .int,
                    .loc = expr.loc,
                    .data = .{
                        .int = .{
                            .is_signed = std.mem.eql(u8, cname, "i"),
                            .width = expr.data.call.args[0],
                        },
                    },
                };
                return t;
            }
            if (std.mem.eql(u8, cname, "reset")) {
                var is_low = false;
                if (expr.data.call.args.len > 0) {
                    const arg0 = expr.data.call.args[0];
                    if (arg0.tag == .enum_literal) {
                        const lit = arg0.data.enum_literal;
                        if (std.mem.eql(u8, lit, "low") or std.mem.eql(u8, lit, "active_low")) {
                            is_low = true;
                        }
                    } else if (arg0.tag == .identifier) {
                        const id = arg0.data.identifier;
                        if (std.mem.eql(u8, id, "low") or std.mem.eql(u8, id, "active_low")) {
                            is_low = true;
                        }
                    }
                }
                const t = try alloc.create(ast.Type);
                t.* = .{
                    .tag = .reset,
                    .loc = expr.loc,
                    .data = .{
                        .reset = .{
                            .is_active_low = is_low,
                        },
                    },
                };
                return t;
            }
        }
        if (expr.tag == .identifier) {
            const name = expr.data.identifier;
            if (std.mem.eql(u8, name, "reset")) {
                const t = try alloc.create(ast.Type);
                t.* = .{
                    .tag = .reset,
                    .loc = expr.loc,
                    .data = .{
                        .reset = .{
                            .is_active_low = false,
                        },
                    },
                };
                return t;
            }
            if (std.mem.eql(u8, name, "reset_n") or std.mem.eql(u8, name, "reset_low")) {
                const t = try alloc.create(ast.Type);
                t.* = .{
                    .tag = .reset,
                    .loc = expr.loc,
                    .data = .{
                        .reset = .{
                            .is_active_low = true,
                        },
                    },
                };
                return t;
            }
            if ((name[0] == 'u' or name[0] == 'i') and name.len > 1) {
                var all_digits = true;
                for (name[1..]) |ch| {
                    if (!std.ascii.isDigit(ch)) {
                        all_digits = false;
                        break;
                    }
                }
                if (all_digits) {
                    const width_val = try std.fmt.parseInt(u64, name[1..], 10);
                    const w_expr = try alloc.create(ast.Expr);
                    w_expr.* = .{
                        .tag = .number,
                        .loc = expr.loc,
                        .data = .{
                            .number = .{
                                .val = width_val,
                                .raw = try alloc.dupe(u8, name[1..]),
                            },
                        },
                    };
                    const t = try alloc.create(ast.Type);
                    t.* = .{
                        .tag = .int,
                        .loc = expr.loc,
                        .data = .{
                            .int = .{
                                .is_signed = (name[0] == 'i'),
                                .width = w_expr,
                            },
                        },
                    };
                    return t;
                }
            }
            const t = try alloc.create(ast.Type);
            t.* = .{
                .tag = .named,
                .loc = expr.loc,
                .data = .{
                    .named = try alloc.dupe(u8, name),
                },
            };
            return t;
        }
        if (expr.tag == .member_access) {
            if (exprToDottedString(alloc, expr)) |dotted| {
                const t = try alloc.create(ast.Type);
                t.* = .{
                    .tag = .named,
                    .loc = expr.loc,
                    .data = .{
                        .named = dotted,
                    },
                };
                return t;
            }
        }
        return error.TypeMismatch;
    }

    fn getOrMonomorphizeModule(
        self: *Elaborator,
        alloc: std.mem.Allocator,
        call_expr: *ast.Expr,
        modules: *ArrayList(hir.HirModule),
        module_ports: *std.StringHashMap([]hir.HirPort),
        local_consts: ?*const std.StringHashMap(u64),
    ) anyerror![]const u8 {
        const callee = call_expr.data.call.callee;
        var fn_name: []const u8 = undefined;
        var fn_decl: ast.FnDecl = undefined;

        if (callee.tag == .identifier) {
            fn_name = callee.data.identifier;
            fn_decl = self.fn_decls.get(fn_name) orelse return error.ModuleNotFound;
        } else if (callee.tag == .member_access) {
            const ma = callee.data.member_access;
            if (exprToDottedString(alloc, callee)) |full_name| {
                fn_name = ma.field;
                fn_decl = self.fn_decls.get(full_name) orelse (self.fn_decls.get(ma.field) orelse return error.ModuleNotFound);
            } else {
                return error.ModuleNotFound;
            }
        } else {
            return error.ModuleNotFound;
        }
        if (fn_decl.body_expr.tag != .module_literal) return error.ModuleNotFound;

        const args = call_expr.data.call.args;
        var substs = ArrayList(ParamSubst).init(alloc);

        for (fn_decl.params, 0..) |param, i| {
            if (i >= args.len) break;
            const arg = args[i];
            const is_type_param = (param.type_expr.tag == .named and std.mem.eql(u8, param.type_expr.data.named, "type")) or
                self.isTypeExprOrName(arg);

            if (is_type_param) {
                const t = self.exprToType(alloc, arg) catch return error.TypeMismatch;
                substs.append(.{
                    .name = param.name,
                    .value = .{ .type_val = t },
                }) catch return error.OutOfMemory;
            } else {
                const v = self.evalConstEx(arg, local_consts);
                substs.append(.{
                    .name = param.name,
                    .value = .{ .int_val = v },
                }) catch return error.OutOfMemory;
            }
        }

        var name_buf = ArrayList(u8).init(alloc);
        name_buf.appendSlice(fn_name) catch return error.OutOfMemory;
        for (substs.items) |subst| {
            switch (subst.value) {
                .int_val => |iv| {
                    const s = std.fmt.allocPrint(alloc, "_{d}", .{iv}) catch return error.OutOfMemory;
                    name_buf.appendSlice(s) catch return error.OutOfMemory;
                },
                .type_val => |tv| {
                    if (tv.tag == .int) {
                        const w = self.evalConst(tv.data.int.width);
                        const sign_char: u8 = if (tv.data.int.is_signed) 'i' else 'u';
                        const s = std.fmt.allocPrint(alloc, "_{c}{d}", .{ sign_char, w }) catch return error.OutOfMemory;
                        name_buf.appendSlice(s) catch return error.OutOfMemory;
                    } else if (tv.tag == .named) {
                        const s = std.fmt.allocPrint(alloc, "_{s}", .{tv.data.named}) catch return error.OutOfMemory;
                        name_buf.appendSlice(s) catch return error.OutOfMemory;
                    } else {
                        name_buf.appendSlice("_type") catch return error.OutOfMemory;
                    }
                },
                .expr_val => |ev| {
                    const iv = self.evalConstEx(ev, local_consts);
                    const s = std.fmt.allocPrint(alloc, "_{d}", .{iv}) catch return error.OutOfMemory;
                    name_buf.appendSlice(s) catch return error.OutOfMemory;
                },
            }
        }
        const mono_name = name_buf.toOwnedSlice() catch return error.OutOfMemory;

        if (self.specialized_modules.contains(mono_name)) {
            return mono_name;
        }
        self.specialized_modules.put(mono_name, {}) catch return error.OutOfMemory;

        // Clone template items
        const template_items = fn_decl.body_expr.data.module_literal.items;
        const specialized_items = self.cloneModuleItems(alloc, template_items, substs.items) catch return error.OutOfMemory;
        const is_extern = fn_decl.body_expr.data.module_literal.is_extern;
        const foreign_name = fn_decl.body_expr.data.module_literal.foreign_name;
        const include_path = fn_decl.body_expr.data.module_literal.include_path;
        if (foreign_name) |fname| {
            self.module_foreign_names.put(mono_name, fname) catch return error.OutOfMemory;
        }
        if (include_path) |inc| {
            self.external_sources.put(inc, {}) catch return error.OutOfMemory;
        }

        // Register ports of this specialized module
        var mod_ports = ArrayList(hir.HirPort).init(alloc);
        for (specialized_items) |item| {
            if (item.tag == .port) {
                const p = item.data.port;
                const h_type = try self.lowerType(p.type_expr);
                mod_ports.append(.{
                    .name = p.name,
                    .dir = switch (p.dir) {
                        .in => .in,
                        .out => .out,
                        .inout => .inout,
                    },
                    .hir_type = h_type,
                }) catch return error.OutOfMemory;
            }
        }
        const owned_ports = mod_ports.toOwnedSlice() catch return error.OutOfMemory;
        module_ports.put(mono_name, owned_ports) catch return error.OutOfMemory;

        // Elaborate the specialized module!
        const hir_mod = try self.elaborateModule(
            alloc,
            mono_name,
            specialized_items,
            module_ports,
            modules,
            is_extern,
            foreign_name,
            include_path,
        );
        modules.append(hir_mod) catch return error.OutOfMemory;

        return mono_name;
    }

    pub fn elaborate(self: *Elaborator, top_module_name: ?[]const u8) !hir.HirDesign {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        var modules = ArrayList(hir.HirModule).init(alloc);
        var testbenches = ArrayList(hir.HirTestbench).init(alloc);
        var module_ports = std.StringHashMap([]hir.HirPort).init(alloc);

        // Pre-scan namespaces and imports
        for (self.ast_tree.decls) |decl| {
            if (decl.tag == .const_decl) {
                const c = decl.data.const_decl;
                if (c.val.tag == .type_expr and c.val.data.type_expr.tag == .struct_type) {
                    _ = try self.registerNamespace(c.name, c.val.data.type_expr.data.struct_type.decls, &module_ports, alloc);
                } else {
                    _ = try self.processConstDeclForImport(
                        c.name,
                        c.val,
                        self.base_dir,
                        &module_ports,
                        alloc,
                    );
                }
            }
        }

        // 1. Collect top-level types, constants, and functions
        for (self.ast_tree.decls) |decl| {
            if (decl.tag == .fn_decl) {
                try self.fn_decls.put(decl.data.fn_decl.name, decl.data.fn_decl);
            } else if (decl.tag == .const_decl) {
                const c = decl.data.const_decl;
                if (c.val.tag == .number) {
                    try self.constants.put(c.name, c.val.data.number.val);
                } else if (c.val.tag == .type_expr) {
                    if (c.val.data.type_expr.tag != .struct_type) {
                        var h_type = try self.lowerType(c.val.data.type_expr);
                        h_type.name = c.name;
                        try self.types.put(c.name, h_type);
                        try self.registerTypeMethods(c.name, c.val.data.type_expr);
                        try self.registerTypeConstantsAndVariants(c.name, c.val.data.type_expr);
                    }
                }
            }
        }

        for (self.ast_tree.decls) |decl| {
            if (decl.tag == .module_decl) {
                try self.all_module_decls.put(decl.data.module_decl.name, decl);
                var mod_ports = ArrayList(hir.HirPort).init(alloc);
                for (decl.data.module_decl.items) |item| {
                    if (item.tag == .port) {
                        const p = item.data.port;
                        const h_type = try self.lowerType(p.type_expr);
                        try mod_ports.append(.{
                            .name = p.name,
                            .dir = switch (p.dir) {
                                .in => .in,
                                .out => .out,
                                .inout => .inout,
                            },
                            .hir_type = h_type,
                        });
                    }
                }
                const owned_ports = try mod_ports.toOwnedSlice();
                try module_ports.put(decl.data.module_decl.name, owned_ports);
                if (decl.data.module_decl.foreign_name) |fname| {
                    try module_ports.put(fname, owned_ports);
                    try self.module_foreign_names.put(decl.data.module_decl.name, fname);
                }
                if (decl.data.module_decl.include_path) |inc| {
                    try self.external_sources.put(inc, {});
                }
            }
        }

        // 2. Find target module
        var target_mod_name = top_module_name;
        if (target_mod_name == null) {
            for (self.ast_tree.decls) |decl| {
                if (decl.tag == .module_decl and !decl.data.module_decl.is_extern) {
                    target_mod_name = decl.data.module_decl.name;
                    break;
                }
            }
            if (target_mod_name == null) {
                for (self.ast_tree.decls) |decl| {
                    if (decl.tag == .const_decl and self.resolveGenericCall(decl.data.const_decl.val, null) != null) {
                        target_mod_name = decl.data.const_decl.name;
                        break;
                    }
                }
            }
            if (target_mod_name == null) {
                for (self.ast_tree.decls) |decl| {
                    if (decl.tag == .module_decl) {
                        target_mod_name = decl.data.module_decl.name;
                        break;
                    }
                }
            }
        }

        // If target_mod_name matches a top-level generic const_decl, monomorphize it now
        if (target_mod_name != null) {
            for (self.ast_tree.decls) |decl| {
                if (decl.tag == .const_decl and std.mem.eql(u8, decl.data.const_decl.name, target_mod_name.?)) {
                    if (self.resolveGenericCall(decl.data.const_decl.val, null)) |call_expr| {
                        target_mod_name = try self.getOrMonomorphizeModule(alloc, call_expr, &modules, &module_ports, null);
                        break;
                    }
                }
            }
        }

        // If target_mod_name is still null, check if any testbench has an instance of a module
        if (target_mod_name == null) {
            for (self.ast_tree.decls) |decl| {
                if (decl.tag == .test_decl) {
                    for (decl.data.test_decl.items) |item| {
                        if (item.tag == .instance) {
                            if (self.resolveGenericCall(item.data.instance.module_expr, decl.data.test_decl.items)) |call_expr| {
                                target_mod_name = try self.getOrMonomorphizeModule(alloc, call_expr, &modules, &module_ports, null);
                                break;
                            } else if (item.data.instance.module_expr.tag == .identifier) {
                                const id = item.data.instance.module_expr.data.identifier;
                                if (self.findModuleDecl(id)) |md| {
                                    target_mod_name = if (md.tag == .module_decl) md.data.module_decl.name else md.data.const_decl.name;
                                } else {
                                    target_mod_name = id;
                                }
                                break;
                            } else if (item.data.instance.module_expr.tag == .member_access) {
                                const ma = item.data.instance.module_expr.data.member_access;
                                if (exprToDottedString(alloc, ma.target)) |pkg_id| {
                                    if (self.packages.get(pkg_id)) |pkg| {
                                        if (pkg.modules.get(ma.field)) |md| {
                                            target_mod_name = if (md.tag == .module_decl) md.data.module_decl.name else md.data.const_decl.name;
                                        } else {
                                            target_mod_name = ma.field;
                                        }
                                    } else {
                                        target_mod_name = ma.field;
                                    }
                                } else {
                                    target_mod_name = ma.field;
                                }
                                break;
                            }
                        }
                    }
                    if (target_mod_name != null) break;
                }
            }
        }

        if (target_mod_name != null and !self.isModuleElaborated(&modules, target_mod_name.?)) {
            const md_opt = self.findModuleDecl(target_mod_name.?);
            if (md_opt) |md| {
                const m_items = if (md.tag == .module_decl) md.data.module_decl.items else md.data.const_decl.val.data.module_literal.items;
                const m_is_extern = if (md.tag == .module_decl) md.data.module_decl.is_extern else md.data.const_decl.val.data.module_literal.is_extern;
                const m_foreign_name = if (md.tag == .module_decl) md.data.module_decl.foreign_name else md.data.const_decl.val.data.module_literal.foreign_name;
                const m_include_path = if (md.tag == .module_decl) md.data.module_decl.include_path else md.data.const_decl.val.data.module_literal.include_path;
                const hir_m = try self.elaborateModule(
                    alloc,
                    target_mod_name.?,
                    m_items,
                    &module_ports,
                    &modules,
                    m_is_extern,
                    m_foreign_name,
                    m_include_path,
                );
                try modules.append(hir_m);
            }
        }

        if (target_mod_name == null) {
            return error.ModuleNotFound;
        }

        for (self.ast_tree.decls) |decl| {
            if (decl.tag == .module_decl) {
                const md = decl.data.module_decl;
                if (!self.isModuleElaborated(&modules, md.name)) {
                    const hir_mod = try self.elaborateModule(
                        alloc,
                        md.name,
                        md.items,
                        &module_ports,
                        &modules,
                        md.is_extern,
                        md.foreign_name,
                        md.include_path,
                    );
                    try modules.append(hir_mod);
                }
            } else if (decl.tag == .test_decl) {
                const td = decl.data.test_decl;
                const tb = try self.elaborateTestbench(alloc, td.name, td.items, &module_ports, &modules);
                try testbenches.append(tb);
            }
        }

        // Reconcile any instance parameters onto blackbox extern modules
        for (modules.items) |mod| {
            for (mod.instances) |inst| {
                if (inst.parameters.len > 0) {
                    for (modules.items) |*target_m| {
                        const matches_name = std.mem.eql(u8, target_m.name, inst.module_name) or
                            (target_m.foreign_name != null and std.mem.eql(u8, target_m.foreign_name.?, inst.module_name));
                        if (matches_name and target_m.is_extern) {
                            for (inst.parameters) |p| {
                                var found = false;
                                for (target_m.parameters) |mp| {
                                    if (std.mem.eql(u8, mp.name, p.name)) {
                                        found = true;
                                        break;
                                    }
                                }
                                if (!found) {
                                    var new_params = ArrayList(hir.HirParameterBinding).init(alloc);
                                    try new_params.appendSlice(target_m.parameters);
                                    try new_params.append(p);
                                    target_m.parameters = try new_params.toOwnedSlice();
                                }
                            }
                            break;
                        }
                    }
                }
            }
        }
        for (testbenches.items) |tb| {
            for (tb.instances) |inst| {
                if (inst.parameters.len > 0) {
                    for (modules.items) |*target_m| {
                        const matches_name = std.mem.eql(u8, target_m.name, inst.module_name) or
                            (target_m.foreign_name != null and std.mem.eql(u8, target_m.foreign_name.?, inst.module_name));
                        if (matches_name and target_m.is_extern) {
                            for (inst.parameters) |p| {
                                var found = false;
                                for (target_m.parameters) |mp| {
                                    if (std.mem.eql(u8, mp.name, p.name)) {
                                        found = true;
                                        break;
                                    }
                                }
                                if (!found) {
                                    var new_params = ArrayList(hir.HirParameterBinding).init(alloc);
                                    try new_params.appendSlice(target_m.parameters);
                                    try new_params.append(p);
                                    target_m.parameters = try new_params.toOwnedSlice();
                                }
                            }
                            break;
                        }
                    }
                }
            }
        }

        var ext_srcs = ArrayList([]const u8).init(alloc);
        var src_it = self.external_sources.keyIterator();
        while (src_it.next()) |k| {
            try ext_srcs.append(k.*);
        }

        return .{
            .arena = arena,
            .modules = try modules.toOwnedSlice(),
            .testbenches = try testbenches.toOwnedSlice(),
            .top_module = target_mod_name.?,
            .external_sources = try ext_srcs.toOwnedSlice(),
        };
    }

    fn elaborateModule(
        self: *Elaborator,
        alloc: std.mem.Allocator,
        mod_name: []const u8,
        items: []ast.ModuleItem,
        module_ports: *std.StringHashMap([]hir.HirPort),
        modules: *ArrayList(hir.HirModule),
        is_extern: bool,
        foreign_name: ?[]const u8,
        include_path: ?[]const u8,
    ) !hir.HirModule {
        var ports = ArrayList(hir.HirPort).init(alloc);
        var registers = ArrayList(hir.HirRegister).init(alloc);
        var local_signals = ArrayList(hir.HirSignal).init(alloc);
        var comb_stmts = ArrayList(hir.HirStatement).init(alloc);
        var instances = ArrayList(hir.HirSubmoduleInstance).init(alloc);
        var parameters = ArrayList(hir.HirParameterBinding).init(alloc);

        var reg_map = std.StringHashMap(hir.HirRegister).init(alloc);
        var signal_types = std.StringHashMap(hir.HirType).init(alloc);

        var default_clk_name: ?[]const u8 = null;
        var default_rst_name: ?[]const u8 = null;
        var default_rst_active_low = false;
        var default_rst_is_sync = false;
        var local_consts = std.StringHashMap(u64).init(alloc);

        for (items) |item| {
            if (item.tag == .port) {
                const p = item.data.port;
                const h_type = self.lowerType(p.type_expr) catch null;
                if (h_type) |ht| {
                    if (ht.tag == .clock) {
                        if (default_clk_name == null) default_clk_name = p.name;
                    }
                    if (ht.tag == .reset) {
                        if (default_rst_name == null) {
                            default_rst_name = p.name;
                            default_rst_active_low = ht.is_active_low;
                            default_rst_is_sync = ht.is_sync;
                        }
                    }
                    try signal_types.put(p.name, ht);
                }
            } else if (item.tag == .const_decl) {
                const c = item.data.const_decl;
                if (isClockCall(c.val)) {
                    std.debug.print(
                        \\
                        \\======================================================================
                        \\COMPILE ERROR: Clock Generator Inside Synthesizable Module '{s}'
                        \\======================================================================
                        \\Clock generators 'clock(...)' can only be declared inside a testbench.
                        \\Synthesizable modules must declare clock inputs as ports:
                        \\
                        \\    in {s}: clock,
                        \\======================================================================
                        \\
                        , .{ mod_name, c.name });
                    return error.ClockGenInModule;
                }
                if (c.type_annot) |ta| {
                    const h_type = self.lowerType(ta) catch null;
                    if (h_type) |ht| {
                        try signal_types.put(c.name, ht);
                    }
                }
            } else if (item.tag == .stmt and item.data.stmt.tag == .var_decl) {
                const vd = item.data.stmt.data.var_decl;
                if (isClockCall(vd.init_val)) {
                    std.debug.print(
                        \\
                        \\======================================================================
                        \\COMPILE ERROR: Clock Generator Inside Synthesizable Module '{s}'
                        \\======================================================================
                        \\Clock generators 'clock(...)' can only be declared inside a testbench.
                        \\Synthesizable modules must declare clock inputs as ports:
                        \\
                        \\    in {s}: clock,
                        \\======================================================================
                        \\
                        , .{ mod_name, vd.name });
                    return error.ClockGenInModule;
                }
                if (vd.type_annot) |ta| {
                    const h_type = self.lowerType(ta) catch null;
                    if (h_type) |ht| {
                        try signal_types.put(vd.name, ht);
                    }
                }
            }
        }

        // First pass: Ports, Registers, Instances, Constants
        for (items) |item| {
            switch (item.tag) {
                .port => {
                    const p = item.data.port;
                    const h_type = try self.lowerType(p.type_expr);
                    try ports.append(.{
                        .name = p.name,
                        .dir = switch (p.dir) {
                            .in => .in,
                            .out => .out,
                            .inout => .inout,
                        },
                        .hir_type = h_type,
                        .is_async = p.is_async,
                    });
                    try signal_types.put(p.name, h_type);
                },
                .reg_decl => {
                    const r = item.data.reg_decl;
                    const h_type = try self.lowerType(r.type_expr);
                    const q_name = try std.fmt.allocPrint(alloc, "{s}_q", .{r.name});
                    const d_name = try std.fmt.allocPrint(alloc, "{s}_d", .{r.name});

                    const clk_str = if (r.clk != null and r.clk.?.tag == .identifier)
                        r.clk.?.data.identifier
                    else blk: {
                        if (default_clk_name) |dcn| {
                            break :blk dcn;
                        } else {
                            std.debug.print(
                                \\
                                \\======================================================================
                                \\COMPILE ERROR: Missing Clock Signal for Register '{s}' in module '{s}'
                                \\======================================================================
                                \\Register '{s}' does not specify an explicit clock, and the module
                                \\does not declare any input port with type 'clock'.
                                \\
                                \\Fix:
                                \\  1. Declare a clock port in the module:
                                \\       in clk: clock,
                                \\  2. Or specify the clock explicitly on the register:
                                \\       reg(clk) {s}: ... = 0;
                                \\======================================================================
                                \\
                                , .{ r.name, mod_name, r.name, r.name });
                            return error.MissingClockSignal;
                        }
                    };

                    const rst_str: ?[]const u8 = if (r.rst != null) blk: {
                        if (r.rst.?.tag == .identifier) {
                            break :blk r.rst.?.data.identifier;
                        } else if (r.rst.?.tag == .enum_literal and std.mem.eql(u8, r.rst.?.data.enum_literal, "none")) {
                            break :blk null;
                        } else {
                            break :blk default_rst_name;
                        }
                    } else default_rst_name;

                    var rst_active_low = false;
                    var rst_is_sync = false;
                    if (r.rst_polarity) |pol| {
                        rst_active_low = pol;
                    } else if (rst_str) |s| {
                        if (signal_types.get(s)) |st| {
                            rst_active_low = st.is_active_low;
                            rst_is_sync = st.is_sync;
                        } else if (std.mem.eql(u8, s, default_rst_name orelse "")) {
                            rst_active_low = default_rst_active_low;
                            rst_is_sync = default_rst_is_sync;
                        }
                    }
                    var init_val: u64 = if (r.init_val.tag == .number) r.init_val.data.number.val else 0;
                    if (h_type.tag == .tagged_union and r.init_val.tag == .struct_init) {
                        const si = r.init_val.data.struct_init;
                        if (si.fields.len > 0) {
                            if (h_type.getUnionField(si.fields[0].name)) |uf| {
                                var v: u64 = if (h_type.elem_width < 64) uf.tag_value << @intCast(h_type.elem_width) else 0;
                                if (uf.payload_width > 0) {
                                    const pv = self.evalConst(si.fields[0].value);
                                    const mask = if (uf.payload_width >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(uf.payload_width)) - 1;
                                    v |= (pv & mask);
                                }
                                init_val = v;
                            }
                        }
                    }

                    const hir_reg: hir.HirRegister = .{
                        .name = r.name,
                        .q_name = q_name,
                        .d_name = d_name,
                        .hir_type = h_type,
                        .clk_name = clk_str,
                        .rst_name = rst_str,
                        .rst_active_low = rst_active_low,
                        .rst_is_sync = rst_is_sync,
                        .init_val = init_val,
                    };

                    try registers.append(hir_reg);
                    try reg_map.put(r.name, hir_reg);
                    try signal_types.put(r.name, h_type);
                    try signal_types.put(q_name, h_type);
                    try signal_types.put(d_name, h_type);

                    // Add Q and D to local signals
                    try local_signals.append(.{ .name = q_name, .hir_type = h_type });
                    try local_signals.append(.{ .name = d_name, .hir_type = h_type });
                },
                .const_decl => {
                    const c = item.data.const_decl;
                    if (self.resolveGenericCall(c.val, items) != null) {
                        // generic module alias - skip creating hardware wire
                    } else if (c.val.tag == .type_expr) {
                        if (c.val.data.type_expr.tag == .struct_type) {
                            _ = try self.registerNamespace(c.name, c.val.data.type_expr.data.struct_type.decls, module_ports, alloc);
                        } else {
                            var h_type = try self.lowerType(c.val.data.type_expr);
                            h_type.name = c.name;
                            try self.types.put(c.name, h_type);
                            try signal_types.put(c.name, h_type);
                            try self.registerTypeMethods(c.name, c.val.data.type_expr);
                            try self.registerTypeConstantsAndVariants(c.name, c.val.data.type_expr);
                        }
                    } else if (c.type_annot) |ta| {
                        const h_type = try self.lowerType(ta);
                        if (!is_extern) {
                            try local_signals.append(.{ .name = c.name, .hir_type = h_type });
                        }
                        try signal_types.put(c.name, h_type);
                        if (is_extern) {
                            const const_v = self.evalConstEx(c.val, &local_consts);
                            try local_consts.put(c.name, const_v);
                            try self.constants.put(c.name, const_v);
                        }
                    } else if (c.val.tag == .number) {
                        try local_consts.put(c.name, c.val.data.number.val);
                        try self.constants.put(c.name, c.val.data.number.val);
                        if (!is_extern) {
                            const h_type: hir.HirType = .{ .tag = .bits, .width = 32 };
                            try local_signals.append(.{ .name = c.name, .hir_type = h_type });
                            try signal_types.put(c.name, h_type);
                        }
                    } else {
                        const const_v = self.evalConstEx(c.val, &local_consts);
                        if (const_v > 0) {
                            try local_consts.put(c.name, const_v);
                        }
                        const val = try self.lowerExpr(alloc, c.val, &reg_map, &signal_types);
                        const h_type = if (val.hir_type.width > 0) val.hir_type else hir.HirType{ .tag = .bits, .width = 32 };
                        if (!is_extern) {
                            try local_signals.append(.{ .name = c.name, .hir_type = h_type });
                        }
                        try signal_types.put(c.name, h_type);
                    }
                    if (is_extern and c.val.tag != .type_expr and self.resolveGenericCall(c.val, items) == null) {
                        const val = try self.lowerExpr(alloc, c.val, &reg_map, &signal_types);
                        try parameters.append(.{
                            .name = c.name,
                            .expr = val,
                        });
                    }
                },
                else => {},
            }
        }

        // Activate dynamic elaboration state for submodules, synchronizers, and blocks
        self.active_registers = &registers;
        self.active_local_signals = &local_signals;
        self.active_comb_stmts = &comb_stmts;
        self.active_reg_map = &reg_map;
        self.active_signal_types = &signal_types;
        defer {
            self.active_registers = null;
            self.active_local_signals = null;
            self.active_comb_stmts = null;
            self.active_reg_map = null;
            self.active_signal_types = null;
        }

        // Second pass: Instances (now all ports, registers and local signals are known)
        for (items) |item| {
            if (item.tag == .instance) {
                const inst = item.data.instance;
                var target_mod: []const u8 = undefined;

                if (self.resolveGenericCall(inst.module_expr, items)) |call_expr| {
                    target_mod = try self.getOrMonomorphizeModule(alloc, call_expr, modules, module_ports, &local_consts);
                } else if (inst.module_expr.tag == .identifier) {
                    const id = inst.module_expr.data.identifier;
                    if (self.findModuleDecl(id)) |md| {
                        target_mod = if (md.tag == .module_decl) md.data.module_decl.name else md.data.const_decl.name;
                    } else {
                        target_mod = id;
                    }
                } else if (inst.module_expr.tag == .member_access) {
                    const ma = inst.module_expr.data.member_access;
                    if (exprToDottedString(alloc, ma.target)) |pkg_id| {
                        if (self.packages.get(pkg_id)) |pkg| {
                            if (pkg.modules.get(ma.field)) |md| {
                                target_mod = if (md.tag == .module_decl) md.data.module_decl.name else md.data.const_decl.name;
                            } else {
                                target_mod = ma.field;
                            }
                        } else {
                            target_mod = ma.field;
                        }
                    } else {
                        target_mod = ma.field;
                    }
                } else {
                    target_mod = "Submodule";
                }

                if (self.module_foreign_names.get(target_mod)) |fname| {
                    target_mod = fname;
                }

                if (!self.isModuleElaborated(modules, target_mod)) {
                    const md_opt = self.findModuleDecl(target_mod) orelse (if (inst.module_expr.tag == .member_access) (if (exprToDottedString(alloc, inst.module_expr)) |dot| self.all_module_decls.get(dot) else null) else null);
                    if (md_opt) |md| {
                        const m_items = if (md.tag == .module_decl) md.data.module_decl.items else md.data.const_decl.val.data.module_literal.items;
                        const m_is_extern = if (md.tag == .module_decl) md.data.module_decl.is_extern else md.data.const_decl.val.data.module_literal.is_extern;
                        const m_foreign_name = if (md.tag == .module_decl) md.data.module_decl.foreign_name else md.data.const_decl.val.data.module_literal.foreign_name;
                        const m_include_path = if (md.tag == .module_decl) md.data.module_decl.include_path else md.data.const_decl.val.data.module_literal.include_path;
                        const hir_m = try self.elaborateModule(
                            alloc,
                            target_mod,
                            m_items,
                            module_ports,
                            modules,
                            m_is_extern,
                            m_foreign_name,
                            m_include_path,
                        );
                        try modules.append(hir_m);
                    }
                }

                var params = ArrayList(hir.HirParameterBinding).init(alloc);
                for (inst.parameters) |p| {
                    const h_expr = try self.lowerExpr(alloc, p.expr, &reg_map, &signal_types);
                    try params.append(.{
                        .name = p.port_name,
                        .expr = h_expr,
                    });
                }

                var conns = ArrayList(hir.HirPortConnection).init(alloc);
                for (inst.bindings) |b| {
                    const h_expr = try self.lowerExpr(alloc, b.expr, &reg_map, &signal_types);
                    try conns.append(.{
                        .port_name = b.port_name,
                        .expr = h_expr,
                    });
                }

                try instances.append(.{
                    .instance_name = inst.name,
                    .module_name = target_mod,
                    .parameters = try params.toOwnedSlice(),
                    .connections = try conns.toOwnedSlice(),
                });
            }
        }

        // Automatic default-hold for registers: count_d = count_q;
        // This guarantees 100% latch-free synthesizable logic!
        for (registers.items) |r| {
            if (r.is_sync_stage) continue;
            const target = try alloc.create(hir.HirExpr);
            target.* = .{
                .tag = .signal_ref,
                .hir_type = r.hir_type,
                .data = .{ .signal_ref = .{ .name = r.d_name } },
            };

            const src = try alloc.create(hir.HirExpr);
            src.* = .{
                .tag = .signal_ref,
                .hir_type = r.hir_type,
                .data = .{ .signal_ref = .{ .name = r.q_name } },
            };

            try comb_stmts.append(.{
                .tag = .assign,
                .data = .{
                    .assign = .{
                        .target = target,
                        .value = src,
                    },
                },
            });
        }

        // Second pass: comb and sync blocks
        for (items) |item| {
            switch (item.tag) {
                .const_decl => {
                    if (is_extern) continue;
                    const c = item.data.const_decl;
                    if (c.val.tag != .number and c.val.tag != .type_expr and self.resolveGenericCall(c.val, items) == null) {
                        const target = try alloc.create(hir.HirExpr);
                        const h_type = signal_types.get(c.name) orelse hir.HirType{ .tag = .bits, .width = 32 };
                        target.* = .{
                            .tag = .signal_ref,
                            .hir_type = h_type,
                            .data = .{ .signal_ref = .{ .name = c.name } },
                        };
                        const val = try self.lowerExpr(alloc, c.val, &reg_map, &signal_types);
                        if (val.tag == .lit and h_type.width > 0) {
                            val.hir_type.width = h_type.width;
                        }
                        if (h_type.tag == .array and val.tag == .array_init) {
                            for (val.data.array_init.elements) |elem| {
                                if (elem.tag == .lit and h_type.elem_width > 0) {
                                    elem.hir_type.width = h_type.elem_width;
                                }
                            }
                        }
                        try comb_stmts.append(.{
                            .tag = .assign,
                            .data = .{
                                .assign = .{
                                    .target = target,
                                    .value = val,
                                },
                            },
                        });
                    }
                },
                .comb_block => {
                    for (item.data.comb_block.stmts) |stmt| {
                        try self.lowerStatement(alloc, stmt, &comb_stmts, &local_signals, &reg_map, &signal_types);
                    }
                },
                .stmt => {
                    try self.lowerStatement(alloc, item.data.stmt, &comb_stmts, &local_signals, &reg_map, &signal_types);
                },
                else => {},
            }
        }

        // Race condition prevention:
        if (!is_extern) {
            // 1. Single-writer rule (no multi-driven nets, no writes to input ports)
            try self.checkMultiDrivers(alloc, mod_name, items, ports.items, instances.items, &reg_map, module_ports);

            // 2. Combinational cycle detection (no zero-delay feedback loops or ring oscillators)
            try self.checkCombinationalLoops(alloc, mod_name, ports.items, local_signals.items, comb_stmts.items, &reg_map);

            // 3. Read-before-write analysis (prevent delta-cycle simulation races & uninitialized nets)
            try self.checkReadBeforeWrite(alloc, mod_name, ports.items, local_signals.items, comb_stmts.items, &reg_map, instances.items, module_ports);

            // 4. Clock Domain Crossing (CDC) verification (no unsynchronized multi-clock domain sampling)
            try self.checkClockDomainCrossing(alloc, mod_name, registers.items, comb_stmts.items, &reg_map, ports.items);
        }

        return .{
            .name = mod_name,
            .is_extern = is_extern,
            .foreign_name = foreign_name,
            .include_path = include_path,
            .parameters = try parameters.toOwnedSlice(),
            .ports = try ports.toOwnedSlice(),
            .registers = try registers.toOwnedSlice(),
            .local_signals = try local_signals.toOwnedSlice(),
            .comb_stmts = try comb_stmts.toOwnedSlice(),
            .instances = try instances.toOwnedSlice(),
        };
    }

    fn elaborateTestbench(
        self: *Elaborator,
        alloc: std.mem.Allocator,
        tb_name: []const u8,
        items: []ast.ModuleItem,
        module_ports: *std.StringHashMap([]hir.HirPort),
        modules: *ArrayList(hir.HirModule),
    ) !hir.HirTestbench {
        var signals = ArrayList(hir.HirSignal).init(alloc);
        var clock_gens = ArrayList(hir.HirClockGen).init(alloc);
        var instances = ArrayList(hir.HirSubmoduleInstance).init(alloc);
        var sim_stmts = ArrayList(hir.HirSimStmt).init(alloc);
        var signal_types = std.StringHashMap(hir.HirType).init(alloc);
        defer signal_types.deinit();
        var reg_map = std.StringHashMap(hir.HirRegister).init(alloc);
        defer reg_map.deinit();

        // 1. Collect signals (wires, registers, ports)
        for (items) |item| {
            switch (item.tag) {
                .port => {
                    const p = item.data.port;
                    const h_type = try self.lowerType(p.type_expr);
                    try signals.append(.{ .name = p.name, .hir_type = h_type });
                    try signal_types.put(p.name, h_type);
                },
                .const_decl => {
                    const c = item.data.const_decl;
                    if (self.resolveGenericCall(c.val, items) != null) {
                        // generic module alias - skip
                    } else if (c.val.tag == .type_expr) {
                    } else if (isClockCall(c.val)) {
                        const cg = try extractClockGen(alloc, c.name, c.val);
                        try clock_gens.append(cg);
                        const h_type: hir.HirType = .{ .tag = .clock, .width = 1 };
                        try signals.append(.{ .name = c.name, .hir_type = h_type });
                        try signal_types.put(c.name, h_type);
                    } else if (isResetCall(c.val)) {
                        const rst_info = try extractResetInfo(c.name, c.val);
                        const h_type: hir.HirType = .{
                            .tag = .reset,
                            .width = 1,
                            .is_active_low = rst_info.is_active_low,
                            .is_sync = rst_info.is_sync,
                        };
                        try signals.append(.{ .name = c.name, .hir_type = h_type });
                        try signal_types.put(c.name, h_type);
                    } else if (c.type_annot) |ta| {
                        const h_type = try self.lowerType(ta);
                        if (h_type.tag == .clock) {
                            std.debug.print(
                                \\
                                \\======================================================================
                                \\COMPILE ERROR: Uninitialized Clock Declaration '{s}'
                                \\======================================================================
                                \\Clocks must be initialized declaratively with a frequency or period:
                                \\
                                \\    var {s} = clock(100MHz);
                                \\    // or: wire {s} = clock(10ns);
                                \\======================================================================
                                \\
                                , .{ c.name, c.name, c.name });
                            return error.UninitializedClock;
                        }
                        try signals.append(.{ .name = c.name, .hir_type = h_type });
                        try signal_types.put(c.name, h_type);
                    } else if (c.val.tag == .number) {
                        try self.constants.put(c.name, c.val.data.number.val);
                    } else {
                        const h_type: hir.HirType = .{ .tag = .bits, .width = 32 };
                        try signals.append(.{ .name = c.name, .hir_type = h_type });
                        try signal_types.put(c.name, h_type);
                    }
                },
                .reg_decl => {
                    const r = item.data.reg_decl;
                    const h_type = try self.lowerType(r.type_expr);
                    try signals.append(.{ .name = r.name, .hir_type = h_type });
                    try signal_types.put(r.name, h_type);
                },
                .stmt => {
                    if (item.data.stmt.tag == .var_decl) {
                        const vd = item.data.stmt.data.var_decl;
                        if (isClockCall(vd.init_val)) {
                            const cg = try extractClockGen(alloc, vd.name, vd.init_val);
                            try clock_gens.append(cg);
                            const h_type: hir.HirType = .{ .tag = .clock, .width = 1 };
                            try signals.append(.{ .name = vd.name, .hir_type = h_type });
                            try signal_types.put(vd.name, h_type);
                        } else if (isResetCall(vd.init_val)) {
                            const rst_info = try extractResetInfo(vd.name, vd.init_val);
                            const h_type: hir.HirType = .{
                                .tag = .reset,
                                .width = 1,
                                .is_active_low = rst_info.is_active_low,
                                .is_sync = rst_info.is_sync,
                            };
                            try signals.append(.{ .name = vd.name, .hir_type = h_type });
                            try signal_types.put(vd.name, h_type);
                        } else if (vd.type_annot) |ta| {
                            const h_type = try self.lowerType(ta);
                            if (h_type.tag == .clock) {
                                std.debug.print(
                                    \\
                                    \\======================================================================
                                    \\COMPILE ERROR: Uninitialized Clock Declaration '{s}'
                                    \\======================================================================
                                    \\Clocks must be initialized declaratively with a frequency or period:
                                    \\
                                    \\    var {s} = clock(100MHz);
                                    \\    // or: wire {s} = clock(10ns);
                                    \\======================================================================
                                    \\
                                    , .{ vd.name, vd.name, vd.name });
                                return error.UninitializedClock;
                            }
                            try signals.append(.{ .name = vd.name, .hir_type = h_type });
                            try signal_types.put(vd.name, h_type);
                        } else {
                            const h_type: hir.HirType = .{ .tag = .bits, .width = 32 };
                            try signals.append(.{ .name = vd.name, .hir_type = h_type });
                            try signal_types.put(vd.name, h_type);
                        }
                    }
                },
                .sim_block => {
                    for (item.data.sim_block.stmts) |s| {
                        if (s.tag == .var_decl) {
                            const vd = s.data.var_decl;
                            if (isClockCall(vd.init_val)) {
                                const cg = try extractClockGen(alloc, vd.name, vd.init_val);
                                try clock_gens.append(cg);
                                const h_type: hir.HirType = .{ .tag = .clock, .width = 1 };
                                try signals.append(.{ .name = vd.name, .hir_type = h_type });
                                try signal_types.put(vd.name, h_type);
                            } else if (isResetCall(vd.init_val)) {
                                const rst_info = try extractResetInfo(vd.name, vd.init_val);
                                const h_type: hir.HirType = .{
                                    .tag = .reset,
                                    .width = 1,
                                    .is_active_low = rst_info.is_active_low,
                                    .is_sync = rst_info.is_sync,
                                };
                                try signals.append(.{ .name = vd.name, .hir_type = h_type });
                                try signal_types.put(vd.name, h_type);
                            } else if (vd.type_annot) |ta| {
                                const h_type = try self.lowerType(ta);
                                if (h_type.tag == .clock) {
                                    std.debug.print(
                                        \\
                                        \\======================================================================
                                        \\COMPILE ERROR: Uninitialized Clock Declaration '{s}'
                                        \\======================================================================
                                        \\Clocks must be initialized declaratively with a frequency or period:
                                        \\
                                        \\    var {s} = clock(100MHz);
                                        \\    // or: wire {s} = clock(10ns);
                                        \\======================================================================
                                        \\
                                        , .{ vd.name, vd.name, vd.name });
                                    return error.UninitializedClock;
                                }
                                try signals.append(.{ .name = vd.name, .hir_type = h_type });
                                try signal_types.put(vd.name, h_type);
                            } else {
                                const h_type: hir.HirType = .{ .tag = .bits, .width = 32 };
                                try signals.append(.{ .name = vd.name, .hir_type = h_type });
                                try signal_types.put(vd.name, h_type);
                            }
                        }
                    }
                },
                else => {},
            }
        }

        // 2. Instances (DUT instantiation)
        for (items) |item| {
            if (item.tag == .instance) {
                const inst = item.data.instance;
                var target_mod: []const u8 = undefined;

                if (self.resolveGenericCall(inst.module_expr, items)) |call_expr| {
                    target_mod = try self.getOrMonomorphizeModule(alloc, call_expr, modules, module_ports, null);
                } else if (inst.module_expr.tag == .identifier) {
                    const id = inst.module_expr.data.identifier;
                    if (self.findModuleDecl(id)) |md| {
                        target_mod = if (md.tag == .module_decl) md.data.module_decl.name else md.data.const_decl.name;
                    } else {
                        target_mod = id;
                    }
                } else if (inst.module_expr.tag == .member_access) {
                    const ma = inst.module_expr.data.member_access;
                    if (exprToDottedString(alloc, ma.target)) |pkg_id| {
                        if (self.packages.get(pkg_id)) |pkg| {
                            if (pkg.modules.get(ma.field)) |md| {
                                target_mod = if (md.tag == .module_decl) md.data.module_decl.name else md.data.const_decl.name;
                            } else {
                                target_mod = ma.field;
                            }
                        } else {
                            target_mod = ma.field;
                        }
                    } else {
                        target_mod = ma.field;
                    }
                } else {
                    target_mod = "DUT";
                }

                if (self.module_foreign_names.get(target_mod)) |fname| {
                    target_mod = fname;
                }

                if (!self.isModuleElaborated(modules, target_mod)) {
                    const md_opt = self.findModuleDecl(target_mod) orelse (if (inst.module_expr.tag == .member_access) (if (exprToDottedString(alloc, inst.module_expr)) |dot| self.all_module_decls.get(dot) else null) else null);
                    if (md_opt) |md| {
                        const m_items = if (md.tag == .module_decl) md.data.module_decl.items else md.data.const_decl.val.data.module_literal.items;
                        const m_is_extern = if (md.tag == .module_decl) md.data.module_decl.is_extern else md.data.const_decl.val.data.module_literal.is_extern;
                        const m_foreign_name = if (md.tag == .module_decl) md.data.module_decl.foreign_name else md.data.const_decl.val.data.module_literal.foreign_name;
                        const m_include_path = if (md.tag == .module_decl) md.data.module_decl.include_path else md.data.const_decl.val.data.module_literal.include_path;
                        const hir_m = try self.elaborateModule(
                            alloc,
                            target_mod,
                            m_items,
                            module_ports,
                            modules,
                            m_is_extern,
                            m_foreign_name,
                            m_include_path,
                        );
                        try modules.append(hir_m);
                    }
                }

                var params = ArrayList(hir.HirParameterBinding).init(alloc);
                for (inst.parameters) |p| {
                    const h_expr = try self.lowerExpr(alloc, p.expr, &reg_map, &signal_types);
                    try params.append(.{
                        .name = p.port_name,
                        .expr = h_expr,
                    });
                }

                var conns = ArrayList(hir.HirPortConnection).init(alloc);
                for (inst.bindings) |b| {
                    const h_expr = try self.lowerExpr(alloc, b.expr, &reg_map, &signal_types);
                    try conns.append(.{
                        .port_name = b.port_name,
                        .expr = h_expr,
                    });
                }

                try instances.append(.{
                    .instance_name = inst.name,
                    .module_name = target_mod,
                    .parameters = try params.toOwnedSlice(),
                    .connections = try conns.toOwnedSlice(),
                });
            }
        }

        // 3. Process simulation statements (from sim blocks, flat statements, and anonymous blocks)
        for (items) |item| {
            if (item.tag == .sim_block) {
                for (item.data.sim_block.stmts) |stmt| {
                    try self.lowerSimStatement(alloc, stmt, &sim_stmts, &clock_gens, &reg_map, &signal_types);
                }
            } else if (item.tag == .stmt) {
                try self.lowerSimStatement(alloc, item.data.stmt, &sim_stmts, &clock_gens, &reg_map, &signal_types);
            } else if (item.tag == .comb_block) {
                for (item.data.comb_block.stmts) |stmt| {
                    try self.lowerSimStatement(alloc, stmt, &sim_stmts, &clock_gens, &reg_map, &signal_types);
                }
            } else if (item.tag == .const_decl) {
                const c = item.data.const_decl;
                if (c.val.tag != .type_expr and self.resolveGenericCall(c.val, items) == null and !isClockCall(c.val) and !isResetCall(c.val)) {
                    if (c.type_annot != null) {
                        const is_zero = (c.val.tag == .number and c.val.data.number.val == 0);
                        if (!is_zero) {
                            const target = try alloc.create(hir.HirExpr);
                            const h_type = signal_types.get(c.name) orelse hir.HirType{ .tag = .bits, .width = 32 };
                            target.* = .{
                                .tag = .signal_ref,
                                .hir_type = h_type,
                                .data = .{ .signal_ref = .{ .name = c.name } },
                            };
                            const val = try self.lowerExpr(alloc, c.val, &reg_map, &signal_types);
                            if (val.tag == .lit and h_type.width > 0) {
                                val.hir_type.width = h_type.width;
                            }
                            if (h_type.tag == .array and val.tag == .array_init) {
                                for (val.data.array_init.elements) |elem| {
                                    if (elem.tag == .lit and h_type.elem_width > 0) {
                                        elem.hir_type.width = h_type.elem_width;
                                    }
                                }
                            }
                            try sim_stmts.append(.{
                                .tag = .assign,
                                .data = .{
                                    .assign = .{
                                        .target = target,
                                        .value = val,
                                    },
                                },
                            });
                        }
                    }
                }
            }
        }

        return .{
            .name = tb_name,
            .signals = try signals.toOwnedSlice(),
            .clock_gens = try clock_gens.toOwnedSlice(),
            .instances = try instances.toOwnedSlice(),
            .sim_stmts = try sim_stmts.toOwnedSlice(),
        };
    }

    fn convertToNs(lit: ast.TimeLiteral) u64 {
        return switch (lit.unit) {
            .ps => if (lit.val > 0 and lit.val < 1000) 1 else lit.val / 1000,
            .ns => lit.val,
            .us => lit.val * 1_000,
            .ms => lit.val * 1_000_000,
            .s => lit.val * 1_000_000_000,
        };
    }

    fn convertFreqToNs(fl: ast.FreqLiteral) u64 {
        const val: u64 = if (fl.val == 0) 1 else fl.val;
        const freq_hz: u64 = switch (fl.unit) {
            .hz => val,
            .khz => val * 1_000,
            .mhz => val * 1_000_000,
            .ghz => val * 1_000_000_000,
        };
        const one_billion: u64 = 1_000_000_000;
        if (freq_hz >= one_billion) return 1;
        return one_billion / freq_hz;
    }

    const FreqConversion = struct {
        period_ns: u64,
        half_period_str: []const u8,
    };

    fn convertFreqToPeriod(alloc: std.mem.Allocator, fl: ast.FreqLiteral) !FreqConversion {
        const val: u64 = if (fl.val == 0) 1 else fl.val;
        const freq_hz: u64 = switch (fl.unit) {
            .hz => val,
            .khz => val * 1_000,
            .mhz => val * 1_000_000,
            .ghz => val * 1_000_000_000,
        };

        const one_trillion: u128 = 1_000_000_000_000;
        const period_ps: u64 = @intCast(one_trillion / freq_hz);
        const half_ps: u64 = if (period_ps >= 2) period_ps / 2 else 1;
        const period_ns: u64 = if (period_ps >= 1000) period_ps / 1000 else 1;

        var half_str: []const u8 = undefined;
        if (half_ps >= 1000 and (half_ps % 1000) == 0) {
            half_str = try std.fmt.allocPrint(alloc, "{d}ns", .{half_ps / 1000});
        } else {
            half_str = try std.fmt.allocPrint(alloc, "{d}ps", .{half_ps});
        }

        return .{
            .period_ns = period_ns,
            .half_period_str = half_str,
        };
    }

    fn convertTimeToHalfPeriodStr(alloc: std.mem.Allocator, tl: ast.TimeLiteral) !struct { period_ns: u64, half_str: []const u8 } {
        const val = tl.val;
        const period_ps: u64 = switch (tl.unit) {
            .ps => val,
            .ns => val * 1000,
            .us => val * 1000000,
            .ms => val * 1000000000,
            .s => val * 1000000000000,
        };
        const half_ps: u64 = if (period_ps >= 2) period_ps / 2 else 1;
        const period_ns: u64 = if (period_ps >= 1000) period_ps / 1000 else 1;

        var half_str: []const u8 = undefined;
        if (half_ps >= 1000 and (half_ps % 1000) == 0) {
            half_str = try std.fmt.allocPrint(alloc, "{d}ns", .{half_ps / 1000});
        } else {
            half_str = try std.fmt.allocPrint(alloc, "{d}ps", .{half_ps});
        }
        return .{ .period_ns = period_ns, .half_str = half_str };
    }

    fn isClockCall(val: *ast.Expr) bool {
        if (val.tag == .call) {
            const callee = val.data.call.callee;
            if (callee.tag == .identifier and std.mem.eql(u8, callee.data.identifier, "clock")) {
                return true;
            }
        }
        return false;
    }

    fn isResetCall(val: *ast.Expr) bool {
        if (val.tag == .call) {
            const callee = val.data.call.callee;
            if (callee.tag == .identifier and std.mem.eql(u8, callee.data.identifier, "reset")) {
                return true;
            }
        }
        return false;
    }

    fn extractClockGen(alloc: std.mem.Allocator, clk_name: []const u8, val: *ast.Expr) !hir.HirClockGen {
        var period: u64 = 10;
        var raw_str: []const u8 = "10ns";
        var half_str: []const u8 = "5ns";
        const c = val.data.call;
        if (c.args.len > 0) {
            const p = c.args[0];
            if (p.tag == .freq_literal) {
                const fc = try convertFreqToPeriod(alloc, p.data.freq_literal);
                period = fc.period_ns;
                half_str = fc.half_period_str;
                raw_str = p.data.freq_literal.raw;
            } else if (p.tag == .time_literal) {
                const tc = try convertTimeToHalfPeriodStr(alloc, p.data.time_literal);
                period = tc.period_ns;
                half_str = tc.half_str;
                raw_str = p.data.time_literal.raw;
            } else if (p.tag == .number) {
                period = p.data.number.val;
                const half = if (period >= 2) period / 2 else 1;
                half_str = try std.fmt.allocPrint(alloc, "{d}ns", .{half});
                raw_str = try std.fmt.allocPrint(alloc, "{d}ns", .{period});
            }
        } else {
            std.debug.print(
                \\
                \\======================================================================
                \\COMPILE ERROR: Missing Frequency/Period for Clock '{s}'
                \\======================================================================
                \\Clock constructor requires a frequency or time literal argument:
                \\
                \\    var {s} = clock(100MHz);
                \\    // or: var {s} = clock(10ns);
                \\======================================================================
                \\
                , .{ clk_name, clk_name, clk_name });
            return error.MissingClockFrequency;
        }
        return .{
            .clk_name = clk_name,
            .period_ns = period,
            .half_period_str = half_str,
            .raw = raw_str,
        };
    }

    pub const ResetInfo = struct {
        is_active_low: bool = false,
        is_sync: bool = false,
    };

    fn extractResetInfo(rst_name: []const u8, val: *ast.Expr) !ResetInfo {
        const c = val.data.call;
        var has_mode = false;
        var is_sync = false;
        var is_active_low = false;

        for (c.args) |arg| {
            var tok: []const u8 = "";
            if (arg.tag == .enum_literal) {
                tok = arg.data.enum_literal;
            } else if (arg.tag == .identifier) {
                tok = arg.data.identifier;
            }

            if (std.mem.eql(u8, tok, "low") or std.mem.eql(u8, tok, "active_low")) {
                is_active_low = true;
            } else if (std.mem.eql(u8, tok, "high") or std.mem.eql(u8, tok, "active_high")) {
                is_active_low = false;
            } else if (std.mem.eql(u8, tok, "async")) {
                is_sync = false;
                has_mode = true;
            } else if (std.mem.eql(u8, tok, "sync")) {
                is_sync = true;
                has_mode = true;
            } else if (std.mem.eql(u8, tok, "async_low")) {
                is_sync = false;
                is_active_low = true;
                has_mode = true;
            } else if (std.mem.eql(u8, tok, "async_high")) {
                is_sync = false;
                is_active_low = false;
                has_mode = true;
            } else if (std.mem.eql(u8, tok, "sync_low")) {
                is_sync = true;
                is_active_low = true;
                has_mode = true;
            } else if (std.mem.eql(u8, tok, "sync_high")) {
                is_sync = true;
                is_active_low = false;
                has_mode = true;
            }
        }

        if (!has_mode) {
            std.debug.print(
                \\
                \\======================================================================
                \\COMPILE ERROR: Underspecified Reset Mode for '{s}'
                \\======================================================================
                \\Resets must explicitly declare their synchronization mode:
                \\  reset(.async)
                \\  reset(.async, .active_low)
                \\  reset(.sync)
                \\  reset(.sync, .active_low)
                \\======================================================================
                \\
            , .{rst_name});
            return error.UnderspecifiedReset;
        }

        return .{
            .is_active_low = is_active_low,
            .is_sync = is_sync,
        };
    }

    fn hasDotNext(target: *const ast.Expr) bool {
        switch (target.tag) {
            .member_access => {
                if (std.mem.eql(u8, target.data.member_access.field, "next")) return true;
                return hasDotNext(target.data.member_access.target);
            },
            .index => return hasDotNext(target.data.index.target),
            .slice => return hasDotNext(target.data.slice.target),
            .part_select => return hasDotNext(target.data.part_select.target),
            .builtin_call => {
                if (target.data.builtin_call.tag == .builtin_concat) {
                    for (target.data.builtin_call.args) |a| {
                        if (hasDotNext(a)) return true;
                    }
                }
                return false;
            },
            .array_init => {
                for (target.data.array_init.elements) |elem| {
                    if (hasDotNext(elem)) return true;
                }
                return false;
            },
            else => return false,
        }
    }

    fn collectAstTargetBaseNames(target: *const ast.Expr, out_names: *ArrayList([]const u8)) anyerror!void {
        switch (target.tag) {
            .identifier => try out_names.append(target.data.identifier),
            .member_access => {
                try collectAstTargetBaseNames(target.data.member_access.target, out_names);
            },
            .index => try collectAstTargetBaseNames(target.data.index.target, out_names),
            .slice => try collectAstTargetBaseNames(target.data.slice.target, out_names),
            .part_select => try collectAstTargetBaseNames(target.data.part_select.target, out_names),
            .builtin_call => {
                if (target.data.builtin_call.tag == .builtin_concat) {
                    for (target.data.builtin_call.args) |a| {
                        try collectAstTargetBaseNames(a, out_names);
                    }
                }
            },
            .array_init => {
                for (target.data.array_init.elements) |elem| {
                    try collectAstTargetBaseNames(elem, out_names);
                }
            },
            else => {},
        }
    }

    fn collectHirTargetBaseNames(target: *const hir.HirExpr, out_names: *ArrayList([]const u8)) anyerror!void {
        switch (target.tag) {
            .signal_ref => try out_names.append(target.data.signal_ref.name),
            .index => try collectHirTargetBaseNames(target.data.index.target, out_names),
            .slice => try collectHirTargetBaseNames(target.data.slice.target, out_names),
            .member => try collectHirTargetBaseNames(target.data.member.target, out_names),
            .part_select => try collectHirTargetBaseNames(target.data.part_select.target, out_names),
            .concat => {
                for (target.data.concat.args) |a| {
                    try collectHirTargetBaseNames(a, out_names);
                }
            },
            else => {},
        }
    }

    fn lowerTargetExpr(
        self: *Elaborator,
        alloc: std.mem.Allocator,
        target_ast: *ast.Expr,
        is_reg_assign: bool,
        reg_map: *const std.StringHashMap(hir.HirRegister),
        signal_types: *const std.StringHashMap(hir.HirType),
    ) anyerror!*hir.HirExpr {
        switch (target_ast.tag) {
            .identifier => {
                const name = target_ast.data.identifier;
                if (reg_map.get(name)) |r| {
                    const h_target = try alloc.create(hir.HirExpr);
                    h_target.* = .{
                        .tag = .signal_ref,
                        .hir_type = r.hir_type,
                        .data = .{ .signal_ref = .{ .name = r.d_name } },
                    };
                    return h_target;
                } else {
                    const h_type = signal_types.get(name) orelse hir.HirType{ .tag = .bits, .width = 32 };
                    const h_target = try alloc.create(hir.HirExpr);
                    h_target.* = .{
                        .tag = .signal_ref,
                        .hir_type = h_type,
                        .data = .{ .signal_ref = .{ .name = name } },
                    };
                    return h_target;
                }
            },
            .member_access => {
                const ma = target_ast.data.member_access;
                if (std.mem.eql(u8, ma.field, "next")) {
                    return try self.lowerTargetExpr(alloc, ma.target, true, reg_map, signal_types);
                }
                const sub_target = try self.lowerTargetExpr(alloc, ma.target, is_reg_assign, reg_map, signal_types);
                if (sub_target.hir_type.getStructField(ma.field)) |f| {
                    const h_target = try alloc.create(hir.HirExpr);
                    h_target.* = .{
                        .tag = .slice,
                        .hir_type = .{ .tag = .bits, .width = f.width },
                        .data = .{
                            .slice = .{
                                .target = sub_target,
                                .start = f.offset,
                                .end = f.offset + f.width,
                                .is_downward = false,
                            },
                        },
                    };
                    return h_target;
                }
                return try self.lowerExpr(alloc, target_ast, reg_map, signal_types);
            },
            .index => {
                const base = try self.lowerTargetExpr(alloc, target_ast.data.index.target, is_reg_assign, reg_map, signal_types);
                const idx_e = try self.lowerExpr(alloc, target_ast.data.index.index, reg_map, signal_types);
                const elem_w = if (base.hir_type.tag == .array) base.hir_type.elem_width else 1;
                const h_target = try alloc.create(hir.HirExpr);
                h_target.* = .{
                    .tag = .index,
                    .hir_type = .{ .tag = .bits, .width = elem_w },
                    .data = .{ .index = .{ .target = base, .index = idx_e } },
                };
                return h_target;
            },
            .slice => {
                const sl = target_ast.data.slice;
                const base = try self.lowerTargetExpr(alloc, sl.target, is_reg_assign, reg_map, signal_types);
                const s_val: u32 = @intCast(self.evalConst(sl.start));
                const e_val: u32 = @intCast(self.evalConst(sl.end));
                var is_down = sl.is_downward;
                var s = s_val;
                var e = e_val;
                if (s_val > e_val) {
                    is_down = true;
                    s = e_val;
                    e = s_val;
                }
                const w = if (e >= s) e - s else 1;
                const h_target = try alloc.create(hir.HirExpr);
                h_target.* = .{
                    .tag = .slice,
                    .hir_type = .{ .tag = .bits, .width = w },
                    .data = .{
                        .slice = .{
                            .target = base,
                            .start = s,
                            .end = e,
                            .is_downward = is_down,
                        },
                    },
                };
                return h_target;
            },
            .part_select => {
                const ps = target_ast.data.part_select;
                const base = try self.lowerTargetExpr(alloc, ps.target, is_reg_assign, reg_map, signal_types);
                const b_expr = try self.lowerExpr(alloc, ps.base, reg_map, signal_types);
                const w: u32 = @intCast(self.evalConst(ps.width));
                const h_target = try alloc.create(hir.HirExpr);
                h_target.* = .{
                    .tag = .part_select,
                    .hir_type = .{ .tag = .bits, .width = w },
                    .data = .{
                        .part_select = .{
                            .target = base,
                            .base = b_expr,
                            .width = w,
                            .is_up = ps.is_up,
                        },
                    },
                };
                return h_target;
            },
            .builtin_call => {
                const bc = target_ast.data.builtin_call;
                if (bc.tag == .builtin_concat) {
                    var args = ArrayList(*hir.HirExpr).init(alloc);
                    var total_w: u32 = 0;
                    for (bc.args) |a| {
                        const sub = try self.lowerTargetExpr(alloc, a, is_reg_assign, reg_map, signal_types);
                        try args.append(sub);
                        total_w += sub.hir_type.width;
                    }
                    const h_target = try alloc.create(hir.HirExpr);
                    h_target.* = .{
                        .tag = .concat,
                        .hir_type = .{ .tag = .bits, .width = total_w },
                        .data = .{ .concat = .{ .args = try args.toOwnedSlice() } },
                    };
                    return h_target;
                }
                return try self.lowerExpr(alloc, target_ast, reg_map, signal_types);
            },
            .array_init => {
                const ai = target_ast.data.array_init;
                var args = ArrayList(*hir.HirExpr).init(alloc);
                var total_w: u32 = 0;
                for (ai.elements) |elem| {
                    const sub = try self.lowerTargetExpr(alloc, elem, is_reg_assign, reg_map, signal_types);
                    try args.append(sub);
                    total_w += sub.hir_type.width;
                }
                const h_target = try alloc.create(hir.HirExpr);
                h_target.* = .{
                    .tag = .concat,
                    .hir_type = .{ .tag = .bits, .width = total_w },
                    .data = .{ .concat = .{ .args = try args.toOwnedSlice() } },
                };
                return h_target;
            },
            else => return try self.lowerExpr(alloc, target_ast, reg_map, signal_types),
        }
    }

    fn lowerSimStatement(
        self: *Elaborator,
        alloc: std.mem.Allocator,
        stmt: ast.Statement,
        sim_stmts: *ArrayList(hir.HirSimStmt),
        clock_gens: *ArrayList(hir.HirClockGen),
        reg_map: *const std.StringHashMap(hir.HirRegister),
        signal_types: *std.StringHashMap(hir.HirType),
    ) !void {
        switch (stmt.tag) {
            .assign => {
                const a = stmt.data.assign;
                const target = try self.lowerTargetExpr(alloc, a.target, false, reg_map, signal_types);
                var val_expr: *hir.HirExpr = undefined;

                if (target.hir_type.tag == .optional) {
                    if (a.value.tag == .null_lit) {
                        val_expr = try alloc.create(hir.HirExpr);
                        val_expr.* = .{
                            .tag = .lit,
                            .hir_type = target.hir_type,
                            .data = .{ .lit = .{ .val = 0, .raw = "0" } },
                        };
                    } else {
                        val_expr = try self.lowerExpr(alloc, a.value, reg_map, signal_types);
                        if (val_expr.hir_type.tag != .optional) {
                            const one_lit = try alloc.create(hir.HirExpr);
                            one_lit.* = .{
                                .tag = .lit,
                                .hir_type = .{ .tag = .bits, .width = 1 },
                                .data = .{ .lit = .{ .val = 1, .raw = "1'b1" } },
                            };
                            if (val_expr.tag == .lit and target.hir_type.elem_width > 0) {
                                val_expr.hir_type.width = target.hir_type.elem_width;
                            }
                            var cat_args = try alloc.alloc(*hir.HirExpr, 2);
                            cat_args[0] = one_lit;
                            cat_args[1] = val_expr;
                            const wrapped = try alloc.create(hir.HirExpr);
                            wrapped.* = .{
                                .tag = .concat,
                                .hir_type = target.hir_type,
                                .data = .{ .concat = .{ .args = cat_args } },
                            };
                            val_expr = wrapped;
                        }
                    }
                } else if (target.hir_type.tag == .tagged_union and a.value.tag == .struct_init) {
                    const si = a.value.data.struct_init;
                    if (si.fields.len > 0) {
                        val_expr = try self.lowerTaggedUnionInit(alloc, target.hir_type, si.fields[0], reg_map, signal_types);
                    } else {
                        val_expr = try alloc.create(hir.HirExpr);
                        val_expr.* = .{
                            .tag = .lit,
                            .hir_type = target.hir_type,
                            .data = .{ .lit = .{ .val = 0, .raw = "0" } },
                        };
                    }
                } else if (a.value.tag == .struct_init and a.value.data.struct_init.type_expr == null and target.hir_type.struct_fields.len > 0) {
                    const st = target.hir_type;
                    const si = a.value.data.struct_init;
                    var concat_args = ArrayList(*hir.HirExpr).init(alloc);
                    var idx = st.struct_fields.len;
                    while (idx > 0) {
                        idx -= 1;
                        const sf = st.struct_fields[idx];
                        var found_val: ?*ast.Expr = null;
                        for (si.fields) |f| {
                            if (std.mem.eql(u8, f.name, sf.name)) {
                                found_val = f.value;
                                break;
                            }
                        }
                        if (found_val) |fv| {
                            const lowered_f = try self.lowerExpr(alloc, fv, reg_map, signal_types);
                            if (lowered_f.tag == .lit and sf.width > 0) {
                                lowered_f.hir_type.width = sf.width;
                            }
                            try concat_args.append(lowered_f);
                        } else {
                            const zero_expr = try alloc.create(hir.HirExpr);
                            zero_expr.* = .{
                                .tag = .lit,
                                .hir_type = .{ .tag = .bits, .width = sf.width },
                                .data = .{ .lit = .{ .val = 0, .raw = "0" } },
                            };
                            try concat_args.append(zero_expr);
                        }
                    }
                    val_expr = try alloc.create(hir.HirExpr);
                    val_expr.* = .{
                        .tag = .concat,
                        .hir_type = st,
                        .data = .{ .concat = .{ .args = try concat_args.toOwnedSlice() } },
                    };
                } else {
                    val_expr = try self.lowerExpr(alloc, a.value, reg_map, signal_types);
                }

                if (val_expr.tag == .lit and target.hir_type.width > 0) {
                    val_expr.hir_type.width = target.hir_type.width;
                    if (target.hir_type.is_signed) val_expr.hir_type.is_signed = true;
                } else if (val_expr.tag == .unary and val_expr.data.unary.operand.tag == .lit and target.hir_type.width > 0) {
                    val_expr.hir_type.width = target.hir_type.width;
                    val_expr.data.unary.operand.hir_type.width = target.hir_type.width;
                    if (target.hir_type.is_signed) {
                        val_expr.hir_type.is_signed = true;
                        val_expr.data.unary.operand.hir_type.is_signed = true;
                    }
                }
                if (target.hir_type.tag != .array and val_expr.tag == .array_init) {
                    const elems = val_expr.data.array_init.elements;
                    val_expr.tag = .concat;
                    val_expr.data = .{ .concat = .{ .args = elems } };
                }
                try sim_stmts.append(.{
                    .tag = .assign,
                    .data = .{
                        .assign = .{
                            .target = target,
                            .value = val_expr,
                        },
                    },
                });
            },
            .expr_stmt => {
                const expr = stmt.data.expr_stmt;
                if (expr.tag == .call) {
                    const c = expr.data.call;
                    if (c.callee.tag == .member_access) {
                        const ma = c.callee.data.member_access;
                        if (ma.target.tag == .identifier) {
                            const obj_name = ma.target.data.identifier;
                            if (std.mem.eql(u8, ma.field, "generate")) {
                                std.debug.print(
                                    \\
                                    \\======================================================================
                                    \\COMPILE ERROR: Deprecated 'clk.generate()' Syntax
                                    \\======================================================================
                                    \\Procedural 'clk.generate(...)' is deprecated and no longer supported.
                                    \\In ZHdl, clocks must be declared declaratively upfront at testbench scope:
                                    \\
                                    \\    var {s} = clock(100MHz);
                                    \\    // or: wire {s} = clock(10ns);
                                    \\======================================================================
                                    \\
                                    , .{ obj_name, obj_name });
                                return error.DeprecatedClockGenerate;
                            } else if (std.mem.eql(u8, ma.field, "wait_until")) {
                                if (c.args.len > 0) {
                                    const cond = try self.lowerExpr(alloc, c.args[0], reg_map, signal_types);
                                    var max_cycles: ?u64 = null;
                                    var timeout_raw: ?[]const u8 = null;
                                    if (c.args.len >= 2) {
                                        const timeout = c.args[1];
                                        if (timeout.tag == .time_literal) {
                                            timeout_raw = timeout.data.time_literal.raw;
                                            max_cycles = null;
                                        } else if (timeout.tag == .number) {
                                            max_cycles = timeout.data.number.val;
                                            timeout_raw = null;
                                        }
                                    }
                                    try sim_stmts.append(.{
                                        .tag = .wait_for,
                                        .data = .{
                                            .wait_for = .{
                                                .cond = cond,
                                                .max_cycles = max_cycles,
                                                .timeout_raw = timeout_raw,
                                                .clk_name = obj_name,
                                            },
                                        },
                                    });
                                    return;
                                }
                            } else if (std.mem.eql(u8, ma.field, "step")) {
                                var cycles: u64 = 1;
                                if (c.args.len > 0 and c.args[0].tag == .number) {
                                    cycles = c.args[0].data.number.val;
                                }
                                try sim_stmts.append(.{
                                    .tag = .step,
                                    .data = .{
                                        .step = .{
                                            .clk_name = obj_name,
                                            .cycles = cycles,
                                            .edge = .posedge,
                                        },
                                    },
                                });
                                return;
                            } else if (std.mem.eql(u8, ma.field, "posedge")) {
                                var cycles: u64 = 1;
                                if (c.args.len > 0 and c.args[0].tag == .number) {
                                    cycles = c.args[0].data.number.val;
                                }
                                try sim_stmts.append(.{
                                    .tag = .step,
                                    .data = .{
                                        .step = .{
                                            .clk_name = obj_name,
                                            .cycles = cycles,
                                            .edge = .posedge,
                                        },
                                    },
                                });
                                return;
                            } else if (std.mem.eql(u8, ma.field, "negedge")) {
                                var cycles: u64 = 1;
                                if (c.args.len > 0 and c.args[0].tag == .number) {
                                    cycles = c.args[0].data.number.val;
                                }
                                try sim_stmts.append(.{
                                    .tag = .step,
                                    .data = .{
                                        .step = .{
                                            .clk_name = obj_name,
                                            .cycles = cycles,
                                            .edge = .negedge,
                                        },
                                    },
                                });
                                return;
                            } else if (std.mem.eql(u8, ma.field, "pulse")) {
                                var cycles: ?u64 = null;
                                var duration_raw: ?[]const u8 = null;
                                var clk_name: ?[]const u8 = null;
                                if (c.args.len > 0) {
                                    if (c.args[0].tag == .time_literal) {
                                        duration_raw = c.args[0].data.time_literal.raw;
                                    } else if (c.args[0].tag == .number) {
                                        cycles = c.args[0].data.number.val;
                                    }
                                }
                                if (cycles == null and duration_raw == null) {
                                    cycles = 1;
                                }
                                var active_low = false;
                                if (signal_types.get(obj_name)) |st| {
                                    active_low = st.is_active_low;
                                }
                                if (c.args.len > 1) {
                                    if (c.args[1].tag == .identifier) {
                                        clk_name = c.args[1].data.identifier;
                                    } else if (c.args[1].tag == .enum_literal) {
                                        const lit = c.args[1].data.enum_literal;
                                        if (std.mem.eql(u8, lit, "low") or std.mem.eql(u8, lit, "active_low")) {
                                            active_low = true;
                                        } else if (std.mem.eql(u8, lit, "high") or std.mem.eql(u8, lit, "active_high")) {
                                            active_low = false;
                                        }
                                    }
                                }
                                if (c.args.len > 2 and clk_name == null) {
                                    if (c.args[2].tag == .identifier) {
                                        clk_name = c.args[2].data.identifier;
                                    }
                                }
                                try sim_stmts.append(.{
                                    .tag = .rst_pulse,
                                    .data = .{
                                        .rst_pulse = .{
                                            .rst_name = obj_name,
                                            .clk_name = clk_name,
                                            .cycles = cycles,
                                            .duration_raw = duration_raw,
                                            .active_low = active_low,
                                        },
                                    },
                                });
                                return;
                            } else if (std.mem.eql(u8, ma.field, "pulse_reset")) {
                                const clk_name = obj_name;
                                var rst_name: []const u8 = "rst";
                                var cycles: u64 = 1;
                                if (c.args.len > 0 and c.args[0].tag == .identifier) {
                                    rst_name = c.args[0].data.identifier;
                                }
                                if (c.args.len > 1 and c.args[1].tag == .number) {
                                    cycles = c.args[1].data.number.val;
                                }
                                var active_low = false;
                                if (signal_types.get(rst_name)) |st| {
                                    active_low = st.is_active_low;
                                }
                                try sim_stmts.append(.{
                                    .tag = .rst_pulse,
                                    .data = .{
                                        .rst_pulse = .{
                                            .rst_name = rst_name,
                                            .clk_name = clk_name,
                                            .cycles = cycles,
                                            .duration_raw = null,
                                            .active_low = active_low,
                                        },
                                    },
                                });
                                return;
                            } else if (std.mem.eql(u8, ma.field, "assert_signal") or std.mem.eql(u8, ma.field, "assert")) {
                                var active_low = false;
                                if (signal_types.get(obj_name)) |st| {
                                    active_low = st.is_active_low;
                                }
                                const active_val: u64 = if (active_low) 0 else 1;
                                const target = try alloc.create(hir.HirExpr);
                                target.* = .{
                                    .tag = .signal_ref,
                                    .hir_type = .{ .tag = .bits, .width = 1 },
                                    .data = .{ .signal_ref = .{ .name = obj_name } },
                                };
                                const val_expr = try alloc.create(hir.HirExpr);
                                val_expr.* = .{
                                    .tag = .lit,
                                    .hir_type = .{ .tag = .bits, .width = 1 },
                                    .data = .{
                                        .lit = .{
                                            .val = active_val,
                                            .raw = if (active_low) "0" else "1",
                                        },
                                    },
                                };
                                try sim_stmts.append(.{
                                    .tag = .assign,
                                    .data = .{
                                        .assign = .{
                                            .target = target,
                                            .value = val_expr,
                                        },
                                    },
                                });
                                return;
                            } else if (std.mem.eql(u8, ma.field, "deassert")) {
                                var active_low = false;
                                if (signal_types.get(obj_name)) |st| {
                                    active_low = st.is_active_low;
                                }
                                const inactive_val: u64 = if (active_low) 1 else 0;
                                const target = try alloc.create(hir.HirExpr);
                                target.* = .{
                                    .tag = .signal_ref,
                                    .hir_type = .{ .tag = .bits, .width = 1 },
                                    .data = .{ .signal_ref = .{ .name = obj_name } },
                                };
                                const val_expr = try alloc.create(hir.HirExpr);
                                val_expr.* = .{
                                    .tag = .lit,
                                    .hir_type = .{ .tag = .bits, .width = 1 },
                                    .data = .{
                                        .lit = .{
                                            .val = inactive_val,
                                            .raw = if (active_low) "1" else "0",
                                        },
                                    },
                                };
                                try sim_stmts.append(.{
                                    .tag = .assign,
                                    .data = .{
                                        .assign = .{
                                            .target = target,
                                            .value = val_expr,
                                        },
                                    },
                                });
                                return;
                            }
                        }
                    } else if (c.callee.tag == .identifier) {
                        const fn_name = c.callee.data.identifier;
                        if (std.mem.eql(u8, fn_name, "step")) {
                            std.debug.print(
                                \\
                                \\======================================================================
                                \\COMPILE ERROR: Deprecated Global 'step()' Call
                                \\======================================================================
                                \\Global 'step(...)' is deprecated and not permitted.
                                \\In ZHdl, clock stepping is a method on the clock signal:
                                \\    clk.step(N);
                                \\    clk.posedge();
                                \\    clk.negedge();
                                \\======================================================================
                                \\
                                , .{});
                            return error.DeprecatedGlobalStep;
                        } else if (std.mem.eql(u8, fn_name, "posedge")) {
                            std.debug.print(
                                \\
                                \\======================================================================
                                \\COMPILE ERROR: Deprecated Global 'posedge()' Call
                                \\======================================================================
                                \\Global 'posedge(...)' is deprecated and not permitted.
                                \\In ZHdl, edge stepping is a method on the clock signal:
                                \\    clk.posedge();
                                \\======================================================================
                                \\
                                , .{});
                            return error.DeprecatedGlobalPosedge;
                        } else if (std.mem.eql(u8, fn_name, "negedge")) {
                            std.debug.print(
                                \\
                                \\======================================================================
                                \\COMPILE ERROR: Deprecated Global 'negedge()' Call
                                \\======================================================================
                                \\Global 'negedge(...)' is deprecated and not permitted.
                                \\In ZHdl, edge stepping is a method on the clock signal:
                                \\    clk.negedge();
                                \\======================================================================
                                \\
                                , .{});
                            return error.DeprecatedGlobalNegedge;
                        } else if (std.mem.eql(u8, fn_name, "assert")) {
                            if (c.args.len > 0) {
                                const cond = try self.lowerExpr(alloc, c.args[0], reg_map, signal_types);
                                const msg: ?[]const u8 = if (c.args.len >= 2 and c.args[1].tag == .string)
                                    c.args[1].data.string
                                else
                                    null;
                                try sim_stmts.append(.{
                                    .tag = .assert_stmt,
                                    .data = .{
                                        .assert_stmt = .{
                                            .cond = cond,
                                            .msg = msg,
                                        },
                                    },
                                });
                                return;
                            }
                        } else if (std.mem.eql(u8, fn_name, "assert_within")) {
                            if (c.args.len >= 2) {
                                const cond = try self.lowerExpr(alloc, c.args[0], reg_map, signal_types);
                                var max_cycles: ?u64 = null;
                                var timeout_raw: ?[]const u8 = null;
                                const timeout = c.args[1];
                                if (timeout.tag == .time_literal) {
                                    timeout_raw = timeout.data.time_literal.raw;
                                    max_cycles = null;
                                } else if (timeout.tag == .number) {
                                    max_cycles = timeout.data.number.val;
                                    timeout_raw = null;
                                }
                                try sim_stmts.append(.{
                                    .tag = .wait_for,
                                    .data = .{
                                        .wait_for = .{
                                            .cond = cond,
                                            .max_cycles = max_cycles,
                                            .timeout_raw = timeout_raw,
                                        },
                                    },
                                });
                                return;
                            }
                        } else if (std.mem.eql(u8, fn_name, "wait_for")) {
                            if (c.args.len > 0) {
                                const cond = try self.lowerExpr(alloc, c.args[0], reg_map, signal_types);
                                var max_cycles: ?u64 = null;
                                var timeout_raw: ?[]const u8 = null;
                                if (c.args.len >= 2) {
                                    const timeout = c.args[1];
                                    if (timeout.tag == .time_literal) {
                                        timeout_raw = timeout.data.time_literal.raw;
                                        max_cycles = null;
                                    } else if (timeout.tag == .number) {
                                        max_cycles = timeout.data.number.val;
                                        timeout_raw = null;
                                    }
                                }
                                try sim_stmts.append(.{
                                    .tag = .wait_for,
                                    .data = .{
                                        .wait_for = .{
                                            .cond = cond,
                                            .max_cycles = max_cycles,
                                            .timeout_raw = timeout_raw,
                                        },
                                    },
                                });
                                return;
                            }
                        } else if (std.mem.eql(u8, fn_name, "trace")) {
                            const vcd_path: []const u8 = if (c.args.len > 0 and c.args[0].tag == .string)
                                c.args[0].data.string
                            else
                                "dump.vcd";
                            try sim_stmts.append(.{
                                .tag = .trace,
                                .data = .{
                                    .trace = .{
                                        .vcd_path = vcd_path,
                                    },
                                },
                            });
                            return;
                        } else if (std.mem.eql(u8, fn_name, "delay")) {
                            var ns: u64 = 10;
                            var raw_str: []const u8 = "10ns";
                            if (c.args.len > 0) {
                                const t = c.args[0];
                                if (t.tag == .time_literal) {
                                    raw_str = t.data.time_literal.raw;
                                    ns = convertToNs(t.data.time_literal);
                                } else if (t.tag == .number) {
                                    ns = t.data.number.val;
                                    raw_str = t.data.number.raw;
                                }
                            }
                            try sim_stmts.append(.{
                                .tag = .delay,
                                .data = .{
                                    .delay = .{
                                        .ns = ns,
                                        .raw = raw_str,
                                    },
                                },
                            });
                            return;
                        } else if (std.mem.eql(u8, fn_name, "finish")) {
                            try sim_stmts.append(.{
                                .tag = .finish,
                                .data = .{ .finish = {} },
                            });
                            return;
                        }
                    }
                }
            },
            .var_decl => {
                const vd = stmt.data.var_decl;
                if (isClockCall(vd.init_val) or isResetCall(vd.init_val)) return;
                const target = try alloc.create(hir.HirExpr);
                const h_type = signal_types.get(vd.name) orelse hir.HirType{ .tag = .bits, .width = 32 };
                target.* = .{
                    .tag = .signal_ref,
                    .hir_type = h_type,
                    .data = .{ .signal_ref = .{ .name = vd.name } },
                };
                var val_expr = try self.lowerExpr(alloc, vd.init_val, reg_map, signal_types);
                if (val_expr.tag == .lit and h_type.width > 0) {
                    val_expr.hir_type.width = h_type.width;
                    if (h_type.is_signed) val_expr.hir_type.is_signed = true;
                }
                if (h_type.tag == .array) {
                    if (val_expr.tag == .array_init) {
                        for (val_expr.data.array_init.elements) |elem| {
                            if (elem.tag == .lit and h_type.elem_width > 0) {
                                elem.hir_type.width = h_type.elem_width;
                            }
                        }
                    } else if (val_expr.tag == .lit and val_expr.data.lit.val == 0) {
                        var zero_elems = try alloc.alloc(*hir.HirExpr, h_type.array_len);
                        for (0..h_type.array_len) |zi| {
                            const z_expr = try alloc.create(hir.HirExpr);
                            z_expr.* = .{
                                .tag = .lit,
                                .hir_type = .{ .tag = .bits, .width = h_type.elem_width },
                                .data = .{ .lit = .{ .val = 0, .raw = "0" } },
                            };
                            zero_elems[zi] = z_expr;
                        }
                        val_expr = try alloc.create(hir.HirExpr);
                        val_expr.* = .{
                            .tag = .array_init,
                            .hir_type = h_type,
                            .data = .{ .array_init = .{ .elements = zero_elems } },
                        };
                    }
                }
                try sim_stmts.append(.{
                    .tag = .assign,
                    .data = .{
                        .assign = .{
                            .target = target,
                            .value = val_expr,
                        },
                    },
                });
            },
            .inline_for => {
                const loop = stmt.data.inline_for;
                const start_val = self.evalConst(loop.start);
                const end_val = self.evalConst(loop.end);

                var idx = start_val;
                while (idx < end_val) : (idx += 1) {
                    try self.constants.put(loop.var_name, idx);
                    for (loop.body) |s| {
                        try self.lowerSimStatement(alloc, s, sim_stmts, clock_gens, reg_map, signal_types);
                    }
                }
                _ = self.constants.remove(loop.var_name);
            },
            else => {},
        }
    }

    fn lowerTaggedUnionInit(
        self: *Elaborator,
        alloc: std.mem.Allocator,
        ut: hir.HirType,
        field_init: ast.NamedExpr,
        reg_map: *const std.StringHashMap(hir.HirRegister),
        signal_types: *const std.StringHashMap(hir.HirType),
    ) anyerror!*hir.HirExpr {
        const uf = ut.getUnionField(field_init.name) orelse return error.SymbolNotFound;
        const tag_expr = try alloc.create(hir.HirExpr);
        tag_expr.* = .{
            .tag = .lit,
            .hir_type = .{ .tag = .bits, .width = ut.tag_width },
            .data = .{
                .lit = .{
                    .val = uf.tag_value,
                    .raw = try std.fmt.allocPrint(alloc, "{d}'d{d}", .{ ut.tag_width, uf.tag_value }),
                },
            },
        };

        const max_payload_w = ut.elem_width;
        if (max_payload_w == 0) {
            const res = try alloc.create(hir.HirExpr);
            res.* = tag_expr.*;
            res.hir_type = ut;
            return res;
        }

        var concat_args = ArrayList(*hir.HirExpr).init(alloc);
        try concat_args.append(tag_expr);

        if (uf.payload_width > 0) {
            const lowered_p = try self.lowerExpr(alloc, field_init.value, reg_map, signal_types);
            if (lowered_p.tag == .lit and uf.payload_width > 0) {
                lowered_p.hir_type.width = uf.payload_width;
            }

            if (uf.payload_width < max_payload_w) {
                const pad_w = max_payload_w - uf.payload_width;
                const pad_expr = try alloc.create(hir.HirExpr);
                pad_expr.* = .{
                    .tag = .lit,
                    .hir_type = .{ .tag = .bits, .width = pad_w },
                    .data = .{
                        .lit = .{
                            .val = 0,
                            .raw = try std.fmt.allocPrint(alloc, "{d}'d0", .{pad_w}),
                        },
                    },
                };
                try concat_args.append(pad_expr);
            }
            try concat_args.append(lowered_p);
        } else {
            const pad_expr = try alloc.create(hir.HirExpr);
            pad_expr.* = .{
                .tag = .lit,
                .hir_type = .{ .tag = .bits, .width = max_payload_w },
                .data = .{
                    .lit = .{
                        .val = 0,
                        .raw = try std.fmt.allocPrint(alloc, "{d}'d0", .{max_payload_w}),
                    },
                },
            };
            try concat_args.append(pad_expr);
        }

        const res = try alloc.create(hir.HirExpr);
        res.* = .{
            .tag = .concat,
            .hir_type = ut,
            .data = .{
                .concat = .{
                    .args = try concat_args.toOwnedSlice(),
                },
            },
        };
        return res;
    }

    fn lowerUnionFieldAssign(
        self: *Elaborator,
        alloc: std.mem.Allocator,
        out_stmts: *ArrayList(hir.HirStatement),
        ut: hir.HirType,
        uf: hir.HirUnionField,
        target_sig_name: []const u8,
        value_ast: *ast.Expr,
        reg_map: *const std.StringHashMap(hir.HirRegister),
        signal_types: *const std.StringHashMap(hir.HirType),
    ) anyerror!void {
        const sub_target = try alloc.create(hir.HirExpr);
        sub_target.* = .{
            .tag = .signal_ref,
            .hir_type = ut,
            .data = .{ .signal_ref = .{ .name = target_sig_name } },
        };

        if (uf.payload_width > 0) {
            const payload_target = try alloc.create(hir.HirExpr);
            payload_target.* = .{
                .tag = .slice,
                .hir_type = .{ .tag = .bits, .width = uf.payload_width },
                .data = .{
                    .slice = .{
                        .target = sub_target,
                        .start = 0,
                        .end = uf.payload_width,
                        .is_downward = false,
                    },
                },
            };
            const lowered_val = try self.lowerExpr(alloc, value_ast, reg_map, signal_types);
            if (lowered_val.tag == .lit and uf.payload_width > 0) {
                lowered_val.hir_type.width = uf.payload_width;
            }
            try out_stmts.append(.{
                .tag = .assign,
                .data = .{
                    .assign = .{
                        .target = payload_target,
                        .value = lowered_val,
                    },
                },
            });
        }

        const tag_target = try alloc.create(hir.HirExpr);
        tag_target.* = .{
            .tag = .slice,
            .hir_type = .{ .tag = .bits, .width = ut.tag_width },
            .data = .{
                .slice = .{
                    .target = sub_target,
                    .start = ut.elem_width,
                    .end = ut.elem_width + ut.tag_width,
                    .is_downward = false,
                },
            },
        };
        const tag_val_expr = try alloc.create(hir.HirExpr);
        tag_val_expr.* = .{
            .tag = .lit,
            .hir_type = .{ .tag = .bits, .width = ut.tag_width },
            .data = .{
                .lit = .{
                    .val = uf.tag_value,
                    .raw = try std.fmt.allocPrint(alloc, "{d}'d{d}", .{ ut.tag_width, uf.tag_value }),
                },
            },
        };
        try out_stmts.append(.{
            .tag = .assign,
            .data = .{
                .assign = .{
                    .target = tag_target,
                    .value = tag_val_expr,
                },
            },
        });
    }

    fn lowerStatement(
        self: *Elaborator,
        alloc: std.mem.Allocator,
        stmt: ast.Statement,
        out_stmts: *ArrayList(hir.HirStatement),
        local_signals: *ArrayList(hir.HirSignal),
        reg_map: *const std.StringHashMap(hir.HirRegister),
        signal_types: *std.StringHashMap(hir.HirType),
    ) !void {
        switch (stmt.tag) {
            .assign => {
                const a = stmt.data.assign;

                if (a.is_reg_assign) {
                    var names = ArrayList([]const u8).init(alloc);
                    defer names.deinit();
                    try collectAstTargetBaseNames(a.target, &names);
                    for (names.items) |bn| {
                        if (reg_map.get(bn) == null) {
                            std.debug.print(
                                \\
                                \\======================================================================
                                \\COMPILE ERROR: Invalid Register Assignment (':=') on Signal '{s}'
                                \\======================================================================
                                \\The operator ':=' is reserved for clocked registers ('reg').
                                \\Signal '{s}' is a combinational wire.
                                \\
                                \\Fix:
                                \\  Use '=' for combinational wires:
                                \\    {s} = ...;
                                \\======================================================================
                                \\
                                , .{ bn, bn, bn });
                            return error.TypeMismatch;
                        }
                    }
                } else {
                    if (hasDotNext(a.target)) {
                        var names = ArrayList([]const u8).init(alloc);
                        defer names.deinit();
                        try collectAstTargetBaseNames(a.target, &names);
                        const first_name = if (names.items.len > 0) names.items[0] else "reg";
                        std.debug.print(
                            \\
                            \\======================================================================
                            \\COMPILE ERROR: Deprecated Register '.next' Syntax
                            \\======================================================================
                            \\Register '.next' assignment syntax is deprecated.
                            \\In ZHdl, clocked registers are updated using the ':=' operator.
                            \\
                            \\Fix:
                            \\  Use ':=' to update register state:
                            \\    {s} := ...;
                            \\======================================================================
                            \\
                            , .{first_name});
                        return error.TypeMismatch;
                    }

                    var names = ArrayList([]const u8).init(alloc);
                    defer names.deinit();
                    try collectAstTargetBaseNames(a.target, &names);
                    for (names.items) |bn| {
                        if (reg_map.get(bn) != null) {
                            std.debug.print(
                                \\
                                \\======================================================================
                                \\COMPILE ERROR: Cannot Assign Clocked Register '{s}' Using '='
                                \\======================================================================
                                \\Cannot assign clocked register '{s}' using '='.
                                \\Registers update synchronously on clock edges using ':='.
                                \\
                                \\Fix:
                                \\  Use ':=' to update register state:
                                \\    {s} := ...;
                                \\======================================================================
                                \\
                                , .{ bn, bn, bn });
                            return error.TypeMismatch;
                        }
                    }
                }

                if (a.target.tag == .member_access) {
                    const ma = a.target.data.member_access;
                    const field_name = ma.field;
                    var base_id: ?[]const u8 = null;
                    if (ma.target.tag == .identifier) {
                        base_id = ma.target.data.identifier;
                    } else if (ma.target.tag == .member_access and std.mem.eql(u8, ma.target.data.member_access.field, "next")) {
                        if (ma.target.data.member_access.target.tag == .identifier) {
                            base_id = ma.target.data.member_access.target.data.identifier;
                        }
                    }

                    if (base_id != null and reg_map.get(base_id.?) != null) {
                        const r = reg_map.get(base_id.?).?;
                        if (r.hir_type.tag == .tagged_union) {
                            if (r.hir_type.getUnionField(field_name)) |uf| {
                                try self.lowerUnionFieldAssign(alloc, out_stmts, r.hir_type, uf, r.d_name, a.value, reg_map, signal_types);
                                return;
                            }
                        }
                    } else if (base_id != null and signal_types.get(base_id.?) != null) {
                        const sig_t = signal_types.get(base_id.?).?;
                        if (sig_t.tag == .tagged_union) {
                            if (sig_t.getUnionField(field_name)) |uf| {
                                try self.lowerUnionFieldAssign(alloc, out_stmts, sig_t, uf, base_id.?, a.value, reg_map, signal_types);
                                return;
                            }
                        }
                    }
                }

                const target_expr = try self.lowerTargetExpr(alloc, a.target, a.is_reg_assign, reg_map, signal_types);

                var val_expr: *hir.HirExpr = undefined;
                if (target_expr.hir_type.tag == .optional) {
                    if (a.value.tag == .null_lit) {
                        val_expr = try alloc.create(hir.HirExpr);
                        val_expr.* = .{
                            .tag = .lit,
                            .hir_type = target_expr.hir_type,
                            .data = .{ .lit = .{ .val = 0, .raw = "0" } },
                        };
                    } else {
                        val_expr = try self.lowerExpr(alloc, a.value, reg_map, signal_types);
                        if (val_expr.hir_type.tag != .optional) {
                            const one_lit = try alloc.create(hir.HirExpr);
                            one_lit.* = .{
                                .tag = .lit,
                                .hir_type = .{ .tag = .bits, .width = 1 },
                                .data = .{ .lit = .{ .val = 1, .raw = "1'b1" } },
                            };
                            if (val_expr.tag == .lit and target_expr.hir_type.elem_width > 0) {
                                val_expr.hir_type.width = target_expr.hir_type.elem_width;
                            }
                            var cat_args = try alloc.alloc(*hir.HirExpr, 2);
                            cat_args[0] = one_lit;
                            cat_args[1] = val_expr;
                            const wrapped = try alloc.create(hir.HirExpr);
                            wrapped.* = .{
                                .tag = .concat,
                                .hir_type = target_expr.hir_type,
                                .data = .{ .concat = .{ .args = cat_args } },
                            };
                            val_expr = wrapped;
                        }
                    }
                } else if (target_expr.hir_type.tag == .tagged_union and a.value.tag == .struct_init) {
                    const si = a.value.data.struct_init;
                    if (si.fields.len > 0) {
                        val_expr = try self.lowerTaggedUnionInit(alloc, target_expr.hir_type, si.fields[0], reg_map, signal_types);
                    } else {
                        val_expr = try alloc.create(hir.HirExpr);
                        val_expr.* = .{
                            .tag = .lit,
                            .hir_type = target_expr.hir_type,
                            .data = .{ .lit = .{ .val = 0, .raw = "0" } },
                        };
                    }
                } else if (a.value.tag == .struct_init and a.value.data.struct_init.type_expr == null and target_expr.hir_type.struct_fields.len > 0) {
                    const st = target_expr.hir_type;
                    const si = a.value.data.struct_init;
                    var concat_args = ArrayList(*hir.HirExpr).init(alloc);
                    var idx = st.struct_fields.len;
                    while (idx > 0) {
                        idx -= 1;
                        const sf = st.struct_fields[idx];
                        var found_val: ?*ast.Expr = null;
                        for (si.fields) |f| {
                            if (std.mem.eql(u8, f.name, sf.name)) {
                                found_val = f.value;
                                break;
                            }
                        }
                        if (found_val) |fv| {
                            const lowered_f = try self.lowerExpr(alloc, fv, reg_map, signal_types);
                            if (lowered_f.tag == .lit and sf.width > 0) {
                                lowered_f.hir_type.width = sf.width;
                            }
                            try concat_args.append(lowered_f);
                        } else {
                            const zero_expr = try alloc.create(hir.HirExpr);
                            zero_expr.* = .{
                                .tag = .lit,
                                .hir_type = .{ .tag = .bits, .width = sf.width },
                                .data = .{ .lit = .{ .val = 0, .raw = "0" } },
                            };
                            try concat_args.append(zero_expr);
                        }
                    }
                    val_expr = try alloc.create(hir.HirExpr);
                    val_expr.* = .{
                        .tag = .concat,
                        .hir_type = st,
                        .data = .{ .concat = .{ .args = try concat_args.toOwnedSlice() } },
                    };
                } else {
                    val_expr = try self.lowerExpr(alloc, a.value, reg_map, signal_types);
                }
                if (val_expr.tag == .lit and target_expr.hir_type.width > 0) {
                    val_expr.hir_type.width = target_expr.hir_type.width;
                    if (target_expr.hir_type.is_signed) val_expr.hir_type.is_signed = true;
                } else if (val_expr.tag == .unary and val_expr.data.unary.operand.tag == .lit and target_expr.hir_type.width > 0) {
                    val_expr.hir_type.width = target_expr.hir_type.width;
                    val_expr.data.unary.operand.hir_type.width = target_expr.hir_type.width;
                    if (target_expr.hir_type.is_signed) {
                        val_expr.hir_type.is_signed = true;
                        val_expr.data.unary.operand.hir_type.is_signed = true;
                    }
                }
                if (target_expr.hir_type.tag == .array) {
                    if (val_expr.tag == .array_init) {
                        for (val_expr.data.array_init.elements) |elem| {
                            if (elem.tag == .lit and target_expr.hir_type.elem_width > 0) {
                                elem.hir_type.width = target_expr.hir_type.elem_width;
                            }
                        }
                    } else if (val_expr.tag == .lit and val_expr.data.lit.val == 0) {
                        var zero_elems = try alloc.alloc(*hir.HirExpr, target_expr.hir_type.array_len);
                        for (0..target_expr.hir_type.array_len) |zi| {
                            const z_expr = try alloc.create(hir.HirExpr);
                            z_expr.* = .{
                                .tag = .lit,
                                .hir_type = .{ .tag = .bits, .width = target_expr.hir_type.elem_width },
                                .data = .{ .lit = .{ .val = 0, .raw = "0" } },
                            };
                            zero_elems[zi] = z_expr;
                        }
                        val_expr = try alloc.create(hir.HirExpr);
                        val_expr.* = .{
                            .tag = .array_init,
                            .hir_type = target_expr.hir_type,
                            .data = .{ .array_init = .{ .elements = zero_elems } },
                        };
                    }
                }
                if (target_expr.hir_type.tag != .array and val_expr.tag == .array_init) {
                    const elems = val_expr.data.array_init.elements;
                    val_expr.tag = .concat;
                    val_expr.data = .{ .concat = .{ .args = elems } };
                }
                try out_stmts.append(.{
                    .tag = .assign,
                    .data = .{
                        .assign = .{
                            .target = target_expr,
                            .value = val_expr,
                        },
                    },
                });
            },
            .var_decl => {
                const vd = stmt.data.var_decl;
                var val = try self.lowerExpr(alloc, vd.init_val, reg_map, signal_types);
                const h_type = if (vd.type_annot) |t|
                    try self.lowerType(t)
                else if (val.hir_type.width > 0)
                    val.hir_type
                else
                    hir.HirType{ .tag = .bits, .width = 32 };

                if (h_type.tag == .optional) {
                    if (vd.init_val.tag == .null_lit) {
                        val.hir_type = h_type;
                        val.data.lit.val = 0;
                    } else if (val.hir_type.tag != .optional) {
                        const one_lit = try alloc.create(hir.HirExpr);
                        one_lit.* = .{
                            .tag = .lit,
                            .hir_type = .{ .tag = .bits, .width = 1 },
                            .data = .{ .lit = .{ .val = 1, .raw = "1'b1" } },
                        };
                        if (val.tag == .lit and h_type.elem_width > 0) {
                            val.hir_type.width = h_type.elem_width;
                        }
                        var cat_args = try alloc.alloc(*hir.HirExpr, 2);
                        cat_args[0] = one_lit;
                        cat_args[1] = val;
                        const wrapped = try alloc.create(hir.HirExpr);
                        wrapped.* = .{
                            .tag = .concat,
                            .hir_type = h_type,
                            .data = .{ .concat = .{ .args = cat_args } },
                        };
                        val = wrapped;
                    }
                }

                if (h_type.tag == .tagged_union and vd.init_val.tag == .struct_init) {
                    const si = vd.init_val.data.struct_init;
                    if (si.fields.len > 0) {
                        val = try self.lowerTaggedUnionInit(alloc, h_type, si.fields[0], reg_map, signal_types);
                    }
                }

                try local_signals.append(.{
                    .name = vd.name,
                    .hir_type = h_type,
                });
                try signal_types.put(vd.name, h_type);

                const target = try alloc.create(hir.HirExpr);
                target.* = .{
                    .tag = .signal_ref,
                    .hir_type = h_type,
                    .data = .{ .signal_ref = .{ .name = vd.name } },
                };
                if (val.tag == .lit and h_type.width > 0) {
                    val.hir_type.width = h_type.width;
                }

                if (h_type.tag == .array) {
                    if (val.tag == .array_init) {
                        for (val.data.array_init.elements) |elem| {
                            if (elem.tag == .lit and h_type.elem_width > 0) {
                                elem.hir_type.width = h_type.elem_width;
                            }
                        }
                        try out_stmts.append(.{
                            .tag = .assign,
                            .data = .{
                                .assign = .{
                                    .target = target,
                                    .value = val,
                                },
                            },
                        });
                    } else if (val.tag == .lit and val.data.lit.val == 0) {
                        var zero_elems = try alloc.alloc(*hir.HirExpr, h_type.array_len);
                        for (0..h_type.array_len) |zi| {
                            const z_expr = try alloc.create(hir.HirExpr);
                            z_expr.* = .{
                                .tag = .lit,
                                .hir_type = .{ .tag = .bits, .width = h_type.elem_width },
                                .data = .{ .lit = .{ .val = 0, .raw = "0" } },
                            };
                            zero_elems[zi] = z_expr;
                        }
                        const zero_arr = try alloc.create(hir.HirExpr);
                        zero_arr.* = .{
                            .tag = .array_init,
                            .hir_type = h_type,
                            .data = .{ .array_init = .{ .elements = zero_elems } },
                        };
                        try out_stmts.append(.{
                            .tag = .assign,
                            .data = .{
                                .assign = .{
                                    .target = target,
                                    .value = zero_arr,
                                },
                            },
                        });
                    }
                } else {
                    try out_stmts.append(.{
                        .tag = .assign,
                        .data = .{
                            .assign = .{
                                .target = target,
                                .value = val,
                            },
                        },
                    });
                }
            },
            .if_stmt => {
                const ifs = stmt.data.if_stmt;
                const cond = try self.lowerExpr(alloc, ifs.cond, reg_map, signal_types);

                var if_cond = cond;
                if (cond.hir_type.tag == .optional) {
                    const valid_slice = try alloc.create(hir.HirExpr);
                    valid_slice.* = .{
                        .tag = .slice,
                        .hir_type = .{ .tag = .bits, .width = 1 },
                        .data = .{
                            .slice = .{
                                .target = cond,
                                .start = cond.hir_type.width - 1,
                                .end = cond.hir_type.width,
                                .is_downward = false,
                            },
                        },
                    };
                    if_cond = valid_slice;
                }

                var then_list = ArrayList(hir.HirStatement).init(alloc);

                var had_cap_in_sig_types = false;
                var old_cap_sig_type: ?hir.HirType = null;
                if (ifs.capture) |cap_name| {
                    const payload_w = if (cond.hir_type.elem_width > 0)
                        cond.hir_type.elem_width
                    else if (cond.hir_type.width > 1)
                        cond.hir_type.width - 1
                    else
                        1;
                    const cap_type = hir.HirType{ .tag = .bits, .width = payload_w };

                    var found = false;
                    for (local_signals.items) |sig| {
                        if (std.mem.eql(u8, sig.name, cap_name)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        try local_signals.append(.{
                            .name = cap_name,
                            .hir_type = cap_type,
                        });
                    }

                    if (signal_types.get(cap_name)) |existing_t| {
                        had_cap_in_sig_types = true;
                        old_cap_sig_type = existing_t;
                    }
                    try signal_types.put(cap_name, cap_type);

                    const cap_target = try alloc.create(hir.HirExpr);
                    cap_target.* = .{
                        .tag = .signal_ref,
                        .hir_type = cap_type,
                        .data = .{ .signal_ref = .{ .name = cap_name } },
                    };

                    const payload_slice = try alloc.create(hir.HirExpr);
                    payload_slice.* = .{
                        .tag = .slice,
                        .hir_type = cap_type,
                        .data = .{
                            .slice = .{
                                .target = cond,
                                .start = 0,
                                .end = payload_w,
                                .is_downward = false,
                            },
                        },
                    };

                    try then_list.append(.{
                        .tag = .assign,
                        .data = .{
                            .assign = .{
                                .target = cap_target,
                                .value = payload_slice,
                            },
                        },
                    });
                }

                for (ifs.then_stmts) |s| {
                    try self.lowerStatement(alloc, s, &then_list, local_signals, reg_map, signal_types);
                }

                if (ifs.capture) |cap_name| {
                    if (had_cap_in_sig_types) {
                        try signal_types.put(cap_name, old_cap_sig_type.?);
                    } else {
                        _ = signal_types.remove(cap_name);
                    }
                }

                var else_list: ?[]hir.HirStatement = null;
                if (ifs.else_stmts) |es| {
                    var el = ArrayList(hir.HirStatement).init(alloc);
                    for (es) |s| {
                        try self.lowerStatement(alloc, s, &el, local_signals, reg_map, signal_types);
                    }
                    else_list = try el.toOwnedSlice();
                }

                try out_stmts.append(.{
                    .tag = .if_stmt,
                    .data = .{
                        .if_stmt = .{
                            .cond = if_cond,
                            .then_body = try then_list.toOwnedSlice(),
                            .else_body = else_list,
                        },
                    },
                });
            },
            .switch_stmt => {
                const sw = stmt.data.switch_stmt;
                const target = try self.lowerExpr(alloc, sw.expr, reg_map, signal_types);

                if (target.hir_type.tag == .tagged_union) {
                    const tag_slice = try alloc.create(hir.HirExpr);
                    tag_slice.* = .{
                        .tag = .slice,
                        .hir_type = .{ .tag = .bits, .width = target.hir_type.tag_width },
                        .data = .{
                            .slice = .{
                                .target = target,
                                .start = target.hir_type.elem_width,
                                .end = target.hir_type.width,
                                .is_downward = false,
                            },
                        },
                    };

                    var branches = ArrayList(hir.HirCaseBranch).init(alloc);
                    for (sw.cases) |c| {
                        var vals = ArrayList(u64).init(alloc);
                        if (!c.is_else) {
                            for (c.patterns) |p| {
                                if (p.tag == .enum_literal) {
                                    if (target.hir_type.getUnionField(p.data.enum_literal)) |uf| {
                                        try vals.append(uf.tag_value);
                                    } else {
                                        try vals.append(self.getEnumVal(p.data.enum_literal));
                                    }
                                } else {
                                    try vals.append(self.evalConstEx(p, null));
                                }
                            }
                        }

                        var body_stmts = ArrayList(hir.HirStatement).init(alloc);
                        var had_cap_in_sig_types = false;
                        var old_cap_sig_type: ?hir.HirType = null;

                        if (c.capture) |cap_name| {
                            var payload_w: u32 = 0;
                            if (c.patterns.len > 0 and c.patterns[0].tag == .enum_literal) {
                                if (target.hir_type.getUnionField(c.patterns[0].data.enum_literal)) |uf| {
                                    payload_w = uf.payload_width;
                                }
                            }

                            if (payload_w > 0) {
                                var cap_type = hir.HirType{ .tag = .bits, .width = payload_w };
                                if (c.patterns.len > 0 and c.patterns[0].tag == .enum_literal) {
                                    if (target.hir_type.getUnionField(c.patterns[0].data.enum_literal)) |uf| {
                                        if (uf.payload_type_name.len > 0) {
                                            if (self.types.get(uf.payload_type_name)) |found_t| {
                                                cap_type = found_t;
                                            }
                                        }
                                    }
                                }

                                var found = false;
                                for (local_signals.items) |*sig| {
                                    if (std.mem.eql(u8, sig.name, cap_name)) {
                                        found = true;
                                        if (cap_type.width > sig.hir_type.width) {
                                            sig.hir_type.width = cap_type.width;
                                        }
                                        break;
                                    }
                                }
                                if (!found) {
                                    try local_signals.append(.{
                                        .name = cap_name,
                                        .hir_type = cap_type,
                                    });
                                }

                                if (signal_types.get(cap_name)) |existing_t| {
                                    had_cap_in_sig_types = true;
                                    old_cap_sig_type = existing_t;
                                }
                                try signal_types.put(cap_name, cap_type);

                                const cap_target = try alloc.create(hir.HirExpr);
                                cap_target.* = .{
                                    .tag = .signal_ref,
                                    .hir_type = cap_type,
                                    .data = .{ .signal_ref = .{ .name = cap_name } },
                                };

                                const cap_slice = try alloc.create(hir.HirExpr);
                                cap_slice.* = .{
                                    .tag = .slice,
                                    .hir_type = cap_type,
                                    .data = .{
                                        .slice = .{
                                            .target = target,
                                            .start = 0,
                                            .end = payload_w,
                                            .is_downward = false,
                                        },
                                    },
                                };

                                try body_stmts.append(.{
                                    .tag = .assign,
                                    .data = .{
                                        .assign = .{
                                            .target = cap_target,
                                            .value = cap_slice,
                                        },
                                    },
                                });
                            }
                        }

                        for (c.body) |s| {
                            try self.lowerStatement(alloc, s, &body_stmts, local_signals, reg_map, signal_types);
                        }

                        if (c.capture) |cap_name| {
                            if (had_cap_in_sig_types) {
                                try signal_types.put(cap_name, old_cap_sig_type.?);
                            } else {
                                _ = signal_types.remove(cap_name);
                            }
                        }

                        try branches.append(.{
                            .pattern_values = try vals.toOwnedSlice(),
                            .is_default = c.is_else,
                            .body = try body_stmts.toOwnedSlice(),
                        });
                    }

                    try out_stmts.append(.{
                        .tag = .case_stmt,
                        .data = .{
                            .case_stmt = .{
                                .expr = tag_slice,
                                .branches = try branches.toOwnedSlice(),
                            },
                        },
                    });
                } else {
                    var branches = ArrayList(hir.HirCaseBranch).init(alloc);
                    for (sw.cases) |c| {
                        var vals = ArrayList(u64).init(alloc);
                        if (!c.is_else) {
                            for (c.patterns) |p| {
                                if (p.tag == .enum_literal) {
                                    // Enum literal: find value or assign index
                                    try vals.append(self.getEnumVal(p.data.enum_literal));
                                } else {
                                    try vals.append(self.evalConstEx(p, null));
                                }
                            }
                        }

                        var body_stmts = ArrayList(hir.HirStatement).init(alloc);
                        for (c.body) |s| {
                            try self.lowerStatement(alloc, s, &body_stmts, local_signals, reg_map, signal_types);
                        }

                        try branches.append(.{
                            .pattern_values = try vals.toOwnedSlice(),
                            .is_default = c.is_else,
                            .body = try body_stmts.toOwnedSlice(),
                        });
                    }

                    try out_stmts.append(.{
                        .tag = .case_stmt,
                        .data = .{
                            .case_stmt = .{
                                .expr = target,
                                .branches = try branches.toOwnedSlice(),
                            },
                        },
                    });
                }
            },
            .inline_for => {
                // Comptime unrolling of loop
                const loop = stmt.data.inline_for;
                const start_val = self.evalConst(loop.start);
                const end_val = self.evalConst(loop.end);

                var idx = start_val;
                while (idx < end_val) : (idx += 1) {
                    try self.constants.put(loop.var_name, idx);
                    for (loop.body) |s| {
                        try self.lowerStatement(alloc, s, out_stmts, local_signals, reg_map, signal_types);
                    }
                }
                _ = self.constants.remove(loop.var_name);
            },
            .expr_stmt => {},
        }
    }

    fn lowerExpr(
        self: *Elaborator,
        alloc: std.mem.Allocator,
        expr: *ast.Expr,
        reg_map: *const std.StringHashMap(hir.HirRegister),
        signal_types: *const std.StringHashMap(hir.HirType),
    ) !*hir.HirExpr {
        const h_expr = try alloc.create(hir.HirExpr);

        switch (expr.tag) {
            .number => {
                var width: u32 = 32;
                if (std.mem.indexOfScalar(u8, expr.data.number.raw, '\'')) |quote_pos| {
                    if (quote_pos > 0) {
                        width = std.fmt.parseInt(u32, expr.data.number.raw[0..quote_pos], 10) catch 32;
                    }
                }
                h_expr.* = .{
                    .tag = .lit,
                    .hir_type = .{ .tag = .bits, .width = width },
                    .data = .{
                        .lit = .{
                            .val = expr.data.number.val,
                            .raw = expr.data.number.raw,
                        },
                    },
                };
            },
            .time_literal => {
                h_expr.* = .{
                    .tag = .lit,
                    .hir_type = .{ .tag = .bits, .width = 64 },
                    .data = .{
                        .lit = .{
                            .val = convertToNs(expr.data.time_literal),
                            .raw = expr.data.time_literal.raw,
                        },
                    },
                };
            },
            .freq_literal => {
                h_expr.* = .{
                    .tag = .lit,
                    .hir_type = .{ .tag = .bits, .width = 64 },
                    .data = .{
                        .lit = .{
                            .val = convertFreqToNs(expr.data.freq_literal),
                            .raw = expr.data.freq_literal.raw,
                        },
                    },
                };
            },
            .boolean => {
                h_expr.* = .{
                    .tag = .lit,
                    .hir_type = .{ .tag = .bits, .width = 1 },
                    .data = .{
                        .lit = .{
                            .val = if (expr.data.boolean) 1 else 0,
                            .raw = if (expr.data.boolean) "1" else "0",
                        },
                    },
                };
            },
            .null_lit => {
                h_expr.* = .{
                    .tag = .lit,
                    .hir_type = .{ .tag = .bits, .width = 1 },
                    .data = .{ .lit = .{ .val = 0, .raw = "0" } },
                };
            },
            .identifier => {
                const name = expr.data.identifier;
                if (self.param_env) |pe| {
                    if (pe.get(name)) |bound_expr| {
                        return bound_expr;
                    }
                }
                // If it's a register name, reading it maps to Q output (e.g. count_q)
                if (reg_map.get(name)) |r| {
                    h_expr.* = .{
                        .tag = .signal_ref,
                        .hir_type = r.hir_type,
                        .data = .{ .signal_ref = .{ .name = r.q_name } },
                    };
                } else if (self.constants.get(name)) |c_val| {
                    h_expr.* = .{
                        .tag = .lit,
                        .hir_type = .{ .tag = .bits, .width = 32 },
                        .data = .{ .lit = .{ .val = c_val, .raw = "" } },
                    };
                } else if (signal_types.get(name)) |st| {
                    h_expr.* = .{
                        .tag = .signal_ref,
                        .hir_type = st,
                        .data = .{ .signal_ref = .{ .name = name } },
                    };
                } else {
                    h_expr.* = .{
                        .tag = .signal_ref,
                        .hir_type = .{ .tag = .bits, .width = 32 },
                        .data = .{ .signal_ref = .{ .name = name } },
                    };
                }
            },
            .enum_literal => {
                const val = self.getEnumVal(expr.data.enum_literal);
                h_expr.* = .{
                    .tag = .lit,
                    .hir_type = .{ .tag = .bits, .width = 8 },
                    .data = .{
                        .lit = .{
                            .val = val,
                            .raw = expr.data.enum_literal,
                        },
                    },
                };
            },
            .member_access => {
                const ma = expr.data.member_access;
                if (exprToDottedString(alloc, expr)) |dotted| {
                    if (self.constants.get(dotted)) |val| {
                        h_expr.* = .{
                            .tag = .lit,
                            .hir_type = .{ .tag = .bits, .width = 32 },
                            .data = .{ .lit = .{ .val = val, .raw = try std.fmt.allocPrint(alloc, "{d}", .{val}) } },
                        };
                        return h_expr;
                    }
                    if (self.enum_variants.get(dotted)) |val| {
                        h_expr.* = .{
                            .tag = .lit,
                            .hir_type = .{ .tag = .bits, .width = 32 },
                            .data = .{ .lit = .{ .val = val, .raw = try std.fmt.allocPrint(alloc, "{d}", .{val}) } },
                        };
                        return h_expr;
                    }
                }
                if (ma.target.tag == .identifier) {
                    if (self.packages.contains(ma.target.data.identifier)) {
                        if (self.constants.get(ma.field)) |val| {
                            h_expr.* = .{
                                .tag = .lit,
                                .hir_type = .{ .tag = .bits, .width = 32 },
                                .data = .{ .lit = .{ .val = val, .raw = try std.fmt.allocPrint(alloc, "{d}", .{val}) } },
                            };
                            return h_expr;
                        }
                        if (self.enum_variants.get(ma.field)) |val| {
                            h_expr.* = .{
                                .tag = .lit,
                                .hir_type = .{ .tag = .bits, .width = 32 },
                                .data = .{ .lit = .{ .val = val, .raw = try std.fmt.allocPrint(alloc, "{d}", .{val}) } },
                            };
                            return h_expr;
                        }
                    }
                }
                const target = try self.lowerExpr(alloc, ma.target, reg_map, signal_types);
                if (target.hir_type.getStructField(ma.field)) |f| {
                    h_expr.* = .{
                        .tag = .slice,
                        .hir_type = .{ .tag = .bits, .width = f.width },
                        .data = .{
                            .slice = .{
                                .target = target,
                                .start = f.offset,
                                .end = f.offset + f.width,
                                .is_downward = false,
                            },
                        },
                    };
                } else {
                    h_expr.* = .{
                        .tag = .member,
                        .hir_type = .{ .tag = .bits, .width = 32 },
                        .data = .{
                            .member = .{
                                .target = target,
                                .field = ma.field,
                            },
                        },
                    };
                }
            },
            .binary => {
                const b = expr.data.binary;
                const left = try self.lowerExpr(alloc, b.left, reg_map, signal_types);
                const right = try self.lowerExpr(alloc, b.right, reg_map, signal_types);

                if (b.op != .shl and b.op != .shr) {
                    if (left.hir_type.width > 0 and right.tag == .lit) {
                        right.hir_type.width = left.hir_type.width;
                        if (left.hir_type.is_signed) right.hir_type.is_signed = true;
                    } else if (right.hir_type.width > 0 and left.tag == .lit) {
                        left.hir_type.width = right.hir_type.width;
                        if (right.hir_type.is_signed) left.hir_type.is_signed = true;
                    } else if (left.hir_type.width > 0 and right.tag == .unary and right.data.unary.operand.tag == .lit) {
                        right.hir_type.width = left.hir_type.width;
                        right.data.unary.operand.hir_type.width = left.hir_type.width;
                        if (left.hir_type.is_signed) {
                            right.hir_type.is_signed = true;
                            right.data.unary.operand.hir_type.is_signed = true;
                        }
                    } else if (right.hir_type.width > 0 and left.tag == .unary and left.data.unary.operand.tag == .lit) {
                        left.hir_type.width = right.hir_type.width;
                        left.data.unary.operand.hir_type.width = right.hir_type.width;
                        if (right.hir_type.is_signed) {
                            left.hir_type.is_signed = true;
                            left.data.unary.operand.hir_type.is_signed = true;
                        }
                    }
                }

                const is_compare = switch (b.op) {
                    .equal_equal, .bang_equal, .less_than, .less_than_equal, .greater_than, .greater_than_equal, .ampersand_ampersand, .pipe_pipe => true,
                    else => false,
                };

                h_expr.* = .{
                    .tag = .binary,
                    .hir_type = if (is_compare) hir.HirType{ .tag = .bits, .width = 1 } else left.hir_type,
                    .data = .{
                        .binary = .{
                            .op = b.op,
                            .left = left,
                            .right = right,
                        },
                    },
                };
            },
            .unary => {
                const u = expr.data.unary;
                const operand = try self.lowerExpr(alloc, u.operand, reg_map, signal_types);
                const is_1bit = (u.op == .bang or u.op == .pipe or u.op == .ampersand or u.op == .caret);
                const res_type: hir.HirType = if (is_1bit)
                    .{ .tag = .bits, .width = 1 }
                else
                    operand.hir_type;
                h_expr.* = .{
                    .tag = .unary,
                    .hir_type = res_type,
                    .data = .{
                        .unary = .{
                            .op = u.op,
                            .operand = operand,
                        },
                    },
                };
            },
            .slice => {
                const sl = expr.data.slice;
                const target = try self.lowerExpr(alloc, sl.target, reg_map, signal_types);
                const start_val: u32 = @intCast(self.evalConst(sl.start));
                const end_val: u32 = @intCast(self.evalConst(sl.end));

                var is_downward = sl.is_downward;
                var s = start_val;
                var e = end_val;
                if (start_val > end_val) {
                    is_downward = true;
                    s = end_val;
                    e = start_val;
                }

                const width = if (e >= s) e - s else 1;
                h_expr.* = .{
                    .tag = .slice,
                    .hir_type = .{ .tag = .bits, .width = width },
                    .data = .{
                        .slice = .{
                            .target = target,
                            .start = s,
                            .end = e,
                            .is_downward = is_downward,
                        },
                    },
                };
            },
            .part_select => {
                const ps = expr.data.part_select;
                const target = try self.lowerExpr(alloc, ps.target, reg_map, signal_types);
                const base = try self.lowerExpr(alloc, ps.base, reg_map, signal_types);
                const w: u32 = @intCast(self.evalConst(ps.width));
                h_expr.* = .{
                    .tag = .part_select,
                    .hir_type = .{ .tag = .bits, .width = w },
                    .data = .{
                        .part_select = .{
                            .target = target,
                            .base = base,
                            .width = w,
                            .is_up = ps.is_up,
                        },
                    },
                };
            },
            .index => {
                const idx = expr.data.index;
                const target = try self.lowerExpr(alloc, idx.target, reg_map, signal_types);
                const index_e = try self.lowerExpr(alloc, idx.index, reg_map, signal_types);
                const w: u32 = if (target.hir_type.tag == .array) target.hir_type.elem_width else 1;
                h_expr.* = .{
                    .tag = .index,
                    .hir_type = .{ .tag = .bits, .width = w },
                    .data = .{
                        .index = .{
                            .target = target,
                            .index = index_e,
                        },
                    },
                };
            },
            .builtin_call => {
                const bc = expr.data.builtin_call;
                switch (bc.tag) {
                    .builtin_replicate => {
                        const count = self.evalConst(bc.args[0]);
                        const val = try self.lowerExpr(alloc, bc.args[1], reg_map, signal_types);
                        if (val.tag == .lit and std.mem.indexOfScalar(u8, val.data.lit.raw, '\'') == null) {
                            val.hir_type.width = 1;
                        }
                        const total_w: u32 = @intCast(count * @as(u64, val.hir_type.width));
                        h_expr.* = .{
                            .tag = .replicate,
                            .hir_type = .{ .tag = .bits, .width = total_w },
                            .data = .{
                                .replicate = .{
                                    .count = @intCast(count),
                                    .val = val,
                                },
                            },
                        };
                    },
                    .builtin_reduce_or => {
                        const operand = try self.lowerExpr(alloc, bc.args[0], reg_map, signal_types);
                        h_expr.* = .{
                            .tag = .unary,
                            .hir_type = .{ .tag = .bits, .width = 1 },
                            .data = .{
                                .unary = .{
                                    .op = .pipe,
                                    .operand = operand,
                                },
                            },
                        };
                    },
                    .builtin_reduce_and => {
                        const operand = try self.lowerExpr(alloc, bc.args[0], reg_map, signal_types);
                        h_expr.* = .{
                            .tag = .unary,
                            .hir_type = .{ .tag = .bits, .width = 1 },
                            .data = .{
                                .unary = .{
                                    .op = .ampersand,
                                    .operand = operand,
                                },
                            },
                        };
                    },
                    .builtin_reduce_xor => {
                        const operand = try self.lowerExpr(alloc, bc.args[0], reg_map, signal_types);
                        h_expr.* = .{
                            .tag = .unary,
                            .hir_type = .{ .tag = .bits, .width = 1 },
                            .data = .{
                                .unary = .{
                                    .op = .caret,
                                    .operand = operand,
                                },
                            },
                        };
                    },
                    .builtin_part_select => {
                        const target = try self.lowerExpr(alloc, bc.args[0], reg_map, signal_types);
                        const base = try self.lowerExpr(alloc, bc.args[1], reg_map, signal_types);
                        const w: u32 = @intCast(self.evalConst(bc.args[2]));
                        h_expr.* = .{
                            .tag = .part_select,
                            .hir_type = .{ .tag = .bits, .width = w },
                            .data = .{
                                .part_select = .{
                                    .target = target,
                                    .base = base,
                                    .width = w,
                                    .is_up = true,
                                },
                            },
                        };
                    },
                    .builtin_bit_reverse => {
                        const target = try self.lowerExpr(alloc, bc.args[0], reg_map, signal_types);
                        h_expr.* = .{
                            .tag = .bit_reverse,
                            .hir_type = target.hir_type,
                            .data = .{ .bit_reverse = .{ .target = target } },
                        };
                    },
                    .builtin_byte_swap => {
                        const target = try self.lowerExpr(alloc, bc.args[0], reg_map, signal_types);
                        h_expr.* = .{
                            .tag = .byte_swap,
                            .hir_type = target.hir_type,
                            .data = .{ .byte_swap = .{ .target = target } },
                        };
                    },
                    .builtin_concat => {
                        var args = ArrayList(*hir.HirExpr).init(alloc);
                        var total_w: u32 = 0;
                        for (bc.args) |a| {
                            const sub = try self.lowerExpr(alloc, a, reg_map, signal_types);
                            try args.append(sub);
                            total_w += sub.hir_type.width;
                        }
                        h_expr.* = .{
                            .tag = .concat,
                            .hir_type = .{ .tag = .bits, .width = total_w },
                            .data = .{ .concat = .{ .args = try args.toOwnedSlice() } },
                        };
                    },
                    .builtin_as, .builtin_truncate, .builtin_bit_cast => {
                        var target_w: u32 = 32;
                        var target_type: ?hir.HirType = null;
                        if (bc.args.len > 1) {
                            const type_arg = bc.args[0];
                            if (type_arg.tag == .identifier) {
                                const id_name = type_arg.data.identifier;
                                if ((id_name[0] == 'u' or id_name[0] == 'i') and id_name.len > 1) {
                                    target_w = std.fmt.parseInt(u32, id_name[1..], 10) catch 32;
                                    target_type = hir.HirType{ .tag = .bits, .width = target_w, .is_signed = (id_name[0] == 'i') };
                                } else if (self.types.get(id_name)) |found_t| {
                                    target_type = found_t;
                                    target_w = found_t.width;
                                }
                            } else if (type_arg.tag == .type_expr) {
                                const found_t = try self.lowerType(type_arg.data.type_expr);
                                target_type = found_t;
                                target_w = found_t.width;
                            }
                            const val_arg = bc.args[1];
                            const sub = try self.lowerExpr(alloc, val_arg, reg_map, signal_types);

                            const is_signed_cast = sub.hir_type.is_signed or (target_type != null and target_type.?.is_signed);
                            const effective_type = if (target_type) |tt| tt else hir.HirType{ .tag = .bits, .width = target_w, .is_signed = is_signed_cast };

                            if (bc.tag == .builtin_truncate and sub.tag != .lit and sub.hir_type.width > target_w) {
                                h_expr.* = .{
                                    .tag = .slice,
                                    .hir_type = effective_type,
                                    .data = .{
                                        .slice = .{
                                            .target = sub,
                                            .start = 0,
                                            .end = target_w,
                                            .is_downward = false,
                                        },
                                    },
                                };
                            } else if ((bc.tag == .builtin_as or bc.tag == .builtin_bit_cast) and sub.tag != .lit and target_w > sub.hir_type.width) {
                                if (is_signed_cast) {
                                    h_expr.* = .{
                                        .tag = .slice,
                                        .hir_type = effective_type,
                                        .data = .{
                                            .slice = .{
                                                .target = sub,
                                                .start = 0,
                                                .end = target_w,
                                                .is_downward = false,
                                            },
                                        },
                                    };
                                } else {
                                    const pad_w = target_w - sub.hir_type.width;
                                    const zero_lit = try alloc.create(hir.HirExpr);
                                    zero_lit.* = .{
                                        .tag = .lit,
                                        .hir_type = .{ .tag = .bits, .width = pad_w },
                                        .data = .{ .lit = .{ .val = 0, .raw = "0" } },
                                    };
                                    var cat_args = try alloc.alloc(*hir.HirExpr, 2);
                                    cat_args[0] = zero_lit;
                                    cat_args[1] = sub;
                                    h_expr.* = .{
                                        .tag = .concat,
                                        .hir_type = effective_type,
                                        .data = .{ .concat = .{ .args = cat_args } },
                                    };
                                }
                            } else {
                                if (sub.tag == .lit and target_w < 64) {
                                    sub.data.lit.val = sub.data.lit.val & ((@as(u64, 1) << @intCast(target_w)) - 1);
                                }
                                if (target_type) |tt| {
                                    sub.hir_type = tt;
                                } else {
                                    sub.hir_type.width = target_w;
                                }
                                if (is_signed_cast and sub.tag != .lit) {
                                    h_expr.* = .{
                                        .tag = .signed_cast,
                                        .hir_type = effective_type,
                                        .data = .{ .signed_cast = .{ .target = sub } },
                                    };
                                } else {
                                    h_expr.* = sub.*;
                                }
                            }
                        } else {
                            const sub = try self.lowerExpr(alloc, bc.args[0], reg_map, signal_types);
                            h_expr.* = sub.*;
                        }
                    },
                    .builtin_sync2ff => {
                        if (bc.args.len < 2) {
                            return error.InvalidComptimeExpr;
                        }
                        const dest_clk_name = switch (bc.args[0].tag) {
                            .identifier => bc.args[0].data.identifier,
                            .member_access => bc.args[0].data.member_access.field,
                            else => "clk",
                        };

                        const sub = try self.lowerExpr(alloc, bc.args[1], reg_map, signal_types);
                        const h_type: hir.HirType = if (sub.hir_type.width > 0) sub.hir_type else .{ .tag = .bits, .width = 1 };

                        // If active_registers is null (e.g. during pass 1 type deduction), return dummy signal_ref
                        if (self.active_registers == null or self.active_comb_stmts == null) {
                            h_expr.* = .{
                                .tag = .signal_ref,
                                .hir_type = h_type,
                                .data = .{ .signal_ref = .{ .name = "_sync2ff_dummy" } },
                            };
                        } else {
                            const sync_id = self.next_sync_id;
                            self.next_sync_id += 1;

                            const ff1_name = try std.fmt.allocPrint(alloc, "_sync2ff_{d}_stage1", .{sync_id});
                            const ff1_q = try std.fmt.allocPrint(alloc, "{s}_q", .{ff1_name});
                            const ff1_d = try std.fmt.allocPrint(alloc, "{s}_d", .{ff1_name});

                            const ff2_name = try std.fmt.allocPrint(alloc, "_sync2ff_{d}_stage2", .{sync_id});
                            const ff2_q = try std.fmt.allocPrint(alloc, "{s}_q", .{ff2_name});
                            const ff2_d = try std.fmt.allocPrint(alloc, "{s}_d", .{ff2_name});

                            const reg1: hir.HirRegister = .{
                                .name = ff1_name,
                                .q_name = ff1_q,
                                .d_name = ff1_d,
                                .hir_type = h_type,
                                .clk_name = dest_clk_name,
                                .rst_name = null,
                                .rst_active_low = false,
                                .init_val = 0,
                                .is_sync_stage = true,
                            };
                            const reg2: hir.HirRegister = .{
                                .name = ff2_name,
                                .q_name = ff2_q,
                                .d_name = ff2_d,
                                .hir_type = h_type,
                                .clk_name = dest_clk_name,
                                .rst_name = null,
                                .rst_active_low = false,
                                .init_val = 0,
                                .is_sync_stage = true,
                            };

                            try self.active_registers.?.append(reg1);
                            try self.active_registers.?.append(reg2);
                            if (self.active_reg_map) |rm| {
                                try rm.put(ff1_name, reg1);
                                try rm.put(ff2_name, reg2);
                            }

                            if (self.active_local_signals) |ls| {
                                try ls.append(.{ .name = ff1_q, .hir_type = h_type });
                                try ls.append(.{ .name = ff1_d, .hir_type = h_type });
                                try ls.append(.{ .name = ff2_q, .hir_type = h_type });
                                try ls.append(.{ .name = ff2_d, .hir_type = h_type });
                            }
                            if (self.active_signal_types) |st| {
                                try st.put(ff1_name, h_type);
                                try st.put(ff1_q, h_type);
                                try st.put(ff1_d, h_type);
                                try st.put(ff2_name, h_type);
                                try st.put(ff2_q, h_type);
                                try st.put(ff2_d, h_type);
                            }

                            // Wire ff1_d = sub
                            const target1 = try alloc.create(hir.HirExpr);
                            target1.* = .{
                                .tag = .signal_ref,
                                .hir_type = h_type,
                                .data = .{ .signal_ref = .{ .name = ff1_d } },
                            };
                            try self.active_comb_stmts.?.append(.{
                                .tag = .assign,
                                .data = .{ .assign = .{ .target = target1, .value = sub } },
                            });

                            // Wire ff2_d = ff1_q
                            const target2 = try alloc.create(hir.HirExpr);
                            target2.* = .{
                                .tag = .signal_ref,
                                .hir_type = h_type,
                                .data = .{ .signal_ref = .{ .name = ff2_d } },
                            };
                            const src2 = try alloc.create(hir.HirExpr);
                            src2.* = .{
                                .tag = .signal_ref,
                                .hir_type = h_type,
                                .data = .{ .signal_ref = .{ .name = ff1_q } },
                            };
                            try self.active_comb_stmts.?.append(.{
                                .tag = .assign,
                                .data = .{ .assign = .{ .target = target2, .value = src2 } },
                            });

                            // Return reference to ff2_q
                            h_expr.* = .{
                                .tag = .signal_ref,
                                .hir_type = h_type,
                                .data = .{ .signal_ref = .{ .name = ff2_q } },
                            };
                        }
                    },
                    else => {
                        h_expr.* = .{
                            .tag = .lit,
                            .hir_type = .{ .tag = .bits, .width = 32 },
                            .data = .{ .lit = .{ .val = 0, .raw = "0" } },
                        };
                    },
                }
            },
            .if_expr => {
                const ife = expr.data.if_expr;
                const cond = try self.lowerExpr(alloc, ife.cond, reg_map, signal_types);
                const then_e = try self.lowerExpr(alloc, ife.then_branch, reg_map, signal_types);
                const else_e = try self.lowerExpr(alloc, ife.else_branch, reg_map, signal_types);

                if (then_e.hir_type.width > 0 and else_e.tag == .lit) {
                    else_e.hir_type.width = then_e.hir_type.width;
                } else if (else_e.hir_type.width > 0 and then_e.tag == .lit) {
                    then_e.hir_type.width = else_e.hir_type.width;
                }

                const mux_type = if (then_e.tag != .lit and then_e.hir_type.width > 0) then_e.hir_type else else_e.hir_type;

                h_expr.* = .{
                    .tag = .mux,
                    .hir_type = mux_type,
                    .data = .{
                        .mux = .{
                            .cond = cond,
                            .then_expr = then_e,
                            .else_expr = else_e,
                        },
                    },
                };
            },
            .struct_init => {
                const si = expr.data.struct_init;
                var resolved_type: ?hir.HirType = null;
                if (si.type_expr) |te| {
                    resolved_type = try self.lowerType(te);
                }

                if (resolved_type != null and resolved_type.?.tag == .tagged_union) {
                    if (si.fields.len > 0) {
                        return try self.lowerTaggedUnionInit(alloc, resolved_type.?, si.fields[0], reg_map, signal_types);
                    }
                }

                if (resolved_type != null and resolved_type.?.struct_fields.len > 0) {
                    const st = resolved_type.?;
                    var concat_args = ArrayList(*hir.HirExpr).init(alloc);
                    var idx = st.struct_fields.len;
                    while (idx > 0) {
                        idx -= 1;
                        const sf = st.struct_fields[idx];
                        var found_val: ?*ast.Expr = null;
                        for (si.fields) |f| {
                            if (std.mem.eql(u8, f.name, sf.name)) {
                                found_val = f.value;
                                break;
                            }
                        }
                        if (found_val) |fv| {
                            const lowered_f = try self.lowerExpr(alloc, fv, reg_map, signal_types);
                            if (lowered_f.tag == .lit and sf.width > 0) {
                                lowered_f.hir_type.width = sf.width;
                            }
                            try concat_args.append(lowered_f);
                        } else {
                            const zero_expr = try alloc.create(hir.HirExpr);
                            zero_expr.* = .{
                                .tag = .lit,
                                .hir_type = .{ .tag = .bits, .width = sf.width },
                                .data = .{ .lit = .{ .val = 0, .raw = "0" } },
                            };
                            try concat_args.append(zero_expr);
                        }
                    }
                    h_expr.* = .{
                        .tag = .concat,
                        .hir_type = st,
                        .data = .{ .concat = .{ .args = try concat_args.toOwnedSlice() } },
                    };
                } else {
                    var concat_args = ArrayList(*hir.HirExpr).init(alloc);
                    var total_w: u32 = 0;
                    var idx = si.fields.len;
                    while (idx > 0) {
                        idx -= 1;
                        const f = si.fields[idx];
                        const lowered_f = try self.lowerExpr(alloc, f.value, reg_map, signal_types);
                        total_w += lowered_f.hir_type.width;
                        try concat_args.append(lowered_f);
                    }
                    h_expr.* = .{
                        .tag = .concat,
                        .hir_type = .{ .tag = .bits, .width = total_w },
                        .data = .{ .concat = .{ .args = try concat_args.toOwnedSlice() } },
                    };
                }
            },
            .array_init => {
                const ai = expr.data.array_init;
                var resolved_type: ?hir.HirType = null;
                if (ai.type_expr) |te| {
                    resolved_type = try self.lowerType(te);
                }

                var elem_w: u32 = if (resolved_type) |rt| (if (rt.tag == .array) rt.elem_width else rt.width) else 0;
                var lowered_elems = ArrayList(*hir.HirExpr).init(alloc);

                for (ai.elements) |elem| {
                    const lowered_e = try self.lowerExpr(alloc, elem, reg_map, signal_types);
                    if (lowered_e.tag == .lit and elem_w > 0) {
                        lowered_e.hir_type.width = elem_w;
                    } else if (elem_w == 0 and lowered_e.hir_type.width > 0) {
                        elem_w = lowered_e.hir_type.width;
                    }
                    try lowered_elems.append(lowered_e);
                }

                const total_len: u32 = @intCast(ai.elements.len);
                const final_type: hir.HirType = if (resolved_type) |rt| rt else .{
                    .tag = .array,
                    .width = elem_w * total_len,
                    .elem_width = elem_w,
                    .array_len = total_len,
                };

                h_expr.* = .{
                    .tag = .array_init,
                    .hir_type = final_type,
                    .data = .{
                        .array_init = .{
                            .elements = try lowered_elems.toOwnedSlice(),
                        },
                    },
                };
            },
            .call => {
                const c = expr.data.call;
                const callee = c.callee;

                if (callee.tag == .member_access) {
                    const ma = callee.data.member_access;
                    var static_type_name: ?[]const u8 = null;
                    if (exprToDottedString(alloc, ma.target)) |target_dot| {
                        if (self.type_methods.contains(target_dot)) {
                            static_type_name = target_dot;
                        }
                    }
                    if (static_type_name == null and ma.target.tag == .identifier and self.type_methods.contains(ma.target.data.identifier)) {
                        static_type_name = ma.target.data.identifier;
                    }

                    if (static_type_name) |type_name| {
                        const methods = self.type_methods.get(type_name).?;
                        if (methods.get(ma.field)) |fn_decl| {
                            var new_env = std.StringHashMap(*hir.HirExpr).init(alloc);
                            for (fn_decl.params, 0..) |param, i| {
                                if (i < c.args.len) {
                                    const arg_val = try self.lowerExpr(alloc, c.args[i], reg_map, signal_types);
                                    try new_env.put(param.name, arg_val);
                                }
                            }
                            const prev_env = self.param_env;
                            self.param_env = &new_env;
                            defer self.param_env = prev_env;

                            var inlined_res = try self.lowerExpr(alloc, fn_decl.body_expr, reg_map, signal_types);
                            if (fn_decl.return_type) |rt| {
                                const ret_h = try self.lowerType(rt);
                                if (ret_h.width > 0) inlined_res.hir_type.width = ret_h.width;
                                if (ret_h.name.len > 0) inlined_res.hir_type.name = ret_h.name;
                                if (ret_h.tag != .bits) inlined_res.hir_type = ret_h;
                            }
                            h_expr.* = inlined_res.*;
                            return h_expr;
                        }
                    } else if (exprToDottedString(alloc, callee)) |full_fn| {
                        const found_fn = self.fn_decls.get(full_fn) orelse self.fn_decls.get(ma.field);
                        if (found_fn) |fn_decl| {
                            var new_env = std.StringHashMap(*hir.HirExpr).init(alloc);
                            for (fn_decl.params, 0..) |param, i| {
                                if (i < c.args.len) {
                                    const arg_val = try self.lowerExpr(alloc, c.args[i], reg_map, signal_types);
                                    try new_env.put(param.name, arg_val);
                                }
                            }
                            const prev_env = self.param_env;
                            self.param_env = &new_env;
                            defer self.param_env = prev_env;

                            var inlined_res = try self.lowerExpr(alloc, fn_decl.body_expr, reg_map, signal_types);
                            if (fn_decl.return_type) |rt| {
                                const ret_h = try self.lowerType(rt);
                                if (ret_h.width > 0) inlined_res.hir_type.width = ret_h.width;
                                if (ret_h.name.len > 0) inlined_res.hir_type.name = ret_h.name;
                                if (ret_h.tag != .bits) inlined_res.hir_type = ret_h;
                            }
                            h_expr.* = inlined_res.*;
                            return h_expr;
                        }
                    }

                    // Otherwise, lower target = try self.lowerExpr(...)
                    const target = try self.lowerExpr(alloc, ma.target, reg_map, signal_types);
                    var type_name = target.hir_type.name;
                    if (type_name.len == 0) {
                        var tit = self.types.iterator();
                        while (tit.next()) |entry| {
                            if (entry.value_ptr.tag == target.hir_type.tag and entry.value_ptr.width == target.hir_type.width) {
                                if (self.type_methods.contains(entry.key_ptr.*)) {
                                    type_name = entry.key_ptr.*;
                                    break;
                                }
                            }
                        }
                    }
                    if (type_name.len > 0) {
                        if (self.type_methods.get(type_name)) |methods| {
                            if (methods.get(ma.field)) |fn_decl| {
                                var new_env = std.StringHashMap(*hir.HirExpr).init(alloc);
                                if (fn_decl.params.len > 0) {
                                    try new_env.put(fn_decl.params[0].name, target);
                                    for (fn_decl.params[1..], 0..) |param, i| {
                                        if (i < c.args.len) {
                                            const arg_val = try self.lowerExpr(alloc, c.args[i], reg_map, signal_types);
                                            try new_env.put(param.name, arg_val);
                                        }
                                    }
                                }
                                const prev_env = self.param_env;
                                self.param_env = &new_env;
                                defer self.param_env = prev_env;

                                var inlined_res = try self.lowerExpr(alloc, fn_decl.body_expr, reg_map, signal_types);
                                if (fn_decl.return_type) |rt| {
                                    const ret_h = try self.lowerType(rt);
                                    if (ret_h.width > 0) inlined_res.hir_type.width = ret_h.width;
                                    if (ret_h.name.len > 0) inlined_res.hir_type.name = ret_h.name;
                                    if (ret_h.tag != .bits) inlined_res.hir_type = ret_h;
                                }
                                h_expr.* = inlined_res.*;
                                return h_expr;
                            }
                        }
                    }
                } else if (callee.tag == .identifier and self.fn_decls.contains(callee.data.identifier)) {
                    const fn_decl = self.fn_decls.get(callee.data.identifier).?;
                    if (fn_decl.body_expr.tag == .module_literal) {
                        return error.TypeMismatch;
                    }
                    var new_env = std.StringHashMap(*hir.HirExpr).init(alloc);
                    for (fn_decl.params, 0..) |param, i| {
                        if (i < c.args.len) {
                            const arg_val = try self.lowerExpr(alloc, c.args[i], reg_map, signal_types);
                            try new_env.put(param.name, arg_val);
                        }
                    }
                    const prev_env = self.param_env;
                    self.param_env = &new_env;
                    defer self.param_env = prev_env;

                    var inlined_res = try self.lowerExpr(alloc, fn_decl.body_expr, reg_map, signal_types);
                    if (fn_decl.return_type) |rt| {
                        const ret_h = try self.lowerType(rt);
                        if (ret_h.width > 0) inlined_res.hir_type.width = ret_h.width;
                        if (ret_h.name.len > 0) inlined_res.hir_type.name = ret_h.name;
                        if (ret_h.tag != .bits) inlined_res.hir_type = ret_h;
                    }
                    h_expr.* = inlined_res.*;
                    return h_expr;
                }

                h_expr.* = .{
                    .tag = .lit,
                    .hir_type = .{ .tag = .bits, .width = 32 },
                    .data = .{ .lit = .{ .val = 0, .raw = "0" } },
                };
            },
            else => {
                h_expr.* = .{
                    .tag = .lit,
                    .hir_type = .{ .tag = .bits, .width = 32 },
                    .data = .{ .lit = .{ .val = 0, .raw = "0" } },
                };
            },
        }

        return h_expr;
    }

    fn lowerType(self: *Elaborator, t: *ast.Type) !hir.HirType {
        switch (t.tag) {
            .int => {
                const w = self.evalConst(t.data.int.width);
                return .{
                    .tag = .bits,
                    .width = @intCast(w),
                    .is_signed = t.data.int.is_signed,
                };
            },
            .array => {
                const len = self.evalConst(t.data.array.len);
                const elem_t = try self.lowerType(t.data.array.elem_type);
                return .{
                    .tag = .array,
                    .width = elem_t.width * @as(u32, @intCast(len)),
                    .elem_width = elem_t.width,
                    .array_len = @intCast(len),
                };
            },
            .named => {
                const name = t.data.named;
                if (std.mem.eql(u8, name, "clock")) {
                    return .{ .tag = .clock, .width = 1 };
                }
                if (std.mem.eql(u8, name, "reset") or std.mem.eql(u8, name, "reset_n") or std.mem.eql(u8, name, "reset_low")) {
                    std.debug.print(
                        \\
                        \\======================================================================
                        \\COMPILE ERROR: Underspecified Reset Mode for '{s}'
                        \\======================================================================
                        \\Resets must explicitly declare their synchronization mode:
                        \\  reset(.async)
                        \\  reset(.async, .active_low)
                        \\  reset(.sync)
                        \\  reset(.sync, .active_low)
                        \\======================================================================
                        \\
                    , .{name});
                    return error.UnderspecifiedReset;
                }
                if (self.types.get(name)) |found| {
                    return found;
                }
                return .{ .tag = .bits, .width = 1, .name = name };
            },
            .reset => {
                return .{
                    .tag = .reset,
                    .width = 1,
                    .is_active_low = t.data.reset.is_active_low,
                    .is_sync = t.data.reset.is_sync,
                };
            },
            .enum_type => {
                const N = t.data.enum_type.fields.len;
                const tag_w: u32 = if (t.data.enum_type.tag_type != null)
                    (try self.lowerType(t.data.enum_type.tag_type.?)).width
                else if (N <= 1)
                    1
                else
                    @intCast(std.math.log2_int_ceil(usize, N));

                var variants = try self.allocator.alloc(hir.HirEnumVariant, N);
                try self.allocated_enum_variants.append(variants);

                var cur_val: u64 = 0;
                for (t.data.enum_type.fields, 0..) |f, i| {
                    if (f.value) |v| {
                        cur_val = self.evalConst(v);
                    }
                    variants[i] = .{
                        .name = f.name,
                        .value = cur_val,
                    };
                    try self.enum_variants.put(f.name, cur_val);
                    cur_val += 1;
                }

                return .{
                    .tag = .enum_type,
                    .width = tag_w,
                    .enum_variants = variants,
                };
            },
            .packed_struct => {
                const f_count = t.data.packed_struct.fields.len;
                var struct_fields = try self.allocator.alloc(hir.HirStructField, f_count);
                try self.allocated_struct_fields.append(struct_fields);
                var offset: u32 = 0;
                for (t.data.packed_struct.fields, 0..) |f, i| {
                    const f_type = try self.lowerType(f.type_expr);
                    struct_fields[i] = .{
                        .name = f.name,
                        .width = f_type.width,
                        .offset = offset,
                    };
                    offset += f_type.width;
                }
                return .{
                    .tag = .packed_struct,
                    .width = offset,
                    .struct_fields = struct_fields,
                };
            },
            .optional => {
                const child_t = try self.lowerType(t.data.optional);
                const total_w = child_t.width + 1;
                var struct_fields = try self.allocator.alloc(hir.HirStructField, 2);
                try self.allocated_struct_fields.append(struct_fields);
                struct_fields[0] = .{
                    .name = "data",
                    .width = child_t.width,
                    .offset = 0,
                };
                struct_fields[1] = .{
                    .name = "valid",
                    .width = 1,
                    .offset = child_t.width,
                };
                return .{
                    .tag = .optional,
                    .width = total_w,
                    .elem_width = child_t.width,
                    .struct_fields = struct_fields,
                };
            },
            .tagged_union => {
                const u_data = t.data.tagged_union;
                const N = u_data.fields.len;
                const tag_w: u32 = if (u_data.tag_type != null)
                    (try self.lowerType(u_data.tag_type.?)).width
                else if (N <= 1)
                    1
                else
                    @intCast(std.math.log2_int_ceil(usize, N));

                var max_payload_w: u32 = 0;
                for (u_data.fields) |f| {
                    if (f.type_expr) |te| {
                        const ft = try self.lowerType(te);
                        max_payload_w = @max(max_payload_w, ft.width);
                    }
                }

                const total_w = tag_w + max_payload_w;

                var union_fields = try self.allocator.alloc(hir.HirUnionField, N);
                try self.allocated_union_fields.append(union_fields);

                for (u_data.fields, 0..) |f, i| {
                    var f_payload_w: u32 = 0;
                    var f_type_name: []const u8 = "";
                    if (f.type_expr) |te| {
                        const ft = try self.lowerType(te);
                        f_payload_w = ft.width;
                        if (te.tag == .named) {
                            f_type_name = te.data.named;
                        } else if (ft.name.len > 0) {
                            f_type_name = ft.name;
                        }
                    }
                    union_fields[i] = .{
                        .name = f.name,
                        .tag_value = @intCast(i),
                        .payload_width = f_payload_w,
                        .payload_type_name = f_type_name,
                    };
                    try self.enum_variants.put(f.name, @intCast(i));
                }

                var struct_fields = try self.allocator.alloc(hir.HirStructField, 1 + N);
                try self.allocated_struct_fields.append(struct_fields);

                struct_fields[0] = .{
                    .name = "tag",
                    .width = tag_w,
                    .offset = max_payload_w,
                };
                for (union_fields, 0..) |uf, i| {
                    struct_fields[1 + i] = .{
                        .name = uf.name,
                        .width = uf.payload_width,
                        .offset = 0,
                    };
                }

                return .{
                    .tag = .tagged_union,
                    .width = total_w,
                    .elem_width = max_payload_w,
                    .tag_width = tag_w,
                    .union_fields = union_fields,
                    .struct_fields = struct_fields,
                };
            },
            .struct_type => {
                return .{
                    .tag = .bits,
                    .width = 0,
                };
            },
        }
    }

    // =========================================================================
    // Race Condition Prevention & Static Verification Checks
    // =========================================================================

    const DriverKind = enum {
        input_port,
        submodule_output,
        continuous_wire,
        comb_block,
    };

    const DriverInfo = struct {
        kind: DriverKind,
        desc: []const u8,
        comb_block_idx: ?usize = null,
    };

    fn getHirTargetBaseName(target: *const hir.HirExpr) ?[]const u8 {
        switch (target.tag) {
            .signal_ref => return target.data.signal_ref.name,
            .index => return getHirTargetBaseName(target.data.index.target),
            .slice => return getHirTargetBaseName(target.data.slice.target),
            .member => return getHirTargetBaseName(target.data.member.target),
            else => return null,
        }
    }

    fn collectTargetsFromAstStatements(stmts: []const ast.Statement, out_targets: *std.StringHashMap(void)) !void {
        for (stmts) |stmt| {
            switch (stmt.tag) {
                .assign => {
                    var names = ArrayList([]const u8).init(out_targets.allocator);
                    defer names.deinit();
                    try collectAstTargetBaseNames(stmt.data.assign.target, &names);
                    for (names.items) |name| {
                        try out_targets.put(name, {});
                    }
                },
                .var_decl => {
                    try out_targets.put(stmt.data.var_decl.name, {});
                },
                .if_stmt => {
                    try collectTargetsFromAstStatements(stmt.data.if_stmt.then_stmts, out_targets);
                    if (stmt.data.if_stmt.else_stmts) |es| {
                        try collectTargetsFromAstStatements(es, out_targets);
                    }
                },
                .switch_stmt => {
                    for (stmt.data.switch_stmt.cases) |c| {
                        try collectTargetsFromAstStatements(c.body, out_targets);
                    }
                },
                .inline_for => {
                    try collectTargetsFromAstStatements(stmt.data.inline_for.body, out_targets);
                },
                .expr_stmt => {},
            }
        }
    }

    fn checkMultiDrivers(
        self: *Elaborator,
        alloc: std.mem.Allocator,
        mod_name: []const u8,
        items: []ast.ModuleItem,
        ports: []const hir.HirPort,
        instances: []const hir.HirSubmoduleInstance,
        reg_map: *const std.StringHashMap(hir.HirRegister),
        module_ports: *const std.StringHashMap([]hir.HirPort),
    ) !void {
        _ = reg_map;
        var drivers = std.StringHashMap(DriverInfo).init(alloc);
        var input_ports = std.StringHashMap(void).init(alloc);

        // 1. Register input ports
        for (ports) |p| {
            if (p.dir == .in) {
                try drivers.put(p.name, .{ .kind = .input_port, .desc = "module input port" });
                try input_ports.put(p.name, {});
            }
        }

        // 2. Register submodule instance outputs
        for (instances) |inst| {
            if (module_ports.get(inst.module_name)) |sub_ports| {
                for (inst.connections) |conn| {
                    for (sub_ports) |sp| {
                        if (std.mem.eql(u8, sp.name, conn.port_name)) {
                            if (sp.dir == .out) {
                                if (getHirTargetBaseName(conn.expr)) |target_name| {
                                    if (drivers.get(target_name)) |existing| {
                                        std.debug.print(
                                            \\
                                            \\======================================================================
                                            \\COMPILE ERROR: Multiple Drivers Detected on Signal '{s}' in module '{s}'
                                            \\======================================================================
                                            \\The signal '{s}' is driven by multiple concurrent sources:
                                            \\  1. {s}
                                            \\  2. submodule instance 'u_{s}' output port '.{s}'
                                            \\
                                            \\Reason:
                                            \\  In hardware, driving a wire or net from two concurrent drivers creates
                                            \\  electrical contention (short circuit in physical silicon, 1'bx in simulation).
                                            \\  Every wire and output port must have exactly one concurrent driver.
                                            \\======================================================================
                                            \\
                                            , .{ target_name, mod_name, target_name, existing.desc, inst.instance_name, conn.port_name });
                                        return error.MultipleDrivers;
                                    }
                                    const desc = try std.fmt.allocPrint(alloc, "submodule instance 'u_{s}' output port '.{s}'", .{ inst.instance_name, conn.port_name });
                                    try drivers.put(target_name, .{ .kind = .submodule_output, .desc = desc });
                                }
                            }
                            break;
                        }
                    }
                }
            }
        }

        // 3. Register continuous wire declarations
        for (items) |item| {
            if (item.tag == .const_decl) {
                const c = item.data.const_decl;
                if (c.val.tag != .number and c.val.tag != .type_expr and self.resolveGenericCall(c.val, items) == null) {
                    if (drivers.get(c.name)) |existing| {
                        std.debug.print(
                            \\
                            \\======================================================================
                            \\COMPILE ERROR: Multiple Drivers Detected on Signal '{s}' in module '{s}'
                            \\======================================================================
                            \\The signal '{s}' is driven by multiple concurrent sources:
                            \\  1. {s}
                            \\  2. continuous wire declaration '{s}'
                            \\
                            \\Reason:
                            \\  Every wire must have exactly one concurrent driver.
                            \\======================================================================
                            \\
                            , .{ c.name, mod_name, c.name, existing.desc, c.name });
                        return error.MultipleDrivers;
                    }
                    const desc = try std.fmt.allocPrint(alloc, "continuous wire declaration '{s}'", .{c.name});
                    try drivers.put(c.name, .{ .kind = .continuous_wire, .desc = desc });
                }
            }
        }

        // 4. Check top-level procedural statements
        var top_level_written = std.StringHashMap(void).init(alloc);
        defer top_level_written.deinit();

        for (items) |item| {
            if (item.tag == .stmt) {
                var single_slice = [1]ast.Statement{item.data.stmt};
                try collectTargetsFromAstStatements(&single_slice, &top_level_written);
            }
        }

        var top_it = top_level_written.keyIterator();
        while (top_it.next()) |k| {
            const target_name = k.*;

            if (input_ports.contains(target_name)) {
                std.debug.print(
                    \\
                    \\======================================================================
                    \\COMPILE ERROR: Cannot Assign to Input Port '{s}' in module '{s}'
                    \\======================================================================
                    \\The signal '{s}' is declared as an input port and cannot be driven internally.
                    \\
                    \\Reason:
                    \\  Input ports are driven externally by the parent module or testbench.
                    \\  Driving an input port from within the module causes illegal contention.
                    \\======================================================================
                    \\
                    , .{ target_name, mod_name, target_name });
                return error.CannotAssignInputPort;
            }

            if (drivers.get(target_name)) |existing| {
                const target_label = target_name;

                std.debug.print(
                    \\
                    \\======================================================================
                    \\COMPILE ERROR: Multiple Drivers Detected on Signal '{s}' in module '{s}'
                    \\======================================================================
                    \\The signal '{s}' is driven by multiple concurrent sources:
                    \\  1. {s}
                    \\  2. top-level module statement on '{s}'
                    \\
                    \\Reason:
                    \\  In hardware, concurrent blocks cannot drive the same net without creating contention.
                    \\======================================================================
                    \\
                    , .{ target_label, mod_name, target_label, existing.desc, target_label });
                return error.MultipleDrivers;
            } else {
                const target_label = target_name;
                const desc = try std.fmt.allocPrint(alloc, "top-level module statement on '{s}'", .{target_label});
                try drivers.put(target_name, .{
                    .kind = .comb_block,
                    .desc = desc,
                    .comb_block_idx = 0,
                });
            }
        }

        // 5. Check comb blocks
        var comb_block_count: usize = 0;
        for (items) |item| {
            if (item.tag == .comb_block) {
                comb_block_count += 1;
                const current_idx = comb_block_count;

                var comb_written = std.StringHashMap(void).init(alloc);
                try collectTargetsFromAstStatements(item.data.comb_block.stmts, &comb_written);

                var it = comb_written.keyIterator();
                while (it.next()) |k| {
                    const target_name = k.*;

                    if (input_ports.contains(target_name)) {
                        std.debug.print(
                            \\
                            \\======================================================================
                            \\COMPILE ERROR: Cannot Assign to Input Port '{s}' in module '{s}'
                            \\======================================================================
                            \\The signal '{s}' is declared as an input port and cannot be driven internally.
                            \\
                            \\Reason:
                            \\  Input ports are driven externally by the parent module or testbench.
                            \\  Driving an input port from within the module causes illegal contention.
                            \\======================================================================
                            \\
                            , .{ target_name, mod_name, target_name });
                        return error.CannotAssignInputPort;
                    }

                    if (drivers.get(target_name)) |existing| {
                        if (existing.kind == .submodule_output or existing.kind == .continuous_wire or
                            (existing.kind == .comb_block and existing.comb_block_idx != null and existing.comb_block_idx.? != current_idx))
                        {
                            const target_label = target_name;

                            std.debug.print(
                                \\
                                \\======================================================================
                                \\COMPILE ERROR: Multiple Drivers Detected on Signal '{s}' in module '{s}'
                                \\======================================================================
                                \\The signal '{s}' is driven by multiple concurrent sources:
                                \\  1. {s}
                                \\  2. procedural assignment in comb block #{d}
                                \\
                                \\Reason:
                                \\  In hardware, concurrent blocks cannot drive the same net without creating contention.
                                \\======================================================================
                                \\
                                , .{ target_label, mod_name, target_label, existing.desc, current_idx });
                            return error.MultipleDrivers;
                        }
                    } else {
                        const target_label = target_name;
                        const desc = try std.fmt.allocPrint(alloc, "procedural assignment to '{s}' in comb block #{d}", .{ target_label, current_idx });
                        try drivers.put(target_name, .{
                            .kind = .comb_block,
                            .desc = desc,
                            .comb_block_idx = current_idx,
                        });
                    }
                }
            }
        }
    }

    fn collectExprSignals(expr: *const hir.HirExpr, out_signals: *ArrayList([]const u8)) anyerror!void {
        switch (expr.tag) {
            .lit => {},
            .signal_ref => {
                try out_signals.append(expr.data.signal_ref.name);
            },
            .member => {
                try collectExprSignals(expr.data.member.target, out_signals);
            },
            .slice => {
                try collectExprSignals(expr.data.slice.target, out_signals);
            },
            .index => {
                try collectExprSignals(expr.data.index.target, out_signals);
                try collectExprSignals(expr.data.index.index, out_signals);
            },
            .concat => {
                for (expr.data.concat.args) |a| {
                    try collectExprSignals(a, out_signals);
                }
            },
            .bit_reverse => {
                try collectExprSignals(expr.data.bit_reverse.target, out_signals);
            },
            .byte_swap => {
                try collectExprSignals(expr.data.byte_swap.target, out_signals);
            },
            .unary => {
                try collectExprSignals(expr.data.unary.operand, out_signals);
            },
            .binary => {
                try collectExprSignals(expr.data.binary.left, out_signals);
                try collectExprSignals(expr.data.binary.right, out_signals);
            },
            .mux => {
                try collectExprSignals(expr.data.mux.cond, out_signals);
                try collectExprSignals(expr.data.mux.then_expr, out_signals);
                try collectExprSignals(expr.data.mux.else_expr, out_signals);
            },
            .array_init => {
                for (expr.data.array_init.elements) |elem| {
                    try collectExprSignals(elem, out_signals);
                }
            },
            .replicate => {
                try collectExprSignals(expr.data.replicate.val, out_signals);
            },
            .part_select => {
                try collectExprSignals(expr.data.part_select.target, out_signals);
                try collectExprSignals(expr.data.part_select.base, out_signals);
            },
            .signed_cast => {
                try collectExprSignals(expr.data.signed_cast.target, out_signals);
            },
        }
    }

    fn walkStmtForDependencies(
        stmt: hir.HirStatement,
        cond_sources: *ArrayList([]const u8),
        graph: *std.StringHashMap(ArrayList([]const u8)),
        comb_signals: *const std.StringHashMap(void),
        alloc: std.mem.Allocator,
    ) anyerror!void {
        switch (stmt.tag) {
            .assign => {
                var targets = ArrayList([]const u8).init(alloc);
                defer targets.deinit();
                try collectHirTargetBaseNames(stmt.data.assign.target, &targets);

                var sources = ArrayList([]const u8).init(alloc);
                defer sources.deinit();
                try collectExprSignals(stmt.data.assign.value, &sources);

                for (targets.items) |target_name| {
                    if (!comb_signals.contains(target_name)) continue;

                    var adj = graph.getPtr(target_name) orelse continue;

                    for (sources.items) |s| {
                        if (comb_signals.contains(s)) {
                            var already = false;
                            for (adj.items) |existing| {
                                if (std.mem.eql(u8, existing, s)) {
                                    already = true;
                                    break;
                                }
                            }
                            if (!already) {
                                try adj.append(s);
                            }
                        }
                    }

                    for (cond_sources.items) |cs| {
                        if (comb_signals.contains(cs)) {
                            var already = false;
                            for (adj.items) |existing| {
                                if (std.mem.eql(u8, existing, cs)) {
                                    already = true;
                                    break;
                                }
                            }
                            if (!already) {
                                try adj.append(cs);
                            }
                        }
                    }
                }
            },
            .if_stmt => {
                const ifs = stmt.data.if_stmt;
                var cond_sigs = ArrayList([]const u8).init(alloc);
                try collectExprSignals(ifs.cond, &cond_sigs);

                const old_len = cond_sources.items.len;
                for (cond_sigs.items) |cs| {
                    if (comb_signals.contains(cs)) {
                        try cond_sources.append(cs);
                    }
                }

                for (ifs.then_body) |s| {
                    try walkStmtForDependencies(s, cond_sources, graph, comb_signals, alloc);
                }
                if (ifs.else_body) |eb| {
                    for (eb) |s| {
                        try walkStmtForDependencies(s, cond_sources, graph, comb_signals, alloc);
                    }
                }

                cond_sources.shrinkRetainingCapacity(old_len);
            },
            .case_stmt => {
                const cs = stmt.data.case_stmt;
                var expr_sigs = ArrayList([]const u8).init(alloc);
                try collectExprSignals(cs.expr, &expr_sigs);

                const old_len = cond_sources.items.len;
                for (expr_sigs.items) |es| {
                    if (comb_signals.contains(es)) {
                        try cond_sources.append(es);
                    }
                }

                for (cs.branches) |b| {
                    for (b.body) |s| {
                        try walkStmtForDependencies(s, cond_sources, graph, comb_signals, alloc);
                    }
                }

                cond_sources.shrinkRetainingCapacity(old_len);
            },
        }
    }

    fn dfsCycleCheck(
        self: *Elaborator,
        u: []const u8,
        graph: *std.StringHashMap(ArrayList([]const u8)),
        color: *std.StringHashMap(u8),
        cycle_path: *ArrayList([]const u8),
        mod_name: []const u8,
        alloc: std.mem.Allocator,
    ) anyerror!void {
        try color.put(u, 1); // Gray (visiting)
        try cycle_path.append(u);

        if (graph.get(u)) |neighbors| {
            for (neighbors.items) |v| {
                const v_color = color.get(v) orelse 0;
                if (v_color == 1) {
                    // Cycle detected!
                    var cycle_start: usize = 0;
                    for (cycle_path.items, 0..) |p, i| {
                        if (std.mem.eql(u8, p, v)) {
                            cycle_start = i;
                            break;
                        }
                    }

                    var cycle_str = ArrayList(u8).init(alloc);
                    for (cycle_path.items[cycle_start..]) |node| {
                        try cycle_str.appendSlice(node);
                        try cycle_str.appendSlice(" -> ");
                    }
                    try cycle_str.appendSlice(v);

                    std.debug.print(
                        \\
                        \\======================================================================
                        \\COMPILE ERROR: Combinational Loop Detected in module '{s}'
                        \\======================================================================
                        \\A cyclic dependency exists among purely combinational signals:
                        \\  {s}
                        \\
                        \\Reason:
                        \\  Combinational logic cannot form a closed loop without an intervening
                        \\  clocked register (D-flip-flop). This creates an unstable analog ring
                        \\  oscillator in physical silicon and hangs event-driven simulators in
                        \\  infinite zero-delay delta-cycle loops.
                        \\
                        \\Solution:
                        \\  Break the combinational cycle by declaring a clocked register:
                        \\    reg {s}: ... = 0;
                        \\    comb {{
                        \\        {s} := ...;
                        \\    }}
                        \\======================================================================
                        \\
                        , .{ mod_name, cycle_str.items, v, v });

                    return error.CombinationalLoop;
                } else if (v_color == 0) {
                    try self.dfsCycleCheck(v, graph, color, cycle_path, mod_name, alloc);
                }
            }
        }

        _ = cycle_path.pop();
        try color.put(u, 2); // Black (visited)
    }

    fn checkCombinationalLoops(
        self: *Elaborator,
        alloc: std.mem.Allocator,
        mod_name: []const u8,
        ports: []const hir.HirPort,
        local_signals: []const hir.HirSignal,
        comb_stmts: []const hir.HirStatement,
        reg_map: *const std.StringHashMap(hir.HirRegister),
    ) !void {
        var comb_signals = std.StringHashMap(void).init(alloc);

        // 1. Output and inout ports are combinational signals
        for (ports) |p| {
            if (p.dir == .out or p.dir == .inout) {
                try comb_signals.put(p.name, {});
            }
        }

        var reg_state_signals = std.StringHashMap(void).init(alloc);
        defer reg_state_signals.deinit();
        var reg_it = reg_map.valueIterator();
        while (reg_it.next()) |r| {
            try reg_state_signals.put(r.q_name, {});
            try reg_state_signals.put(r.d_name, {});
        }

        // 2. Local signals that are not registers or internal register nets are combinational wires
        for (local_signals) |s| {
            if (reg_map.get(s.name) != null) continue;
            if (reg_state_signals.contains(s.name)) continue;
            try comb_signals.put(s.name, {});
        }

        // 3. Build graph
        var graph = std.StringHashMap(ArrayList([]const u8)).init(alloc);
        var it = comb_signals.keyIterator();
        while (it.next()) |k| {
            try graph.put(k.*, ArrayList([]const u8).init(alloc));
        }

        // 4. Populate edges
        var cond_sources = ArrayList([]const u8).init(alloc);
        for (comb_stmts) |stmt| {
            try walkStmtForDependencies(stmt, &cond_sources, &graph, &comb_signals, alloc);
        }

        // 5. DFS cycle detection
        var color = std.StringHashMap(u8).init(alloc);
        var cycle_path = ArrayList([]const u8).init(alloc);

        var node_it = comb_signals.keyIterator();
        while (node_it.next()) |k| {
            const u = k.*;
            const c = color.get(u) orelse 0;
            if (c == 0) {
                try self.dfsCycleCheck(u, &graph, &color, &cycle_path, mod_name, alloc);
            }
        }
    }

    fn checkReadBeforeWrite(
        self: *Elaborator,
        alloc: std.mem.Allocator,
        mod_name: []const u8,
        ports: []const hir.HirPort,
        local_signals: []const hir.HirSignal,
        comb_stmts: []const hir.HirStatement,
        reg_map: *const std.StringHashMap(hir.HirRegister),
        instances: []const hir.HirSubmoduleInstance,
        module_ports: *const std.StringHashMap([]hir.HirPort),
    ) !void {
        var comb_signals = std.StringHashMap(void).init(alloc);
        defer comb_signals.deinit();

        // 1. Output ports are combinational signals that must be assigned before read
        for (ports) |p| {
            if (p.dir == .out) {
                try comb_signals.put(p.name, {});
            }
        }

        var reg_state_signals = std.StringHashMap(void).init(alloc);
        defer reg_state_signals.deinit();
        var reg_it = reg_map.valueIterator();
        while (reg_it.next()) |r| {
            try reg_state_signals.put(r.name, {});
            try reg_state_signals.put(r.q_name, {});
            try reg_state_signals.put(r.d_name, {});
        }

        // 2. Local signals that are not registers or internal register nets are combinational wires
        for (local_signals) |s| {
            if (reg_map.get(s.name) != null) continue;
            if (reg_state_signals.contains(s.name)) continue;
            try comb_signals.put(s.name, {});
        }

        // 3. Populate initial 'safe to read' (written) signals:
        var written = std.StringHashMap(void).init(alloc);
        defer written.deinit();

        // Input and inout ports are always driven externally
        for (ports) |p| {
            if (p.dir == .in or p.dir == .inout) {
                try written.put(p.name, {});
            }
        }

        // Registers are always driven by their flop Q outputs (state from previous clock edge)
        var r_it = reg_map.valueIterator();
        while (r_it.next()) |r| {
            try written.put(r.name, {});
            try written.put(r.q_name, {});
        }

        // Submodule output connections are driven continuously by the instantiated child module
        for (instances) |inst| {
            if (module_ports.get(inst.module_name)) |sub_ports| {
                for (inst.connections) |conn| {
                    for (sub_ports) |sp| {
                        if (std.mem.eql(u8, sp.name, conn.port_name)) {
                            if (sp.dir == .out) {
                                if (getHirTargetBaseName(conn.expr)) |target_name| {
                                    try written.put(target_name, {});
                                }
                            }
                            break;
                        }
                    }
                }
            }
        }

        // Constants are safe to read
        var const_it = self.constants.keyIterator();
        while (const_it.next()) |k| {
            try written.put(k.*, {});
        }

        // 4. Walk procedural statements in order:
        for (comb_stmts) |stmt| {
            try self.walkStmtForReadBeforeWrite(alloc, &stmt, &written, &comb_signals, mod_name);
        }
    }

    fn walkStmtForReadBeforeWrite(
        self: *Elaborator,
        alloc: std.mem.Allocator,
        stmt: *const hir.HirStatement,
        written: *std.StringHashMap(void),
        comb_signals: *const std.StringHashMap(void),
        mod_name: []const u8,
    ) !void {
        switch (stmt.tag) {
            .assign => {
                const a = stmt.data.assign;
                // If target has subscript/index, check index expr
                if (a.target.tag == .index) {
                    try self.verifyExprReadSafety(a.target.data.index.index, written, comb_signals, mod_name);
                }
                // Verify all signals read in RHS are already written
                try self.verifyExprReadSafety(a.value, written, comb_signals, mod_name);
                // Now mark all target signals as written
                var targets = ArrayList([]const u8).init(alloc);
                defer targets.deinit();
                try collectHirTargetBaseNames(a.target, &targets);
                for (targets.items) |target_name| {
                    try written.put(target_name, {});
                }
            },
            .if_stmt => {
                const ifs = stmt.data.if_stmt;
                try self.verifyExprReadSafety(ifs.cond, written, comb_signals, mod_name);

                // Clone written set for then branch
                var then_written = std.StringHashMap(void).init(alloc);
                defer then_written.deinit();
                var it = written.keyIterator();
                while (it.next()) |k| try then_written.put(k.*, {});

                for (ifs.then_body) |s| {
                    try self.walkStmtForReadBeforeWrite(alloc, &s, &then_written, comb_signals, mod_name);
                }

                if (ifs.else_body) |eb| {
                    var else_written = std.StringHashMap(void).init(alloc);
                    defer else_written.deinit();
                    var e_it = written.keyIterator();
                    while (e_it.next()) |k| try else_written.put(k.*, {});

                    for (eb) |s| {
                        try self.walkStmtForReadBeforeWrite(alloc, &s, &else_written, comb_signals, mod_name);
                    }

                    // A signal is definitely written after if-else if written in BOTH branches
                    var t_it = then_written.keyIterator();
                    while (t_it.next()) |k| {
                        if (else_written.contains(k.*)) {
                            try written.put(k.*, {});
                        }
                    }
                }
            },
            .case_stmt => {
                const cs = stmt.data.case_stmt;
                try self.verifyExprReadSafety(cs.expr, written, comb_signals, mod_name);

                var has_default = false;
                var branch_written_list = ArrayList(std.StringHashMap(void)).init(alloc);
                defer {
                    for (branch_written_list.items) |*bw| bw.deinit();
                    branch_written_list.deinit();
                }

                for (cs.branches) |b| {
                    if (b.is_default) has_default = true;
                    var b_written = std.StringHashMap(void).init(alloc);
                    var it = written.keyIterator();
                    while (it.next()) |k| try b_written.put(k.*, {});

                    for (b.body) |s| {
                        try self.walkStmtForReadBeforeWrite(alloc, &s, &b_written, comb_signals, mod_name);
                    }
                    try branch_written_list.append(b_written);
                }

                if (has_default and branch_written_list.items.len > 0) {
                    var candidate_it = branch_written_list.items[0].keyIterator();
                    while (candidate_it.next()) |k| {
                        const sig = k.*;
                        var in_all = true;
                        for (branch_written_list.items[1..]) |bw| {
                            if (!bw.contains(sig)) {
                                in_all = false;
                                break;
                            }
                        }
                        if (in_all) {
                            try written.put(sig, {});
                        }
                    }
                }
            },
        }
    }

    fn verifyExprReadSafety(
        self: *Elaborator,
        expr: *const hir.HirExpr,
        written: *const std.StringHashMap(void),
        comb_signals: *const std.StringHashMap(void),
        mod_name: []const u8,
    ) anyerror!void {
        switch (expr.tag) {
            .signal_ref => {
                const name = expr.data.signal_ref.name;
                if (comb_signals.contains(name) and !written.contains(name)) {
                    std.debug.print(
                        \\
                        \\======================================================================
                        \\COMPILE ERROR: Read-Before-Write Hazard on Signal '{s}' in module '{s}'
                        \\======================================================================
                        \\Combinational signal '{s}' is read before it has been assigned.
                        \\
                        \\Reason:
                        \\  Reading a combinational wire before it is assigned in the procedural flow
                        \\  causes delta-cycle race conditions and simulation-synthesis mismatches.
                        \\
                        \\Fix:
                        \\  Assign '{s}' before reading it, or declare it as a clocked register ('reg').
                        \\======================================================================
                        \\
                        , .{ name, mod_name, name, name });
                    return error.ReadBeforeWriteHazard;
                }
            },
            .unary => {
                try self.verifyExprReadSafety(expr.data.unary.operand, written, comb_signals, mod_name);
            },
            .binary => {
                try self.verifyExprReadSafety(expr.data.binary.left, written, comb_signals, mod_name);
                try self.verifyExprReadSafety(expr.data.binary.right, written, comb_signals, mod_name);
            },
            .slice => {
                try self.verifyExprReadSafety(expr.data.slice.target, written, comb_signals, mod_name);
            },
            .index => {
                try self.verifyExprReadSafety(expr.data.index.target, written, comb_signals, mod_name);
                try self.verifyExprReadSafety(expr.data.index.index, written, comb_signals, mod_name);
            },
            .member => {
                try self.verifyExprReadSafety(expr.data.member.target, written, comb_signals, mod_name);
            },
            .bit_reverse => {
                try self.verifyExprReadSafety(expr.data.bit_reverse.target, written, comb_signals, mod_name);
            },
            .byte_swap => {
                try self.verifyExprReadSafety(expr.data.byte_swap.target, written, comb_signals, mod_name);
            },
            .concat => {
                for (expr.data.concat.args) |a| {
                    try self.verifyExprReadSafety(a, written, comb_signals, mod_name);
                }
            },
            .mux => {
                try self.verifyExprReadSafety(expr.data.mux.cond, written, comb_signals, mod_name);
                try self.verifyExprReadSafety(expr.data.mux.then_expr, written, comb_signals, mod_name);
                try self.verifyExprReadSafety(expr.data.mux.else_expr, written, comb_signals, mod_name);
            },
            .array_init => {
                for (expr.data.array_init.elements) |elem| {
                    try self.verifyExprReadSafety(elem, written, comb_signals, mod_name);
                }
            },
            .replicate => {
                try self.verifyExprReadSafety(expr.data.replicate.val, written, comb_signals, mod_name);
            },
            .part_select => {
                try self.verifyExprReadSafety(expr.data.part_select.target, written, comb_signals, mod_name);
                try self.verifyExprReadSafety(expr.data.part_select.base, written, comb_signals, mod_name);
            },
            .signed_cast => {
                try self.verifyExprReadSafety(expr.data.signed_cast.target, written, comb_signals, mod_name);
            },
            else => {},
        }
    }

    fn walkStmtForCdcDependencies(
        stmt: hir.HirStatement,
        cond_sources: *ArrayList([]const u8),
        dep_graph: *std.StringHashMap(ArrayList([]const u8)),
        alloc: std.mem.Allocator,
    ) anyerror!void {
        switch (stmt.tag) {
            .assign => {
                var targets = ArrayList([]const u8).init(alloc);
                defer targets.deinit();
                try collectHirTargetBaseNames(stmt.data.assign.target, &targets);

                var sources = ArrayList([]const u8).init(alloc);
                defer sources.deinit();
                try collectExprSignals(stmt.data.assign.value, &sources);

                for (targets.items) |target_name| {
                    const gop = try dep_graph.getOrPut(target_name);
                    if (!gop.found_existing) {
                        gop.value_ptr.* = ArrayList([]const u8).init(alloc);
                    }
                    var adj = gop.value_ptr;

                    for (sources.items) |s| {
                        var already = false;
                        for (adj.items) |existing| {
                            if (std.mem.eql(u8, existing, s)) {
                                already = true;
                                break;
                            }
                        }
                        if (!already) {
                            try adj.append(s);
                        }
                    }

                    for (cond_sources.items) |cs| {
                        var already = false;
                        for (adj.items) |existing| {
                            if (std.mem.eql(u8, existing, cs)) {
                                already = true;
                                break;
                            }
                        }
                        if (!already) {
                            try adj.append(cs);
                        }
                    }
                }
            },
            .if_stmt => {
                const ifs = stmt.data.if_stmt;
                var cond_sigs = ArrayList([]const u8).init(alloc);
                try collectExprSignals(ifs.cond, &cond_sigs);

                const old_len = cond_sources.items.len;
                for (cond_sigs.items) |cs| {
                    try cond_sources.append(cs);
                }

                for (ifs.then_body) |s| {
                    try walkStmtForCdcDependencies(s, cond_sources, dep_graph, alloc);
                }
                if (ifs.else_body) |eb| {
                    for (eb) |s| {
                        try walkStmtForCdcDependencies(s, cond_sources, dep_graph, alloc);
                    }
                }

                cond_sources.shrinkRetainingCapacity(old_len);
            },
            .case_stmt => {
                const cs = stmt.data.case_stmt;
                var expr_sigs = ArrayList([]const u8).init(alloc);
                try collectExprSignals(cs.expr, &expr_sigs);

                const old_len = cond_sources.items.len;
                for (expr_sigs.items) |es| {
                    try cond_sources.append(es);
                }

                for (cs.branches) |b| {
                    for (b.body) |s| {
                        try walkStmtForCdcDependencies(s, cond_sources, dep_graph, alloc);
                    }
                }

                cond_sources.shrinkRetainingCapacity(old_len);
            },
        }
    }

    fn checkCdcPathDfs(
        current_signal: []const u8,
        dest_reg: *const hir.HirRegister,
        reg_by_q: *const std.StringHashMap(hir.HirRegister),
        async_ports: *const std.StringHashMap(void),
        dep_graph: *const std.StringHashMap(ArrayList([]const u8)),
        visited: *std.StringHashMap(void),
        path: *ArrayList([]const u8),
        mod_name: []const u8,
        alloc: std.mem.Allocator,
    ) anyerror!void {
        if (visited.contains(current_signal)) return;
        try visited.put(current_signal, {});
        try path.append(current_signal);
        defer _ = path.pop();

        // Check if current_signal is an asynchronous input port
        if (async_ports.contains(current_signal)) {
            var path_str = ArrayList(u8).init(alloc);
            try path_str.appendSlice(current_signal);

            if (path.items.len > 2) {
                var idx = path.items.len - 2;
                while (idx >= 1) : (idx -= 1) {
                    const node = path.items[idx];
                    if (!std.mem.eql(u8, node, current_signal) and
                        !std.mem.eql(u8, node, dest_reg.d_name) and
                        !std.mem.eql(u8, node, dest_reg.name))
                    {
                        try path_str.appendSlice(" -> ");
                        try path_str.appendSlice(node);
                    }
                }
            }
            try path_str.appendSlice(" -> ");
            try path_str.appendSlice(dest_reg.name);

            std.debug.print(
                \\
                \\======================================================================
                \\COMPILE ERROR: Direct Sampling of Asynchronous Input in module '{s}'
                \\======================================================================
                \\Illegal asynchronous transfer from external async port '{s}' into clock domain '{s}':
                \\  Async input port:     '{s}'
                \\  Destination register: '{s}' (clock: {s})
                \\  Dataflow path:        {s}
                \\
                \\Reason:
                \\  Directly sampling an asynchronous input port without synchronization causes
                \\  metastability and non-deterministic logic failures.
                \\
                \\Fix:
                \\  Pass the asynchronous input through a 2-stage flip-flop synchronizer:
                \\    wire {s}_sync = @sync2ff({s}, {s});
                \\======================================================================
                \\
                , .{
                    mod_name,
                    current_signal,
                    dest_reg.clk_name,
                    current_signal,
                    dest_reg.name,
                    dest_reg.clk_name,
                    path_str.items,
                    current_signal,
                    dest_reg.clk_name,
                    current_signal,
                },
            );

            return error.DirectAsyncInputSampling;
        }

        // Check if current_signal is a register output
        if (reg_by_q.get(current_signal)) |src_reg| {
            if (!std.mem.eql(u8, src_reg.clk_name, dest_reg.clk_name)) {
                // Illegal Clock Domain Crossing detected!
                var path_str = ArrayList(u8).init(alloc);
                try path_str.appendSlice(src_reg.name);

                if (path.items.len > 2) {
                    var idx = path.items.len - 2;
                    while (idx >= 1) : (idx -= 1) {
                        const node = path.items[idx];
                        if (!std.mem.eql(u8, node, src_reg.q_name) and
                            !std.mem.eql(u8, node, src_reg.name) and
                            !std.mem.eql(u8, node, dest_reg.d_name) and
                            !std.mem.eql(u8, node, dest_reg.name))
                        {
                            try path_str.appendSlice(" -> ");
                            try path_str.appendSlice(node);
                        }
                    }
                }
                try path_str.appendSlice(" -> ");
                try path_str.appendSlice(dest_reg.name);

                std.debug.print(
                    \\
                    \\======================================================================
                    \\COMPILE ERROR: Unsafe Clock Domain Crossing in module '{s}'
                    \\======================================================================
                    \\Illegal asynchronous transfer from clock domain '{s}' to '{s}':
                    \\  Source register:      '{s}' (clock: {s})
                    \\  Destination register: '{s}' (clock: {s})
                    \\  Dataflow path:        {s}
                    \\
                    \\Reason:
                    \\  Sampling registers across asynchronous clock domains without synchronization
                    \\  causes metastability and non-deterministic race conditions.
                    \\
                    \\Fix:
                    \\  Synchronize the cross-domain signal using a 2-stage flip-flop synchronizer:
                    \\    wire {s}_sync = @sync2ff({s}, {s});
                    \\======================================================================
                    \\
                    , .{
                        mod_name,
                        src_reg.clk_name,
                        dest_reg.clk_name,
                        src_reg.name,
                        src_reg.clk_name,
                        dest_reg.name,
                        dest_reg.clk_name,
                        path_str.items,
                        src_reg.name,
                        dest_reg.clk_name,
                        src_reg.name,
                    },
                );

                return error.ClockDomainCrossing;
            }
            // Same clock domain: sequential boundary reached, stop search
            return;
        }

        // Combinational wire: recurse to its sources
        if (dep_graph.get(current_signal)) |sources| {
            for (sources.items) |src| {
                try checkCdcPathDfs(
                    src,
                    dest_reg,
                    reg_by_q,
                    async_ports,
                    dep_graph,
                    visited,
                    path,
                    mod_name,
                    alloc,
                );
            }
        }
    }

    fn checkClockDomainCrossing(
        self: *Elaborator,
        alloc: std.mem.Allocator,
        mod_name: []const u8,
        registers: []const hir.HirRegister,
        comb_stmts: []const hir.HirStatement,
        reg_map: *const std.StringHashMap(hir.HirRegister),
        ports: []const hir.HirPort,
    ) !void {
        _ = self;
        _ = reg_map;

        // 1. Collect distinct clock domains and async input ports
        var clk_domains = std.StringHashMap(void).init(alloc);
        for (registers) |r| {
            try clk_domains.put(r.clk_name, {});
        }

        var async_ports = std.StringHashMap(void).init(alloc);
        for (ports) |p| {
            if (p.is_async and p.dir == .in) {
                try async_ports.put(p.name, {});
            }
        }

        // Fast path: single-clock designs with no async inputs have 0 overhead
        if (clk_domains.count() <= 1 and async_ports.count() == 0) {
            return;
        }

        // 2. Map register Q outputs and base names to register definitions
        var reg_by_q = std.StringHashMap(hir.HirRegister).init(alloc);
        for (registers) |r| {
            try reg_by_q.put(r.q_name, r);
            try reg_by_q.put(r.name, r);
        }

        // 3. Build combinational dependency graph: target -> [sources]
        var dep_graph = std.StringHashMap(ArrayList([]const u8)).init(alloc);
        var cond_sources = ArrayList([]const u8).init(alloc);
        for (comb_stmts) |stmt| {
            try walkStmtForCdcDependencies(stmt, &cond_sources, &dep_graph, alloc);
        }

        // 4. Trace backward from each non-synchronizer destination register's D-input
        for (registers) |dest_reg| {
            if (dest_reg.is_sync_stage) continue;

            if (dep_graph.get(dest_reg.d_name)) |sources| {
                var visited = std.StringHashMap(void).init(alloc);
                var path = ArrayList([]const u8).init(alloc);
                try path.append(dest_reg.d_name);

                for (sources.items) |src| {
                    try checkCdcPathDfs(
                        src,
                        &dest_reg,
                        &reg_by_q,
                        &async_ports,
                        &dep_graph,
                        &visited,
                        &path,
                        mod_name,
                        alloc,
                    );
                }
            }
        }
    }

    fn evalConstEx(self: *Elaborator, expr: *ast.Expr, local_consts: ?*const std.StringHashMap(u64)) u64 {
        switch (expr.tag) {
            .number => return expr.data.number.val,
            .time_literal => return convertToNs(expr.data.time_literal),
            .freq_literal => return convertFreqToNs(expr.data.freq_literal),
            .boolean => return if (expr.data.boolean) 1 else 0,
            .enum_literal => return self.enum_variants.get(expr.data.enum_literal) orelse 0,
            .identifier => {
                if (local_consts) |lc| {
                    if (lc.get(expr.data.identifier)) |v| return v;
                }
                return self.constants.get(expr.data.identifier) orelse self.enum_variants.get(expr.data.identifier) orelse 1;
            },
            .member_access => {
                const ma = expr.data.member_access;
                if (exprToDottedString(self.str_arena.allocator(), expr)) |dotted| {
                    if (self.constants.get(dotted)) |v| return v;
                    if (self.enum_variants.get(dotted)) |v| return v;
                }
                if (ma.target.tag == .identifier) {
                    if (self.constants.get(ma.field)) |v| return v;
                    if (self.enum_variants.get(ma.field)) |v| return v;
                }
                return 1;
            },
            .binary => {
                const l = self.evalConstEx(expr.data.binary.left, local_consts);
                const r = self.evalConstEx(expr.data.binary.right, local_consts);
                return switch (expr.data.binary.op) {
                    .plus, .plus_percent => l + r,
                    .minus, .minus_percent => if (l >= r) l - r else 0,
                    .asterisk, .asterisk_percent => l * r,
                    .shl => l << @intCast(r),
                    .shr => l >> @intCast(r),
                    else => 0,
                };
            },
            .unary => {
                const u = expr.data.unary;
                const op_val = self.evalConstEx(u.operand, local_consts);
                return switch (u.op) {
                    .tilde => ~op_val,
                    .bang => if (op_val == 0) 1 else 0,
                    .minus => (~op_val) +% 1,
                    .pipe => if (op_val != 0) 1 else 0,
                    .ampersand => if (op_val != 0 and (op_val & (op_val + 1)) == 0) 1 else 0,
                    .caret => @popCount(op_val) & 1,
                    else => op_val,
                };
            },
            .builtin_call => {
                const bc = expr.data.builtin_call;
                if (bc.tag == .builtin_as and bc.args.len >= 2) {
                    return self.evalConstEx(bc.args[1], local_consts);
                }
                if (bc.tag == .builtin_clog2 and bc.args.len > 0) {
                    const arg_val = self.evalConstEx(bc.args[0], local_consts);
                    if (arg_val <= 1) return 1;
                    return 64 - @clz(arg_val - 1);
                }
                if (bc.tag == .builtin_replicate and bc.args.len >= 2) {
                    const count = self.evalConstEx(bc.args[0], local_consts);
                    const val = self.evalConstEx(bc.args[1], local_consts);
                    var res: u64 = 0;
                    for (0..@intCast(count)) |_| {
                        res = (res << 1) | (val & 1);
                    }
                    return res;
                }
                if (bc.tag == .builtin_reduce_or and bc.args.len > 0) {
                    const val = self.evalConstEx(bc.args[0], local_consts);
                    return if (val != 0) 1 else 0;
                }
                if (bc.tag == .builtin_reduce_xor and bc.args.len > 0) {
                    const val = self.evalConstEx(bc.args[0], local_consts);
                    return @popCount(val) & 1;
                }
                return 0;
            },
            else => return 0,
        }
    }

    fn evalConst(self: *Elaborator, expr: *ast.Expr) u64 {
        return self.evalConstEx(expr, null);
    }

    fn getEnumVal(self: *Elaborator, name: []const u8) u64 {
        if (self.enum_variants.get(name)) |v| {
            return v;
        }
        return 0;
    }
};
