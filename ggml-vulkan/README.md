# Closed ggml/Vulkan experiment archive
This contains the model-interception work removed from the Windows enablement root. It is evidence and experimental source, not a supported inference product.

Read the [postmortem](../docs/POSTMORTEM.md) and [original autopsy](docs/original-autopsy-20261001.md) before interpreting any receipt. Some early high-throughput runs failed correctness.

- `src/`: PowerShell emitters and the stock llama baton launcher.
- `experiments/`: probes, shaders, copied integration scripts, raw text/JSON logs and diagnostics.
- `docs/`: work orders, interim conclusions and historical discussions. They can contain hypotheses later rejected.
- `Receipts/`: earlier measurements, including unsuccessful experiments.
- `receipts/`: proof integrity inventory and device capability capture.
- [Original immutable proofs](../GGML/Vulkan/Proofs/): retained without changes or relocation.

Experimental scripts preserve their original environment paths and ABI assumptions. They are not promised to run from the archive's new layout. Stock runtime DLLs, generated managed assemblies, downloaded upstream source snapshots, models, and driver payloads are excluded from publication. The original local `scratch/` and `runtime-stock/` data remain on disk and ignored.

The current benchmark controls identify the exact upstream commit and DLL hash. A local forked build is not an interchangeable control.
