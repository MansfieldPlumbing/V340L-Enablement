> Historical enablement proposals. HBCC and registry-policy ideas below are not verified enablement features. The current supported scope and checks are in the root README.

# Windows enablement roadmap

The 22.Q4 package-identification and `REV_03` to `REV_05` preparation stage is now evidence-backed. Privileged signing, boot-policy, installation, and reboot automation remains gated.

Nothing in this section may be shipped as a copied machine snapshot. Every mutation must be derived from discovered hardware state, backed up, range-checked, verified by readback, and reversible.

## Evidence-gated work

- Discover V340 dies by `PCI\VEN_1002&DEV_6864`; never hard-code display-class indices such as `0009`.
- Correct the HBCC 12 GiB report by changing only KMD values demonstrated on the detected driver, preserving whether each value existed and its exact prior type/value for rollback.
- Acquire AMD Software: PRO Edition 22.Q4 from AMD, record URL, Authenticode status, version, size, and SHA-256 before use. **Implemented safely by `Prepare-AmdPro22Q4V340L.ps1`.**
- Patch only the detected hardware-ID revision mismatch in the extracted display INF. Require exactly one old match, no pre-existing new match, an equal-length byte substitution, and verified readback. **Implemented for the proven `REV_03` to `REV_05` delta.**
- Regenerate the catalog with Inf2Cat and test-sign it. Merely retaining AMD's original catalog after changing the INF is invalid.
- Guide the user through test-signing enable, reboot, driver installation, test-signing disable, and final reboot. Never reboot or change boot policy without an explicit interactive confirmation.
- Replace fixed PowerPlay registry blobs with a structural parser/solver grounded in the matching Vega 10 table revision. Until all edited fields and bounds are proven, use reversible documented ADL runtime policy only.
- Dynamically back up and restore every touched registry key and driver package.
- Keep the P2000 as the display/command-queue adapter and exclude it from V340 compute policy.

See [`AMD-PRO-22Q4-V340L.md`](AMD-PRO-22Q4-V340L.md) for the pinned package identity, exact two-source comparison, signing requirements, and deliberately gated install sequence.

## Performance language

The verified design is a system-memory aperture hairpin. Report each VRAM-to-host and host-to-VRAM leg separately. Do not describe their rates as direct die-to-die bandwidth unless a peer-memory import and byte-verified peer copy actually succeeds.
