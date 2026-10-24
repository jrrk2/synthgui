synthgui for Windows
====================

The Qt front end for the open FPGA flow (Verilator mapper, nextpnr-himbaechel, prjxray bitstream, openFPGALoader),
with the tools bundled. Nothing else needs installing to run it: no MSYS2, no bash, no Perl, no Python.

Start bin\synthgui.exe. The folder can live anywhere, but keep it together: synthgui finds the tools, the chip
databases and the example projects (projects\) relative to bin\.


Programming a board: one-off USB driver step
--------------------------------------------

openFPGALoader talks to the board's FTDI USB chip through libusb, and Windows only lets libusb open a USB interface
that uses Microsoft's WinUSB driver. When a board is first plugged in, Windows gives every interface of its FTDI chip
FTDI's own serial-port driver instead, and openFPGALoader then finds no devices ("unable to open ftdi device",
"Entity not found"). Change the driver of the JTAG interface, once per board and per PC:

 1. Plug the board in and power it up.
 2. Download Zadig from https://zadig.akeo.ie and run it. Windows asks for administrator rights; allow it.
 3. In Zadig, open the Options menu and tick "List All Devices".
 4. In the drop-down list choose the board's JTAG interface:
      Sonata:  "Sonata (Interface 0)"
               the USB ID row must read  0403  6011  00   (the last box is the interface number)
      VC707:   the Digilent JTAG interface, "Interface 0" of the Digilent device
               the USB ID row must read  0403  6010  00
    Do not pick interfaces 1, 2 or 3: those are the board's serial ports (COM ports) and keep working only if
    they keep FTDI's driver.
 5. In the box to the right of the green arrow, select WinUSB.
 6. Click "Replace Driver" (it may say "Install Driver") and wait for "The driver was installed successfully".
 7. Close Zadig.

To check, open a Command Prompt in this folder and run

    build-deps\prefix\bin\openFPGALoader.exe --scan-usb

The board should be listed (the Sonata as "ft4232 ... Sonata"). Then

    build-deps\prefix\bin\openFPGALoader.exe -c ft4232 --detect          (Sonata)
    build-deps\prefix\bin\openFPGALoader.exe -c digilent --detect        (VC707)

should print the FPGA: xc7a50t for the Sonata, xc7vx485t for the VC707.

Vivado: Xilinx's Hardware Manager uses its own Digilent/FTDI driver, so after this change it no longer sees that
interface. To give the board back to Vivado (or to undo the change for any other reason): Device Manager, find the
interface under "Universal Serial Bus devices", open Properties, Driver tab, and choose "Roll Back Driver"; or choose
"Uninstall device" with "Attempt to remove the driver" ticked and then unplug and replug the board.


Sonata: copying a UF2 instead
-----------------------------

The Sonata can also be programmed without the driver change, by copying the .uf2 file the "UF2" step writes
(top.bit.slot1.uf2 in the project's work directory) to the board's SONATA drive in File Explorer. The project's
"Program (SONATA drive)" step copies to /Volumes/SONATA, the macOS name of that drive; on Windows edit the step to use
the drive's letter (for example E:/) or copy the file by hand. "Program (JTAG)" is the step that needs the driver
change above.


Notes
-----

- Work directories default to %USERPROFILE%\synthgui-work\<project>.
- Not code-signed yet: Windows SmartScreen may warn the first time synthgui.exe is started ("More info", then
  "Run anyway").
- Smart App Control (Windows 11, Settings > Privacy & security > Windows Security > App & browser control) judges
  unsigned programs one by one and may block some of the tools ("Part of this app has been blocked"; a step then
  fails with "cannot run"). It cannot be told to allow a single program: the choice is to wait for a signed release
  or to turn Smart App Control off, which Windows only lets you turn back on by resetting or reinstalling Windows.
