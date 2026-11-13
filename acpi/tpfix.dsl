//
// tpfix.dsl — standalone SSDT that only re-declares _CRS for the touchpad's
// ACPI device, changing the Interrupt() resource's sharing disposition from
// Exclusive to SharedAndWake. Compiles clean (0 errors, 0 warnings, 1 style
// remark) with `iasl -tc tpfix.dsl`, producing a 149-byte tpfix.aml.
//
// DOES NOT WORK AS A WINDOWS 7 FIX — kept here anyway because the ASL fix
// itself is still believed correct; only the *delivery mechanism* fails.
// See ../docs/code12-resource-conflict.md, section "Attempted fix #2", for
// the full explanation: Windows' registry ACPI-table-override mechanism
// only replaces a table that already exists in firmware under a matching
// OEMID/OEMTableID, with a higher OEMRevision — it cannot inject a brand
// new table with no firmware counterpart, which is what this is.
//
// If you find a way to get Windows 7 to load an *additional* SSDT that
// doesn't already exist in firmware (e.g. firmware/UEFI-level injection
// before the OS boots, rather than an OS-level registry override), this is
// the fix to use.
//
// Adjust \_SB.PCI0.I2C1.ETPD to your own touchpad's ACPI device path.
//
DefinitionBlock ("", "SSDT", 2, "_ASUS_", "TPIRQFIX", 0x00000001)
{
    External (\_SB.PCI0.I2C1.ETPD, DeviceObj)

    Scope (\_SB.PCI0.I2C1.ETPD)
    {
        Method (_CRS, 0, Serialized)  // _CRS: Current Resource Settings
        {
            Name (SBFI, ResourceTemplate ()
            {
                I2cSerialBusV2 (0x0015, ControllerInitiated, 0x00061A80,
                    AddressingMode7Bit, "\\_SB.PCI0.I2C1",
                    0x00, ResourceConsumer, , Exclusive,
                    )
                Interrupt (ResourceConsumer, Level, ActiveLow, SharedAndWake, ,, )
                {
                    0x0000006D,
                }
            })
            Return (SBFI)
        }
    }
}
