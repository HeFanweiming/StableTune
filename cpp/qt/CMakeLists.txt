add_executable(
    StableTune
    src/main_backend.cpp
)

set(
    FELIX_RULE_CATALOG_SOURCE
    "${CMAKE_CURRENT_SOURCE_DIR}/../../src/StableTune/rules/catalog.json"
)
set(
    FELIX_POWERSHELL_MODULE_SOURCE
    "${CMAKE_CURRENT_SOURCE_DIR}/../../src/StableTune"
)
set(
    FELIX_BACKEND_HOST_SOURCE
    "${CMAKE_CURRENT_SOURCE_DIR}/../backend/backend_host.ps1"
)

target_link_libraries(
    StableTune
    PRIVATE
        StableTune::Bridge
        Qt6::Concurrent
        Qt6::Widgets
)

add_custom_command(
    TARGET StableTune
    POST_BUILD
    COMMAND
        "${CMAKE_COMMAND}" -E make_directory
        "$<TARGET_FILE_DIR:StableTune>/rules"
    COMMAND
        "${CMAKE_COMMAND}" -E copy_if_different
        "${FELIX_RULE_CATALOG_SOURCE}"
        "$<TARGET_FILE_DIR:StableTune>/rules/catalog.json"
    COMMAND
        "${CMAKE_COMMAND}" -E make_directory
        "$<TARGET_FILE_DIR:StableTune>/powershell/StableTune"
    COMMAND
        "${CMAKE_COMMAND}" -E copy_directory
        "${FELIX_POWERSHELL_MODULE_SOURCE}"
        "$<TARGET_FILE_DIR:StableTune>/powershell/StableTune"
    COMMAND
        "${CMAKE_COMMAND}" -E copy_if_different
        "${FELIX_BACKEND_HOST_SOURCE}"
        "$<TARGET_FILE_DIR:StableTune>/powershell/backend_host.ps1"
    VERBATIM
)

target_compile_options(
    StableTune
    PRIVATE
        $<$<CXX_COMPILER_ID:MSVC>:/W4 /permissive- /Zc:__cplusplus>
        $<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-Wall -Wextra -Wpedantic>
)

set_target_properties(
    StableTune
    PROPERTIES
        WIN32_EXECUTABLE TRUE
)

install(TARGETS StableTune RUNTIME DESTINATION bin)
install(FILES "${FELIX_RULE_CATALOG_SOURCE}" DESTINATION bin/rules)
install(DIRECTORY "${FELIX_POWERSHELL_MODULE_SOURCE}/" DESTINATION bin/powershell/StableTune)
install(FILES "${FELIX_BACKEND_HOST_SOURCE}" DESTINATION bin/powershell)

if(WIN32)
    qt_generate_deploy_app_script(
        TARGET StableTune
        OUTPUT_SCRIPT felix_qt_deploy_script
        NO_UNSUPPORTED_PLATFORM_ERROR
    )
    install(SCRIPT "${felix_qt_deploy_script}")
endif()
