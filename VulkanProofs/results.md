# V340L GGML Function Interception Benchmark Data

> **Correction (2026-09-28):** The recorded `+0x40` mutation targeted `synchronize`, not `cpy_tensor_async`: `ggml_guid_t` is an 8-byte pointer, so the interface begins at `+0x08` and `cpy_tensor_async` is at `+0x38`. The recorded `Return=True` invocation also used null tensor pointers and submitted no copy. The transfer figures below came from separate Vulkan benchmark code.

> **Superseding result:** `Test-GgmlApertureInterception.ps1` runtime-validates the corrected `+0x38` ABI and performs a real stock-ggml tensor copy through a 2 MiB shared allocation. An 8 KiB patterned tensor passed byte-for-byte in both the aperture and destination VRAM on all three four-die boundaries: Vulkan 1→2, 2→3, and 3→4.

> The transfer figures below are a standalone Vulkan microbenchmark against an explicit CPU-bounce baseline. They are not a stock llama.cpp inference A/B measurement and do not prove that the intercepted callback performs the copy.

**Environment**: Managed PowerShell (pwsh.exe) with Reflection.Emit dynamic IL trampoline.
**Compiler**: **None**. Zero C/C++ compilation, zero C# compilation, zero llama rebuilds.
**Hardware**: Dual Radeon Pro V340L (four Vega 10 dies, 8 GB HBM2 each, 32 GB aggregate, PCI\VEN_1002&DEV_6864).
**Driver**: AMD Proprietary `31.0.12044.3` on Windows 11 Enterprise.
**Stock GGML**: `version: 9934 (32e41fa5b)` (`ggml-vulkan.dll` SHA256: `EB1C15F81A6FE213BE1482F187E74BBBDD71C82D52451C3DC92DA9DA95CB790B`).

---

## 1. Function Interception Verification

| Parameter | Value |
|---|---|
| Historical Target Function Slot | `ggml_backend_i::synchronize` at `+64 (0x40)` (incorrectly labeled at capture time) |
| Shared Host Aperture Address | `0x2A599660000` |
| Stock Function Pointer | `0x7FFDB41B3D90` |
| In-Runspace Trampoline Pointer | `0x7FFD7B2FB3D8` |
| Direct Interception Invocation | **Return=True** |
| Restored Function Pointer | `0x7FFDB41B3D90` (Exact Match) |
| State Verification | **PASS** (Reversible & Clean) |

---

## 2. Die-to-Die Transfer Benchmark Curve

Transfer method:
- **Explicit CPU-Bounce Baseline**: Die 0 VRAM $\to$ Host Staging Buffer $\to$ Host CPU RtlMoveMemory $\to$ Host Staging Buffer $\to$ Die 1 VRAM.
- **Our Host Aperture**: Die 0 VRAM $\to$ Shared Host Aperture (VK_EXT_external_memory_host) $\to$ Die 1 VRAM (**Zero CPU Memcpy**).

| Size | CPU Bounce (p50) | CPU Bounce (min) | Aperture SDMA (p50) | Aperture SDMA (min) | Speedup Ratio | Aggregate Two-Leg Traffic Rate | Bit-for-Bit Verified |
|---|---|---|---|---|---|---|---|
| 8 KiB | 319.9 µs | 304.9 µs | 248.6 µs | 232.8 µs | **1.29x** (22.3%) | 0.07 GB/s | PASS (Bit-for-Bit Identical) |
| 64 KiB | 738.1 µs | 708 µs | 243.9 µs | 241.7 µs | **3.03x** (67%) | 0.54 GB/s | PASS (Bit-for-Bit Identical) |
| 256 KiB | 2426.5 µs | 2333.7 µs | 271.3 µs | 267.5 µs | **8.94x** (88.8%) | 1.96 GB/s | PASS (Bit-for-Bit Identical) |
| 1 MiB | 8608.4 µs | 8186.7 µs | 490.4 µs | 459.9 µs | **17.55x** (94.3%) | 4.56 GB/s | PASS (Bit-for-Bit Identical) |
| 4 MiB | 34262.1 µs | 33833 µs | 1265.7 µs | 1227.2 µs | **27.07x** (96.3%) | 6.84 GB/s | PASS (Bit-for-Bit Identical) |
| 16 MiB | 132785.1 µs | 132213.8 µs | 3768.1 µs | 3480.8 µs | **35.24x** (97.2%) | 9.64 GB/s | PASS (Bit-for-Bit Identical) |
| 64 MiB | 526405.1 µs | 524165.5 µs | 11338.7 µs | 11162.6 µs | **46.43x** (97.8%) | 12.02 GB/s | PASS (Bit-for-Bit Identical) |

---

## 3. Key Transport Findings

1. **Zero Compiler Architecture**: Stock llama.cpp binaries (`C:\bin\llama.cpp`) are left completely untouched. The corrected PowerShell mutator uses Reflection.Emit to replace `cpy_tensor_async` at `+56 / 0x38`, performs both aperture legs, and returns `true` only after both legs succeed. The historical `+64 / 0x40` receipt targeted `synchronize` and is retained above only as provenance.
2. **Bit-for-Bit Data Integrity**: Every transfer across all sizes (8 KiB to 16 MiB) is validated bit-for-bit against dynamic fill patterns using native msvcrt.dll!memcmp.
3. **Measured Transport Rate**: At 64 MiB, the aperture path moves **12.02 GB/s of aggregate two-leg traffic** and is **46.43x faster** than the explicit CPU-bounce microbenchmark. This is not end-to-end payload bandwidth or a llama.cpp speedup.
