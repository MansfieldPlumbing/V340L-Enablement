# Batched semantic aperture result — 2026-09-30

## Verdict

The aperture transport is real and the batched handoff restored coherent Gemma 4 generation, but it did not recover useful dual-die throughput and failed the larger prompt benchmark gate. This is a bounded Vulkan proof, not a runtime claim.

## Exact environment

- llama.cpp build `11223`, commit `4da633776`
- Model: `C:\Models\gemma-4-E4B-it-Q4_K_M.gguf`
- Model SHA-256: `DFF0FFBA4C90B4082D70214D53CE9504A28D4D8D998276DCB3B8881A656C742A`
- Devices: `Vulkan1/Vulkan2`, Radeon Pro V340L 22Q4
- Split: layer, `1/1`
- KV cache: `q4_0`, flash attention enabled, no host buffer fallback

## What worked

- PowerShell mutated the pinned release build's live `cpy_tensor_async`, `graph_compute`, and `synchronize` callbacks without C# or a llama.cpp rebuild.
- Producer copies used distinct aperture offsets rather than aliasing every tensor onto one address.
- One producer completion boundary covered the complete input batch for each consuming split.
- Consumer-side Vulkan blits copied aperture payloads into llama's real destination tensors immediately before the consuming graph.
- The short benchmark completed with 147 producer handoffs and 147 consumer blits, seven batched producer waits, and zero blocking fallbacks.
- A deterministic 96-token Gemma generation was coherent and completed with 2,100 producer handoffs, 2,100 consumer blits, 100 batched producer waits, and zero blocking fallbacks.

## What did not work

- Short semantic generation measured only `21.2` tokens/s; the four-token benchmark measured `21.530449` tokens/s.
- The established stock references are `40.010` tokens/s on one V340 die and `20.418` tokens/s on two dies. The semantic aperture remained near stock dual-die speed and retained almost the full dual-die latency penalty.
- The earlier unsynchronized alias measured `71.306` tokens/s but produced invalid output. That number represented execution with the dependency removed, not usable inference.
- The `p512/n128`, three-repetition warmup gate failed during prompt decoding with `test_prompt: failed to decode prompt batch, res = -3`. No sustained-performance claim is made.

## Interpretation

The byte payload is not the dominant cost. The short semantic run took about `46–47 ms/token`, versus `48.976 ms/token` for stock dual die and `24.994 ms/token` for stock single die. Approximately one producer completion boundary occurred per generated token. Batching removed per-tensor completion waits, but the two graph stages remained serial and the host still had to bridge the two independently created Vulkan devices.

The downstream die can be ready while the upstream die computes, but a single autoregressive stream cannot start the next token until the downstream stage finishes the current token. A queued GPU semaphore would remove the host wakeup; it would not remove this causal stage latency. Concurrent independent sequences are required to pipeline useful work across both stages.

## Stop condition

Per the experiment boundary, no additional Vulkan mutation attempts follow this failure. The durable work proceeds through the stock CPU ggml interception seam, persistent D3D12/DirectML buckets, explicit CPU fallback, and separate latency-versus-throughput tests.
