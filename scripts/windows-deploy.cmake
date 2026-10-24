# Copy the DLLs synthgui.exe and its Qt plugins load into the executable's directory, so that it starts from File
# Explorer as well as from a shell with MSYS2 (or the Qt kit) on PATH.  Run after windeployqt, by CMakeLists.txt:
#
#   cmake -DEXE=path/synthgui.exe "-DDIRS=dir;dir" -P scripts/windows-deploy.cmake
#
# DIRS are where the DLLs are found (the compiler's and Qt's bin directories); Windows' own DLLs are left alone.
if(POLICY CMP0207)
    cmake_policy(SET CMP0207 NEW)  # normalize paths before matching the exclusions
endif()
get_filename_component(dest "${EXE}" DIRECTORY)
file(GLOB_RECURSE plugins "${dest}/*/*.dll")
file(GET_RUNTIME_DEPENDENCIES
    EXECUTABLES "${EXE}"
    LIBRARIES ${plugins}
    DIRECTORIES ${DIRS}
    RESOLVED_DEPENDENCIES_VAR found
    UNRESOLVED_DEPENDENCIES_VAR missing
    CONFLICTING_DEPENDENCIES_PREFIX conflict
    PRE_EXCLUDE_REGEXES "^api-ms-" "^ext-ms-"
    POST_EXCLUDE_REGEXES "[/\\\\][Ww][Ii][Nn][Dd][Oo][Ww][Ss][/\\\\]")
# a DLL found both beside the executable (windeployqt put it there) and in DIRS: the copy beside it is the one loaded
foreach(name IN LISTS conflict_FILENAMES)
    if(NOT EXISTS "${dest}/${name}")
        list(GET conflict_${name} 0 first)
        list(APPEND found "${first}")
    endif()
endforeach()
foreach(dll IN LISTS found)
    get_filename_component(dir "${dll}" DIRECTORY)
    if(NOT dir STREQUAL dest)
        file(COPY "${dll}" DESTINATION "${dest}")
    endif()
endforeach()
if(missing)
    message(WARNING "synthgui: DLLs not found in ${DIRS}: ${missing}")
endif()
