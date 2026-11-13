# ASUS X540UB/X540UBR I2C-HID Touchpad on Windows 7 x64 — Research Log (Unsolved)

This repository documents a deep investigation into getting the built-in ELAN1200
I2C-HID touchpad working on **Windows 7 x64**, on an ASUS X540UB/X540UBR laptop
(Kaby Lake-U / Sunrise Point-LP chipset). **The touchpad was not made to work.**
This is published so the next person who tries this does not repeat the same
dead ends, and has exact error codes, root causes, and a map of what is left
to try.

If you just want the short version: see [Status / TL;DR](#status--tldr) below.

No proprietary binaries (Microsoft/Intel/Synaptics/ASUS driver files, firmware
ACPI table dumps) are included here — only original scripts, INF files we wrote
ourselves, ASL source we wrote ourselves, and a written account of what we
found. Where a fix needs a vendor file, we tell you exactly where to get it
(a Windows ISO you're licensed for, Microsoft's own Update Catalog, etc.).

## Hardware / software identification

- Laptop: ASUS X540UB / X540UBR (Kaby Lake-U, Intel "Sunrise Point-LP" PCH)
- Touchpad: ELAN1200
  - ACPI `_HID`: `ELAN1200`
  - ACPI `_CID`: `PNP0C50` (generic "HID over I2C" compatible ID)
  - ACPI path: `\_SB.PCI0.I2C1.ETPD`
  - I2C bus: Intel Sunrise Point-LP **Serial IO I2C Controller #1**,
    `PCI\VEN_8086&DEV_9D61` (bound to Windows service `iaLPSS2_I2C`, which was
    already present and working — this part is not the problem)
  - I2C slave address: `0x15` (7-bit addressing)
  - Interrupt: ACPI `_CRS` declares a **GSI 0x6D (109 decimal)**,
    Level-triggered, ActiveLow, **Exclusive** sharing disposition (see
    [acpi/etpd-crs-original.asl](acpi/etpd-crs-original.asl))
- OS: Windows 7 SP1 x64, genuinely **UEFI boot** (confirmed via `efibootmgr`:
  `Windows Boot Manager` → `\EFI\Microsoft\Boot\bootmgfw.efi`), disk is **GPT**.
  CSM was enabled in firmware (needed to get the Windows 7 installer to run at
  all) but this does **not** mean the installed OS boots in Legacy/CSM mode —
  it doesn't. Don't waste time on the CSM angle, see
  [docs/dead-ends.md](docs/dead-ends.md).
- HID report descriptor (read from Linux's `i2c_hid_acpi` driver, which talks
  to this exact hardware successfully — the touchpad firmware itself is fine):
  - **Report ID 1**: a plain `GenericDesktop.Mouse` application collection —
    2 buttons + relative X/Y + relative wheel + horizontal scroll. This is a
    deliberate legacy fallback collection that ELAN firmware ships specifically
    for OSes without Precision-Touchpad support (Windows 7 is exactly this
    case). **This is the collection any fix needs to expose as a plain
    "HID-compliant mouse."**
  - Report ID 4: `Digitizer.TouchPad` application collection (multitouch,
    Windows-8+-style Precision Touchpad). Not reachable on Windows 7 without a
    PTP class driver stack that doesn't exist there — out of scope, don't try
    to get gestures working, only basic pointer movement is realistically
    achievable.

## Status / TL;DR

**Unresolved.** Three different Windows I2C-HID transport drivers were tried
against this exact ACPI device. All three fail, for three *different* reasons:

| Driver | Source | Result |
|---|---|---|
| `hidi2c.sys` (Microsoft, from Windows 8.1) | backported by us | **Code 39** — missing kernel exports, see below. Dead end, not fixable without binary-patching the driver. |
| `iaHIDI2C.sys` "Intel(R) Serial IO Multi-touch Miniport Driver" v12.4.0.2 | genuine Intel OEM driver, found already present on this machine's disk from earlier (pre-this-investigation) attempts | Loads cleanly (0 missing imports). Blocked by **Code 12** ("insufficient resources"). |
| `SynHidI2c.sys` "Synaptics(R) I2C Miniport" v19.4.18.37 | genuine Synaptics OEM driver, same situation | Loads cleanly (0 missing imports). Blocked by the same **Code 12**. |

The last blocker — **Code 12, PnP resource arbiter refuses to grant the
Exclusive GSI 109 interrupt this ACPI device demands** — is as far as we got.
See [docs/code12-resource-conflict.md](docs/code12-resource-conflict.md) for
everything we tried against it and why each attempt was abandoned.

**Practical workaround: use a USB or Bluetooth mouse.** We could not find a
safe fix. A fix likely exists (see "What's left to try" below) but requires
either binary-patching a driver or recompiling/overriding this laptop's full
ACPI DSDT, both of which carry real risk of breaking other hardware on a
machine we could not iteratively test against (single physical laptop, no
spare unit, no kernel debugger set up).

## What's left to try (we did not attempt these, or attempted and gave up for risk reasons)

1. **Binary-patch `hidi2c.sys`'s two unresolved imports.** It imports
   `IoGetActivityIdIrp` and `IoSetActivityIdIrp` from `ntoskrnl.exe` — both
   introduced in Windows 8, absent from Windows 7's kernel (confirmed by
   diffing the import table against a live Windows 7 `ntoskrnl.exe` export
   table with `objdump -p`). These two calls are only used for ETW activity-ID
   tagging (diagnostics/tracing), not core functionality. If you can locate
   the call sites in the compiled driver and redirect the IAT entries to small
   stub functions (return `STATUS_SUCCESS` / a zeroed GUID), the driver might
   load and run on Windows 7. We did not attempt this — it's real x64
   disassembly + IAT patching work, and still wouldn't fix the Code 12 issue
   the OEM drivers hit (see next point), so it's unclear it would even help
   end-to-end.
2. **Fix the ACPI DSDT properly and override it.** We have the full
   disassembled DSDT for this exact BIOS revision. The one-line fix
   (`Exclusive` → `SharedAndWake` on the touchpad's `Interrupt()` resource
   descriptor, see [acpi/etpd-crs-original.asl](acpi/etpd-crs-original.asl))
   is almost certainly correct — but recompiling the *entire* 180,000-line
   vendor DSDT with `iasl` produces 17 pre-existing, unrelated errors (stray
   decompiler artifacts from round-tripping a complex, modern ASUS DSDT:
   duplicate `Case` values, "illegal open scope on external object",
   a missing `_SB.PCI0.RP01.HPME` object). None of these are caused by our
   edit — they're decompiler round-trip noise that exists in the *unmodified*
   disassembly too. Fixing all 17 and then deploying a full-DSDT override
   (via `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\ACPI\DSDT\...`,
   see Microsoft's ["Microsoft ASL Compiler"](https://learn.microsoft.com/en-us/windows-hardware/drivers/bringup/microsoft-asl-compiler)
   docs) is the "real" fix, but is system-wide and risky to deploy blind on
   someone's only machine with no interactive kernel debugger set up to catch
   a bad boot. A minimal standalone SSDT injection (just overriding `_CRS` for
   the one device, see [acpi/tpfix.dsl](acpi/tpfix.dsl) — compiles clean, 0
   errors) would have been much safer, but **does not work**: Microsoft's
   registry ACPI-table-override mechanism only *replaces* a table that
   already exists in firmware under a matching `OEMID`/`OEMTableID`, with a
   strictly higher `OEMRevision` — it has no mechanism for injecting a
   brand-new table that has no firmware counterpart. Confirmed from the
   Microsoft ASL Compiler documentation page cited above.
3. **Find a BIOS setting that changes how the firmware describes this
   device's interrupt.** We didn't get far here — this is a budget ASUS
   laptop with a very limited BIOS (no "OS Type"/"ACPI version" selector that
   we could find). A BIOS update from ASUS *might* fix this if ASUS ever
   revised the ACPI tables for this model, worth checking their support page.
4. **A kernel debugger (WinDbg/KD) attached over network/USB3 debug cable**
   would let you watch the PnP resource arbiter's actual decision in real
   time instead of guessing from WER crash dumps and event logs, and would
   make attempt #1 and #2 above far less risky to iterate on. We didn't have
   this set up (would also hit the same "modern WinDbg won't run on Windows 7"
   problem documented in [docs/windows7-compat-updates.md](docs/windows7-compat-updates.md)
   that we hit with DebugView — an older WinDbg build from the Windows 7-era
   WDK would be needed).

## Contents of this repo

- [docs/attempted-drivers.md](docs/attempted-drivers.md) — every driver tried,
  exact error codes, how we got each piece of evidence (WER reports, Windows
  Event Log `Kernel-PnP` Event ID 219, `objdump` import-table diffing against
  a live `ntoskrnl.exe`).
- [docs/code12-resource-conflict.md](docs/code12-resource-conflict.md) — deep
  dive on the final blocker.
- [docs/dead-ends.md](docs/dead-ends.md) — things that turned out not to be
  the problem (KMDF version, CSM/legacy boot mode, IRQ conflicts with other
  devices), so nobody re-checks them.
- [docs/windows7-compat-updates.md](docs/windows7-compat-updates.md) — general
  notes on which Microsoft KB updates you actually need to run modern tools
  (DebugView etc.) on Windows 7 SP1 x64 in 2026, since even that took several
  wrong turns.
- [docs/driver-signing.md](docs/driver-signing.md) — how we got a
  self-extracted/backported driver to load on Windows 7 x64 without
  `bcdedit testsigning` (self-signed cert into Trusted Root + Trusted
  Publisher), for anyone else needing to sideload a driver on Win7 x64.
- `inf/` — the INF files we wrote ourselves (not the `.sys` binaries, which
  are proprietary — see each file's header comment for exactly where its
  matching `.sys` needs to come from).
- `acpi/` — the ASL source we wrote/edited ourselves (a small excerpt of the
  original relevant ACPI block, and our proposed fix), not the full
  180K-line vendor DSDT (that's ASUS/Insyde/AMI's copyrighted firmware source,
  not ours to redistribute).
- `scripts/` — the Linux-side diagnostic script used to gather all of the
  hardware facts above, and the driver re-signing workflow.

## License

Everything in this repository (`.md` docs, `.inf` files we authored, `.sh`
scripts, `.dsl`/`.asl` source we authored) is original work, released under
the MIT license (see `LICENSE`). This does **not** cover, and we make no
claim over, any Microsoft/Intel/Synaptics/ASUS proprietary file referenced by
filename, version number, or KB number in these docs — go get those from
their respective owners.
