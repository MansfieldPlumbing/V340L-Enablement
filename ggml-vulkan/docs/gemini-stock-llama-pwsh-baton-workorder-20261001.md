# Work order: stock llama.cpp, PowerShell runtime mutation, GPU boundary synchronization

## Objective and scope

Remove the approximately 20 ms CPU synchronization penalty between layer stages of a model split across V340L devices. Preserve stock llama.cpp model loading, graph construction, layer placement, Vulkan kernels, resident weights, and KV behavior. Implement the handoff through runtime mutation installed by PowerShell, with the shared pinned host aperture carrying activations and a D3D12-created fence providing GPU ordering.

Work in `C:\dev\V340L-Emancipated`. Follow its `AGENTS.md`. Antigravity is already investigating this path: inspect the current working state before editing and do not overwrite its changes. Do not modify files under `GGML\Vulkan\Proofs`.

The deliverable is a new, self-contained PowerShell launcher/shim and measured receipts. Do not rebuild or replace stock llama/ggml DLLs, edit upstream C++, introduce generated C#, replace the inference engine with DirectML/ORT, or create a new backend as a substitute for this task. PowerShell may emit IL/RyuJIT callbacks and allocate native structures. Hot-path callbacks must execute without returning to the PowerShell interpreter, and must remain valid when called from native worker threads.

If the required native seam cannot be intercepted at this layer, report the exact missing seam and the evidence. Do not substitute a CPU wait, destination activation copy, or unordered early return and label it success.

## Existing evidence and code to reuse

These are starting points, not instructions to repeat every experiment:

- `GGML\Vulkan\Measure-LlamaVulkanAperture.ps1`: existing in-process stock DLL launcher, emitted IL backend-factory/copy hooks, permanent host aperture imports, and destination tensor aliasing. Its existing unordered mailbox mode is not a correctness implementation.
- `Test-V340CrossAdapterFence-20261001.ps1`: native D3D12 fence creation/export and Vulkan import/submit ABI. Same-device and cross-device empty-submit baton tests passed.
- `GGML\Vulkan\Test-ResidentVramSdmaBaton-20261001.ps1`: resident VRAM, compute-to-dedicated-transfer ordering, aperture copies, imported cross-adapter fence, and consumer verification shader. Saved receipts report 5376 verified words across 21 regions with zero mismatches on pairs 0→1, 0→2, 1→2, and 2→3. Receipt names do not establish physical card grouping; map devices by LUID.
- `GGML\Vulkan\ArenaFooterVerify-20260930.comp` / `.spv`: existing diagnostic verifier. Preserve it; create a new diagnostic file if changes are necessary.
- `docs\antigravity-d3d12-vulkan-baton-receipt-20261001.md`: exact tested fence ABI and limits.

Use explicit executable paths, including `C:\bin\pwsh\pwsh.exe`. The model is `C:\Models\gemma-4-E4B-it-Q4_K_M.gguf`.

The saved stock Vulkan DLL is `C:\bin\llama.cpp\ggml-vulkan.dll.stock`, 45286400 bytes, SHA256 `AE67DDD85CC9C0E777FA76368E1A63AD90DDD4B97709CBC5C46F734F97C5248E`. The installed `ggml-vulkan.dll` has been modified during earlier experiments; do not mistake it for stock. Validate all runtime DLLs and the exact ABI/build used. The earlier harness is pinned to build 11223 / commit 4da633776. Do not apply its private offsets to another build without validation.

Use an isolated runtime directory or another verified loading arrangement to select the original DLL without overwriting the installed DLL. Stock binaries on disk must remain unchanged. The local `llama-cli-impl.dll` exports `?llama_cli@@YAHHPEAPEAD@Z`; the existing harness calls that entry point inside the PowerShell process. Calling `llama-cli.exe` as a separate child does not carry over in-process pointer mutations.

## Required physical path

```text
Producer Vulkan compute finishes the source activations
    ↓ local GPU dependency, with correct queue-family access
Producer dedicated transfer queue copies the batch into the permanent aperture
    ↓ Vulkan submission signals an imported D3D12-created fence
Consumer Vulkan submission waits on that fence
    ↓
Consumer graph reads the imported aperture at the correct tensor offsets
```

D3D12 is a setup component: create its device, fence, and shared handle once and retain them. It does not need a per-boundary relay queue, DirectML dispatch, CPU completion worker, or P2000 sidecar.

CPU synchronization, fence polling, queue draining, and CPU activation copies are forbidden between stages. The consumer must read the imported aperture directly; an aperture-to-destination-local activation copy is a different mechanism and is outside this order.

## Implementation sequence

### 1. Establish the actual stock synchronization site

Capture a minimal layer-split stock run in process. Identify the cross-device async-copy callback, consumer graph submission, and the host completion path reached for that handoff. Record callback pointers and selected device identities. Distinguish the stock scheduler's failed-async-copy fallback from the `ggml_vk_fence_spin_wait` in the modified aperture backend; do not patch a function that exists only in the custom DLL and call it a stock mutation.

Use the existing tensor metadata to derive sizes, views, strides, source buffer offsets, destination aliases, and arena offsets. Do not hard-code 21 tensors as a universal contract. It is a model/run observation, and prefill geometry differs from single-token decode.

### 2. Hook initialization before stock Vulkan device creation

Install the hook before any stock Vulkan backend/device initialization. Ensure its actual `VkDeviceCreateInfo` enables `VK_KHR_external_semaphore_win32` and the required dependencies for the API version, while preserving all original extensions, feature chains, and queue requests. Ensure the aperture extension is enabled as well.

The inspected initializer omits the Win32 external-semaphore extension; the saved stock DLL has no corresponding extension-name literal. A fresh sidecar device does not retrofit extensions into llama's already-created Vulkan devices. Intercept the native call path actually used by the stock DLL, including dynamically resolved Vulkan function pointers where applicable. Merely binding a replacement delegate in PowerShell does not redirect existing native callers.

Capture the stock Vulkan devices/queues and match their physical identities by LUID. Import the shared fence into those devices; do not assume stock llama will adopt separately created Vulkan devices.

### 3. Create and retain the tested baton

Create a D3D12 fence at initial value 0 with:

```text
D3D12_FENCE_FLAG_SHARED | D3D12_FENCE_FLAG_SHARED_CROSS_ADAPTER = 3
```

Export using `ID3D12Device::CreateSharedHandle`. Permanently import into ordinary binary Vulkan semaphores using `VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_D3D12_FENCE_BIT = 8`. Local capability queries did not advertise timeline imports for this handle type; retain the binary import mechanism that passed the hardware tests.

Use `VkD3D12FenceSubmitInfoKHR` to supply explicit uint64 wait/signal values on submissions. Use fresh increasing publication values. For a multi-boundary pipeline, give each independently signaling boundary its own fence unless a single-writer ordering contract has been proved; avoid unrelated queues signaling one shared timeline out of order.

Checked x64 ABI:

- `VkImportSemaphoreWin32HandleInfoKHR`: 48 bytes; sType 1000078000; semaphore at 16, flags at 24, handle type at 28, handle at 32, optional name at 40.
- `VkD3D12FenceSubmitInfoKHR`: 48 bytes; sType 1000078002; wait count at 16 and values pointer at 24; signal count at 32 and values pointer at 40.
- `VkSubmitInfo`: 72 bytes. Preserve existing waits/signals/command buffers and pNext structures when adding the baton; do not discard stock dependencies.
- `VkDescriptorSetAllocateInfo`: 40 bytes on x64.

### 4. Translate the specific boundary wait into GPU dependencies

The target behavior is:

```text
llama requests the layer-boundary synchronization
    → the shim ensures producer publication and consumer GPU wait are queued
    → the shim returns without host completion observation
    → the receiving GPU waits before consuming the activation batch
```

This is a targeted translation, not a fence-pointer substitution. A CPU polling a D3D12 fence still stalls. A generic `synchronize()` callback still promises completion to its caller, so do not replace all synchronization callbacks with a no-op or an asynchronous queue wait.

Claim cross-device `cpy_tensor_async` success only after establishing both halves of the contract: producer work precedes the aperture copy, and subsequent consumer work waits for its publication. Attach the GPU wait before the consumer submission executes, while allowing CPU recording/submission to continue. Preserve the stock graph/kernel callback.

### 5. Preserve ownership and retirement

Audit what the original host wait protects before returning early. Retain command buffers, command pools, copy contexts, source tensors, tensor aliases, fence values, and arena regions until their final GPU users retire. Do not immediately reset/free/recycle objects formerly protected by the CPU wait.

The resident-source proof uses concurrent sharing across compute and transfer queue families. Verify the actual stock source buffer's sharing mode; establish proper GPU queue-family ownership transfer for exclusive buffers rather than assuming the diagnostic buffer configuration applies.

Keep one permanent aperture with graph-derived offsets. Do not introduce staging buffers, dual buffering, or arbitrary rings. Reuse storage only behind the concrete required GPU dependency. Prefer the existing bounded no-reuse arrangement for the first finite correctness test if capacity permits. If using no-reuse offsets, record the capacity and terminate cleanly before exhausting it.

### 6. Validate one real boundary before throughput claims

First verify one real Gemma receiving boundary against a correct reference with identical model, inputs, token position, and tensor geometry. Keep diagnostic observation after the finite GPU submission chain; do not insert CPU readback or comparison between producer and consumer as an ordering bridge.

Then run deterministic generation in the in-process stock runtime using a fixed seed and greedy sampling, with a short identical prompt such as `The capital of France is` and 32 generated tokens. Save the complete text and token IDs if available. Require coherent output and the same model/tokenizer/control-token configuration. Cross-device numerical precision can affect exact token identity; explain any discrepancy using receiving-tensor/logit evidence rather than accepting gibberish as performance.

Measure generation and prefill separately. Do not compare the earlier one-shot PowerShell API-call timings or terminal fence observation time with the claimed approximately 20 ms inference boundary cost. Record CPU callback/submission time and GPU work separately; do not subtract timestamps from different devices without calibration.

## Acceptance gates

1. Original runtime DLLs remain unchanged; record paths and hashes actually loaded.
2. Mutation is installed before Vulkan device creation, with required extensions verified on the actual stock call path.
3. Real model handoffs traverse resident source → dedicated transfer → permanent aperture → direct consumer read.
4. GPU publication and consumer wait are attached to the actual inference submissions.
5. Zero CPU fence polls, host completion waits, queue-idle/device-idle calls, and CPU activation copies bridge those stages. Terminal observation/teardown is reported separately.
6. No stock blocking-copy fallback executes for claimed handoffs.
7. Resource lifetimes and any storage reuse remain valid after removal of the host completion guarantee.
8. Real boundary correctness and coherent deterministic generation pass before reporting generation throughput as a success.

## Deliverables

- A new PowerShell launcher/shim outside `Proofs`, with emitted IL callbacks rooted for the entire native run and reversible pointer mutations restored when safe.
- Machine-readable receipts naming the build, runtime hashes, LUIDs, enabled extensions, intercepted callbacks, handoff counts, actual byte path, publication values, host bridge-wait/fallback counts, full generated output, and separate prefill/generation rates.
- A concise report stating what passed, what remains unproved, and the exact missing native hook if the stock path cannot be intercepted. Do not silently broaden the task to a fork, new backend, or alternate engine.
