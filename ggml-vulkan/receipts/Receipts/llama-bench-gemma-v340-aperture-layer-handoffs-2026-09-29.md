# Gemma V340 aperture layer-handoff receipt

**Date:** 2026-09-29  
**Model:** `C:\Models\gemma-4-E4B-it-Q4_K_M.gguf`  
**Model size:** 4,961,343,656 bytes (llama-bench report)  
**Build:** stock `llama.cpp` / ggml commit `4da633776`, build 11223  
**Benchmark:** `llama-bench`, prompt 512, generation 128, repetitions 3  
**Purpose:** run Gemma with real `l_out-21` activations routed through the shared aperture at the Vulkan destination-buffer copy seam.

**Harness:** [`Probe-LlamaBenchBufferCopy.ps1`](../Probe-LlamaBenchBufferCopy.ps1). The correctness pass used `-Prompt 512 -Generation 128 -Repetitions 1 -RouteThroughAperture`; the timed route pass added `-Repetitions 3 -SkipByteVerification -WarmupBeforeMeasure`. The CPU-bounce comparison used the same settings with `-ForceCpuBounce` instead of `-RouteThroughAperture`.

## Physical V340 pairs

The four present V340 adapters were read from Windows PnP and matched to DXGI LUIDs with `D3DKMTOpenAdapterFromLuid` / `D3DKMTQueryAdapterInfo(KMTQAITYPE_ADAPTERADDRESS)`. Their PCI locations and PnP parent paths group into two cards:

| llama.cpp selection | DXGI adapter LUID | PCI location | PnP card path |
|---|---:|---|---|
| `Vulkan1` | `00000000:00027B14` | bus 186, device 0, function 0 | `PCIROOT(B2)…ACPI(PC03)…BR3A…PEGP` |
| `Vulkan2` | `00000000:00025481` | bus 183, device 0, function 0 | `PCIROOT(B2)…ACPI(PC03)…BR3A…PEGP` |
| `Vulkan3` | `00000000:00022DF2` | bus 108, device 0, function 0 | `PCIROOT(64)…ACPI(PC02)…BR2A…PEGP` |
| `Vulkan4` | `00000000:0002073F` | bus 105, device 0, function 0 | `PCIROOT(64)…ACPI(PC02)…BR2A…PEGP` |

The Vulkan-index-to-LUID association follows the Vulkan device enumeration order, cross-checked against the four PnP V340 PCI locations. The loader also exposes one extra V340-labelled endpoint at PCI `0:0.3`; it is not one of the four present PnP V340 adapters, and it is not in ggml Vulkan’s reported five-device inventory (P2000 plus four V340s). The physical-card grouping itself is directly visible in the shared PnP parent paths above.

Thus `Vulkan1 → Vulkan2` tests the two dies on the first physical card, and `Vulkan3 → Vulkan4` tests the two dies on the second. Each llama-bench invocation selected only its listed V340 pair; `Vulkan0` (Quadro P2000) was not selected.

## Exact runtime seam and route

The scheduler’s split input is `l_out-21` on the source die and `VulkanN#l_out-21#0` on the destination die. The matching-build ggml buffer interface places `cpy_tensor` at `buffer + 0x40`. The earlier `ggml_backend_i::cpy_tensor_async` hook at `+0x38` is not the callback used for these copies. This layout and the destination-buffer copy contract are in the pinned [`ggml-backend-impl.h`](https://github.com/ggml-org/llama.cpp/blob/4da6337767f973e2b4d0797e5b323d77d8565e4a/ggml/src/ggml-backend-impl.h#L840-L870); the pinned [`ggml-backend.cpp`](https://github.com/ggml-org/llama.cpp/blob/4da6337767f973e2b4d0797e5b323d77d8565e4a/ggml/src/ggml-backend.cpp#L2521-L2533) invokes that callback, and its [CPU fallback](https://github.com/ggml-org/llama.cpp/blob/4da6337767f973e2b4d0797e5b323d77d8565e4a/ggml/src/ggml-backend.cpp#L2935-L2968) performs tensor get-to-host followed by tensor set-from-host.

The process-local probe wraps selected Vulkan buffer allocations, replaces the returned buffer’s `cpy_tensor`, and handles only the named `l_out-21` source/destination pair. It copies source VRAM to a source-device view of one page-aligned shared host allocation, then from the destination-device view of that same allocation to destination VRAM. It returns handled only after both legs succeed; other copies use the captured stock callback. An 8 MiB aperture was selected because the prompt activation is 5 MiB. The default 2 MiB aperture would not hold that activation.

Before timing, a separate correctness pass ran the same model and batch sizes on each card pair. It verified source VRAM, the aperture bytes, and destination VRAM byte-for-byte for both activation sizes: 5,242,880 bytes and 10,240 bytes. That pass routed 131 copies per pair and reported no route failures. During each measured pass, all 389 targeted copies routed successfully: 4 prompt activations of 5,242,880 bytes and 385 decode activations of 10,240 bytes.

The hot-path callback timers below exclude the separate correctness readbacks. The route was warmed once in the same process before the three measured repetitions, so bridge-buffer/tensor initialization was outside the reported repetitions. “Complete callback” includes route metadata lookup plus both copy calls; the two leg columns time each copy call separately.

## Timed results

All rates are tokens per second, mean ± sample standard deviation across three repetitions.

| Same-card pair | Mode | Prompt tok/s | Generation tok/s |
|---|---|---:|---:|
| `Vulkan1/Vulkan2` | stock copy | 404.432 ± 0.300 | 20.485 ± 0.063 |
| `Vulkan1/Vulkan2` | aperture route | 403.035 ± 0.280 | 20.301 ± 0.089 |
| `Vulkan1/Vulkan2` | forced CPU bounce | 403.828 ± 0.569 | 20.206 ± 0.115 |
| `Vulkan3/Vulkan4` | stock copy | 411.405 ± 0.465 | 20.375 ± 0.071 |
| `Vulkan3/Vulkan4` | aperture route | 410.033 ± 0.647 | 20.195 ± 0.065 |
| `Vulkan3/Vulkan4` | forced CPU bounce | 410.375 ± 0.140 | 20.333 ± 0.093 |

The CPU-bounce control makes the targeted buffer callback return `false`, causing the pinned ggml copy implementation to allocate a CPU buffer, read the source tensor to it, then write it to the destination. It was run separately, never concurrently with the aperture measurements. These results show no consistent token-throughput improvement from routing the boundary through the aperture; the measured rates are close to both stock and forced bounce.

The measured aperture leg and full route-callback times are averages from the timed repetitions:

| Same-card pair | Payload | Source VRAM → aperture | Aperture → destination VRAM | Two copy legs | Complete route callback |
|---|---:|---:|---:|---:|---:|
| `Vulkan1/Vulkan2` | 5,242,880 B | 630.975 µs | 1,179.100 µs | 1,810.075 µs | 1,816.050 µs |
| `Vulkan1/Vulkan2` | 10,240 B | 159.961 µs | 220.694 µs | 380.655 µs | 386.250 µs |
| `Vulkan3/Vulkan4` | 5,242,880 B | 638.850 µs | 1,107.725 µs | 1,746.575 µs | 1,753.775 µs |
| `Vulkan3/Vulkan4` | 10,240 B | 158.023 µs | 226.554 µs | 384.577 µs | 389.700 µs |

The complete callback figure covers the route after recognizing the activation handoff, including metadata lookup and both synchronous buffer-copy calls. It is a per-handoff timing, not an added end-to-end token latency and not a bulk-drain throughput result.

## Runtime conditions and cleanup

The invocation used `-ngl 999 -ncmoe 0 -sm layer -ts 1/1 -ctk q4_0 -ctv q4_0 -fa on --no-host 1 -p 512 -n 128 -r 3`. llama-bench reported `type_k=q4_0`, `type_v=q4_0`, `flash_attn=1`, `no_host=true`, and only the selected V340 pair. CPU threads still handle host orchestration; the selected model layers were placed on the two selected V340 dies.

The probe ran inside a dedicated PowerShell process. Its buffer-type allocation hooks are restored in `finally`; benchmark-owned buffers and the imported aperture views are released before the ggml libraries are unloaded. The process exits after the run. No driver, registry, or global system configuration was changed.

**Receipt status:** real Gemma layer handoffs were routed through the shared aperture on both physical V340 cards; activation bytes were verified exactly at prompt and decode sizes. The benchmark demonstrates the seam and records its cost. It does not show a token-throughput gain over stock copying or the explicit CPU-bounce fallback.

## Stock callback observation (diagnostic run)

A separate pass-through diagnostic on `Vulkan1/Vulkan2` (`-p 8 -n 4 -r 1`) called the captured stock destination-buffer `cpy_tensor` callback unchanged. All 7 observed `l_out-21` callbacks returned handled=true: five 10,240-byte copies and two 81,920-byte copies. The same diagnostic also observed handled stock copies for `inp_per_layer` (1,024 B ×100 and 8,192 B ×40). This confirms the stock destination callback accepts these transfers; it does not reveal whether its internal implementation uses a peer path, synchronization, or host staging, and the short diagnostic is not a latency benchmark.

The user's repeated observation that generation throughput falls with every additional layer-offloaded die is consistent with accumulated per-boundary latency. The current receipt does not quantify end-to-end latency contribution per boundary or establish that the aperture route removes it: on the measured two-die runs, generation remained about 20 tok/s in stock, aperture, and forced-bounce modes. The per-copy aperture callback time alone is therefore insufficient to explain or resolve the observed scaling.

## Correction: end-to-end comparison hook

The separate first scaling comparison in [aperture-gemma-die-scaling-2026-09-29.txt](aperture-gemma-die-scaling-2026-09-29.txt) intercepted the destination buffer `cpy_tensor` callback at `+0x40`. That is a real copy seam, but it is not the repository's validated backend async `cpy_tensor_async` hook at `+0x38`; do not treat it as the A/B of the intended mutation. The corrected, end-to-end comparison across one through four dies is in [gemma-stock-vs-async-aperture-layer-offload-2026-09-29.md](gemma-stock-vs-async-aperture-layer-offload-2026-09-29.md).
