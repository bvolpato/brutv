# SPDX-License-Identifier: GPL-3.0-or-later
foreach(name PS5_PAYLOAD_SDK BRUTV_PS5_OPENGL BRUTV_PS5_NATIVE BRUTV_PS5_PACBREW)
  if(NOT DEFINED ENV{${name}})
    message(FATAL_ERROR "Missing ${name}; use tools/build-ps5.sh")
  endif()
endforeach()
set(_sdk "$ENV{PS5_PAYLOAD_SDK}")
set(_gl "$ENV{BRUTV_PS5_OPENGL}")
set(_native "$ENV{BRUTV_PS5_NATIVE}")
set(_ports "$ENV{BRUTV_PS5_PACBREW}/user/homebrew")
set(PS5OpenGL_DIR "${_gl}/sdk/lib/cmake/PS5OpenGL")
find_package(PS5OpenGL CONFIG REQUIRED)
find_package(PkgConfig REQUIRED)
pkg_check_modules(PS5_MEDIA REQUIRED IMPORTED_TARGET libavformat libavcodec libavutil libswscale libswresample libcurl)
execute_process(COMMAND "${PKG_CONFIG_EXECUTABLE}" --static --libs libavformat libavcodec libavutil libswscale libswresample libcurl
  OUTPUT_VARIABLE _media_flags OUTPUT_STRIP_TRAILING_WHITESPACE COMMAND_ERROR_IS_FATAL ANY)
separate_arguments(_media_libraries UNIX_COMMAND "${_media_flags}")
# Ports retain a few absolute build-machine -L paths. All selected archives
# live in this isolated prefix, and no host search directory may leak in.
list(FILTER _media_libraries EXCLUDE REGEX "^-L")
execute_process(COMMAND clang-18 --print-resource-dir OUTPUT_VARIABLE _clang_resource OUTPUT_STRIP_TRAILING_WHITESPACE COMMAND_ERROR_IS_FATAL ANY)
file(GLOB _sdk_modules "${_sdk}/target/lib/*.so")
# The converter resolves imports from these public link stubs. They are import
# declarations, not runtime implementations, and are not packaged as Sony code.
list(FILTER _sdk_modules EXCLUDE REGEX "/libSceAgc(Driver)?\\.so$")
list(FILTER _sdk_modules EXCLUDE REGEX "/libScePosixForWebKit\\.so$")
add_library(brutv_ps5_platform INTERFACE)
target_sources(brutv_ps5_platform INTERFACE
  "${_native}/tooling/native/app_crt.cpp"
  "${_native}/tooling/native/app_cpp_runtime.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/../tools/console_compat.c"
  "${_gl}/source/native-app/cts_runtime_shims.c"
  "${_gl}/native-app/app_heap.c")
target_include_directories(brutv_ps5_platform INTERFACE "${_gl}/sdk/include" "${_native}/examples/update-check" ${PS5_MEDIA_INCLUDE_DIRS})
target_compile_definitions(brutv_ps5_platform INTERFACE BRUTV_PS5=1 GL_GLEXT_PROTOTYPES=1)
target_link_directories(brutv_ps5_platform INTERFACE "${_sdk}/target/lib" "${_ports}/lib")
target_link_options(brutv_ps5_platform INTERFACE
  "LINKER:-T,${CMAKE_CURRENT_LIST_DIR}/ps5-pie.ld"
  "LINKER:--version-script,${CMAKE_CURRENT_LIST_DIR}/app-symbols.map"
  "LINKER:-e,_start,--gc-sections,--as-needed"
  "LINKER:--wrap=fcntl"
  "LINKER:--wrap=fopen,--wrap=pthread_setname_np,--wrap=pthread_set_name_np"
  "LINKER:--wrap=malloc,--wrap=calloc,--wrap=realloc,--wrap=free,--wrap=posix_memalign,--wrap=malloc_usable_size")
# GNU groups resolve cyclic FFmpeg and C++ runtime dependencies without silently
# falling back to any host libraries. Platform import stubs follow static libs.
target_link_libraries(brutv_ps5_platform INTERFACE
  "-Wl,--start-group" ${_media_libraries} PS5OpenGL::OpenGL
  "${_sdk}/target/lib/libc++.a" "${_sdk}/target/lib/libc++abi.a"
  "${_sdk}/target/lib/libunwind.a" "${_clang_resource}/lib/linux/libclang_rt.builtins-x86_64.a"
  "-Wl,--end-group" ${_sdk_modules})
