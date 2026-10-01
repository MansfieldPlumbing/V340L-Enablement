# Vulkan Proofs

This directory is evidence, not architecture.

Vulkan is **not** the V340L Emancipated compute backend. On the tested Windows/V340 stack it is a poor compute path, and this project is not spending itself trying to turn that dead end into a product. Active compute work lives at the repository root and targets DirectML plus D3D12 compute shaders.

These files remain because they establish facts the DirectML/D3D12 implementation can reuse:

- A PowerShell runspace can validate, replace, call, and restore stock ggml's live `cpy_tensor_async` callback at `+56 / 0x38`.
- The same page-aligned host allocation can be imported by adjacent V340 Vulkan devices.
- Device memory can be copied into that allocation and then out to the next die with no CPU `memcpy` between the two device legs.
- The destination and shared aperture can be verified byte-for-byte.
- The transport can be measured against an explicit CPU-bounce microbenchmark.
- The aperture is not intrinsically limited to 2 MiB; 2 MiB was the initial activation-sized test allocation.

## What this does not prove

- Vulkan is suitable for V340 inference.
- The dies have direct peer-to-peer VRAM access.
- The shared host aperture avoids host memory entirely.
- The two-leg aggregate traffic rate is end-to-end payload bandwidth.
- DirectML executes llama.cpp graphs.
- Four-die token throughput exceeds one-die throughput.

The path proved here is:

```text
source VRAM -> device transfer -> shared host allocation
shared host allocation -> device transfer -> destination VRAM
```

It is a deliberate hairpin through shared host memory. It removes the explicit CPU copy from the measured middle of the path; it does not invent a physical die-to-die interconnect.

## Files

- `Test-GgmlApertureInterception.ps1` — corrected stock-ggml callback interception and byte-verified boundary copy.
- `Compare-Die2Die.ps1` — explicit CPU bounce versus shared-aperture device-transfer microbenchmark.
- `Test-V340L-VramDrain.ps1` — large-payload transport saturation experiment.
- `results.json` — committed machine-readable historical measurement.
- `results.md` — interpretation, correction, and limits of that measurement.

No active DirectML or graph-execution script imports code from this directory.
