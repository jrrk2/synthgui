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
2. Either test first: *Actions → Windows release → Run workflow*. The zip is the run's artifact `synthgui-windows`
   (the package folder before signing is `synthgui-windows-unsigned`).
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

## Signing (SignPath Foundation)

Applied for on 2026-10-24; SignPath accepts projects depending on their reputation. Until then the zip is unsigned,
and its release notes must say so.

What SignPath requires, and where it is met:

- An OSI-approved licence for all components: GPL-3.0 (`LICENSE`); bundled files keep their own compatible licences.
- A "Code signing policy" on the project's home page: the README section of that name.
- Builds from source on GitHub-hosted runners, the artifact uploaded by the workflow, manual approval of each signing
  request: the workflow above.
- Only the project's own binaries are signed: `.signpath/artifact-configuration.xml` signs `bin/synthgui.exe`. The other
  projects' tools and the DLLs are bundled unsigned, which their terms allow. fasm2netlist (`tileverilog`,
  `lvs_equiv`) is jrrk2's own project and can be added there if SignPath agrees it counts.
- Multi-factor authentication on GitHub and SignPath for everyone on the team.

When the project is accepted:

1. Install the SignPath GitHub App on the repository.
2. In SignPath: link the project to the predefined *GitHub.com* trusted build system, and paste
   `.signpath/artifact-configuration.xml` as its artifact configuration.
3. In the repository settings: secret `SIGNPATH_API_TOKEN`; variables `SIGNPATH_ORGANIZATION_ID`,
   `SIGNPATH_PROJECT_SLUG`, `SIGNPATH_SIGNING_POLICY_SLUG` (and `SIGNPATH_ARTIFACT_CONFIGURATION_SLUG` if not the
   project's default). With the variables set, the workflow submits the package, waits up to five hours for the
   approval, checks the signature on `synthgui.exe` (`Get-AuthenticodeSignature`) and zips the signed folder.
4. In the README's *Code signing policy*, replace "applied for; until then the Windows zip is unsigned" with SignPath's
   attribution: "Free code signing provided by SignPath.io, certificate by SignPath Foundation".

Why signing matters: Windows 11's Smart App Control judges unsigned programs one by one and can block any of them, and
a user cannot allow a single program, only turn Smart App Control off (and Windows only lets it back on after a reset).
It blocked a stripped `openFPGALoader.exe` here while letting the unstripped one run, which is why the package leaves
openFPGALoader unstripped. Signing `synthgui.exe` covers synthgui itself; the bundled tools stay unsigned until their
own projects sign them.

Other routes, looked at and not taken: Azure Artifact Signing takes individual developers only in the US and Canada,
and its organisation validation needs a legal entity in public records, which a UK sole trader is not. A commercial
code-signing certificate in your own name (from about $250 a year) would also work, with a signtool step in
`package-windows.sh`. Cloudflare issues TLS certificates, not code-signing ones.

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
