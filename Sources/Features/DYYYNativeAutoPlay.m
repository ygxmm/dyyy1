#import "DYYYNativeAutoPlay.h"
#import "DYYYConstants.h"
#import <objc/message.h>
#import <objc/runtime.h>

static id DYYYAutoPlayService(void) {
    Class centerClass = NSClassFromString(@"HTSServiceCenter");
    if (![centerClass respondsToSelector:@selector(defaultCenter)]) return nil;
    id center = ((id (*)(id, SEL))objc_msgSend)(centerClass, @selector(defaultCenter));
    Protocol *protocol = objc_getProtocol("AWEFeedModuleService");
    if (protocol && [center respondsToSelector:@selector(getProtocolService:)]) {
        id service = ((id (*)(id, SEL, Protocol *))objc_msgSend)(center, @selector(getProtocolService:), protocol);
        if (service) return service;
    }
    Class serviceClass = NSClassFromString(@"AWEFeedModuleService");
    if (serviceClass && [center respondsToSelector:@selector(getService:)]) {
        return ((id (*)(id, SEL, Class))objc_msgSend)(center, @selector(getService:), serviceClass);
    }
    return nil;
}

static NSString *const kDYYYLegacyAutoPlayKey = @"DYYYisEnableAutoPlay";

static NSNumber *DYYYAutoPlayBool(id value) {
    if ([value isKindOfClass:NSNumber.class]) return @([value boolValue]);
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *text = [[value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    if ([text isEqualToString:@"yes"] || [text isEqualToString:@"true"] || [text isEqualToString:@"1"]) return @YES;
    if ([text isEqualToString:@"no"] || [text isEqualToString:@"false"] || [text isEqualToString:@"0"]) return @NO;
    return nil;
}

static NSNumber *DYYYAutoPlayPreference(NSUserDefaults *defaults) {
    return DYYYAutoPlayBool([defaults objectForKey:DYYY_ENABLE_AUTO_PLAY_KEY]) ?: DYYYAutoPlayBool([defaults objectForKey:kDYYYLegacyAutoPlayKey]);
}

static BOOL DYYYApplyAutoPlayPreference(BOOL enabled) {
    id service = DYYYAutoPlayService();
    SEL getState = @selector(getFeedIphoneAutoPlayState);
    SEL setState = @selector(setFeedIphoneAutoPlayState:);
    if (![service respondsToSelector:getState] || ![service respondsToSelector:setState]) return NO;
    // Reading the service first also lets it finish creating its native manager.
    if (((BOOL (*)(id, SEL))objc_msgSend)(service, getState) == enabled) return YES;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(service, setState, enabled);
    return ((BOOL (*)(id, SEL))objc_msgSend)(service, getState) == enabled;
}

BOOL DYYYAutoPlayIsEnabled(void) {
    return [DYYYAutoPlayPreference(NSUserDefaults.standardUserDefaults) boolValue];
}

BOOL DYYYAutoPlaySetEnabled(BOOL enabled) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:enabled forKey:DYYY_ENABLE_AUTO_PLAY_KEY];
    [defaults removeObjectForKey:kDYYYLegacyAutoPlayKey];
    return DYYYApplyAutoPlayPreference(enabled);
}

void DYYYRestoreAutoPlayPreference(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (![defaults boolForKey:@"DYYYUserAgreementAccepted"]) return;
    NSNumber *saved = DYYYAutoPlayPreference(defaults);
    if (!saved) return; // A never-configured DYYY switch leaves the host alone.
    if ([defaults objectForKey:kDYYYLegacyAutoPlayKey]) {
        if (!DYYYAutoPlayBool([defaults objectForKey:DYYY_ENABLE_AUTO_PLAY_KEY])) {
            [defaults setBool:saved.boolValue forKey:DYYY_ENABLE_AUTO_PLAY_KEY];
        }
        [defaults removeObjectForKey:kDYYYLegacyAutoPlayKey];
    }
    DYYYApplyAutoPlayPreference(saved.boolValue);
}

NSDictionary *DYYYAutoPlayNormalizeBackup(NSDictionary *settings) {
    NSMutableDictionary *normalized = [settings mutableCopy];
    NSNumber *saved = DYYYAutoPlayBool(settings[DYYY_ENABLE_AUTO_PLAY_KEY]) ?: DYYYAutoPlayBool(settings[kDYYYLegacyAutoPlayKey]);
    [normalized removeObjectForKey:kDYYYLegacyAutoPlayKey];
    if (saved) normalized[DYYY_ENABLE_AUTO_PLAY_KEY] = saved;
    else [normalized removeObjectForKey:DYYY_ENABLE_AUTO_PLAY_KEY];
    return normalized;
}
