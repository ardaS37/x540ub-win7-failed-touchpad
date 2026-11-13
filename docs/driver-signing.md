# Sideloading an unsigned/backported x64 kernel driver on Windows 7 without `testsigning`

When you backport a driver file from a different Windows version (or modify
its INF), Windows 7 x64's kernel-mode code signing policy will refuse to
load it, surfacing as Device Manager **Code 52**
(`STATUS_INVALID_IMAGE_HASH`, NTSTATUS `0xC0000428`). Two ways to deal with
this:

1. `bcdedit /set testsigning on` + sign with a self-signed test cert, or
   boot-time `F8` → "Disable Driver Signature Enforcement" — both work but
   are per-boot/intrusive (testsigning puts a permanent watermark on the
   desktop; F8 resets every single boot, see
   [dead-ends.md](dead-ends.md#driver-signature-enforcement-code-52-masking-the-real-problem)).
2. **What we actually used**: generate your own self-signed code-signing
   certificate, Authenticode-sign the driver file(s) with it directly (no
   catalog needed), and import that one certificate into the target
   machine's **Local Machine → Trusted Root Certification Authorities**
   *and* **Local Machine → Trusted Publishers** stores. This is enough for
   Windows 7 x64's code-integrity check to accept the driver permanently,
   with no `testsigning` mode and no watermark, and it survives reboots.

This is standard, well-known technique (not a Windows 7 peculiarity — the
same approach works on any x64 Windows for sideloading an unsigned/
third-party kernel driver you trust), just worth writing down since it took
several iterations to pin down exactly which NTSTATUS/Code corresponds to
"your signature isn't trusted" versus the *other* failure modes documented in
[attempted-drivers.md](attempted-drivers.md).

## Steps (Linux side, generating the cert and signing)

Needs `openssl` and `osslsigncode` (the latter available via your distro's
package manager, or extractable from its `.rpm`/`.deb` without installing,
via `rpm2cpio package.rpm | cpio -idm` if you don't have root).

```sh
# 1. Generate a self-signed code-signing CA cert, long validity
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout cert_key.pem -out cert.pem -days 7300 \
  -subj "/CN=My Driver Signing Cert/O=Local Driver Signing" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,digitalSignature,keyCertSign,cRLSign" \
  -addext "extendedKeyUsage=codeSigning"

# 2. Export a PFX (for signing) and a DER .cer (for importing on Windows)
openssl pkcs12 -export -out cert.pfx -inkey cert_key.pem -in cert.pem \
  -passout pass:YOURPASSWORD
openssl x509 -in cert.pem -outform DER -out MyTestCert.cer

# 3. Authenticode-sign the driver binary directly (embeds the signature in
#    the PE, no catalog file needed at all)
osslsigncode sign -pkcs12 cert.pfx -pass YOURPASSWORD \
  -n "Description of what this is" \
  -in original_driver.sys -out signed_driver.sys
```

## Steps (Windows side, trusting the cert)

As Administrator:

```cmd
certutil -addstore "Root" MyTestCert.cer
certutil -addstore "TrustedPublisher" MyTestCert.cer
```

(Or double-click the `.cer` → "Install Certificate" → **Local Machine**
(not Current User!) → "Place all certificates in the following store" →
manually pick each of the two stores above, running it twice.)

Reboot. The signed driver should now load without needing `testsigning` or
`F8` on every subsequent boot.

## Caveat

This only gets you past Code 52. It says nothing about whether the driver
will actually *work* — see [attempted-drivers.md](attempted-drivers.md) and
[code12-resource-conflict.md](code12-resource-conflict.md) for the further
problems we hit after clearing this one.
