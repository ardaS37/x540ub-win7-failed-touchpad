# Code 12 — "This device cannot find enough free resources that it can use"

This is the final, unresolved blocker. Once a driver with a clean import
table (`iaHIDI2C.sys` or `SynHidI2c.sys`, see
[attempted-drivers.md](attempted-drivers.md)) is signed/trusted and loads,
`ACPI\ELAN1200\1` fails to start with Device Manager Code 12.

## Why this is hard to debug

Code 12 is decided by the **PnP resource arbiter**, before the driver image
is ever loaded. In our testing:

- It produces **no Windows Event Log entry at all** — specifically, no
  `Microsoft-Windows-Kernel-PnP` Event 219 ("driver X failed to load"), which
  makes sense: the driver never gets that far, so there's nothing to log
  about *it*. We checked exhaustively and found nothing resource-allocation
  related tied to this device in the System log.
- It produces **no WER crash report** either (`msinfo32`'s exported
  `PnPDeviceProblemCode` history, see [attempted-drivers.md](attempted-drivers.md)
  for the format, never shows a `P4` of `0000000C` for this device across
  many repeated attempts — only `00000027` (Code 39) and `00000034` (Code 52)
  from the driver-load-level failures that happened on *other* attempts).
- The device's own **Resources tab in Device Manager doesn't exist** when
  Code 12 is active — there's nothing to show, since no resource was ever
  actually granted.

So the only way to look at this at all is indirect.

## What we checked

### Is GSI 109 actually held by another device?

No evidence of this. Device Manager's **View → Resources by type →
Interrupt request (IRQ)** list, and the system-wide "Conflicts/Sharing"
report from `msinfo32`, both show IRQ/GSI 109 only as part of a large block
(roughly GSI 88–113 in our case) generically reserved by
**"Microsoft ACPI Compliant System"** — this is the ACPI HAL's normal
placeholder reservation covering the *entire* range of possible GSI numbers
before any are individually carved out to real devices. It is not evidence of
a real competing device. No other named device appears anywhere near GSI 109
in either listing.

### The ACPI resource descriptor itself

The firmware's `_CRS` method for this device (see
[acpi/etpd-crs-original.asl](../acpi/etpd-crs-original.asl), extracted via
`acpidump`/`iasl -d` on Linux from this exact machine) returns:

```asl
I2cSerialBusV2 (0x0015, ControllerInitiated, 0x00061A80,
    AddressingMode7Bit, "\\_SB.PCI0.I2C1",
    0x00, ResourceConsumer, , Exclusive, )
Interrupt (ResourceConsumer, Level, ActiveLow, Exclusive, ,, )
{
    0x0000006D,
}
```

Note `Exclusive` on the `Interrupt()` descriptor — the firmware is telling
the OS this GSI must not be shared with anything else. Our working
hypothesis is that Windows 7's resource arbiter, for whatever reason specific
to this platform/BIOS, cannot actually satisfy an **exclusive** claim on this
particular GSI, while a **shared** claim (`SharedAndWake` instead of
`Exclusive`) would likely succeed. We did not get to test this (see below).

### Was the firmware perhaps presenting a degraded/Legacy-mode ACPI table because CSM was enabled?

Checked and ruled out. CSM was enabled in BIOS (it was required to get the
Windows 7 installer to boot at all on this UEFI firmware), but that does not
mean the *installed* OS is running in Legacy/CSM mode:

```
$ lsblk -o NAME,PTTYPE /dev/sda
sda   gpt
├─sda1  gpt   (EFI System Partition, vfat)
...
$ efibootmgr -v
Boot0001* Windows Boot Manager  HD(1,GPT,...)/\EFI\MICROSOFT\BOOT\BOOTMGFW.EFI
```

The disk is GPT and Windows 7's own boot manager entry is a native UEFI
entry pointing at `bootmgfw.efi`. Windows flatly cannot be installed in
Legacy/BIOS mode onto a GPT disk at all — so this Windows 7 install is
getting the exact same (modern, UEFI-exposed) ACPI tables that Windows 8/10
would see on this same firmware. The CSM toggle is a red herring for this
specific problem; don't spend time on it.

### Attempted fix #1: full DSDT override with `Exclusive` → `SharedAndWake`

The one-line fix is almost certainly right, but getting it into a deployable
override is where this fell apart. See
[acpi/etpd-crs-original.asl](../acpi/etpd-crs-original.asl) for the proposed
edit. To deploy it you need a **complete, recompilable replacement DSDT**
(Microsoft's ACPI table registry-override mechanism replaces whole tables,
see
[Microsoft ASL Compiler docs](https://learn.microsoft.com/en-us/windows-hardware/drivers/bringup/microsoft-asl-compiler)).
Disassembling this machine's live DSDT (`acpidump` + `iasl -d`) and
recompiling it **unmodified** already fails with 17 errors under `iasl -tc`:
repeated "Case value already specified" (decompiler mishandling a `Switch`
statement somewhere in the XHCI USB port section), "Illegal open scope on
external object from within DSDT" (a `Scope (_SB.PCI0.RP01.PXSX)` block that
the disassembler couldn't resolve standalone), and one missing object
(`\_SB.PCI0.RP01.HPME`). None of these are related to our edit — they're
pre-existing round-trip artifacts in a large, complex, modern ASUS DSDT.
Fixing all of them (by hand, with no way to verify each fix doesn't change
behavior for USB/PCIe/etc. on a machine we can't risk bricking) was judged
not worth it. If you want to pursue this path, you'll need to either:

- Get ASUS's own DSDT source (not available to us), or
- Carefully work through each of the 17 errors (mostly: deleting the
  offending re-disassembled `Switch`/`Scope` blocks and replacing them with
  equivalent hand-written ASL, verifying against the *working* Linux
  interpretation of the same table for sanity), then deploy via the registry
  override path with a **higher `OEMRevision`** than the firmware's own
  (`0x01072009` for `OEMID "_ASUS_"`, `OEMTableID "Notebook"` on our test
  unit — yours may differ, always read it from your own `acpidump` output).

### Attempted fix #2: inject a small standalone SSDT instead (safer, didn't work)

To avoid touching the 180K-line DSDT at all, we wrote a tiny, self-contained
SSDT that only re-declares `_CRS` for this one device (see
[acpi/tpfix.dsl](../acpi/tpfix.dsl) — compiles clean, 0 errors, 149-byte
AML). The idea: use the same
`HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\ACPI\...` registry
mechanism to have Windows load this as an *additional* table at boot,
leaving the real DSDT completely untouched.

**This does not work.** Per the Microsoft ASL Compiler documentation (same
link as above), the registry ACPI-table-load mechanism only *overrides* a
table that **already exists in firmware** under a matching
signature/`OEMID`/`OEMTableID`, and requires the override to carry a
**strictly higher `OEMRevision`** than the firmware copy. It has no path for
injecting a brand-new table with an `OEMTableID` the firmware never had. So a
made-up `OEMTableID` like our `"TPIRQFIX"` is simply never looked for/loaded
by Windows — there is nothing to override. (This is in contrast to how some
other OSes handle ACPI table overrides, where injecting net-new SSDTs from
an initrd/EFI-loader is explicitly supported; Windows 7's mechanism is
override-only.) We're leaving `acpi/tpfix.dsl` in this repo anyway since the
*ASL fix itself* is still the right target if someone finds a way to load an
additional SSDT on Windows 7 some other way (e.g. a custom ACPI
BIOS/UEFI-level SSDT injection done at the firmware level, outside the OS
entirely — we didn't explore that).

### Attempted fix #3: `bcdedit /set x2apicpolicy disable`

A known lever for interrupt-routing weirdness between older Windows and
modern Intel platforms. Fully reversible
(`bcdedit /set x2apicpolicy default` to undo), doesn't touch ACPI tables at
all. **Tried, did not resolve Code 12.**

## If you pick this up

The most promising untried avenues, roughly in order of how much we'd bet on
them:

1. Properly fix the full DSDT (attempt #1 above) and deploy it as a registry
   override with a kernel debugger attached so you can actually see *why*
   the arbiter rejects the Exclusive claim, rather than guessing. This is
   the "real" fix if the sharing-disposition hypothesis is correct.
2. Check whether loading the SSDT fix at the **firmware/UEFI level** (e.g. via
   a UEFI Shell `acpidump`/custom DXE driver injecting an extra SSDT before
   the OS boots, similar to what Hackintosh tooling like OpenCore does, but
   obviously without OpenCore itself since that's for a different OS) would
   let Windows 7 see it as if it came from firmware in the first place,
   sidestepping the "override needs an existing table" restriction entirely.
3. Ask ASUS support directly whether a newer BIOS revision changed this
   device's `_CRS`.
