add_library(
    felix_core
    STATIC
    src/rule_types.cpp
    src/rule_catalog.cpp
    src/handler_registry.cpp
    src/rule_engine.cpp
    src/snapshot_repository.cpp
    src/windows/process_runner.cpp
    src/windows/registry.cpp
    src/windows/power_config.cpp
    src/windows/system_facts.cpp
    src/windows/network_adapters.cpp
    src/handlers/builtin_handlers.cpp
)

add_library(StableTune::Core ALIAS felix_core)

target_include_directories(
    felix_core
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
        $<INSTALL_INTERFACE:include>
)

target_link_libraries(felix_core PUBLIC Qt6::Core)

if(WIN32)
    target_compile_definitions(felix_core PRIVATE FELIX_PLATFORM_WINDOWS=1)
    target_link_libraries(
        felix_core
        PRIVATE
            Advapi32
            Iphlpapi
            Ws2_32
            Userenv
    )
else()
    message(FATAL_ERROR "StableTune core currently targets Windows only.")
endif()

target_compile_options(
    felix_core
    PRIVATE
        $<$<CXX_COMPILER_ID:MSVC>:/W4 /permissive- /Zc:__cplusplus>
        $<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-Wall -Wextra -Wpedantic>
)
