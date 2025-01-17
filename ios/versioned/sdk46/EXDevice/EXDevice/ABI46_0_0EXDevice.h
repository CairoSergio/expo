// Copyright 2019-present 650 Industries. All rights reserved.

#import <ABI46_0_0ExpoModulesCore/ABI46_0_0EXExportedModule.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Keep this enum in sync with JavaScript
typedef NS_ENUM(NSInteger, ABI46_0_0EXDeviceType) {
    ABI46_0_0EXDeviceTypeUnknown = 0,
    ABI46_0_0EXDeviceTypePhone,
    ABI46_0_0EXDeviceTypeTablet,
    ABI46_0_0EXDeviceTypeDesktop,
    ABI46_0_0EXDeviceTypeTV,
};

@interface ABI46_0_0EXDevice : ABI46_0_0EXExportedModule

@end

NS_ASSUME_NONNULL_END
