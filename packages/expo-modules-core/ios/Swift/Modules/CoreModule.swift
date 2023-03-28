// Copyright 2023-present 650 Industries. All rights reserved.

internal final class CoreModule: Module {
  func definition() -> ModuleDefinition {
    Class("NativeException", NativeException.self) {
      Property("code", \.exception.code)
      Property("reason", \.exception.reason)
//      Property("cause") { this in
//        return this.exception.cause
//      }
    }
  }
}

internal final class NativeException: NativeClass {
  let exception: Exception

  init(_ exception: Exception) {
    self.exception = exception
  }
}
