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
set(AVOX_PLUGIN_DIR "${AVOX_OUT_DIR}/plugins" CACHE PATH "avox plugins dir")
set(SHERPA_RUNTIME_DIR "${AVOX_ROOT}/build/windows/sherpa-onnx/bin/Release" CACHE PATH "sherpa runtime DLLs")
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

# 预览接/摘视口隔离测试(宿主窗, 不走 Flutter/UIA)
add_executable(ak_preview_smoke tools/ak_preview_smoke.cpp)
target_include_directories(ak_preview_smoke PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/third_party")
target_compile_definitions(ak_preview_smoke PRIVATE
  NOMINMAX
  WIN32_LEAN_AND_MEAN
  _CRT_SECURE_NO_WARNINGS)
target_compile_options(ak_preview_smoke PRIVATE
  $<$<CXX_COMPILER_ID:MSVC>:/utf-8>)
target_link_libraries(ak_preview_smoke PRIVATE avoxkit_native)

# 取消后重启预览复现: 采样子窗像素判断画面是否还在刷新
add_executable(ak_preview_restart tools/ak_preview_restart.cpp)
target_include_directories(ak_preview_restart PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/third_party")
target_compile_definitions(ak_preview_restart PRIVATE
  NOMINMAX
  WIN32_LEAN_AND_MEAN
  _CRT_SECURE_NO_WARNINGS)
target_compile_options(ak_preview_restart PRIVATE
  $<$<CXX_COMPILER_ID:MSVC>:/utf-8>)
target_link_libraries(ak_preview_restart PRIVATE avoxkit_native)

# 无头功能集成测试: 转换/封装/直拷/提取/队列/错误路径一次跑完
add_executable(ak_features_test tools/ak_features_test.cpp)
target_include_directories(ak_features_test PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/third_party")
target_compile_definitions(ak_features_test PRIVATE
  NOMINMAX
  WIN32_LEAN_AND_MEAN
  _CRT_SECURE_NO_WARNINGS)
target_compile_options(ak_features_test PRIVATE
  $<$<CXX_COMPILER_ID:MSVC>:/utf-8>)
target_link_libraries(ak_features_test PRIVATE avoxkit_native)

# 内嵌字幕导出无头测试: 有文本字幕轨就直出 SRT, 没有则跳过
add_executable(ak_subtitle_test tools/ak_subtitle_test.cpp)
target_include_directories(ak_subtitle_test PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/third_party")
target_compile_definitions(ak_subtitle_test PRIVATE
  NOMINMAX
  WIN32_LEAN_AND_MEAN
  _CRT_SECURE_NO_WARNINGS)
target_compile_options(ak_subtitle_test PRIVATE
  $<$<CXX_COMPILER_ID:MSVC>:/utf-8>)
target_link_libraries(ak_subtitle_test PRIVATE avoxkit_native)

# 图像修复无头测试: 模型就位时跑手绘 mask + 自动检测, 缺模型只验证能力探测
add_executable(ak_image_test tools/ak_image_test.cpp)
target_include_directories(ak_image_test PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/third_party"
  "${AVOX_BUILD_DIR}/install/include")
target_compile_definitions(ak_image_test PRIVATE
  NOMINMAX
  WIN32_LEAN_AND_MEAN
  _CRT_SECURE_NO_WARNINGS)
target_compile_options(ak_image_test PRIVATE
  $<$<CXX_COMPILER_ID:MSVC>:/utf-8>)
target_link_libraries(ak_image_test PRIVATE avoxkit_native "${AVOX_LIB}")

# 只带 kit 的 ffmpeg + avox.dll, 不带 avox 3rdparty 的 ffmpeg
file(GLOB KIT_DLLS CONFIGURE_DEPENDS "${KIT_DIR}/bin/*.dll")
set(AK_RUNTIME_DLLS "${AVOX_DLL}" ${KIT_DLLS})
add_custom_command(TARGET avoxkit_native POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
          ${AK_RUNTIME_DLLS} "$<TARGET_FILE_DIR:avoxkit_native>"
  COMMENT "Copy avox/ffmpeg runtime DLLs")

# 语音识别插件与 sherpa/onnxruntime 依赖; 图像修复再带 avox_cv/onnx/opencv。
# 模型不随包, 首次使用时下载
set(AK_PLUGIN_FILES "")
foreach(_name avox_sherpa.dll sherpa-onnx-c-api.dll sherpa-onnx-cxx-api.dll
              avox_cv.dll avox_onnx.dll avox_opencv.dll opencv_world4130.dll)
  if(EXISTS "${AVOX_PLUGIN_DIR}/${_name}")
    list(APPEND AK_PLUGIN_FILES "${AVOX_PLUGIN_DIR}/${_name}")
  endif()
endforeach()
if(EXISTS "${SHERPA_RUNTIME_DIR}/onnxruntime.dll")
  list(APPEND AK_PLUGIN_FILES "${SHERPA_RUNTIME_DIR}/onnxruntime.dll")
endif()
if(AK_PLUGIN_FILES)
  add_custom_command(TARGET avoxkit_native POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory
            "$<TARGET_FILE_DIR:avoxkit_native>/plugins"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            ${AK_PLUGIN_FILES}
            "$<TARGET_FILE_DIR:avoxkit_native>/plugins"
    COMMENT "Copy avox speech plugin + runtime DLLs")
endif()
