# V340L-Enablement

Windows enablement and verification for the AMD Radeon Pro V340L: driver
package preparation, adapter discovery, DirectML operator checks and die-to-die
transfer measurements. Everything is PowerShell, calling the platform APIs directly; there is no compiler or build step.

Documentation: [learn.mansfieldplumbing.dev/V340L-Enablement](https://learn.mansfieldplumbing.dev/V340L-Enablement/)

## Scripts

| Script | Purpose |
| --- | --- |
| `Prepare-AmdPro22Q4V340L.ps1` | Downloads or validates AMD Software: PRO Edition 22.Q4, verifies signatures, extracts the display driver and prepares the V340L hardware-ID revision change. It never installs a driver, changes boot policy or reboots. |
| `Probe-DirectMLV340.ps1` | Creates D3D12 and DirectML devices on every V340L die. |
| `Test-DirectMLGemm.ps1` | Runs a deterministic FP16 DirectML GEMM on a die and verifies the result. |
| `Test-V340CrossAdapterFence.ps1` | D3D12 cross-adapter queue waits and shared-buffer copies, with no host wait between queues. |
| `Compare-V340DieTransfer.ps1` | Vulkan die-to-die transfer: CPU-bounce baseline against a shared host aperture. |
| `Measure-V340ApertureThroughput.ps1` | Multi-gigabyte transfer through the shared host aperture. |
| `Verify.ps1` | Runs the probe and the GEMM test and writes JSON results to `output/`. |

```powershell
pwsh -NoProfile -File .\Verify.ps1
```

## Verified system

Windows 11 IoT Enterprise LTSC 26100, AMD Pro 22.Q4 driver 31.0.12044.3, two
V340L cards exposing four Vega 10 (gfx900) dies with 8 GiB each.

## Results

| Measurement | Result |
| --- | --- |
| Die-to-die transfer, 64 MiB, shared host aperture (`Compare-V340DieTransfer.ps1`, 20 trials, 2026-10-02) | Median 11.59 ms, about 11.6 GB/s across both legs; 44.8x the CPU-bounce path (519 ms); byte-for-byte verified |

A layer-split llama.cpp experiment across V340L dies did not recover
single-die decode throughput; it is written up at
[learn.mansfieldplumbing.dev](https://learn.mansfieldplumbing.dev/V340L-Enablement/multi-die-investigation).

## License

MIT. See [LICENSE](LICENSE).
