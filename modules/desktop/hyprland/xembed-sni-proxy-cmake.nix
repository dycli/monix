{ version }:
''
  cmake_minimum_required(VERSION 3.16)

  project(xembed-sni-proxy VERSION ${version} LANGUAGES CXX)

  set(CMAKE_CXX_STANDARD 23)
  set(CMAKE_CXX_STANDARD_REQUIRED ON)

  find_package(ECM REQUIRED NO_MODULE)
  set(CMAKE_MODULE_PATH ''${ECM_MODULE_PATH})

  include(KDEInstallDirs)
  include(KDECMakeSettings)
  include(KDECompilerSettings NO_POLICY_SCOPE)
  include(ECMQtDeclareLoggingCategory)

  find_package(Qt6 REQUIRED COMPONENTS Core DBus Gui)
  find_package(KF6 REQUIRED COMPONENTS CoreAddons Crash DBusAddons WindowSystem)
  find_package(X11 REQUIRED COMPONENTS Xtst)
  find_package(XCB REQUIRED COMPONENTS XCB XFIXES DAMAGE COMPOSITE RANDR SHM UTIL IMAGE ICCCM)

  file(WRITE "''${CMAKE_CURRENT_BINARY_DIR}/config-workspace.h"
      "#define WORKSPACE_VERSION_STRING \"''${PROJECT_VERSION}\"\n")

  set(XEMBED_SNI_PROXY_SOURCES
      main.cpp
      fdoselectionmanager.cpp
      snidbus.cpp
      sniproxy.cpp
      xtestsender.cpp
  )

  qt_add_dbus_adaptor(XEMBED_SNI_PROXY_SOURCES org.kde.StatusNotifierItem.xml sniproxy.h SNIProxy)
  qt_add_dbus_interface(XEMBED_SNI_PROXY_SOURCES org.kde.StatusNotifierWatcher.xml statusnotifierwatcher_interface)

  ecm_qt_declare_logging_category(XEMBED_SNI_PROXY_SOURCES
      HEADER debug.h
      IDENTIFIER SNIPROXY
      CATEGORY_NAME kde.xembedsniproxy
      DEFAULT_SEVERITY Info
      DESCRIPTION "xembed sni proxy"
  )

  add_executable(xembedsniproxy ''${XEMBED_SNI_PROXY_SOURCES})
  target_link_libraries(xembedsniproxy
      Qt::Core
      Qt::DBus
      Qt::Gui
      KF6::CoreAddons
      KF6::Crash
      KF6::DBusAddons
      KF6::WindowSystem
      X11::Xtst
      XCB::XCB
      XCB::XFIXES
      XCB::DAMAGE
      XCB::COMPOSITE
      XCB::RANDR
      XCB::SHM
      XCB::UTIL
      XCB::IMAGE
      XCB::ICCCM
  )

  install(TARGETS xembedsniproxy ''${KDE_INSTALL_TARGETS_DEFAULT_ARGS})
''
