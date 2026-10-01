# AGENTS.md — Repository Invariants & Operational Law

> **MANDATORY DIRECTIVE FOR ALL AGENTS AND RUNTIMES IN THIS REPOSITORY**
>
> **FUCK OFF WITH YOUR CPU SYNC SHIT.**
>
> The CPU is NOT allowed to synchronize, wait on fences, stall, poll, or drain queues across multi-GPU boundaries during execution.

---

## 1. Zero CPU Synchronization Law

1. **The CPU is Not a Synchronizer**:
   - The CPU's role in multi-GPU inference is strictly non-blocking command recording and asynchronous submission.
   - Under NO circumstance may an agent or code path insert `ggml_vk_synchronize()`, `vkQueueWaitIdle()`, `vkDeviceWaitIdle()`, or CPU fence spin-waits between layer splits or across GPU boundaries.
   - Halting the CPU to bridge two GPUs destroys pipelining and collapses inference throughput.

2. **Causality Must Be GPU-to-GPU**:
   - All ordering dependencies between GPUs must be enforced in hardware or GPU silicon.
   - Multi-GPU communication operates through the shared pinned host aperture (`VK_EXT_external_memory_host`).
   - If ordering is required across GPUs, it must be enforced through GPU-native mechanisms (hardware semaphores, GPU memory barriers, or GPU-side atomic spin-wait kernels), NEVER by waking up or stalling the CPU host thread.

3. **No Dual Buffering / CPU Staging Bounce**:
   - Never allocate temporary staging buffers to copy data back to host memory via CPU `memcpy()`.
   - Data movement across dies uses direct hardware SDMA into the shared pinned memory aperture.

---

## 2. Inviolable Repository Rules

1. **Proofs Are Immutable**:
   - Never modify or overwrite files in `c:\dev\V340L-Emancipated\GGML\Vulkan\Proofs\`.
   - Proofs represent established empirical truth. If new experiments are needed, create new files.

2. **No Assumptions & Explicit Executables**:
   - Never default to ungrounded system PATH assumptions. Always use explicit disk paths (e.g., `C:\bin\pwsh\pwsh.exe`, `C:\bin\llama.cpp\llama-bench.exe`).

3. **Facts & Numbers Only**:
   - No opinions, no self-prompting in success messages, no speculation.
   - Report only measured timings, compilation outputs, token rates, and verified facts.

4. **No Circular Loops**:
   - Do not repeatedly re-read or inspect files that have already been examined.
   - Execute, measure, verify, and report.

## Current repository scope
This repository is V340L-Enablement: Windows driver preparation and device/operator verification. The closed inference experiment is archived under ggml-vulkan/. The zero-CPU-sync law applies to any multi-device execution experiment; terminal standalone diagnostic readback is not a cross-device bridge. Do not modify or relocate the original GGML/Vulkan/Proofs files. No new Vulkan inference implementation is planned here.
