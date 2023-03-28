// Copyright 2023-present 650 Industries. All rights reserved.

internal final class ClassRegistry {
  var jsClasses: [String: JavaScriptWeakObject] = [:]

  func get(_ name: String) -> JavaScriptObject? {
    return jsClasses[name]?.lock()
  }

  func newObject(appContext: AppContext, className: String) throws -> JavaScriptObject? {
    guard let jsClass = get(className) else {
      return nil
    }
    let prototype = try jsClass.getProperty("prototype").asObject()
    let object = try appContext.runtime.createObject(withPrototype: prototype)

    return object
  }
}
