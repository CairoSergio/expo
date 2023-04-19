// Copyright 2023-present 650 Industries. All rights reserved.

#import <Foundation/Foundation.h>
#import <ExpoModulesCore/EXJavaScriptRuntime.h>

#ifdef __cplusplus
#import <jsi/jsi.h>

namespace jsi = facebook::jsi;
#endif // __cplusplus

@interface EXJavaScriptFunction : NSObject

#ifdef __cplusplus
- (nonnull instancetype)initWith:(std::shared_ptr<jsi::Function>)function
                         runtime:(nonnull EXJavaScriptRuntime *)runtime;
#endif // __cplusplus

@end
