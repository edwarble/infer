const std = @import("std");
const infer = @import("infer");

const PreTokenizer = struct {
    pre_tokenizer: struct {
        type: []const u8,
        pretokenizers: []const Step,
    },

    pub const Step = struct {
        type: []const u8,
        pattern: ?struct {
            Regex: []const u8,
        } = null,
        behavior: ?[]const u8 = null,
        invert: ?bool = null,
        add_prefix_space: ?bool = null,
        trim_offsets: ?bool = null,
        use_regex: ?bool = null,
    };
};
const AddedTokens = struct { // <|special_token|> lookup
    added_tokens: []const SpecialToken,

    pub const SpecialToken = struct {
        id: u32,
        content: []const u8,
        single_word: ?bool = null,
        lstrip: ?bool = null,
        rstrip: ?bool = null,
        normalized: ?bool = null,
        special: ?bool = null,
    };
};
const TokenizerMerges = struct {
    model: struct {
        merges: []const []const u8,
    },
};
const TokenizerVocab = struct {
    model: struct {
        ignore_merges: ?bool = null,
        vocab: std.json.ArrayHashMap(u32),
    },
};

pub fn loadJson(
    comptime T: ?type,
    io: std.Io,
    cwd: std.Io.Dir,
    arena: std.mem.Allocator,
    path: []const u8,
    options: ?std.json.ParseOptions,
) !(T orelse std.json.Value) {
    const file = try cwd.openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);

    var read_buffer: [1024]u8 = undefined;
    var fr = file.reader(io, &read_buffer);
    const reader = &fr.interface;

    const stat = try file.stat(io);
    const fsize = stat.size;
    const buf = try arena.alloc(u8, fsize);

    _ = try reader.readSliceAll(buf);

    if (!std.unicode.utf8ValidateSlice(buf)) return error.InvalidUtf8;

    const parsed_json = try std.json.parseFromSliceLeaky(
        T orelse std.json.Value,
        arena,
        buf,
        options orelse .{},
    );

    return parsed_json;
}

pub fn main(init: std.process.Init) !void {
    // .safetensors format
    // 8 bytes: N, an unsigned little-endian 64-bit integer, containing the size of the header
    // | N bytes: a JSON UTF-8 string header
    // | * bytes: contiguous tensor data with offsets in JSON header
    // The JSON header looks like:
    // {
    //     "model.embed_tokens.weight": {
    //         "dtype": "F32",
    //         "shape": [49152, 576],
    //         "data_offsets": [0, 113246208]
    //     },
    //     "model.layers.0.input_layernorm.weight": {
    //         "dtype": "BF16",
    //         "shape": [4096],
    //         "data_offsets": [262144000, 262152192]
    //     },
    //     ...
    //     "__metadata__": { ... }
    // }
    // where dtypes is one of "F64","F32","F16","BF16","I64","I32","I16","I8","U8","BOOL"
    // ref. https://github.com/safetensors/safetensors, https://huggingface.co/docs/safetensors/en/index

    // model path
    const model_dir = "models/Llama-3.2-1B-Instruct";
    const config_filename = "config.json";
    const generation_config_filename = "generation_config.json";
    const tokenizer_filename = "tokenizer.json";
    const tokenizer_config_filename = "tokenizer_config.json";
    const model_filename = "model.safetensors";

    // get cwd, arena allocator
    const cwd = std.Io.Dir.cwd();
    const arena: std.mem.Allocator = init.arena.allocator();

    // parse config.json
    const config_path = model_dir ++ "/" ++ config_filename;
    const config_json = try loadJson(std.json.Value, init.io, cwd, arena, config_path, .{});

    // parse generation_config.json
    const generation_config_path = model_dir ++ "/" ++ generation_config_filename;
    const generation_config_json = try loadJson(std.json.Value, init.io, cwd, arena, generation_config_path, .{});

    // parse tokenizer_config.json
    const tokenizer_config_path = model_dir ++ "/" ++ tokenizer_config_filename;
    const tokenizer_config_json = try loadJson(std.json.Value, init.io, cwd, arena, tokenizer_config_path, .{});

    // parse tokenizer.json incl. merges, pretokenizers, added/special tokens (TODO comprehensive struct for tokenizer, single read)
    const tokenizer_path = model_dir ++ "/" ++ tokenizer_filename;
    const tokenizer_json = try loadJson(std.json.Value, init.io, cwd, arena, tokenizer_path, .{});
    const pretokenizer_json = try loadJson(PreTokenizer, init.io, cwd, arena, tokenizer_path, .{ .ignore_unknown_fields = true });
    const added_tokens_json = try loadJson(AddedTokens, init.io, cwd, arena, tokenizer_path, .{ .ignore_unknown_fields = true });
    const merges_json = try loadJson(TokenizerMerges, init.io, cwd, arena, tokenizer_path, .{ .ignore_unknown_fields = true });
    const vocab_json = try loadJson(TokenizerVocab, init.io, cwd, arena, tokenizer_path, .{ .ignore_unknown_fields = true });

    // swap vocab bytes with BBPE
    var vocab_bbpe_swap: std.json.ArrayHashMap(u32) = .{};
    var vocab_raw_iterator = vocab_json.model.vocab.map.iterator();
    while (vocab_raw_iterator.next()) |tok| {
        const bytes = try infer.bbpeSwap(arena, tok.key_ptr.*);
        try vocab_bbpe_swap.map.put(arena, bytes, tok.value_ptr.*);
    }
    const vocab_map = &vocab_bbpe_swap.map;

    const regex = blk: {
         for (pretokenizer_json.pre_tokenizer.pretokenizers) |step| {
             if (std.mem.eql(u8, step.type, "Split")) {
                 const pattern = step.pattern orelse return error.InvalidValue;
                 break :blk pattern.Regex;
             }
         }
         return error.InvalidValue;
     };

    var merge_rules: std.json.ArrayHashMap(u32) = .{};
    var merge_ranks: std.json.ArrayHashMap(u32) = .{};
    var merge_buf: [2048]u8 = undefined;
    const merge_key_template = "{d}:{d}";
    for (merges_json.model.merges, 0..) |merge, rank| {
        const space = std.mem.indexOfScalar(u8, merge, ' ') orelse return error.InvalidValue;
        const token1 = try infer.bbpeSwap(arena, merge[0..space]);
        const token2 = try infer.bbpeSwap(arena, merge[space + 1 ..]);

        const token_id1: u32 = vocab_map.get(token1) orelse return error.InvalidValue;
        const token_id2: u32 = vocab_map.get(token2) orelse return error.InvalidValue;
        const merged_token = try std.fmt.bufPrint(
            &merge_buf,
            "{s}{s}",
            .{ token1, token2 },
        );
        const merged_token_id: u32 = vocab_map.get(merged_token) orelse return error.InvalidValue;

        const key = try std.fmt.allocPrint(
            arena,
            merge_key_template,
            .{ token_id1, token_id2 },
        );

        try merge_rules.map.put(arena, key, merged_token_id);
        try merge_ranks.map.put(arena, key, @intCast(rank));
    }
    const merge_rules_map = &merge_rules.map;
    const merge_ranks_map = &merge_ranks.map;

    // get cli args
    const args = try init.minimal.args.toSlice(arena);
    // for (args) |arg| {
    //     std.log.info("arg: {s}", .{arg});
    // }
    const user_prompt: []const u8 = if (args.len > 1) args[1] else "Provide minimal instructions on using this language model.";
    const system_prompt = "You are a helpful chat assistant.";

    // render chat from template
    const template = "<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\nCutting Knowledge Date: December 2023\nToday Date: {[date_string]s}\n\n{[system_message]s}<|eot_id|><|start_header_id|>user<|end_header_id|>\n\n{[user_message]s}<|eot_id|><|start_header_id|>assistant<|end_header_id|>\n\n"; // llama3 template
    const today = "09 Sep 2026"; // replace with call to get today's date
    var render_buf: [2048]u8 = undefined;
    const rendered_input = try std.fmt.bufPrint(
        &render_buf,
        template,
        .{
            .date_string = today,
            .system_message = system_prompt,
            .user_message = user_prompt
        },
    );

    // tokenize input
    var token_ids: std.ArrayList(u32) = .empty;
    var pos: usize = 0;
    var key_buf: [256]u8 = undefined;

    var loop_arena_heap = std.heap.ArenaAllocator.init(arena);
    defer loop_arena_heap.deinit();
    const loop_arena = loop_arena_heap.allocator();

    while (pos < rendered_input.len) {
        const rest = rendered_input[pos..];

        if (std.mem.startsWith(u8, rest, "<|")) {
            const close = std.mem.indexOf(u8, rest, "|>") orelse return error.InvalidValue;
            const len = close + 2;

            const special_token = rest[0..len];
            const token_id = for (added_tokens_json.added_tokens) |added_token| {
                if (std.mem.eql(u8, special_token, added_token.content)) {
                    break added_token.id;
                }
            } else return error.InvalidValue;

            try token_ids.append(arena, token_id);
            pos += len;
        } else {
            const len = std.mem.indexOf(u8, rest, "<|") orelse rest.len;

            const chunk = rest[0..len];
            const pretokens = try infer.tokenizerSplitRegex(arena, regex, chunk);
            for (pretokens) |pretoken| {
                if (vocab_json.model.ignore_merges orelse false) {
                    const token_id: ?u32 = vocab_map.get(pretoken);
                    if (token_id) |id| {
                        try token_ids.append(arena, id);
                        continue;
                    }
                }

                // split text to token IDs
                var token_split: std.ArrayList(u32) = .empty;
                for (0..pretoken.len) |i| {
                    const id = vocab_map.get(pretoken[i .. i + 1]) orelse return error.InvalidValue;
                    try token_split.append(loop_arena, id);
                }

                // apply merge rules, TODO min heap for O(n^2) -> O(nlogn)?
                while (token_split.items.len > 1) {
                    var best_pos: ?usize = null;
                    var best_rank: u32 = std.math.maxInt(u32);
                    var best_merged_tid: u32 = undefined;

                    for (0..token_split.items.len - 1) |i| {
                        const key = try std.fmt.bufPrint(
                            &key_buf,
                            merge_key_template,
                            .{ token_split.items[i], token_split.items[i + 1] },
                        );

                        if (merge_ranks_map.get(key)) |rank| {
                            if (best_pos == null or rank < best_rank) {
                                best_pos = i;
                                best_rank = rank;
                                best_merged_tid = merge_rules_map.get(key) orelse return error.InvalidValue;
                            }
                        }
                    }

                    const i = best_pos orelse break;
                    token_split.items[i] = best_merged_tid;
                    _ = token_split.orderedRemove(i + 1);
                }

                try token_ids.appendSlice(arena, token_split.items);
            }

            pos += len;
        }
    }

    // open .safetensors file with mmap
    const model_path = model_dir ++ "/" ++ model_filename;
    const model_file = cwd.openFile(
        init.io, model_path, .{ .mode = .read_only }
    ) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.err("no file found at {s}", .{model_path});
            return;
        },
        else => return err,
    };
    defer model_file.close(init.io);

    // mmap file
    const mf_stat = try model_file.stat(init.io);
    const mf_size = mf_stat.size;
    const hls_u64: usize = 8; // header length size, 8 bytes little endian
    if (mf_size < hls_u64) { // error.InvalidFileFormat
        std.log.err("file size {d} incorrect at {s}", .{ mf_size, model_path });
        return;
    }
    var mm = try model_file.createMemoryMap(init.io, .{ .len = mf_size, .protection = .{ .read = true, .write = false } });
    defer mm.destroy(init.io);
    const mmbuf = mm.memory;

    // parse header
    const hsize: usize = std.mem.readInt(u64, mmbuf[0..hls_u64], .little);
    const header = mmbuf[hls_u64 .. hls_u64 + hsize];
    const header_json = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        header,
        .{}
    );
    const data_offset: usize = hls_u64 + hsize;
    const tensor_data = mmbuf[data_offset..];

    // embed tokens data location
    const embed_tokens = header_json.object.get("model.embed_tokens.weight").?;
    const embed_tokens_dtype = embed_tokens.object.get("dtype").?.string;

    const embed_tokens_data_offsets = embed_tokens.object.get("data_offsets").?.array.items;
    const embed_tokens_start: usize = @intCast(embed_tokens_data_offsets[0].integer);
    const embed_tokens_end: usize = @intCast(embed_tokens_data_offsets[1].integer);

    const embed_tokens_shape = embed_tokens.object.get("shape").?.array.items;
    const embed_tokens_num: usize = @intCast(embed_tokens_shape[0].integer);
    const embed_tokens_dim: usize = @intCast(embed_tokens_shape[1].integer);

    var bytes_per_row: usize = embed_tokens_dim * 2; // fix default handling
    if (std.mem.eql(u8, embed_tokens_dtype, "BF16")) {
        bytes_per_row = embed_tokens_dim * 2;
    }
    else {
        return error.NotImplemented;
    }

    const embed_tokens_data = tensor_data[embed_tokens_start .. embed_tokens_end];

    // lookup input embeddings
    const embeddings = try arena.alloc(f32, token_ids.items.len * embed_tokens_dim);
    for (token_ids.items, 0..) |tid, tpos| {
        const emb_offset = @as(usize, tid) * bytes_per_row;
        const embedding_bytes = embed_tokens_data[emb_offset..][0..bytes_per_row];

        for (0..embed_tokens_dim) |vpos| {
            // https://en.wikipedia.org/wiki/Single-precision_floating-point_format
            // f32 format: | 1 sign bit | 8 exponent bits | 23 fraction/precision bits |
            // https://en.wikipedia.org/wiki/Bfloat16_floating-point_format
            // bf16 format: | 1 sign bit | 8 exponent bits | 7 fraction/precision bits |
            // no native support in Zig for b16, hence: (a) read as u16, (b) convert to u32, (c) left-shift by 16 bits, (d) convert to f32
            const bits = std.mem.readInt(u16, embedding_bytes[2 * vpos ..][0..2], .little);
            embeddings[tpos * embed_tokens_dim + vpos] = @bitCast(@as(u32, bits) << 16);
        }
    }

    // forward pass
    const num_hidden_layers: usize = @intCast(config_json.object.get("num_hidden_layers").?.integer);
    for (0..num_hidden_layers) |i| {
        std.debug.print("layer-{d} ", .{i});
    }

    // output embedding

    // debug prints and discards
    std.debug.print("\n\n___rendered input:\n{s}", .{rendered_input});
    // std.debug.print("---header---\n{f}\n", .{std.json.fmt(header_json, .{ .whitespace = .indent_4 })});
    std.debug.print("\n___token sequence:\n", .{});
    for (token_ids.items, 0..) |tid, tpos| {
        const row = embeddings[tpos * embed_tokens_dim ..][0..embed_tokens_dim];
        std.debug.print("token {d}: {any}\n", .{ tid, row });
    }
    _ = embed_tokens_num;
    _ = generation_config_json; // stop tokens
    _ = tokenizer_config_json;
    _ = tokenizer_json;
}
