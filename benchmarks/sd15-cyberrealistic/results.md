# SD1.5 LCM: DirectAI / ORT DirectML versus stock sd.cpp / Vulkan

2026-10-01. Windows; Radeon Pro V340L 22Q4. Sequential resident-context runs,
one warm-up followed by three measured images for each placement. No concurrent
GPU workload. Downloads were stopped before these final repetitions.

Prompt: a photograph of a red rose in a glass vase, natural daylight.
512 x 512, six LCM steps, seed 42, guidance 1, FP16 GGUF, no quantization.
Stock sd.cpp release master-929-3f8527a installed in C:\bin\sd.cpp.
DirectAI used its existing Release executable; the modular refactor was not
built or substituted during this experiment.

| Text encoder / UNet / VAE device ordinals | DirectAI median | sd.cpp median | sd.cpp / DirectAI |
|---|---:|---:|---:|
| 0 / 0 / 0 | 1.838 s | 4.900 s | 2.67x |
| 1 / 1 / 1 | 1.681 s | 4.810 s | 2.86x |
| 0 / 1 / 1 | 1.692 s | 4.830 s | 2.85x |
| 0 / 1 / 2 | 1.705 s | 4.810 s | 2.82x |

DirectAI's two-device stage placement is 2.84x faster than sd.cpp's
single-device-1 run. Relative to DirectAI device 1 alone, two-device stage
placement is 0.67% slower; three-device placement is 1.45% slower.
Stage placement does not split the UNet and does not establish simultaneous
multi-GPU arithmetic or an isolated handoff-latency measurement.

## Timing and repeatability

DirectAI timings surround the resident diffusion pipeline invocation and exclude
loading and PNG saving. sd.cpp's native generate_image timings exclude model
context creation and HTTP response encoding; they have 10 ms printed resolution.
HTTP round-trip times are retained separately in each sidecar.
sd-server conditioning caching was explicitly disabled, so both paths execute
the text encoder for each measured request. Neither path enabled denoiser caching.

All 12 DirectAI PNG files have one identical SHA256; all 18 successful sd.cpp PNG
files have one identical SHA256. They differ between runtimes. A sd.cpp image was
visually inspected and contains coherent red roses in a glass vase.
Different RNG, sampler arithmetic, graph implementations and exported weights
prevent a claim of cross-runtime byte identity.
The adapter numbers are each API's enumeration ordinals; a DXGI/Vulkan LUID
correspondence was not captured. Both tested single-device ordinals identify V340L.

## Stock UNet layer-split attempt

Default two-device assignment: te=Vulkan1,diffusion=Vulkan0&Vulkan1,vae=Vulkan1.
The loader announced two backends, but the assignment log put all 686 UNet tensors
(1640.3 MB) and graph segments [0,22) on Vulkan0. Its 5.160 s median is therefore
not a successful two-device UNet measurement.

With --max-vram Vulkan0=1,Vulkan1=7, the actual assignment was:

- Vulkan0: segments [0,12), 336 tensors, 975.0 MB.
- Vulkan1: segments [12,22), 350 tensors, 665.2 MB.

Execution failed during weight preparation. Vulkan0 had 7350.21 MB reported
physical free memory, but the imposed 1024 MB budget was below the required
1525.89 MB budget allocation / 2037.89 MB device allocation.
The CLI returned exit 1; the server returned HTTP 500. Result: **DNF for this
tested forced split**. This does not establish impossibility for every budget.
No sd.cpp source or binaries were modified.

## Model identity qualification

Local checkpoint:
N:\models\checkpoints\cyberrealisticLCM_cyberrealistic42.safetensors.
It was converted using sd.cpp's stock convert mode to
C:\Models\sd.cpp\CyberRealistic-LCM-4.2-f16.gguf.
The ONNX export was the installed CyberRealistic-LCM-amuse directory.

The binary weight audit found:

- UNet: 519 of 637 inspected FP16 initializer payloads match checkpoint payloads.
- VAE decoder: 133 of 137 inspected FP16 initializer payloads match.
- Text encoder: 0 of 196 inspected FP16 initializer payloads match.

Unmatched payloads were not proven to be equivalent through casts, transposes,
rounding or other export transformations. In particular, exact text-encoder
weight parity has not been established. These are measured comparable SD1.5-LCM
workloads from the named model family, **not a proven identical-all-weights
comparison**. Full graph-and-weight parity requires a validated conversion recipe.

## Receipts

summary.json and measurements.json contain all final repetitions.
Every PNG has an adjacent JSON with settings, timing and SHA256.
The corresponding stdout logs contain native stage timings and tensor placement.
artifact-hashes.json records the local checkpoint, GGUF and benchmark binaries.
The earlier exploratory/cache-enabled run was archived under output/history.

DirectAI currently has one whole UNet session on one adapter. Splitting its
UNet requires two executable ONNX partitions, a complete boundary tensor
contract including skip connections, retained device residency, ordering,
and numerical parity checks before any speed claim.
