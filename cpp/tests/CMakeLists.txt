find_package(Qt6 6.8 REQUIRED COMPONENTS Test)

add_executable(
    felix_core_tests
    test_core.cpp
)

target_link_libraries(
    felix_core_tests
    PRIVATE
        StableTune::Core
        StableTune::Bridge
        Qt6::Test
)

target_compile_definitions(
    felix_core_tests
    PRIVATE
        FELIX_TEST_CATALOG="${CMAKE_SOURCE_DIR}/../src/StableTune/rules/catalog.json"
        FELIX_TEST_REPOSITORY="${CMAKE_SOURCE_DIR}/.."
)

add_test(
    NAME felix_core_tests
    COMMAND
        "${CMAKE_COMMAND}" -E env
        "PATH=$<TARGET_FILE_DIR:Qt6::Core>;$ENV{PATH}"
        "$<TARGET_FILE:felix_core_tests>"
)
