const std = @import("std");
const util = @import("./util.zig");
const hash = @import("./hash.zig");

const LoadError = error{
    HashTblNotFound,
    UnexpectedRelocEntSize,
    NotELF,
};

pub const Consts = struct {
    pub const DT_RELRSZ = 35;
    pub const DT_RELR = 36;
    pub const DT_RELRENT = 37;
};

fn elf_read(comptime T: type, fd: std.posix.fd_t, offset: u64) !T {
    var result: T = undefined;
    // TODO: if file is smaller than that?
    _ = try std.posix.pread(fd, @as([*]u8, @ptrCast(&result))[0..@sizeOf(T)], offset);
    return result;
}

fn opt_max(comptime T: type, cur: ?T, new: T) T {
    if (cur == null) return new;
    return @max(cur, new);
}

fn opt_min(comptime T: type, cur: ?T, new: T) T {
    if (cur == null) return new;
    return @min(cur, new);
}

const MapRange = struct {
    offset_aligned: usize,
    start_aligned: usize,
    end_aligned: usize,
    end_file_aligned: usize,
    zeroing: ?usize,
    prot: u32,

    fn from(phdr: std.elf.Elf64_Phdr, page_size: usize) MapRange {
        const start_aligned = phdr.p_vaddr & -%page_size;
        const end_aligned = (phdr.p_vaddr + phdr.p_memsz + page_size - 1) & -%page_size;
        const end_file_aligned = (phdr.p_vaddr + phdr.p_filesz + page_size - 1) & -%page_size;
        const start_diff = phdr.p_vaddr - start_aligned;

        var prot: u32 = 0;
        if (phdr.p_flags & std.elf.PF_R != 0) prot |= std.posix.PROT.READ;
        if (phdr.p_flags & std.elf.PF_W != 0) prot |= std.posix.PROT.WRITE;
        if (phdr.p_flags & std.elf.PF_X != 0) prot |= std.posix.PROT.EXEC;

        const zeroing: ?usize = if (phdr.p_flags & std.elf.PF_W != 0 and phdr.p_vaddr + phdr.p_filesz != end_file_aligned)
            phdr.p_filesz + start_diff
        else
            null;
        return MapRange{
            .offset_aligned = phdr.p_offset - start_diff,
            .start_aligned = start_aligned,
            .end_aligned = end_aligned,
            .end_file_aligned = end_file_aligned,
            .zeroing = zeroing,
            .prot = prot,
        };
    }

    fn apply(self: MapRange, base: ?[*]u8, fd: std.posix.fd_t, max_avoidance: usize) ![]u8 {
        try util.printNumHex(self.start_aligned);
        _ = try std.io.getStdOut().write(" -> ");
        try util.printNumHex(self.end_aligned);
        _ = try std.io.getStdOut().write("\n");

        const file_portion = if (base) |b|
            try std.posix.mmap(@alignCast(b + self.start_aligned), self.file_len(), self.prot, std.posix.MAP{ .TYPE = std.os.linux.MAP_TYPE.PRIVATE, .FIXED_NOREPLACE = true }, fd, self.offset_aligned)
        else blk: {
            const mapped = try std.posix.mmap(null, max_avoidance, self.prot, std.posix.MAP{ .TYPE = std.os.linux.MAP_TYPE.PRIVATE }, fd, self.offset_aligned);
            std.posix.munmap(@alignCast(mapped[self.file_len()..]));
            break :blk mapped[0..self.file_len()];
        };

        if (self.zero_len() != 0) {
            _ = try std.posix.mmap(@alignCast(file_portion.ptr + file_portion.len), self.zero_len(), self.prot, std.posix.MAP{ .TYPE = std.os.linux.MAP_TYPE.PRIVATE, .FIXED_NOREPLACE = true, .ANONYMOUS = true }, 0, 0);
        }

        if (self.zeroing) |z| {
            @memset(file_portion[z..], 0);
        }

        return file_portion.ptr[0..self.tot_len()];
    }

    fn file_len(self: MapRange) usize {
        return self.end_file_aligned - self.start_aligned;
    }
    fn zero_len(self: MapRange) usize {
        return self.end_aligned - self.end_file_aligned;
    }
    fn tot_len(self: MapRange) usize {
        return self.end_aligned - self.start_aligned;
    }
};

pub const LoadedElf = struct {
    base: [*]u8,
    phdrs: []std.elf.Elf64_Phdr,
    dyn: ?Dyn,
};

pub const JmpRel = union(enum) {
    rela: []std.elf.Elf64_Rela,
    rel: []std.elf.Elf64_Rel,
};

const INIT_FUNC = fn () callconv(.C) void;

pub const Dyn = struct {
    section: []std.elf.Elf64_Dyn,
    symtab: [*]std.elf.Elf64_Sym,
    strtab: [*]u8,

    rela: ?[]std.elf.Elf64_Rela,
    rel: ?[]std.elf.Elf64_Rel,
    relr: ?[]u64,
    jmprel: ?JmpRel,

    init: ?*INIT_FUNC,
    inits: []*INIT_FUNC,

    hash: hash.HashTbl,
    soname: ?[]u8,
};

fn path_has_slash(path: [*:0]const u8) bool {
    var cur = path;
    while (cur[0] != 0) : ({
        cur += 1;
    }) {
        if (cur[0] == '/') return true;
    }
    return false;
}

pub fn elf_load(path: [*:0]const u8, page_size: usize, search: ?[*:0]const u8) !LoadedElf {
    if ((search == null) or path_has_slash(path)) {
        // Loading application or library with absolute path
        _ = try std.io.getStdOut().write("Direct open: ");
        _ = try std.io.getStdOut().write(std.mem.span(path));
        _ = try std.io.getStdOut().write("\n");
        const fd: std.posix.fd_t = try std.posix.openZ(path, std.posix.O{}, 0);
        _ = try std.io.getStdOut().write("Open complete\n");
        return elf_load_fd(fd, page_size);
    } else {
        var sidx: usize = 0;
        // Loading relative-pathed library
        while (true) {
            // TODO: check for overflow
            var concat: [std.fs.MAX_PATH_BYTES - 1:0]u8 = undefined;
            var didx: usize = 0;
            while (search.?[sidx] != 0 and search.?[sidx] != ':') {
                concat[didx] = search.?[sidx];
                sidx += 1;
                didx += 1;
            }

            var pidx: usize = 0;
            concat[didx] = '/';
            didx += 1;
            while (path[pidx] != 0) {
                concat[didx] = path[pidx];
                didx += 1;
                pidx += 1;
            }
            concat[didx] = 0;
            _ = try std.io.getStdOut().write(concat[0..didx]);
            _ = try std.io.getStdOut().write("\n");
            const fd: std.posix.fd_t = std.posix.openZ(&concat, std.posix.O{}, 0) catch {
                if (search.?[sidx] == 0) {
                    return std.posix.OpenError.FileNotFound;
                } else {
                    sidx += 1;
                    continue;
                }
            };
            return elf_load_fd(fd, page_size) catch continue;
        }
    }
}

pub fn elf_load_fd(fd: std.posix.fd_t, page_size: usize) !LoadedElf {
    const ehdr = try elf_read(std.elf.Elf64_Ehdr, fd, 0);
    if (!std.mem.eql(u8, ehdr.e_ident[0..4], &([4]u8{ 0x7f, 'E', 'L', 'F' }))) return LoadError.NotELF;
    // TODO: detect ELF tag
    // TODO: detect ET_DYN

    // First PHDR loop:
    // - Stat required vaddr range
    // - Get PHDR vaddr offset
    var phdr_vaddr_offset: ?usize = null;
    var vaddr_min: ?usize = null;
    var vaddr_max: ?usize = null;
    var first_range: MapRange = undefined;

    // TODO: actually map phdr first, and use the mapped version
    var discovered_phdr: ?usize = null;

    for (0..ehdr.e_phnum) |i| {
        const phdr_offset = ehdr.e_phoff + i * ehdr.e_phentsize;
        const phdr: std.elf.Elf64_Phdr = try elf_read(std.elf.Elf64_Phdr, fd, phdr_offset);

        switch (phdr.p_type) {
            std.elf.PT_PHDR => {
                phdr_vaddr_offset = phdr.p_vaddr;
            },
            std.elf.PT_LOAD => {
                // PT_LOAD headers have to be ascending.
                // TODO: assert about that
                const vaddr = phdr.p_vaddr;
                if (vaddr_min == null) {
                    vaddr_min = vaddr;
                    first_range = MapRange.from(phdr, page_size);
                }
                vaddr_max = vaddr + phdr.p_memsz;

                if (ehdr.e_phoff >= phdr.p_offset and ehdr.e_phoff < phdr.p_offset + phdr.p_filesz) {
                    discovered_phdr = phdr.p_vaddr + (ehdr.e_phoff - phdr.p_offset);
                }
            },
            else => continue,
        }
    }

    const vaddr_min_aligned = vaddr_min.? & -%page_size;
    const vaddr_max_aligned = (vaddr_max.? + page_size - 1) & -%page_size;
    const tot_map_len = vaddr_max_aligned - vaddr_min_aligned;

    // const first_mapped_raw = try std.posix.mmap(null, map_len, first_range.prot, std.posix.MAP{ .TYPE = std.os.linux.MAP_TYPE.PRIVATE }, fd, first_range.offset_aligned);
    // std.posix.munmap(@alignCast(first_mapped_raw[first_range.len()..]));
    // const first_mapped = first_mapped_raw[0..first_range.len()];
    const first_mapped = try first_range.apply(null, fd, tot_map_len);

    const base = first_mapped.ptr - first_range.start_aligned;
    var first_load = true;

    // try util.printNumHex(@intFromPtr(base) + vaddr_min_aligned);
    // _ = try std.io.getStdOut().write("\n");
    // try util.printNumHex(@intFromPtr(base) + vaddr_max_aligned);
    // _ = try std.io.getStdOut().write("\n");

    for (0..ehdr.e_phnum) |i| {
        const phdr_offset = ehdr.e_phoff + i * ehdr.e_phentsize;
        const phdr: std.elf.Elf64_Phdr = try elf_read(std.elf.Elf64_Phdr, fd, phdr_offset);

        switch (phdr.p_type) {
            std.elf.PT_LOAD => {
                if (first_load) {
                    first_load = false;
                    continue;
                }

                const range = MapRange.from(phdr, page_size);
                _ = try range.apply(base, fd, tot_map_len);

                // try util.printNumHex(@intFromPtr(base) + range.start_aligned);
                // _ = try std.io.getStdOut().write("\n");
                // try util.printNumHex(@intFromPtr(base) + range.start_aligned + range.len());
                // _ = try std.io.getStdOut().write("\n");
            },
            // FIXME: BSS?
            else => continue,
        }
    }

    // TODO: If there is no PT_PHDR, find mapped phdr, or map it
    var mapped_phdrs = base;
    if (phdr_vaddr_offset != null) {
        mapped_phdrs += phdr_vaddr_offset.?;
    } else {
        mapped_phdrs += discovered_phdr.?;
    }

    const phdrs: []std.elf.Elf64_Phdr = @as([*]std.elf.Elf64_Phdr, @alignCast(@ptrCast(mapped_phdrs)))[0..ehdr.e_phnum];
    const dyn = try elf_find_dyn(phdrs, base);
    return LoadedElf{
        .base = base,
        .phdrs = phdrs,
        .dyn = dyn,
    };
}

pub fn elf_load_mapped(base: [*]u8) !LoadedElf {
    const ehdr: *std.elf.Elf64_Ehdr = @alignCast(@ptrCast(base));
    // This is actually not always correct. But it's the best we can do. Let's hope whoever loaded the image have fixed e_phoff
    const phdr_base = base + ehdr.e_phoff;
    const phdrs: []std.elf.Elf64_Phdr = @as([*]std.elf.Elf64_Phdr, @alignCast(@ptrCast(phdr_base)))[0..ehdr.e_phnum];
    const dyn = try elf_find_dyn(phdrs, base);
    return LoadedElf{
        .base = base,
        .phdrs = phdrs,
        .dyn = dyn,
    };
}

pub fn elf_parse_dyn(dyn_section: []std.elf.Elf64_Dyn, base: [*]u8) !Dyn {
    var dyn_strtab: [*]u8 = undefined;
    var dyn_symtab: [*]std.elf.Elf64_Sym = undefined;
    var dyn_hash: ?hash.HashTbl = null;
    var dyn_gnu_hash: ?hash.HashTbl = null;
    var dyn_soname: ?u64 = null;

    var dyn_rela: ?[*]std.elf.Elf64_Rela = null;
    var dyn_relalen: usize = 0;
    var dyn_rel: ?[*]std.elf.Elf64_Rel = null;
    var dyn_rellen: usize = 0;
    var dyn_relr: ?[*]u64 = null;
    var dyn_relrlen: usize = 0;
    var dyn_jmprel: ?[*]u64 = null;
    var dyn_jmprelsz: usize = 0;
    var dyn_pltrel: u64 = 0;

    var dyn_init: ?*INIT_FUNC = null;
    var dyn_inits: ?[*]*INIT_FUNC = null;
    var dyn_initlen: usize = 0;
    // var dyn_syment: usize = undefined;
    // TODO: implement GNU Hash
    for (dyn_section) |dyn| {
        switch (dyn.d_tag) {
            std.elf.DT_STRTAB => dyn_strtab = @alignCast(@ptrCast(base + dyn.d_val)),
            std.elf.DT_SYMTAB => dyn_symtab = @alignCast(@ptrCast(base + dyn.d_val)),
            std.elf.DT_HASH => {
                _ = try std.io.getStdOut().write("Found DT_HASH\n");
                dyn_hash = hash.HashTbl{
                    .vanilla = hash.VanillaHashTbl.parse(@alignCast(@ptrCast(base + dyn.d_val))),
                };
            },
            std.elf.DT_GNU_HASH => {
                _ = try std.io.getStdOut().write("Found DT_GNU_HASH\n");
                dyn_gnu_hash = hash.HashTbl{
                    .gnu = hash.GNUHashTbl.parse(@alignCast(@ptrCast(base + dyn.d_val))),
                };
            },
            std.elf.DT_RELA => dyn_rela = @alignCast(@ptrCast(base + dyn.d_val)),
            std.elf.DT_RELAENT => if (dyn.d_val != @sizeOf(std.elf.Elf64_Rela)) {
                try util.printNumHex(dyn.d_val);
                try util.printNumHex(@sizeOf(std.elf.Elf64_Rela));
                return LoadError.UnexpectedRelocEntSize;
            },
            std.elf.DT_RELASZ => dyn_relalen = dyn.d_val / @sizeOf(std.elf.Elf64_Rela),
            std.elf.DT_REL => dyn_rel = @alignCast(@ptrCast(base + dyn.d_val)),
            std.elf.DT_RELENT => if (dyn.d_val != @sizeOf(std.elf.Elf64_Rel)) {
                return LoadError.UnexpectedRelocEntSize;
            },
            std.elf.DT_RELSZ => dyn_rellen = dyn.d_val / @sizeOf(std.elf.Elf64_Rel),
            Consts.DT_RELR => dyn_relr = @alignCast(@ptrCast(base + dyn.d_val)),
            Consts.DT_RELRENT => if (dyn.d_val != @sizeOf(u64)) {
                return LoadError.UnexpectedRelocEntSize;
            },
            Consts.DT_RELRSZ => dyn_relrlen = dyn.d_val / @sizeOf(u64),
            std.elf.DT_JMPREL => dyn_jmprel = @alignCast(@ptrCast(base + dyn.d_val)),
            std.elf.DT_PLTREL => dyn_pltrel = dyn.d_val,
            std.elf.DT_PLTRELSZ => dyn_jmprelsz = dyn.d_val,

            std.elf.DT_SONAME => dyn_soname = dyn.d_val,

            std.elf.DT_INIT => {
                dyn_init = @ptrCast(base + dyn.d_val);
            },
            std.elf.DT_INIT_ARRAY => {
                dyn_inits = @alignCast(@ptrCast(base + dyn.d_val));
            },
            std.elf.DT_INIT_ARRAYSZ => {
                dyn_initlen = dyn.d_val / @sizeOf(*INIT_FUNC);
            },
            // std.elf.DT_SYMENT => dyn_syment = dyn.d_val,
            else => continue,
        }
    }

    if (dyn_hash == null and dyn_gnu_hash == null) {
        return LoadError.HashTblNotFound;
    }

    const soname: ?[]u8 = if (dyn_soname) |idx| blk: {
        const soname = std.mem.span(@as([*:0]u8, @ptrCast(dyn_strtab + idx)));
        _ = try std.io.getStdOut().write("DT_SONAME: ");
        _ = try std.io.getStdOut().write(soname);
        _ = try std.io.getStdOut().write("\n");
        break :blk soname;
    } else null;

    const hashtbl: hash.HashTbl = (dyn_gnu_hash orelse dyn_hash).?;
    const symcnt = hashtbl.symcnt();

    var jmprel: ?JmpRel = null;
    if (dyn_jmprel) |j| {
        switch (dyn_pltrel) {
            std.elf.DT_REL => jmprel = JmpRel{
                .rel = @as([*]std.elf.Elf64_Rel, @alignCast(@ptrCast(j)))[0 .. dyn_jmprelsz / @sizeOf(std.elf.Elf64_Rel)],
            },
            std.elf.DT_RELA => jmprel = JmpRel{
                .rela = @as([*]std.elf.Elf64_Rela, @alignCast(@ptrCast(j)))[0 .. dyn_jmprelsz / @sizeOf(std.elf.Elf64_Rela)],
            },
            else => {},
        }
    }

    const symtab = dyn_symtab[0..symcnt];
    _ = try std.io.getStdOut().write("Symbol count: ");
    try util.printNum(symcnt);
    _ = try std.io.getStdOut().write("\n");

    for (symtab) |sym| {
        const bind = sym.st_bind();
        if (bind == std.elf.STB_LOCAL) _ = try std.io.getStdOut().write("L ");
        if (bind == std.elf.STB_GLOBAL) _ = try std.io.getStdOut().write("G ");
        if (bind == std.elf.STB_WEAK) _ = try std.io.getStdOut().write("W ");
        if (sym.st_name == 0) {
            _ = try std.io.getStdOut().write("[NONAME]\n");
        } else {
            const name: [*:0]u8 = @ptrCast(dyn_strtab + sym.st_name);
            _ = try std.io.getStdOut().write(std.mem.sliceTo(name, 0));
            _ = try std.io.getStdOut().write("\n");
        }
    }

    return Dyn{
        .section = dyn_section,
        .hash = hashtbl,
        .symtab = dyn_symtab,
        .strtab = dyn_strtab,
        .rela = if (dyn_rela) |d| d[0..dyn_relalen] else null,
        .rel = if (dyn_rel) |d| d[0..dyn_rellen] else null,
        .relr = if (dyn_relr) |d| d[0..dyn_relrlen] else null,
        .jmprel = jmprel,
        .soname = soname,

        .init = dyn_init,
        .inits = if (dyn_inits) |i| i[0..dyn_initlen] else &.{},
    };
}

pub fn elf_find_dyn(phdrs: []std.elf.Elf64_Phdr, base: [*]u8) !?Dyn {
    // Parse dynamic header
    for (phdrs) |phdr| {
        if (phdr.p_type == std.elf.PT_DYNAMIC) {
            const dyn_section_ptr: [*]std.elf.Elf64_Dyn = @alignCast(@ptrCast(base + phdr.p_vaddr));
            const dyn_section_len = phdr.p_memsz;
            const dyn_section = dyn_section_ptr[0..(dyn_section_len / @sizeOf(std.elf.Elf64_Dyn))];
            return try elf_parse_dyn(dyn_section, base);
        }
    }
    return null;
}
