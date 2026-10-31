cmake_minimum_required(VERSION 3.25)
project(avoxkit_native LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")

set(AVOX_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../avox" CACHE PATH "avox source root")

if(APPLE)
  # 与 avox build_mac.py 保持一致; 混架构会在加载时直接失败
  set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "macOS architecture")
  set(CMAKE_OSX_DEPLOYMENT_TARGET "12.0" CACHE STRING "macOS deployment target")
  set(AVOX_BUILD_DIR "${AVOX_ROOT}/build/macos/avox" CACHE PATH "avox build dir")
  set(AVOX_OUT_DIR "${AVOX_BUILD_DIR}/install/aarch64/Release" CACHE PATH "avox install output")
  set(AVOX_PLUGIN_DIR "${AVOX_OUT_DIR}/plugins" CACHE PATH "avox plugins dir")
  set(KIT_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../third_party/ffmpeg/kit-macos" CACHE PATH "ffmpeg kit")
  set(AVOX_LIB "${AVOX_OUT_DIR}/libavox.a")
  set(AVOX_ASSETS_DIR "${AVOX_ROOT}/glsl/target" CACHE PATH "avox compiled shaders")
  set(MOLTENVK_DYLIB "${AVOX_OUT_DIR}/../libMoltenVK.dylib"
      CACHE FILEPATH "MoltenVK (loaded by volk as libvulkan.1.dylib)")
  set(ONNXRUNTIME_DYLIB "${AVOX_ROOT}/../avox_library/3rdparty/library/darwin/onnxruntime/lib/libonnxruntime.1.23.2.dylib"
      CACHE FILEPATH "onnxruntime dylib for plugins")
else()
  # avox 用 /MT 静态 CRT, shim 必须一致
  set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
  set(AVOX_BUILD_DIR "${AVOX_ROOT}/build-avoxkit" CACHE PATH "avox build dir")
  set(AVOX_OUT_DIR "${AVOX_BUILD_DIR}/install/AMD64/Release" CACHE PATH "avox install output")
  set(AVOX_PLUGIN_DIR "${AVOX_OUT_DIR}/plugins" CACHE PATH "avox plugins dir")
  set(SHERPA_RUNTIME_DIR "${AVOX_ROOT}/build/windows/sherpa-onnx/bin/Release" CACHE PATH "sherpa runtime DLLs")
  set(KIT_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../third_party/ffmpeg/kit" CACHE PATH "ffmpeg kit")
  set(AVOX_LIB "${AVOX_OUT_DIR}/avox.lib")
  set(AVOX_DLL "${AVOX_OUT_DIR}/avox.dll")
endif()

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
# 全部媒体能力已收回 avox: probe/index/frame 走 IMediaReader, 混音/封装走
# IMediaComposer(avox AvoxCapture.h), 运行时能力走 AvoxRuntime。本目标不再直链 libav
if(APPLE)
  # libavox.a 的 av_* 是未定义引用, 由本仓 kit 这份唯一 ffmpeg 解析;
  # 链 avox 3rdparty 的 libav*.a 会让同一个 dylib 出现两套 ffmpeg。
  set(AK_KIT_LIBS "")
  foreach(_name libavformat.a libavcodec.a libswresample.a libavutil.a)
    if(NOT EXISTS "${KIT_DIR}/lib/${_name}")
      message(FATAL_ERROR
        "ffmpeg kit 缺 ${_name}: 先跑 script/ffmpeg/build_ffmpeg_macos.sh")
    endif()
    list(APPEND AK_KIT_LIBS "${KIT_DIR}/lib/${_name}")
  endforeach()
  # 编码器依赖排在 avcodec 之后; lame 的 mpglib 再依赖 mpg123
  foreach(_name libdav1d.a libmp3lame.a libmpg123.a)
    if(EXISTS "${KIT_DIR}/lib/${_name}")
      list(APPEND AK_KIT_LIBS "${KIT_DIR}/lib/${_name}")
    endif()
  endforeach()
  # Agent/httplib 在无 WebRTC(BoringSSL) 时用 OpenSSL; 必须静态链,
  # 否则会把 Homebrew 的绝对路径带进 app。arm64 与 avox 一致。
  find_library(AK_OPENSSL_SSL_LIB NAMES libssl.a
    PATHS "$ENV{HOME}/.homebrew/opt/openssl@3/lib"
          "/opt/homebrew/opt/openssl@3/lib"
          "$ENV{HOME}/homebrew/opt/openssl@3/lib"
    NO_DEFAULT_PATH)
  find_library(AK_OPENSSL_CRYPTO_LIB NAMES libcrypto.a
    PATHS "$ENV{HOME}/.homebrew/opt/openssl@3/lib"
          "/opt/homebrew/opt/openssl@3/lib"
          "$ENV{HOME}/homebrew/opt/openssl@3/lib"
    NO_DEFAULT_PATH)
  if(NOT AK_OPENSSL_SSL_LIB OR NOT AK_OPENSSL_CRYPTO_LIB)
    message(FATAL_ERROR
      "找不到静态 libssl.a/libcrypto.a (openssl@3)。设置 AK_OPENSSL_SSL_LIB / "
      "AK_OPENSSL_CRYPTO_LIB 指向静态库。")
  endif()
  # whole-archive: avox 的模块注册靠静态初始化, 普通链接会被 dead-strip
  target_link_options(avoxkit_native PRIVATE "-Wl,-force_load,${AVOX_LIB}")
  # force_load 只是链接选项, CMake 不跟踪静态库变化; 引擎重编后必须重链
  set_property(TARGET avoxkit_native APPEND PROPERTY LINK_DEPENDS "${AVOX_LIB}")
  target_link_libraries(avoxkit_native PRIVATE
    ${AK_KIT_LIBS}
    "${AVOX_OUT_DIR}/libfdk-aac.a"
    "${AVOX_OUT_DIR}/libfreetype.a"
    "${AVOX_OUT_DIR}/libvolk.a"
    "${AK_OPENSSL_SSL_LIB}"
    "${AK_OPENSSL_CRYPTO_LIB}"
    "-framework AVFoundation"
    "-framework CoreAudio"
    "-framework AudioUnit"
    "-framework CoreMedia"
    "-framework CoreVideo"
    "-framework VideoToolbox"
    "-framework AudioToolbox"
    "-framework ScreenCaptureKit"
    "-framework Metal"
    "-framework MetalKit"
    "-framework QuartzCore"
    "-framework IOSurface"
    "-framework Cocoa"
    "-framework AppKit"
    "-framework Foundation"
    "-framework Security"
    "-framework CFNetwork"
    "-framework CoreFoundation"
    "-framework CoreGraphics"
    "-framework IOKit"
    "-framework CoreServices"
    "-lz" "-lbz2" "-liconv" "-lpthread" "-ldl")
  set_target_properties(avoxkit_native PROPERTIES
    PREFIX ""
    OUTPUT_NAME "avoxkit_native"
    INSTALL_NAME_DIR "@rpath"
    BUILD_RPATH "@loader_path"
    INSTALL_RPATH "@loader_path")
else()
  target_link_libraries(avoxkit_native PRIVATE "${AVOX_LIB}")
endif()
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

# 预览接/摘视口隔离测试(宿主窗, 不走 Flutter/UIA); 预览窗本身只有 Windows 实现
if(WIN32)
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
endif()

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
target_link_libraries(ak_image_test PRIVATE avoxkit_native)
if(WIN32)
  # Windows 的 avox 是 DLL, 测试直接调 avox API 时补一层导出
  target_link_libraries(ak_image_test PRIVATE "${AVOX_LIB}")
endif()

# 录屏整链无头测试: 采集 -> finalize -> 工程导出 (Windows; GDI 道)
if(WIN32)
add_executable(ak_capture_test tools/ak_capture_test.cpp)
target_include_directories(ak_capture_test PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/third_party")
target_compile_definitions(ak_capture_test PRIVATE
  NOMINMAX
  WIN32_LEAN_AND_MEAN
  _CRT_SECURE_NO_WARNINGS)
target_compile_options(ak_capture_test PRIVATE
  $<$<CXX_COMPILER_ID:MSVC>:/utf-8>)
target_link_libraries(ak_capture_test PRIVATE avoxkit_native)
endif()

if(WIN32)
# 只带 kit 的 ffmpeg + avox.dll, 不带 avox 3rdparty 的 ffmpeg
file(GLOB KIT_DLLS CONFIGURE_DEPENDS "${KIT_DIR}/bin/*.dll")
set(AK_RUNTIME_DLLS "${AVOX_DLL}" ${KIT_DLLS})
add_custom_command(TARGET avoxkit_native POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
          ${AK_RUNTIME_DLLS} "$<TARGET_FILE_DIR:avoxkit_native>"
  COMMENT "Copy avox/ffmpeg runtime DLLs")

# 场景层 shader 从 exe 目录 assets/glsl 加载; 少了它场景层静默禁用、导出全丢帧
if(EXISTS "${AVOX_OUT_DIR}/assets")
  add_custom_command(TARGET avoxkit_native POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_directory
            "${AVOX_OUT_DIR}/assets" "$<TARGET_FILE_DIR:avoxkit_native>/assets"
    COMMENT "Copy avox assets (glsl)")
endif()

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
endif()

if(APPLE)
  # 插件目录由 dladdr(avoxModuleMarker) 定位到 shim 所在目录 => bin/plugins;
  # 模型不随包, Dart 侧首次使用时下载。
  set(AK_PLUGIN_FILES "")
  foreach(_name libavox_sherpa.dylib libavox_cv.dylib libavox_onnx.dylib
                libavox_opencv.dylib)
    if(EXISTS "${AVOX_PLUGIN_DIR}/${_name}")
      list(APPEND AK_PLUGIN_FILES "${AVOX_PLUGIN_DIR}/${_name}")
    endif()
  endforeach()
  if(EXISTS "${ONNXRUNTIME_DYLIB}")
    list(APPEND AK_PLUGIN_FILES "${ONNXRUNTIME_DYLIB}")
  endif()
  if(AK_PLUGIN_FILES)
    add_custom_command(TARGET avoxkit_native POST_BUILD
      COMMAND ${CMAKE_COMMAND} -E make_directory
              "$<TARGET_FILE_DIR:avoxkit_native>/plugins"
      COMMAND ${CMAKE_COMMAND} -E copy_if_different
              ${AK_PLUGIN_FILES}
              "$<TARGET_FILE_DIR:avoxkit_native>/plugins"
      COMMENT "Copy avox plugins + onnxruntime")
  endif()
  # macOS getShaderPath() 只查 Resources/glsl 或 CWD/glsl; 无头工具默认在 bin 下跑
  if(EXISTS "${AVOX_ASSETS_DIR}")
    add_custom_command(TARGET avoxkit_native POST_BUILD
      COMMAND ${CMAKE_COMMAND} -E make_directory
              "$<TARGET_FILE_DIR:avoxkit_native>/glsl"
      COMMAND ${CMAKE_COMMAND} -E copy_directory
              "${AVOX_ASSETS_DIR}" "$<TARGET_FILE_DIR:avoxkit_native>/glsl"
      COMMENT "Copy avox glsl shaders (macOS CWD lookup)")
  endif()
  # volk 按 libvulkan.1.dylib 找 loader; macOS 上 MoltenVK 直接充当该角色
  if(EXISTS "${MOLTENVK_DYLIB}")
    add_custom_command(TARGET avoxkit_native POST_BUILD
      COMMAND ${CMAKE_COMMAND} -E copy_if_different
              "${MOLTENVK_DYLIB}"
              "$<TARGET_FILE_DIR:avoxkit_native>/libvulkan.1.dylib"
      COMMENT "Copy MoltenVK as libvulkan.1.dylib")
  endif()
endif()
