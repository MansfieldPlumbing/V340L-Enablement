# AMD Software: PRO Edition 22.Q4 for V340L

This is the evidence-backed Windows driver path for a V340 whose PCI revision is `REV_05`. It is not an unattended unsigned-driver installer.

## Proven package identity

AMD's [22.Q4 release notes](https://www.amd.com/en/resources/support-articles/release-notes/RN-PRO-WIN-22-Q4.html) identify package version `22.20.44`, Windows driver `31.0.12044.3`, and the official Windows 10/11 download.

| Artifact | Verified value |
|---|---|
| Official installer | `https://drivers.amd.com/drivers/prographics/amd-software-pro-edition-22.q4-win10-win11-nov15.exe` |
| Size | `597154608` bytes |
| SHA-256 | `04DB1EC2FBC1AAABDF22ACBF91BB914AC2E7140DDF241FC9418C2349335913C2` |
| Authenticode | Valid; `Advanced Micro Devices Inc.` |
| Pristine `U0385558.inf` SHA-256 | `8E809C34906D0E9361EA262F2F53D7B3898B22B7793E428110974057044BA27F` |
| Stock `U0385558.cat` SHA-256 | `684A7F6994FCE0E41F7B5CF932BA6B1ECCC441BBE2BBF872AAED8BEC89FB27E2` |
| Stock catalog signer | Microsoft Windows Hardware Compatibility Publisher |

The package is an NSIS archive. 7-Zip can unpack it without launching AMD Setup. The primary display package is `Packages\Drivers\Display\WT6A_INF`: `U0385558.inf`, `u0385558.cat`, and 159 files under `B385477`.

## Exact hardware-ID delta

The machine under test exposes four identical hardware IDs:

```text
PCI\VEN_1002&DEV_6864&SUBSYS_0C001002&REV_05
```

The pristine AMD INF contains one incompatible revision-qualified match:

```diff
-"%AMD6864.1%" = ati2mtag_R7500, PCI\VEN_1002&DEV_6864&REV_03
+"%AMD6864.1%" = ati2mtag_R7500, PCI\VEN_1002&DEV_6864&REV_05
```

That equal-length replacement is the complete functional patch. The active driver-store export on the development machine also changes the cosmetic string `Radeon Pro V340` to `Radeon Pro V340L 22Q4`; the preparation script deliberately does not. A friendly name is not a reason to alter another signed-package byte.

Run the safe preparation stage with a trusted local `7z.exe`:

```powershell
pwsh -NoProfile -File .\Prepare-AmdPro22Q4V340L.ps1 -SevenZipPath 'C:\Program Files\7-Zip\7z.exe'
```

The script discovers present V340 hardware, downloads with `Invoke-WebRequest`, validates size, hash, and AMD Authenticode, extracts only the driver package, preserves the original INF/catalog under `Evidence`, patches one byte sequence, verifies readback, and emits JSON plus a diff. It performs no certificate, BCD, driver-store, device, or reboot mutation.

## Why test-signing alone is insufficient

The pristine INF verifies as a member of AMD's Microsoft-signed catalog. The `REV_05` INF does not: SignTool reports that the modified file is not present in the specified catalog. Microsoft documents that changing an INF invalidates the package catalog relationship and that a PnP driver package must have a newly generated, signed catalog.

The required tools are therefore:

- `Inf2Cat.exe` from the Windows Driver Kit to regenerate `U0385558.cat`.
- `SignTool.exe` from the Windows SDK/WDK to sign and verify it.
- A purpose-specific self-signed code-signing certificate whose public certificate is installed in Local Machine `Root` and `TrustedPublisher` for the test window.

Relevant Microsoft documentation:

- [Catalog files and digital signatures](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/catalog-files)
- [Inf2Cat](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/inf2cat)
- [Test-signing a driver package's catalog](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/test-signing-a-driver-package-s-catalog-file)
- [Verifying a test-signed catalog](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/verifying-the-signature-of-a-test-signed-catalog-file)
- [Enable loading of test-signed drivers](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/the-testsigning-boot-configuration-option)

## Deliberately gated install sequence

Do all package work before weakening boot policy:

1. Run `Prepare-AmdPro22Q4V340L.ps1`. Preserve its receipt and the exported current driver package for rollback.
2. Install the WDK tools if `Inf2Cat.exe` is absent. On the development machine, SignTool is present but Inf2Cat is not.
3. Generate a new `U0385558.cat` over the prepared package. For Windows 11 build 26100, the current Inf2Cat target is `10_GE_X64`; add only other OS targets that will actually be supported.
4. Create a dedicated code-signing test certificate, trust its public certificate in Local Machine `Root` and `TrustedPublisher`, sign the new catalog with SHA-256, then verify both the catalog signature and INF membership with `signtool verify /v /pa /c U0385558.cat U0385558.inf`.
5. Check BitLocker, Secure Boot, Memory Integrity/HVCI, and enterprise code-integrity policy. Microsoft states that ordinary test-signing is blocked by Secure Boot; suspend BitLocker protection before a firmware Secure Boot change. Do not use `nointegritychecks`.
6. With explicit administrator consent, run `bcdedit /set testsigning on`, verify the command succeeded, and reboot.
7. Confirm Test Mode after reboot. Install only the prepared display INF with `pnputil /add-driver U0385558.inf /install`. Capture `pnputil`, SetupAPI, device-state, and driver-version receipts.
8. Verify all four `REV_05` devices are started on `31.0.12044.3`, the P2000 remains the display adapter, and the repository's DirectML verification still passes.
9. Run `bcdedit /set testsigning off` and reboot again. Re-enable Secure Boot and resume BitLocker if they were changed.
10. Re-run device, signature, and DirectML checks after the final reboot. Keep the previous driver package and test certificate removal instructions as rollback artifacts.

The reason step 9 can be tested is narrow: the AMD kernel binary remains vendor/Microsoft signed; the local test catalog authenticates the modified PnP package during staging. This must still be proven on every supported Windows configuration after Test Mode is disabled—it is not a universal promise across Secure Boot, HVCI, or WDAC policies.

## Missing automation by design

No committed script currently creates/trusts the certificate, invokes Inf2Cat, changes BCD, disables Secure Boot, suspends BitLocker, installs the driver, or reboots. Those operations need an explicit resumable state machine, administrator elevation, preflight receipts, and rollback. The preparation stage is safe to automate now; the machine-policy stage is not cargo-culted from a successful workstation snapshot.
