# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(rbwa LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "rbwa")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# ---------------------------------------------------------------------------
# Rust core (rbwa_core) via flutter_rust_bridge.
# Builds the cdylib with cargo and stages rbwa_core.dll next to the
# executable. The app loads it at runtime via ExternalLibrary; the Windows
# DLL search order prefers the exe directory.
# ---------------------------------------------------------------------------
set(RBWA_RUST_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../rust")
set(RBWA_RUST_TARGET_DIR "${CMAKE_BINARY_DIR}/rust_target")

# Multi-config generators (VS) can't pick a single profile at configure time,
# so both are built and the install step selects by configuration.
set(RBWA_RUST_DEBUG_LIB "${RBWA_RUST_TARGET_DIR}/debug/rbwa_core.dll")
set(RBWA_RUST_RELEASE_LIB "${RBWA_RUST_TARGET_DIR}/release/rbwa_core.dll")

file(GLOB_RECURSE RBWA_RUST_SOURCES
    "${RBWA_RUST_DIR}/src/*.rs"
    "${RBWA_RUST_DIR}/Cargo.toml")
add_custom_command(
  OUTPUT "${RBWA_RUST_DEBUG_LIB}" "${RBWA_RUST_RELEASE_LIB}"
  COMMAND ${CMAKE_COMMAND} -E env
      "CARGO_TARGET_DIR=${RBWA_RUST_TARGET_DIR}"
      cargo build --manifest-path "${RBWA_RUST_DIR}/Cargo.toml"
  COMMAND ${CMAKE_COMMAND} -E env
      "CARGO_TARGET_DIR=${RBWA_RUST_TARGET_DIR}"
      cargo build --manifest-path "${RBWA_RUST_DIR}/Cargo.toml" --release
  DEPENDS ${RBWA_RUST_SOURCES}
  COMMENT "Building Rust core (rbwa_core) via cargo..."
  VERBATIM)

add_custom_target(rbwa_core_lib
  DEPENDS "${RBWA_RUST_DEBUG_LIB}" "${RBWA_RUST_RELEASE_LIB}")

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")

# The executable exists now: make it depend on the Rust core so cargo runs
# before the bundle is assembled.
add_dependencies(${BINARY_NAME} rbwa_core_lib)


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

# Rust core dll: pick the cargo profile matching the CMake configuration
# (Debug -> dev build, Profile/Release -> release build) and place it next to
# the exe. install(CODE) can't be used here because ${CMAKE_INSTALL_PREFIX}
# holds a generator expression that only resolves inside install().
install(FILES "${RBWA_RUST_DEBUG_LIB}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  CONFIGURATIONS Debug COMPONENT Runtime)
install(FILES "${RBWA_RUST_RELEASE_LIB}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  CONFIGURATIONS Profile;Release COMPONENT Runtime)

# pdfium (bundled, BSD-3). pdfium-render loads it at runtime via libloading,
# so it must sit next to the exe. Missing file only warns: the app still
# builds, but PDF rendering fails until the dll is fetched.
set(RBWA_PDFIUM_LIB "${CMAKE_CURRENT_SOURCE_DIR}/../rust/libpdfium/pdfium.dll")
if(EXISTS "${RBWA_PDFIUM_LIB}")
  install(FILES "${RBWA_PDFIUM_LIB}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
else()
  message(WARNING "pdfium.dll not found at ${RBWA_PDFIUM_LIB} -- fetch it before building")
endif()

# OCR models (PP-OCRv4), optional at build time: the core resolves
# <exe dir>/models at runtime and reports "models not installed" if absent.
set(RBWA_MODELS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../rust/models")
if(EXISTS "${RBWA_MODELS_DIR}")
  install(DIRECTORY "${RBWA_MODELS_DIR}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
