# V340L multi-die Vulkan experiment: postmortem
Date: 2026-10-01. Status: experiment closed; Windows enablement retained.

## Intended result
Demonstrate that a model fitting one V340L die could be layer-split across dies without losing roughly half its decode throughput. The starting evidence was encouraging: PowerShell device creation, FP16 DirectML GEMM, SDMA aperture transfers, and GPU ordering worked in isolated tests. The project tried to join those smoke-tested pieces into stock llama.cpp using runtime hooks, avoiding a maintained llama.cpp fork.

## What we tried
1. Imported pinned host memory into both Vulkan devices and established a shared activation aperture.
2. Batched producer publication instead of issuing a separate transfer submission per tensor.
3. Tested external Vulkan semaphore handles. Handle import success alone was insufficient to establish working cross-adapter queue waits.
4. Created a D3D12 cross-adapter shared fence and imported it into Vulkan. Established producer publication and consumer ordering without an application CPU wait at the boundary.
5. Intercepted stock backend/device function pointers from PowerShell-generated assemblies. Corrected native ABI offsets, views, payload offsets, and queue ordering.
6. Compared stock one/two-die inference against the coherent aperture/baton path; tested pipeline-parallel disablement and coarse Vulkan submission batching.
7. Tested V340-to-P2000 inference as a heterogeneous correctness experiment.

The implementation progressed from isolated probes to coherent inference. It did not progress to the promised performance result.

## Results
The controlled llama runtime was commit `4da6337767f973e2b4d0797e5b323d77d8565e4a`. Its ggml-vulkan DLL SHA256 was `AE67DDD85CC9C0E777FA76368E1A63AD90DDD4B97709CBC5C46F734F97C5248E`. A different installed/forked DLL was excluded from these controls.

Gemma E4B Q4_K_M; “The capital of France is”; 32 forced generated tokens; greedy sampling, seed 1234, F16 KV, context 512; equal layer split. These are short-run measurements, not a long-duration production qualification.

| Path | Prompt tok/s | Decode tok/s |
|---|---:|---:|
| Stock, one die | 60.4 | 40.4 |
| Stock, two dies | 45.8 | 20.8 |
| Shim, one die | 60.4–60.8 | 40.5–40.6 |
| Coherent baton, two dies | 47.0–47.8 | 21.6–21.8 |
| Stock, pipeline parallelism disabled | 46.07 | 21.20 |
| Baton, coarse decode submissions | 47.2 | 21.8 |

The coherent baton improved the measured two-die decode rate only slightly. It did not restore one-die throughput. Disabling pipeline parallelism also changes the scheduler's event/copy behavior, so that experiment did not isolate graph reuse from asynchronous handoff.

Coarse batching reduced instrumented submissions from **658 to 386 (41.3%)**, with the recorded shader dispatch/workgroup totals unchanged, while decode stayed approximately **21.8 tok/s**. Those counts include instrumented graph phases; they are not an exact per-decode-token accounting. Submission count alone did not explain the remaining penalty.

The measured boundary payload was **30,720 bytes across 21 regions**. The SDMA copy took approximately **0.007 ms**, with measured producer-completion-to-copy-start gaps of **0.15–0.44 ms**. The roughly 22 ms/token performance deficit was not explained by that measured transport interval. These timestamps do not account for every consumer wait, host read, or driver scheduling interval; independent device clocks were not directly subtracted.

Earlier approximately 64–71 tok/s unordered/aliased runs produced incoherent text. They are failed correctness tests, excluded from performance claims. Cross-vendor coherent execution was demonstrated, but its short-run throughput did not demonstrate a speedup. Four-die production inference was not qualified.

## What failed, and what remains unknown
The performance objective failed. The experiment measured severe scaling loss in this ggml-vulkan/driver/hardware configuration, including after an application GPU baton replaced the boundary bridge. The residual cause was not established. Neither “PCIe is slow,” “all CPU waits are eliminated everywhere,” nor “a specific WDDM bug caused it” is supported by these receipts.

The independent SD1.5 comparison measured DirectAI at 1.681–1.838 seconds and stock sd.cpp Vulkan at 4.810–4.900 seconds for the comparable six-step workload. The original ONNX and GGUF weights were not fully identical, and each UNet ran on one die. This is evidence about the tested implementations, not a universal DirectML-versus-Vulkan verdict or a completed multi-die UNet benchmark.

The error was treating separate smoke tests as sufficient evidence that composition would preserve their performance. Native runtime mutation also increased ABI, lifetime, and provenance complexity without closing the performance gap. Once coherent transfer and coarser submission experiments failed to recover throughput, continued expansion of the shim had no demonstrated product payoff.

## Disposition
Windows driver preparation, device probes, and DirectML GEMM verification remain supported. ggml/Vulkan interception sources, historical receipts, and the original autopsy are retained in [ggml-vulkan](../ggml-vulkan/README.md). Original immutable proofs remain at their original paths under `GGML/Vulkan/Proofs`.

No new Vulkan inference backend or shim work is planned here. DirectAI is the separate inference project. Its next work starts with whole-graph seam analysis and compiled boundary contracts, with explicit correctness and latency gates.

## Evidence
- [Original detailed autopsy](../ggml-vulkan/docs/original-autopsy-20261001.md).
- [Integration receipts and source](../ggml-vulkan/experiments/codex-baton-integration-20261001/).
- [Preserved historical receipts](../ggml-vulkan/Receipts/).
- [Immutable proof hashes](../ggml-vulkan/receipts/immutable-proofs.json).
- [Benchmark summary](benchmarks.json).
