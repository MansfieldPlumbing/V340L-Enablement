# V340 llama-bench copy interception

`Probe-LlamaBenchBufferCopy.ps1` loads the pinned stock llama.cpp build 11223 (`4da633776`) in one process and replaces the selected Vulkan backends' `ggml_backend_i::cpy_tensor_async` function pointer at `+0x38`. It classifies transfers from the source and destination buffer devices, so tensor names do not determine routing. `Vulkan0` and any selected adapter whose description does not contain `V340` are rejected.

The script allocates **one host aperture for the whole run** with `VirtualAlloc`, imports that same allocation into each selected V340 backend with `ggml_backend_dev_buffer_from_host_ptr`, and caches bridge tensors by layout. For every selected cross-die copy, the verified reference route synchronizes source and destination, copies source VRAM to the aperture, then copies the aperture to destination VRAM. The allocation and device imports stay live until teardown. There is no CPU `memcpy` between the transfer legs.

This is a **blocking correctness reference**, not a queued or consumer-triggered blit. It does not claim that model execution achieves the separate 64 MiB drain benchmark's aggregate 12.02 GB/s. The returned benchmark is rejected if any selected cross-die callback fails its aperture route, falls through to the destination buffer copy callback, exceeds the aperture, or if `llama_bench` reports failure. A verification pass compares source, aperture, and destination bytes for the first observed transfer of each payload size; it does not check every occurrence.

## Measured Gemma result, 2026-09-29

Model: `C:\Models\gemma-4-E4B-it-Q4_K_M.gguf`. Settings: `-ngl 999 -sm layer -ncmoe 0 -ctk q4_0 -ctv q4_0 -fa on --no-host 1 -p 512 -n 128`. All selected devices were V340 dies; P2000 was excluded.

| Run | Selected dies | Generation tok/s | Coverage |
|---|---|---:|---|
| Stock llama-bench, 3 repetitions | `Vulkan1` | 40.010 | One-die reference |
| Stock llama-bench, 3 repetitions | `Vulkan1/Vulkan2` | 20.418 | Two-die reference |
| Blocking aperture route, warmup then 3 repetitions | `Vulkan1/Vulkan2` | 19.186 | 8,169/8,169 selected cross-die async callbacks routed; zero route failures |
| Blocking aperture verification, 1 repetition | `Vulkan3/Vulkan4` | 19.210 | 2,751/2,751 routed; first occurrence of each payload size byte-exact |
| Stock llama-bench, 3 repetitions | `Vulkan2` | 43.616 | Second die solo reference |

`Vulkan1/Vulkan2` are the two dies on one V340 card; `Vulkan3/Vulkan4` are the two dies on the other, as mapped in the existing DXGI/PnP receipt. The single-repetition second-card result is a correctness run, not a controlled speed comparison. The first-card blocking aperture route is **6.0% slower than stock two-die llama-bench**. It has not recovered the one-to-two-die generation drop.

The observed two-die generation workload has roughly 20 one-KiB `inp_per_layer` copies plus one 10-KiB `l_out` copy per token. On the blocking route, source synchronization before the 10-KiB copy averaged about 21 ms, whereas its two transfer legs averaged about 0.27 ms combined. This synchronization includes queued source GPU work; it is not a pure transfer-latency measurement. Improving bulk transfer bandwidth alone does not establish a model token-rate improvement.

Raw evidence: [stock scaling](Receipts/stock-gemma-die-scaling-2026-09-29.txt), [first-card all-copy run](Receipts/all-copy-two-die-benchmark-2026-09-29.txt), [second-card byte verification](Receipts/all-copy-second-card-verification-2026-09-29.txt), and [per-leg synchronization breakdown](Receipts/same-card-sync-breakdown-2026-09-29.txt).

## Invocation

```powershell
pwsh -NoProfile -File .\Probe-LlamaBenchBufferCopy.ps1 `
  -DeviceSelection Vulkan1/Vulkan2 -TensorSplit 1/1 `
  -Prompt 512 -Generation 128 -Repetitions 1 -RouteThroughAperture
```

The default 8 MiB aperture covers the observed Gemma payloads up to 5 MiB. A larger model payload needs a larger `-ApertureBytes`; the script rejects an undersized aperture. `-SkipByteVerification` is only for timing after a verification pass, and `-WarmupBeforeMeasure` runs one untimed repetition first. The script mutates callbacks only in its own process and restores selected device allocator slots during teardown.

## Next implementation seam

A queued path must keep the same imported arena open and replace the two blocking tensor-copy calls. The `cpy_tensor_async` callback can publish an immutable handoff command; a consumer-side hook must order the destination blit before the next graph uses that activation. Reusing or overwriting arena payload without that ordering is an explicitly approximate mode and must be measured separately from byte-exact inference. No queued-path speedup is claimed here.
