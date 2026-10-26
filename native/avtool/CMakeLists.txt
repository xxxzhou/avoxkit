cmake_minimum_required(VERSION 3.25)
project(avoxkit_native LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
# avox 用 /MT 静态 CRT, shim 必须一致
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")

set(AVOX_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../avox" CACHE PATH "avox source root")
set(AVOX_BUILD_DIR "${AVOX_ROOT}/build-avoxkit" CACHE PATH "avox build dir")
set(AVOX_OUT_DIR "${AVOX_BUILD_DIR}/install/AMD64/Release" CACHE PATH "avox install output")
set(KIT_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../third_party/ffmpeg/kit" CACHE PATH "ffmpeg kit")

set(AVOX_LIB "${AVOX_OUT_DIR}/avox.lib")
set(AVOX_DLL "${AVOX_OUT_DIR}/avox.dll")
if(NOT EXISTS "${AVOX_LIB}")
  message(FATAL_ERROR
    "avox 未构建: ${AVOX_LIB} 不存在。先按 docs/m1-kickoff.md §1.2 构建 avox。")
endif()

file(GLOB_RECURSE AK_SOURCES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/src/*.cpp")

add_library(avoxkit_native SHARED ${AK_SOURCES})
target_include_directories(avoxkit_native PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/third_party"
  "${AVOX_BUILD_DIR}/install/include"
  "${KIT_DIR}/include")
target_compile_definitions(avoxkit_native PRIVATE
  AVOXKIT_NATIVE_EXPORTS
  NOMINMAX
  WIN32_LEAN_AND_MEAN
  _CRT_SECURE_NO_WARNINGS)
target_compile_options(avoxkit_native PRIVATE
  $<$<CXX_COMPILER_ID:MSVC>:/utf-8>)
target_link_libraries(avoxkit_native PRIVATE
  "${AVOX_LIB}"
  "${KIT_DIR}/bin/avformat.lib"
  "${KIT_DIR}/bin/avcodec.lib"
  "${KIT_DIR}/bin/avutil.lib"
  "${KIT_DIR}/bin/swresample.lib")
if(MSVC)
  # Release 也出 PDB / MAP, 崩溃时能按 RVA 定位到函数
  target_link_options(avoxkit_native PRIVATE /DEBUG /MAP)
endif()

add_executable(ak_smoke tools/ak_smoke.cpp)
target_include_directories(ak_smoke PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/third_party")
target_compile_definitions(ak_smoke PRIVATE
  NOMINMAX
  WIN32_LEAN_AND_MEAN
  _CRT_SECURE_NO_WARNINGS)
target_compile_options(ak_smoke PRIVATE
  $<$<CXX_COMPILER_ID:MSVC>:/utf-8>)
target_link_libraries(ak_smoke PRIVATE avoxkit_native)

# 只带 kit 的 ffmpeg + avox.dll, 不带 avox 3rdparty 的 ffmpeg
file(GLOB KIT_DLLS "${KIT_DIR}/bin/*.dll")
set(AK_RUNTIME_DLLS "${AVOX_DLL}" ${KIT_DLLS})
add_custom_command(TARGET avoxkit_native POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
          ${AK_RUNTIME_DLLS} "$<TARGET_FILE_DIR:avoxkit_native>"
  COMMENT "Copy avox/ffmpeg runtime DLLs")
