#!/bin/sh
# Put synthgui in this user's application menu, with its icon. Nothing is installed system-wide; run it again if the
# folder moves.
here=$(cd "$(dirname "$0")" && pwd)
data=${XDG_DATA_HOME:-$HOME/.local/share}
for s in 16 24 32 48 64 128 256 512; do
    mkdir -p "$data/icons/hicolor/${s}x${s}/apps"
    cp "$here/share/icons/synthgui-$s.png" "$data/icons/hicolor/${s}x${s}/apps/synthgui.png"
done
mkdir -p "$data/applications"
sed "s#^Exec=.*#Exec=\"$here/bin/synthgui\"#" "$here/share/synthgui.desktop" > "$data/applications/synthgui.desktop"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$data/applications" >/dev/null 2>&1
command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t "$data/icons/hicolor" >/dev/null 2>&1
echo "synthgui is in your application menu (the entry is $data/applications/synthgui.desktop)"
