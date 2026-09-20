cmake_minimum_required(VERSION 3.24)

project(
    StableTune
    VERSION 0.1.9.2
    DESCRIPTION "PowerShell-backed Qt UI plus the experimental native core"
    LANGUAGES CXX
)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(MSVC)
    add_compile_options(/utf-8)
    add_compile_definitions(
        NOMINMAX
        WIN32_LEAN_AND_MEAN
        _WIN32_WINNT=0x0A00
    )
endif()

set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTOUIC ON)
set(CMAKE_AUTORCC ON)

find_package(Qt6 6.8 REQUIRED COMPONENTS Core Concurrent Gui Widgets)

add_subdirectory(core)
add_subdirectory(bridge)
add_subdirectory(qt)

include(CTest)
if(BUILD_TESTING)
    add_subdirectory(tests)
endif()
