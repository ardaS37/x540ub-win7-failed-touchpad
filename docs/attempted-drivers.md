# Attempted drivers, in order, with exact evidence

All three drivers below were installed against the exact same ACPI device
node: `ACPI\ELAN1200\1`, ACPI path `\_SB.PCI0.I2C1.ETPD`.

How to reproduce the diagnostics below yourself:

- **WER / Problem Reports history**: open `msinfo32.exe` → `File` → `Export`,
  or use `msinfo32 /report c:\report.nfo` from a command line, then grep the
  exported `.nfo` (it's UTF-16LE XML) for `PnPDeviceProblemCode` and
  `PnPDriverNotFound` entries with `P2: ACPI\ELAN1200`. `P4` is the Device
  Manager problem code **in hex** (e.g. `00000027` = 39 decimal = Code 39).
  `P5`/`P6` are the driver filename/version that failed.
- **Live kernel-PnP load failures**: Windows Event Viewer, `System` log,
  source `Microsoft-Windows-Kernel-PnP`, Event ID `219`. The `Status` field is
  an `NTSTATUS` as an unsigned decimal — convert to hex to identify it (e.g.
  `3221226536` = `0xC0000428` = `STATUS_INVALID_IMAGE_HASH`, which Device
  Manager surfaces as Code 52).
- **Import-table verification against the real running kernel**: copy
  `C:\Windows\System32\ntoskrnl.exe` (and `hidclass.sys` etc. as needed) off
  the actual target machine, then on any Linux box with `binutils`:
  `objdump -p ntoskrnl.exe | grep -A2 'DLL Name'` lists its exports;
  `objdump -p the_driver.sys` lists what it imports. Diff the two lists by
  hand — anything the driver imports that the kernel doesn't export is a hard
  load-time failure (`Code 39`, WER string "cannot find ntoskrnl.exe `<name>`").

## 1. `hidi2c.sys` (Microsoft inbox driver, Windows 8.1, v6.3.9600.16384)

Backported from a licensed Windows 8.1 ISO (`Windows/System32/drivers/hidi2c.sys`,
paired with `mshidkmdf.sys` as its required `UpperFilters` KMDF class-extension
filter — see [inf/hidi2c.inf](../inf/hidi2c.inf) for the exact service wiring,
which Windows 8.1 does automatically via its boot hive but Windows 7 does not).

- **First failure**: Code 39 (`0x00000027`). WER detail string:
  `\SystemRoot\system32\DRIVERS\hidi2c.sys cannot find ntoskrnl.exe IoGetActivityIdIrp`
- Root cause, confirmed by import-table diff: `hidi2c.sys` imports
  `IoGetActivityIdIrp` and `IoSetActivityIdIrp` from `ntoskrnl.exe`. Both are
  **Windows 8+ only** kernel exports (ETW activity-ID IRP tagging helpers —
  used for diagnostic tracing, not core I2C/HID logic). Windows 7's
  `ntoskrnl.exe` does not export either symbol. This is an unconditional
  static import — the Windows loader refuses to load the whole driver if any
  import is unresolved, so this is a hard wall, not a missing-file problem.
- Also missing (separately): `WppRecorder.sys` (WPP software tracing helper —
  also not shipped on Windows 7, but *is* backportable from the same Win8.1
  ISO at `Windows/System32/drivers/WppRecorder.sys`; unlike `hidi2c.sys`'s
  problem, this one has a clean fix — just copy the file in, it's loaded by
  image-import resolution, not via a Service Control Manager entry, so no
  registry work is needed beyond having the file present in
  `%SystemRoot%\System32\drivers`).
- **After fixing signing and `WppRecorder.sys`**: still Code 39 for the same
  `IoGetActivityIdIrp` reason — that one is unfixable without binary-patching
  the driver (see README "What's left to try" #1).
- **Later retest, after re-signing with a different cert generation and after
  several reboots with inconsistent `bcdedit testsigning`/F8 state**: Code 52
  (`0x00000034`) instead, i.e. `STATUS_INVALID_IMAGE_HASH`. This is a
  *different* failure mode (signature trust, not missing imports) — see
  [driver-signing.md](driver-signing.md). Don't let a Code 52 on a later
  attempt confuse you into thinking the `IoGetActivityIdIrp` problem went away
  — it didn't, it's just that the earlier signature failure happens first and
  masks it when present.

**Verdict: dead end as shipped.** Would need the IAT patch described in the
README to even get a chance at running.

## 2. `iaHIDI2C.sys` — "Intel(R) Serial IO Multi-touch Miniport Driver" v12.4.0.2

This is a genuine Intel-signed OEM driver (`DriverVersion 12.4.0.2`,
`DriverProvider Intel Corporation` per its WER/PnP install record), found
already present on the test machine's disk (`C:\Windows\System32\drivers\iaHIDI2C.sys`,
49232 bytes) from an earlier, unrelated attempt — its original `.inf`
(`iahidi2c.inf`) had already been removed from the DriverStore by the time we
got here, so we wrote our own minimal INF to re-bind it
(see [inf/iaHIDI2C.inf](../inf/iaHIDI2C.inf)). Go find the real
`iaHIDI2C.sys`+`.inf`+`.cat` package yourself — it ships as part of various
Lenovo/Intel "Serial IO" driver bundles for I2C-HID touch digitizers on
Skylake/Kaby Lake platforms; search your OEM's support site for your exact
touchpad chip's PCI/ACPI IDs, or check `C:\Windows\System32\DriverStore\FileRepository\`
on any machine that's had one installed.

- **Import-table check**: 14 `ntoskrnl.exe` imports (all plain, pre-Windows-7
  APIs: `ExFreePoolWithTag`, `IoGetDeviceInterfaces`,
  `IoRegisterPlugPlayNotification`, `RtlInitAnsiString`, etc.) + the standard
  4 `WDFLDR.SYS` KMDF version-binding imports. **Zero missing imports** against
  a real Windows 7 SP1 x64 kernel. No `HIDCLASS.SYS` import at all — it
  implements the classic (pre-KMDF-split) HID minidriver contract directly,
  no separate filter needed.
- **Loads successfully** — confirmed via Windows Event Log: no
  `Kernel-PnP` Event 219 "failed to load" entry for this driver at all,
  across multiple clean-reboot test cycles (with driver-signature enforcement
  disabled via F8, since it wasn't yet trusted — see
  [driver-signing.md](driver-signing.md)).
- **But the device never starts**: Device Manager shows **Code 12**
  ("This device cannot find enough free resources that it can use") after it
  loads. See [code12-resource-conflict.md](code12-resource-conflict.md).
- No child "HID-compliant mouse" device ever appears under
  "Mice and other pointing devices", and no `HID\...` child key ever appears
  under `HKLM\SYSTEM\CurrentControlSet\Enum\HID\` for this device, confirming
  the device never actually starts far enough to expose its HID collections.

**Verdict: architecturally correct, blocked by Code 12.**

## 3. `SynHidI2c.sys` — "Synaptics(R) I2C Miniport" v19.4.18.37

Same situation as `iaHIDI2C.sys` above — a genuine Synaptics-signed OEM
driver found pre-existing on disk from an earlier attempt, original INF
already gone from the DriverStore, so we wrote our own
(see [inf/SynHidI2c.inf](../inf/SynHidI2c.inf)). This exact binary ships as
part of various Synaptics touchpad driver packages for I2C-HID digitizers;
check your OEM's support site, or `DriverStore\FileRepository\synhidi2c.inf_*`
on a machine that's had one.

- **Import-table check**: 52 `ntoskrnl.exe` imports (a larger surface than
  Intel's — includes thread/event primitives like `KeWaitForSingleObject`,
  `PsCreateSystemThread`, registry helpers like `RtlQueryRegistryValues`,
  `ZwEnumerateKey`/`ZwEnumerateValueKey`, string helpers like `strcpy_s`,
  `wcsncpy_s`) + the same 4 `WDFLDR.SYS` imports. **Zero missing imports**
  against a real Windows 7 SP1 x64 kernel.
- Also loads successfully (no Event 219 failure).
- Also blocked by **Code 12** once past the signature step.

**Verdict: architecturally correct, blocked by the same Code 12.**

## A fourth attempt that was never really viable: hand-written `x540tp.sys`

An earlier, separate attempt at a from-scratch WDM driver (`x540tp.sys`,
~32KB, built with clang/lld in a cross-compile setup, no WDK) targeted the
**PCI function itself** (`PCI\VEN_8086&DEV_9D61`) rather than the ACPI HID
device — i.e. it tried to be its own I2C-bus driver talking directly to the
DesignWare I2C controller's MMIO registers, bypassing the HID-over-I2C
transport layer entirely. This cannot coexist with Intel's `iaLPSS2_I2C`
driver, which is already correctly bound to and driving that same PCI device
(and which you need, since it's not actually broken — nothing else on the
I2C bus works without it either). The `x540tp` service was registered in the
`SYSTEM` registry hive but the PCI device stayed bound to `iaLPSS2_I2C`, so
this driver most likely never ran at all. If you want to pursue a
from-scratch driver, target the ACPI child device (`ACPI\ELAN1200`) the same
way the three real transport drivers above do, and use the SPB
(Simple Peripheral Bus) resource-hub APIs to talk I2C through the
already-working `iaLPSS2_I2C`-driven bus, not raw MMIO.
