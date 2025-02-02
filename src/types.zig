const std = @import("std");
const stdx = @import("stdx");
const t = stdx.testing;
const cy = @import("cyber.zig");
const cc = @import("capi.zig");
const rt = cy.rt;
const sema = cy.sema;
const fmt = @import("fmt.zig");
const v = fmt.v;
const vmc = @import("vm_c.zig");
const log = cy.log.scoped(.types);

pub const TypeId = u32;

pub const TypeKind = enum(u8) {
    null,
    bool,
    int,
    float,
    object,
    custom_object,
    @"enum",
    choice,
    @"struct",
    option,
};

pub const Type = extern struct {
    sym: *cy.Sym,
    kind: TypeKind,
    // Duped to avoid lookup from `sym`.
    // symType: cy.sym.SymType,
    data: extern union {
        // This is duped from ObjectType so that object creation/destruction avoids the lookup from `sym`.
        object: extern struct {
            numFields: u16,
        },
        // Even though this increases the size of other type entries, it might not be worth
        // separating into another table since it would add another indirection.
        custom_object: extern struct {
            getChildrenFn: cc.ObjectGetChildrenFn,
            finalizerFn: cc.ObjectFinalizerFn,
        },
        @"struct": extern struct {
            numFields: u16,
        },
    },
};

test "types internals." {
    try t.eq(@sizeOf(Type), @sizeOf(vmc.TypeEntry));
    try t.eq(@offsetOf(Type, "sym"), @offsetOf(vmc.TypeEntry, "sym"));
    try t.eq(@offsetOf(Type, "kind"), @offsetOf(vmc.TypeEntry, "kind"));
}

pub const CompactType = packed struct {
    /// Should always be a static typeId.
    id: u31,
    dynamic: bool,

    pub fn init(id: TypeId) CompactType {
        if (id == bt.Dynamic) {
            return CompactType.initDynamic(bt.Any);
        } else {
            return CompactType.initStatic(id);
        }
    }

    pub fn init2(id: TypeId, dynamic: bool) CompactType {
        return .{
            .id = @intCast(id),
            .dynamic = dynamic,
        };
    }

    pub fn initStatic(id: TypeId) CompactType {
        return .{ .id = @intCast(id), .dynamic = false };
    }

    pub fn initDynamic(id: TypeId) CompactType {
        return .{ .id = @intCast(id), .dynamic = true };
    }

    pub fn toDeclType(self: CompactType) TypeId {
        if (self.dynamic) {
            return bt.Dynamic;
        } else {
            return self.id;
        }
    }

    pub fn toStaticDeclType(self: CompactType) TypeId {
        if (self.dynamic) {
            return bt.Any;
        } else {
            return self.id;
        }
    }
};

pub const PrimitiveEnd: TypeId = vmc.PrimitiveEnd;
pub const BuiltinEnd: TypeId = vmc.BuiltinEnd;

const bt = BuiltinTypes;
pub const BuiltinTypes = struct {
    pub const Any: TypeId = vmc.TYPE_ANY;
    pub const Boolean: TypeId = vmc.TYPE_BOOLEAN;
    pub const Placeholder1: TypeId = vmc.TYPE_PLACEHOLDER1;
    pub const Placeholder2: TypeId = vmc.TYPE_PLACEHOLDER2;
    pub const Placeholder3: TypeId = vmc.TYPE_PLACEHOLDER3;
    pub const Float: TypeId = vmc.TYPE_FLOAT;
    pub const Integer: TypeId = vmc.TYPE_INTEGER;
    pub const String: TypeId = vmc.TYPE_STRING;
    pub const Array: TypeId = vmc.TYPE_ARRAY;
    pub const Symbol: TypeId = vmc.TYPE_SYMBOL;
    pub const Tuple: TypeId = vmc.TYPE_TUPLE;
    pub const List: TypeId = vmc.TYPE_LIST;
    pub const ListIter: TypeId = vmc.TYPE_LIST_ITER;
    pub const Map: TypeId = vmc.TYPE_MAP;
    pub const MapIter: TypeId = vmc.TYPE_MAP_ITER;
    pub const Pointer: TypeId = vmc.TYPE_POINTER;
    pub const Void: TypeId = vmc.TYPE_VOID;
    pub const Error: TypeId = vmc.TYPE_ERROR;
    pub const Fiber: TypeId = vmc.TYPE_FIBER;
    pub const MetaType: TypeId = vmc.TYPE_METATYPE;
    pub const Type: TypeId = vmc.TYPE_TYPE;
    pub const Closure: TypeId = vmc.TYPE_CLOSURE;
    pub const Lambda: TypeId = vmc.TYPE_LAMBDA;
    pub const Box: TypeId = vmc.TYPE_BOX;
    pub const HostFunc: TypeId = vmc.TYPE_HOST_FUNC;
    pub const TccState: TypeId = vmc.TYPE_TCC_STATE;
    pub const ExternFunc: TypeId = vmc.TYPE_EXTERN_FUNC;
    pub const Range: TypeId = vmc.TYPE_RANGE;

    /// Used to indicate no type value.
    // pub const Undefined: TypeId = vmc.TYPE_UNDEFINED;

    /// A dynamic type does not have a static type.
    /// This is not the same as bt.Any which is a static type.
    pub const Dynamic: TypeId = vmc.TYPE_DYNAMIC;
};

pub const SemaExt = struct {

    pub fn pushType(s: *cy.Sema) !TypeId {
        const typeId = s.types.items.len;
        try s.types.append(s.alloc, .{
            .sym = undefined,
            .kind = .null,
            .data = undefined,
        });
        return @intCast(typeId);
    }

    pub fn getTypeKind(s: *cy.Sema, id: TypeId) TypeKind {
        return s.types.items[id].kind;
    }

    pub fn getTypeBaseName(s: *cy.Sema, id: TypeId) []const u8 {
        return s.types.items[id].sym.name();
    }

    pub fn allocTypeName(s: *cy.Sema, id: TypeId) ![]const u8 {
        const type_e = s.types.items[id];
        switch (type_e.kind) {
            .option => {
                const template = type_e.sym.parent.?.cast(.typeTemplate);
                const variant = template.variants.items[type_e.sym.cast(.enum_t).variantId];
                const param = variant.params[0].asHeapObject();
                const name = s.getTypeBaseName(param.type.type);
                return try std.fmt.allocPrint(s.alloc, "?{s}", .{name});
            },
            .choice => {
                return try s.alloc.dupe(u8, type_e.sym.name());
            },
            else => {
                return try s.alloc.dupe(u8, type_e.sym.name());
            }
        }
    }

    pub fn writeTypeName(s: *cy.Sema, w: anytype, id: TypeId) !void {
        const typ = s.types.items[id];
        try w.writeAll(typ.sym.name());
    }

    pub fn writeCompactType(s: *cy.Sema, w: anytype, ctype: CompactType, comptime showRecentType: bool) !void {
        if (showRecentType) {
            if (ctype.dynamic) {
                try w.writeAll("dyn ");
            }
            try s.writeTypeName(w, ctype.id);
        } else {
            if (ctype.dynamic) {
                try w.writeAll("dynamic");
            } else {
                try s.writeTypeName(w, ctype.id);
            }
        }
    }

    pub fn getTypeSym(s: *cy.Sema, id: TypeId) *cy.Sym {
        if (cy.Trace) {
            if (s.types.items[id].kind == .null) {
                cy.panicFmt("Type `{}` is uninited.", .{ id });
            }
        }
        return s.types.items[id].sym;
    }

    pub fn isUserObjectType(s: *cy.Sema, id: TypeId) bool {
        if (id < BuiltinEnd) {
            return false;
        }
        return s.types.items[id].kind == .object;
    }

    pub fn isStructType(s: *cy.Sema, id: TypeId) bool {
        if (id < BuiltinEnd) {
            return false;
        }
        return s.types.items[id].kind == .@"struct";
    }

    pub fn isEnumType(s: *cy.Sema, typeId: TypeId) bool {
        if (typeId < PrimitiveEnd) {
            return false;
        }
        return s.types.items[typeId].kind == .@"enum";
    }

    pub fn isRcCandidateType(s: *cy.Sema, id: TypeId) bool {
        switch (id) {
            bt.String,
            bt.Array,
            bt.List,
            bt.ListIter,
            bt.Map,
            bt.MapIter,
            bt.Pointer,
            bt.Fiber,
            bt.MetaType,
            bt.Dynamic,
            bt.ExternFunc,
            bt.Any => return true,
            bt.Integer,
            bt.Float,
            bt.Symbol,
            bt.Void,
            bt.Error,
            // bt.Undefined,
            bt.Boolean => return false,
            else => {
                const sym = s.getTypeSym(id);
                switch (sym.type) {
                    .custom_object_t,
                    .struct_t,
                    .object_t => return true,
                    .enum_t => {
                        return sym.cast(.enum_t).isChoiceType;
                    },
                    else => {
                        cy.panicFmt("Unexpected sym type: {} {}", .{id, sym.type});
                    }
                }
            }
        }
    }
};

pub const ChunkExt = struct {

    pub fn checkForZeroInit(c: *cy.Chunk, typeId: TypeId, nodeId: cy.NodeId) !void {
        var res = hasZeroInit(c, typeId);
        if (res == .missingEntry) {
            const sym = c.sema.getTypeSym(typeId);
            if (sym.type == .object_t) {
                res = try visitTypeHasZeroInit(c, sym.cast(.object_t));
            } else if (sym.type == .struct_t) {
                res = try visitTypeHasZeroInit(c, sym.cast(.struct_t));
            } else return error.Unexpected;
        }
        switch (res) {
            .hasZeroInit => return,
            .missingEntry => return error.Unexpected,
            .unsupported => {
                const name = c.sema.getTypeBaseName(typeId);
                return c.reportErrorFmt("Unsupported zero initializer for `{}`.", &.{v(name)}, nodeId);
            },
            .circularDep => {
                const name = c.sema.getTypeBaseName(typeId);
                return c.reportErrorFmt("Can not zero initialize `{}` because of circular dependency.", &.{v(name)}, nodeId);
            }
        }
    }
};

pub fn isAnyOrDynamic(id: TypeId) bool {
    return id == bt.Any or id == bt.Dynamic;
}

/// Check type constraints on target func signature.
pub fn isTypeFuncSigCompat(c: *cy.Compiler, args: []const CompactType, ret_cstr: ReturnCstr, targetId: sema.FuncSigId) bool {
    const target = c.sema.getFuncSig(targetId);
    if (cy.Trace) {
        const sigStr = c.sema.formatFuncSig(targetId, &cy.tempBuf) catch cy.fatal();
        log.tracev("matching against: {s}", .{sigStr});
    }

    // First check params length.
    if (args.len != target.paramLen) {
        return false;
    }

    // Check each param type. Attempt to satisfy constraints.
    for (target.params(), args) |cstrType, argType| {
        if (isTypeSymCompat(c, argType.id, cstrType)) {
            continue;
        }
        if (argType.dynamic) {
            if (isTypeSymCompat(c, cstrType, argType.id)) {
                // Only defer to runtime type check if arg type is a parent type of cstrType.
                continue;
            }
        }
        log.tracev("`{s}` not compatible with param `{s}`", .{c.sema.getTypeBaseName(argType.id), c.sema.getTypeBaseName(cstrType)});
        return false;
    }

    // Check return type. Target is the source return type.
    return isValidReturnType(c, target.ret, ret_cstr);
}

pub const ReturnCstr = enum(u8) {
    any,       // exprStmt.
    not_void,  // expr.
};

pub fn isValidReturnType(_: *cy.Compiler, type_id: TypeId, cstr: ReturnCstr) bool {
    switch (cstr) {
        .any => {
            return true;
        },
        .not_void => {
            return type_id != bt.Void;
        },
    }
}

pub fn isTypeSymCompat(_: *cy.Compiler, typeId: TypeId, cstrType: TypeId) bool {
    if (typeId == cstrType) {
        return true;
    }
    if (cstrType == bt.Any or cstrType == bt.Dynamic) {
        return true;
    }
    return false;
}

/// Check type constraints on target func signature.
pub fn isFuncSigCompat(c: *cy.Compiler, id: sema.FuncSigId, targetId: sema.FuncSigId) bool {
    const src = c.sema.getFuncSig(id);
    const target = c.sema.getFuncSig(targetId);

    // First check params length.
    if (src.paramLen != target.paramLen) {
        return false;
    }

    // Check each param type. Attempt to satisfy constraints.
    for (target.params(), src.params()) |cstsymId, typeSymId| {
        if (!isTypeSymCompat(c, typeSymId, cstsymId)) {
            return false;
        }
    }

    // Check return type. Source return type is the constraint.
    return isTypeSymCompat(c, target.retSymId, src.retSymId);
}

pub fn toRtConcreteType(typeId: TypeId) ?cy.TypeId {
    return switch (typeId) {
        bt.Dynamic,
        bt.Any => null,
        else => return typeId,
    };
}

pub fn typeEqualOrChildOf(a: TypeId, b: TypeId) bool {
    if (b == bt.Any) {
        return true;
    }
    if (a == b) {
        return true;
    }
    // TODO: Check if a is a child type of b.
    return false;
}

pub fn isSameType(t1: TypeId, t2: TypeId) bool {
    return t1 == t2;
}

pub fn unionOf(c: *cy.Compiler, a: TypeId, b: TypeId) TypeId {
    _ = c;
    if (a == b) {
        return a;
    } else {
        if (a == bt.Dynamic or b == bt.Dynamic) {
            return bt.Dynamic;
        } else {
            return bt.Any;
        }
    }
}

const ZeroInitResult = enum {
    hasZeroInit,
    missingEntry,
    unsupported,
    circularDep,
};

fn hasZeroInit(c: *cy.Chunk, typeId: TypeId) ZeroInitResult {
    switch (typeId) {
        bt.Dynamic,
        bt.Any,
        bt.Boolean,
        bt.Integer,
        bt.Float,
        bt.List,
        bt.Map,
        bt.Array,
        bt.String => return .hasZeroInit,
        else => {
            const sym = c.sema.getTypeSym(typeId);
            if (sym.type == .object_t or sym.type == .struct_t) {
                if (c.typeDepsMap.get(sym)) |entryId| {
                    if (!c.typeDeps.items[entryId].visited) {
                        // Still being visited, which indicates a circular reference.
                        return .circularDep;
                    }
                    if (c.typeDeps.items[entryId].hasCircularDep) {
                        return .circularDep;
                    }
                    if (c.typeDeps.items[entryId].hasUnsupported) {
                        return .unsupported;
                    }
                    return .hasZeroInit;
                } else {
                    return .missingEntry;
                }
            }
            return .unsupported;
        },
    }
}

fn visitTypeHasZeroInit(c: *cy.Chunk, obj: *cy.sym.ObjectType) !ZeroInitResult {
    const entryId = c.typeDeps.items.len;
    try c.typeDeps.append(c.alloc, .{ .visited = false, .hasCircularDep = false, .hasUnsupported = false });
    try c.typeDepsMap.put(c.alloc, @ptrCast(obj), @intCast(entryId));

    var finalRes = ZeroInitResult.hasZeroInit;
    for (obj.fields[0..obj.numFields]) |field| {
        var res = hasZeroInit(c, field.type);
        if (res == .missingEntry) {
            const childSym = c.sema.getTypeSym(field.type).cast(.object_t);
            res = try visitTypeHasZeroInit(c, childSym);
        }
        switch (res) {
            .hasZeroInit => continue,
            .missingEntry => cy.unexpected(),
            .unsupported => {
                if (finalRes == .hasZeroInit) {
                    finalRes = .unsupported;
                }
            },
            .circularDep => {
                if (finalRes == .hasZeroInit) {
                    finalRes = .circularDep;
                }
            },
        }
    }

    if (finalRes == .circularDep) {
        c.typeDeps.items[entryId].hasCircularDep = true;
    } else if (finalRes == .unsupported) {
        c.typeDeps.items[entryId].hasUnsupported = true;
    }
    c.typeDeps.items[entryId].visited = true;
    return finalRes;
}