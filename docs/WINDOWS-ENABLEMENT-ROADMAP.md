# Windows enablement roadmap

This work is deliberately parked while the no-build DirectML execution path is completed.

Nothing in this section may be shipped as a copied machine snapshot. Every mutation must be derived from discovered hardware state, backed up, range-checked, verified by readback, and reversible.

## Evidence-gated work

- Discover V340 dies by `PCI\VEN_1002&DEV_6864`; never hard-code display-class indices such as `0009`.
- Correct the HBCC 12 GiB report by changing only KMD values demonstrated on the detected driver, preserving whether each value existed and its exact prior type/value for rollback.
- Acquire AMD Software: PRO Edition 22.Q4 from AMD, record URL, Authenticode status, version, size, and SHA-256 before use.
- Patch only the detected hardware-ID revision mismatch in the extracted display INF. Require an exact nonzero old-match count, an equal new-match count, and emit a unified before/after receipt. Do not apply unrelated INF edits.
- Guide the user through test-signing enable, reboot, driver installation, test-signing disable, and final reboot. Never reboot or change boot policy without an explicit interactive confirmation.
- Replace fixed PowerPlay registry blobs with a structural parser/solver grounded in the matching Vega 10 table revision. Until all edited fields and bounds are proven, use reversible documented ADL runtime policy only.
- Dynamically back up and restore every touched registry key and driver package.
- Keep the P2000 as the display/command-queue adapter and exclude it from V340 compute policy.

## Performance language

The verified design is a system-memory aperture hairpin. Report each VRAM-to-host and host-to-VRAM leg separately. Do not describe their rates as direct die-to-die bandwidth unless a peer-memory import and byte-verified peer copy actually succeeds.
