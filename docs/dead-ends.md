# Dead ends — things that turned out NOT to be the problem

Saving you the time we spent on each of these.

## KMDF framework version

`hidi2c.sys` imports `WdfVersionBind`/`WdfVersionBindClass` from `WDFLDR.SYS`,
which binds to whatever KMDF "class library" version is registered on the
system. Windows 7 SP1 ships KMDF 1.9 inbox; `hidi2c.sys` comes from Windows
8.1 and could plausibly need a newer class library.

We installed the official Microsoft update that brings Windows 7 up to
**KMDF 1.11** — `KB2685811` ("Update for Kernel-Mode Driver Framework version
1.11") — confirmed it actually applied (file version `Wdf01000.sys
1.11.9200.16384`, service-package markers present under
`C:\Windows\servicing\Packages\...KB2685811...`). **This was not the actual
blocker.** The real `hidi2c.sys` problem is the missing `IoGetActivityIdIrp`/
`IoSetActivityIdIrp` kernel exports (see
[attempted-drivers.md](attempted-drivers.md)), which has nothing to do with
KMDF at all. Don't assume a KMDF-related Code 39 message means you need a
newer KMDF — check the *exact* WER/event-log string first (`.sys cannot find
ntoskrnl.exe <X>` tells you precisely which import is missing and from which
module).

Do *not* waste time on `KB2999226` either if you're on Windows 7 — that KB
number's Microsoft Update Catalog entries only cover Vista/Server 2008.
`KB3118401` is the one that actually ships for Windows 7 SP1/Server 2008 R2
SP1 (same "Universal C Runtime" update, later KB number, superseded the
2999226 branch for these OS versions — see
[windows7-compat-updates.md](windows7-compat-updates.md)).

## CSM / Legacy BIOS boot mode

See [code12-resource-conflict.md](code12-resource-conflict.md) — fully ruled
out. Disk is GPT, Windows 7 boots natively via UEFI
(`efibootmgr` shows `Windows Boot Manager` → `bootmgfw.efi`). CSM being
enabled in firmware settings (needed just to get the Win7 installer to run)
does not change this.

## A competing device already holding the interrupt

Checked via Device Manager's IRQ-by-type view and `msinfo32`'s
Conflicts/Sharing report. GSI 109 (`0x6D`, the number this device's ACPI
`_CRS` demands) is not claimed by any specific named device in either
listing — it only shows up as part of the generic, always-present
"Microsoft ACPI Compliant System" placeholder block that spans a wide GSI
range by default. There is no second real device fighting for this exact
number. See [code12-resource-conflict.md](code12-resource-conflict.md) for
the actual (still unresolved) theory, which is about the `Exclusive` sharing
disposition in the ACPI descriptor itself, not a literal two-devices-one-IRQ
conflict.

## Driver signature enforcement (Code 52) masking the real problem

Early on, every attempt failed with Code 52
(`STATUS_INVALID_IMAGE_HASH`/`0xC0000428`) because our backported/re-signed
`.sys` files weren't trusted. `F8` → "Disable Driver Signature Enforcement"
only lasts for **one single boot session** — after reboot (including just
switching OSes and back on a dual-boot machine), it resets, and you'll see
Code 52 again on the *next* boot even on a driver you already successfully
loaded once with F8 active. This cost us several redundant test cycles before
we realized the inconsistency was self-inflicted, not a new failure. Either
properly import your signing cert into both `Local Machine\Root` and
`Local Machine\TrustedPublisher` (see [driver-signing.md](driver-signing.md))
so it survives reboots, or be very disciplined about re-selecting F8 on
*every single* boot you intend to test with.
