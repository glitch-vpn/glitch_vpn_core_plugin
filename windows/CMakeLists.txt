# The Flutter tooling requires that developers have a version of Visual Studio
# installed that includes CMake 3.14 or later. You should not increase this
# version, as doing so will cause the plugin to fail to compile for some
# customers of the plugin.
cmake_minimum_required(VERSION 3.14)

# Project-level configuration.
set(PROJECT_NAME "glitch_vpn_core")
project(${PROJECT_NAME} LANGUAGES CXX)

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# This value is used when generating builds using this plugin, so it must
# not be changed
set(PLUGIN_NAME "glitch_vpn_core_plugin")

# Any new source files that you add to the plugin should be added here.
list(APPEND PLUGIN_SOURCES
  "glitch_vpn_core_plugin.cpp"
  "glitch_vpn_core_plugin.h"
)

# Define the plugin library target. Its name must not be changed (see comment
# on PLUGIN_NAME above).
add_library(${PLUGIN_NAME} SHARED
  "include/glitch_vpn_core/glitch_vpn_core_plugin_c_api.h"
  "glitch_vpn_core_plugin_c_api.cpp"
  ${PLUGIN_SOURCES}
)

# Apply a standard set of build settings that are configured in the
# application-level CMakeLists.txt. This can be removed for plugins that want
# full control over build settings.
apply_standard_settings(${PLUGIN_NAME})

# Symbols are hidden by default to reduce the chance of accidental conflicts
# between plugins. This should not be removed; any symbols that should be
# exported should be explicitly exported with the FLUTTER_PLUGIN_EXPORT macro.
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

# Source include directories and library dependencies. Add any plugin-specific
# dependencies here.
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME}
  PRIVATE
  flutter
  flutter_wrapper_plugin
  shell32
  Advapi32
  gdiplus
  Ole32
)

# Binaries source: LIBGLITCHCORE_LOCAL → a local, gitignored windows/libs/ that
# holds all three bundled files → the pinned release (pubspec.yaml).
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/../pubspec.yaml" _pubspec)
string(REGEX MATCH "libglitchcore_version:[ \t]*([^\n\r]+)" _ "${_pubspec}")
string(STRIP "${CMAKE_MATCH_1}" LIBGLITCHCORE_VERSION)
if(NOT LIBGLITCHCORE_VERSION)
  message(FATAL_ERROR "libglitchcore_version missing in pubspec.yaml")
endif()
string(REGEX MATCH "libglitchcore_sha256:[ \t]*([^\n\r]+)" _ "${_pubspec}")
string(STRIP "${CMAKE_MATCH_1}" LIBGLITCHCORE_SHA)

if(DEFINED ENV{LIBGLITCHCORE_LOCAL})
  set(_core_win "$ENV{LIBGLITCHCORE_LOCAL}/windows")
elseif(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/libs/libglitchcore.dll"
       AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/libs/wintun.dll"
       AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/libs/glitch_vpn_core_service.exe")
  set(_core_win "${CMAKE_CURRENT_SOURCE_DIR}/libs")
else()
  set(_dl "${CMAKE_CURRENT_BINARY_DIR}/libglitchcore/${LIBGLITCHCORE_VERSION}")
  set(_zip "${_dl}.zip")
  if(NOT EXISTS "${_dl}/ffi/windows/libglitchcore.dll")
    if(NOT EXISTS "${_zip}")
      set(_url "https://github.com/glitch-vpn/libglitchcore/releases/download/${LIBGLITCHCORE_VERSION}/libglitchcore-${LIBGLITCHCORE_VERSION}.zip")
      message(STATUS "libglitchcore: downloading ${_url}")
      if(LIBGLITCHCORE_SHA)
        file(DOWNLOAD "${_url}" "${_zip}" EXPECTED_HASH SHA256=${LIBGLITCHCORE_SHA} STATUS _st)
      else()
        file(DOWNLOAD "${_url}" "${_zip}" STATUS _st)
      endif()
      list(GET _st 0 _code)
      if(NOT _code EQUAL 0)
        file(REMOVE "${_zip}")
        message(FATAL_ERROR "libglitchcore download failed: ${_st}")
      endif()
    endif()
    file(MAKE_DIRECTORY "${_dl}")
    execute_process(COMMAND ${CMAKE_COMMAND} -E tar xf "${_zip}" WORKING_DIRECTORY "${_dl}" RESULT_VARIABLE _x)
    if(NOT _x EQUAL 0)
      message(FATAL_ERROR "libglitchcore extract failed: ${_x}")
    endif()
  endif()
  set(_core_win "${_dl}/ffi/windows")
endif()

# Bundled next to the .exe; geo assets are the app's own (connect geoAssetsDir).
# The service binary rides along for the app's installer to register.
set(glitch_vpn_core_bundled_libraries
  "${_core_win}/libglitchcore.dll"
  "${_core_win}/wintun.dll"
  "${_core_win}/glitch_vpn_core_service.exe"
  PARENT_SCOPE
)

# === Tests ===
# These unit tests can be run from a terminal after building the example, or
# from Visual Studio after opening the generated solution file.

# Only enable test builds when building the example (which sets this variable)
# so that plugin clients aren't building the tests.
if (${include_${PROJECT_NAME}_tests})
set(TEST_RUNNER "${PROJECT_NAME}_test")
enable_testing()

# Add the Google Test dependency.
include(FetchContent)
FetchContent_Declare(
  googletest
  URL https://github.com/google/googletest/archive/release-1.11.0.zip
)
# Prevent overriding the parent project's compiler/linker settings
set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
# Disable install commands for gtest so it doesn't end up in the bundle.
set(INSTALL_GTEST OFF CACHE BOOL "Disable installation of googletest" FORCE)
FetchContent_MakeAvailable(googletest)

# The plugin's C API is not very useful for unit testing, so build the sources
# directly into the test binary rather than using the DLL.
add_executable(${TEST_RUNNER}
  test/glitch_vpn_core_plugin_test.cpp
  ${PLUGIN_SOURCES}
)
apply_standard_settings(${TEST_RUNNER})
target_include_directories(${TEST_RUNNER} PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(${TEST_RUNNER} PRIVATE flutter_wrapper_plugin)
target_link_libraries(${TEST_RUNNER} PRIVATE gtest_main gmock)
# The test binary compiles the plugin sources directly, so it needs the same
# native libs (icon extraction uses GDI+ / COM streams; shell APIs for enum).
target_link_libraries(${TEST_RUNNER} PRIVATE shell32 Advapi32 gdiplus Ole32)
# flutter_wrapper_plugin has link dependencies on the Flutter DLL.
add_custom_command(TARGET ${TEST_RUNNER} POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
  "${FLUTTER_LIBRARY}" $<TARGET_FILE_DIR:${TEST_RUNNER}>
)

# Enable automatic test discovery.
include(GoogleTest)
gtest_discover_tests(${TEST_RUNNER})
endif()
