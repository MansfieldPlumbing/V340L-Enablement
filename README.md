# V340L Emancipated

No-build PowerShell, DirectML, and D3D12 compute for AMD Radeon Pro V340L on Windows.

The V340L is not waiting for another Vulkan workaround. This project intercepts a real stock ggml execution seam from a PowerShell runspace, drives DirectML on every V340 die without compiling a helper, and is building toward four-die pipeline inference with D3D12-owned tensors and a shared host-memory hairpin.

## Compute policy

The product path is unambiguous:

- **DirectML** for supported dense tensor operators.
- **D3D12 compute shaders** for quantized kernels, fusions, and operations DirectML cannot express efficiently.
- **Stock ggml `graph_compute` interception** as the initial no-build integration seam.
- **One model stage per V340 die**, with only boundary activations crossing between dies.
- **No Vulkan compute backend.** The Vulkan work is retained only in [`VulkanProofs/`](VulkanProofs/) because it proves the shared-aperture transport and measures the cost of an explicit CPU bounce.
- **No ROCm, HIP, ZLUDA, Roslyn, C#, or native helper build.** The current probes use PowerShell 7, `Reflection.Emit`, COM vtables, and Windows-native APIs.

The NVIDIA Quadro P2000 remains the display adapter. It is deliberately excluded from V340 compute selection.

## Verified now

| Claim | Result | Evidence |
|---|---:|---|
| Create D3D12 and DirectML devices on all four V340 dies | PASS | [`Probe-DirectMLV340.ps1`](Probe-DirectMLV340.ps1) |
| Compile FP16 DirectML GEMM `[1,4096] x [4096,4096]` on every die | PASS | Meta-commands enabled; P2000 excluded |
| Initialize, dispatch, read back, and verify that GEMM | PASS | 4,096/4,096 exact outputs on every die |
| Mutate a real stock ggml CPU `graph_compute` callback | PASS | [`Test-GgmlCpuGraphInterception.ps1`](Test-GgmlCpuGraphInterception.ps1) |
| Forward the intercepted `GGML_OP_MUL_MAT` to stock CPU and restore the callback | PASS | One intercepted call; 8/8 exact outputs; callback restored |
| Execute a decoded ggml `GGML_OP_MUL_MAT` through DirectML without CPU compute | PASS | [`Test-GgmlDirectMLInterception.ps1`](Test-GgmlDirectMLInterception.ps1); 4/4 dies, zero error |
| Intercept stock CPU backend creation before a backend instance exists | PASS | [`Test-GgmlCpuFactoryInterception.ps1`](Test-GgmlCpuFactoryInterception.ps1) |
| Register four in-memory V340 GPU devices with stock ggml | PASS | [`Test-GgmlRuntimeBackendRegistration.ps1`](Test-GgmlRuntimeBackendRegistration.ps1) |
| Allocate a device-owned host fitting bucket through each emitted device | PASS | 1 MiB byte-verified per die; zero live allocations after teardown |
| Move bytes through one shared host allocation across every adjacent V340 boundary | PASS | [`VulkanProofs/Test-GgmlApertureInterception.ps1`](VulkanProofs/Test-GgmlApertureInterception.ps1) |
| Preserve bytes through the aperture | PASS | Native `memcmp` at the aperture and destination |
| Execute a complete llama layer through DirectML/D3D12 | **Not yet** | Graph translation and D3D12 tensor ownership remain |
| Demonstrate end-to-end model throughput | **Not yet** | No model benchmark has been run or claimed |

The DirectML timing emitted by the current harness includes operator creation/JIT, initialization, input upload, dispatch, synchronization, and readback. It is a correctness envelope, not steady-state token throughput.

## The interception seam

`Test-GgmlCpuGraphInterception.ps1` loads the installed stock `ggml-base.dll` and `ggml-cpu-x64.dll`, constructs a real F32 `GGML_OP_MUL_MAT` graph, validates the backend interface, and replaces `graph_compute` at runtime.

On the tested upstream binary:

- `ggml_backend` begins with an 8-byte GUID pointer.
- The backend interface follows at offset `+0x08`.
- `graph_compute` is interface slot 12, at `+104 / 0x68`.
- An emitted native-call trampoline counts the interception and forwards to the original callback.
- Teardown restores the exact original function pointer.

That forwarding probe establishes the control case. `Test-GgmlDirectMLInterception.ps1` then takes the same seam without forwarding: it decodes the received graph node, follows the actual `src[0]` and `src[1]` tensor pointers, reads their ggml bytes, executes an FP16 DirectML GEMM, converts the result back to ggml layout, and writes the output tensor. It passes independently on all four V340 dies with zero error.

`Test-GgmlCpuFactoryInterception.ps1` moves the mutation one level earlier. It intercepts the CPU device's `init_backend` callback at `+40 / 0x28`, lets the stock factory create its backend, and installs the `graph_compute` callback before that backend is returned. A future llama context can therefore be caught at backend creation without traversing private context state.

The stock backend used for this interception proof is ggml's CPU backend from `ggml-cpu-x64.dll`. DirectML is not being mislabeled as an existing llama.cpp backend: V340L Emancipated is replacing that forwarding path operation by operation, with DirectML and D3D12 as the target execution machinery.

## Intended execution path

```text
stock llama/ggml graph
        |
        v
PowerShell graph_compute interceptor
        |
        +--> DirectML: supported dense operators
        |
        +--> D3D12 shaders: quantized/fused/unsupported operators
        |
        v
D3D12 tensors owned by one V340 die
        |
        v
stage boundary activation -> shared host aperture -> next V340 die
```

The shared allocation is a transport mechanism, not a claim of direct die-to-die VRAM wiring. The measured path is two ordered device transfers through shared host memory with no CPU `memcpy` between the legs.

## Model fitting: canonical RAM, active HBM

The first inference path deliberately spends host RAM to avoid rebuilding llama's loader:

```text
GGUF/file mapping -> canonical ggml host tensors
                          |
              layer fit / tensor identity
                          |
          one-time upload into four HBM shadows
                          |
              hot token execution in D3D12
```

The canonical host tensor remains available for validation, relocation, recovery, and honest CPU fallback. It is not intended to feed weights over PCIe for every token. Each persistent HBM shadow is keyed by the original `ggml_tensor *` and records its V340 die, D3D12 resource, byte offset, type, and shape.

The upgrade path is also proved. `Test-GgmlRuntimeBackendRegistration.ps1` emits one ggml backend registration, four GPU device objects, and four device-owned host bucket buffer types entirely in memory. Stock ggml discovers them, allocates through each buffer interface, verifies bytes, frees every allocation, and unregisters cleanly. Once those callbacks also own D3D12 resources, llama's existing `devices`, `n_gpu_layers`, layer split, `tensor_split`, and buffer placement machinery can perform the four-bucket fit directly.

The registered proof uses a conservative configured budget of 7 GiB free per 8 GiB die. It does not claim live memory telemetry or successful model placement yet.

## Why `VulkanProofs` exists

Vulkan compute on this hardware is not the product. It performs poorly enough on this Windows/V340 stack that spending the project on increasingly elaborate Vulkan kernels would preserve the wrong architecture.

[`VulkanProofs/`](VulkanProofs/) is retained for exactly two reasons:

1. It proves that stock ggml's live `cpy_tensor_async` callback can be replaced, invoked, and restored safely from PowerShell.
2. It proves that one imported host allocation can carry byte-exact device traffic across the three adjacent boundaries of the four-die pipeline, and it quantifies that transport against an explicit CPU-bounce microbenchmark.

Nothing in that directory proves Vulkan is a good inference backend, direct peer VRAM access, DirectML llama execution, or token-per-second performance. No DirectML execution script imports it; `Verify.ps1` invokes it only as a separate historical transport stage.

## Reproduce the current proofs

Run from 64-bit PowerShell 7. No compiler is required.

```powershell
# DirectML device creation and operator compilation on all V340 dies
pwsh -NoProfile -File .\Probe-DirectMLV340.ps1 -M 1 -K 4096 -N 4096

# DirectML initialization, dispatch, readback, and full result verification
pwsh -NoProfile -File .\Test-DirectMLGemm.ps1 -M 1 -K 4096 -N 4096

# Stock ggml graph_compute interception, forwarding, verification, and restoration
pwsh -NoProfile -File .\Test-GgmlCpuGraphInterception.ps1

# Actual ggml tensor inputs -> DirectML -> ggml tensor output, without CPU compute
pwsh -NoProfile -File .\Test-GgmlDirectMLInterception.ps1 -V340Ordinal 0

# Catch a stock CPU backend at factory creation
pwsh -NoProfile -File .\Test-GgmlCpuFactoryInterception.ps1

# Register four V340 devices and byte-verify their host fitting buckets
pwsh -NoProfile -File .\Test-GgmlRuntimeBackendRegistration.ps1

# Historical transport proof; not the compute backend
pwsh -NoProfile -File .\VulkanProofs\Test-GgmlApertureInterception.ps1 -Bytes 8192 -ApertureBytes 2MB

# Full correctness and transport verification suite
pwsh -NoProfile -File .\Verify.ps1
```

`Verify.ps1` writes fresh, machine-readable and Markdown receipts under `Receipts/`. Its default transfer sweep is intentionally substantial; use `-Sizes 8192 -Trials 1` for a smoke run.

## Repository map

- [`Probe-DirectMLV340.ps1`](Probe-DirectMLV340.ps1) — enumerate the V340 dies and compile a transformer-shaped DirectML GEMM.
- [`Test-DirectMLGemm.ps1`](Test-DirectMLGemm.ps1) — perform the full no-build DirectML lifecycle and verify every FP16 output.
- [`Test-GgmlCpuGraphInterception.ps1`](Test-GgmlCpuGraphInterception.ps1) — exercise the stock ggml graph interception seam.
- [`Test-GgmlDirectMLInterception.ps1`](Test-GgmlDirectMLInterception.ps1) — decode a real ggml graph and replace its CPU `MUL_MAT` with DirectML execution.
- [`Test-GgmlCpuFactoryInterception.ps1`](Test-GgmlCpuFactoryInterception.ps1) — catch stock CPU backend instances as their public device factory creates them.
- [`Test-GgmlRuntimeBackendRegistration.ps1`](Test-GgmlRuntimeBackendRegistration.ps1) — emit four ggml GPU devices and device-owned host fitting buckets in memory.
- [`Verify.ps1`](Verify.ps1) — run the integrated proof suite and write fresh receipts.
- [`src/New-WindowsFunctionPointerBinder.ps1`](src/New-WindowsFunctionPointerBinder.ps1) — native C-ABI function-pointer binding used by the PowerShell probes.
- [`VulkanProofs/`](VulkanProofs/) — quarantined transport evidence and historical benchmark receipts.
- [`docs/WINDOWS-ENABLEMENT-ROADMAP.md`](docs/WINDOWS-ENABLEMENT-ROADMAP.md) — evidence-gated driver, HBCC, INF, and PowerPlay work planned after compute execution.

## Scope discipline

The single-op ggml-to-DirectML seam is complete. The next action is the first model-facing dry run: load the supplied GGUF into canonical host memory, inventory its actual graph operations and tensor types, exercise a four-bucket fit, and produce the kernel-coverage manifest. That action is intentionally not performed by this commit.

No complete llama layer, quantized weight kernel, persistent four-die D3D12 executor, D3D12 cross-adapter activation path, or token benchmark is claimed yet. Unsupported operations retain an explicit synchronization-and-CPU fallback design until their DirectML or shader implementation is verified.

The repository does not ship guessed registry flags, captured PowerPlay blobs, hard-coded adapter class keys, or unsigned driver folklore. Windows enablement work must discover targets programmatically, parse structures, back up original state, read changes back, and provide rollback.

## System under test

- Windows 11 IoT Enterprise LTSC, build 26100
- PowerShell 7.7.0-preview.4, x64 CoreCLR
- Two Radeon Pro V340L cards: four Vega 10 dies, 8 GiB HBM2 per die
- AMD driver `31.0.12044.3` (22.Q4)
- Stock upstream llama.cpp build 11223, commit `4da633776`

## License

MIT
