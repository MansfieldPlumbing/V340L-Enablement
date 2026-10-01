# Gemma 4 DirectML versus ggml measurement plan

## Question

Can the repository's CPU-backend interception seam execute real Gemma 4 graph buckets through persistent DirectML/D3D12 resources faster than stock ggml CPU execution while preserving coherent greedy output?

Vulkan is not part of the candidate runtime. Its single- and dual-die measurements remain diagnostic references only.

## Fixed test contract

- Use `C:\Models\gemma-4-E4B-it-Q4_K_M.gguf` with SHA-256 `DFF0FFBA4C90B4082D70214D53CE9504A28D4D8D998276DCB3B8881A656C742A`.
- Pin one llama.cpp build and record its build number and commit.
- Use the same prompt bytes, context size, KV types, thread count, seed, temperature zero, token count, and stop conditions in every lane.
- Perform one warmup followed by three measured repetitions.
- Measure locally in PowerShell. Persist raw output and parsed receipts. Never extrapolate between models, prompt sizes, devices, or execution lanes.

## Lanes

1. Stock ggml CPU: `-ngl 0`. This is the semantic and fallback baseline.
2. Stock Vulkan, one V340 die. Diagnostic reference, not a runtime dependency.
3. Stock Vulkan, two V340 dies. Diagnostic split-latency reference.
4. Stock CPU graph with one complete contiguous layer bucket intercepted and executed through DirectML/D3D12 on one V340 die. Unsupported nodes explicitly execute through stock CPU.
5. Same bucket executor with persistent layer placement across two V340 dies.
6. Only after lane 5 is correct: four-die placement and concurrent-sequence pipeline throughput.

## Build the model-facing lane in gates

1. Load Gemma through the CPU build and inventory every decode-graph node: operation, tensor type, shape, strides, byte size, and repetition count.
2. Produce a coverage manifest with exactly three dispositions: DirectML, D3D12 shader, or stock CPU fallback.
3. Select one complete contiguous layer bucket. Partial single-operator timing is not a model benchmark.
4. Create persistent D3D12 resources for its weights and scratch. Weight upload and operator compilation occur during warmup, never per token.
5. Execute the bucket through the existing `graph_compute` interception seam. Copy only boundary activations; retain weights and intermediate tensors on the assigned die.
6. Compare boundary tensors against stock CPU at every bucket edge before measuring speed.
7. Run deterministic generation and require coherent output. Record greedy token identity and numeric error at bucket boundaries.
8. Expand bucket coverage only after the preceding bucket passes correctness and resource-lifetime checks.

## Metrics

- Prompt tokens/s and time to first token.
- Generation tokens/s and per-token p50/p95 latency.
- D3D12 timestamp-query duration for each bucket.
- Host submit/wait time, bytes uploaded, and bytes read back per token.
- CPU fallback node count and accumulated fallback time.
- Per-die command-queue occupancy and memory residency.
- Greedy token agreement with stock CPU plus maximum/mean boundary-tensor error.

## Two different utilization tests

### Latency: one autoregressive sequence

The downstream die is necessarily idle while it waits for the upstream activation, and the upstream die becomes idle while the downstream layers run. Pre-recorded command lists and GPU queue dependencies can remove host dispatch bubbles, but cannot remove the token dependency.

### Throughput: multiple independent sequences

Pipeline independent sequences or microbatches so die 1 processes sequence B while die 2 processes sequence A. Report aggregate tokens/s and per-sequence latency separately. Do not present aggregate multi-sequence throughput as single-stream latency.

## Acceptance gates

- No silent unsupported operation and no unmeasured fallback.
- No hot-path weight upload or operator compilation.
- Every accelerated bucket passes boundary-tensor comparison.
- Deterministic output remains coherent and the greedy-token comparison is reported.
- DirectML/D3D12 must beat stock ggml CPU in an identical controlled lane before adding more dies.
- Any failure closes that bucket and falls back to stock CPU; it does not trigger another backend workaround.
