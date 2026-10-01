# GGML / Vulkan proofs

This directory contains pinned instrumentation proofs for stock llama.cpp's Vulkan backend on Radeon Pro V340L 22Q4 devices. It is not the durable V340L Emancipated runtime.

`Measure-LlamaVulkanAperture.ps1` mutates a verified release build in-process and compares stock paths with an imported host-aperture handoff. The script is intentionally restricted to llama.cpp build `11223` / commit `4da633776`, known model hashes, and V340 adapters. Matching that recipe makes the experiment reproducible; it does not establish support for other builds, drivers, models, or machines.

The important result is bounded:

- The aperture can transfer bytes exactly.
- An unsynchronized single-slot alias is fast but semantically invalid.
- A batched semantic handoff restores coherent short generation but remains near stock dual-die throughput and fails the larger prompt gate.
- No production token-rate improvement is claimed.

See [the batched semantic receipt](Receipts/batched-semantic-aperture-2026-09-30.md) for the final result. `Historical` preserves superseded experiments; `Proofs` contains transport and interception probes; `Receipts` contains raw and summarized evidence.

The durable roadmap uses stock CPU ggml as the mutable integration seam, persistent DirectML/D3D12 buckets, and explicit stock CPU fallback. See [the Gemma 4 comparison plan](../../docs/GEMMA4-DIRECTML-VS-GGML-PLAN.md).
