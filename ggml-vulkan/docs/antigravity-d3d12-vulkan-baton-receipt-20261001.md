# D3D12-created fence imported by two Vulkan dies: local execution receipt

The following tests executed on 2026-10-01. Existing Proofs files were not modified.

## Native D3D12 transport

Script: `C:\dev\V340L-Emancipated\Test-V340CrossAdapterFence-20261001.ps1`

Receipt: `GGML/Vulkan/Receipts/d3d12-cross-adapter-fence-20261001.json`

- Producer: DXGI 0, LUID `E9FC010000000000`.
- Consumer: DXGI 1, LUID `C370020000000000`.
- Both names: `Radeon Pro V340L 22Q4`.
- Fence flags: `SHARED | SHARED_CROSS_ADAPTER`, numeric 3.
- Shared-heap flags: `SHARED | SHARED_CROSS_ADAPTER`, numeric 0x21.
- All 32 consumer queue waits and diagnostic copies were submitted before any producer copies/signals.
- 32 packets, 1024 uint32 words per packet, 131072 bytes total.
- 32768 words verified, zero mismatches.
- Zero CPU boundary completion checks. One terminal event wait after all GPU work had been submitted.
- This is a D3D12 shared-heap copy/readback transport result, not direct shader or Vulkan aperture consumption.

## Vulkan fence baton

Command:

```powershell
& 'C:\bin\pwsh\pwsh.exe' -NoProfile -File 'C:\dev\V340L-Emancipated\Test-V340CrossAdapterFence-20261001.ps1' -Packets 1 -VulkanFenceInterop -ReceiptPath 'C:\dev\V340L-Emancipated\GGML\Vulkan\Receipts\vulkan-d3d12-fence-interop-20261001.json'
```

Both same-device control and cross-device test passed. DXGI-to-Vulkan matching used `deviceLUID`, not enumeration assumptions.

Cross-device identities:

- Vulkan physical 0: UUID `00000000690000000000000000000000`.
- Vulkan physical 1: UUID `00000000BA0000000000000000000000`.

For each test a fresh D3D12 fence was created at value 0 with flags 3, exported with `ID3D12Device::CreateSharedHandle`, and permanently imported into binary Vulkan semaphores using `VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_D3D12_FENCE_BIT`.

Results:

- Both Vulkan imports: `VkResult=0`.
- Consumer queue submit waiting for native fence value 1: `VkResult=0`.
- Producer queue submit signaling native fence value 1: `VkResult=0`.
- Consumer terminal fence completion: `VkResult=0`.
- Native `ID3D12Fence::GetCompletedValue`, checked after terminal completion: 1.
- Consumer submitted before producer. Zero CPU boundary completion checks.
- Cross-device consumer `vkQueueSubmit` call duration: 0.1184 ms. This is managed API-call wall time, not GPU handoff latency.

The Vulkan submissions contained no command buffers. This establishes local cross-device execution of the imported D3D12 fence wait/signal, not payload visibility, arena retirement, or model correctness. The raw receipt's top-level `VulkanInteropTested=false` is a metadata bug in the first harness version; the nested `VulkanSameDeviceControl` and `VulkanCrossDevice` operation receipts record the actual tests. The script now sets that metadata field correctly.

## Exact Vulkan ABI details

Use ordinary **binary** semaphores for this tested route; the local capability probe did not advertise timeline imports for this handle type.

Attach `VkD3D12FenceSubmitInfoKHR` to each `VkSubmitInfo` with a uint64 value of 1 in the corresponding wait/signal array. Those arrays must have the matching semaphore counts. Do not silently omit the values and rely on a default value of 0.

Installed Vulkan SDK constants checked against `vulkan_core.h`:

| Structure | sType |
|---|---:|
| VkImportSemaphoreWin32HandleInfoKHR | 1000078000 |
| VkD3D12FenceSubmitInfoKHR | 1000078002 |
| VkSemaphoreGetWin32HandleInfoKHR | 1000078003 |
| VkExportSemaphoreCreateInfo | 1000077000 |
| VkPhysicalDeviceProperties2 | 1000059001 |
| VkPhysicalDeviceIDProperties | 1000071004 |

`VkImportSemaphoreWin32HandleInfoKHR` is 48 bytes on x64, including the name pointer at offset 40. Import flags were 0, meaning permanent import. No Vulkan export capability was required because D3D12 created the handle.

The existing `GGML/Vulkan/Test-ExternalSemaphorePair.ps1` contains different, incorrect sType values for export/get/import structures and requests exportable timeline semaphores. Its source does not reproduce the binary test described in the pasted report. No conclusion about the cause of that earlier -13 error was established here.

## Next payload test

Keep the tested native fence construction and Vulkan wait/signal structures. Add the actual producer aperture writes before the signal and a consumer shader reading the imported host aperture behind the wait. Verify every payload word and the manifest with no CPU bridge and no destination-local activation copy. Retain all resources until terminal completion. Do not wire the inference graph or reuse arena offsets until that direct-aperture payload test passes.

The specification's compatibility table remains relevant to portability; it did not predict the successful local driver experiment. This receipt supersedes the earlier categorical claim that distinct V340 UUIDs rule out executing this D3D12-created fence route.

References:

- https://docs.vulkan.org/refpages/latest/refpages/source/VkD3D12FenceSubmitInfoKHR.html
- https://docs.vulkan.org/refpages/latest/refpages/source/VkImportSemaphoreWin32HandleInfoKHR.html
- https://docs.vulkan.org/spec/latest/chapters/capabilities.html
