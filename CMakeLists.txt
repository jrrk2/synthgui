cmake_minimum_required(VERSION 3.16)
project(synthgui LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release)
endif()
find_package(Qt6 REQUIRED COMPONENTS Widgets)
# the converters the pipeline runs as `synthgui --tool NAME` (tools/): the bitstream path needs no Python
set(SYNTHGUI_TOOLS tools/fasm2frames/fasm2frames.cpp tools/bit2uf2/bit2uf2.cpp tools/sta_prep/sta_prep.cpp tools/bram_fom/bram_fom.cpp)
set(SYNTHGUI_VERSION "0.1.1" CACHE STRING "version shown in the app bundle")
option(SYNTHGUI_BUNDLE "build synthgui.app (scripts/package-macos.sh) instead of the bare build/synthgui" OFF)
if(SYNTHGUI_BUNDLE)
    add_executable(synthgui MACOSX_BUNDLE main.cpp ${SYNTHGUI_TOOLS})
else()
    add_executable(synthgui main.cpp ${SYNTHGUI_TOOLS})
endif()
set_target_properties(synthgui PROPERTIES
    MACOSX_BUNDLE_BUNDLE_NAME "synthgui"
    MACOSX_BUNDLE_GUI_IDENTIFIER "uk.kimmitt.synthgui"
    MACOSX_BUNDLE_BUNDLE_VERSION "${SYNTHGUI_VERSION}"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "${SYNTHGUI_VERSION}"
    MACOSX_BUNDLE_COPYRIGHT "Jonathan Kimmitt")
target_link_libraries(synthgui PRIVATE Qt6::Widgets)

