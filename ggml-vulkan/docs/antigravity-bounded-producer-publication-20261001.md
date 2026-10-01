# Bounded task: submit the real producer aperture copy before the hardware baton

The target remains coherent layer-split inference across four V340L dies with the approximately 20 ms CPU boundary stall removed. Decode throughput must ultimately be compared with one-die inference on the same model and prompt. This task owns only producer publication for the first two-die boundary. Codex owns runtime provenance and full llama integration.

## Established by Codex, not assumptions

- Isolated native runtime: `C:\dev\V340L-Emancipated\scratch\codex-baton-20261001\runtime`.
- Actual loaded ggml/llama modules came from that directory. See `native-init-receipt.json` and `cli-entry-modules.json` alongside it.
- Vulkan SHA256: `AE67DDD85CC9C0E777FA76368E1A63AD90DDD4B97709CBC5C46F734F97C5248E`.
- CLI reports build 11223 / commit `4da633776`. The installed `C:\bin\llama.cpp\ggml-vulkan.dll` has a different hash and is excluded.
- Both existing emitted native init callbacks pass against real stock backends. Device init offset is `0x28`; backend async-copy offset is `0x38`.
- A bounded real Gemma run with `--no-warmup -c 512 -n 1` reached both init callbacks, the producer graph and first async-copy callback. The captured stock same-device copy returned true. The diagnostic intentionally exited 88 before signal/wait or consumer execution. Logs: `copy-record.log`, `cli-entry.log`. This is not completed inference or a throughput result.
- Crucial stock behavior: `ggml_backend_vk_cpy_tensor_async` calls `ggml_vk_buffer_copy_async` on the compute recording context and returns true. It does not end or submit that recording context. The current shim's subsequent empty signal submission therefore does not publish the recorded copy. Do not use that sequence as a completion baton.

## Deliverable and ownership

Create a separate PowerShell-emitted native publisher module under `C:\dev\V340L-Emancipated\scratch\antigravity-publisher-20261001\`. Use `PersistedAssemblyBuilder` or emitted IL; no Roslyn, MSBuild, C++ rebuild, DLL replacement, or new inference engine. Do not edit Codex's isolated snapshot, the existing launcher/emitter, or any files under `GGML\Vulkan\Proofs`.

Expose an explicit setup operation and a native-callable batch publication operation. Inputs must include the real backend-created producer VkDevice, compute queue/family, dedicated transfer queue/family, permanent producer aperture VkBuffer, imported D3D12-fence semaphore, publication value, and a bounded list of `{source VkBuffer, source offset, arena offset, byte count}`. Record/submit GPU work and return a checked status without a CPU completion wait. Return the consumer wait requirement to the caller; do not claim that publication alone satisfies the complete async-copy contract.

### Native buffer seam already tested

For this exact x64 stock build:

1. `ggml_tensor.buffer`: offset `0x08`.
2. `ggml_backend_buffer.context`: offset `0x60`.
3. `ggml_backend_vk_buffer_context.dev_buffer` shared-pointer object pointer: offset `0x10`.
4. The pointed-to `vk_buffer_struct` starts with native `VkBuffer` at offset `0`; mapped host pointer at `0x18`; buffer size at `0x20`.

Codex applied this chain to both real imported aperture buffers, checked the host pointer and size, and called `vkGetBufferMemoryRequirements` with the extracted native handles. Both reported 33,554,432 bytes and alignment 4. See `buffer-abi-receipt.json`. Validate resident source tensors too; this receipt directly covers the aperture imports only.

For source views preserve stock addressing: use `view_src->data` when `view_src` exists, otherwise `data`; subtract `0x1000`, then add `view_offs`. Tensor offsets are `view_src=0xE8`, `view_offs=0xF0`, `data=0xF8`. Keep all ranges within their actual native buffers.

## Required GPU order

```text
Already-submitted producer graph on stock compute queue
  -> producer release / readiness signal on that queue
  -> dedicated SDMA queue GPU wait + ownership acquire where required
  -> batched vkCmdCopyBuffer into permanent aperture
  -> release publication + imported D3D12 fence signal
  -> consumer compute queue GPU wait before its graph
```

- Do not call the stock copy recorder and immediately signal an empty submission.
- Use actual captured queue families. Current launcher selects compute family 1; the earlier standalone fixture used family 0. Do not transplant the fixture's compute family.
- Establish stock buffer sharing mode from the pinned source/native creation path. The previous SDMA proof used concurrent source buffers; that does not establish stock buffer ownership. For exclusive sources, implement the paired compute-to-transfer ownership barriers and transfer-to-compute return dependency before subsequent producer use. No host waits or guessed ownership.
- Check every `VkResult`. Do not discard submission failures or return false into ggml's blocking copy fallback. Report a hard mechanism failure to the integration caller.
- Keep command buffers, semaphore objects, region metadata and imported memory alive. Any command/storage reuse must have an explicit GPU retirement dependency. For the first-boundary proof allocate bounded unique command/storage resources and stop before reuse; no blind ring wraparound.
- Consumer reads the imported aperture directly. No CPU activation memcpy, host staging bounce, or aperture-to-consumer-local scratch copy.
- Batch the boundary's tensors into one publication value; do not introduce a GPU baton for each tensor as the final implementation.

## Bounded verification and stop point

Verify one actual producer publication and consumer GPU wait using these stock-created devices/buffers. Keep CPU recording/submission time separate from GPU completion time. A bounded terminal observation after all submissions is acceptable; no intermediate host polling, fence waits, queue/device idle, or backend synchronization.

Return the module, invocation example, exact queue/buffer identities, checked submit results and a receipt that distinguishes recorded work from submitted work and consumer execution. If a needed native seam is unavailable, identify it precisely and stop. Do not broaden into an engine rewrite, four-device enumeration, throughput tuning or edits to the existing experiment.

Codex will integrate the publisher at the consumer graph seam, retain exact tensor identities/lifetimes, enable default F16 KV, then run deterministic 32-token inference and audit CPU boundary waits before reporting any speedup.
