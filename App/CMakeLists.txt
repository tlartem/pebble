cmake_minimum_required(VERSION 3.25)
project(Pebble LANGUAGES C Swift)
add_subdirectory(../Native Native)
file(GLOB app_sources CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/*.swift" "${CMAKE_CURRENT_SOURCE_DIR}/UI/*.swift")
add_executable(Pebble MACOSX_BUNDLE ${app_sources} Assets.xcassets)
configure_file("${AIR_GOLDEN_GATE}/LICENSE" "${CMAKE_CURRENT_BINARY_DIR}/GoldenGate-LICENSE.txt" COPYONLY)
configure_file("${AIR_GOLDEN_GATE}/NOTICE" "${CMAKE_CURRENT_BINARY_DIR}/GoldenGate-NOTICE.txt" COPYONLY)
configure_file("${AIR_GOLDEN_GATE}/external/mbedtls-3/LICENSE" "${CMAKE_CURRENT_BINARY_DIR}/MbedTLS-LICENSE.txt" COPYONLY)
set(license_files
    "${CMAKE_CURRENT_BINARY_DIR}/GoldenGate-LICENSE.txt"
    "${CMAKE_CURRENT_BINARY_DIR}/GoldenGate-NOTICE.txt"
    "${CMAKE_CURRENT_BINARY_DIR}/MbedTLS-LICENSE.txt")
set_source_files_properties(Assets.xcassets PROPERTIES MACOSX_PACKAGE_LOCATION Resources)
set_source_files_properties(${license_files} PROPERTIES MACOSX_PACKAGE_LOCATION Resources)
target_sources(Pebble PRIVATE ${license_files})
foreach(language en ru)
    file(GLOB localized_files "${CMAKE_CURRENT_SOURCE_DIR}/Localization/${language}.lproj/*.strings")
    set_source_files_properties(${localized_files} PROPERTIES MACOSX_PACKAGE_LOCATION "Resources")
    target_sources(Pebble PRIVATE ${localized_files})
endforeach()
target_link_libraries(Pebble PRIVATE air-transport "-framework CoreBluetooth" "-framework SwiftUI" "-framework Security" "-framework HealthKit" "-framework UserNotifications" "-framework Charts" "-framework CallKit" "-framework AVFoundation" "-framework AppIntents" "-framework BackgroundTasks")
set_target_properties(Pebble PROPERTIES
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist"
    XCODE_ATTRIBUTE_ASSETCATALOG_COMPILER_APPICON_NAME "AppIcon"
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "com.medpar.air.companion"
    XCODE_ATTRIBUTE_SWIFT_OBJC_BRIDGING_HEADER "${CMAKE_CURRENT_SOURCE_DIR}/../Native/air_transport.h"
    XCODE_ATTRIBUTE_SWIFT_VERSION "5.0"
    XCODE_ATTRIBUTE_CODE_SIGN_ENTITLEMENTS "${CMAKE_CURRENT_SOURCE_DIR}/Pebble.entitlements"
    XCODE_ATTRIBUTE_CODE_SIGN_STYLE "Automatic"
    XCODE_ATTRIBUTE_DEVELOPMENT_TEAM "${AIR_DEVELOPMENT_TEAM}"
    XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1"
    XCODE_ATTRIBUTE_ENABLE_USER_SCRIPT_SANDBOXING "YES"
    XCODE_ATTRIBUTE_GENERATE_INFOPLIST_FILE "NO"
    XCODE_ATTRIBUTE_LD_RUNPATH_SEARCH_PATHS "@executable_path/Frameworks"
)
