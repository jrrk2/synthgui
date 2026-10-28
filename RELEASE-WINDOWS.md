# Releasing synthgui for Windows

How the Windows package is built, checked, signed and released, and what was learnt getting there. The build itself is
described in the README (*Windows*); this file is the release procedure.

## What a release is

`synthgui-VERSION-windows-x64.zip`: one folder that runs with nothing installed (no MSYS2, bash, Perl or Python).

| Path in the zip | Contents |
| --- | --- |
| `bin/` | `synthgui.exe`, Qt (windeployqt) and the MinGW runtime |
| `build-deps/prefix/bin/` | `verilator_bin.exe`, `sta.exe`, `openFPGALoader.exe` |
| `build-deps/prefix/share/`, `lib/tcl8.6` | Verilator's include files, openFPGALoader's data, Tcl's script library for `sta` |
| `build-deps/nextpnr/` | `nextpnr-himbaechel.exe` and the xc7a50t and xc7vx485t chip databases |
| `build-deps/fasm2netlist/` | `tileverilog.exe`, `lvs_equiv.exe` |
| `build-deps/prjxray/tools/` | `xc7frames2bit.exe` |
| `deps/prjxray-db/` | the Artix-7 and Virtex-7 families |
| `xc7/`, `projects/`, `example.json` | cell models and the example projects |
| `README-Windows.txt`, `LICENSE` | running it, the WinUSB driver step for JTAG, and the GPL-3.0 |

Every directory with programs has the MINGW64 DLLs they load beside them, and synthgui runs the step commands itself
(`directPieces` in `main.cpp`), so no shell is needed.

## Making a release (GitHub Actions)

`.github/workflows/windows-release.yml` builds everything from source on GitHub-hosted Windows runners, with nothing
built cached between runs (only MSYS2's own packages are installed):

| Job | Builds | Time on a hosted runner |
| --- | --- | --- |
| `tools` | CUDD, prjxray's `xc7frames2bit`, fasm2netlist, OpenSTA, openFPGALoader (with libusb, hidapi, libftdi) | about 13 min |
| `verilator` | Verilator with ABC (the synthesis fork) | about 28 min |
| `nextpnr` | nextpnr-himbaechel, and both chip databases generated from prjxray-db | about 17 min |
| `package` | synthgui, `scripts/package-windows.sh`, signing, the zip, the draft release | about 5 min, plus the wait for a signing approval |

The first three run in parallel; a whole run took 33 minutes. The runners are real x86-64 Windows VMs (4 CPUs, 16 GB),
not emulated: Windows is slow at builds that start many processes (MSYS2 emulates `fork`) and touch many small files.

Steps:

1. Bump `SYNTHGUI_VERSION` in `CMakeLists.txt`: the zip's name comes from it. Commit and push.
2. Either test first: *Actions → Windows release → Run workflow*. The zip is the run's artifact `synthgui-windows`.
3. Or release: `git tag vX.Y.Z-windows && git push origin vX.Y.Z-windows`. The run does the same and also creates a
   **draft** release with the zip and its SHA-256.
4. Check the zip (below), then edit the draft's notes, using the v0.1.1-windows release as the model (download line, what
   is bundled, the driver step, the signing state, known issues, SHA-256, the commit it was built from), and publish.

If a job fails on something transient, *Re-run failed jobs* keeps the other jobs' artifacts. A re-run uses the commit
the run started from, so after fixing a script start a new run instead.

## Checking the zip before publishing

Download the run's artifact (`gh run download RUN --repo jrrk2/synthgui --name synthgui-windows`), unzip it to a new
folder, and with neither MSYS2 nor bash available (for example `PATH` set to `C:\Windows\System32;C:\Windows` and
`MSYS2_ROOT` pointing at a folder that does not exist, so synthgui cannot add `C:\msys64\mingw64\bin`):

- Start each program once (`bin\synthgui.exe`, everything under `build-deps\...\*.exe`). On a PC with Smart App Control
  on, any refusal shows in the event log *Microsoft-Windows-CodeIntegrity/Operational* (event 3077).
- `bin\synthgui.exe --project projects\sonata_johnson.json --run synth,pnr,fom,sta,lvs,bit,uf2,program`, with a
  Sonata plugged in and its Interface 0 on WinUSB.
- `bin\synthgui.exe --project projects\johnson.json --run synth,pnr,lvs,bit` (VC707, xc7vx485t).
- Each step's result is in `%USERPROFILE%\synthgui-work\<project>\<step>.status` (`0` is success) and `<step>.log`.

The run of 2026-10-24 (40110127725) passed all of it on Windows 11 with Smart App Control on, except *program*, which
needed the Sonata plugged in. Its xc7vx485t chip database came out byte-identical to the one in the macOS 0.1.1 release.

## Signing (Certum Open Source Code Signing)

The route is a Certum *Open Source Code Signing* certificate in the cloud (SimplySign). Its key stays in Certum's HSM and is used through the SimplySign client, which asks for a one-time code
from the phone app on each login: nothing the workflow can do from a runner. So the workflow builds the zip unsigned, and
the signing is done by hand on a Windows PC where SimplySign is logged in, before the draft release is published:

1. Download the run's artifact (or the draft release's zip) and unzip it.
2. Sign `bin\synthgui.exe` with `signtool sign /fd SHA256 /tr http://time.certum.pl /td SHA256 /a bin\synthgui.exe`
   (the timestamp keeps the signature valid after the certificate expires), then `signtool verify /pa /v` it.
3. Zip the folder again with the same name, put it on the draft release in place of the unsigned one
   (`gh release upload TAG ZIP --clobber`), and replace "Not signed" in the notes with "Signed by Certum" and the new
   SHA-256.

Until a release has been signed its notes say so. Only `synthgui.exe` is signed; the other projects' tools and the DLLs
are bundled unsigned.

Why signing matters: Windows 11's Smart App Control judges unsigned programs one by one and can block any of them, and
a user cannot allow a single program, only turn Smart App Control off (and Windows only lets it back on after a reset).
It blocked a stripped `openFPGALoader.exe` here while letting the unstripped one run, which is why the package leaves
openFPGALoader unstripped. Signing `synthgui.exe` covers synthgui itself; the bundled tools stay unsigned until their
own projects sign them.

Other routes, looked at and not taken: Azure Artifact Signing
takes individual developers only in the US and Canada, and its organisation validation needs a legal entity in public
records, which a UK sole trader is not. Cloudflare issues TLS certificates, not code-signing ones. A signing service with
an API for CI would let the workflow sign by itself, if the by-hand step becomes a burden.

## Programming boards on Windows

openFPGALoader needs the board's JTAG interface on Microsoft's WinUSB driver, set once per board and PC with Zadig;
`README-Windows.txt` in the zip has the steps (Sonata: *Sonata (Interface 0)*, `0403 6011 00`; VC707: the Digilent
device's Interface 0, `0403 6010 00`, untested). Leave the other interfaces on FTDI's driver: they are the serial ports.
Vivado's Hardware Manager no longer sees an interface after the change; *Roll Back Driver* in Device Manager undoes it.

## Known issues

- OpenSTA reports `fmax = inf` on designs with carry chains: nextpnr's SDF names those cells `…$LUT$…`, the netlist
  `sta_prep` writes names them `…$legal$…`, so the paths are not timed. Not Windows-specific as far as is known; compare a
  macOS run's `sta.log`. nextpnr's own timing report (the Place & Route log) is right.
- The Sonata *Program (SONATA drive)* step copies to `/Volumes/SONATA`, the macOS mount point; on Windows use the drive
  letter or copy the UF2 by hand.
- JTAG on a VC707 has not been tried on Windows.

## Pitfalls met on the way

- **CRLF**: Git for Windows checks out with `core.autocrlf=true`, which breaks the autotools and generator scripts. Set
  `core.autocrlf false` before cloning (the workflow does).
- **MSYS2 mirrors** sometimes stall ("Operation too slow"), failing the whole pacman transaction: the workflow retries
  the package install three times.
- **prjxray-db symlinks** (`virtex7/tileconn.json`, `kintex7/xc7k420t`): real symlinks on the runner, text files in a
  checkout with `core.symlinks` off. `package-windows.sh` copies their targets. (The 0.1.1-windows zip has the 23-byte
  text file as `virtex7/tileconn.json`; the flow's readers prefer the per-device file, so it worked regardless.)
- **Memory**: building locally with 8 GB, use `JOBS=2` or `3`, and make the xc7vx485t chip database on a run of its own
  (`CHIPDBS`); it takes several GB.
- **MSYS2 from Git for Windows' bash** loses the whole environment: export `MSYSTEM=MINGW64`, `OS=Windows_NT` and
  `USERPROFILE` inside the `bash -c` command, then `source /etc/profile`.
- **nextpnr with LTO** fails to link under MinGW ("defined in discarded section .gnu.linkonce"): `build-deps.sh` turns
  it off on Windows.

## History

- v0.1.1-windows (2026-10-24): first Windows release, built locally with `scripts/package-windows.sh` from commit
  f80ef5e, unsigned; its xc7vx485t chip database was copied from the macOS 0.1.1 release.
- 2026-10-24: the workflow's first complete run (40110127725) built the same package on GitHub, all from source.
