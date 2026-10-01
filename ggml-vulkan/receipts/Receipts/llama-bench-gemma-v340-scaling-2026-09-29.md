# llama.cpp Gemma 4 V340 Scaling Benchmark

**Date:** 2026-09-29  
**Host:** Windows 11; Intel Xeon W-2145; four Radeon Pro V340L dies  
**Benchmark:** stock `llama-bench.exe` / Vulkan backend  
**Build:** llama.cpp 0.5.0-dev, build 11223, commit `4da633776`  
**Model:** `C:\Models\gemma-4-E4B-it-Q4_K_M.gguf` (4,961,343,656 bytes; 7,518,069,290 parameters; GGUF model type `gemma4 E4B Q4_K - Medium`)

## Configuration

All runs used three repetitions, prompt processing at 512 tokens, generation at 128 tokens, layer split, Q4_0 K and V cache, Flash Attention enabled, all model layers requested on GPU (`-ngl 999`), CPU MoE layers set to zero, and `--no-host 1`. Vulkan device selection was explicit and contained only the listed V340 devices. The P2000 (`Vulkan0`) was not selected. Host CPU threads still handle orchestration and benchmark setup; `--no-host` prevents using host buffers as a fallback for model tensors.

| V340 dies selected | Vulkan devices | Tensor split | Prompt tok/s (mean ± SD) | Prompt samples | Generation tok/s (mean ± SD) | Generation samples |
|---:|---|---|---:|---|---:|---|
| 1 | `Vulkan1` | `1.00` | 404.835 ± 0.935 | 405.278, 405.467, 403.761 | 40.049 ± 0.045 | 40.0789, 39.9977, 40.0707 |
| 2 | `Vulkan1/Vulkan2` | `1.00/1.00` | 402.680 ± 0.922 | 403.670, 401.845, 402.526 | 20.521 ± 0.019 | 20.5024, 20.5407, 20.5207 |
| 3 | `Vulkan1/Vulkan2/Vulkan3` | `1.00/1.00/1.00` | 400.376 ± 0.322 | 400.747, 400.218, 400.164 | 16.163 ± 0.017 | 16.1827, 16.1527, 16.1543 |
| 4 | `Vulkan1/Vulkan2/Vulkan3/Vulkan4` | `1.00/1.00/1.00/1.00` | 394.715 ± 0.288 | 394.878, 394.885, 394.382 | 14.265 ± 0.015 | 14.2685, 14.2497, 14.2783 |

## Interpretation and limits

The runs completed successfully for every selected device count. On this model and benchmark configuration, adding V340 dies did not improve measured throughput: prompt processing decreased from 404.835 tok/s on one die to 394.715 tok/s on four; generation decreased from 40.049 tok/s to 14.265 tok/s. These are measurements for this stock Vulkan build, model, and configuration, not DirectML results or a general throughput claim.

`llama-bench` reports the full Vulkan inventory in its `gpu_info` field, including the P2000. Actual benchmark selection is the separate `devices` field (`Vulkan1` through `Vulkan4` only). Each invocation specified that selection explicitly. The Vulkan loader also loaded the CPU backend DLL; that is normal backend discovery and host orchestration. `n_gpu_layers=999`, `n_cpu_moe=0`, `no_host=true`, and explicit V340 device selection constrained model placement to the selected GPU backends. This is not a claim that the CPU is absent from process orchestration.

The requested Q4_0 cache and Flash Attention settings were recorded by llama-bench as `type_k=q4_0`, `type_v=q4_0`, and `flash_attn=1`. Gemma runs used llama-bench defaults `n_batch=2048`, `n_ubatch=512`, and eight threads.

## Reproduction command shape

Replace `<DEVICES>` and `<SPLIT>` with the rows above:

```powershell
C:\bin\llama.cpp\llama-bench.exe `
  -m C:\Models\gemma-4-E4B-it-Q4_K_M.gguf `
  -ngl 999 -dev <DEVICES> -sm layer -ts <SPLIT> -ncmoe 0 `
  -ctk q4_0 -ctv q4_0 -fa on --no-host 1 `
  -p 512 -n 128 -r 3 -o json
```

The three-repetition JSON measurements are summarized above. No Muse Glimmer result is included: its initial two-die run was interrupted before completion and was not counted.

## Aperture-fix integration attempt

The in-process interception harness was then used with the same pinned `llama-bench-impl.dll`, Gemma model, Vulkan devices, and benchmark settings. Its shared allocation was 2 MiB (the harness default). The aperture allocation size is configurable; this particular proof callback and harness are currently restricted to exactly 8,192-byte tensor copies.

| Selected V340 dies | Harness status | Prompt tok/s (mean ± SD) | Generation tok/s (mean ± SD) | Aperture-routed model copies |
|---:|---|---:|---:|---:|
| 1 | Completed; no cross-device copy expected | 405.830 ± 0.623 | 40.203 ± 0.179 | 0 |
| 2 | Rejected as a fixed-path result | 403.485 ± 0.564 | 20.489 ± 0.180 | 0 |

For the two-die run, the hook was installed on the live Vulkan backend objects, but the model scheduler did not call the patched callback. The verbose scheduler trace instead showed a `Vulkan_Host` compute buffer and four scheduler copies. The script therefore failed closed and did not mark that benchmark as using the aperture. Its throughput is diagnostic only and must not be compared as “with the fix.”

Separately, `VulkanProofs\Test-GgmlApertureInterception.ps1` passed its standalone 8,192-byte copy through the 2 MiB aperture between V340 Vulkan devices: one callback handled, no stock fallback, and both aperture and destination bytes matched exactly. Elapsed time was 8,644.1 µs for that proof invocation; this is not llama inference latency or throughput. The proof restores the patched callback during cleanup. This confirms the aperture callback itself, but does not establish that llama.cpp model execution uses it.

**Receipt status:** baseline Vulkan Gemma scaling and the standalone byte-exact aperture proof are recorded. A same-model benchmark actually routed through the aperture has not yet been obtained. No fixed-path performance claim is made from the integration attempt.
