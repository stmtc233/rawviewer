cmake_minimum_required(VERSION 3.10)

project(native_lib LANGUAGES CXX)

# 设置 C++ 标准
set(CMAKE_CXX_STANDARD 11)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# 包含 LibRaw 头文件
include_directories(libraw)

# 收集 LibRaw 源文件
file(GLOB_RECURSE LIBRAW_SOURCES 
    "libraw/src/libraw_c_api.cpp"
    "libraw/src/libraw_datastream.cpp"
    "libraw/src/decoders/*.cpp"
    "libraw/src/decompressors/*.cpp"
    "libraw/src/demosaic/*.cpp"
    "libraw/src/integration/*.cpp"
    "libraw/src/metadata/*.cpp"
    "libraw/src/postprocessing/*.cpp"
    "libraw/src/preprocessing/*.cpp"
    "libraw/src/tables/*.cpp"
    "libraw/src/utils/*.cpp"
    "libraw/src/write/*.cpp"
    "libraw/src/x3f/*.cpp"
)

# 移除不需要的文件（如果有冲突）
list(FILTER LIBRAW_SOURCES EXCLUDE REGEX ".*_ph\\.cpp$")
# list(REMOVE_ITEM LIBRAW_SOURCES "libraw/src/demosaic/gpr_read_image.cpp")

# 添加库
add_library(native_lib SHARED
    wrapper.cpp
    ${LIBRAW_SOURCES}
)

# Windows 特有设置
if(WIN32)
    target_compile_definitions(native_lib PRIVATE LIBRAW_BUILD_CHECK)
    target_compile_definitions(native_lib PRIVATE LIBRAW_NODLL) 
    target_compile_definitions(native_lib PRIVATE _CRT_SECURE_NO_WARNINGS)
    if(MSVC)
        target_compile_options(native_lib PRIVATE /wd4018 /wd4244 /wd4996 /wd4005 /wd4146 /wd4819)
    endif()
    # 或者如果不定义 LIBRAW_NODLL，则需要处理导出符号
endif()
