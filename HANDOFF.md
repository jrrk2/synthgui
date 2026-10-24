# Task: compile synthgui for Windows

synthgui is a single-file Qt 6 Widgets application (`main.cpp`, `options.h`, `CMakeLists.txt`). The goal is a working
`synthgui.exe` built on Windows. Nothing else in this repository is needed for that, so ignore `deps/` (3 GB of
submodules), `build-deps/`, `projects/` and `xc7/` unless a step below says otherwise. Do not run
`git submodule update` for this task.

## Build

Needs Qt 6 (Widgets; 6.5 or newer), CMake 3.16+ and a C++17 compiler (MSVC 2022, or MinGW from the Qt installer).

    git clone https://github.com/jrrk2/synthgui.git
    cd synthgui
    cmake -S . -B build -DCMAKE_PREFIX_PATH=C:/Qt/6.x.x/msvc2022_64    # or the MinGW kit
    cmake --build build --config Release
    windeployqt --release build/Release/synthgui.exe                    # copies the Qt DLLs next to it

Then run `synthgui.exe` and check that the main window opens.

## What to expect

* `main.cpp` is plain Qt apart from one POSIX assumption: pipeline steps run through `/bin/bash -c <command>`
  (`QProcess::start("/bin/bash", ...)`, in `MainWindow` where `m_proc->start` is called). On Windows that path does not
  exist. Use `bash` from the PATH (Git for Windows or MSYS2 provide it) and say in the README that it is needed.
  Keep the macOS and Linux behaviour unchanged (`#ifdef Q_OS_WIN`).
* The project files (`projects/*.json`) hold commands for macOS tools (`{prefix}/bin/verilator`, `/Volumes/SONATA`,
  Homebrew paths). They will not work on Windows; the aim here is only that the GUI builds, opens, loads a project and
  edits files. Running the FPGA flow on Windows is out of scope.
* `repoRoot()` is the directory above the executable (`build/..`). On Windows with a `build/Release/` layout that
  is `build/`, not the checkout: adjust it only if something breaks, and keep it working for the macOS `.app`
  layout (`Contents/MacOS` goes to `Contents/Resources`).
* `CMakeLists.txt` has an option `SYNTHGUI_BUNDLE` (default OFF) that builds a macOS `.app`. Leave it alone.
  `scripts/package-macos.sh` is macOS-only: Developer ID signing and notarization. Do not port it.

## Done when

`synthgui.exe` starts from a clean checkout following the commands above, with the README updated with the
Windows build instructions. Signing (an Authenticode certificate) is a separate, later task: do not sign or publish
anything.

## Rules for this repository

* Commit only when asked; the commit message ends with a `Co-Authored-By: Claude ...` line like the existing commits.
* Do not push or tag. The owner pushes.
* Do not touch `projects/sonata_romlinux-src/` (the Sonata Linux work, separate and unfinished).
