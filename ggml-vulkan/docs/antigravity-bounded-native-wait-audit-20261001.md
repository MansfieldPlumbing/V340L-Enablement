# Bounded work order: native boundary-wait audit

Goal: audit every native Vulkan host wait between the producer graph returning and consumer graph entering in the stock in-process llama pipeline. Preserve the existing aperture + SDMA + D3D12-fence mechanism. No architecture changes or CPU wait substitutions.

Read-only inputs:
- C:\dev\V340L-Emancipated\scratch\codex-baton-integration-20261001\New-IntegrationAssembly.ps1
- C:\dev\V340L-Emancipated\scratch\codex-baton-integration-20261001\Run-IntegrationTail.ps1
- C:\dev\V340L-Emancipated\scratch\codex-baton-integration-20261001\Launch-Integration.ps1
- C:\dev\V340L-Emancipated\scratch\codex-baton-20261001\New-V340LlamaBatonShimAssembly.ps1

Write only new files under scratch\antigravity-native-wait-audit-20261001. Do not modify these inputs, stock DLL files, or GGML\Vulkan\Proofs. Use explicit executable paths and PersistedAssemblyBuilder only; no C++, Roslyn, or MSBuild.

Deliver a small reusable emitted audit assembly and a bootstrap-integration guide. Intercept procedure resolution through vkGetInstanceProcAddr AND vkGetDeviceProcAddr so that stock cached dispatch tables cannot bypass the audit. Observe vkWaitForFences, vkWaitSemaphores, vkQueueWaitIdle, and vkDeviceWaitIdle. Preserve every original call outside the audited boundary. A wait requested inside the boundary must log its function and arguments then terminate the bounded test BEFORE calling the original function. Never replace an unfinished wait with success or query/poll the GPU.

Expose a persistent host phase word allocated during bootstrap. Integration sets it active AFTER the producer native graph call returns and clears it BEFORE consumer native graph entry. It remains active throughout tensor-copy preparation, publisher submission and consumer wait submission. Hook callbacks read this host word; this is host control state, not GPU completion polling. Include per-function total and boundary counters and verify a synthetic call hits the guard. Root delegates for the entire process.

Background: stock two-die control produces Paris and exits 0. Our forced 32-token continuation completed 35 publications / 735 GPU activation copies, exit 0; backend boundary guard zero. Existing terminal readback completion certificates allow eight redundant consumer event waits per subsequent token to be deferred, retaining native event resources. This does NOT yet establish zero native host waits beneath stock tensor input uploads. Find the first such request if present; do not solve it by adding staging, CPU waits, or disabling synchronization globally.

Publisher corrections already applied in our private snapshot: COMMAND_POOL_CREATE_INFO=39; COMPUTE_SHADER stage=0x800; D3D12 fence wait-value count=1 matching the local binary wait count. Do not transplant the older incorrect constants. Consumer waits currently use ALL_COMMANDS=0x10000 and include a GPU memory acquire command. Validation-layer runs still crash; normal runs complete. Report that difference accurately.

Return the emitted source + DLL + synthetic guard receipt + precise bootstrap hook installation instructions. Any actual model run must use a private copy and a unique receipt/log path. Do not run GPU benchmarks concurrently with Codex's comparison.