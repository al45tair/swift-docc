#[[
This source file is part of the Swift open source project

Copyright © 2014 - 2025 Apple Inc. and the Swift project authors
Licensed under Apache License v2.0 with Runtime Library Exception

See https://swift.org/LICENSE.txt for license information
#]]

add_library(MicroHttpd
  MicroHttpd.swift
  SocketStream.swift
  WebRootRequestHandler.swift
  ISO8859-1.swift
  Date+FileTime.swift
  Date+HTTPDate.swift
)

set_target_properties(MicroHttpd PROPERTIES
  Swift_LANGUAGE_VERSION 6)

if(BUILD_SHARED_LIBS)
  install(TARGETS MicroHttpd
    ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
endif()
