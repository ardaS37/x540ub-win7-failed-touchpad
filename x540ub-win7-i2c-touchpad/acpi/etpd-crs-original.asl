// Small excerpt (not the full DSDT, which is ASUS/Insyde/AMI's copyrighted
// firmware source and not ours to redistribute) of the one ACPI method
// relevant to this whole investigation: the `_CRS` (Current Resource
// Settings) method of the touchpad's ACPI device node, as disassembled with
// `iasl -d` from `acpidump` output taken on the actual affected machine.
//
// Device path: \_SB.PCI0.I2C1.ETPD  (ACPI _HID "ELAN1200", _CID "PNP0C50")
// Firmware table header this came from: Signature "DSDT", OEM ID "_ASUS_",
// OEM Table ID "Notebook", OEM Revision 0x01072009 — read these from your
// own acpidump output, they will differ per BIOS build.
//
// ============================================================
// AS SHIPPED BY FIRMWARE (this is what causes Device Manager Code 12 —
// see ../docs/code12-resource-conflict.md):
// ============================================================
//
//     Method (_CRS, 0, Serialized)
//     {
//         Name (SBFI, ResourceTemplate ()
//         {
//             I2cSerialBusV2 (0x0015, ControllerInitiated, 0x00061A80,
//                 AddressingMode7Bit, "\\_SB.PCI0.I2C1",
//                 0x00, ResourceConsumer, , Exclusive,
//                 )
//             Interrupt (ResourceConsumer, Level, ActiveLow, Exclusive, ,, )
//             {
//                 0x0000006D,
//             }
//         })
//         Return (SBFI)
//     }
//
// ============================================================
// PROPOSED FIX (untested end-to-end — see ../docs/code12-resource-conflict.md
// for why we believe this is right but couldn't safely deploy it):
// change the Interrupt() resource's sharing disposition from Exclusive to
// SharedAndWake. Everything else is identical.
// ============================================================
//
//     Method (_CRS, 0, Serialized)
//     {
//         Name (SBFI, ResourceTemplate ()
//         {
//             I2cSerialBusV2 (0x0015, ControllerInitiated, 0x00061A80,
//                 AddressingMode7Bit, "\\_SB.PCI0.I2C1",
//                 0x00, ResourceConsumer, , Exclusive,
//                 )
//             Interrupt (ResourceConsumer, Level, ActiveLow, SharedAndWake, ,, )
//             {
//                 0x0000006D,
//             }
//         })
//         Return (SBFI)
//     }
//
// To use this fix you need a complete, recompilable DSDT with this one line
// changed, then deploy it via the Windows registry ACPI-table-override
// mechanism with a strictly higher OEMRevision than your firmware's own copy
// (see https://learn.microsoft.com/en-us/windows-hardware/drivers/bringup/microsoft-asl-compiler).
// We could not get the rest of this particular machine's DSDT to round-trip
// cleanly through `iasl -tc` (17 unrelated pre-existing decompiler errors —
// see ../docs/code12-resource-conflict.md) and did not want to deploy a
// full-DSDT override with those unresolved on a machine we couldn't
// iteratively test against. A standalone SSDT with just this fix
// (`tpfix.dsl` in this same folder) compiles clean, but Windows' registry
// override mechanism cannot inject a brand-new table that has no firmware
// counterpart — also documented in ../docs/code12-resource-conflict.md.
