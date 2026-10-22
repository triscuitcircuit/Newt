cmake_minimum_required(VERSION 3.20)
project(Newt VERSION 0.1.0 LANGUAGES CXX OBJCXX)
if(NOT APPLE)
    message(FATAL_ERROR "Newt currently requires macOS")
endif()

if(CMAKE_SOURCE_DIR STREQUAL CMAKE_BINARY_DIR)
    message(FATAL_ERROR "In-source builds are not supported. Remove CMakeCache.txt/CMakeFiles and run: cmake -S . -B build")
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 17)

if(NOT DEFINED VULKAN_SDK)
    if(DEFINED ENV{VULKAN_SDK})
        set(VULKAN_SDK "$ENV{VULKAN_SDK}")
    else()
        file(GLOB _sdk_candidates "$ENV{HOME}/VulkanSDK/*/macOS")
        if(_sdk_candidates)
            list(SORT _sdk_candidates)
            list(GET _sdk_candidates -1 VULKAN_SDK)
        else()
            set(VULKAN_SDK "/usr/local")
        endif()
    endif()
endif()

if(NOT IS_DIRECTORY "${VULKAN_SDK}")
    message(FATAL_ERROR "VULKAN_SDK must be the SDK directory (for example ~/VulkanSDK/<version>/macOS), not a dylib.")
endif()
message(STATUS "Newt: Vulkan SDK ${VULKAN_SDK}")

set(NEWT_SDK_SEARCH_PATH "" CACHE STRING
    "Extra install prefixes to search for the OpenXR SDK's CMake package (semicolon-separated)")
list(APPEND CMAKE_PREFIX_PATH "${CMAKE_INSTALL_PREFIX}" "/opt/homebrew" "/usr/local" ${NEWT_SDK_SEARCH_PATH})
find_package(OpenXR CONFIG QUIET)
if(NOT OpenXR_FOUND)
    message(FATAL_ERROR "No OpenXR CMake package (OpenXRConfig.cmake) found under: ${CMAKE_PREFIX_PATH}\n"
        "Build/install https://github.com/KhronosGroup/OpenXR-SDK, then either pass "
        "-DOpenXR_DIR=/path/to/folder/containing/OpenXRConfig.cmake or -DNEWT_SDK_SEARCH_PATH=/its/install/prefix.")
endif()
find_package(OpenXR CONFIG REQUIRED)
message(STATUS "Newt: OpenXR package found at ${OpenXR_DIR}")

find_program(GLSLANGVALIDATOR NAMES glslangValidator
    HINTS "/usr/local/bin" "/opt/homebrew/bin" "${VULKAN_SDK}/bin" "${VULKAN_SDK}/macOS/bin" REQUIRED)
find_package(Python3 COMPONENTS Interpreter REQUIRED)
set(CMAKE_PREFIX_PATH "${VULKAN_SDK}" ${CMAKE_PREFIX_PATH})
find_package(Vulkan REQUIRED)

set(GENERATED_DIR "${CMAKE_CURRENT_BINARY_DIR}/generated")
file(MAKE_DIRECTORY "${GENERATED_DIR}")
function(add_shader input output symbol)
    set(spv "${GENERATED_DIR}/${output}.spv")
    set(header "${GENERATED_DIR}/${output}.h")
    add_custom_command(
        OUTPUT "${header}"
        COMMAND "${GLSLANGVALIDATOR}" -V "${CMAKE_CURRENT_SOURCE_DIR}/shaders/${input}" -o "${spv}"
        COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/tools/bin2h.py" "${spv}" "${header}" "${symbol}"
        DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/shaders/${input}" "${CMAKE_CURRENT_SOURCE_DIR}/tools/bin2h.py"
        VERBATIM)
    set(${output}_HEADER "${header}" PARENT_SCOPE)
endfunction()

add_shader(color.vert color_vert color_vert_spv)
add_shader(color.frag color_frag color_frag_spv)
add_shader(texture.vert texture_vert texture_vert_spv)
add_shader(texture.frag texture_frag texture_frag_spv)

add_library(newt_core STATIC
    CoreLifecycle.mm
    GPUTexture.mm
    CoreFrame.mm
    CoreInput.mm
    CorePipelines.mm
    XRSession.mm
    VulkanResources.mm
    Capture.mm
    DrawHelpers.mm
    Log.mm
    "${color_vert_HEADER}" "${color_frag_HEADER}"
    "${texture_vert_HEADER}" "${texture_frag_HEADER}")
target_include_directories(newt_core PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}" "${GENERATED_DIR}")
target_compile_options(newt_core PRIVATE -fobjc-arc)
target_compile_definitions(newt_core PRIVATE XR_USE_GRAPHICS_API_VULKAN)
target_link_libraries(newt_core PRIVATE OpenXR::openxr_loader Vulkan::Vulkan)

target_compile_features(newt_core PUBLIC cxx_std_17)
set_target_properties(newt_core PROPERTIES EXPORT_NAME core OUTPUT_NAME "newt_core")

target_include_directories(newt_core PUBLIC
    "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>" "$<INSTALL_INTERFACE:include>")
target_link_libraries(newt_core PUBLIC
    OpenXR::openxr_loader Vulkan::Vulkan
    "-framework AppKit"
    "-framework CoreGraphics"
    "-framework IOSurface"
    "-framework CoreVideo"
    "-framework Foundation")
add_library(Newt::core ALIAS newt_core)

add_library(newt INTERFACE)
set_target_properties(newt PROPERTIES EXPORT_NAME newt)
target_include_directories(newt INTERFACE
    "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>" "$<INSTALL_INTERFACE:include>")
target_link_libraries(newt INTERFACE newt_core)
add_library(Newt::newt ALIAS newt)
set(NEWT_TARGETS newt_core)
option(NEWT_BUILD_DAEMON "Build native session-manager daemon (newtd)" ON)
if(NEWT_BUILD_DAEMON)
    # The session manager: one JSON object per line over a private per-user
    # Unix socket. Deliberately independent of the OpenXR/Vulkan targets, and
    # of any dashboard: a game reaches Monado through `launch`/`prepare`+
    # `attach` alone, with no dashboard executable required.
    add_executable(newtd daemon/newtd.mm)
    target_compile_options(newtd PRIVATE -fobjc-arc)
    target_compile_features(newtd PRIVATE cxx_std_17)
    target_link_libraries(newtd PRIVATE "-framework Foundation")
endif()
set(NEWT_WITH_USB "AUTO" CACHE STRING "Build optional libusb transport: AUTO, ON, or OFF")
set_property(CACHE NEWT_WITH_USB PROPERTY STRINGS AUTO ON OFF)
set(NEWT_WITH_USB_ENABLED OFF)
if(NOT NEWT_WITH_USB STREQUAL "OFF")
    find_package(PkgConfig)
    if(PkgConfig_FOUND)
        pkg_check_modules(LIBUSB QUIET IMPORTED_TARGET libusb-1.0)
    endif()
    if(LIBUSB_FOUND)
        set(NEWT_WITH_USB_ENABLED ON)
    elseif(NEWT_WITH_USB STREQUAL "ON")
        message(FATAL_ERROR "NEWT_WITH_USB=ON but libusb-1.0 was not found via pkg-config. Install: brew install libusb pkg-config")
    endif()
endif()
message(STATUS "Newt: USB transport ${NEWT_WITH_USB_ENABLED} (NEWT_WITH_USB=${NEWT_WITH_USB})")
if(NEWT_WITH_USB_ENABLED)
    add_library(newt_usb SHARED usb/NewtUSB.cpp)
    add_library(Newt::usb ALIAS newt_usb)
    set_target_properties(newt_usb PROPERTIES EXPORT_NAME usb VERSION ${PROJECT_VERSION} SOVERSION 0)
    target_include_directories(newt_usb PUBLIC "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>" "$<INSTALL_INTERFACE:include>")
    target_link_libraries(newt_usb PRIVATE PkgConfig::LIBUSB)
    add_executable(newt-usb-list examples/usb_list.cpp)
    target_link_libraries(newt-usb-list PRIVATE Newt::usb)
endif()
include(GNUInstallDirs)
include(CMakePackageConfigHelpers)
if(NEWT_WITH_USB_ENABLED)
    install(TARGETS newt_usb EXPORT NewtTargets LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR})
    install(FILES include/NewtUSB.h DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
endif()
install(TARGETS newt ${NEWT_TARGETS} EXPORT NewtTargets ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR})
if(NEWT_BUILD_DAEMON)
    install(TARGETS newtd RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
    # The installed `newt` CLI is newtd itself (same binary, same argv[0]-agnostic
    # dispatch): a relative symlink keeps the prefix relocatable and means there
    # is only ever one binary to keep in sync between the two names.
    install(CODE "execute_process(COMMAND ${CMAKE_COMMAND} -E create_symlink newtd \"\${CMAKE_INSTALL_PREFIX}/${CMAKE_INSTALL_BINDIR}/newt\")")
    install(FILES daemon/launchd/org.newt.manager.plist.in
        DESTINATION ${CMAKE_INSTALL_DATAROOTDIR}/Newt/launchd)
    install(PROGRAMS daemon/install-launch-agent.sh
        DESTINATION ${CMAKE_INSTALL_DATAROOTDIR}/Newt/launchd)
    # Used by `newtd bundle` at export time (developer Mac only) to embed a
    # runtime/ICD dylib closure into standalone bundles.
    install(PROGRAMS tools/bundle-dylib-closure.py
        DESTINATION ${CMAKE_INSTALL_DATAROOTDIR}/Newt/tools)
endif()

set(NEWT_CONFIGURE_RUNTIME "" CACHE FILEPATH "Runtime JSON to configure after installing (optional)")
set(NEWT_CONFIGURE_ICD "" CACHE FILEPATH "Vulkan ICD JSON to configure after installing (optional, requires NEWT_CONFIGURE_RUNTIME)")
if(NEWT_CONFIGURE_ICD AND NOT NEWT_CONFIGURE_RUNTIME)
    message(FATAL_ERROR "NEWT_CONFIGURE_ICD requires NEWT_CONFIGURE_RUNTIME")
endif()
if(NEWT_CONFIGURE_RUNTIME)
    install(CODE "
        set(_newt \"\${CMAKE_INSTALL_PREFIX}/${CMAKE_INSTALL_BINDIR}/newt\")
        set(_args --runtime \"${NEWT_CONFIGURE_RUNTIME}\")
        if(NOT \"${NEWT_CONFIGURE_ICD}\" STREQUAL \"\")
            list(APPEND _args --icd \"${NEWT_CONFIGURE_ICD}\")
        endif()
        set(_state_dir \"\$ENV{NEWT_STATE_DIR}\")
        if(_state_dir STREQUAL \"\")
            set(_state_dir \"\$ENV{HOME}/Library/Application Support/Newt\")
        endif()
        set(_config \"\${_state_dir}/config.json\")
        if(EXISTS \"\${_config}\")
            file(READ \"\${_config}\" _json)
            string(JSON _godot ERROR_VARIABLE _err GET \"\${_json}\" godot)
            if(NOT _err)
                list(APPEND _args --godot \"\${_godot}\")
            endif()
        endif()
        execute_process(COMMAND \"\${_newt}\" configure \${_args} RESULT_VARIABLE _rc)
        if(NOT _rc EQUAL 0)
            message(FATAL_ERROR \"newt configure failed\")
        endif()
    ")
endif()

install(DIRECTORY addons/newt_bridge DESTINATION ${CMAKE_INSTALL_DATADIR}/Newt/addons PATTERN "__pycache__" EXCLUDE)
install(DIRECTORY include/Newt DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(FILES include/NewtLog.h DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(FILES LICENSE DESTINATION ${CMAKE_INSTALL_DATADIR}/licenses/Newt)
install(EXPORT NewtTargets NAMESPACE Newt:: DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/Newt)
configure_package_config_file(cmake/NewtConfig.cmake.in ${CMAKE_CURRENT_BINARY_DIR}/NewtConfig.cmake INSTALL_DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/Newt)
write_basic_package_version_file(${CMAKE_CURRENT_BINARY_DIR}/NewtConfigVersion.cmake VERSION ${PROJECT_VERSION} COMPATIBILITY SameMajorVersion)
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/NewtConfig.cmake ${CMAKE_CURRENT_BINARY_DIR}/NewtConfigVersion.cmake DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/Newt)
include(CTest)
if(BUILD_TESTING)
    add_executable(newt-session-lifecycle-test tests/session_lifecycle_test.cpp)
    target_compile_options(newt-session-lifecycle-test PRIVATE -UNDEBUG)
    target_link_libraries(newt-session-lifecycle-test PRIVATE Newt::core)
    add_test(NAME session-lifecycle COMMAND newt-session-lifecycle-test)
    set_tests_properties(session-lifecycle PROPERTIES ENVIRONMENT "XR_RUNTIME_JSON=${CMAKE_CURRENT_BINARY_DIR}/deliberately-missing-runtime.json;XR_API_LAYER_PATH=${CMAKE_CURRENT_BINARY_DIR}/no-api-layers")
    if(NEWT_WITH_USB_ENABLED)
        add_executable(newt-usb-validation-test tests/usb_validation_test.cpp)
        target_compile_options(newt-usb-validation-test PRIVATE -UNDEBUG)
        target_link_libraries(newt-usb-validation-test PRIVATE Newt::usb)
        add_test(NAME usb-validation COMMAND newt-usb-validation-test)
        add_executable(newt-usb-ownership-test tests/usb_ownership_test.cpp)
        target_include_directories(newt-usb-ownership-test PRIVATE include ${LIBUSB_INCLUDE_DIRS})
        target_compile_options(newt-usb-ownership-test PRIVATE -UNDEBUG)
        add_test(NAME usb-ownership COMMAND newt-usb-ownership-test)
    endif()
    if(NEWT_BUILD_DAEMON)
        # The Python harness is the protocol acceptance test for newtd;
        # NEWT_SERVE_CMD tells it which built binary to drive.
        add_test(NAME session-manager-newtd
            COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/session_manager_test.py)
        set_tests_properties(session-manager-newtd PROPERTIES
            ENVIRONMENT "NEWT_SERVE_CMD=$<TARGET_FILE:newtd> serve"
            TIMEOUT 600)
    endif()
endif()

option(NEWT_BUILD_GPU_TEST "Build the manual IOSurface sampling/lifetime test" OFF)
if(NEWT_BUILD_GPU_TEST)
    add_executable(newt-gpu-texture-test tests/gpu_texture_test.mm)
    target_include_directories(newt-gpu-texture-test PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
    target_compile_options(newt-gpu-texture-test PRIVATE -UNDEBUG -fobjc-arc)
    target_link_libraries(newt-gpu-texture-test PRIVATE Newt::core)
endif()
