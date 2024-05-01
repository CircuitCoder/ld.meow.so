const std = @import("std");
const load = @import("./load.zig");

pub const VanillaHashTbl = struct {
    nbucket: u32,
    nchain: u32,
    buckets: []u32,
    chains: []u32,

    pub fn parse(base: [*]u32) VanillaHashTbl {
        const nbucket = base[0];
        const nchain = base[1];

        return VanillaHashTbl{
            .nbucket = nbucket,
            .nchain = nchain,
            .buckets = base[2 .. 2 + nbucket],
            .chains = base[2 + nbucket .. 2 + nbucket + nchain],
        };
    }

    pub fn lookup(self: VanillaHashTbl, name: []u8, dyn: load.Dyn) ?usize {
        const hash = vanilla_hash(name);
        var symidx = hash % self.nbucket;

        while (symidx != 0) : ({
            symidx = self.chains[symidx];
        }) {
            const sym = dyn.symtab[symidx];
            const symname = std.mem.span(@as([*:0]u8, @ptrCast(dyn.strtab + sym.st_name)));
            if (std.mem.eql(u8, symname, name)) return symidx;
        }
        return null;
    }
};

pub const GNUHashTbl = struct {
    nbuckets: u32,
    symoffset: u32,
    bloom_size: u32,
    bloom_shift: u32,
    bloom: []u64,
    buckets: []u32,
    chain: [*]u32,

    pub fn parse(base: [*]u32) GNUHashTbl {
        return GNUHashTbl{
            .nbuckets = base[0],
            .symoffset = base[1],
            .bloom_size = base[2],
            .bloom_shift = base[3],
            .bloom = @as([*]u64, @alignCast(@ptrCast(base)))[2 .. 2 + base[2]],
            .buckets = base[4 + base[2] * 2 .. 4 + base[2] * 2 + base[0]],
            .chain = base + (4 + base[2] * 2 + base[0]),
        };
    }

    pub fn lookup(self: GNUHashTbl, name: []u8, dyn: load.Dyn) ?usize {
        const hash = gnu_hash(name);
        // Lookup bloom filter
        const bloom_bucket = (hash / 64) % self.bloom_size;
        const bloom_filter = self.bloom[bloom_bucket];
        const bloom_idx1 = hash % 64;
        const bloom_idx2 = (hash >> @intCast(self.bloom_shift)) % 64;

        if (((bloom_filter >> @intCast(bloom_idx1)) & 1 == 0) or ((bloom_filter >> @intCast(bloom_idx2)) & 1 == 0)) {
            return null;
        }

        var symidx = self.buckets[hash % self.nbuckets];
        if (symidx == 0) return null;

        while (true) : ({
            symidx += 1;
        }) {
            const chain_content = self.chain[symidx - self.symoffset];
            if (chain_content | 1 == hash | 1) {
                // Hash checks out, real lookup
                const sym = dyn.symtab[symidx];
                const symname = std.mem.span(@as([*:0]u8, @ptrCast(dyn.strtab + sym.st_name)));
                if (std.mem.eql(u8, symname, name)) return symidx;
            }

            if (chain_content & 1 == 1) {
                break;
            }
        }

        return null;
    }
};

pub const HashTbl = union(enum) {
    vanilla: VanillaHashTbl,
    gnu: GNUHashTbl,

    pub fn symcnt(self: HashTbl) u32 {
        switch (self) {
            .gnu => |t| {
                // TODO: Maybe use section length?
                var max_sym: u32 = 0;
                for (t.buckets) |b| max_sym = @max(max_sym, b);

                if (max_sym == 0) return 0;

                while (t.chain[max_sym - t.symoffset] & 1 == 0) {
                    max_sym += 1;
                }
                return max_sym + 1;
            },
            .vanilla => |t| return t.nchain,
        }
    }

    pub fn lookup(self: HashTbl, name: []u8, dyn: load.Dyn) ?usize {
        switch (self) {
            .vanilla => |t| return t.lookup(name, dyn),
            .gnu => |t| return t.lookup(name, dyn),
        }
    }
};

fn vanilla_hash(sym_name: []const u8) u32 {
    var h: u32 = 0;
    for (sym_name) |t| {
        h = (h << 4) +% t;
        const top_slice = h & 0xF0000000;
        h ^= (top_slice >> 24) & 0xF0;
    }
    return h & 0x0FFFFFFF;
}

// DJB2
fn gnu_hash(sym_name: []const u8) u32 {
    var h: u32 = 5381;
    for (sym_name) |t| {
        h = h *% 33 + t;
    }
    return h;
}

test "Common GNU hash values" {
    // From https://flapenguin.me/elf-dt-gnu-hash
    try std.testing.expectEqual(gnu_hash(""), 0x00001505);
    try std.testing.expectEqual(gnu_hash("printf"), 0x156b2bb8);
    try std.testing.expectEqual(gnu_hash("exit"), 0x7c967e3f);
    try std.testing.expectEqual(gnu_hash("syscall"), 0xbac212a0);
}
