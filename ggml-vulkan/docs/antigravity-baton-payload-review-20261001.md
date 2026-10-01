# Review of Antigravity's aperture payload experiment

Read-only review of the script and two saved receipts on 2026-10-01. No GPU rerun performed and no experiment or Proofs files changed.

## Observed result

Both receipts report PASS, native fence value 1, zero error flags, zero mismatches, sequence 1, region count 21, and 5376 examined words. The source submits the consumer before the producer. The consumer descriptor points directly at its imported host-aperture buffer; there is no aperture-to-destination activation copy. The only host fence wait occurs after both submissions.

This extends the earlier empty-submit baton experiment to actual GPU writes and direct consumer shader reads of the aperture.

## Harness corrections

1. `Test-BatonApertureTransport-20261001.ps1:463`: `VkDescriptorSetAllocateInfo` requires 40 bytes on x64. The script allocates 32 bytes and then writes the eight-byte `pSetLayouts` pointer at offset 32, outside that allocation. Allocate 40 bytes.
2. Lines 565–566: `0x800` is `VK_ACCESS_TRANSFER_READ_BIT`, not `VK_ACCESS_MEMORY_READ_BIT` (which is `0x8000`). Neither read mask belongs with a destination of `BOTTOM_OF_PIPE`. If keeping this legacy release-only barrier, use `srcAccess=TRANSFER_WRITE`, `dstAccess=0`, `srcStage=TRANSFER`, `dstStage=BOTTOM_OF_PIPE`; the queued semaphore wait orders the consumer. Do not merely change 0x800 to 0x8000 and retain the current destination stage.
3. Lines 646–649: the stopwatch reported as `TotalPipelineMilliseconds` starts after both queue submissions. Rename it to terminal observation time. For end-to-end CPU wall time, start before consumer submission; for GPU execution/transfer time, use GPU timestamps. Report these separately.

References:

- https://docs.vulkan.org/refpages/latest/refpages/source/VkDescriptorSetAllocateInfo.html
- https://docs.vulkan.org/refpages/latest/refpages/source/vkCmdPipelineBarrier.html
- Access constants checked against `C:\bin\VulkanSDK-1.4.341.1\Include\vulkan\vulkan_core.h`.

## Remaining inference-specific edges

The current producer fills the aperture using `vkCmdFillBuffer` and updates the manifest. It uses the selected compute queue family. It does not test the proposed resident-VRAM-to-aperture copy on a dedicated SDMA queue, producer-compute-to-transfer ordering, or queue-family ownership for that source tensor.

The test has one publication, fence value 1, constant data within each region, and no aperture-region reuse. It does not yet test repeated values, source allocator reuse, consumer completion before overwrite, actual tensor views/offsets/strides, KV updates, or coherent generation.

The receipts identify ordinal pairs 0→1 and 0→2 by LUID. They contain no PCI/card topology map establishing the same-card label. Preserve LUID identities and verify physical card grouping separately.

## Next bounded test

Correct the harness, then substitute a GPU-generated resident source buffer and the actual VRAM-to-aperture copy for direct aperture fills. Use the intended compute/SDMA queues, retaining exact GPU ordering on both producer and consumer. Use word-varying data and fresh sequence values; the consumer continues reading the imported aperture directly. Preserve a single permanent arena, avoid destination activation copies, and perform diagnostic observation only after the finite submitted experiment completes.

Once that transfer chain passes, integrate one real Gemma boundary using graph-derived tensor layout metadata and compare against a correct reference. Establish GPU-controlled retirement of any reused source/arena regions before removing the runtime's host completion guarantee. The single logical backend remains an integration option if outer ggml scheduling still introduces host waits; it is not established by this standalone test.
