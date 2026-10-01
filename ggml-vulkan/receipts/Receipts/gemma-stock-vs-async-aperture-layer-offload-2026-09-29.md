# Gemma stock vs async aperture layer offload

**Date:** 2026-09-29  
**Model:** `C:\Models\gemma-4-E4B-it-Q4_K_M.gguf`  
**Build:** stock llama.cpp / ggml commit `4da633776`, build 11223  
**Metric:** generation throughput only, 128-token `llama-bench` decode, 3 measured repetitions. Prompt prefill is omitted from the comparison.  
**Common settings:** `-ngl 999 -sm layer -ncmoe 0 -ctk q4_0 -ctv q4_0 -fa on --no-host 1 -p 512 -n 128 -r 3`; equal tensor split across selected V340 dies. Vulkan0/P2000 was not selected.

## End-to-end decode results

Rates are mean ± sample standard deviation across 3 repetitions. The single-die hook control has no inter-die copy and measures the hook's no-handoff overhead.

| Selected V340 dies | Stock layer offload tok/s | Shared-aperture callback tok/s | Difference vs stock | Targeted async handoffs routed per measured run |
|---:|---:|---:|---:|---:|
| 1 | 40.010 ± 0.046 | 40.011 ± 0.046 | +0.00% | 0 |
| 2 | 20.418 ± 0.083 | 20.206 ± 0.101 | −1.04% | 389 |
| 3 | 16.178 ± 0.014 | 15.948 ± 0.012 | −1.42% | 778 |
| 4 | 14.251 ± 0.020 | 14.085 ± 0.014 | −1.17% | 1,167 |

The async aperture path did **not** improve end-to-end decode throughput in this run. It produced essentially stock performance, slightly lower at two through four dies. This is the direct result; do not describe it as a speedup.

## Hook and correctness evidence

The process-local probe patches the selected backend devices' `init_backend` callbacks, then patches each returned backend's `ggml_backend_i::cpy_tensor_async` slot at `+0x38`. Every matching `l_out-*` handoff between selected Vulkan devices was routed through one shared host aperture. It does not rebuild or replace the stock llama.cpp binaries. P2000/Vulkan0 was excluded.

Separate correctness passes succeeded byte-for-byte through the aperture and destination VRAM:

| Selected dies | Verified handoffs | Payload sizes observed |
|---:|---:|---:|
| 2 | 131 | 5,242,880 B and 10,240 B |
| 3 | 262 | 5,242,880 B and 10,240 B |
| 4 | 393 | 5,242,880 B and 10,240 B |

The measured repetitions used a same-process warmup and skipped readback verification to keep those CPU readbacks out of timing. They routed the expected 389/778/1,167 handoffs for two/three/four dies.

## What the timing shows

For each routed handoff, the current correctness-oriented async callback synchronizes both backend queues before issuing two synchronous buffer copies through the shared aperture. At the 10,240-byte decode size, the measured averages were:

| Dies | Both-backend synchronization | Source VRAM → aperture | Aperture → destination VRAM | Sync plus two legs |
|---:|---:|---:|---:|---:|
| 2 | 21.614 ms | 140.154 µs | 140.514 µs | 21.895 ms |
| 3 | 16.945 ms | 133.059 µs | 127.437 µs | 17.206 ms |
| 4 | 14.677 ms | 137.137 µs | 134.986 µs | 14.949 ms |

The explicit synchronization dominates the two copy legs by roughly two orders of magnitude. The callback currently implements the correctness milestone's blocking ordering (`synchronize` both backends, then copy), so it has not removed the per-boundary wait that matters to token latency. The pinned ggml async-copy fallback itself synchronizes both backends before doing a blocking tensor copy when the destination `cpy_tensor_async` returns false ([pinned source](https://github.com/ggml-org/llama.cpp/blob/4da6337767f973e2b4d0797e5b323d77d8565e4a/ggml/src/ggml-backend.cpp#L2972-L3002)).

This explains why the current aperture mutation fails to improve throughput: the per-hop synchronization remains, while the aperture only changes the transfer legs. The next optimization target is removing the blocking per-hop queue drain while preserving source-ready and destination-consumer ordering; a faster aperture transfer alone cannot yield the expected tok/s increase.

## Raw records

- Stock end-to-end run: [stock-gemma-die-scaling-2026-09-29.txt](stock-gemma-die-scaling-2026-09-29.txt)
- Actual `cpy_tensor_async +0x38` aperture run: [async-aperture-gemma-die-scaling-2026-09-29.txt](async-aperture-gemma-die-scaling-2026-09-29.txt)
- Probe: [Probe-LlamaBenchBufferCopy.ps1](../Probe-LlamaBenchBufferCopy.ps1)

**Correction to earlier comparison:** [aperture-gemma-die-scaling-2026-09-29.txt](aperture-gemma-die-scaling-2026-09-29.txt) records an earlier mutation of the destination buffer `cpy_tensor` callback at `+0x40`. It is not the repository's backend async `cpy_tensor_async +0x38` mutation and should not be used as the A/B result for this method.
