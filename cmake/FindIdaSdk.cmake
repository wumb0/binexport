# Copyright 2011-2024 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# FindIdaSdk
# ----------
#
# Locates and configures the IDA Pro SDK. Supports version 7.0 or higher.
#
# Use this module by invoking find_package with the form:
#
#   find_package(IdaSdk
#                [REQUIRED]  # Fail with an error if IDA SDK is not found
#               )
#
# Defines the following variables:
#
#   IdaSdk_INCLUDE_DIRS - Include directories for the IDA Pro SDK.
#   IdaSdk_PLATFORM     - IDA SDK platform, one of __LINUX__, __NT__ or
#                         __MAC__.
#
# This module reads hints about search locations from variables:
#
#   IdaSdk_ROOT_DIR  - Preferred installation prefix
#
# Example (this assumes Windows):
#
#   find_package(IdaSdk REQUIRED)
#
#   # Builds targets plugin.dll
#   add_ida_plugin(plugin myplugin.cc)
#
#   Builds targets ldr.dll
#   add_ida_loader(ldr myloader.cc)
#
# To avoid the duplication above, these functions, which mimic the built-in
# ones, are also defined:
#
#   add_ida_library(<name> ...)               <=> add_libary()
#   ida_target_link_libraries(...)            <=> target_link_libraries()
#   ida_target_include_directories(...)       <=> target_include_directories()
#   set_ida_target_properties(...)            <=> set_target_properties()
#   ida_install(...)                          <=> install()

include(CMakeParseArguments)
include(FindPackageHandleStandardArgs)

find_path(IdaSdk_DIR NAMES include/pro.h
                     HINTS "${IdaSdk_ROOT_DIR}" ENV IDASDK_ROOT
                     PATHS "${CMAKE_CURRENT_LIST_DIR}/../third_party/idasdk"
                     PATH_SUFFIXES idasdk
                     DOC "Location of the IDA SDK"
                     NO_DEFAULT_PATH)
set(IdaSdk_INCLUDE_DIRS "${IdaSdk_DIR}/include")

find_package_handle_standard_args(IdaSdk
  FOUND_VAR IdaSdk_FOUND
  REQUIRED_VARS IdaSdk_DIR
                IdaSdk_INCLUDE_DIRS
  FAIL_MESSAGE "IDA SDK not found, try setting IdaSdk_ROOT_DIR"
)

if(APPLE)
  set(IdaSdk_PLATFORM __MAC__)

  # Not using find_library(), as static-lib search might be enforced in
  # calling project.
  find_path(IdaSdk_LIBPATH64_X64 libida.dylib
    PATHS "${IdaSdk_DIR}/lib" PATH_SUFFIXES "x64_mac_clang_64"
    NO_DEFAULT_PATH REQUIRED
  )
  find_path(IdaSdk_LIBPATH64_ARM64 libida.dylib
    PATHS "${IdaSdk_DIR}/lib" PATH_SUFFIXES "arm64_mac_clang_64"
    NO_DEFAULT_PATH REQUIRED
  )
  if(NOT TARGET ida64_universal)
    set(_ida64_universal_lib
      "${CMAKE_CURRENT_BINARY_DIR}/libida64_universal.dylib"
      CACHE INTERNAL ""
    )
    # Create a new "universal" library to allow the linker to select the
    # correct one per architecture. Ideally, Hex Rays would just compile
    # libida64.dylib as a universal bundle.
    add_custom_target(ida64_universal
      DEPENDS "${IdaSdk_LIBPATH64_ARM64}/libida.dylib"
              "${IdaSdk_LIBPATH64_X64}/libida.dylib"
      BYPRODUCTS "${_ida64_universal_lib}"
      COMMAND lipo -create "${IdaSdk_LIBPATH64_ARM64}/libida.dylib"
                           "${IdaSdk_LIBPATH64_X64}/libida.dylib"
                   -output "${_ida64_universal_lib}"
    )
  endif()
  add_library(ida64 SHARED IMPORTED)
  add_dependencies(ida64 ida64_universal)
  set_target_properties(ida64 PROPERTIES
    IMPORTED_LOCATION "${_ida64_universal_lib}"
  )
elseif(UNIX)
  set(IdaSdk_PLATFORM __LINUX__)

  find_path(IdaSdk_LIBPATH64 libida.so
    PATHS "${IdaSdk_DIR}/lib" PATH_SUFFIXES "x64_linux_gcc_64"
    NO_DEFAULT_PATH REQUIRED
  )
  add_library(ida64 SHARED IMPORTED)
  set_target_properties(ida64 PROPERTIES
    IMPORTED_LOCATION "${IdaSdk_LIBPATH64}/libida.so"
  )
elseif(WIN32)
  set(IdaSdk_PLATFORM __NT__)

  find_library(IdaSdk_LIB64 ida
    PATHS "${IdaSdk_DIR}/lib" PATH_SUFFIXES "x64_win_vc_64"
    NO_DEFAULT_PATH REQUIRED
  )
  add_library(ida64 SHARED IMPORTED)
  set_target_properties(ida64 PROPERTIES IMPORTED_LOCATION "${IdaSdk_LIB64}")
  set_target_properties(ida64 PROPERTIES IMPORTED_IMPLIB "${IdaSdk_LIB64}")
else()
  message(FATAL_ERROR "Unsupported system type: ${CMAKE_SYSTEM_NAME}")
endif()

function(_ida_common_target_settings t)
  # Add the necessary __IDP__ define and allow to use "dangerous" and standard
  # file functions.
  target_compile_definitions(${t} PUBLIC ${IdaSdk_PLATFORM}
                                         __EA64__
                                         __X64__
                                         __IDP__
                                         USE_DANGEROUS_FUNCTIONS
                                         USE_STANDARD_FILE_FUNCTIONS)
  target_include_directories(${t} PUBLIC "${IdaSdk_INCLUDE_DIRS}")
endfunction()

function(_ida_library name)
  add_library(${name} ${ARGN})
  _ida_common_target_settings(${name})
endfunction()

function(_ida_plugin name link_script)  # ARGN contains sources
  # Define a module with the specified sources.
  add_library(${name} MODULE ${ARGN})
  _ida_common_target_settings(${name})

  set_target_properties(${name} PROPERTIES PREFIX "")
  target_link_libraries(${name} ida64)
  if(UNIX)
    if(APPLE)
      target_link_libraries(${name}
        -Wl,-flat_namespace
        -Wl,-exported_symbol,_PLUGIN
      )
    else()
      # Always use the linker script needed for IDA.
      target_link_libraries(${name}
        -Wl,--version-script "${IdaSdk_DIR}/${link_script}")
    endif()

    # For qrefcnt_obj_t in ida.hpp
    # TODO(cblichmann): This belongs in an interface library instead.
    target_compile_options(${name} PUBLIC
      -Wno-non-virtual-dtor
      -Wno-varargs
    )
  endif()
endfunction()

function(add_ida_library name)
  _ida_library(${name} ${ARGN})
endfunction()

function(add_ida_plugin name)
  _ida_plugin(${name} plugins/exports.def ${ARGN})
endfunction()

function(add_ida_loader name)
  _ida_plugin(${name} ldr/exports.def ${ARGN})
endfunction()

function(ida_target_link_libraries name)
  target_link_libraries(${name} ${ARGN})
endfunction()

function(ida_target_include_directories name)
  target_include_directories(${name} ${ARGN})
endfunction()

function(set_ida_target_properties name)
  set_target_properties(${name} ${ARGN})
endfunction()

function(ida_install)
  install(${ARGN})
endfunction()
