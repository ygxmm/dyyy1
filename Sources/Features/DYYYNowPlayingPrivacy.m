#import "DYYYNowPlayingPrivacy.h"
#import "DYYYNowPlayingPolicy.h"
#import "DYYYRuntimeHookInstaller.h"
#import "DYYYConstants.h"
#import <MediaPlayer/MediaPlayer.h>
#import <AVKit/AVKit.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>

static DYYYNowPlayingPolicy *gDYYYNowPlayingPolicy;
static void (*DYYYOriginalInfo)(id, SEL, id);
static void (*DYYYOriginalContentItem)(id, SEL, id);
static void (*DYYYOriginalState)(id, SEL, NSUInteger);
static void (*DYYYOriginalCenterInvalidate)(id, SEL);
static void (*DYYYOriginalSessionBaseInfo)(id, SEL, id);
static void (*DYYYOriginalSessionManualInfo)(id, SEL, id);
static void (*DYYYOriginalSessionAuto)(id, SEL, BOOL);
static void (*DYYYOriginalSessionEligible)(id, SEL, BOOL);
static void (*DYYYOriginalSessionInvalidate)(id, SEL);
static void (*DYYYOriginalSessionCenterSetter)(id, SEL, id);
static id (*DYYYOriginalSessionPlayersInit)(id, SEL, id);
static id (*DYYYOriginalSessionPathInit)(id, SEL, id, id);
static id (*DYYYOriginalSessionCenterGetter)(id, SEL);
static void (*DYYYOriginalControllerAuto)(id, SEL, BOOL);
static id (*DYYYOriginalControllerNibInit)(id, SEL, id, id);
static id (*DYYYOriginalControllerCoderInit)(id, SEL, id);
static id (*DYYYOriginalControllerPlainInit)(id, SEL);

NSString *DYYYNowPlayingPrivacyBuildIdentifier(void) { return @"now-playing-runtime-sessions-20261121.1"; }

static void DYYYReconcileNowPlayingPrivacy(void) {
    if (gDYYYNowPlayingPolicy) {
        [gDYYYNowPlayingPolicy setSuppressed:
            [NSUserDefaults.standardUserDefaults boolForKey:DYYY_DISABLE_FEED_NOW_PLAYING_INFO_KEY]];
    }
}
static id DYYYMediaObject(id object, SEL selector) {
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}
static BOOL DYYYMediaBoolean(id object, SEL selector) {
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
}
static void DYYYTrackNowPlayingCenter(id center) {
    if (!center) return;
    if ([center respondsToSelector:@selector(isInvalidated)] && DYYYMediaBoolean(center, @selector(isInvalidated))) return;
    if (DYYYOriginalInfo && [center respondsToSelector:@selector(nowPlayingInfo)]) {
        [gDYYYNowPlayingPolicy seedValue:DYYYMediaObject(center, @selector(nowPlayingInfo)) owner:center channel:@"metadata"];
    }
    SEL contentGetter = NSSelectorFromString(@"nowPlayingContentItem");
    if (DYYYOriginalContentItem && [center respondsToSelector:contentGetter]) {
        [gDYYYNowPlayingPolicy seedValue:DYYYMediaObject(center, contentGetter) owner:center channel:@"content-item"];
    }
    if (DYYYOriginalState && [center respondsToSelector:@selector(playbackState)]) {
        NSUInteger state = ((NSUInteger (*)(id, SEL))objc_msgSend)(center, @selector(playbackState));
        [gDYYYNowPlayingPolicy seedValue:@(state) owner:center channel:@"state"];
    }
}
static void DYYYTrackSession(id session, id center) {
    if (!session) return;
    SEL autoGetter = NSSelectorFromString(@"automaticallyPublishesNowPlayingInfo");
    if (DYYYOriginalSessionAuto && [session respondsToSelector:autoGetter]) {
        [gDYYYNowPlayingPolicy seedValue:@(DYYYMediaBoolean(session, autoGetter)) owner:session channel:@"session-auto"];
    }
    SEL activeGetter = NSSelectorFromString(@"canBecomeActive");
    if (DYYYOriginalSessionEligible && [session respondsToSelector:activeGetter]) {
        [gDYYYNowPlayingPolicy seedValue:@(DYYYMediaBoolean(session, activeGetter)) owner:session channel:@"session-eligible"];
    }
    if (DYYYOriginalSessionBaseInfo && [session respondsToSelector:@selector(baseNowPlayingInfo)]) {
        [gDYYYNowPlayingPolicy seedValue:DYYYMediaObject(session, @selector(baseNowPlayingInfo)) owner:session channel:@"session-base"];
    }
    SEL manualGetter = NSSelectorFromString(@"nowPlayingInfo");
    if (DYYYOriginalSessionManualInfo && [session respondsToSelector:manualGetter]) {
        [gDYYYNowPlayingPolicy seedValue:DYYYMediaObject(session, manualGetter) owner:session channel:@"session-info"];
    }
    DYYYTrackNowPlayingCenter(center);
}
static void DYYYTrackController(id controller) {
    SEL getter = NSSelectorFromString(@"updatesNowPlayingInfoCenter");
    if (controller && DYYYOriginalControllerAuto && [controller respondsToSelector:getter]) {
        [gDYYYNowPlayingPolicy seedValue:@(DYYYMediaBoolean(controller, getter)) owner:controller channel:@"controller-auto"];
    }
}

static void DYYYWriteSystemInfo(id center, SEL selector, id info) {
    DYYYReconcileNowPlayingPrivacy();
    [gDYYYNowPlayingPolicy writeValue:info owner:center channel:@"metadata"];
}
static void DYYYWriteSystemContentItem(id center, SEL selector, id item) {
    DYYYReconcileNowPlayingPrivacy();
    [gDYYYNowPlayingPolicy writeValue:item owner:center channel:@"content-item"];
}
static void DYYYWriteSystemPlaybackState(id center, SEL selector, NSUInteger state) {
    DYYYReconcileNowPlayingPrivacy();
    [gDYYYNowPlayingPolicy writeValue:@(state) owner:center channel:@"state"];
}
static void DYYYInvalidateSystemCenter(id center, SEL selector) {
    [gDYYYNowPlayingPolicy forgetOwner:center];
    DYYYOriginalCenterInvalidate(center, selector);
}
static void DYYYWriteSessionBaseInfo(id session, SEL selector, id info) {
    DYYYReconcileNowPlayingPrivacy();
    [gDYYYNowPlayingPolicy writeValue:info owner:session channel:@"session-base"];
}
static void DYYYWriteSessionManualInfo(id session, SEL selector, id info) {
    DYYYReconcileNowPlayingPrivacy();
    [gDYYYNowPlayingPolicy writeValue:info owner:session channel:@"session-info"];
}
static void DYYYWriteSessionAutoPublish(id session, SEL selector, BOOL requested) {
    DYYYReconcileNowPlayingPrivacy();
    [gDYYYNowPlayingPolicy writeValue:@(requested) owner:session channel:@"session-auto"];
}
static void DYYYWriteSessionEligibility(id session, SEL selector, BOOL requested) {
    DYYYReconcileNowPlayingPrivacy();
    [gDYYYNowPlayingPolicy writeValue:@(requested) owner:session channel:@"session-eligible"];
}
static void DYYYWriteControllerAutoPublish(id controller, SEL selector, BOOL requested) {
    DYYYReconcileNowPlayingPrivacy();
    [gDYYYNowPlayingPolicy writeValue:@(requested) owner:controller channel:@"controller-auto"];
}
static void DYYYInvalidateSession(id session, SEL selector) {
    id center = DYYYOriginalSessionCenterGetter ? DYYYOriginalSessionCenterGetter(session, NSSelectorFromString(@"nowPlayingInfoCenter")) : nil;
    [gDYYYNowPlayingPolicy forgetOwner:session];
    [gDYYYNowPlayingPolicy forgetOwner:center];
    DYYYOriginalSessionInvalidate(session, selector);
}
static void DYYYSetSessionCenter(id session, SEL selector, id center) {
    id oldCenter = DYYYOriginalSessionCenterGetter ? DYYYOriginalSessionCenterGetter(session, NSSelectorFromString(@"nowPlayingInfoCenter")) : nil;
    if (oldCenter != center) [gDYYYNowPlayingPolicy forgetOwner:oldCenter];
    DYYYOriginalSessionCenterSetter(session, selector, center);
    DYYYReconcileNowPlayingPrivacy();
    DYYYTrackSession(session, center);
}
static id DYYYGetSessionCenter(id session, SEL selector) {
    if (!DYYYOriginalSessionCenterGetter) return nil;
    id center = DYYYOriginalSessionCenterGetter(session, selector);
    DYYYReconcileNowPlayingPrivacy();
    DYYYTrackSession(session, center);
    return center;
}
static id DYYYInitSessionWithPlayers(id session, SEL selector, id players) {
    id result = DYYYOriginalSessionPlayersInit(session, selector, players);
    DYYYTrackSession(result, result ? DYYYGetSessionCenter(result, NSSelectorFromString(@"nowPlayingInfoCenter")) : nil);
    return result;
}
static id DYYYInitSessionWithPath(id session, SEL selector, id playerPath, id routingContext) {
    id result = DYYYOriginalSessionPathInit(session, selector, playerPath, routingContext);
    DYYYTrackSession(result, result ? DYYYGetSessionCenter(result, NSSelectorFromString(@"nowPlayingInfoCenter")) : nil);
    return result;
}
static id DYYYInitAVPlayerControllerWithNib(id controller, SEL selector, id nibName, id bundle) {
    id result = DYYYOriginalControllerNibInit(controller, selector, nibName, bundle);
    DYYYTrackController(result);
    return result;
}
static id DYYYInitAVPlayerControllerWithCoder(id controller, SEL selector, id coder) {
    id result = DYYYOriginalControllerCoderInit(controller, selector, coder);
    DYYYTrackController(result);
    return result;
}
static id DYYYInitAVPlayerController(id controller, SEL selector) {
    id result = DYYYOriginalControllerPlainInit(controller, selector);
    DYYYTrackController(result);
    return result;
}

static DYYYRuntimeHookInstallResult DYYYInstallNowPlayingHook(NSString *identifier, NSString *className,
    NSString *selectorName, const char *const *encodings, NSUInteger count, IMP replacement, IMP *original) {
    DYYYRuntimeHookRequest request = {
        .identifier = identifier.UTF8String,
        .targetClass = NSClassFromString(className),
        .selector = NSSelectorFromString(selectorName),
        .classMethod = NO,
        .replacement = replacement,
        .allowedTypeEncodings = encodings,
        .allowedTypeEncodingCount = count,
        .originalImplementation = original,
    };
    DYYYRuntimeHookInstallResult result = DYYYInstallRuntimeHook(request);
    if (result.status != DYYYRuntimeHookInstallStatusInstalled && result.status != DYYYRuntimeHookInstallStatusAlreadyInstalled &&
        result.status != DYYYRuntimeHookInstallStatusTargetClassMissing && result.status != DYYYRuntimeHookInstallStatusTargetMethodMissing) {
        NSLog(@"[DYYY][NowPlaying] hook=%@ target=%@ selector=%@ status=%@ encoding=%s", identifier, className, selectorName,
              DYYYRuntimeHookInstallStatusName(result.status), result.actualTypeEncoding ?: "<missing>");
    }
    return result;
}
static BOOL DYYYInstallNowPlayingChannel(NSString *identifier, NSString *className, NSString *selectorName,
    const char *const *encodings, NSUInteger count, IMP replacement, IMP *original,
    NSString *channel, id hiddenValue, void (^sink)(id, id)) {
    DYYYRuntimeHookInstallResult result = DYYYInstallNowPlayingHook(identifier, className, selectorName,
        encodings, count, replacement, original);
    if (result.status != DYYYRuntimeHookInstallStatusInstalled && result.status != DYYYRuntimeHookInstallStatusAlreadyInstalled) return NO;
    if (channel) return [gDYYYNowPlayingPolicy configureChannel:channel hiddenValue:hiddenValue sink:sink];
    return YES;
}
static void DYYYInstallNowPlayingHooks(void) {
    static const char *objectSetter[] = {"v24@0:8@16"};
    static const char *unsignedSetter[] = {"v24@0:8Q16", "v24@0:8q16"};
    static const char *booleanSetter[] = {"v20@0:8B16", "v20@0:8c16"};
    static const char *objectGetter[] = {"@16@0:8"};
    static const char *sessionInit[] = {"@24@0:8@16"};
    static const char *sessionPathInit[] = {"@32@0:8@16@24"};
    static const char *avInitNib[] = {"@32@0:8@16@24"};
    static const char *avInitCoder[] = {"@24@0:8@16"};
    static const char *plainInit[] = {"@16@0:8"};
    static const char *voidMethod[] = {"v16@0:8"};

    DYYYInstallNowPlayingChannel(@"system.metadata", @"MPNowPlayingInfoCenter", @"setNowPlayingInfo:", objectSetter, 1,
        (IMP)DYYYWriteSystemInfo, (IMP *)&DYYYOriginalInfo, @"metadata", nil,
        ^(id owner, id value) { DYYYOriginalInfo(owner, @selector(setNowPlayingInfo:), value); });
    DYYYInstallNowPlayingChannel(@"system.content-item", @"MPNowPlayingInfoCenter", @"setNowPlayingContentItem:", objectSetter, 1,
        (IMP)DYYYWriteSystemContentItem, (IMP *)&DYYYOriginalContentItem, @"content-item", nil,
        ^(id owner, id value) { DYYYOriginalContentItem(owner, NSSelectorFromString(@"setNowPlayingContentItem:"), value); });
    DYYYInstallNowPlayingChannel(@"system.playback-state", @"MPNowPlayingInfoCenter", @"setPlaybackState:", unsignedSetter, 2,
        (IMP)DYYYWriteSystemPlaybackState, (IMP *)&DYYYOriginalState, @"state", @0,
        ^(id owner, id value) { DYYYOriginalState(owner, @selector(setPlaybackState:), [value unsignedIntegerValue]); });
    DYYYInstallNowPlayingHook(@"system.invalidate", @"MPNowPlayingInfoCenter", @"invalidate", voidMethod, 1,
        (IMP)DYYYInvalidateSystemCenter, (IMP *)&DYYYOriginalCenterInvalidate);

    DYYYInstallNowPlayingChannel(@"session.base-info", @"MPNowPlayingSession", @"setBaseNowPlayingInfo:", objectSetter, 1,
        (IMP)DYYYWriteSessionBaseInfo, (IMP *)&DYYYOriginalSessionBaseInfo, @"session-base", nil,
        ^(id owner, id value) { DYYYOriginalSessionBaseInfo(owner, NSSelectorFromString(@"setBaseNowPlayingInfo:"), value); });
    DYYYInstallNowPlayingChannel(@"session.manual-info", @"MPNowPlayingSession", @"setNowPlayingInfo:", objectSetter, 1,
        (IMP)DYYYWriteSessionManualInfo, (IMP *)&DYYYOriginalSessionManualInfo, @"session-info", nil,
        ^(id owner, id value) { DYYYOriginalSessionManualInfo(owner, NSSelectorFromString(@"setNowPlayingInfo:"), value); });
    DYYYInstallNowPlayingHook(@"session.invalidate", @"MPNowPlayingSession", @"invalidate", voidMethod, 1,
        (IMP)DYYYInvalidateSession, (IMP *)&DYYYOriginalSessionInvalidate);
    DYYYInstallNowPlayingChannel(@"session.autopublish", @"MPNowPlayingSession", @"setAutomaticallyPublishesNowPlayingInfo:", booleanSetter, 2,
        (IMP)DYYYWriteSessionAutoPublish, (IMP *)&DYYYOriginalSessionAuto, @"session-auto", @NO,
        ^(id owner, id value) { DYYYOriginalSessionAuto(owner, NSSelectorFromString(@"setAutomaticallyPublishesNowPlayingInfo:"), [value boolValue]); });
    DYYYInstallNowPlayingChannel(@"session.active", @"MPNowPlayingSession", @"setCanBecomeActive:", booleanSetter, 2,
        (IMP)DYYYWriteSessionEligibility, (IMP *)&DYYYOriginalSessionEligible, @"session-eligible", @NO,
        ^(id owner, id value) { DYYYOriginalSessionEligible(owner, NSSelectorFromString(@"setCanBecomeActive:"), [value boolValue]); });
    DYYYInstallNowPlayingHook(@"session.init.players", @"MPNowPlayingSession", @"initWithPlayers:", sessionInit, 1,
        (IMP)DYYYInitSessionWithPlayers, (IMP *)&DYYYOriginalSessionPlayersInit);
    DYYYInstallNowPlayingHook(@"session.init.player-path", @"MPNowPlayingSession", @"initWithPlayerPath:routingContextID:", sessionPathInit, 1,
        (IMP)DYYYInitSessionWithPath, (IMP *)&DYYYOriginalSessionPathInit);
    DYYYInstallNowPlayingHook(@"session.center", @"MPNowPlayingSession", @"nowPlayingInfoCenter", objectGetter, 1,
        (IMP)DYYYGetSessionCenter, (IMP *)&DYYYOriginalSessionCenterGetter);
    DYYYInstallNowPlayingHook(@"session.set-center", @"MPNowPlayingSession", @"setNowPlayingInfoCenter:", objectSetter, 1,
        (IMP)DYYYSetSessionCenter, (IMP *)&DYYYOriginalSessionCenterSetter);

    DYYYInstallNowPlayingChannel(@"avplayer-controller.autopublish", @"AVPlayerViewController", @"setUpdatesNowPlayingInfoCenter:", booleanSetter, 2,
        (IMP)DYYYWriteControllerAutoPublish, (IMP *)&DYYYOriginalControllerAuto, @"controller-auto", @NO,
        ^(id owner, id value) { DYYYOriginalControllerAuto(owner, NSSelectorFromString(@"setUpdatesNowPlayingInfoCenter:"), [value boolValue]); });
    DYYYInstallNowPlayingHook(@"avplayer-controller.init.nib", @"AVPlayerViewController", @"initWithNibName:bundle:", avInitNib, 1,
        (IMP)DYYYInitAVPlayerControllerWithNib, (IMP *)&DYYYOriginalControllerNibInit);
    DYYYInstallNowPlayingHook(@"avplayer-controller.init.coder", @"AVPlayerViewController", @"initWithCoder:", avInitCoder, 1,
        (IMP)DYYYInitAVPlayerControllerWithCoder, (IMP *)&DYYYOriginalControllerCoderInit);
    DYYYInstallNowPlayingHook(@"avplayer-controller.init", @"AVPlayerViewController", @"init", plainInit, 1,
        (IMP)DYYYInitAVPlayerController, (IMP *)&DYYYOriginalControllerPlainInit);
}
static void DYYYTrackDefaultSystemCenter(void) {
    Class cls = NSClassFromString(@"MPNowPlayingInfoCenter");
    SEL selector = @selector(defaultCenter);
    if (!cls || ![cls respondsToSelector:selector]) return;
    DYYYTrackNowPlayingCenter(((id (*)(id, SEL))objc_msgSend)(cls, selector));
}
static BOOL DYYYHookPendingIfPresent(Class cls, NSString *selectorName, IMP original) {
    return cls && class_getInstanceMethod(cls, NSSelectorFromString(selectorName)) && !original;
}
static BOOL DYYYNowPlayingHookPending(void) {
    Class systemCenter = NSClassFromString(@"MPNowPlayingInfoCenter");
    Class session = NSClassFromString(@"MPNowPlayingSession");
    Class controller = NSClassFromString(@"AVPlayerViewController");
    return DYYYHookPendingIfPresent(systemCenter, @"setNowPlayingInfo:", (IMP)DYYYOriginalInfo) ||
        DYYYHookPendingIfPresent(systemCenter, @"setPlaybackState:", (IMP)DYYYOriginalState) ||
        DYYYHookPendingIfPresent(session, @"setBaseNowPlayingInfo:", (IMP)DYYYOriginalSessionBaseInfo) ||
        DYYYHookPendingIfPresent(session, @"setAutomaticallyPublishesNowPlayingInfo:", (IMP)DYYYOriginalSessionAuto) ||
        DYYYHookPendingIfPresent(session, @"setCanBecomeActive:", (IMP)DYYYOriginalSessionEligible) ||
        DYYYHookPendingIfPresent(controller, @"setUpdatesNowPlayingInfoCenter:", (IMP)DYYYOriginalControllerAuto);
}
static void DYYYApplyCurrentNowPlayingPolicy(void) {
    DYYYInstallNowPlayingHooks();
    [gDYYYNowPlayingPolicy setSuppressed:
        [NSUserDefaults.standardUserDefaults boolForKey:DYYY_DISABLE_FEED_NOW_PLAYING_INFO_KEY]];
    DYYYTrackDefaultSystemCenter();
}
void DYYYStartNowPlayingPrivacy(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gDYYYNowPlayingPolicy = [DYYYNowPlayingPolicy new];
        DYYYInstallNowPlayingHooks();
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
            DYYYInstallNowPlayingHooks();
            DYYYApplyCurrentNowPlayingPolicy();
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:NSUserDefaultsDidChangeNotification object:NSUserDefaults.standardUserDefaults queue:nil usingBlock:^(__unused NSNotification *note) {
            dispatch_async(dispatch_get_main_queue(), ^{ DYYYApplyCurrentNowPlayingPolicy(); });
        }];
        DYYYApplyCurrentNowPlayingPolicy();
        __block NSUInteger attempts = 0;
        __block void (^retry)(void);
        retry = ^{
            DYYYInstallNowPlayingHooks();
            DYYYApplyCurrentNowPlayingPolicy();
            if (++attempts < 20 && DYYYNowPlayingHookPending()) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), retry);
            } else {
                retry = nil;
            }
        };
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), retry);
    });
}
void DYYYApplyNowPlayingPrivacySettingChange(BOOL hidden) {
    (void)hidden;
    if (!gDYYYNowPlayingPolicy) DYYYStartNowPlayingPrivacy();
    dispatch_async(dispatch_get_main_queue(), ^{ DYYYApplyCurrentNowPlayingPolicy(); });
}
