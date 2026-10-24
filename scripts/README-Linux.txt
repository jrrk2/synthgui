synthgui for Linux
==================

The Qt front end for the open FPGA flow (Verilator mapper, nextpnr-himbaechel, prjxray bitstream, openFPGALoader),
with the tools bundled. Built on and for Ubuntu 24.04 (x86-64); on other distributions build it from source
(README.md in the repository: scripts/build-deps.sh, then cmake).

Qt is in the folder (lib/, plugins/). The tools and Qt load some of Ubuntu's own libraries; a desktop install has
most of them. Install the rest once with

    sudo apt install libboost-program-options1.83.0 libboost-iostreams1.83.0 libboost-thread1.83.0 \
        libtcl8.6 tcl-tclreadline libreadline8t64 libusb-1.0-0 libftdi1-2 libhidapi-libusb0 libgomp1 \
        libicu74 libdouble-conversion3 libb2-1 libpcre2-16-0 libmd4c0 libharfbuzz0b libfreetype6 libfontconfig1 \
        libpng16-16t64 libglib2.0-0t64 libdbus-1-3 libegl1 libopengl0 libglx0 libxkbcommon0 libxkbcommon-x11-0 \
        libx11-6 libx11-xcb1 libsm6 libice6 libxcb1 libxcb-cursor0 libxcb-icccm4 libxcb-image0 libxcb-keysyms1 \
        libxcb-randr0 libxcb-render0 libxcb-render-util0 libxcb-shape0 libxcb-shm0 libxcb-sync1 libxcb-util1 \
        libxcb-xfixes0 libxcb-xinput0 libxcb-xkb1

Start bin/synthgui. The folder can live anywhere, but keep it together: synthgui finds the tools, the chip databases
and the example projects (projects/) relative to bin/. Headless batch runs work with QT_QPA_PLATFORM=offscreen:

    QT_QPA_PLATFORM=offscreen bin/synthgui --project projects/sonata_johnson.json --run all


Programming a board: one-off udev rule
--------------------------------------

openFPGALoader opens the board's FTDI USB chip directly, which Linux only lets root do until a udev rule gives it
to your user. Once per PC:

    sudo cp 99-openfpgaloader.rules /etc/udev/rules.d/
    sudo udevadm control --reload-rules && sudo udevadm trigger
    sudo usermod -a -G plugdev $USER          # then log out and back in

Check with

    build-deps/prefix/bin/openFPGALoader --scan-usb
    build-deps/prefix/bin/openFPGALoader -c ft4232 --detect          (Sonata: xc7a50t)
    build-deps/prefix/bin/openFPGALoader -c digilent --detect        (VC707: xc7vx485t)


Sonata: copying a UF2 instead
-----------------------------

The Sonata can also be programmed by copying the .uf2 file the "UF2" step writes (top.bit.slot1.uf2 in the
project's work directory) to the board's SONATA drive. The project's "Program (SONATA drive)" step copies to
/Volumes/SONATA, the macOS name of that drive; on Linux edit the step to use where the desktop mounts it (usually
/media/$USER/SONATA) or copy the file by hand.


Notes
-----

- Work directories default to ~/synthgui-work/<project>.
- The steps run through /bin/bash.
