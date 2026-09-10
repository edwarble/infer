const std = @import("std");
const pcre2_lib = @import("pcre2.zig");

pub fn tokenizerSplitRegex(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    text: []const u8,
) ![][]const u8 {
    var err: c_int = 0;
    var offset: usize = 0;
    const re = pcre2_lib.pcre2_compile_8(pattern.ptr, pattern.len, pcre2_lib.PCRE2_UTF | pcre2_lib.PCRE2_UCP, &err, &offset, null,) orelse return error.InvalidValue;
    defer pcre2_lib.pcre2_code_free_8(re);

    const match = pcre2_lib.pcre2_match_data_create_from_pattern_8(re, null) orelse return error.OutOfMemory;
    defer pcre2_lib.pcre2_match_data_free_8(match);

    var pieces: std.ArrayList([]const u8) = .empty;
    errdefer pieces.deinit(allocator);

    var pos: usize = 0;
    while (pos < text.len) {
        const rc = pcre2_lib.pcre2_match_8(re, text.ptr, text.len, pos, 0, match, null,);
        if (rc == pcre2_lib.PCRE2_ERROR_NOMATCH) return error.InvalidValue;
        if (rc < 0) return error.InvalidValue;

        const b = pcre2_lib.pcre2_get_ovector_pointer_8(match);
        if (b[0] == b[1]) return error.InvalidValue;

        try pieces.append(allocator, text[b[0]..b[1]]);
        pos = b[1];
    }

    return try pieces.toOwnedSlice(allocator);
}

fn unicodeToByte(lv: u32) !u8 {
    // byte swapping follows GPT-2, cf. https://github.com/openai/gpt-2/blob/master/src/encoder.py
    // @lru_cache()
    // def bytes_to_unicode():
    //     """
    //     Returns list of utf-8 byte and a corresponding list of unicode strings.
    //     The reversible bpe codes work on unicode strings.
    //     This means you need a large # of unicode characters in your vocab if you want to avoid UNKs.
    //     When you're at something like a 10B token dataset you end up needing around 5K for decent coverage.
    //     This is a signficant percentage of your normal, say, 32K bpe vocab.
    //     To avoid that, we want lookup tables between utf-8 bytes and unicode strings.
    //     And avoids mapping to whitespace/control characters the bpe code barfs on.
    //     """
    //     bs = list(range(ord("!"), ord("~")+1))+list(range(ord("¡"), ord("¬")+1))+list(range(ord("®"), ord("ÿ")+1))
    //     cs = bs[:]
    //     n = 0
    //     for b in range(2**8):
    //         if b not in bs:
    //             bs.append(b)
    //             cs.append(2**8+n)
    //             n += 1
    //     cs = [chr(n) for n in cs]
    //     return dict(zip(bs, cs))
    const Lookup = struct {
        bs: [256]u32, // bytes
        cs: [256]u32, // codepoints
    };
    const lookup: Lookup = comptime blk: {
        @setEvalBranchQuota(256*256);
        var bs: [256]u32 = undefined;
        var offset: u32 = 0;
        for (33..127) |i| { bs[i-33+offset] = @intCast(i); } // list(range(ord("!"), ord("~")+1))
        offset += 127 - 33;
        for (161..173) |i| { bs[i-161+offset] = @intCast(i); } // list(range(ord("¡"), ord("¬")+1))
        offset += 173 - 161;
        for (174..256) |i| { bs[i-174+offset] = @intCast(i); } // list(range(ord("®"), ord("ÿ")+1))
        offset += 256 - 174;

        var cs = bs;
        var b: u32 = 0;
        var n: u32 = 0;
        while (b < 256) : (b += 1) {
            if (std.mem.indexOfScalar(u32, bs[0..offset], b) == null) {
                bs[offset] = b;
                cs[offset] = 256 + n;
                offset += 1;
                n += 1;
            }
        }

        break :blk .{ .bs = bs, .cs = cs };
    };
    const idx = std.mem.indexOfScalar(u32, &lookup.cs, lv) orelse return error.InvalidValue;
    return @intCast(lookup.bs[idx]);
}

pub fn bbpeSwap(allocator: std.mem.Allocator, token: []const u8) ![]u8 {
    var codepoint_iterator = (try std.unicode.Utf8View.init(token)).iterator();
    var bytes: std.ArrayList(u8) = .empty;
    while (codepoint_iterator.nextCodepoint()) |cp| {
        try bytes.append(allocator, @intCast(try unicodeToByte(cp)));
    }

    return bytes.toOwnedSlice(allocator);
}
