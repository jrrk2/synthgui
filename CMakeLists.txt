cmake_minimum_required(VERSION 3.16)
project(synthgui LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release)
endif()
find_package(Qt6 REQUIRED COMPONENTS Widgets)
# the converters the pipeline runs as `synthgui --tool NAME` (tools/): the bitstream path needs no Python
set(SYNTHGUI_TOOLS tools/fasm2frames/fasm2frames.cpp tools/bit2uf2/bit2uf2.cpp tools/sta_prep/sta_prep.cpp tools/bram_fom/bram_fom.cpp)
set(SYNTHGUI_VERSION "0.1.1" CACHE STRING "version shown in the app bundle")
option(SYNTHGUI_BUNDLE "build synthgui.app (scripts/package-macos.sh) instead of the bare build/synthgui" OFF)
# The logo (assets/OpenXC7Logo.jpg; assets/make-icons.py makes the files): the window icon is in every build, the app
# bundle gets the .icns, synthgui.exe gets the .ico as a resource.
set(SYNTHGUI_RESOURCES assets/icons.qrc)
if(WIN32)
    enable_language(RC)
    set(SYNTHGUI_ICO "${CMAKE_CURRENT_SOURCE_DIR}/assets/icon/synthgui.ico")
    configure_file(assets/synthgui.rc.in "${CMAKE_CURRENT_BINARY_DIR}/synthgui.rc" @ONLY)
    list(APPEND SYNTHGUI_RESOURCES "${CMAKE_CURRENT_BINARY_DIR}/synthgui.rc")
endif()
if(SYNTHGUI_BUNDLE)
    set(SYNTHGUI_ICNS "${CMAKE_CURRENT_SOURCE_DIR}/assets/icon/synthgui.icns")
    set_source_files_properties("${SYNTHGUI_ICNS}" PROPERTIES MACOSX_PACKAGE_LOCATION Resources)
    add_executable(synthgui MACOSX_BUNDLE main.cpp ${SYNTHGUI_TOOLS} ${SYNTHGUI_RESOURCES} "${SYNTHGUI_ICNS}")
else()
    add_executable(synthgui main.cpp ${SYNTHGUI_TOOLS} ${SYNTHGUI_RESOURCES})
endif()
set_target_properties(synthgui PROPERTIES
    MACOSX_BUNDLE_BUNDLE_NAME "synthgui"
    MACOSX_BUNDLE_GUI_IDENTIFIER "uk.kimmitt.synthgui"
    MACOSX_BUNDLE_BUNDLE_VERSION "${SYNTHGUI_VERSION}"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "${SYNTHGUI_VERSION}"
    MACOSX_BUNDLE_ICON_FILE "synthgui.icns"
    MACOSX_BUNDLE_COPYRIGHT "Jonathan Kimmitt")
target_link_libraries(synthgui PRIVATE Qt6::Widgets)
# Windows: Qt, its plugins and every other DLL the build loads beside build/synthgui.exe, so it also starts from File
# Explorer (MSYS2's and the Qt kit's DLLs are not on the system PATH). SYNTHGUI_DEPLOY=OFF to skip.
option(SYNTHGUI_DEPLOY "Windows: copy the DLLs synthgui.exe needs beside it after each build" ON)
if(WIN32 AND SYNTHGUI_DEPLOY)
    get_target_property(qmake Qt6::qmake IMPORTED_LOCATION)
    get_filename_component(qtbin "${qmake}" DIRECTORY)
    get_filename_component(cxxbin "${CMAKE_CXX_COMPILER}" DIRECTORY)
    find_program(WINDEPLOYQT NAMES windeployqt6 windeployqt HINTS "${qtbin}" REQUIRED)
    add_custom_command(TARGET synthgui POST_BUILD
        COMMAND "${WINDEPLOYQT}" --no-translations --no-system-d3d-compiler --no-opengl-sw --verbose 0
                "$<TARGET_FILE:synthgui>"
        COMMAND "${CMAKE_COMMAND}" "-DEXE=$<TARGET_FILE:synthgui>" "-DDIRS=${qtbin};${cxxbin}"
                -P "${CMAKE_CURRENT_SOURCE_DIR}/scripts/windows-deploy.cmake"
        VERBATIM)
endif()

