# Vulkan experiment autopsy and DirectML pivot — 2026-10-01

## Outcome

The runtime shim carries coherent layer-split inference through a shared host aperture, including V340L to P2000. It has not recovered single-die performance. The exact cause of the remaining approximately 22 ms/token penalty is unresolved.

The last experiment reduced counted graph-phase Vulkan submissions from 658 to 386 (41.3%) while decode remained approximately 21.8 tokens/s. That rejects submission count alone as a sufficient explanation under this tested batching configuration. It does not identify GPU execution residency, consumer wait time, or inter-batch idle time.

## Runtime identity and controls

- Isolated stock runtime: `C:\dev\V340L-Emancipated\scratch\codex-baton-20261001\runtime`.
- Upstream commit: `4da6337767f973e2b4d0797e5b323d77d8565e4a`.
- `ggml-vulkan.dll` SHA256: `AE67DDD85CC9C0E777FA76368E1A63AD90DDD4B97709CBC5C46F734F97C5248E`.
- Installed `C:\bin\llama.cpp` Vulkan DLL is a different, forked binary. It was excluded from these controls.
- Model: `C:\Models\gemma-4-E4B-it-Q4_K_M.gguf`; identical capital-of-France prompt, 32 forced generated tokens, seed 1234, greedy sampling, F16 KV, context 512, layer split 1:1.
- Managed callbacks emitted through PowerShell/Reflection.Emit. No C++ rebuild was used for the coarse-batching experiment.

## Results

| Configuration | Prompt tokens/s | Decode tokens/s | Approx. decode ms/token |
|---|---:|---:|---:|
| Stock one V340 die | 60.4 | 40.4 | 24.75 |
| Stock two V340 dies | 45.8 | 20.8 | 48.08 |
| Shim one V340 die | 60.4–60.8 | 40.5–40.6 | 24.63–24.69 |
| Aperture/baton two V340 dies | 47.0–47.8 | 21.6–21.8 | 45.87–46.30 |
| Stock two dies, dummy override / PP off | 46.07 | 21.20 | 47.17 |
| Aperture/baton two dies, coarse batching | 47.2 | 21.8 | 45.87 |

Rates printed with one decimal place imply rounding. These are bounded runs, not a confidence-interval study. Visible deterministic generated output remained coherent; no formal token-ID hash equivalence assertion has been made.

### Coarse batching receipt

`integration-coarse-decode-two-32-token-receipt.json` and `coarse-decode-two-console.log` contain the result.

The stock graph callback has RVA `0x36B0`. Disassembly confirms `last_total_flops` at backend context offset `0x130`: multiply/shift division by 40 at RVA `0x3F67`, and actual-total writeback at `0x58B5`. The launcher checks the division instruction bytes before enabling mutation.

The node cap was raised to 100000 for the process. After the first four graph calls per backend, the hook writes 8 trillion to `last_total_flops` immediately before native graph execution, driving its /40 threshold to the 200-GFLOP cap, or any lower native device cap. Sixty-two graph calls were mutated. The native graph retains its normal writeback. The aperture, tensor routing, fence baton, and GPU stage markers were unchanged.

| Graph-phase counters | Ordinary baton | Coarse baton |
|---|---:|---:|
| Producer submits | 333 | 212 |
| Consumer submits | 325 | 174 |
| Total submits | 658 | 386 |
| Producer direct dispatches | 17969 | 17969 |
| Consumer direct dispatches | 13130 | 13130 |
| Producer workgroups | 7866952 | 7866952 |
| Consumer workgroups | 9038327 | 9038327 |

These counts cover graph phases, including the profiling configuration; they are not whole-process submission counts or exactly 32 identical decode-only frames. Coarse-run graph CPU calls totaled 145.86 ms producer and 106.79 ms consumer. Publication CPU calls totaled 180.99 ms. Native fence waits in phase 0 totaled 1260.11 ms; phase 0 includes work outside graph and boundary phases and has not been exhaustively attributed to particular readbacks.

### What the transport measurement establishes

Steady boundary payload is 30720 bytes in 21 tensor-copy regions. GPU timestamps measured producer SDMA copy duration around 0.007 ms. The observed producer graph-end marker to copy-start gap was approximately 0.15–0.44 ms.

This establishes that the measured producer copy and lead-in gap do not explain 22 ms/token. It does **not** time the subsequent consumer fence wait, consumer reads from system memory, or all driver scheduling. Cross-device timestamp values were not directly subtracted. Existing whole-stage timestamps include queue bubbles and recording gaps; they are not isolated shader arithmetic measurements. Per-batch GPU gaps remain unmeasured.

### Other findings and limits

- Stock PP-on and PP-off runs both reported 30 reused graphs. PP-off changes the handoff: one scheduler copy means no scheduler events and a host-sync fallback. The shim's guard rejected that path before handoff; the guard was not bypassed.
- Application-level boundary CPU wait requests were zero in the successful shim runs. That does not prove that WDDM internally performs cross-adapter fence scheduling without CPU involvement. [Microsoft native GPU fence documentation](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/native-gpu-fence-objects).
- V340→P2000 ran coherently, but the measured shim decode rate was 17.3 tokens/s versus 22.7 stock heterogeneous. Startup/compilation and an execution outlier limit that comparison. This is not a heterogeneous speedup result.
- The current shim uses bounded, preallocated publication objects and deferred native event cleanup. Long-running resource retirement and four-die production operation have not been validated.

## DirectML pivot: inspected assets

- `C:\dev\DirectAI`: ONNX Runtime DirectML application. `DirectMLSession.cs` creates ordinary ORT sessions; diffusion stage transitions materialize managed output arrays. It is a useful application/model integration reference, not yet the queue-owned executor required here.
- `C:\dev\dpx\dpx-cs`: model/tokenizer/interpreter reference with native-free D3D12 interop and quantized shaders. `GpuD3D12.cs` uploads activations, copies results to readback, and CPU-spin-waits per GEMM. That hot path cannot be carried into the requested multi-device executor.
- `C:\dev\inswapper-restored`: DirectML admission/tooling reference. Inspection has not established a resident cross-adapter LLM stage executor.
- Existing PowerShell `Test-DirectMLGemm.ps1` is a standalone DirectML operator/binding reference. Its terminal verification wait must not become an inter-stage wait.

Standalone DirectML records compiled operators into an application-owned command list; the caller submits it and supplies dependency barriers. [RecordDispatch](https://learn.microsoft.com/en-us/windows/win32/api/directml/nf-directml-idmlcommandrecorder-recorddispatch). Whole operator graphs can be compiled with [CompileGraph](https://learn.microsoft.com/en-us/windows/win32/api/directml/nf-directml-idmldevice1-compilegraph). This is an execution API capability, not evidence of recovered multi-GPU throughput.

### Driver census

`Probe-D3D12MetaCommands.ps1` completed and wrote `d3d12-metacommand-census.json`. DXGI adapters 0–3 each expose four MetaCommands: two convolution and two GEMM descriptions. P2000 exposes 14, including GEMM, MHA, and quantized GEMM. Adapter 5 is another AMD DXGI entry; it has not been assigned as an additional physical die. All parameter stages are saved. The initial census counted SDK conditional declarations as duplicate vtable slots and crashed; corrected slots 59/60 completed. No MetaCommand execution has been tested.

## Next bounded experiment: identical work, different placement

Build a PowerShell-owned standalone DML/D3D12 two-stage harness before replacing an inference engine. Use fixed, resident tensors and weights, deterministic input, and identical operator dimensions/counts. Compare:

1. Both dependent stages on V340 die 0.
2. The same stages split V340 die 0→die 1.
3. The same stages split V340 die 0→P2000, with each adapter's local execution time also measured.

Record one command list per stage, one GPU fence handoff, and the boundary payload. No host readback, host copy, fence polling, or host wait between stages. Obtain a single terminal completion for verification and query readback. Keep creation, compilation, initialization, and weight upload outside timed iterations. Use D3D12 timestamp frequencies and clock calibration to compare adapter timelines; report calibration uncertainty instead of subtracting unrelated raw GPU clocks.

Capture median/p95 end-to-end latency, per-stage GPU time, producer publication, consumer wait/acquire interval, submitted lists per queue, boundary bytes, and output error. Include a fence-only baseline to separate ordering latency from data and compute. Begin with the measured 30-KiB boundary size. Compare a local two-stage submission shape against the split shape so submission count is controlled.

DirectML operations and custom D3D12 shaders can share the same queue/resource design. Do not assume standalone DML accepts the existing GGUF Q4_K_M packing: quantized format conversion and Gemma attention/KV semantics are separate implementation work. The first acceptance criterion is a measured, correct two-stage latency comparison; full-model decoding follows only after that comparison is credible.
