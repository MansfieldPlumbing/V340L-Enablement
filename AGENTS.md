# Repository contract

V340L-Enablement covers Windows driver preparation and device, operator and
transfer verification for the AMD Radeon Pro V340L. It is not an inference
runtime.

## Rules

- Scripts never install or sign drivers, change boot or test-signing policy,
  or reboot. Driver installation stays an explicit operator action.
- Use explicit executable paths; do not rely on PATH.
- Report measured values with their conditions. A transfer rate states whether
  it counts one leg or both.
- The shared host aperture is a hairpin through host memory, not a
  peer-to-peer link between dies. Describe it that way.
- Multi-device tests order work on the GPUs (fences, queue waits). A host wait
  is allowed only once, after all GPU work, for diagnostic readback.
- Generated output goes to `output/` and is not committed.

Documentation and recorded results live at
https://learn.mansfieldplumbing.dev/V340L-Enablement/.