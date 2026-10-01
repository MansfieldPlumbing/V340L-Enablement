# Bounded experiment: stock runtime interception, SDMA arena, binary GPU baton

> CORRECTION — 2026-10-01: The binary semaphore capability flags below do NOT establish a supported cross-physical-device route. The Vulkan external semaphore compatibility table requires matching driverUUID AND deviceUUID for OPAQUE_WIN32, OPAQUE_WIN32_KMT, and D3D12_FENCE semaphore handles. The four distinct V340 dies have distinct deviceUUIDs. Consequently, the proposed cross-die Win32 binary semaphore test below is not a supported portable Vulkan path; do not proceed on the strength of its per-device feature flags. The aperture HOST_ALLOCATION memory handle has no such UUID restriction, but still needs a separately established GPU completion/visibility mechanism. A P2000 relay does not remove this restriction. Any driver-specific experiment must be identified as such rather than represented as spec-supported. Source: https://docs.vulkan.org/spec/latest/chapters/capabilities.html#_external_semaphore_handle_types_compatibility

This is an experiment specification, not a completed inference fix. No throughput target is promised. Preserve `GGML/Vulkan/Proofs/` unchanged. Do not replace the current installed binaries during this experiment.

## User corrections and post-restart identity evidence — 2026-10-01

The user specifies a 37 GB VRAM budget and sequential layer stages, with the participating dies used as a pipeline rather than simultaneous compute stages for this single stream. Do not use a 64 GB capacity claim or sum four HBM peak bandwidths to describe this execution. The user clarified the bandwidth unit as gigabytes per second (200–400 GB/s), and identified the actual llama.cpp problem as the approximately 20 ms pause between dies. Prioritize eliminating that handoff stall; do not turn the task into an HBM bandwidth benchmark or a request for 200–400 GB/s over PCIe.

The acceptance criterion belongs to the real inference handoff: coherent deterministic output, no CPU synchronization across the die boundary, GPU ordering at both producer-compute-to-SDMA and SDMA-to-consumer edges, and measured handoff timing. Capture CPU callback/submission times and GPU stage timestamps; do not subtract timestamps across independent devices without valid calibration. A fast standalone copy or a timer ending before consumer execution does not establish removal of the inference stall.

Existing `Proofs/results.md` reports 12.02 GB/s as aggregate TWO-LEG traffic, explicitly not useful payload bandwidth. Do not cite it as a 12.02 GB/s end-to-end activation rate.

A fresh read-only capability query again found binary opaque Win32/KMT export and import support, and no external timeline support for the tested handles. Corrected identity enumeration found four distinct V340 device UUIDs, plus a fifth V340-labelled entry that repeats ordinal 0's UUID with a different LUID. Ordinals 0/3 contain UUID bytes 0x69/0x6c and ordinals 1/2 contain 0xba/0xb7; no PCI-bus or card correspondence is established solely by this result. All reported V340 API versions decode to Vulkan 1.3.217. Each enumerated V340 device group contained one member. Raw receipts are `GGML/Vulkan/Receipts/semaphore-capabilities-20261001-after-restart.json` and `GGML/Vulkan/Receipts/device-identities-20261001-after-restart.json`.

The pasted identity probe used `VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ID_PROPERTIES=1000071000`; the installed SDK value is 1000071004. Its group probe used a 272-byte stride; the Windows x64 structure requires 288 bytes, physicalDevices begins at offset 24, and subsetAllocation is at offset 280. Re-establish any mapping derived from those probes. Select devices by verified identity and ggml mapping, not by pre-restart ordinal alone. This does not change the first test: one verified pair and 32 non-reused packets.

## New measured capability evidence

`GGML/Vulkan/Query-V340SemaphoreCapabilities-20260930.ps1` queried AMD V340 physical ordinals 1 and 2, explicitly filtering vendor 0x1002 and name V340. Both reported:

| Semaphore type | Win32 opaque | Win32 KMT | D3D12 fence |
|---|---|---|---|
| Binary | export + import (features=3) | export + import (features=3) | import only (features=2) |
| Timeline | neither (features=0) | neither (features=0) | neither (features=0) |

Both advertise external-memory-host, external-semaphore-win32, timeline-semaphore, and Vulkan-memory-model extensions. Advertising timeline semaphores does not establish support for exporting timeline semaphores. Raw results: `GGML/Vulkan/Receipts/semaphore-capabilities-20260930-discussion.json`.

This query creates no logical devices, submits no GPU work, and waits on no queues or fences. Export/import and useful payload visibility still require an execution test. Physical ordinals are not a substitute for verifying ggml's device mapping.

## Physical route and footer

Keep the working drain's permanent host allocation imported into both dies. For the initial diagnostic, use unique non-overlapping packet regions for the entire bounded run; no ring reuse and no destination-local payload copy. This removes overwrite/reuse from the first question.

Each packet contains 21 aligned payload regions followed by a fixed-location footer:

`magic | batch sequence | entry count | payload end | {offset, length, pattern base, pattern step}[21]`

All quantities consumed by the diagnostic shader are uint32 words, not bytes. Producer VRAM contains different known patterns in each region, changing with batch sequence. The producer SDMA copies those regions into the arena, then writes the complete footer LAST with a transfer-to-transfer dependency. Signal an external binary semaphore only after the payload and footer work. The consumer waits on its imported semaphore before reading either.

The footer is an inert manifest until the GPU baton releases its consumer. It is not executable SPIR-V and is not, by itself, a portable cross-device memory barrier. Metadata may be authored by the CPU before submission; payload movement and readiness must remain GPU operations.

## First test: prove the baton with the existing transport

1. In a new PowerShell C-ABI harness, select the same verified V340 pair. Create devices with the required supported external-memory and external-semaphore extensions enabled at creation. Use correct SDK structure types. Create an exportable BINARY semaphore, export `OPAQUE_WIN32`, and permanently import its payload into the consumer. Do not chain timeline semaphore creation information.
2. Use a bounded pool of separate binary semaphore payloads, one per packet, retained for the entire test. Never signal an already-signaled binary payload or assign one signal to multiple waits. No host wait is required to recycle semaphores because this first test does not recycle them.
3. Establish the producer-compute-to-SDMA GPU dependency too. Generate the source patterns with GPU compute, then have the transfer submission wait on a producer-local semaphore. Express source-buffer release/acquire ownership if exclusive buffers move between different queue families. Compute completion must precede SDMA reads; enqueue order across queues alone is insufficient.
4. Submit SDMA payload and footer writes, followed by the external binary signal. Express the imported-memory availability/visibility and ownership requirements for the actual devices and allocation. Do not treat two devices' numeric queue-family indices as one ownership domain.
5. Submit consumer work waiting on the imported binary semaphore at ALL_COMMANDS for this first diagnostic. Dispatch exactly one workgroup of `ArenaFooterVerify-20260930.spv`. Bind the aperture directly as storage-buffer binding 0; binding 1 is a separate diagnostic result buffer. Push constants are four uint32 values: footerWord, expectedSequence, arenaWordCount, resultWord.
6. Results contain eight uint32 words per packet, initialized once before submission to `{0,0,0xffffffff,0,0,0,0,0}`. Allocate descriptor ranges and push constants so all shader accesses are in bounds. Expected pass: error flags=0, mismatches=0, observed sequence/count match, examined words equal the sum of region lengths. CPU reads only the small diagnostic results after the full bounded sequence has been submitted and completed; no CPU completion observation between producer and consumer submissions.
7. Queue 32 packets with unique offsets and changing patterns. The CPU only records and submits during the chain. No CPU polling, fence spinning, queue-idle waits, sleeps, or payload memcpy. Capture GPU timestamps on each die's operations; do not subtract timestamps from different devices without a valid calibration. A recording timer is not GPU completion latency.

Stop after the bounded test. On failure, report the first failing Vulkan operation/result or packet invariant. Do not switch to a CPU wait, destination scratch path, or another API under the same experiment name.

The provided verifier compiled successfully and passed SPIR-V validation (both commands completed; combined exit code 0) with:

```powershell
& 'C:\bin\VulkanSDK-1.4.341.1\Bin\glslc.exe' --target-env=vulkan1.1 'C:\dev\V340L-Emancipated\GGML\Vulkan\ArenaFooterVerify-20260930.comp' -o 'C:\dev\V340L-Emancipated\GGML\Vulkan\ArenaFooterVerify-20260930.spv'
& 'C:\bin\VulkanSDK-1.4.341.1\Bin\spirv-val.exe' --target-env vulkan1.1 'C:\dev\V340L-Emancipated\GGML\Vulkan\ArenaFooterVerify-20260930.spv'
```

The shader is diagnostic code, not a GPU execution receipt. It checks every payload word and footer identity after the semaphore wait. It contains no shared-flag polling loop. No GPU dispatch of this verifier has been performed.

## Optional interlocking shaders on additional dies

The current capability query enumerated two V340 devices. Do not assume additional dies are available until enumerated and mapped.

A shader on a helper die could interpret manifests, verify completed packets, or coordinate multiple streams. It still needs a valid incoming completion edge and an outgoing edge releasing the actual consumer. Moving a shared-flag poll onto a helper die does not establish cross-device atomic scope, payload visibility, or producer ordering. Vulkan disallows SPIR-V CrossDevice scope; a vendor-specific aperture polling protocol would be a separate hardware experiment, not the portable replacement for a semaphore.

Use the supported external binary queue wait for the first gate. It needs no persistent helper shader. If a helper is later justified by measured useful work, first schedule it behind the incoming hardware semaphore, then signal an outgoing hardware semaphore. Include its work in end-to-end decode timing. Do not add another die solely to relay a completion event that can travel directly between the participating queues.

## Only after that passes: integrate through the runtime seam

Use a pristine pinned stock llama.cpp build in a separate directory. Keep PowerShell as the host harness and reuse the demonstrated ggml callback mutation. Capture actual source/destination tensor ranges at `cpy_tensor_async`; redirect selected consumer tensors to their imported aperture ranges, preserving views and layouts. Attach the producer and consumer GPU dependencies at actual submission boundaries.

Intercept device creation early enough to enable supported external semaphore extensions. A startup Vulkan layer can intercept device creation and queue submissions without rebuilding llama.cpp. A ggml callback patch alone does not enable missing device extensions or automatically expose Vulkan queue and buffer handles. Establish which handles the wrapper can access before writing the integration; if inaccessible, add only a narrow submission/device-creation shim rather than rewriting the backend.

Do not turn generic fence waits into unconditional success. Trace the selected boundary's immediate post-wait actions: fence resets, pool resets, command-context destruction, and allocator reuse. Preserve or defer those actions while their resources remain in flight. Keep tensor metadata, command buffers, and aperture allocations alive. Distinguish internal cross-die waits from terminal host output observation.

First inference gate: the same short prompt, 32 generated tokens, deterministic sampling, full text compared with a stock single-die reference, correct selected handoff counts, and zero host boundary waits. Record generation throughput only alongside that semantic outcome. No prefill expansion or second architecture experiment in this gate.

## Why the film analogy helps

DTS uses film timecode to identify playback position and an offset to account for reader-to-picture geometry. Interlocked projectors share a moving print with loop storage between mechanisms. The corresponding GPU concepts are packet identity, fixed offset geometry, buffered capacity, and a hardware release condition. Equal average speed or a fixed delay is insufficient to identify which activation belongs to the current token. A footer carries identity; the semaphore supplies the release condition; resource lifetime supplies the loop's capacity.

Sources:

- DTS-6D manufacturer manual: https://www.film-tech.com/warehouse/manuals/DTS6D.pdf
- Interlocking description: https://www.sprocketschool.org/wiki/Interlocking
- Vulkan shader scopes (CrossDevice is disallowed): https://docs.vulkan.org/spec/latest/chapters/shaders.html
- Vulkan memory model: https://docs.vulkan.org/spec/latest/appendices/memorymodel.html
- Device extension enabling: https://docs.vulkan.org/guide/latest/enabling_extensions.html
- Vulkan loader/layer interfaces: https://vulkan.lunarg.com/doc/view/1.4.304.1/windows/LoaderLayerInterface.html
