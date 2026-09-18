const std = @import("std");
const infer = @import("infer");

// Llama3 - https://github.com/meta-llama/llama3/blob/main/llama/model.py
// safetensor spec - https://github.com/safetensors/safetensors, https://huggingface.co/docs/safetensors/en/index
// HF transformers model support: // https://github.com/huggingface/transformers/blob/main/src/transformers/models/auto/modeling_auto.py
// BF16 hardware support - https://github.com/llvm/llvm-project/blob/main/llvm/lib/Target/AArch64/AArch64Processors.td
// SIMD/etc - https://mitchellh.com/writing/everyone-should-know-simd, https://www.ziglang.in/learn/how-to/simd-sum/
// https://developer.apple.com/documentation/accelerate, https://arxiv.org/html/2606.25426v1
// https://developer.apple.com/metal/, https://developer.apple.com/metal/cpp/, https://opensource.apple.com/projects/mlx/, https://github.com/ml-explore/mlx-c

// Tokenizer structs - merge to one?
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

// .safetensors header structs
const TensorInfo = struct {
    dtype: []const u8,
    shape: []const u64,
    data_offsets: [2]u64,
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

pub fn mmapReadWeights(
    arena: std.mem.Allocator,
    key: []const u8,
    tensor_info: std.json.ArrayHashMap(TensorInfo),
    tensor_data: []const u8,
) []f32 {
    const info = tensor_info.map.get(input_layernorm_key).?;
    std.debug.assert(std.mem.eql(u8, info.dtype, "BF16"));
    const dim = info.shape[info.shape.len - 1];
    const data = tensor_data[info.data_offsets[0] .. info.data_offsets[1]];
    const weights = try arena.alloc(f32, dim);
    for (0..dim) |i| {
        const bf16_bytes = std.mem.readInt(u16, data[2 * i ..][0..2], .little);
        weights[i] = @bitCast(@as(u32, bf16_bytes) << 16);
    }

    return weights;
}

pub fn simdDotProduct(
    comptime T: type
    x: []const T,
    y: []const T
) !T {
    if (x.len != y.len) return error.InvalidValue;
    const limit = x.len;

    const lanes = std.simd.suggestVectorLength(T);
    const V = @Vector(lanes, T);

    var k: usize = 0;
    var a: V = @splat(0);
    while (k + lanes <= limit) : (k += lanes) {
        const d1: V = x[k..][0..lanes].*;
        const d2: V = x[k..][0..lanes].*;
        a = @mulAdd(V, d1, d2, a); // equivalent to a += d1 * d2 but with one FMA instruction when hardware support available
    }
    var sum: T = @reduce(.Add, a);
    while (k < limit) : (k += 1) {
        const d1 = x[k];
        const d2 = y[k];
        sum = @mulAdd(T, d1, d2, sum);
    }

    return sum;
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

    // load config params
    const rms_norm_eps: f32 = config_json.object.get("rms_norm_eps").?;
    const hidden_size: usize = config_json.object.get("hidden_size").?;

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

    // load vocab, swap utf-8 codepoints per BBPE
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

    // load merges, swap token utf-8 codepoints per BBPE
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
    const sequence_len = token_ids.len;

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
    var tensor_info: std.json.ArrayHashMap(u32) = .{};
    var tensor_iterator = header_json.object.iterator();
    while (tensor_iterator.next()) |t| {
        const tname = t.key_ptr.*;
        if (std.mem.eql(u8, tname, "__metadata__")) continue;

        const info = try std.json.parseFromValueLeaky(
            TensorInfo,
            arena,
            t.value_ptr.*,
            .{},
        );

        try tensor_info.map.put(arena, tname, info);
    }
    const data_offset: usize = hls_u64 + hsize;
    const tensor_data = mmbuf[data_offset..];

    // embed tokens tensors
    const embed_tokens = tensor_info.map.get("model.embed_tokens.weight").?;
    const embed_tokens_dim = embed_tokens.shape[embed_tokens.shape.len - 1];
    std.debug.assert(embed_tokens_dim == hidden_size);

    std.debug.assert(std.mem.eql(u8, embed_tokens.dtype, "BF16"));
    var bytes_per_row: usize = hidden_size * 2;

    const embed_tokens_data = tensor_data[embed_tokens.data_offsets[0] .. embed_tokens.data_offsets[1]];

    // input embedding via lookup
    const activations = try arena.alloc(f32, token_ids.items.len * hidden_size);
    for (token_ids.items, 0..) |tid, tpos| {
        const emb_offset = @as(usize, tid) * bytes_per_row;
        const embedding_bytes = embed_tokens_data[emb_offset..][0..bytes_per_row];

        // https://en.wikipedia.org/wiki/Single-precision_floating-point_format
        // f32 format: | 1 sign bit | 8 exponent bits | 23 fraction/precision bits |
        // https://en.wikipedia.org/wiki/Bfloat16_floating-point_format
        // bf16 format: | 1 sign bit | 8 exponent bits | 7 fraction/precision bits |
        // steps: (a) read as u16, (b) convert to u32, (c) left-shift by 16 bits, (d) convert to f32 (with implicit typing for @bitCast)
        for (0..hidden_size) |vpos| {
            const bf16_bytes = std.mem.readInt(u16, embedding_bytes[2 * vpos ..][0..2], .little);
            activations[tpos * hidden_size + vpos] = @bitCast(@as(u32, bf16_bytes) << 16);
        }
    }

    // forward pass
    // prefill
    const num_hidden_layers: usize = @intCast(config_json.object.get("num_hidden_layers").?.integer);
    const layer_buf: [2048]u8 = undefined;
    for (0..num_hidden_layers) |i| {
        std.debug.print("layer-{d} ", .{i});

        // input RMSNorm
        // RMSNorm(a_i) = (1/RMS(a)) * (a_i * g_i) and RMS(a) = \sqrt((rms_norm_eps + (1/hidden_size) * \sum_{i=1}^{hidden_size} a_i^2))

        // load learnable gain parameters g
        const input_layernorm_key = try std.fmt.bufPrint(&layer_buf, "model.layers.{d}.input_layernorm.weight", .{ i });
        std.debug.assert(tensor_info.map.get(input_layernorm_key).?.shape[info.shape.len - 1] == hidden_size);
        const gain_params = try mmapReadWeights(input_layernorm_key, tensor_info, tensor_data);

        // RMS norm calc (replace with function)
        const lanes = std.simd.suggestVectorLength(f32);
        const V = @Vector(lanes, f32);
        for (0..sequence_len) |j| {
            // dot product
            const sum: f32 = try simdDotProduct(f32, activations[j*hidden_size..][0..hidden_size], activations[j*hidden_size..][0..hidden_size]);
            const rms_inv = 1 / @sqrt( ( rms_norm_eps + (1 / hidden_size) * sum ) );

            // (1/RMS(a)) * a_i * g_i, move to simdVectorHadamard() function?
            var k: usize = 0;
            var accumulator: V = @splat(0);
            const rms_inv_vec: V = @splat(rms_inv);
            while (k + lanes <= hidden_size) : (k += lanes) {
                const g: V = gain_params[k..][0..lanes].*;
                const a: V = activations[j * hidden_size + k ..][0..lanes].*;
                const out = rms_inv_vec * g * a;
                activations[j * hidden_size + k ..][0..lanes].* = out;
            }
            while (k < hidden_size) : (k += 1) {
                const g = gain_params[k];
                const a = activations[j * hidden_size + k];
                const out = rms_inv * g * a;
                activations[j * hidden_size + k] = out;
            }
        }

        // causal self-attention
        const num_attention_heads: usize = @intCast(config_json.object.get("num_attention_heads").?.integer);
        const num_key_value_heads: usize = @intCast(config_json.object.get("num_key_value_heads").?.integer);
        const head_dim: usize = @intCast(config_json.object.get("head_dim").?.integer);

        const qproj_key = try std.fmt.bufPrint(&layer_buf, "model.layers.{d}.self_attn.q_proj.weight", .{ i });
        std.debug.assert((tensor_info.map.get(qproj_key).?.shape[0] / num_attention_heads) == head_dim);
        std.debug.assert(tensor_info.map.get(qproj_key).?.shape[tensor_info.map.get(qproj_key).?.shape.len - 1] == hidden_size);
        const qproj_weights = try mmapReadWeights(qproj_key, tensor_info, tensor_data);

        const kproj_key = try std.fmt.bufPrint(&layer_buf, "model.layers.{d}.self_attn.k_proj.weight", .{ i });
        std.debug.assert((tensor_info.map.get(kproj_key).?.shape[0] / num_key_value_heads) == head_dim);
        std.debug.assert(tensor_info.map.get(kproj_key).?.shape[tensor_info.map.get(kproj_key).?.shape.len - 1] == hidden_size);
        const kproj_weights = try mmapReadWeights(kproj_key, tensor_info, tensor_data);

        const vproj_key = try std.fmt.bufPrint(&layer_buf, "model.layers.{d}.self_attn.v_proj.weight", .{ i });
        std.debug.assert((tensor_info.map.get(vproj_key).?.shape[0] / num_key_value_heads) == num_attn_keys);
        std.debug.assert(tensor_info.map.get(vproj_key).?.shape[tensor_info.map.get(vproj_key).?.shape.len - 1] == hidden_size);
        const vproj_weights = try mmapReadWeights(vproj_key, tensor_info, tensor_data);

        const oproj_key = try std.fmt.bufPrint(&layer_buf, "model.layers.{d}.self_attn.o_proj.weight", .{ i });
        std.debug.assert((tensor_info.map.get(oproj_key).?.shape[0] / num_attention_heads) == num_attn_queries);
        std.debug.assert(tensor_info.map.get(oproj_key).?.shape[tensor_info.map.get(oproj_key).?.shape.len - 1] == hidden_size);
        const oproj_weights = try mmapReadWeights(oproj_key, tensor_info, tensor_data);

        for (0..num_attention_heads) |i| {
            // matmul Q * A

            for (0..num_key_value_heads) |j| {
                // matmul K * A, cache
                // matmul V * A, cache
                ...
            }
        }



        // attention (GQA-8) with RoPE + KV caching, + residual
        // post-attention RMS norm
        // FFN with SwiGLU, + residual
    }

    // RMS norm
    // logits = outvec * E^T
    // sample next token from logits

    // decode

    // debug prints and discards
    std.debug.print("\n\n___rendered input:\n{s}", .{rendered_input});
    std.debug.print("---header---\n{f}\n", .{std.json.fmt(header_json, .{ .whitespace = .indent_4 })});
    // std.debug.print("\n___token sequence:\n", .{});
    // for (token_ids.items, 0..) |tid, tpos| {
    //     const row = embeddings[tpos * hidden_size ..][0..hidden_size];
    //     std.debug.print("token {d}: {any}\n", .{ tid, row });
    // }
    _ = embed_tokens_num;
    _ = generation_config_json; // stop tokens
    _ = tokenizer_config_json;
    _ = tokenizer_json;

    // https://github.com/meta-llama/llama3/blob/main/llama/model.py
    // class TransformerBlock(nn.Module):
    //     def __init__(...):
    //         ...
    //         self.feed_forward = FeedForward(
    //             dim=args.dim,
    //             hidden_dim=4 * args.dim,
    //             multiple_of=args.multiple_of,
    //             ffn_dim_multiplier=args.ffn_dim_multiplier,
    //         )
    //         ...
    //         self.attention_norm = RMSNorm(args.dim, eps=args.norm_eps)
    //         self.ffn_norm = RMSNorm(args.dim, eps=args.norm_eps)
    //     def forward(...):
    //         h = x + self.attention(self.attention_norm(x), start_pos, freqs_cis, mask)
    //         out = h + self.feed_forward(self.ffn_norm(h))
    //         return out
    //
    // class Transformer(nn.Module):
    //     ...
    //     def forward(...):
    //         _bsz, seqlen = tokens.shape
    //         h = self.tok_embeddings(tokens)
    //         ... # compute mask and freqs_cis (cosine/sine freqs for RoPE)
    //         for layer in self.layers:
    //             h = layer(h, start_pos, freqs_cis, mask)
    //         h = self.norm(h)
    //         output = self.output(h).float()
    //         return output

}
