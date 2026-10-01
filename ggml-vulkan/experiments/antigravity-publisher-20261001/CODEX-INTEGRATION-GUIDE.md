# Codex Integration Guide: Antigravity Standalone Producer Publisher

## 1. Module Overview

The standalone assembly `Antigravity.ProducerPublisher.dll` provides zero-CPU-wait native publication of layer-split activations across AMD Radeon Pro V340L dies. It directly addresses the issue where `ggml_backend_vk_cpy_tensor_async` records a copy on the compute recording context without submitting it, causing subsequent empty fence submissions to fail to publish the activations.

### Location & Provenance
- Assembly: `C:\dev\V340L-Emancipated\scratch\antigravity-publisher-20261001\Antigravity.ProducerPublisher.dll`
- Target Runtime Vulkan SHA256: `AE67DDD85CC9C0E777FA76368E1A63AD90DDD4B97709CBC5C46F734F97C5248E`
- Emitted via: CoreCLR `PersistedAssemblyBuilder` (zero Roslyn / MSBuild dependency)
- Verified Receipt: `C:\dev\V340L-Emancipated\scratch\antigravity-publisher-20261001\publisher-verification-receipt.json`

---

## 2. ABI Contracts & Data Structures

All structures and function pointers follow standard 64-bit Cdecl ABI.

### Region Descriptor (`AntigravityRegion`, 32 bytes)
```c
typedef struct {
    uint64_t sourceVkBuffer; // Native VkBuffer handle of resident source tensor
    uint64_t sourceOffset;   // Byte offset inside the source buffer
    uint64_t arenaOffset;    // Byte offset in shared aperture arena
    uint64_t byteCount;      // Number of bytes to copy
} AntigravityRegion;
```

### Consumer Wait Requirement (`AntigravityConsumerWait`, 24 bytes)
```c
typedef struct {
    uint64_t d3d12Semaphore;   // Native Vulkan binary semaphore handle importing D3D12 fence
    uint64_t publicationValue; // 64-bit monotonic baton value (e.g., 1, 2, ...)
    uint32_t waitStageMask;    // Pipeline stage mask for wait (0x20 = VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT)
    int32_t  status;           // 0 (VK_SUCCESS)
} AntigravityConsumerWait;
```

---

## 3. Native Callable Exports & Function Signatures

### A. `Setup`
Configures device handles, command pools, local semaphores, and pre-allocated submission structures.
```c
int Setup(
    void*    vkDevice,            // Logical VkDevice of producer die (Die 0)
    void*    computeQueue,        // VkQueue handle for Compute (Family 1)
    int32_t  computeQueueFamily,  // 1 (Compute without graphics)
    void*    transferQueue,       // VkQueue handle for Dedicated SDMA (Family 2)
    int32_t  transferQueueFamily, // 2 (Dedicated Transfer)
    uint64_t apertureBuffer,      // Native VkBuffer handle of producer aperture
    uint64_t d3d12Semaphore       // Native Vulkan binary semaphore handle importing D3D12 fence
);
```
- Available in managed: `[Antigravity.ProducerPublisher]::Setup(...)`
- Available as Cdecl function pointer: `[Antigravity.ProducerPublisher]::HookSetupPtr`

### B. `PublishBatch`
Records compute ownership release barrier on Family 1, signals internal local semaphore, records transfer acquire barrier on Family 2, SDMA `vkCmdCopyBuffer` into aperture, release barrier, return ownership barrier back to Family 1, and submits transfer queue with D3D12 fence signal.
```c
int PublishBatch(
    uint64_t                 publicationValue, // Monotonic incrementing sequence value
    int32_t                  regionCount,      // Number of regions (up to 64 per batch)
    const AntigravityRegion* pRegions,         // Array of AntigravityRegion
    AntigravityConsumerWait* pConsumerWaitOut  // Out-parameter receiving consumer wait requirement
);
```
- Available in managed: `[Antigravity.ProducerPublisher]::PublishBatch(...)`
- Available as Cdecl function pointer: `[Antigravity.ProducerPublisher]::HookPublishBatchPtr`
- **Zero CPU waits**: Returns immediately after asynchronous queue submission.

### C. `ExtractTensorBuffer`
Helper extracting native `VkBuffer` and byte offset from a stock `ggml_tensor` (handles both direct and view tensors):
```c
int ExtractTensorBuffer(
    const void* pTensor,    // Pointer to stock ggml_tensor struct
    uint64_t*   pOutBuffer, // Receives native VkBuffer handle
    int64_t*    pOutOffset  // Receives byte offset inside VkBuffer
);
```
- Available as Cdecl function pointer: `[Antigravity.ProducerPublisher]::HookExtractTensorPtr`

---

## 4. Integration into Consumer Graph Seam

### Step 1: Initialization / Setup
When setting up the hardware baton between Die 0 and Die 1:
```powershell
$pubBytes = [IO.File]::ReadAllBytes('C:\dev\V340L-Emancipated\scratch\antigravity-publisher-20261001\Antigravity.ProducerPublisher.dll')
$pubAssembly = [Reflection.Assembly]::Load($pubBytes)
$pubType = $pubAssembly.GetType('Antigravity.ProducerPublisher')

# Retrieve queues:
# Die 0 Compute: Family 1, Index 0
# Die 0 Transfer: Family 2, Index 0
$fnGetDevQueue.Invoke($vkDev0, [uint32]1, [uint32]0, $outQ0Comp)
$q0Compute = [Runtime.InteropServices.Marshal]::ReadIntPtr($outQ0Comp)

$fnGetDevQueue.Invoke($vkDev0, [uint32]2, [uint32]0, $outQ0Xfer)
$q0Transfer = [Runtime.InteropServices.Marshal]::ReadIntPtr($outQ0Xfer)

# Call Setup:
$status = [int]$pubType.GetMethod('Setup').Invoke($null, @(
    $vkDev0,
    $q0Compute,
    1,
    $q0Transfer,
    2,
    [uint64]$vkBuf0,
    [uint64]$d3d12Sem0
))
```

### Step 2: Producer Publication (at Layer Boundary)
When layer activations are ready on Die 0:
```powershell
# Bounded region list for the layer split tensors:
$pRegions = [Runtime.InteropServices.Marshal]::AllocHGlobal($regionCount * 32)
# Fill pRegions with { sourceVkBuffer, sourceOffset, arenaOffset, byteCount } for each activation tensor

$pWaitOut = [Runtime.InteropServices.Marshal]::AllocHGlobal(24)

# Call PublishBatch (returns in sub-millisecond wall time, ZERO CPU waits):
$pubStatus = [int]$pubType.GetMethod('PublishBatch').Invoke($null, @(
    [uint64]$currentSequence,
    [int]$regionCount,
    $pRegions,
    $pWaitOut
))
```

### Step 3: Consumer Execution (on Die 1)
Pass the returned wait requirement into Die 1's submission:
- Wait Semaphore: `Marshal.ReadInt64($pWaitOut, 0)` (`d3d12Sem1`)
- Wait Value: `Marshal.ReadInt64($pWaitOut, 8)` (`currentSequence`)
- Wait Stage: `0x20` (`VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT`)
- Submit Die 1 compute graph with this wait info.
- Die 1 reads activation tensors directly from `buf1` (aperture) in hardware without host staging bounces.
