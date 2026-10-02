# V340L-Enablement
Windows enablement and verification for AMD Radeon Pro V340L: driver-package preparation, adapter discovery, DirectML operator probes and reproducible hardware evidence.

The former V340L-Emancipated inference experiment is closed. Its coherent GPU handoff did not recover single-die decode throughput. Read the [postmortem](docs/POSTMORTEM.md), [audit](docs/AUDIT-20261001.md) and [ggml-vulkan archive](ggml-vulkan/README.md). The separate inference project is [DirectAI](https://github.com/MansfieldPlumbing/DirectAI).

## Supported scope
- [Prepare the AMD Pro 22Q4 package](docs/AMD-PRO-22Q4-V340L.md), verify its hash/signature and prepare the documented V340L INF revision change.
- Enumerate adapters and verify D3D12/DirectML device and operator creation.
- Execute a deterministic FP16 GEMM and compare diagnostic readback with its reference.
- Preserve measured performance and transport receipts.

The preparation script does not install a driver, alter boot policy or reboot. Driver signing/installation remain explicit operator actions. This repository is not a model-serving runtime, llama.cpp fork or multi-GPU inference backend.

## Verified system
Windows 11 IoT Enterprise LTSC build 26100; AMD Pro 22Q4 driver 31.0.12044.3; two V340L cards exposing four Vega 10 / gfx900 dies, **8 GiB per die**. A Quadro P2000 served as a separate display/heterogeneous test adapter. Adapter ordinals are environment-specific; verify identity before placement. This is not four 16-GB dies.

## Run the checks
Use x64 PowerShell and explicit executable paths:

```powershell
& C:\bin\pwsh\pwsh.exe -NoProfile -File .\Probe-DirectMLV340.ps1
& C:\bin\pwsh\pwsh.exe -NoProfile -File .\Test-DirectMLGemm.ps1
& C:\bin\pwsh\pwsh.exe -NoProfile -File .\Verify.ps1
```

Verification writes JSON to `output/`. GEMM diagnostic readback occurs after the test's GPU work completes; it is not a multi-device inference handoff.

## V340L PowerPlay and HBCC facade

Double-click `V340L.cmd` in this repository, or copy `V340L*.cmd`, `V340L.ps1`, and `V340L-TUI.ps1` together to `C:\scripts\` and double-click `C:\scripts\V340L.cmd`. The window stays open after errors. `V340L-Floor.cmd`, `V340L-Presets.cmd`, `V340L-HBCC.cmd`, and `V340L-1200.cmd` are clickable shortcuts into the same PowerShell facade. The 1200 shortcut changes only the core maximum. The script discovers present V340L dies by PCI ID and resolves each device's current display-class registry key. It does not assume a card count, PCI bus, or `00XX` key number.

```powershell
& C:\bin\pwsh\pwsh.exe -NoProfile -File .\V340L.ps1 -Mode Tui
& C:\bin\pwsh\pwsh.exe -NoProfile -File .\V340L.ps1 -Mode Floor -Apply
& C:\bin\pwsh\pwsh.exe -NoProfile -File .\V340L.ps1 -Mode Preset -Preset Fast -Apply
& C:\bin\pwsh\pwsh.exe -NoProfile -File .\V340L.ps1 -CoreMaxMHz 1200 -Apply
& C:\bin\pwsh\pwsh.exe -NoProfile -File .\V340L.ps1 -Mode HBCC -Apply
```

The five clock presets are `VeryLow` (600/300 MHz core/memory maximum), `Low` (750/470), `Quiet` (900/600), `Balanced` (1050/700), and `Fast` (1200/800). `Floor` sets every core state to 300 MHz and every memory state to 167 MHz. Presets and custom edits preserve existing voltage entries. They are operator experiments, not validated voltage or power limits. Without `-Apply`, the command previews its candidate. `-Apply` requests elevation, saves a before-backup, writes the same candidate to every present die, and verifies registry readback. A reboot is needed for driver ingestion; registry readback alone does not prove loaded clocks or workload stability.

The editor accepts an existing Vega 10 PowerPlay 8.1 SPPT override with eight core and four memory dependency states. It refuses to write if a present die lacks an override or the discovered dies have different table hashes; obtain and verify the exact VBIOS PowerPlay table before first installation. On this workstation, it also updates the existing managed boot profile so it will not revert the new settings. Machines without that boot profile receive a warning and no scheduled task is created.

`-Mode HBCC` reports `KMD_EnablePageMigration` and `KMD_VirtualSegmentSize` at each discovered key. `-Apply` backs up the prior presence, type and value of both entries, writes DWORD zero, and verifies registry readback. Reboot and check dedicated memory again; this script does not reset live GPU devices. The HBCC operation is separate from PowerPlay clock editing.

## Recorded performance
See [machine-readable summary](docs/benchmarks.json) and the postmortem for controls and limitations. No new performance run is implied by this repository reorganization.

**Gemma E4B Q4_K_M**, 32 forced tokens, greedy, F16 KV, context 512, stock llama commit `4da633776`:

| Configuration | Prompt tok/s | Decode tok/s |
|---|---:|---:|
| Stock Vulkan, one V340L die | 60.4 | 40.4 |
| Stock Vulkan, two V340L dies | 45.8 | 20.8 |
| Coherent aperture/D3D12 baton, two dies | 47.0–47.8 | 21.6–21.8 |
| Coarse submissions with baton, two dies | 47.2 | 21.8 |

The baton carried 30,720 activation bytes in approximately 0.007 ms of SDMA copy time. Coarse batching reduced instrumented submission count 658 → 386 without recovering decode throughput. The remaining roughly 22 ms/token deficit was unresolved. Earlier incoherent approximately 64–71 tok/s runs are excluded.

**SD1.5 CyberRealistic-LCM family**, 512×512, six steps, seed 42, FP16, warm resident generation:

| Placement: text encoder / UNet / VAE | DirectAI / ORT DirectML | Stock sd.cpp / Vulkan |
|---|---:|---:|
| 0 / 0 / 0 | 1.838 s | 4.900 s |
| 1 / 1 / 1 | 1.681 s | 4.810 s |
| 0 / 1 / 1 | 1.692 s | 4.830 s |
| 0 / 1 / 2 | 1.705 s | 4.810 s |

The observed single-die ratio was **2.67–2.86×** in favor of DirectAI. The original ONNX and GGUF weights were **not fully identical**; timer boundaries also differ. Each UNet ran on one die. These results characterize the tested workloads and implementations, not an intrinsic Vulkan hardware bandwidth limit or a completed multi-die UNet comparison. See [DirectAI receipts](https://github.com/MansfieldPlumbing/DirectAI/tree/main/benchmarks/sd15-cyberrealistic).

The forced sd.cpp UNet split failed allocation under the tested budgets; the default two-device request actually kept the UNet on one device. Neither is a successful split benchmark.

## Repository boundaries
`docs/` documents Windows enablement and measured history. `src/` contains the shared PowerShell function-pointer binder. `ggml-vulkan/` contains the closed experiment. Original immutable proofs remain in `GGML/Vulkan/Proofs/`. Local runtime binaries, scratch data, driver packages and models are ignored.

[DirectAI's graph-builder plan](https://github.com/MansfieldPlumbing/DirectAI/blob/main/docs/GRAPH-BUILDER-PLAN.md) is separate from this repository's supported scope.
