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

BOOL DYYYNativeAutoPlayIsEnabled(void) {
    id service = DYYYAutoPlayService();
    SEL getState = @selector(getFeedIphoneAutoPlayState);
    if ([service respondsToSelector:getState]) {
        return ((BOOL (*)(id, SEL))objc_msgSend)(service, getState);
    }
    return NO;
}

BOOL DYYYNativeAutoPlaySetEnabled(BOOL enabled) {
    id service = DYYYAutoPlayService();
    SEL getState = @selector(getFeedIphoneAutoPlayState);
    SEL setState = @selector(setFeedIphoneAutoPlayState:);
    if (![service respondsToSelector:getState] || ![service respondsToSelector:setState]) return NO;
    BOOL current = ((BOOL (*)(id, SEL))objc_msgSend)(service, getState);
    if (current != enabled) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(service, setState, enabled);
    }
    if (((BOOL (*)(id, SEL))objc_msgSend)(service, getState) != enabled) return NO;
    // This key holds a pending legacy/backup value only; after applying it the host owns the state.
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:DYYY_ENABLE_AUTO_PLAY_KEY]) [defaults removeObjectForKey:DYYY_ENABLE_AUTO_PLAY_KEY];
    return YES;
}

void DYYYNativeAutoPlayMigrateLegacySetting(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (![defaults boolForKey:@"DYYYUserAgreementAccepted"]) return;
    id oldValue = [defaults objectForKey:DYYY_ENABLE_AUTO_PLAY_KEY];
    // In the old implementation OFF meant “leave the native switch alone”.
    if (![oldValue respondsToSelector:@selector(boolValue)]) return;
    if ([oldValue boolValue]) DYYYNativeAutoPlaySetEnabled(YES);
    else [defaults removeObjectForKey:DYYY_ENABLE_AUTO_PLAY_KEY];
}
