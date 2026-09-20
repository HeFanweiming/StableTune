add_library(
    felix_bridge
    STATIC
    src/powershell_bridge.cpp
)

add_library(StableTune::Bridge ALIAS felix_bridge)

target_include_directories(
    felix_bridge
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
)

target_link_libraries(felix_bridge PUBLIC Qt6::Core)

target_compile_options(
    felix_bridge
    PRIVATE
        $<$<CXX_COMPILER_ID:MSVC>:/W4 /permissive- /Zc:__cplusplus>
        $<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-Wall -Wextra -Wpedantic>
)
