# Native plugins of the Lumen plugin store
#   cmake -S . -B build && cmake --build build   -> plugins/<id>/bin/<platform>/
cmake_minimum_required(VERSION 3.16)
project(LumenPlugins C)

# Output folder per platform. Without an architecture suffix: Windows/Linux x64 and
# macOS universal (build with -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"); ARM64 builds
# for Windows and Linux go to "<os>-arm64" (needs Lumen 1.0 or newer).
if(CMAKE_GENERATOR_PLATFORM)
    set(_arch "${CMAKE_GENERATOR_PLATFORM}")
else()
    set(_arch "${CMAKE_SYSTEM_PROCESSOR}")
endif()
if(_arch MATCHES "^(ARM64|arm64|aarch64)$")
    set(_suffix "-arm64")
else()
    set(_suffix "")
endif()
if(WIN32)
    set(PLATFORM "windows${_suffix}")
elseif(APPLE)
    set(PLATFORM macos)
else()
    set(PLATFORM "linux${_suffix}")
endif()
message(STATUS "Lumen plugins: output folder bin/${PLATFORM}")

function(lumen_native_plugin id name)
    add_library(${name} MODULE ${ARGN})
    target_include_directories(${name} PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/include")
    set(out "${CMAKE_CURRENT_SOURCE_DIR}/plugins/${id}/bin/${PLATFORM}")
    set_target_properties(${name} PROPERTIES PREFIX "" C_VISIBILITY_PRESET hidden
        LIBRARY_OUTPUT_DIRECTORY "${out}" RUNTIME_OUTPUT_DIRECTORY "${out}")
    if(APPLE)
        set_target_properties(${name} PROPERTIES SUFFIX ".dylib")
    endif()
    if(MINGW)
        # ohne Abhängigkeit von libgcc-DLLs
        target_link_options(${name} PRIVATE -static-libgcc)
    endif()
endfunction()

lumen_native_plugin(my-aacs-handler my_decrypt_plugin plugins/my-aacs-handler/src/my_decrypt_plugin.c)
