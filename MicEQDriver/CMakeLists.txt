cmake_minimum_required(VERSION 3.12.0)

project(MicEQ CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# Set to a non-empty string to enable code signing (e.g. "-" for ad-hoc signing).
set(CODESIGN_ID "" CACHE STRING "Codesign ID")

set(DRIVER_NAME "MicEQ")
set(DRIVER_VERSION "0.1.0")
set(DRIVER_COPYRIGHT "Copyright (c) MicEQ contributors")
set(DRIVER_IDENTIFIER "com.miceq.driver")
set(DRIVER_UID "D7E7ABB8-C787-420C-AEC1-95D4E635FB37")
set(DRIVER_ENTRYPOINT "MicEQEntryPoint")

message(STATUS "Driver name - ${DRIVER_NAME}")
message(STATUS "Driver version - ${DRIVER_VERSION}")
message(STATUS "Driver identifier - ${DRIVER_IDENTIFIER}")
message(STATUS "Driver codesign ID - ${CODESIGN_ID}")

get_filename_component(LIBASPL_SOURCE_DIR
  ${CMAKE_CURRENT_LIST_DIR}/../ThirdParty/libASPL
  ABSOLUTE)

set(LIBASPL_TARGET MicEQ_libASPL)
include(ExternalProject)
ExternalProject_Add(${LIBASPL_TARGET}
  SOURCE_DIR ${LIBASPL_SOURCE_DIR}
  BINARY_DIR ${CMAKE_CURRENT_BINARY_DIR}/libASPL-build
  INSTALL_DIR ${CMAKE_CURRENT_BINARY_DIR}/libASPL-prefix
  CMAKE_ARGS -DCMAKE_INSTALL_PREFIX=<INSTALL_DIR>
  LOG_DOWNLOAD NO
  LOG_CONFIGURE NO
  LOG_BUILD NO
  LOG_INSTALL NO
  )

add_library(${DRIVER_NAME} MODULE
  "Driver.cpp"
  )

add_dependencies(${DRIVER_NAME} ${LIBASPL_TARGET})
target_include_directories(${DRIVER_NAME}
  PRIVATE ${CMAKE_CURRENT_BINARY_DIR}/libASPL-prefix/include
  )
target_link_libraries(${DRIVER_NAME}
  PRIVATE ${CMAKE_CURRENT_BINARY_DIR}/libASPL-prefix/lib/libASPL.a
  )

find_library(LIB_CoreFoundation CoreFoundation REQUIRED)
target_link_libraries(${DRIVER_NAME}
  PRIVATE ${LIB_CoreFoundation}
  )

set_target_properties(${DRIVER_NAME} PROPERTIES
  OUTPUT_NAME "${DRIVER_NAME}"
  BUNDLE true
  BUNDLE_EXTENSION "driver"
  PREFIX ""
  SUFFIX ""
  MACOSX_BUNDLE ON
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in"
  MACOSX_BUNDLE_BUNDLE_NAME "${DRIVER_NAME}"
  MACOSX_BUNDLE_BUNDLE_VERSION "${DRIVER_VERSION}"
  MACOSX_BUNDLE_COPYRIGHT "${DRIVER_COPYRIGHT}"
  MACOSX_BUNDLE_GUI_IDENTIFIER "${DRIVER_IDENTIFIER}"
  MACOSX_BUNDLE_SHORT_VERSION_STRING "${DRIVER_VERSION}"
  )

if(NOT CODESIGN_ID STREQUAL "")
  add_custom_command(
    TARGET ${DRIVER_NAME}
    POST_BUILD
    COMMENT "Signing ${DRIVER_NAME}.driver with ID ${CODESIGN_ID}"
    VERBATIM
    COMMAND
      codesign --force -s "${CODESIGN_ID}"
        "${CMAKE_CURRENT_BINARY_DIR}/${DRIVER_NAME}.driver"
    )
endif()

