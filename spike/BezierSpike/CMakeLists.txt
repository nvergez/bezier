# Bézier CEF spike part 2: minimal AppKit app embedding a CEF browser in an
# app-owned NSView. Modeled on the cefsimple sample from the CEF binary
# distribution, restructured as an external project (find_package(CEF)) with a
# Swift UI layer on top of an Obj-C++ bridge.
#
# Usage:
#   cmake -G Ninja -B build -DCMAKE_BUILD_TYPE=Release \
#     [-DCEF_ROOT=/path/to/cef_binary_...] .
#   ninja -C build
# Output: build/Release/BezierSpike.app

cmake_minimum_required(VERSION 3.21)

project(BezierSpike LANGUAGES C CXX Swift)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

# Path to the CEF binary distribution (part 1's cache location by default).
if(NOT DEFINED CEF_ROOT)
  set(CEF_ROOT "$ENV{HOME}/cef-spike-cache/cef_binary_150.0.11+gb887805+chromium-150.0.7871.115_macosarm64")
endif()
if(NOT IS_DIRECTORY "${CEF_ROOT}")
  message(FATAL_ERROR "CEF binary distribution not found at ${CEF_ROOT}. "
                      "Pass -DCEF_ROOT=... (see docs/spike/cefclient-evidence.md).")
endif()

set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} "${CEF_ROOT}/cmake")
find_package(CEF REQUIRED)

if(NOT OS_MAC)
  message(FATAL_ERROR "This spike targets macOS only.")
endif()

# Build with ARC, like the cefsimple sample's default.
list(APPEND CEF_COMPILER_FLAGS -fobjc-arc)

# Build libcef_dll_wrapper (C++ ↔ libcef ABI glue) from the distribution.
add_subdirectory(${CEF_LIBCEF_DLL_WRAPPER_PATH} libcef_dll_wrapper)

PRINT_CEF_CONFIG()

#
# Target names / bundle metadata.
#

set(SPIKE_TARGET "BezierSpike")
set(SPIKE_HELPER_TARGET "BezierSpike_Helper")
set(SPIKE_HELPER_OUTPUT_NAME "BezierSpike Helper")
set(VERSION_SHORT "0.1.0")

SET_CEF_TARGET_OUT_DIR()
set(SPIKE_APP "${CEF_TARGET_OUT_DIR}/${SPIKE_TARGET}.app")

#
# Swift UI layer. A separate static library because the Ninja generator cannot
# mix Swift and C-family sources in one target. It sees the Obj-C facade
# (CefBridge.h, no C++ in it) through the bridging header.
#

add_library(BezierUI STATIC src/AppDelegate.swift)
set_target_properties(BezierUI PROPERTIES Swift_MODULE_NAME "BezierUI")
target_compile_options(BezierUI PRIVATE
  -import-objc-header "${CMAKE_CURRENT_SOURCE_DIR}/src/CefBridge.h")

#
# Main app bundle target (Obj-C++: CEF bootstrap, bridge, message pump).
#

set(SPIKE_SRCS
  src/main.mm
  src/CefBridge.h
  src/CefBridge.mm
  src/BezierClient.h
  src/BezierClient.mm
  src/BezierCefApp.h
  src/BezierCefApp.mm
  src/BezierMessagePump.h
  src/BezierMessagePump.mm
  )

# Variables referenced from Info.plist.in at configure time.
set(EXECUTABLE_NAME "${SPIKE_TARGET}")
set(PRODUCT_NAME "${SPIKE_TARGET}")

add_executable(${SPIKE_TARGET} MACOSX_BUNDLE ${SPIKE_SRCS})
SET_EXECUTABLE_TARGET_PROPERTIES(${SPIKE_TARGET})
add_dependencies(${SPIKE_TARGET} libcef_dll_wrapper BezierUI)
# -force_load so the Swift AppDelegate class (referenced only via
# NSClassFromString) survives static-library dead stripping.
target_link_libraries(${SPIKE_TARGET}
  libcef_dll_wrapper
  ${CEF_STANDARD_LIBS}
  "-Wl,-force_load,$<TARGET_FILE:BezierUI>"
  )
# Search path for the auto-linked Swift runtime .tbd stubs.
execute_process(COMMAND xcrun --show-sdk-path
                OUTPUT_VARIABLE MACOS_SDK_PATH
                OUTPUT_STRIP_TRAILING_WHITESPACE)
target_link_options(${SPIKE_TARGET} PRIVATE
  "-L${MACOS_SDK_PATH}/usr/lib/swift"
  "-L/usr/lib/swift"
  )
set_target_properties(${SPIKE_TARGET} PROPERTIES
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/mac/Info.plist.in"
  )

# Copy the CEF framework into the app bundle's Frameworks directory.
COPY_MAC_FRAMEWORK("${SPIKE_TARGET}" "${CEF_BINARY_DIR}" "${SPIKE_APP}")

#
# Helper app bundle targets (one per CEF helper process type).
#

foreach(_suffix_list ${CEF_HELPER_APP_SUFFIXES})
  string(REPLACE ":" ";" _suffix_list ${_suffix_list})
  list(GET _suffix_list 0 _name_suffix)
  list(GET _suffix_list 1 _target_suffix)
  list(GET _suffix_list 2 _plist_suffix)

  set(_helper_target "${SPIKE_HELPER_TARGET}${_target_suffix}")
  set(_helper_output_name "${SPIKE_HELPER_OUTPUT_NAME}${_name_suffix}")

  # Helper-specific Info.plist (manual substitution; see cefsimple's comment on
  # why configure_file is not used here).
  set(_helper_info_plist "${CMAKE_CURRENT_BINARY_DIR}/helper-Info${_target_suffix}.plist")
  file(READ "${CMAKE_CURRENT_SOURCE_DIR}/mac/helper-Info.plist.in" _plist_contents)
  string(REPLACE "\${EXECUTABLE_NAME}" "${_helper_output_name}" _plist_contents ${_plist_contents})
  string(REPLACE "\${PRODUCT_NAME}" "${_helper_output_name}" _plist_contents ${_plist_contents})
  string(REPLACE "\${BUNDLE_ID_SUFFIX}" "${_plist_suffix}" _plist_contents ${_plist_contents})
  string(REPLACE "\${VERSION_SHORT}" "${VERSION_SHORT}" _plist_contents ${_plist_contents})
  file(WRITE ${_helper_info_plist} ${_plist_contents})

  add_executable(${_helper_target} MACOSX_BUNDLE helper/process_helper_mac.cc)
  SET_EXECUTABLE_TARGET_PROPERTIES(${_helper_target})
  add_dependencies(${_helper_target} libcef_dll_wrapper)
  target_link_libraries(${_helper_target} libcef_dll_wrapper ${CEF_STANDARD_LIBS})
  set_target_properties(${_helper_target} PROPERTIES
    MACOSX_BUNDLE_INFO_PLIST ${_helper_info_plist}
    OUTPUT_NAME ${_helper_output_name}
    )

  add_dependencies(${SPIKE_TARGET} "${_helper_target}")

  # Copy the helper app bundle into the Frameworks directory.
  add_custom_command(
    TARGET ${SPIKE_TARGET}
    POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_directory
            "${CEF_TARGET_OUT_DIR}/${_helper_output_name}.app"
            "${SPIKE_APP}/Contents/Frameworks/${_helper_output_name}.app"
    VERBATIM
    )
endforeach()
