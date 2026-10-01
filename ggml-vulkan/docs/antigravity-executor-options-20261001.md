# Execution boundary investigation — 2026-10-01

**Later execution result:** the native D3D12 shared-heap transport test passed, and a D3D12-created cross-adapter fence imported into binary Vulkan semaphores passed both same-device and cross-device empty-submit tests. See [the execution receipt](antigravity-d3d12-vulkan-baton-receipt-20261001.md). The earlier UUID-based rejection below is superseded for this measured local driver path; direct Vulkan aperture payload consumption remains untested.

## Required result

Correct Gemma inference through sequential V340L stages, within the user's approximately 37 GB usable VRAM budget. Inter-stage submission must not require CPU fence waits, polling, queue draining, or CPU activation copies. Weights and KV data remain resident on their assigned dies; boundary activations use a permanent shared arena. A single-GPU baseline does not establish this multi-GPU result.

## DPX's role

The user identifies `C:\dev\dpx\dpx-cs` as the working Gemma implementation and the C++ implementation as broken. Treat the C# implementation as the model and decoding reference. No DPX generation benchmark was performed in this investigation.

The current C# D3D12 matrix wrapper uploads input activations, dispatches a matrix operation, copies results to readback, spins on `GetCompletedValue`, and returns CPU arrays (`GpuD3D12.cs`, approximately lines 337–360). Resident weight caching already exists; repeated weight upload is not established as the problem. This per-operation interface does not provide an asynchronous multi-die graph executor. Merely substituting DirectML for the matrix dispatch retains the surrounding CPU round trip.

## Option A: keep llama.cpp, own an external backend

The checked-out ggml source exposes these seams:

- `ggml_backend_load_all_from_path` loads the DLL named by `GGML_BACKEND_PATH` (`ggml-backend-reg.cpp:600–603`).
- The module exports `ggml_backend_init`; the loader checks the backend API version (`ggml-backend-reg.cpp:237–253`). The inspected interface uses API version 2.
- The backend interface includes asynchronous copies, graph compute, event record/wait, and allocation dependency declarations (`ggml-backend-impl.h:111–155`).
- The scheduler synchronizes if async copy is unavailable or returns false (`ggml-backend.cpp:1785–1792`). It also has explicit completion guards for allocation reuse (`1661–1668`).

Therefore a separate backend module is an exposed integration point. Suppressing `synchronize` does not satisfy its completion contract. Loading a complete external module into the installed executable has not been tested here.

Design to evaluate: expose one logical pipeline device to ggml, with physical die placement, graph partitioning, permanent arena offsets, command queues, and resource retirement owned inside that backend. This moves physical stage boundaries out of ggml's multi-backend scheduler. It does not remove GPU causality requirements or make graph allocation automatically safe. The backend must retain every source, destination, arena region, and command allocation until its final GPU consumer has retired. CPU fallback nodes inside the pipeline must be detected, since they reintroduce a host boundary.

An out-of-tree backend still requires implementation and version maintenance. Vulkan shaders and backend code may be reused where appropriate; DirectML does not automatically execute GGUF Q4_K weights or translate all ggml operations.

## Option B: use an existing DirectML LLM runtime

ONNX Runtime GenAI provides tokenization, the generation loop, sampling, and KV cache management. Microsoft documents DirectML LLM execution with that runtime. The Generate API is preview. This is an existing engine to test before writing another one:

- https://onnxruntime.ai/docs/genai/
- https://learn.microsoft.com/en-us/windows/ai/directml/dml-get-started

DirectML itself is a low-level D3D12 operator/graph library. The ORT DirectML provider can use an application-supplied `IDMLDevice` and `ID3D12CommandQueue` through `SessionOptionsAppendExecutionProvider_DML1`:

- https://onnxruntime.ai/docs/execution-providers/DirectML-ExecutionProvider.html

That factory does not establish non-blocking multi-adapter session execution. ORT's internal completion behavior and tensor ownership must be verified before using sessions as asynchronous pipeline stages. No compatibility result exists here for the local Gemma ONNX/SQLite model packaging or this V340 driver. The DirectML EP remains supported in sustained engineering; new Windows deployment feature development has moved to WinML.

## Next bounded experiment: native D3D12 ordering and arena visibility

Before converting the LLM, test the transfer/control contract independently of model math:

1. Select two distinct V340 adapters by verified DXGI identity. Create native D3D12 devices and queues.
2. Create one permanent cross-adapter shared heap and a placed buffer with the required shared/cross-adapter heap and resource flags. This is a D3D12 system-memory arena; it is not proof that the existing Vulkan imported host allocation can be reused unchanged.
3. Create a fence with `D3D12_FENCE_FLAG_SHARED | D3D12_FENCE_FLAG_SHARED_CROSS_ADAPTER`, export its handle, and open it on the consumer device. Record HRESULTs.
4. On the producer GPU, generate a deterministic payload and trailing manifest, then transfer to the shared arena. Apply the required resource barriers and queue-signal the packet sequence after publication.
5. Queue `ID3D12CommandQueue::Wait` on the consumer for that sequence, then run a consumer shader that reads the shared arena and verifies every payload word and manifest field. The queue wait returns immediately to the CPU; the GPU performs the wait.
6. Start with 32 packets at distinct offsets in that same arena, with no region reuse. Record and submit all inter-stage work without CPU completion checks. Read diagnostic results only after the finite experiment has completed; no readback bridges stages.
7. Report payload sizes, HRESULTs, mismatch counts, CPU submit durations, and per-device GPU durations. Do not subtract timestamps from different adapters without calibration. Extend to GPU-controlled region reuse only after this publication/visibility test passes.

D3D12 explicitly documents cross-adapter fences, non-blocking CPU queue waits, and coherent cross-adapter shared heaps:

- https://learn.microsoft.com/en-us/windows/win32/api/d3d12/ne-d3d12-d3d12_fence_flags
- https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12commandqueue-wait
- https://learn.microsoft.com/en-us/windows/win32/direct3d12/shared-heaps

This experiment is proposed, not executed. Driver support, performance, and suitability for DirectML tensor binding remain unmeasured.

## Vulkan correction carried forward

The per-device external semaphore feature flags previously collected do not establish cross-die interoperability. Vulkan's Win32 opaque and D3D12-fence semaphore handle compatibility rules require matching device UUIDs, whereas the four distinct V340 dies have different UUIDs. Native D3D12 cross-adapter fence support is a different API contract; do not infer Vulkan interoperability from it.

- https://docs.vulkan.org/spec/latest/chapters/capabilities.html
- Local identity receipt: `GGML/Vulkan/Receipts/device-identities-20261001-after-restart.json`

## Acceptance gates

First prove coherent GPU-to-GPU publication and consumption with zero CPU bridge waits. Then prove a real Gemma stage against the working C# reference, including tensor layouts and KV updates. Then integrate full generation and measure end-to-end inter-stage cost. Coherent tokens and verified ordering are required before a throughput number qualifies as inference performance.
