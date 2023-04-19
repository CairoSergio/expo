// Copyright 2023-present 650 Industries. All rights reserved.

#import <ExpoModulesCore/EXJSIConversions.h>
#import <ExpoModulesCore/EXJavaScriptFunction.h>

@implementation EXJavaScriptFunction {
  /**
   Pointer to the `EXJavaScriptRuntime` wrapper.

   \note It must be weak because only then the original runtime can be safely deallocated
   when the JS engine wants to without unsetting it on each created object.
   */
  __weak EXJavaScriptRuntime *_runtime;

  /**
   Shared pointer to the `WeakRef` JS object. Available only on JSC engine.
   */
  std::shared_ptr<jsi::Function> _function;
}

- (nonnull instancetype)initWith:(std::shared_ptr<jsi::Function>)function
                         runtime:(nonnull EXJavaScriptRuntime *)runtime
{
  if (self = [super init]) {
    _runtime = runtime;
    _function = function;
  }
  return self;
}

- (nonnull EXJavaScriptValue *)callWithArguments:(nonnull NSArray<id> *)arguments
                                            this:(nullable EXJavaScriptObject *)thisObject
                                   asConstructor:(BOOL)asConstructor
{
  jsi::Runtime *runtime = [_runtime get];
  std::vector<jsi::Value> vector = expo::convertNSArrayToStdVector(*runtime, arguments);
  jsi::Value result;

  if (asConstructor) {
    result = _function->callAsConstructor(*runtime, vector.data(), arguments.count);
  } else if (thisObject) {
    result = _function->callWithThis(*runtime, *[thisObject get], vector.data(), arguments.count);
  } else {
    result = _function->call(*runtime, vector.data(), arguments.count);
  }

  return [[EXJavaScriptValue alloc] initWithRuntime:_runtime value:std::make_shared<jsi::Value>(result)];
}

@end
