# Icons

`OpenXC7Logo.jpg` is the logo (640x640, white background). `make-icons.py` makes every icon from it (`pip install pillow`;
the `.icns` also needs macOS's `iconutil`); the results in `icon/` are committed, so a build needs neither:

| file | used for |
| --- | --- |
| `icon/synthgui.icns` | macOS: `synthgui.app`'s icon (CMake copies it into `Contents/Resources` and sets `CFBundleIconFile`; `SYNTHGUI_BUNDLE=ON`) |
| `icon/synthgui.ico`, `synthgui.rc.in` | Windows: the icon of `synthgui.exe` in File Explorer and the taskbar (a resource, compiled in by CMake) |
| `icon/synthgui-{16..256}.png`, `icons.qrc` | the window icon inside the program on every platform (title bar, taskbar, and the Dock when not run from the `.app`) |
| `icon/synthgui-{16..512}.png`, `synthgui.desktop`, `install-desktop.sh` | Linux: the hicolor icons and menu entry in the tarball (`./install-desktop.sh` puts them in `~/.local/share`) |

From 128 px up the icon is the whole logo, circle and wordmark; below that the circle alone, since the lettering cannot be
read. The logo sits on a white rounded tile because its background is white; the macOS icon follows Apple's grid (body
824 of 1024 pixels, a soft shadow) and the others fill more of the square. The master is only 640 px, so the 1024 px macOS
representation is an upscale: a larger master would make it sharper.
