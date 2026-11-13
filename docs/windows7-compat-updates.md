# Running modern tools on Windows 7 SP1 x64 in 2026

Tangential to the touchpad problem, but cost real time: we needed to run
Sysinternals **DebugView** on this machine to try to capture kernel
diagnostic output, and the current (2026-era) build simply cannot run on
Windows 7 — worth documenting since it'll bite you for any other modern tool
too.

## The actual error and why KB updates didn't fix it

Current `dbgview64.exe` (and the 32-bit `Dbgview.exe` from the same release)
fails to start with:

```
Program can't start because api-ms-win-core-libraryloader-l1-2-0.dll is
missing from your computer.
```

This looks like a simple missing-DLL problem that a "Universal CRT" update
should fix. We installed, in order:

1. `KB4490628` — 2019-03 Servicing Stack Update for Windows 7 x64
2. `KB4474419` — 2019-09 **SHA-2 code signing support** for Windows 7 x64
   (needed regardless — by 2019, nearly everything Microsoft (and most
   vendors) sign uses SHA-256, and Windows 7 SP1 only trusts SHA-1 by
   default without this; you basically can't install *anything* modern and
   signed without it)
3. `KB3118401` — Update for Kernel-Mode... no, **Universal C Runtime**
   update for Windows 7 x64 (this is the real Windows-7 equivalent of the
   "Universal CRT" update; **`KB2999226` does NOT apply to Windows 7** —
   checking the Microsoft Update Catalog, `KB2999226`'s only listed targets
   are Windows Vista and Windows Server 2008. Don't go looking for it on a
   Win7 box.)
4. The latest Visual C++ 2015-2022 Redistributable (`vc_redist.x64.exe` from
   `https://aka.ms/vs/17/release/vc_redist.x64.exe`)

All four installed cleanly (confirmed present under
`C:\Windows\servicing\Packages\`). **`api-ms-win-core-libraryloader-l1-2-0.dll`
was still missing after all four, and still is.** This is because:

`api-ms-win-core-libraryloader-l1-2-0.dll` is a **newer API-Set version**
(the `l1-2-0` suffix) than what the 2015-era Universal CRT backport provides
(`l1-1-0`, confirmed present at `C:\Windows\System32\api-ms-win-core-libraryloader-l1-1-0.dll`
after installing the above). This specific, later API-Set revision is a
genuinely Windows-10-only component that Microsoft never backported to
Windows 7 in any update. No KB fixes this. Checking the full import table of
the modern `Dbgview.exe` with `objdump -p` on Linux shows it also imports
several *other* Windows-10-only API sets that have never existed on Windows 7
at all (`api-ms-win-ntuser-sysparams-l1-1-0.dll`,
`api-ms-win-shcore-stream-winrt-l1-1-0.dll`) — so even if the libraryloader
DLL existed, this exact build would still not run.

## The actual fix: use an old build

Current Sysinternals downloads (`https://download.sysinternals.com/files/<Tool>.zip`)
only ship their latest, Windows-10+-targeted build. An **archived old
build** from before Microsoft modernized the Sysinternals build pipeline
works fine, since it only links against classic Win32 DLLs
(`KERNEL32.dll`, `USER32.dll`, `ADVAPI32.dll`, etc. — no API sets at all).
We fetched one via the Wayback Machine:

```sh
curl -L -o DebugView_old.zip \
  "https://web.archive.org/web/20150927011456if_/https://download.sysinternals.com/files/DebugView.zip"
```

(Note the `if_` suffix on the timestamp — without it, `web.archive.org`
serves an HTML-wrapped version with its own UI chrome injected into the
page, not the raw file; `id_` also works for some asset types.) The
`Dbgview.exe` inside that particular archived zip (itself dated Dec 2012,
despite being served from a Sept-2015 Wayback snapshot) only imports
classic Win32 DLLs and runs fine on Windows 7.

If you hit the same class of error with some *other* modern tool and an old
build isn't available, check its import table the same way
(`objdump -p tool.exe | grep 'DLL Name'` on Linux, or `dumpbin /imports` on
Windows) before assuming a KB update will save you — if it pulls in
`api-ms-win-ntuser-*`, `api-ms-win-shcore-stream-winrt-*`, or similarly
late-arriving API sets, no Windows 7 update exists that provides them, full
stop.

## Useful direct-download technique for Microsoft Update Catalog KBs

`catalog.update.microsoft.com` requires JavaScript for the actual download
button, but its backing `DownloadDialog.aspx` endpoint can be curled
directly once you have an update's GUID (scraped from the search results
page):

```sh
# 1. Search, scrape the GUID for the title you want
curl -s "https://www.catalog.update.microsoft.com/Search.aspx?q=KB3118401" \
  -A "Mozilla/5.0" -o search.html
grep -oE "goToDetails\('[a-f0-9-]+'\)" search.html | sort -u
# (then grep backwards from each GUID's position for the title text in a
#  nearby `NoBreakLink">` anchor to figure out which GUID is which OS/arch)

# 2. Resolve the GUID to a direct CDN URL
curl -s "https://www.catalog.update.microsoft.com/DownloadDialog.aspx" \
  -A "Mozilla/5.0" \
  --data-urlencode 'updateIDs=[{"size":0,"languages":"","uidInfo":"<GUID>","updateID":"<GUID>"}]' \
  --data-urlencode 'updateIDsBlockedForImport=' --data-urlencode 'wsusApiPresent=' \
  --data-urlencode 'contentImport=' --data-urlencode 'sku=' \
  --data-urlencode 'serverName=' --data-urlencode 'ssl=' \
  --data-urlencode 'portNumber=' --data-urlencode 'version=' \
  -o dl.html
grep -oE "https?://[^'\" ]+\.(msu|cab|exe)" dl.html
```

See `scripts/fetch-kb-update.sh` for this wrapped into a reusable script.
