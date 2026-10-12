//
//  DYYY
//
//  Copyright (c) 2024 huami. All rights reserved.
//  Channel: @huamidev
//  Created on: 2024/10/04
//
#import <QuartzCore/QuartzCore.h>
#include <stdarg.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <float.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <substrate.h>
#import <stdlib.h>
#import <string.h>
#import <syslog.h>

#import "AwemeHeaders.h"
#import "CityManager.h"
#import "DYYYBottomAlertView.h"
#import "DYYYGlassConfirmView.h"
#import "DYYYManager.h"

#import "AWMSafeDispatchTimer.h"
#import "DYYYConstants.h"
#import "DYYYFloatClearButton.h"
#import "DYYYFloatSpeedButton.h"
#import "DYYYLivePreStreamLayoutCoordinator.h"
#import "DYYYLoginBypassManager.h"
#import "DYYYLoginRepairHooks.h"
#import "DYYYHideMusicButtonHooks.h"
#import "DYYYHideShareContentViewHooks.h"
#import "DYYYHideMessageAndMinePageHooks.h"
#import "DYYYHideCommentAIAnalysisHooks.h"
#import "DYYYHideTemplateCollectionHooks.h"
#import "DYYYSearchKeyboardVoiceHooks.h"
#import "DYYYHighFPSHooks.h"
#import "DYYYFPSOverlay.h"
#import "DYYYHookManager.h"
#import "DYYYMiniProgramRewardBypass.h"
#import "DYYYPrivacyRecordUploadGuard.h"
#import "DYYYSettingViewController.h"
#import "DYYYToast.h"
#import "DYYYUtils.h"

static CGFloat gStartY = 0.0;
static CGFloat gStartVal = 0.0;
static DYEdgeMode gMode = DYEdgeModeNone;
static __weak UICollectionView *gFeedCV = nil;

static const CGFloat kInvalidAlpha = -1.0;
static const CGFloat kInvalidHeight = -1.0;
static CGFloat gGlobalTransparency = kInvalidAlpha;
static CGFloat gCurrentTabBarHeight = kInvalidHeight;
static CGFloat originalTabBarHeight = kInvalidHeight;
static NSString *const kDYYYGlobalTransparencyKey = @"DYYYGlobalTransparency";
static NSString *const kDYYYGlobalTransparencyDidChangeNotification = @"DYYYGlobalTransparencyDidChangeNotification";
static NSString *const kDYYYEnableLoginBypassKey = @"DYYYEnableLoginBypass";
static char kDYYYGlobalTransparencyBaseAlphaKey;
static NSInteger dyyyGlobalTransparencyMutationDepth = 0;

static BOOL DYYYLoginBypassEnabled(void) {
    return [DYYYLoginBypassManager isLoginBypassEnabled];
}

static BOOL DYYYShouldBlockVersionUpdateWorkflow(void) {
    return DYYYGetBool(@"DYYYNoUpdates") || DYYYLoginBypassEnabled();
}

static void DYYYLoginBypassInvokeCloseCallback(id callback) {
    if (!callback) {
        return;
    }

    void (^completionBlock)(void) = callback;
    completionBlock();
}

static NSString *DYYYLoginBypassReplacementBundleIdentifier(NSString *bundleIdentifier) {
    return [DYYYLoginBypassManager replacementBundleIdentifier:bundleIdentifier];
}

static NSString *DYYYLoginBypassHeaderValueByReplacingBundleIdentifier(NSString *value, NSString *field) {
    return [DYYYLoginBypassManager headerValueByReplacingBundleIdentifier:value field:field];
}

static NSDictionary *DYYYLoginBypassHeadersByReplacingBundleIdentifiers(NSDictionary *headers) {
    return [DYYYLoginBypassManager headersByReplacingBundleIdentifiers:headers];
}

static NSURL *DYYYLoginBypassURLByReplacingBundleIdentifier(NSURL *url) {
    return [DYYYLoginBypassManager URLByReplacingTargetBundleIdentifiers:url];
}

%group DYYYLoginBypassCore


// ===== DYYY 统一日志（变参，动态沙盒路径）=====
static NSString *DYYYLogPath(void) {
    NSString *home = NSHomeDirectory();
    if (home.length == 0) return nil;
    return [[home stringByAppendingPathComponent:@"Documents"]
            stringByAppendingPathComponent:@"dyyy_fs.log"];
}

static void DLog(NSString *fmt, ...) {
    @autoreleasepool {
        va_list ap;
        va_start(ap, fmt);
        NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
        NSString *path = DYYYLogPath();
        if (!s || !path) return;
        FILE *fp = fopen(path.UTF8String, "a");
        if (!fp) return;
        fputs(([s stringByAppendingString:@"\n"]).UTF8String, fp);
        fclose(fp);
    }
}

%hook NSBundle
- (NSString *)bundleIdentifier {
    NSString *bundleIdentifier = %orig;
    return DYYYLoginBypassReplacementBundleIdentifier(bundleIdentifier);
}

- (NSDictionary *)infoDictionary {
    NSDictionary *infoDictionary = %orig;
    if (![infoDictionary isKindOfClass:[NSDictionary class]]) {
        return infoDictionary;
    }

    NSString *bundleIdentifier = infoDictionary[@"CFBundleIdentifier"];
    NSString *replacementIdentifier = DYYYLoginBypassReplacementBundleIdentifier(bundleIdentifier);
    if (![replacementIdentifier isKindOfClass:[NSString class]] || replacementIdentifier.length == 0 ||
        [replacementIdentifier isEqualToString:bundleIdentifier]) {
        return infoDictionary;
    }

    NSMutableDictionary *mutableInfoDictionary = [infoDictionary mutableCopy];
    mutableInfoDictionary[@"CFBundleIdentifier"] = replacementIdentifier;
    return mutableInfoDictionary;
}
%end

%hook NSURLRequest
- (NSURL *)URL {
    NSURL *url = %orig;
    return DYYYLoginBypassURLByReplacingBundleIdentifier(url);
}
%end

%hook NSMutableURLRequest
- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    %orig(DYYYLoginBypassHeaderValueByReplacingBundleIdentifier(value, field), field);
}

- (void)addValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    %orig(DYYYLoginBypassHeaderValueByReplacingBundleIdentifier(value, field), field);
}

- (void)setURL:(NSURL *)url {
    %orig(DYYYLoginBypassURLByReplacingBundleIdentifier(url));
}
%end

%hook NSURLSessionConfiguration
- (NSDictionary *)HTTPAdditionalHeaders {
    NSDictionary *headers = %orig;
    return DYYYLoginBypassHeadersByReplacingBundleIdentifiers(headers);
}

- (void)setHTTPAdditionalHeaders:(NSDictionary *)headers {
    %orig(DYYYLoginBypassHeadersByReplacingBundleIdentifiers(headers));
}
%end

%end

%group DYYYLoginBypassAccountLifecycle

%hook AWEUserServiceListener

- (void)didFinishLoginWithUid:(NSString *)userID {
    %orig(userID);
    [DYYYLoginBypassManager handleOfficialLoginCompletionWithUserID:userID];
}

%end

%end

%group DYYYLoginBypassAccountLogout

%hook AWEUserServiceListener

- (void)didFinishLogoutWithUid:(NSString *)userID {
    %orig(userID);
    [DYYYLoginBypassManager handleOfficialLogout];
}

%end

%end

%group DYYYLoginBypassAccountLifecycleDidFinishLogin

%hook AWEUserServiceListener

- (void)didFinishLogin:(id)user {
    %orig(user);
    [DYYYLoginBypassManager handleOfficialLoginCompletionWithUserID:user];
}

%end

%end

%group DYYYLoginBypassAccountMulticast

%hook TTAccountMulticast

- (void)broadcastLoginSuccess:(id)user platform:(id)platform reason:(long long)reason {
    %orig(user, platform, reason);
    [DYYYLoginBypassManager handleOfficialLoginCompletionWithUserID:user];
}

%end

%end

%group DYYYLoginBypassVersionUpdateAlert
%hook AWEVersionUpdateAlert
- (BOOL)canShow {
    return DYYYShouldBlockVersionUpdateWorkflow() ? NO : %orig;
}

- (BOOL)canShowWithUpgradeStatus {
    return DYYYShouldBlockVersionUpdateWorkflow() ? NO : %orig;
}

- (BOOL)isUpgradeStatusVersionValid {
    return DYYYShouldBlockVersionUpdateWorkflow() ? NO : %orig;
}

- (BOOL)versionCompareForNeedUpgrade {
    return DYYYShouldBlockVersionUpdateWorkflow() ? NO : %orig;
}

- (void)showWithCloseCallback:(id)closeCallback {
    if (DYYYShouldBlockVersionUpdateWorkflow()) {
        DYYYLoginBypassInvokeCloseCallback(closeCallback);
        return;
    }
    %orig(closeCallback);
}

- (void)_showUpgradeModal {
    if (DYYYShouldBlockVersionUpdateWorkflow()) {
        return;
    }
    %orig;
}

- (void)showDialog {
    if (DYYYShouldBlockVersionUpdateWorkflow()) {
        return;
    }
    %orig;
}

- (void)requestNewVersion {
    if (DYYYShouldBlockVersionUpdateWorkflow()) {
        return;
    }
    %orig;
}
%end
%end

%group DYYYLoginBypassVersionUpdatePopup
%hook AWEVersionUpdatePopup
- (BOOL)isShowing {
    return DYYYShouldBlockVersionUpdateWorkflow() ? NO : %orig;
}

- (void)showDialog {
    if (DYYYShouldBlockVersionUpdateWorkflow()) {
        return;
    }
    %orig;
}

- (void)showInfoPanel {
    if (DYYYShouldBlockVersionUpdateWorkflow()) {
        return;
    }
    %orig;
}

- (void)p_showDialog {
    if (DYYYShouldBlockVersionUpdateWorkflow()) {
        return;
    }
    %orig;
}

- (void)p_showInfoPanel {
    if (DYYYShouldBlockVersionUpdateWorkflow()) {
        return;
    }
    %orig;
}
%end
%end

%group DYYYLoginBypassVersionUpdateWorkflow
%hook AWEVersionUpdateWorkflow
- (void)startVersionUpdateWorkflow:(id)request completion:(id)completion {
    if (DYYYShouldBlockVersionUpdateWorkflow()) {
        DYYYLoginBypassInvokeCloseCallback(completion);
        return;
    }
    %orig(request, completion);
}

- (void)openAppStore {
    if (DYYYShouldBlockVersionUpdateWorkflow()) {
        return;
    }
    %orig;
}

- (void)showLoadingView {
    if (DYYYShouldBlockVersionUpdateWorkflow()) {
        return;
    }
    %orig;
}
%end
%end

%group DYYYLoginBypassTeenVersionUpdateManager
%hook AWETeenVersionUpdateManager
- (BOOL)canShow {
    return DYYYShouldBlockVersionUpdateWorkflow() ? NO : %orig;
}

- (void)showWithCloseCallback:(id)closeCallback {
    if (DYYYShouldBlockVersionUpdateWorkflow()) {
        DYYYLoginBypassInvokeCloseCallback(closeCallback);
        return;
    }
    %orig(closeCallback);
}

- (void)p_showUpgradeAlert {
    if (DYYYShouldBlockVersionUpdateWorkflow()) {
        return;
    }
    %orig;
}

- (BOOL)versionCompareForUpgrade {
    return DYYYShouldBlockVersionUpdateWorkflow() ? NO : %orig;
}

- (void)requestNewVersion {
    if (DYYYShouldBlockVersionUpdateWorkflow()) {
        return;
    }
    %orig;
}
%end
%end

%group DYYYLoginBypassPreLoginAlert
%hook AWEPreLoginAlertManager
- (BOOL)canShow {
    return DYYYShouldBlockVersionUpdateWorkflow() ? NO : %orig;
}

- (BOOL)canShowNow {
    return DYYYShouldBlockVersionUpdateWorkflow() ? NO : %orig;
}
%end
%end

%group DYYYLoginBypassPreLoginFrequency
%hook AWEPreLoginAlertManager
- (BOOL)isShowFrequencySatisfied {
    return DYYYShouldBlockVersionUpdateWorkflow() ? NO : %orig;
}

- (BOOL)isShowFrequencySatisfiedByLoginStrategy {
    return DYYYShouldBlockVersionUpdateWorkflow() ? NO : %orig;
}
%end
%end

%group DYYYLoginBypassNewVersionAlert
%hook AWENewVersionAlertManager
- (BOOL)canShow {
    return DYYYShouldBlockVersionUpdateWorkflow() ? NO : %orig;
}
%end
%end

static void updateGlobalTransparencyCache() {
    NSString *transparentValue = DYYYGetString(kDYYYGlobalTransparencyKey);
    if (transparentValue.length > 0) {
        float alphaValue;
        NSScanner *scanner = [NSScanner scannerWithString:transparentValue];
        if ([scanner scanFloat:&alphaValue] && scanner.isAtEnd) {
            gGlobalTransparency = MIN(MAX(alphaValue, 0.0), 1.0);
            return;
        }
    }
    gGlobalTransparency = kInvalidAlpha;
}

static NSDictionary<NSString *, NSString *> *DYYYTopTabTitleMapping(void) {
    static NSString *cachedRawValue = nil;
    static NSDictionary<NSString *, NSString *> *cachedMapping = nil;

    NSString *currentValue = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYModifyTopTabText"];
    BOOL rawValueChanged = (cachedRawValue != currentValue) && ![cachedRawValue isEqualToString:currentValue];

    if (!rawValueChanged) {
        return cachedMapping;
    }

    cachedRawValue = [currentValue copy];

    if (currentValue.length == 0) {
        cachedMapping = nil;
        return nil;
    }

    NSMutableDictionary<NSString *, NSString *> *mapping = [NSMutableDictionary dictionary];
    NSArray<NSString *> *titlePairs = [currentValue componentsSeparatedByString:@"#"];
    NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];

    for (NSString *pair in titlePairs) {
        NSArray<NSString *> *components = [pair componentsSeparatedByString:@"="];
        if (components.count != 2) {
            continue;
        }

        NSString *originalTitle = [components[0] stringByTrimmingCharactersInSet:whitespace];
        NSString *newTitle = [components[1] stringByTrimmingCharactersInSet:whitespace];

        if (originalTitle.length == 0 || newTitle.length == 0) {
            continue;
        }

        mapping[originalTitle] = newTitle;
    }

    cachedMapping = mapping.count > 0 ? [mapping copy] : nil;
    return cachedMapping;
}

static NSString *DYYYCustomAssetsDirectory(void) {
    static NSString *customDirectory = nil;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
      NSString *documentsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
      customDirectory = [documentsPath stringByAppendingPathComponent:@"DYYY"];
      [[NSFileManager defaultManager] createDirectoryAtPath:customDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    });

    return customDirectory;
}

static NSString *DYYYCustomIconFileNameForButtonName(NSString *nameString) {
    if (nameString.length == 0) {
        return nil;
    }

    static NSDictionary<NSString *, NSString *> *prefixMapping = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      prefixMapping = @{
          @"icon_home_like_after" : @"like_after.png",
          @"icon_home_like_before" : @"like_before.png",
          @"icon_home_comment" : @"comment.png",
          @"icon_home_unfavorite" : @"unfavorite.png",
          @"icon_home_favorite" : @"favorite.png",
          @"iconHomeShareRight" : @"share.png"
      };
    });

    for (NSString *prefix in prefixMapping) {
        if ([nameString hasPrefix:prefix]) {
            return prefixMapping[prefix];
        }
    }

    if ([nameString containsString:@"_comment"]) {
        return @"comment.png";
    }
    if ([nameString containsString:@"_like"]) {
        BOOL isLikedState = [nameString containsString:@"_after"] || [nameString containsString:@"_liked"];
        return isLikedState ? @"like_after.png" : @"like_before.png";
    }
    if ([nameString containsString:@"_collect"]) {
        return @"unfavorite.png";
    }
    if ([nameString containsString:@"_share"]) {
        return @"share.png";
    }

    return nil;
}

static UIImage *DYYYLoadCustomImage(NSString *fileName, CGSize targetSize) {
    if (fileName.length == 0) {
        return nil;
    }

    static NSCache<NSString *, UIImage *> *imageCache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      imageCache = [[NSCache alloc] init];
      imageCache.name = @"com.dyyy.customIcons.cache";
    });

    NSString *cacheKey = (targetSize.width > 0.0 && targetSize.height > 0.0) ? [NSString stringWithFormat:@"%@_%0.1f_%0.1f", fileName, targetSize.width, targetSize.height] : fileName;

    UIImage *cachedImage = [imageCache objectForKey:cacheKey];
    if (cachedImage) {
        return cachedImage;
    }

    NSString *fullPath = [DYYYCustomAssetsDirectory() stringByAppendingPathComponent:fileName];
    UIImage *sourceImage = [UIImage imageWithContentsOfFile:fullPath];
    if (!sourceImage) {
        return nil;
    }

    if (targetSize.width <= 0.0 || targetSize.height <= 0.0) {
        [imageCache setObject:sourceImage forKey:cacheKey];
        return sourceImage;
    }

    CGSize originalSize = sourceImage.size;
    if (originalSize.width <= 0.0 || originalSize.height <= 0.0) {
        return sourceImage;
    }

    CGFloat widthScale = targetSize.width / originalSize.width;
    CGFloat heightScale = targetSize.height / originalSize.height;
    CGFloat scale = fmin(widthScale, heightScale);

    if (fabs(1.0 - scale) <= FLT_EPSILON) {
        [imageCache setObject:sourceImage forKey:cacheKey];
        return sourceImage;
    }

    CGSize newSize = CGSizeMake(originalSize.width * scale, originalSize.height * scale);
    UIGraphicsBeginImageContextWithOptions(newSize, NO, 0.0);
    [sourceImage drawInRect:CGRectMake(0, 0, newSize.width, newSize.height)];
    UIImage *resizedImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    UIImage *resultImage = resizedImage ?: sourceImage;
    [imageCache setObject:resultImage forKey:cacheKey];
    return resultImage;
}

static __weak AWEPlayInteractionViewController *dyyyActivePlaybackInteractionController = nil;
static __weak UIViewController *dyyyActiveSpeedPlayerViewController = nil;
static __weak AWEDPlayerSpeedController *dyyyActiveDPlayerSpeedController = nil;
static __weak AWEDPlayerSpeedController *dyyyLongPressDPlayerSpeedController = nil;
static __weak AFDSpeedManager *dyyyActiveNativeSpeedManager = nil;
static __weak AWEAwemeModel *dyyyCurrentSpeedAweme = nil;
static NSString *dyyyCommittedSpeedAwemeIdentifier = nil;
static NSHashTable<_TtC33AWECommentPanelContainerSwiftImpl30CommentContainerInnerViewModel *> *dyyyCommentPauseViewModels = nil;
static __weak _TtC33AWECommentPanelContainerSwiftImpl30CommentContainerInnerViewModel *dyyyLastCommentPauseViewModel = nil;

static float DYYYConfiguredDefaultPlaybackSpeed(void) {
    float speed = [[NSUserDefaults standardUserDefaults] floatForKey:@"DYYYDefaultSpeed"];
    return isfinite(speed) && speed > 0.0f ? speed : 1.0f;
}

static BOOL DYYYNativeLockedPlaybackSpeed(float *speedOut) {
    @try {
        AFDSpeedManager *speedManager = dyyyActiveNativeSpeedManager;
        if (!speedManager) {
            Class managerClass = NSClassFromString(@"AFDSpeedManager");
            if ([managerClass respondsToSelector:@selector(sharedInstance)]) {
                speedManager = [(id)managerClass sharedInstance];
            }
        }
        if (![speedManager respondsToSelector:@selector(isLockedSpeedAwemeID)] ||
            ![speedManager respondsToSelector:@selector(currentSpeed)]) {
            return NO;
        }

        NSString *lockedAwemeID = [speedManager isLockedSpeedAwemeID];
        if (![lockedAwemeID isKindOfClass:[NSString class]] || lockedAwemeID.length == 0) {
            return NO;
        }

        NSString *currentAwemeID = dyyyCurrentSpeedAweme.itemID;
        if (currentAwemeID.length > 0 && ![currentAwemeID isEqualToString:lockedAwemeID]) {
            return NO;
        }

        double speed = [speedManager currentSpeed];
        if (!isfinite(speed) || speed <= 0.0) {
            return NO;
        }

        if (speedOut) {
            *speedOut = (float)speed;
        }
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static float DYYYUnlockedNormalPlaybackSpeed(void) {
    if (isFloatSpeedButtonEnabled) {
        float speed = getCurrentSpeed();
        if (isfinite(speed) && speed > 0.0f && fabsf(speed - 1.0f) > FLT_EPSILON) {
            return speed;
        }
    }
    return DYYYConfiguredDefaultPlaybackSpeed();
}

static float DYYYNormalPlaybackSpeed(void) {
    float lockedSpeed = 0.0f;
    if (DYYYNativeLockedPlaybackSpeed(&lockedSpeed)) {
        return lockedSpeed;
    }
    return DYYYUnlockedNormalPlaybackSpeed();
}

static BOOL DYYYShouldHandleSpeedFeatures(void) {
    if (isFloatSpeedButtonEnabled) {
        return YES;
    }

    float defaultSpeed = DYYYConfiguredDefaultPlaybackSpeed();
    return fabsf(defaultSpeed - 1.0f) > FLT_EPSILON;
}

static BOOL DYYYSpeedMethodMatchesEncoding(id object, SEL selector, const char *expectedEncoding) {
    if (!object || !selector || !expectedEncoding) {
        return NO;
    }
    Method method = class_getInstanceMethod(object_getClass(object), selector);
    const char *actualEncoding = method ? method_getTypeEncoding(method) : NULL;
    return actualEncoding && strcmp(actualEncoding, expectedEncoding) == 0;
}

static BOOL DYYYIsVerifiedNativeDPlayerSpeedController(id object) {
    return object &&
           DYYYSpeedMethodMatchesEncoding(object, @selector(playbackRate), "f16@0:8") &&
           DYYYSpeedMethodMatchesEncoding(object, @selector(setPlaybackRate:), "v20@0:8f16") &&
           DYYYSpeedMethodMatchesEncoding(object, @selector(isInLongPressSpeed), "B16@0:8");
}

static BOOL DYYYNativeDPlayerLongPressIsActive(AWEDPlayerSpeedController *speedController) {
    if (!DYYYIsVerifiedNativeDPlayerSpeedController(speedController)) {
        return NO;
    }
    @try {
        return [speedController isInLongPressSpeed];
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static BOOL DYYYAnyNativeDPlayerLongPressIsActive(void) {
    return DYYYNativeDPlayerLongPressIsActive(dyyyLongPressDPlayerSpeedController) ||
           DYYYNativeDPlayerLongPressIsActive(dyyyActiveDPlayerSpeedController);
}

static BOOL DYYYApplyPlaybackRateToNativeDPlayer(AWEDPlayerSpeedController *speedController, double speed) {
    if (!DYYYIsVerifiedNativeDPlayerSpeedController(speedController) ||
        !isfinite(speed) ||
        speed <= 0.0 ||
        DYYYAnyNativeDPlayerLongPressIsActive() ||
        DYYYNativeDPlayerLongPressIsActive(speedController)) {
        return NO;
    }

    @try {
        dyyyActiveDPlayerSpeedController = speedController;
        [speedController setPlaybackRate:(float)speed];
        return YES;
    } @catch (NSException *exception) {
        NSLog(@"[DYYY][Speed397] native setPlaybackRate failed on %@: %@",
              NSStringFromClass([speedController class]),
              exception.reason);
        return NO;
    }
}

static CGFloat DYYYViewControllerVisibilityScore(UIViewController *viewController) {
    if (!viewController || !viewController.isViewLoaded) {
        return -1.0;
    }

    UIView *view = viewController.view;
    UIWindow *window = view.window;
    if (!window || view.hidden || view.alpha <= 0.01 || CGRectIsEmpty(view.bounds)) {
        return -1.0;
    }

    CGRect frameInWindow = [view convertRect:view.bounds toView:window];
    CGRect visibleFrame = CGRectIntersection(frameInWindow, window.bounds);
    if (CGRectIsNull(visibleFrame) || CGRectIsEmpty(visibleFrame)) {
        return -1.0;
    }

    CGFloat visibleArea = CGRectGetWidth(visibleFrame) * CGRectGetHeight(visibleFrame);
    CGFloat totalArea = CGRectGetWidth(frameInWindow) * CGRectGetHeight(frameInWindow);
    CGFloat visibleRatio = totalArea > 0.0 ? visibleArea / totalArea : 0.0;
    CGPoint windowCenter = CGPointMake(CGRectGetMidX(window.bounds), CGRectGetMidY(window.bounds));
    CGFloat centerBonus = CGRectContainsPoint(visibleFrame, windowCenter) ? 1000000000.0 : 0.0;
    return centerBonus + visibleRatio * 1000000.0 + visibleArea;
}

static BOOL DYYYAwemeModelsMatch(AWEAwemeModel *lhs, AWEAwemeModel *rhs) {
    if (!lhs || !rhs) {
        return NO;
    }
    if (lhs == rhs) {
        return YES;
    }

    NSString *lhsItemID = lhs.itemID;
    NSString *rhsItemID = rhs.itemID;
    return lhsItemID.length > 0 && rhsItemID.length > 0 && [lhsItemID isEqualToString:rhsItemID];
}

static AWEAwemeModel *DYYYSpeedAwemeFromObject(id object) {
    Class awemeClass = NSClassFromString(@"AWEAwemeModel");
    if (!object || !awemeClass) {
        return nil;
    }
    if ([object isKindOfClass:awemeClass]) {
        return (AWEAwemeModel *)object;
    }

    for (NSString *key in @[ @"model", @"awemeModel", @"currentAweme" ]) {
        @try {
            id value = [object valueForKey:key];
            if ([value isKindOfClass:awemeClass]) {
                return (AWEAwemeModel *)value;
            }
        } @catch (NSException *exception) {
        }
    }
    return nil;
}

static NSArray<UIViewController *> *DYYYViewControllersInHierarchy(UIViewController *rootViewController) {
    if (!rootViewController) {
        return @[];
    }

    NSMutableArray<UIViewController *> *viewControllers = [NSMutableArray arrayWithObject:rootViewController];
    for (UIViewController *childViewController in rootViewController.childViewControllers) {
        [viewControllers addObjectsFromArray:DYYYViewControllersInHierarchy(childViewController)];
    }
    return viewControllers;
}

static NSArray<UIViewController *> *DYYYViewControllersInActiveWindowHierarchy(void) {
    UIWindow *window = [DYYYUtils getActiveWindow];
    UIViewController *rootViewController = window.rootViewController;
    NSMutableOrderedSet<UIViewController *> *viewControllers = [NSMutableOrderedSet orderedSet];
    while (rootViewController) {
        [viewControllers addObjectsFromArray:DYYYViewControllersInHierarchy(rootViewController)];
        rootViewController = rootViewController.presentedViewController;
    }
    return viewControllers.array;
}

static NSArray<AWEPlayInteractionViewController *> *DYYYPlaybackInteractionControllers(AWEPlayInteractionViewController *preferredController) {
    NSMutableArray<AWEPlayInteractionViewController *> *controllers = [NSMutableArray array];
    Class interactionControllerClass = NSClassFromString(@"AWEPlayInteractionViewController");

    for (UIViewController *viewController in DYYYViewControllersInActiveWindowHierarchy()) {
        if (interactionControllerClass && [viewController isKindOfClass:interactionControllerClass]) {
            [controllers addObject:(AWEPlayInteractionViewController *)viewController];
        }
    }
    if (preferredController && ![controllers containsObject:preferredController]) {
        [controllers addObject:preferredController];
    }
    return controllers;
}

static AWEPlayInteractionViewController *DYYYResolvePlaybackInteractionController(AWEPlayInteractionViewController *preferredController,
                                                                                  AWEAwemeModel *targetAweme,
                                                                                  BOOL allowVisibleFallback) {
    AWEPlayInteractionViewController *bestModelMatch = nil;
    AWEPlayInteractionViewController *bestVisibleController = nil;
    CGFloat bestModelMatchScore = -1.0;
    CGFloat bestVisibleScore = -1.0;

    for (AWEPlayInteractionViewController *controller in DYYYPlaybackInteractionControllers(preferredController)) {
        CGFloat visibilityScore = DYYYViewControllerVisibilityScore(controller);
        if (visibilityScore < 0.0) {
            continue;
        }
        if (visibilityScore > bestVisibleScore) {
            bestVisibleScore = visibilityScore;
            bestVisibleController = controller;
        }
        if (targetAweme && DYYYAwemeModelsMatch(controller.model, targetAweme) && visibilityScore > bestModelMatchScore) {
            bestModelMatchScore = visibilityScore;
            bestModelMatch = controller;
        }
    }
    return bestModelMatch ?: (allowVisibleFallback ? bestVisibleController : nil);
}

static void DYYYEnsureFloatSpeedButton(AWEPlayInteractionViewController *preferredController) {
    AWEPlayInteractionViewController *currentController =
        DYYYResolvePlaybackInteractionController(preferredController ?: dyyyActivePlaybackInteractionController,
                                                 dyyyCurrentSpeedAweme,
                                                 YES);
    if (!currentController) {
        updateSpeedButtonVisibility();
        return;
    }

    dyyyActivePlaybackInteractionController = currentController;
    if (!dyyyCurrentSpeedAweme && currentController.model) {
        dyyyCurrentSpeedAweme = currentController.model;
    }
    dyyyInteractionViewVisible = YES;

    if (!isFloatSpeedButtonEnabled) {
        if (speedButton) {
            speedButton.hidden = YES;
        }
        return;
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    CGFloat configuredSize = [defaults floatForKey:@"DYYYSpeedButtonSize"];
    speedButtonSize = configuredSize > 0.0 ? configuredSize : 35.0;
    showSpeedX = [defaults boolForKey:@"DYYYSpeedButtonShowX"];

    UIWindow *keyWindow = [DYYYUtils getActiveWindow];
    if (!keyWindow) {
        return;
    }

    if (!speedButton) {
        CGRect windowBounds = keyWindow.bounds;
        CGFloat initialY = CGRectGetHeight(windowBounds) * (1.0 - 0.65) - speedButtonSize / 2.0;
        initialY = MAX(10.0, MIN(initialY, CGRectGetHeight(windowBounds) - speedButtonSize - 10.0));
        CGRect initialFrame = CGRectMake(CGRectGetWidth(windowBounds) - speedButtonSize - 10.0,
                                         initialY,
                                         speedButtonSize,
                                         speedButtonSize);
        speedButton = [[FloatingSpeedButton alloc] initWithFrame:initialFrame];
        speedButton.interactionController = currentController;
        updateSpeedButtonUI();
    } else {
        if (speedButton.interactionController != currentController) {
            speedButton.interactionController = currentController;
        }
        if (fabs(CGRectGetWidth(speedButton.frame) - speedButtonSize) > 0.5) {
            speedButton.frame = CGRectMake(0, 0, speedButtonSize, speedButtonSize);
            speedButton.layer.cornerRadius = speedButtonSize / 2.0;
            [speedButton loadSavedPosition];
        }
    }

    if (![speedButton isDescendantOfView:keyWindow]) {
        [keyWindow addSubview:speedButton];
        [speedButton loadSavedPosition];
        [speedButton dyyy_schedulePresentationTimersIfNeeded];
    }

    [keyWindow bringSubviewToFront:speedButton];
    updateSpeedButtonUI();
    updateSpeedButtonVisibility();
}

void DYYYRefreshFloatSpeedButton(void) {
    dispatch_block_t refreshBlock = ^{
      DYYYEnsureFloatSpeedButton(dyyyActivePlaybackInteractionController);
    };
    if ([NSThread isMainThread]) {
        refreshBlock();
    } else {
        dispatch_async(dispatch_get_main_queue(), refreshBlock);
    }
}

static id DYYYBestVisiblePlaybackRateTarget(id preferredTarget) {
    if ([preferredTarget isKindOfClass:UIViewController.class] &&
        [preferredTarget respondsToSelector:@selector(setVideoControllerPlaybackRate:)] &&
        DYYYViewControllerVisibilityScore((UIViewController *)preferredTarget) >= 0.0) {
        return preferredTarget;
    }

    UIViewController *activePlayerViewController = dyyyActiveSpeedPlayerViewController;
    if (activePlayerViewController &&
        [activePlayerViewController respondsToSelector:@selector(setVideoControllerPlaybackRate:)] &&
        DYYYViewControllerVisibilityScore(activePlayerViewController) >= 0.0) {
        return activePlayerViewController;
    }

    UIViewController *bestPlayerViewController = nil;
    CGFloat bestVisibilityScore = -1.0;
    for (UIViewController *viewController in DYYYViewControllersInActiveWindowHierarchy()) {
        if ([viewController isKindOfClass:NSClassFromString(@"AWEAwemePlayVideoViewController")] ||
            [viewController isKindOfClass:NSClassFromString(@"AWEDPlayerFeedPlayerViewController")] ||
            [viewController isKindOfClass:NSClassFromString(@"AWEDPlayerViewController_Merge")]) {
            CGFloat visibilityScore = DYYYViewControllerVisibilityScore(viewController);
            if (visibilityScore > bestVisibilityScore) {
                bestVisibilityScore = visibilityScore;
                bestPlayerViewController = viewController;
            }
        }
    }
    return bestPlayerViewController;
}

static AWEDPlayerSpeedController *DYYYNativeDPlayerSpeedControllerFromFastSpeedController(id fastSpeedController) {
    if (DYYYIsVerifiedNativeDPlayerSpeedController(fastSpeedController)) {
        return (AWEDPlayerSpeedController *)fastSpeedController;
    }
    if (!fastSpeedController ||
        !DYYYSpeedMethodMatchesEncoding(fastSpeedController, @selector(dPlayerSpeed), "@16@0:8")) {
        return nil;
    }

    @try {
        id candidate = [(AWEPlayInteractionDPlayerSpeedController *)fastSpeedController dPlayerSpeed];
        return DYYYIsVerifiedNativeDPlayerSpeedController(candidate) ? (AWEDPlayerSpeedController *)candidate : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static AWEDPlayerSpeedController *DYYYNativeDPlayerSpeedControllerFromInteractionControllerOptions(AWEPlayInteractionViewController *interactionController,
                                                                                                  BOOL allowCachedController) {
    if (allowCachedController && dyyyActiveDPlayerSpeedController) {
        return dyyyActiveDPlayerSpeedController;
    }
    if (!interactionController || ![interactionController respondsToSelector:@selector(controllerByProtocol:)]) {
        return nil;
    }

    Protocol *speedControllerProtocol = NSProtocolFromString(@"AWEFastSpeedControllerProtocol");
    if (!speedControllerProtocol) {
        return nil;
    }

    @try {
        id fastSpeedController = [interactionController controllerByProtocol:speedControllerProtocol];
        return DYYYNativeDPlayerSpeedControllerFromFastSpeedController(fastSpeedController);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static AWEDPlayerSpeedController *DYYYNativeDPlayerSpeedControllerFromInteractionController(AWEPlayInteractionViewController *interactionController) {
    return DYYYNativeDPlayerSpeedControllerFromInteractionControllerOptions(interactionController, YES);
}

static BOOL DYYYSetPlaybackRateOnTarget(id target, double speed) {
    if (DYYYAnyNativeDPlayerLongPressIsActive() ||
        !target ||
        ![target respondsToSelector:@selector(setVideoControllerPlaybackRate:)]) {
        return NO;
    }

    @try {
        [(AWEAwemePlayVideoViewController *)target setVideoControllerPlaybackRate:speed];
        if ([target isKindOfClass:UIViewController.class]) {
            dyyyActiveSpeedPlayerViewController = (UIViewController *)target;
        }
        return YES;
    } @catch (NSException *exception) {
        NSLog(@"[DYYY][DefaultSpeed] apply failed on %@: %@", NSStringFromClass([target class]), exception.reason);
        return NO;
    }
}

static BOOL DYYYIsImageAlbumAweme(AWEAwemeModel *model) {
    return model && [model respondsToSelector:@selector(awemeType)] && model.awemeType == 68;
}

static BOOL DYYYInteractionUsesRichContent(AWEPlayInteractionViewController *interactionController) {
    if (!interactionController) {
        return NO;
    }

    AWEPlayInteractionContext *context = interactionController.context;
    if (context.isInRichContentContainer || context.richContentContainer || interactionController.richContentContainer) {
        return YES;
    }

    id videoDelegate = interactionController.videoDelegate ?: context.videoDelegate;
    return [videoDelegate respondsToSelector:@selector(setAlbumFastPlaySpeed:)];
}

static BOOL DYYYShouldUseImageAlbumSpeedPath(AWEPlayInteractionViewController *interactionController) {
    AWEAwemeModel *model = interactionController.model ?: dyyyCurrentSpeedAweme;
    return DYYYIsImageAlbumAweme(model) || DYYYInteractionUsesRichContent(interactionController);
}

static void DYYYSyncNativeSpeedManagerCurrentSpeed(double speed) {
    AFDSpeedManager *speedManager = dyyyActiveNativeSpeedManager;
    if (!speedManager) {
        Class managerClass = NSClassFromString(@"AFDSpeedManager");
        if ([managerClass respondsToSelector:@selector(sharedInstance)]) {
            speedManager = [(id)managerClass sharedInstance];
        }
    }
    if ([speedManager respondsToSelector:@selector(setCurrentSpeed:)]) {
        [speedManager setCurrentSpeed:speed];
    }
}

static BOOL DYYYApplySpeedToAFDSlidesView(AFDSlidesView *slidesView, double speed) {
    if (!slidesView || !isfinite(speed) || speed <= 0.0) {
        return NO;
    }

    @try {
        BOOL useFastRate = fabs(speed - 1.0) > 0.001;
        slidesView.fastPlaySpeed = useFastRate ? speed : 1.0;
        slidesView.needFastPlay = useFastRate;
        if ([slidesView isPlaying]) {
            [slidesView pauseTimer];
            [slidesView setupAndPlayTimer];
        } else {
            [slidesView playTimer];
        }
        return YES;
    } @catch (NSException *exception) {
        NSLog(@"[DYYY][Speed] AFDSlidesView fastPlay apply failed: %@", exception.reason);
        return NO;
    }
}

static BOOL DYYYApplySpeedToAFDSlidesViewsInHierarchy(UIView *rootView, double speed) {
    if (!rootView) {
        return NO;
    }

    Class slidesViewClass = NSClassFromString(@"AFDSlidesView");
    if (!slidesViewClass) {
        return NO;
    }

    BOOL applied = NO;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:rootView];
    while (queue.count > 0) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([view isKindOfClass:slidesViewClass] &&
            DYYYApplySpeedToAFDSlidesView((AFDSlidesView *)view, speed)) {
            applied = YES;
        }
        for (UIView *subview in view.subviews) {
            [queue addObject:subview];
        }
    }
    return applied;
}

static BOOL DYYYApplySpeedToVisibleAFDSlidesViews(AWEPlayInteractionViewController *interactionController,
                                                  id albumTarget,
                                                  double speed) {
    BOOL applied = NO;
    if (DYYYApplySpeedToAFDSlidesViewsInHierarchy(interactionController.view, speed)) {
        applied = YES;
    }
    if ([albumTarget isKindOfClass:UIViewController.class] &&
        DYYYApplySpeedToAFDSlidesViewsInHierarchy([(UIViewController *)albumTarget view], speed)) {
        applied = YES;
    }
    // 图文 slides 常挂在 interaction 覆盖层的兄弟子树，向上扩一层父视图再找。
    UIView *parentView = interactionController.view.superview;
    for (NSInteger depth = 0; parentView && depth < 4; depth++) {
        if (DYYYApplySpeedToAFDSlidesViewsInHierarchy(parentView, speed)) {
            applied = YES;
            break;
        }
        parentView = parentView.superview;
    }
    return applied;
}

static id DYYYRichContentAlbumSpeedTarget(AWEPlayInteractionViewController *interactionController) {
    if (!interactionController) {
        return nil;
    }

    AWEPlayInteractionContext *context = interactionController.context;
    id target = interactionController.richContentContainer ?: context.richContentContainer;
    if (!target) {
        target = interactionController.videoDelegate ?: context.videoDelegate;
    }
    return [target respondsToSelector:@selector(setAlbumFastPlaySpeed:)] ? target : nil;
}

static BOOL DYYYApplyImageAlbumPlaybackSpeed(AWEPlayInteractionViewController *interactionController, double speed) {
    if (!interactionController || !isfinite(speed) || speed <= 0.0 ||
        !DYYYShouldUseImageAlbumSpeedPath(interactionController)) {
        return NO;
    }

    BOOL applied = NO;
    BOOL useFastRate = fabs(speed - 1.0) > 0.001;
    DYYYSyncNativeSpeedManagerCurrentSpeed(speed);

    // 图文必须从当前 interaction 解析，避免复用上一个视频残留的 DPlayerSpeedController。
    AWEDPlayerSpeedController *dplayerSpeedController =
        DYYYNativeDPlayerSpeedControllerFromInteractionControllerOptions(interactionController, NO);
    if (dplayerSpeedController && [dplayerSpeedController respondsToSelector:@selector(speedContainer)]) {
        @try {
            AWEDSpeedCoreContainer *coreContainer = [dplayerSpeedController speedContainer];
            if (coreContainer.albumContainer) {
                [coreContainer.albumContainer changeAlbumSpeed:speed];
                applied = YES;
            }
            [coreContainer changeSpeed:speed];
            applied = YES;
        } @catch (NSException *exception) {
            NSLog(@"[DYYY][Speed] native album speed apply failed: %@", exception.reason);
        }
    }

    id albumTarget = DYYYRichContentAlbumSpeedTarget(interactionController);
    if (albumTarget) {
        @try {
            if ([albumTarget respondsToSelector:@selector(setAlbumFastPlaySpeed:enterMethod:)]) {
                [(id<AFDRichContentAlbumContainerProtocol>)albumTarget setAlbumFastPlaySpeed:speed
                                                                                 enterMethod:@"speed_button"];
            } else {
                [(id<AFDRichContentAlbumContainerProtocol>)albumTarget setAlbumFastPlaySpeed:speed];
            }
            // 配置写入后必须真正启用/关闭图文快播。
            // forcePlay:YES 会触发长按快进转场（拉伸/停顿/回弹）；这里用 forcePlay:NO 只驱动速率。
            if ([albumTarget respondsToSelector:@selector(setAlbumFastPlay:forcePlay:)]) {
                [(id<AFDRichContentAlbumContainerProtocol>)albumTarget setAlbumFastPlay:useFastRate
                                                                             forcePlay:NO];
            } else if ([albumTarget respondsToSelector:@selector(setAlbumFastPlay:)]) {
                [(id<AFDRichContentAlbumContainerProtocol>)albumTarget setAlbumFastPlay:useFastRate];
            }
            applied = YES;
        } @catch (NSException *exception) {
            NSLog(@"[DYYY][Speed] rich content album speed apply failed on %@: %@",
                  NSStringFromClass([albumTarget class]),
                  exception.reason);
        }
    }

    if (DYYYApplySpeedToVisibleAFDSlidesViews(interactionController, albumTarget, speed)) {
        applied = YES;
    }

    return applied;
}

static BOOL DYYYApplyPlaybackSpeedThroughInteractionController(AWEPlayInteractionViewController *interactionController, double speed) {
    if (!isfinite(speed) || speed <= 0.0) {
        return NO;
    }

    interactionController = DYYYResolvePlaybackInteractionController(interactionController, dyyyCurrentSpeedAweme, YES);
    if (!interactionController) {
        return DYYYSetPlaybackRateOnTarget(DYYYBestVisiblePlaybackRateTarget(nil), speed);
    }

    if (DYYYShouldUseImageAlbumSpeedPath(interactionController)) {
        return DYYYApplyImageAlbumPlaybackSpeed(interactionController, speed);
    }

    Protocol *speedControllerProtocol = NSProtocolFromString(@"AWEFastSpeedControllerProtocol");
    if (speedControllerProtocol && [interactionController respondsToSelector:@selector(controllerByProtocol:)]) {
        @try {
            id speedController = [interactionController controllerByProtocol:speedControllerProtocol];
            AWEDPlayerSpeedController *nativeDPlayerSpeedController =
                DYYYNativeDPlayerSpeedControllerFromFastSpeedController(speedController);
            if (nativeDPlayerSpeedController) {
                if (DYYYNativeDPlayerLongPressIsActive(nativeDPlayerSpeedController)) {
                    return NO;
                }
                return DYYYApplyPlaybackRateToNativeDPlayer(nativeDPlayerSpeedController, speed);
            }
            if ([speedController respondsToSelector:@selector(playVideoViewController)] &&
                DYYYSetPlaybackRateOnTarget([(AWEPlayInteractionSpeedController *)speedController playVideoViewController], speed)) {
                return YES;
            }
            if ([speedController respondsToSelector:@selector(changeSpeed:)] &&
                !DYYYAnyNativeDPlayerLongPressIsActive()) {
                [(AWEPlayInteractionSpeedController *)speedController changeSpeed:speed];
                return YES;
            }
        } @catch (NSException *exception) {
            NSLog(@"[DYYY][Speed] apply through speedController failed: %@", exception.reason);
        }
    }
    if ([interactionController respondsToSelector:@selector(videoDelegate)] &&
        DYYYSetPlaybackRateOnTarget([interactionController videoDelegate], speed)) {
        return YES;
    }
    return DYYYSetPlaybackRateOnTarget(DYYYBestVisiblePlaybackRateTarget(nil), speed);
}

static void DYYYApplyNormalPlaybackSpeedToNativeDPlayer(AWEDPlayerSpeedController *speedController) {
    if (!DYYYShouldHandleSpeedFeatures() || !speedController) {
        return;
    }

    void (^applyBlock)(void) = ^{
      DYYYApplyPlaybackRateToNativeDPlayer(speedController, DYYYNormalPlaybackSpeed());
    };
    if ([NSThread isMainThread]) {
        applyBlock();
    } else {
        __weak AWEDPlayerSpeedController *weakSpeedController = speedController;
        dispatch_async(dispatch_get_main_queue(), ^{
          DYYYApplyPlaybackRateToNativeDPlayer(weakSpeedController, DYYYNormalPlaybackSpeed());
        });
    }
}

static BOOL DYYYHandleNormalPlaybackSpeedWithMatchingNativeController(AWEDPlayerSpeedController *speedController,
                                                                      id playerViewController) {
    if (!DYYYIsVerifiedNativeDPlayerSpeedController(speedController) || !playerViewController) {
        return NO;
    }

    id nativePlayerViewController = nil;
    @try {
        nativePlayerViewController = [speedController playerViewController];
    } @catch (__unused NSException *exception) {
    }
    if (nativePlayerViewController != playerViewController) {
        return NO;
    }

    DYYYApplyPlaybackRateToNativeDPlayer(speedController, DYYYNormalPlaybackSpeed());
    return YES;
}

static void DYYYApplyNormalPlaybackSpeedToPlayerFallback(id playerViewController) {
    if (!DYYYShouldHandleSpeedFeatures() || !playerViewController) {
        return;
    }

    void (^applyBlock)(void) = ^{
      AWEPlayInteractionViewController *visibleInteractionController =
          DYYYResolvePlaybackInteractionController(dyyyActivePlaybackInteractionController,
                                                   dyyyCurrentSpeedAweme,
                                                   YES);
      AWEDPlayerSpeedController *visibleNativeSpeedController =
          DYYYNativeDPlayerSpeedControllerFromInteractionController(visibleInteractionController);
      if (DYYYHandleNormalPlaybackSpeedWithMatchingNativeController(visibleNativeSpeedController,
                                                                    playerViewController) ||
          DYYYHandleNormalPlaybackSpeedWithMatchingNativeController(dyyyActiveDPlayerSpeedController,
                                                                    playerViewController)) {
          return;
      }
      if (DYYYAnyNativeDPlayerLongPressIsActive()) {
          return;
      }
      DYYYSetPlaybackRateOnTarget(playerViewController, DYYYNormalPlaybackSpeed());
    };

    if ([NSThread isMainThread]) {
        applyBlock();
    } else {
        __weak id weakPlayerViewController = playerViewController;
        dispatch_async(dispatch_get_main_queue(), ^{
          id strongPlayerViewController = weakPlayerViewController;
          if (strongPlayerViewController) {
              DYYYApplyNormalPlaybackSpeedToPlayerFallback(strongPlayerViewController);
          }
        });
    }
}

static NSObject *DYYYCommentPauseViewModelRegistryLock(void) {
    static NSObject *lock = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      lock = [NSObject new];
    });
    return lock;
}

static void DYYYRegisterCommentPauseViewModel(_TtC33AWECommentPanelContainerSwiftImpl30CommentContainerInnerViewModel *viewModel) {
    if (!viewModel) {
        return;
    }

    @synchronized(DYYYCommentPauseViewModelRegistryLock()) {
        if (!dyyyCommentPauseViewModels) {
            dyyyCommentPauseViewModels = [NSHashTable weakObjectsHashTable];
        }
        [dyyyCommentPauseViewModels addObject:viewModel];
    }
}

static NSArray<_TtC33AWECommentPanelContainerSwiftImpl30CommentContainerInnerViewModel *> *DYYYRegisteredCommentPauseViewModels(void) {
    @synchronized(DYYYCommentPauseViewModelRegistryLock()) {
        return dyyyCommentPauseViewModels.allObjects ?: @[];
    }
}

static BOOL DYYYCommentViewModelIsPlaying(_TtC33AWECommentPanelContainerSwiftImpl30CommentContainerInnerViewModel *viewModel) {
    if (!viewModel || ![viewModel respondsToSelector:@selector(isFeedVideoPlaying)]) {
        return NO;
    }

    @try {
        return [viewModel isFeedVideoPlaying];
    } @catch (NSException *exception) {
        return NO;
    }
}

static CGFloat DYYYCommentViewModelScore(_TtC33AWECommentPanelContainerSwiftImpl30CommentContainerInnerViewModel *viewModel) {
    CGFloat score = 0.0;
    id playerController = nil;
    @try {
        if ([viewModel respondsToSelector:@selector(feedVideoPlayerController)]) {
            playerController = [viewModel feedVideoPlayerController];
        }
    } @catch (NSException *exception) {
        return score;
    }

    AWEAwemeModel *viewModelAweme = DYYYSpeedAwemeFromObject(playerController);
    if (DYYYAwemeModelsMatch(viewModelAweme, dyyyCurrentSpeedAweme)) {
        score += 1000000000000.0;
    }
    if ([playerController isKindOfClass:[UIViewController class]]) {
        CGFloat visibilityScore = DYYYViewControllerVisibilityScore((UIViewController *)playerController);
        if (visibilityScore >= 0.0) {
            score += visibilityScore;
        }
    }
    return score;
}

static _TtC33AWECommentPanelContainerSwiftImpl30CommentContainerInnerViewModel *DYYYCurrentPlayingCommentViewModel(void) {
    _TtC33AWECommentPanelContainerSwiftImpl30CommentContainerInnerViewModel *bestViewModel = nil;
    CGFloat bestScore = -CGFLOAT_MAX;
    for (_TtC33AWECommentPanelContainerSwiftImpl30CommentContainerInnerViewModel *viewModel in DYYYRegisteredCommentPauseViewModels()) {
        if (!DYYYCommentViewModelIsPlaying(viewModel)) {
            continue;
        }

        CGFloat score = DYYYCommentViewModelScore(viewModel);
        if (viewModel == dyyyLastCommentPauseViewModel) {
            score += 1.0;
        }
        if (!bestViewModel || score > bestScore) {
            bestViewModel = viewModel;
            bestScore = score;
        }
    }
    return bestViewModel;
}

static void DYYYCommentPausePlaybackIfNeeded(void) {
    if (!dyyyCommentViewVisible || !DYYYGetBool(@"DYYYCommentPausePlayback")) {
        return;
    }

    _TtC33AWECommentPanelContainerSwiftImpl30CommentContainerInnerViewModel *viewModel = DYYYCurrentPlayingCommentViewModel();
    if (!viewModel || ![viewModel respondsToSelector:@selector(pauseVideoIfPlayingWithoutShowingPauseIcon)]) {
        return;
    }

    @try {
        // This native entry owns the comment pause state used by media-preview
        // parameters. Recovery remains with the original comment lifecycle.
        [viewModel pauseVideoIfPlayingWithoutShowingPauseIcon];
        dyyyLastCommentPauseViewModel = viewModel;
    } @catch (NSException *exception) {
        NSLog(@"[DYYY][CommentPause] native pause failed on %@: %@", NSStringFromClass([viewModel class]), exception.reason);
    }
}

static BOOL DYYYCommentContainerSkipsPanelLifecycle(AWECommentContainerViewController *commentViewController) {
    if (!commentViewController || ![commentViewController respondsToSelector:@selector(state)]) {
        return NO;
    }

    @try {
        _TtC33AWECommentPanelContainerSwiftImpl31CommentViewControllerStateModel *state = [commentViewController state];
        if (!state || ![state respondsToSelector:@selector(isSkipCommentPanelLifecycle)]) {
            return NO;
        }
        return [state isSkipCommentPanelLifecycle];
    } @catch (NSException *exception) {
        return NO;
    }
}

static void DYYYCommentRecoverPlaybackIfNeeded(_TtC33AWECommentPanelContainerSwiftImpl30CommentContainerInnerViewModel *viewModel) {
    if (!viewModel || ![viewModel respondsToSelector:@selector(recoverPlayIfPauseByComment)]) {
        return;
    }

    @try {
        [viewModel recoverPlayIfPauseByComment];
    } @catch (NSException *exception) {
        NSLog(@"[DYYY][CommentPause] native recovery failed on %@: %@", NSStringFromClass([viewModel class]), exception.reason);
    }

    if (dyyyLastCommentPauseViewModel == viewModel) {
        dyyyLastCommentPauseViewModel = nil;
    }
}

static BOOL DYYYCommentPauseOwnsPlayback(void) {
    return DYYYGetBool(@"DYYYCommentPausePlayback") && dyyyLastCommentPauseViewModel != nil;
}

static void DYYYHandleCurrentAwemeChanged(id aweme) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
          DYYYHandleCurrentAwemeChanged(aweme);
        });
        return;
    }

    AWEAwemeModel *currentAweme = DYYYSpeedAwemeFromObject(aweme);
    if (currentAweme) {
        dyyyCurrentSpeedAweme = currentAweme;
    }
}

static void DYYYHandleCommittedSpeedAwemeChanged(id aweme) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
          DYYYHandleCommittedSpeedAwemeChanged(aweme);
        });
        return;
    }

    AWEAwemeModel *currentAweme = DYYYSpeedAwemeFromObject(aweme);
    if (!currentAweme) {
        return;
    }

    NSString *itemID = currentAweme.itemID;
    BOOL hasStableIdentifier = itemID.length > 0;
    BOOL isNewCommittedAweme = hasStableIdentifier
                                   ? ![dyyyCommittedSpeedAwemeIdentifier isEqualToString:itemID]
                                   : !DYYYAwemeModelsMatch(dyyyCurrentSpeedAweme, currentAweme);

    dyyyCurrentSpeedAweme = currentAweme;
    if (hasStableIdentifier) {
        dyyyCommittedSpeedAwemeIdentifier = [itemID copy];
    }

    if (isNewCommittedAweme) {
        if (isFloatSpeedButtonEnabled &&
            [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYAutoRestoreSpeed"]) {
            setCurrentSpeedIndex(0);
            updateSpeedButtonUI();
        }
    }
}

static void DYYYScheduleCurrentAwemeTracking(id source, id fallbackAweme) {
    __weak id weakSource = source;
    void (^trackingBlock)(void) = ^{
      AWEPlayInteractionViewController *visibleController = DYYYResolvePlaybackInteractionController(nil, nil, YES);
      if (!visibleController) {
          return;
      }
      AWEAwemeModel *candidateAweme = DYYYSpeedAwemeFromObject(weakSource);
      if (!DYYYAwemeModelsMatch(candidateAweme, visibleController.model)) {
          candidateAweme = DYYYSpeedAwemeFromObject(fallbackAweme);
      }
      if (DYYYAwemeModelsMatch(candidateAweme, visibleController.model)) {
          DYYYHandleCurrentAwemeChanged(candidateAweme);
      }
    };
    dispatch_async(dispatch_get_main_queue(), trackingBlock);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), trackingBlock);
}

@interface AWEFeedProgressSlider (DYYYProgressLabel)
- (NSString *)dyyy_formatTimeFromSeconds:(CGFloat)seconds;
- (CGFloat)dyyy_modelDurationInSeconds;
- (CGFloat)dyyy_scheduleVerticalOffset;
- (void)dyyy_removeScheduleLabels;
- (void)dyyy_updateScheduleLabelsWithCurrentTime:(CGFloat)currentTime totalDuration:(CGFloat)totalDuration;
@end

@interface AWEPlayInteractionProgressController (DYYYProgressLabel)
- (void)dyyy_syncScheduleLabelsWithCurrentTime:(CGFloat)currentTime totalDuration:(CGFloat)totalDuration;
@end

@interface AWEDProgressCoreContainer (DYYYProgressLabel)
- (void)dyyy_syncScheduleLabelsWithCurrentTime:(CGFloat)currentTime totalDuration:(CGFloat)totalDuration;
@end

@interface UIView (DYYYProgressLabelLegacy)
- (void)dyyy_updateScheduleLabelsLegacyWithCurrentTime:(CGFloat)currentTime totalDuration:(CGFloat)totalDuration model:(id)model;
@end

@implementation UIView (DYYYProgressLabelLegacy)

- (NSString *)dyyy_legacyFormatTimeFromSeconds:(CGFloat)seconds {
    CGFloat safeSeconds = seconds;
    if (safeSeconds < 0) {
        safeSeconds = 0;
    }

    NSInteger total = (NSInteger)floor(safeSeconds);
    NSInteger hours = total / 3600;
    NSInteger minutes = (total % 3600) / 60;
    NSInteger secs = total % 60;

    if (hours > 0) {
        return [NSString stringWithFormat:@"%02ld:%02ld:%02ld", (long)hours, (long)minutes, (long)secs];
    }
    return [NSString stringWithFormat:@"%02ld:%02ld", (long)minutes, (long)secs];
}

- (CGFloat)dyyy_legacyScheduleVerticalOffset {
    CGFloat verticalOffset = -12.5;
    NSString *offsetValueString = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYTimelineVerticalPosition"];
    if (offsetValueString.length > 0) {
        CGFloat configuredOffset = [offsetValueString floatValue];
        if (configuredOffset != 0) {
            verticalOffset = configuredOffset;
        }
    }
    return verticalOffset;
}

- (CGFloat)dyyy_legacyModelDurationInSeconds:(id)model {
    if (!model || ![model respondsToSelector:@selector(videoDuration)]) {
        return 0;
    }

    CGFloat videoDurationMs = [[model valueForKey:@"videoDuration"] doubleValue];
    if (videoDurationMs <= 0) {
        return 0;
    }
    return videoDurationMs / 1000.0;
}

- (void)dyyy_updateScheduleLabelsLegacyWithCurrentTime:(CGFloat)currentTime totalDuration:(CGFloat)totalDuration model:(id)model {
    if (!DYYYGetBool(@"DYYYShowScheduleDisplay")) {
        UIView *parentView = self.superview;
        if (parentView) {
            [[parentView viewWithTag:10001] removeFromSuperview];
            [[parentView viewWithTag:10002] removeFromSuperview];
        }
        return;
    }

    if (![NSThread isMainThread]) {
        __weak __typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
          [weakSelf dyyy_updateScheduleLabelsLegacyWithCurrentTime:currentTime totalDuration:totalDuration model:model];
        });
        return;
    }

    UIView *parentView = self.superview;
    if (!parentView) {
        return;
    }
    [parentView layoutIfNeeded];
    [self layoutIfNeeded];

    NSString *scheduleStyle = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYScheduleStyle"];
    BOOL showRightRemainingTime = [scheduleStyle isEqualToString:@"进度条右侧剩余"];
    BOOL showRightCompleteTime = [scheduleStyle isEqualToString:@"进度条右侧完整"];
    BOOL showLeftRemainingTime = [scheduleStyle isEqualToString:@"进度条左侧剩余"];
    BOOL showLeftCompleteTime = [scheduleStyle isEqualToString:@"进度条左侧完整"];

    BOOL shouldShowLeftLabel = !showRightRemainingTime && !showRightCompleteTime;
    BOOL shouldShowRightLabel = !showLeftRemainingTime && !showLeftCompleteTime;

    CGFloat modelDuration = [self dyyy_legacyModelDurationInSeconds:model];
    CGFloat effectiveTotalDuration = totalDuration > 0 ? totalDuration : modelDuration;
    if (effectiveTotalDuration < 0) {
        effectiveTotalDuration = 0;
    }

    CGFloat effectiveCurrentTime = currentTime;
    if (effectiveCurrentTime < 0) {
        effectiveCurrentTime = 0;
    }
    if (effectiveTotalDuration > 0 && effectiveCurrentTime > effectiveTotalDuration) {
        effectiveCurrentTime = effectiveTotalDuration;
    }

    CGRect sliderFrameInParent = [self convertRect:self.bounds toView:parentView];
    if (CGRectGetWidth(sliderFrameInParent) <= 1.0 || CGRectGetHeight(sliderFrameInParent) <= 1.0) {
        return;
    }
    CGFloat labelYPosition = CGRectGetMinY(sliderFrameInParent) + [self dyyy_legacyScheduleVerticalOffset];
    CGFloat labelHeight = 15.0;
    UIFont *labelFont = [UIFont systemFontOfSize:8];
    NSString *labelColorHex = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYProgressLabelColor"];

    UILabel *leftLabel = (UILabel *)[parentView viewWithTag:10001];
    if (leftLabel && ![leftLabel isKindOfClass:[UILabel class]]) {
        [leftLabel removeFromSuperview];
        leftLabel = nil;
    }

    if (shouldShowLeftLabel) {
        if (!leftLabel) {
            leftLabel = [[UILabel alloc] init];
            leftLabel.backgroundColor = [UIColor clearColor];
            leftLabel.tag = 10001;
            [parentView addSubview:leftLabel];
        }
        leftLabel.font = labelFont;

        NSString *newLeftText = nil;
        if (showLeftRemainingTime) {
            newLeftText = [self dyyy_legacyFormatTimeFromSeconds:MAX(effectiveTotalDuration - effectiveCurrentTime, 0)];
        } else if (showLeftCompleteTime) {
            newLeftText = [NSString stringWithFormat:@"%@/%@", [self dyyy_legacyFormatTimeFromSeconds:effectiveCurrentTime], [self dyyy_legacyFormatTimeFromSeconds:effectiveTotalDuration]];
        } else {
            newLeftText = [self dyyy_legacyFormatTimeFromSeconds:effectiveCurrentTime];
        }

        if (![leftLabel.text isEqualToString:newLeftText]) {
            leftLabel.text = newLeftText;
        }
        [leftLabel sizeToFit];
        leftLabel.frame = CGRectMake(CGRectGetMinX(sliderFrameInParent), labelYPosition, CGRectGetWidth(leftLabel.bounds), labelHeight);
        [DYYYUtils applyColorSettingsToLabel:leftLabel colorHexString:labelColorHex];
    } else {
        [leftLabel removeFromSuperview];
    }

    UILabel *rightLabel = (UILabel *)[parentView viewWithTag:10002];
    if (rightLabel && ![rightLabel isKindOfClass:[UILabel class]]) {
        [rightLabel removeFromSuperview];
        rightLabel = nil;
    }

    if (shouldShowRightLabel) {
        if (!rightLabel) {
            rightLabel = [[UILabel alloc] init];
            rightLabel.backgroundColor = [UIColor clearColor];
            rightLabel.tag = 10002;
            [parentView addSubview:rightLabel];
        }
        rightLabel.font = labelFont;

        NSString *newRightText = nil;
        if (showRightRemainingTime) {
            newRightText = [self dyyy_legacyFormatTimeFromSeconds:MAX(effectiveTotalDuration - effectiveCurrentTime, 0)];
        } else if (showRightCompleteTime) {
            newRightText = [NSString stringWithFormat:@"%@/%@", [self dyyy_legacyFormatTimeFromSeconds:effectiveCurrentTime], [self dyyy_legacyFormatTimeFromSeconds:effectiveTotalDuration]];
        } else {
            newRightText = [self dyyy_legacyFormatTimeFromSeconds:effectiveTotalDuration];
        }

        if (![rightLabel.text isEqualToString:newRightText]) {
            rightLabel.text = newRightText;
        }
        [rightLabel sizeToFit];
        CGFloat rightLabelX = MAX(CGRectGetMaxX(sliderFrameInParent) - CGRectGetWidth(rightLabel.bounds), CGRectGetMinX(sliderFrameInParent));
        rightLabel.frame = CGRectMake(rightLabelX, labelYPosition, CGRectGetWidth(rightLabel.bounds), labelHeight);
        [DYYYUtils applyColorSettingsToLabel:rightLabel colorHexString:labelColorHex];
    } else {
        [rightLabel removeFromSuperview];
    }
}

@end

// 关闭不可见水印
%hook AWEHPChannelInvisibleWaterMarkModel

- (BOOL)isEnter {
    return NO;
}

- (BOOL)isAppear {
    return NO;
}

%end

// 长按复制个人简介
%hook AWEProfileMentionLabel

- (void)layoutSubviews {
    %orig;

    if (!DYYYGetBool(@"DYYYBioCopyText")) {
        return;
    }

    BOOL hasLongPressGesture = NO;
    for (UIGestureRecognizer *gesture in self.gestureRecognizers) {
        if ([gesture isKindOfClass:[UILongPressGestureRecognizer class]]) {
            hasLongPressGesture = YES;
            break;
        }
    }

    if (!hasLongPressGesture) {
        UILongPressGestureRecognizer *longPressGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
        longPressGesture.minimumPressDuration = 0.5;
        [self addGestureRecognizer:longPressGesture];
        self.userInteractionEnabled = YES;
    }
}

%new
- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        NSString *bioText = self.text;
        if (bioText && bioText.length > 0) {
            [[UIPasteboard generalPasteboard] setString:bioText];
            [DYYYToast showSuccessToastWithMessage:@"个人简介已复制"];
        }
    }
}

%end

// 抖音 39.1.0 访问他人主页时会由详情组件直接上传访客记录
%hook AWEProfileUserDetailComponent

- (void)reportUserDetailVisitIfNeeded:(id)user {
    if ([DYYYPrivacyRecordUploadGuard isProfileVisitRecordUploadDisabled]) {
        return;
    }

    %orig;
}

%end

// 兼容旧版访客记录上传路径
%hook AWEProfileRecordHelper

+ (void)postProfileRecordWithParams:(id)params {
    if ([DYYYPrivacyRecordUploadGuard isProfileVisitRecordUploadDisabled]) {
        return;
    }

    %orig;
}

+ (void)postProfileRecordWithParams:(id)params completionBlock:(id)completionBlock {
    if ([DYYYPrivacyRecordUploadGuard isProfileVisitRecordUploadDisabled]) {
        return;
    }

    %orig;
}

+ (void)postProfileRecordWithKey:(id)key valueDic:(id)valueDic {
    if ([DYYYPrivacyRecordUploadGuard isProfileVisitRecordUploadDisabled]) {
        return;
    }

    %orig;
}

+ (void)postProfileRecordWithKey:(id)key valueDic:(id)valueDic completionBlock:(id)completionBlock {
    if ([DYYYPrivacyRecordUploadGuard isProfileVisitRecordUploadDisabled]) {
        return;
    }

    %orig;
}

%end

// 抖音 39.7.0：作品浏览记录由 AFDPlayerAndInteractionService 上报至
// /aweme/v1/familiar/video/stats/（scene 常见值 FeedVideoViewedDedicatedStats）
%hook AFDPlayerAndInteractionService

- (void)statisticsVideoViewedWithID:(NSString *)itemID scene:(NSString *)scene {
    if ([DYYYPrivacyRecordUploadGuard isAwemeViewRecordUploadDisabled]) {
        return;
    }

    %orig;
}

- (void)statisticsVideoViewedWithID:(NSString *)itemID
                           authorID:(NSString *)authorID
                       followStatus:(long long)followStatus
                     followerStatus:(long long)followerStatus
                            isStory:(BOOL)isStory
                  isRequestDirectly:(BOOL)isRequestDirectly
                              scene:(NSString *)scene {
    if ([DYYYPrivacyRecordUploadGuard isAwemeViewRecordUploadDisabled]) {
        return;
    }

    %orig;
}

%end

static BOOL DYYYTryBlockPrivacyNetworkRequest(NSString *URLString, id completion) {
    if (![DYYYPrivacyRecordUploadGuard shouldBlockURLString:URLString]) {
        return NO;
    }

    [DYYYPrivacyRecordUploadGuard invokeCancelledCompletionIfPossible:completion];
    return YES;
}

%hook AWENetworkService

+ (id)postWithURLString:(NSString *)URLString params:(id)params completion:(id)completion {
    if (DYYYTryBlockPrivacyNetworkRequest(URLString, completion)) {
        return nil;
    }
    return %orig;
}

+ (id)getWithURLString:(NSString *)URLString params:(id)params completion:(id)completion {
    if (DYYYTryBlockPrivacyNetworkRequest(URLString, completion)) {
        return nil;
    }
    return %orig;
}

+ (id)requestWithURLString:(NSString *)URLString params:(id)params method:(id)method completion:(id)completion {
    if (DYYYTryBlockPrivacyNetworkRequest(URLString, completion)) {
        return nil;
    }
    return %orig;
}

+ (id)postWithURLString:(NSString *)URLString params:(id)params headerField:(id)headerField completion:(id)completion {
    if (DYYYTryBlockPrivacyNetworkRequest(URLString, completion)) {
        return nil;
    }
    return %orig;
}

+ (id)getWithURLString:(NSString *)URLString params:(id)params headerField:(id)headerField completion:(id)completion {
    if (DYYYTryBlockPrivacyNetworkRequest(URLString, completion)) {
        return nil;
    }
    return %orig;
}

%end

%hook TTNetworkManager

- (id)requestForJSONWithURL:(NSString *)url
                     params:(id)params
                     method:(NSString *)method
           needCommonParams:(BOOL)needCommonParams
                headerField:(id)headerField
          requestSerializer:(Class)requestSerializerClass
         responseSerializer:(Class)responseSerializerClass
                 autoResume:(BOOL)autoResume
                   callback:(id)callback {
    if (DYYYTryBlockPrivacyNetworkRequest(url, callback)) {
        return nil;
    }
    return %orig;
}

- (id)requestForJSONWithResponse:(NSString *)url
                          params:(id)params
                          method:(NSString *)method
                needCommonParams:(BOOL)needCommonParams
                     headerField:(id)headerField
               requestSerializer:(Class)requestSerializerClass
              responseSerializer:(Class)responseSerializerClass
                      autoResume:(BOOL)autoResume
                        callback:(id)callback {
    if (DYYYTryBlockPrivacyNetworkRequest(url, callback)) {
        return nil;
    }
    return %orig;
}

- (id)requestForBinaryWithResponse:(NSString *)url
                            params:(id)params
                            method:(NSString *)method
                  needCommonParams:(BOOL)needCommonParams
                       headerField:(id)headerField
                          callback:(id)callback {
    if (DYYYTryBlockPrivacyNetworkRequest(url, callback)) {
        return nil;
    }
    return %orig;
}

%end

static BOOL DYYYShouldSkipPrivacyRecordTaskStart(id task) {
    BOOL shouldBlock = [DYYYPrivacyRecordUploadGuard isTaskMarkedForBlocking:task] ||
                       [DYYYPrivacyRecordUploadGuard shouldBlockRequestObject:task];
    if (!shouldBlock) {
        return NO;
    }

    // 即使任务对象不支持 cancel，也必须阻止原始启动，避免隐私请求继续发出。
    (void)[DYYYPrivacyRecordUploadGuard cancelTaskIfPossible:task];
    return YES;
}

%hook TTHttpTask

- (void)resume {
    if (DYYYShouldSkipPrivacyRecordTaskStart(self)) {
        return;
    }

    %orig;
}

%end

%hook TTHttpTaskChromium

- (void)runRequestFiltersAndStart {
    if (DYYYShouldSkipPrivacyRecordTaskStart(self)) {
        return;
    }

    %orig;
}

- (void)resume {
    if (DYYYShouldSkipPrivacyRecordTaskStart(self)) {
        return;
    }

    %orig;
}

%end

%hook TTConcurrentHttpTask

- (void)resume {
    if (DYYYShouldSkipPrivacyRecordTaskStart(self)) {
        return;
    }

    %orig;
}

%end

%hook NSURLSessionTask

- (void)resume {
    if (DYYYShouldSkipPrivacyRecordTaskStart(self)) {
        return;
    }

    %orig;
}

%end

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url {
    NSURLSessionDataTask *task = %orig;
    [DYYYPrivacyRecordUploadGuard markTaskForBlockingIfNeeded:task requestObject:url];
    return task;
}

- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    NSURLSessionDataTask *task = %orig;
    [DYYYPrivacyRecordUploadGuard markTaskForBlockingIfNeeded:task requestObject:url];
    return task;
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    NSURLSessionDataTask *task = %orig;
    [DYYYPrivacyRecordUploadGuard markTaskForBlockingIfNeeded:task requestObject:request];
    return task;
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    NSURLSessionDataTask *task = %orig;
    [DYYYPrivacyRecordUploadGuard markTaskForBlockingIfNeeded:task requestObject:request];
    return task;
}

- (NSURLSessionDownloadTask *)downloadTaskWithURL:(NSURL *)url {
    NSURLSessionDownloadTask *task = %orig;
    [DYYYPrivacyRecordUploadGuard markTaskForBlockingIfNeeded:task requestObject:url];
    return task;
}

- (NSURLSessionDownloadTask *)downloadTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSURL *location, NSURLResponse *response, NSError *error))completionHandler {
    NSURLSessionDownloadTask *task = %orig;
    [DYYYPrivacyRecordUploadGuard markTaskForBlockingIfNeeded:task requestObject:url];
    return task;
}

- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request {
    NSURLSessionDownloadTask *task = %orig;
    [DYYYPrivacyRecordUploadGuard markTaskForBlockingIfNeeded:task requestObject:request];
    return task;
}

- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURL *location, NSURLResponse *response, NSError *error))completionHandler {
    NSURLSessionDownloadTask *task = %orig;
    [DYYYPrivacyRecordUploadGuard markTaskForBlockingIfNeeded:task requestObject:request];
    return task;
}

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData {
    NSURLSessionUploadTask *task = %orig;
    [DYYYPrivacyRecordUploadGuard markTaskForBlockingIfNeeded:task requestObject:request];
    return task;
}

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    NSURLSessionUploadTask *task = %orig;
    [DYYYPrivacyRecordUploadGuard markTaskForBlockingIfNeeded:task requestObject:request];
    return task;
}

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromFile:(NSURL *)fileURL {
    NSURLSessionUploadTask *task = %orig;
    [DYYYPrivacyRecordUploadGuard markTaskForBlockingIfNeeded:task requestObject:request];
    return task;
}

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromFile:(NSURL *)fileURL completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    NSURLSessionUploadTask *task = %orig;
    [DYYYPrivacyRecordUploadGuard markTaskForBlockingIfNeeded:task requestObject:request];
    return task;
}

- (NSURLSessionUploadTask *)uploadTaskWithStreamedRequest:(NSURLRequest *)request {
    NSURLSessionUploadTask *task = %orig;
    [DYYYPrivacyRecordUploadGuard markTaskForBlockingIfNeeded:task requestObject:request];
    return task;
}

%end

@interface AWENowPlayingInfoCenter : NSObject
@property(nonatomic, weak) id playingPlayer;
@end

@interface MPNowPlayingInfoCenter : NSObject
@property(nonatomic, copy) NSDictionary *nowPlayingInfo;
+ (instancetype)defaultCenter;
@end

static BOOL dyyyClearingFeedNowPlayingSystemInfo = NO;
static CFTimeInterval dyyyLastFeedNowPlayingSystemClearTime = 0.0;

static void DYYYClearFeedNowPlayingSystemInfo(BOOL ignoreThrottle) {
    if (dyyyClearingFeedNowPlayingSystemInfo) {
        return;
    }

    CFTimeInterval currentTime = CFAbsoluteTimeGetCurrent();
    if (!ignoreThrottle && currentTime - dyyyLastFeedNowPlayingSystemClearTime < 0.25) {
        return;
    }
    dyyyLastFeedNowPlayingSystemClearTime = currentTime;

    Class nowPlayingInfoCenterClass = NSClassFromString(@"MPNowPlayingInfoCenter");
    if (!nowPlayingInfoCenterClass || ![nowPlayingInfoCenterClass respondsToSelector:@selector(defaultCenter)]) {
        return;
    }

    id center = ((id (*)(Class, SEL))objc_msgSend)(nowPlayingInfoCenterClass, @selector(defaultCenter));
    if (!center) {
        return;
    }

    dyyyClearingFeedNowPlayingSystemInfo = YES;
    @try {
        if ([center respondsToSelector:@selector(setNowPlayingInfo:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(center, @selector(setNowPlayingInfo:), nil);
        }

        SEL setPlaybackStateSelector = NSSelectorFromString(@"setPlaybackState:");
        if ([center respondsToSelector:setPlaybackStateSelector]) {
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(center, setPlaybackStateSelector, 0);
        }
    } @catch (__unused NSException *exception) {
    } @finally {
        dyyyClearingFeedNowPlayingSystemInfo = NO;
    }
}

static void DYYYClearFeedNowPlayingSystemInfoThrottled(void) {
    if (!DYYYGetBool(DYYY_DISABLE_FEED_NOW_PLAYING_INFO_KEY)) {
        return;
    }

    DYYYClearFeedNowPlayingSystemInfo(NO);
}

static id DYYYSharedInstanceForClass(Class cls) {
    if (!cls) {
        return nil;
    }

    for (NSString *selectorName in @[ @"sharedManager", @"sharedInstance", @"defaultCenter", @"shared", @"defaultManager" ]) {
        SEL selector = NSSelectorFromString(selectorName);
        if ([cls respondsToSelector:selector]) {
            id instance = ((id (*)(Class, SEL))objc_msgSend)(cls, selector);
            if (instance) {
                return instance;
            }
        }
    }

    return nil;
}

static void DYYYRefreshFeedNowPlayingInfoFromDouyin(void) {
    for (NSString *className in @[ @"AWEFeedBackgroundPlayManager", @"AWENowPlayingInfoCenter", @"AWEAwemeBackgroundPlayModule" ]) {
        id instance = DYYYSharedInstanceForClass(NSClassFromString(className));
        if (!instance) {
            continue;
        }

        SEL forceRefreshSelector = @selector(refreshNowPlayingInfoIsForce:);
        if ([instance respondsToSelector:forceRefreshSelector]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(instance, forceRefreshSelector, YES);
        }

        SEL refreshSelector = @selector(refreshNowPlayingInfo);
        if ([instance respondsToSelector:refreshSelector]) {
            ((void (*)(id, SEL))objc_msgSend)(instance, refreshSelector);
        }

        SEL refreshIfNeededSelector = @selector(refreshNowPlayingInfoIfNeeded);
        if ([instance respondsToSelector:refreshIfNeededSelector]) {
            ((void (*)(id, SEL))objc_msgSend)(instance, refreshIfNeededSelector);
        }

        SEL updatePlaybackSelector = @selector(updateNowPlayingInfoPlayback);
        if ([instance respondsToSelector:updatePlaybackSelector]) {
            ((void (*)(id, SEL))objc_msgSend)(instance, updatePlaybackSelector);
        }
    }
}

void DYYYApplyFeedNowPlayingSettingChange(BOOL disableNowPlayingInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (disableNowPlayingInfo) {
            DYYYClearFeedNowPlayingSystemInfo(YES);
            return;
        }

        DYYYRefreshFeedNowPlayingInfoFromDouyin();
    });
}

static BOOL DYYYShouldBlockFeedNowPlayingSystemInfoWrite(void) {
    return DYYYGetBool(DYYY_DISABLE_FEED_NOW_PLAYING_INFO_KEY) && !dyyyClearingFeedNowPlayingSystemInfo;
}

%hook AWEAwemeBackgroundPlayModule

- (id)nowPlayingInfo {
    if (DYYYGetBool(@"DYYYDisableFeedNowPlayingInfo")) {
        DYYYClearFeedNowPlayingSystemInfoThrottled();
        return nil;
    }

    return %orig;
}

- (void)refreshNowPlayingInfoIfNeeded {
    if (DYYYGetBool(@"DYYYDisableFeedNowPlayingInfo")) {
        DYYYClearFeedNowPlayingSystemInfoThrottled();
        return;
    }

    %orig;
}

- (void)updateNowPlayingInfoPlayback {
    if (DYYYGetBool(@"DYYYDisableFeedNowPlayingInfo")) {
        DYYYClearFeedNowPlayingSystemInfoThrottled();
        return;
    }

    %orig;
}

%end

%hook AWEFeedBackgroundPlayManager

- (id)nowPlayingInfo {
    if (DYYYGetBool(@"DYYYDisableFeedNowPlayingInfo")) {
        DYYYClearFeedNowPlayingSystemInfoThrottled();
        return nil;
    }

    return %orig;
}

- (void)setNowPlayingInfo:(id)nowPlayingInfo {
    if (DYYYGetBool(@"DYYYDisableFeedNowPlayingInfo")) {
        DYYYClearFeedNowPlayingSystemInfoThrottled();
        return;
    }

    %orig;
}

- (void)resetNowPlayingInfo:(id)model {
    if (DYYYGetBool(@"DYYYDisableFeedNowPlayingInfo")) {
        DYYYClearFeedNowPlayingSystemInfoThrottled();
        return;
    }

    %orig;
}

- (void)refreshNowPlayingInfo {
    if (DYYYGetBool(@"DYYYDisableFeedNowPlayingInfo")) {
        DYYYClearFeedNowPlayingSystemInfoThrottled();
        return;
    }

    %orig;
}

- (void)refreshNowPlayingInfoIsForce:(BOOL)isForce {
    if (DYYYGetBool(@"DYYYDisableFeedNowPlayingInfo")) {
        DYYYClearFeedNowPlayingSystemInfoThrottled();
        return;
    }

    %orig;
}

- (void)updateNowPlayingInfoPlayback {
    if (DYYYGetBool(@"DYYYDisableFeedNowPlayingInfo")) {
        DYYYClearFeedNowPlayingSystemInfoThrottled();
        return;
    }

    %orig;
}

%end

// 写入播放中心时清空系统 Now Playing，不再走宿主写入路径。
%hook AWENowPlayingInfoCenter

- (void)becomePlayingPlayer:(id)player {
    if (DYYYGetBool(@"DYYYDisableFeedNowPlayingInfo")) {
        DYYYClearFeedNowPlayingSystemInfoThrottled();
        return;
    }

    %orig;
}

- (void)setNowPlayingInfo:(id)nowPlayingInfo {
    if (DYYYGetBool(@"DYYYDisableFeedNowPlayingInfo")) {
        DYYYClearFeedNowPlayingSystemInfoThrottled();
        return;
    }

    %orig;
}

- (void)refreshNowPlayingInfo {
    if (DYYYGetBool(@"DYYYDisableFeedNowPlayingInfo")) {
        DYYYClearFeedNowPlayingSystemInfoThrottled();
        return;
    }

    %orig;
}

%end

// 耳机或系统媒体会话可能绕过抖音播放中心，最终都要写入 MPNowPlayingInfoCenter。
%hook MPNowPlayingInfoCenter

- (void)setNowPlayingInfo:(NSDictionary *)nowPlayingInfo {
    if (DYYYShouldBlockFeedNowPlayingSystemInfoWrite()) {
        %orig(nil);
        return;
    }

    %orig;
}

- (void)setPlaybackState:(NSInteger)playbackState {
    if (DYYYShouldBlockFeedNowPlayingSystemInfoWrite()) {
        %orig(0);
        return;
    }

    %orig;
}

%end

static BOOL DYYYShouldDisableAllHDR(void);
static NSArray *DYYYFilteredSDRBitrateModels(NSArray *models);
static NSArray *DYYYFilteredSDRRawBitrateData(NSArray *rawData);
static void DYYYStripHDRHintsFromBitrateModels(NSArray *models);

// 读取单个码率档位的比特率；档位类型不符或字段缺失时返回 -1，排序时会被沉到末尾。
static NSInteger DYYYBitrateForBitrateModel(id model) {
    Class bitrateModelClass = %c(AWEVideoBSModel);
    if (!bitrateModelClass || ![model isKindOfClass:bitrateModelClass]) {
        return -1;
    }

    id bitrateValue = [model bitrate];
    return bitrateValue ? [bitrateValue integerValue] : -1;
}

// 默认视频流最高画质
%hook AWEVideoModel

- (AWEURLModel *)playURL {
    if (!DYYYGetBoolCached(@"DYYYEnableVideoHighestQuality")) {
        return %orig;
    }

    // 获取比特率模型数组
    NSArray *bitrateModels = [self bitrateModels];
    if (!bitrateModels || bitrateModels.count == 0) {
        return %orig;
    }

    // 查找比特率最高的模型
    id highestBitrateModel = nil;
    NSInteger highestBitrate = 0;

    for (id model in bitrateModels) {
        NSInteger bitrate = DYYYBitrateForBitrateModel(model);
        if (bitrate >= 0 && bitrate > highestBitrate) {
            highestBitrate = bitrate;
            highestBitrateModel = model;
        }
    }

    // 如果找到了最高比特率模型，获取其播放地址
    if (highestBitrateModel) {
        id playAddr = [highestBitrateModel valueForKey:@"playAddr"];
        if (playAddr && [playAddr isKindOfClass:%c(AWEURLModel)]) {
            return playAddr;
        }
    }

    return %orig;
}

- (NSArray *)bitrateModels {
    NSArray *originalModels = %orig;

    if (DYYYShouldDisableAllHDR()) {
        NSArray *filteredModels = DYYYFilteredSDRBitrateModels(originalModels);
        DYYYStripHDRHintsFromBitrateModels(filteredModels);
        originalModels = filteredModels;
    }

    if (!DYYYGetBoolCached(@"DYYYEnableVideoHighestQuality")) {
        return originalModels;
    }

    if (originalModels.count < 2) {
        return originalModels;
    }

    // 按比特率降序排列，最高画质档位置于首位。
    // 这里刻意保留完整档位表而不裁剪成单档：只留最高码率会让播放器在带宽下滑时无档可退，
    // 只能停在原地反复重缓冲，表现为播放中途卡住。保留低码率档后仍可自适应降级。
    return [originalModels sortedArrayWithOptions:NSSortStable
                                  usingComparator:^NSComparisonResult(id lhs, id rhs) {
                                    NSInteger leftBitrate = DYYYBitrateForBitrateModel(lhs);
                                    NSInteger rightBitrate = DYYYBitrateForBitrateModel(rhs);
                                    if (leftBitrate == rightBitrate) {
                                        return NSOrderedSame;
                                    }
                                    return leftBitrate > rightBitrate ? NSOrderedAscending : NSOrderedDescending;
                                  }];
}

- (void)setBitrateModels:(NSArray *)bitrateModels {
    if (DYYYShouldDisableAllHDR()) {
        NSArray *filteredModels = DYYYFilteredSDRBitrateModels(bitrateModels);
        DYYYStripHDRHintsFromBitrateModels(filteredModels);
        %orig(filteredModels);
        return;
    }
    %orig;
}

- (void)setManualBitrateModels:(NSArray *)manualBitrateModels {
    if (DYYYShouldDisableAllHDR()) {
        NSArray *filteredModels = DYYYFilteredSDRBitrateModels(manualBitrateModels);
        DYYYStripHDRHintsFromBitrateModels(filteredModels);
        %orig(filteredModels);
        return;
    }
    %orig;
}

- (NSArray *)manualBitrateModels {
    NSArray *models = %orig;
    if (DYYYShouldDisableAllHDR()) {
        models = DYYYFilteredSDRBitrateModels(models);
        DYYYStripHDRHintsFromBitrateModels(models);
    }
    return models;
}

- (void)setBitrateRawData:(NSArray *)bitrateRawData {
    if (DYYYShouldDisableAllHDR()) {
        %orig(DYYYFilteredSDRRawBitrateData(bitrateRawData));
        return;
    }
    %orig;
}

- (NSArray *)bitrateRawData {
    NSArray *rawData = %orig;
    if (DYYYShouldDisableAllHDR()) {
        rawData = DYYYFilteredSDRRawBitrateData(rawData);
    }
    return rawData;
}

- (void)setHasFilterHDR:(BOOL)hasFilterHDR {
    %orig(DYYYShouldDisableAllHDR() ? NO : hasFilterHDR);
}

- (BOOL)hasFilterHDR {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (void)setIsSourceHDR:(NSInteger)isSourceHDR {
    %orig(DYYYShouldDisableAllHDR() ? 0 : isSourceHDR);
}

- (NSInteger)isSourceHDR {
    if (DYYYShouldDisableAllHDR()) {
        return 0;
    }
    return %orig;
}

%end

static NSString *const kDYYYHDRModeKey = @"DYYYHDRMode";
static NSString *const kDYYYHDRModeOff = @"关闭";
static NSString *const kDYYYHDRModeDisable = @"全局屏蔽HDR效果";
static NSString *const kDYYYHDRModeFilter = @"全局过滤HDR作品";
static char kDYYYHDRStrippedAwemeModelKey;
static char kDYYYHDRStrippedVideoModelKey;
static char kDYYYHDROnlyAwemeModelKey;
static char kDYYYHDROnlyVideoModelKey;

static void DYYYMigrateCombinedHDRModeIfNeeded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        if ([defaults boolForKey:@"DYYYHDRModeMigratedV1"]) {
            return;
        }

        NSString *mode = [defaults stringForKey:kDYYYHDRModeKey];
        BOOL hasValidMode = [mode isEqualToString:kDYYYHDRModeOff] ||
                            [mode isEqualToString:kDYYYHDRModeDisable] ||
                            [mode isEqualToString:kDYYYHDRModeFilter];
        if (!hasValidMode) {
            if ([defaults boolForKey:@"DYYYDisableAllHDR"]) {
                mode = kDYYYHDRModeDisable;
            } else if ([defaults boolForKey:@"DYYYFilterFeedHDR"]) {
                mode = kDYYYHDRModeFilter;
            } else {
                mode = kDYYYHDRModeOff;
            }
        }

        [defaults setObject:mode forKey:kDYYYHDRModeKey];
        [defaults removeObjectForKey:@"DYYYDisableAllHDR"];
        [defaults removeObjectForKey:@"DYYYFilterFeedHDR"];
        [defaults setBool:YES forKey:@"DYYYHDRModeMigratedV1"];
    });
}

static NSString *DYYYUserDefaultsStringValue(id value) {
    if ([value isKindOfClass:[NSString class]]) {
        return (NSString *)value;
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)value stringValue];
    }
    return nil;
}

static NSString *DYYYMigratedVerticalOffsetString(id value) {
    NSString *stringValue = DYYYUserDefaultsStringValue(value);
    if (stringValue.length == 0) {
        return stringValue;
    }

    CGFloat offset = [stringValue floatValue];
    if (offset == 0.0f) {
        return stringValue;
    }

    return [NSString stringWithFormat:@"%g", -offset];
}

static void DYYYMigrateScaleAndSizeSettingsIfNeeded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        if ([defaults boolForKey:@"DYYYScaleAndSizeSettingsMigratedV1"]) {
            return;
        }

        NSString *nicknameScale = DYYYUserDefaultsStringValue([defaults objectForKey:@"DYYYNicknameScale"]);
        if (nicknameScale.length > 0 && [defaults objectForKey:@"DYYYDescriptionScale"] == nil) {
            [defaults setObject:nicknameScale forKey:@"DYYYDescriptionScale"];
        }

        id nicknameOffsetValue = [defaults objectForKey:@"DYYYNicknameVerticalOffset"];
        if (nicknameOffsetValue != nil) {
            NSString *migratedNicknameOffset = DYYYMigratedVerticalOffsetString(nicknameOffsetValue);
            if (migratedNicknameOffset.length > 0) {
                [defaults setObject:migratedNicknameOffset forKey:@"DYYYNicknameVerticalOffset"];
            }
        }

        id descriptionOffsetValue = [defaults objectForKey:@"DYYYDescriptionVerticalOffset"];
        if (descriptionOffsetValue != nil) {
            NSString *migratedDescriptionOffset = DYYYMigratedVerticalOffsetString(descriptionOffsetValue);
            if (migratedDescriptionOffset.length > 0) {
                [defaults setObject:migratedDescriptionOffset forKey:@"DYYYDescriptionVerticalOffset"];
            }
        }

        [defaults setBool:YES forKey:@"DYYYScaleAndSizeSettingsMigratedV1"];
    });
}

static void DYYYMigrateScaleAndSizeSettingsV2IfNeeded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        if ([defaults boolForKey:@"DYYYScaleAndSizeSettingsMigratedV2"]) {
            return;
        }

        NSString *nicknameScale = DYYYUserDefaultsStringValue([defaults objectForKey:@"DYYYNicknameScale"]);
        if (nicknameScale.length > 0 && [defaults objectForKey:@"DYYYIPLabelScale"] == nil) {
            [defaults setObject:nicknameScale forKey:@"DYYYIPLabelScale"];
        }

        [defaults setBool:YES forKey:@"DYYYScaleAndSizeSettingsMigratedV2"];
    });
}

// HDR 模式判定被 AVPlayerLayer、CALayer、UIImageView 等极高频钩子反复调用，
// 每次读取字符串偏好并比较的开销在滚动时不可忽略，这里按设置代际号缓存结果。
static BOOL DYYYShouldDisableAllHDR(void) {
    static uint32_t cachedGeneration = UINT32_MAX;
    static BOOL cachedValue = NO;

    uint32_t generation = gDYYYSettingsGeneration;
    if (cachedGeneration != generation) {
        cachedValue = [[[NSUserDefaults standardUserDefaults] stringForKey:kDYYYHDRModeKey] isEqualToString:kDYYYHDRModeDisable];
        cachedGeneration = generation;
    }
    return cachedValue;
}

static BOOL DYYYShouldFilterGlobalHDR(void) {
    static uint32_t cachedGeneration = UINT32_MAX;
    static BOOL cachedValue = NO;

    uint32_t generation = gDYYYSettingsGeneration;
    if (cachedGeneration != generation) {
        cachedValue = [[[NSUserDefaults standardUserDefaults] stringForKey:kDYYYHDRModeKey] isEqualToString:kDYYYHDRModeFilter];
        cachedGeneration = generation;
    }
    return cachedValue;
}

static id DYYYKVCValueIfPossible(id object, NSString *key) {
    if (!object || key.length == 0) {
        return nil;
    }

    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static void DYYYSetKVCValueIfPossible(id object, NSString *key, id value) {
    if (!object || key.length == 0) {
        return;
    }

    @try {
        [object setValue:value forKey:key];
    } @catch (__unused NSException *exception) {
    }
}

static id DYYYIvarValueIfPossible(id object, const char *ivarName) {
    if (!object || !ivarName) {
        return nil;
    }

    Class cls = object_getClass(object);
    while (cls) {
        Ivar ivar = class_getInstanceVariable(cls, ivarName);
        if (ivar) {
            return object_getIvar(object, ivar);
        }
        cls = class_getSuperclass(cls);
    }

    return nil;
}

static id DYYYValuePreferringIvar(id object, const char *ivarName, NSString *key) {
    id ivarValue = DYYYIvarValueIfPossible(object, ivarName);
    if (ivarValue) {
        return ivarValue;
    }
    return DYYYKVCValueIfPossible(object, key);
}

static NSInteger DYYYIntegerValueForKeyIfPossible(id object, NSString *key, NSInteger fallback) {
    id value = DYYYKVCValueIfPossible(object, key);
    if ([value respondsToSelector:@selector(integerValue)]) {
        return [value integerValue];
    }
    return fallback;
}

static BOOL DYYYStringValueLooksHDR(id value) {
    if (![value isKindOfClass:[NSString class]]) {
        return NO;
    }

    NSString *lowercaseValue = [(NSString *)value lowercaseString];
    return [lowercaseValue containsString:@"hdr"] ||
           [lowercaseValue containsString:@"hlg"] ||
           [lowercaseValue containsString:@"dolby"] ||
           [lowercaseValue containsString:@"vivid"] ||
           [lowercaseValue isEqualToString:@"pq"] ||
           [lowercaseValue containsString:@"_pq"] ||
           [lowercaseValue containsString:@"pq_"];
}

static BOOL DYYYRawBitrateDictionaryLooksHDR(NSDictionary *dictionary);

static BOOL DYYYBitrateModelLooksHDR(id bitrateModel) {
    if (!bitrateModel) {
        return NO;
    }

    if ([bitrateModel isKindOfClass:[NSDictionary class]]) {
        return DYYYRawBitrateDictionaryLooksHDR((NSDictionary *)bitrateModel);
    }

    id hdrTypeValue = DYYYKVCValueIfPossible(bitrateModel, @"hdrType");
    id hdrBitValue = DYYYKVCValueIfPossible(bitrateModel, @"hdrBit");
    NSInteger hdrType = DYYYIntegerValueForKeyIfPossible(bitrateModel, @"hdrType", 0);
    NSInteger hdrBit = DYYYIntegerValueForKeyIfPossible(bitrateModel, @"hdrBit", 0);
    BOOL hasHdrType = DYYYIntegerValueForKeyIfPossible(bitrateModel, @"hasHdrType", 0) > 0;
    BOOL hasHdrBit = DYYYIntegerValueForKeyIfPossible(bitrateModel, @"hasHdrBit", 0) > 0;

    return hdrType > 0 ||
           hdrBit >= 10 ||
           hasHdrType ||
           hasHdrBit ||
           DYYYStringValueLooksHDR(hdrTypeValue) ||
           DYYYStringValueLooksHDR(hdrBitValue);
}

static BOOL DYYYStringKeyLooksVideoBitrateList(NSString *key) {
    NSString *lowercaseKey = key.lowercaseString;
    if (lowercaseKey.length == 0 || [lowercaseKey containsString:@"audio"]) {
        return NO;
    }

    return [lowercaseKey containsString:@"bit_rate"] ||
           [lowercaseKey containsString:@"bitrate"] ||
           [lowercaseKey containsString:@"bit_rate_model"] ||
           [lowercaseKey containsString:@"bitratemodel"];
}

static BOOL DYYYRawBitrateDictionaryLooksHDR(NSDictionary *dictionary) {
    if (![dictionary isKindOfClass:[NSDictionary class]]) {
        return NO;
    }

    for (id rawKey in dictionary) {
        id value = dictionary[rawKey];
        NSString *key = [[rawKey description] lowercaseString];
        NSInteger numericValue = [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : 0;

        if (([key isEqualToString:@"hdr_type"] ||
             [key isEqualToString:@"hdrtype"] ||
             [key isEqualToString:@"videohdrtype"] ||
             [key isEqualToString:@"video_hdr_type"] ||
             [key isEqualToString:@"source_hdr_type"]) && numericValue > 0) {
            return YES;
        }

        if (([key isEqualToString:@"hdr_bit"] ||
             [key isEqualToString:@"hdrbit"] ||
             [key isEqualToString:@"bit_depth"] ||
             [key isEqualToString:@"bitdepth"]) && numericValue >= 10) {
            return YES;
        }

        if (([key isEqualToString:@"is_source_hdr"] ||
             [key isEqualToString:@"source_hdr"] ||
             [key isEqualToString:@"is_hdr"] ||
             [key isEqualToString:@"ishdr"] ||
             [key isEqualToString:@"has_hdr"] ||
             [key isEqualToString:@"hashdr"] ||
             [key isEqualToString:@"has_filter_hdr"] ||
             [key isEqualToString:@"filter_hdr"] ||
             [key isEqualToString:@"has_hdr_type"] ||
             [key isEqualToString:@"hashdrtype"] ||
             [key isEqualToString:@"has_hdr_bit"] ||
             [key isEqualToString:@"hashdrbit"]) && numericValue > 0) {
            return YES;
        }

        if (DYYYStringValueLooksHDR(value)) {
            return YES;
        }
    }

    return NO;
}

static void DYYYCollectRawBitrateHDRStatus(id object, NSUInteger depth, BOOL *foundHDRBitrate, BOOL *foundSDRBitrate) {
    if (!object || depth > 8 || (foundSDRBitrate && *foundSDRBitrate)) {
        return;
    }

    if ([object isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dictionary = (NSDictionary *)object;
        for (id rawKey in dictionary) {
            id value = dictionary[rawKey];
            NSString *key = [rawKey description];

            if (DYYYStringKeyLooksVideoBitrateList(key) && [value isKindOfClass:[NSArray class]]) {
                for (id entry in (NSArray *)value) {
                    if (![entry isKindOfClass:[NSDictionary class]]) {
                        continue;
                    }

                    if (DYYYRawBitrateDictionaryLooksHDR((NSDictionary *)entry)) {
                        if (foundHDRBitrate) {
                            *foundHDRBitrate = YES;
                        }
                    } else if (foundSDRBitrate) {
                        *foundSDRBitrate = YES;
                        return;
                    }
                }
                continue;
            }

            if ([value isKindOfClass:[NSDictionary class]] || [value isKindOfClass:[NSArray class]]) {
                DYYYCollectRawBitrateHDRStatus(value, depth + 1, foundHDRBitrate, foundSDRBitrate);
            }
        }
    } else if ([object isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)object) {
            DYYYCollectRawBitrateHDRStatus(value, depth + 1, foundHDRBitrate, foundSDRBitrate);
        }
    }
}

static BOOL DYYYRawObjectHasOnlyHDRBitrateModels(id object) {
    BOOL foundHDRBitrate = NO;
    BOOL foundSDRBitrate = NO;
    DYYYCollectRawBitrateHDRStatus(object, 0, &foundHDRBitrate, &foundSDRBitrate);
    return foundHDRBitrate && !foundSDRBitrate;
}

static BOOL DYYYVideoModelHasOnlyHDRBitrateModels(id video) {
    if (!video) {
        return NO;
    }

    NSNumber *cachedResult = objc_getAssociatedObject(video, &kDYYYHDROnlyVideoModelKey);
    if (cachedResult) {
        return cachedResult.boolValue;
    }

    NSMutableArray *models = [NSMutableArray array];
    NSArray *bitrateModels = DYYYValuePreferringIvar(video, "_bitrateModels", @"bitrateModels");
    if ([bitrateModels isKindOfClass:[NSArray class]]) {
        [models addObjectsFromArray:bitrateModels];
    }

    NSArray *manualBitrateModels = DYYYValuePreferringIvar(video, "_manualBitrateModels", @"manualBitrateModels");
    if ([manualBitrateModels isKindOfClass:[NSArray class]]) {
        [models addObjectsFromArray:manualBitrateModels];
    }

    NSArray *bitrateRawData = DYYYValuePreferringIvar(video, "_bitrateRawData", @"bitrateRawData");
    if ([bitrateRawData isKindOfClass:[NSArray class]]) {
        [models addObjectsFromArray:bitrateRawData];
    }

    if (models.count == 0) {
        return NO;
    }

    BOOL onlyHDR = YES;
    for (id model in models) {
        if (!DYYYBitrateModelLooksHDR(model)) {
            onlyHDR = NO;
            break;
        }
    }

    objc_setAssociatedObject(video, &kDYYYHDROnlyVideoModelKey, @(onlyHDR), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return onlyHDR;
}

static BOOL DYYYAwemeModelHasOnlyHDRBitrateModels(id aweme) {
    if (!aweme) {
        return NO;
    }

    NSNumber *cachedResult = objc_getAssociatedObject(aweme, &kDYYYHDROnlyAwemeModelKey);
    if (cachedResult) {
        return cachedResult.boolValue;
    }

    BOOL onlyHDR = NO;
    BOOL shouldCacheResult = NO;
    id video = DYYYValuePreferringIvar(aweme, "_video", @"video");
    if (video) {
        shouldCacheResult = YES;
    }
    if (DYYYVideoModelHasOnlyHDRBitrateModels(video)) {
        onlyHDR = YES;
    } else {
        NSArray *albumImages = DYYYValuePreferringIvar(aweme, "_albumImages", @"albumImages");
        if ([albumImages isKindOfClass:[NSArray class]]) {
            shouldCacheResult = shouldCacheResult || albumImages.count > 0;
            for (id imageModel in albumImages) {
                id clipVideo = DYYYValuePreferringIvar(imageModel, "_clipVideo", @"clipVideo");
                if (DYYYVideoModelHasOnlyHDRBitrateModels(clipVideo)) {
                    onlyHDR = YES;
                    break;
                }
            }
        }
    }

    if (shouldCacheResult || onlyHDR) {
        objc_setAssociatedObject(aweme, &kDYYYHDROnlyAwemeModelKey, @(onlyHDR), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return onlyHDR;
}

static NSArray *DYYYFilteredSDRRawBitrateData(NSArray *rawData) {
    if (![rawData isKindOfClass:[NSArray class]] || rawData.count == 0) {
        return rawData;
    }

    NSMutableArray *sdrData = [NSMutableArray arrayWithCapacity:rawData.count];
    NSUInteger hdrCount = 0;
    for (id entry in rawData) {
        if ([entry isKindOfClass:[NSDictionary class]] && DYYYRawBitrateDictionaryLooksHDR((NSDictionary *)entry)) {
            hdrCount++;
            continue;
        }
        [sdrData addObject:entry];
    }

    if (hdrCount == 0 || sdrData.count == 0) {
        return rawData;
    }

    return [sdrData copy];
}

static NSArray *DYYYFilteredSDRBitrateModels(NSArray *models) {
    if (![models isKindOfClass:[NSArray class]] || models.count == 0) {
        return models;
    }

    NSMutableArray *sdrModels = [NSMutableArray arrayWithCapacity:models.count];
    NSUInteger hdrCount = 0;
    for (id model in models) {
        if (DYYYBitrateModelLooksHDR(model)) {
            hdrCount++;
            continue;
        }
        [sdrModels addObject:model];
    }

    // 只有 HDR 档的作品在模型层过滤；这里不清空列表，避免播放器拿不到可播档导致有声黑屏。
    if (hdrCount == 0 || sdrModels.count == 0) {
        return models;
    }

    return [sdrModels copy];
}

static void DYYYStripHDRHintsFromBitrateModels(NSArray *models) {
    if (![models isKindOfClass:[NSArray class]]) {
        return;
    }

    for (id model in models) {
        DYYYSetKVCValueIfPossible(model, @"hdrType", @0);
        DYYYSetKVCValueIfPossible(model, @"hdrBit", @8);
        DYYYSetKVCValueIfPossible(model, @"hasHdrType", @NO);
        DYYYSetKVCValueIfPossible(model, @"hasHdrBit", @NO);
    }
}

static void DYYYStripHDRHintsFromVideoModel(id video) {
    if (!DYYYShouldDisableAllHDR() || !video) {
        return;
    }

    if (objc_getAssociatedObject(video, &kDYYYHDRStrippedVideoModelKey)) {
        return;
    }
    objc_setAssociatedObject(video, &kDYYYHDRStrippedVideoModelKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if ([video respondsToSelector:@selector(setIsSourceHDR:)]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(video, @selector(setIsSourceHDR:), 0);
    }
    if ([video respondsToSelector:@selector(setHasFilterHDR:)]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(video, @selector(setHasFilterHDR:), NO);
    }

    NSArray *bitrateModels = DYYYKVCValueIfPossible(video, @"bitrateModels");
    NSArray *filteredBitrateModels = DYYYFilteredSDRBitrateModels(bitrateModels);
    if (filteredBitrateModels && filteredBitrateModels != bitrateModels) {
        DYYYSetKVCValueIfPossible(video, @"bitrateModels", filteredBitrateModels);
        bitrateModels = filteredBitrateModels;
    }
    DYYYStripHDRHintsFromBitrateModels(bitrateModels);

    NSArray *manualBitrateModels = DYYYKVCValueIfPossible(video, @"manualBitrateModels");
    NSArray *filteredManualBitrateModels = DYYYFilteredSDRBitrateModels(manualBitrateModels);
    if (filteredManualBitrateModels && filteredManualBitrateModels != manualBitrateModels) {
        DYYYSetKVCValueIfPossible(video, @"manualBitrateModels", filteredManualBitrateModels);
        manualBitrateModels = filteredManualBitrateModels;
    }
    DYYYStripHDRHintsFromBitrateModels(manualBitrateModels);

    NSArray *bitrateRawData = DYYYValuePreferringIvar(video, "_bitrateRawData", @"bitrateRawData");
    NSArray *filteredBitrateRawData = DYYYFilteredSDRRawBitrateData(bitrateRawData);
    if (filteredBitrateRawData && filteredBitrateRawData != bitrateRawData) {
        DYYYSetKVCValueIfPossible(video, @"bitrateRawData", filteredBitrateRawData);
    }
}

static void DYYYStripHDRHintsFromAwemeModel(id aweme) {
    if (!DYYYShouldDisableAllHDR() || !aweme) {
        return;
    }

    if (objc_getAssociatedObject(aweme, &kDYYYHDRStrippedAwemeModelKey)) {
        return;
    }
    objc_setAssociatedObject(aweme, &kDYYYHDRStrippedAwemeModelKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    id video = DYYYValuePreferringIvar(aweme, "_video", @"video");
    DYYYStripHDRHintsFromVideoModel(video);

    NSArray *albumImages = DYYYValuePreferringIvar(aweme, "_albumImages", @"albumImages");
    if ([albumImages isKindOfClass:[NSArray class]]) {
        for (id imageModel in albumImages) {
            DYYYStripHDRHintsFromVideoModel(DYYYValuePreferringIvar(imageModel, "_clipVideo", @"clipVideo"));
        }
    }
}

static id DYYYStandardCADynamicRange(void) {
    static id standardDynamicRange = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *symbol = dlsym(RTLD_DEFAULT, "CADynamicRangeStandard");
        if (symbol) {
            id __unsafe_unretained *value = (id __unsafe_unretained *)symbol;
            standardDynamicRange = *value;
        }
    });
    return standardDynamicRange;
}

static id DYYYToneMapModeIfSupported(void) {
    static id toneMapMode = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *symbol = dlsym(RTLD_DEFAULT, "CAToneMapModeIfSupported");
        if (symbol) {
            id __unsafe_unretained *value = (id __unsafe_unretained *)symbol;
            toneMapMode = *value;
        }
    });
    return toneMapMode;
}

static void DYYYApplySDRDynamicRangeToImageView(UIImageView *imageView) {
    if (!DYYYShouldDisableAllHDR() || !imageView) {
        return;
    }

    if (@available(iOS 17.0, *)) {
        imageView.preferredImageDynamicRange = UIImageDynamicRangeStandard;
    }
}

// 头像加号可能由异步动画重建图层，需要在 CALayer 写入点继续压制。
static BOOL DYYYShouldForceHideAvatarActionLayer(CALayer *layer);
static BOOL DYYYShouldClearAvatarActionLayer(CALayer *layer);
static void DYYYPrepareAvatarActionSublayer(CALayer *parentLayer, CALayer *sublayer);

// 收藏按钮在部分视频中会异步重建图片/动画图层，标记后在写入点继续压制。
static char kDYYYFeedVideoCollectButtonHiddenViewKey;
static char kDYYYFeedVideoCollectButtonHiddenLayerKey;
static char kDYYYFeedVideoCollectButtonDeferredApplyKey;

static BOOL DYYYShouldForceHideFeedVideoCollectButtonLayer(CALayer *layer);
static BOOL DYYYShouldClearFeedVideoCollectButtonLayer(CALayer *layer);
static void DYYYPrepareFeedVideoCollectButtonSublayer(CALayer *parentLayer, CALayer *sublayer);
static BOOL DYYYShouldForceHideFeedVideoCollectButtonView(UIView *view);
static void DYYYMarkFeedVideoCollectButtonViewHidden(UIView *view);

static void DYYYDisableExtendedRangeForLayer(CALayer *layer) {
    if (!DYYYShouldDisableAllHDR() || !layer) {
        return;
    }

    SEL setWantsEDRSelector = @selector(setWantsExtendedDynamicRangeContent:);
    if ([layer respondsToSelector:setWantsEDRSelector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(layer, setWantsEDRSelector, NO);
    }

    id toneMapMode = DYYYToneMapModeIfSupported();
    SEL setToneMapModeSelector = @selector(setToneMapMode:);
    if (toneMapMode && [layer respondsToSelector:setToneMapModeSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(layer, setToneMapModeSelector, toneMapMode);
    }

    id standardDynamicRange = DYYYStandardCADynamicRange();
    SEL setPreferredDynamicRangeSelector = @selector(setPreferredDynamicRange:);
    if (standardDynamicRange && [layer respondsToSelector:setPreferredDynamicRangeSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(layer, setPreferredDynamicRangeSelector, standardDynamicRange);
    }

    if (@available(iOS 16.0, *)) {
        if ([layer isKindOfClass:[CAMetalLayer class]]) {
            ((CAMetalLayer *)layer).EDRMetadata = nil;
        }
    }
}

static void DYYYDisableExtendedRangeForMetalLayer(CAMetalLayer *metalLayer) {
    if (!DYYYShouldDisableAllHDR() || !metalLayer) {
        return;
    }

    DYYYDisableExtendedRangeForLayer(metalLayer);
}

static void DYYYDisableAVPlayerItemHDRMetadata(AVPlayerItem *item) {
    if (!DYYYShouldDisableAllHDR() || !item) {
        return;
    }

    if (@available(iOS 14.0, *)) {
        item.appliesPerFrameHDRDisplayMetadata = NO;
    }
}

// 保留 HDR 解码及原生 HDR -> SDR 转换，只关闭亮度增强、SDR -> HDR 和最终 EDR 输出。

%hook AVPlayer

+ (AVPlayerHDRMode)availableHDRModes {
    if (DYYYShouldDisableAllHDR()) {
        return 0;
    }
    return %orig;
}

+ (BOOL)eligibleForHDRPlayback {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

+ (instancetype)playerWithURL:(NSURL *)URL {
    AVPlayer *player = %orig;
    DYYYDisableAVPlayerItemHDRMetadata(player.currentItem);
    return player;
}

+ (instancetype)playerWithPlayerItem:(AVPlayerItem *)item {
    DYYYDisableAVPlayerItemHDRMetadata(item);
    return %orig;
}

- (instancetype)initWithURL:(NSURL *)URL {
    self = %orig;
    DYYYDisableAVPlayerItemHDRMetadata(self.currentItem);
    return self;
}

- (instancetype)initWithPlayerItem:(AVPlayerItem *)item {
    DYYYDisableAVPlayerItemHDRMetadata(item);
    return %orig;
}

- (void)replaceCurrentItemWithPlayerItem:(AVPlayerItem *)item {
    DYYYDisableAVPlayerItemHDRMetadata(item);
    %orig;
}

%end

%hook AVPlayerItem

+ (instancetype)playerItemWithURL:(NSURL *)URL {
    AVPlayerItem *item = %orig;
    DYYYDisableAVPlayerItemHDRMetadata(item);
    return item;
}

+ (instancetype)playerItemWithAsset:(AVAsset *)asset {
    AVPlayerItem *item = %orig;
    DYYYDisableAVPlayerItemHDRMetadata(item);
    return item;
}

+ (instancetype)playerItemWithAsset:(AVAsset *)asset automaticallyLoadedAssetKeys:(NSArray<NSString *> *)automaticallyLoadedAssetKeys {
    AVPlayerItem *item = %orig;
    DYYYDisableAVPlayerItemHDRMetadata(item);
    return item;
}

- (instancetype)initWithURL:(NSURL *)URL {
    self = %orig;
    DYYYDisableAVPlayerItemHDRMetadata(self);
    return self;
}

- (instancetype)initWithAsset:(AVAsset *)asset {
    self = %orig;
    DYYYDisableAVPlayerItemHDRMetadata(self);
    return self;
}

- (instancetype)initWithAsset:(AVAsset *)asset automaticallyLoadedAssetKeys:(NSArray<NSString *> *)automaticallyLoadedAssetKeys {
    self = %orig;
    DYYYDisableAVPlayerItemHDRMetadata(self);
    return self;
}

- (void)setAppliesPerFrameHDRDisplayMetadata:(BOOL)appliesPerFrameHDRDisplayMetadata {
    %orig(DYYYShouldDisableAllHDR() ? NO : appliesPerFrameHDRDisplayMetadata);
}

- (BOOL)appliesPerFrameHDRDisplayMetadata {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

%end

%hook AVPlayerLayer

- (void)setPlayer:(AVPlayer *)player {
    DYYYDisableAVPlayerItemHDRMetadata(player.currentItem);
    %orig;
    DYYYDisableExtendedRangeForLayer(self);
}

- (void)layoutSublayers {
    %orig;
    DYYYDisableAVPlayerItemHDRMetadata(self.player.currentItem);
    DYYYDisableExtendedRangeForLayer(self);
}

%end

%hook AWEKnowledgeABTestSettings

+ (BOOL)enableHDRAutomaticIdentification {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

%end

%hook AWEFeedABSettings

+ (BOOL)enableHDRBrightnessOpt {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

+ (BOOL)enableProfilePreloadHDRBrightnessFilter {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

+ (BOOL)enableDynamicGaussianBlurHDR {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

+ (BOOL)enableHDRFullModelAdaptation {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

+ (BOOL)hdrAutomaticIdentification {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

%end

%hook AWEFeedABTestServiceObjc

+ (BOOL)enableProfilePreloadHDRBrightnessFilter {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

%end

%hook BDSimPlayerBizConfig

- (BOOL)enableHDRBrightnessOpt {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (BOOL)enableHDRFullModelAdaptation {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (BOOL)hdrAutomaticIdentification {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

%end

%hook AWEBDSimPlayerBizConfig

- (BOOL)enableHDRBrightnessOpt {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (BOOL)enableHDRFullModelAdaptation {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (BOOL)hdrAutomaticIdentification {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

%end

%hook AWEVideoPlayerConfiguration

+ (void)setHDRBrightnessStrategy:(id)strategy {
    if (!DYYYShouldDisableAllHDR()) {
        %orig;
    }
}

+ (double)getHDRBrightnessOffset:(id)configuration brightness:(double)brightness {
    if (DYYYShouldDisableAllHDR()) {
        return 0.0;
    }
    return %orig;
}

%end

%hook AWEDPlayerVideoDisplayOptState

- (BOOL)enableHDR {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (void)setEnableHDR:(BOOL)enableHDR {
    %orig(DYYYShouldDisableAllHDR() ? NO : enableHDR);
}

%end

%hook AWEPlayVideoPlayerContext

- (BOOL)enableHDR {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (void)setEnableHDR:(BOOL)enableHDR {
    %orig(DYYYShouldDisableAllHDR() ? NO : enableHDR);
}

%end

%hook AWEDPlayerVideoModel

- (BOOL)awe_isHDRVideo {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (void)setAwe_isHDRVideo:(BOOL)awe_isHDRVideo {
    %orig(DYYYShouldDisableAllHDR() ? NO : awe_isHDRVideo);
}

%end

%hook AWEPlayVideoViewController

- (BOOL)enableHDR {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (void)setEnableHDR:(BOOL)enableHDR {
    %orig(DYYYShouldDisableAllHDR() ? NO : enableHDR);
}

- (BOOL)awe_isCurrentVideoHDR {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (void)setPlayerLutFilter:(id)lutFilter HDRLutImage:(id)HDRLutImage {
    %orig(lutFilter, DYYYShouldDisableAllHDR() ? nil : HDRLutImage);
}

%end

%hook AWEDPlayerBrightnessContainer

- (BOOL)awe_isCurrentVideoHDR {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

%end

%hook AWEVideoPlayerScreenBrightnessManager

- (BOOL)isHDRVideo {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (void)setIsHDRVideo:(BOOL)isHDRVideo {
    // 播放器复用时会重新写入当前作品的 HDR 状态，需同时清除写入值和读取结果。
    %orig(DYYYShouldDisableAllHDR() ? NO : isHDRVideo);
}

%end

%hook ALMOwnPlayerWrapper

- (void)setLutFilter:(id)lutFilter HDRLutImage:(id)HDRLutImage {
    %orig(lutFilter, DYYYShouldDisableAllHDR() ? nil : HDRLutImage);
}

%end

%hook ALMSysPlayerWrapper

- (void)setLutFilter:(id)lutFilter HDRLutImage:(id)HDRLutImage {
    %orig(lutFilter, DYYYShouldDisableAllHDR() ? nil : HDRLutImage);
}

%end

%hook ALMVideoPlayerConfig

+ (void)setPlayerEffectHDRLutImageEnable:(BOOL)enable {
    %orig(DYYYShouldDisableAllHDR() ? NO : enable);
}

%end

%hook IESVideoPlayerConfig

+ (void)setPlayerEffectHDRLutImageEnable:(BOOL)enable {
    %orig(DYYYShouldDisableAllHDR() ? NO : enable);
}

%end

%hook AWEIMModuleService

- (BOOL)im_forceHDRToSDR {
    if (DYYYShouldDisableAllHDR()) {
        return YES;
    }
    return %orig;
}

%end

%hook IESIMVideoPlayerWrapper

- (void)setupHDREnable:(BOOL)enable {
    %orig(DYYYShouldDisableAllHDR() ? NO : enable);
}

%end

%hook AWEIMVideoBrowserCollectionViewCell

- (void)setEnablePlayHDR:(BOOL)enable {
    %orig(DYYYShouldDisableAllHDR() ? NO : enable);
}

%end

%hook AWEECOMIMAppSettingsService

+ (BOOL)enableVideoPreviewSupportHDR {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

%end

%hook IESLiveAudienceHDRController

+ (BOOL)currentHDRStatusForRoomID:(id)roomID {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

+ (BOOL)isCurrentRoomSupportHDR:(id)roomID roomModel:(id)roomModel {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

+ (BOOL)isFeedCanEnableHDRFeature {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

+ (BOOL)isInnerFeedCanEnableHDRFeature {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

+ (BOOL)isUserEnableHDR {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

+ (BOOL)p_isHDRFeatureEnable {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

+ (void)setUserEnableHDR:(BOOL)enableHDR {
    %orig(DYYYShouldDisableAllHDR() ? NO : enableHDR);
}

+ (BOOL)shouldShowHDRSwitchForRoom:(id)room {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

%end

%hook IESLivePlayerController

- (BOOL)isVideoSDR2HDRSupport {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (void)setEnableVideoSDR2HDR:(BOOL)enable callTrace:(id)callTrace {
    %orig(DYYYShouldDisableAllHDR() ? NO : enable, callTrace);
}

- (BOOL)enableCloseSDR2HDR {
    if (DYYYShouldDisableAllHDR()) {
        return YES;
    }
    return %orig;
}

%end

%hook AWELivePreStreamPlayer

- (void)changeSDR2HDRWithStrategy {
    if (!DYYYShouldDisableAllHDR()) {
        %orig;
    }
}

%end

%hook HTSLiveStreamPlayer

- (void)setEnableVideoSDR2HDR:(BOOL)enable callTrace:(id)callTrace {
    %orig(DYYYShouldDisableAllHDR() ? NO : enable, callTrace);
}

- (void)changeSDR2HDRWithStrategy {
    if (!DYYYShouldDisableAllHDR()) {
        %orig;
    }
}

%end

%hook IESLiveStreamPlayerVideoAudioEffectPlugin

- (void)setEnableVideoSDR2HDR:(BOOL)enable callTrace:(id)callTrace {
    %orig(DYYYShouldDisableAllHDR() ? NO : enable, callTrace);
}

- (void)changeSDR2HDRWithStrategy {
    if (!DYYYShouldDisableAllHDR()) {
        %orig;
    }
}

%end

%hook TVLManager

- (BOOL)shouldForbidHDR10Render {
    if (DYYYShouldDisableAllHDR()) {
        return YES;
    }
    return %orig;
}

- (void)setShouldForbidHDR10Render:(BOOL)shouldForbid {
    %orig(DYYYShouldDisableAllHDR() ? YES : shouldForbid);
}

- (void)setupVideoSDR2HDR:(id)config {
    if (!DYYYShouldDisableAllHDR()) {
        %orig;
    }
}

%end

%hook TVLPlayerItemPreferences

- (BOOL)forbidSDR2HDRInPreview {
    if (DYYYShouldDisableAllHDR()) {
        return YES;
    }
    return %orig;
}

- (void)setForbidSDR2HDRInPreview:(BOOL)forbid {
    %orig(DYYYShouldDisableAllHDR() ? YES : forbid);
}

- (BOOL)enableUseSDR2HDR {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (void)setEnableUseSDR2HDR:(BOOL)enable {
    %orig(DYYYShouldDisableAllHDR() ? NO : enable);
}

%end

%hook TVLSettingsManager

- (BOOL)enableMetalRenderHDR {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

%end

%hook IESFiltersManager

- (void)setHDRIndensity:(double)intensity {
    %orig(DYYYShouldDisableAllHDR() ? 0.0 : intensity);
}

%end

%hook BDImageDecoderFactory

+ (BOOL)isHDRImageData:(id)data withHeifDecoderClass:(Class)decoderClass {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

%end

%hook BDImageDecoderImageIO

- (BOOL)isHDRCGImage:(CGImageRef)image decodedToHDR:(BOOL)decodedToHDR {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (id)hdrOptionsFor:(id)image decodedToHDR:(BOOL *)decodedToHDR {
    if (DYYYShouldDisableAllHDR()) {
        if (decodedToHDR) {
            *decodedToHDR = NO;
        }
        return nil;
    }
    return %orig;
}

%end

%hook BDImageDecoderHeic

+ (BOOL)isHDRData:(id)data {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (BOOL)isHDR {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (void)setIsHDR:(BOOL)isHDR {
    %orig(DYYYShouldDisableAllHDR() ? NO : isHDR);
}

%end

%hook BDImageDecoderBVC2

- (BOOL)isHDR {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (void)setIsHDR:(BOOL)isHDR {
    %orig(DYYYShouldDisableAllHDR() ? NO : isHDR);
}

%end

%hook BDImageDecoderWebP

- (BOOL)isHDR {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (void)setIsHDR:(BOOL)isHDR {
    %orig(DYYYShouldDisableAllHDR() ? NO : isHDR);
}

%end

%hook BDImage

- (BOOL)isHDR {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (void)setIsHDR:(BOOL)isHDR {
    %orig(DYYYShouldDisableAllHDR() ? NO : isHDR);
}

%end

%hook HDRMTUIImageView

- (instancetype)initWithFrame:(CGRect)frame hdrEnabled:(BOOL)hdrEnabled {
    return %orig(frame, DYYYShouldDisableAllHDR() ? NO : hdrEnabled);
}

- (BOOL)hdrEnabled {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (void)setHdrEnabled:(BOOL)hdrEnabled {
    %orig(DYYYShouldDisableAllHDR() ? NO : hdrEnabled);
}

- (void)setImage:(UIImage *)image {
    if (DYYYShouldDisableAllHDR()) {
        self.hdrEnabled = NO;
    }
    DYYYApplySDRDynamicRangeToImageView(self);
    %orig;
    DYYYApplySDRDynamicRangeToImageView(self);
}

%end

%hook HDRMTImageView

- (void)setMetalLayer:(CAMetalLayer *)metalLayer {
    %orig;
    DYYYDisableExtendedRangeForMetalLayer(metalLayer);
}

- (void)setUpEnv {
    %orig;
    DYYYDisableExtendedRangeForMetalLayer(self.metalLayer);
}

- (void)layoutSubviews {
    %orig;
    DYYYDisableExtendedRangeForMetalLayer(self.metalLayer);
}

%end

%hook HDRMTButton

- (void)configHDRContent {
    %orig;
    DYYYApplySDRDynamicRangeToImageView(self.hdrmtImageView);
}

%end

%hook CAMetalLayer

- (void)setWantsExtendedDynamicRangeContent:(BOOL)wantsExtendedDynamicRangeContent {
    %orig(DYYYShouldDisableAllHDR() ? NO : wantsExtendedDynamicRangeContent);
}

- (BOOL)wantsExtendedDynamicRangeContent {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (void)setEDRMetadata:(CAEDRMetadata *)EDRMetadata {
    %orig(DYYYShouldDisableAllHDR() ? nil : EDRMetadata);
}

- (CAEDRMetadata *)EDRMetadata {
    if (DYYYShouldDisableAllHDR()) {
        return nil;
    }
    return %orig;
}

%end

%hook CALayer

- (void)setHidden:(BOOL)hidden {
    BOOL shouldForceHidden = DYYYShouldForceHideAvatarActionLayer(self) || DYYYShouldForceHideFeedVideoCollectButtonLayer(self);
    %orig(shouldForceHidden ? YES : hidden);
}

- (void)setContents:(id)contents {
    BOOL shouldClearLayer = DYYYShouldClearAvatarActionLayer(self) || DYYYShouldClearFeedVideoCollectButtonLayer(self);
    %orig(shouldClearLayer ? nil : contents);
}

- (void)setBackgroundColor:(CGColorRef)backgroundColor {
    BOOL shouldClearLayer = DYYYShouldClearAvatarActionLayer(self) || DYYYShouldClearFeedVideoCollectButtonLayer(self);
    %orig(shouldClearLayer ? UIColor.clearColor.CGColor : backgroundColor);
}

- (void)setOpaque:(BOOL)opaque {
    BOOL shouldClearLayer = DYYYShouldClearAvatarActionLayer(self) || DYYYShouldClearFeedVideoCollectButtonLayer(self);
    %orig(shouldClearLayer ? NO : opaque);
}

- (void)setBorderWidth:(CGFloat)borderWidth {
    BOOL shouldClearLayer = DYYYShouldClearAvatarActionLayer(self) || DYYYShouldClearFeedVideoCollectButtonLayer(self);
    %orig(shouldClearLayer ? 0.0 : borderWidth);
}

- (void)setBorderColor:(CGColorRef)borderColor {
    BOOL shouldClearLayer = DYYYShouldClearAvatarActionLayer(self) || DYYYShouldClearFeedVideoCollectButtonLayer(self);
    %orig(shouldClearLayer ? UIColor.clearColor.CGColor : borderColor);
}

- (void)setShadowOpacity:(float)shadowOpacity {
    BOOL shouldClearLayer = DYYYShouldClearAvatarActionLayer(self) || DYYYShouldClearFeedVideoCollectButtonLayer(self);
    %orig(shouldClearLayer ? 0.0f : shadowOpacity);
}

- (void)setShadowColor:(CGColorRef)shadowColor {
    BOOL shouldClearLayer = DYYYShouldClearAvatarActionLayer(self) || DYYYShouldClearFeedVideoCollectButtonLayer(self);
    %orig(shouldClearLayer ? UIColor.clearColor.CGColor : shadowColor);
}

- (void)addSublayer:(CALayer *)layer {
    DYYYPrepareAvatarActionSublayer(self, layer);
    DYYYPrepareFeedVideoCollectButtonSublayer(self, layer);
    %orig(layer);
}

- (void)insertSublayer:(CALayer *)layer atIndex:(unsigned int)index {
    DYYYPrepareAvatarActionSublayer(self, layer);
    DYYYPrepareFeedVideoCollectButtonSublayer(self, layer);
    %orig(layer, index);
}

- (void)insertSublayer:(CALayer *)layer below:(CALayer *)sibling {
    DYYYPrepareAvatarActionSublayer(self, layer);
    DYYYPrepareFeedVideoCollectButtonSublayer(self, layer);
    %orig(layer, sibling);
}

- (void)insertSublayer:(CALayer *)layer above:(CALayer *)sibling {
    DYYYPrepareAvatarActionSublayer(self, layer);
    DYYYPrepareFeedVideoCollectButtonSublayer(self, layer);
    %orig(layer, sibling);
}

- (void)setSublayers:(NSArray<CALayer *> *)sublayers {
    for (CALayer *layer in sublayers) {
        DYYYPrepareAvatarActionSublayer(self, layer);
        DYYYPrepareFeedVideoCollectButtonSublayer(self, layer);
    }
    %orig(sublayers);
}

- (void)setWantsExtendedDynamicRangeContent:(BOOL)wantsExtendedDynamicRangeContent {
    %orig(DYYYShouldDisableAllHDR() ? NO : wantsExtendedDynamicRangeContent);
}

- (BOOL)wantsExtendedDynamicRangeContent {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (void)setPreferredDynamicRange:(id)preferredDynamicRange {
    id standardDynamicRange = DYYYStandardCADynamicRange();
    %orig(DYYYShouldDisableAllHDR() && standardDynamicRange ? standardDynamicRange : preferredDynamicRange);
}

- (id)preferredDynamicRange {
    id preferredDynamicRange = %orig;
    if (DYYYShouldDisableAllHDR()) {
        id standardDynamicRange = DYYYStandardCADynamicRange();
        if (standardDynamicRange) {
            return standardDynamicRange;
        }
    }
    return preferredDynamicRange;
}

%end

%hook CAShapeLayer

- (void)setFillColor:(CGColorRef)fillColor {
    BOOL shouldClearLayer = DYYYShouldClearAvatarActionLayer(self) || DYYYShouldClearFeedVideoCollectButtonLayer(self);
    %orig(shouldClearLayer ? UIColor.clearColor.CGColor : fillColor);
}

- (void)setStrokeColor:(CGColorRef)strokeColor {
    BOOL shouldClearLayer = DYYYShouldClearAvatarActionLayer(self) || DYYYShouldClearFeedVideoCollectButtonLayer(self);
    %orig(shouldClearLayer ? UIColor.clearColor.CGColor : strokeColor);
}

%end

// 直播间真实人数
%hook IESLiveUserSeqlistFragment

- (void)refreshVerticalUserCount:(id)arg1 horizontalUserCount:(id)arg2 trueValue:(NSInteger)trueValue {
    if ( trueValue > 0 && DYYYGetBool(@"DYYYEnableLiveRealCount") ) {
        NSString *realStr = [NSString stringWithFormat:@"%ld", (long)trueValue];
        %orig(realStr, realStr, trueValue);
    } else {
        %orig;
    }
}

%end

// 评论具体时间
%hook AWEDateTimeFormatter

+ (id)formattedDateForTimestamp:(double)timestamp {
    if (!DYYYGetBool(@"DYYYCommentExactTime")) return %orig(timestamp);
    return [NSString stringWithFormat:@"%.0f ", timestamp];
}

%end

%hook AWERLVirtualLabel

- (void)setText:(NSString *)text {
    if (!DYYYGetBool(@"DYYYCommentExactTime") || !text || text.length == 0) {
        %orig(text);
        return;
    }

    if ([text isEqualToString:@"回复"]) {
        %orig(@"");
        return;
    }

    NSError *error = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^(\\d{10,13})([\\s\\S]*)" options:0 error:&error];

    NSTextCheckingResult *match = [regex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];

    if (match) {
        NSString *rawTs = [text substringWithRange:[match rangeAtIndex:1]];
        NSString *suffix = [text substringWithRange:[match rangeAtIndex:2]];

        long long ts = [rawTs longLongValue];

        if (ts > 100000000000) {
            ts = ts / 1000;
        }

        NSDate *date = [NSDate dateWithTimeIntervalSince1970:ts];
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
        NSString *formattedDate = [formatter stringFromDate:date];

        NSString *newText = [NSString stringWithFormat:@"%@%@", formattedDate, suffix];
        %orig(newText);
    } else {
        %orig(text);
    }
}

%end

%group DYYYCommentExactTimeGroup
%hook AWECommentSwiftBizUI_CommentInteractionBaseLabel

- (void)setText:(NSString *)text {
    %orig(text); // 先让系统把文本赋上去

    if (!DYYYGetBool(@"DYYYCommentExactTime")) {
        return;
    }

    UILabel *label = (UILabel *)self;
    if (!text || text.length == 0) return;

    // --- 1. 拦截翻译文本，将其绝对定位在屏幕右侧 100 像素 ---
    if ([text isEqualToString:@"翻译"] || [text isEqualToString:@"隐藏翻译"]) {
        CGRect currentFrame = label.frame;
        CGFloat screenWidth = [UIScreen mainScreen].bounds.size.width;
        // 重新计算 X 坐标：屏幕宽度 - 100 - 标签自身宽度
        currentFrame.origin.x = screenWidth - 100.0 - currentFrame.size.width;
        label.frame = currentFrame;
        return;
    }

    // --- 2. 拦截时间文本，如果不够宽则扩充宽度 ---
    UIFont *font = label.font;
    if (font) {
        CGFloat expectedWidth = ceilf([text sizeWithAttributes:@{NSFontAttributeName: font}].width);
        CGRect currentFrame = label.frame;

        // 如果当前宽度不够，并且不是尚未初始化的状态（>0），则强行修改并重新赋值
        if (currentFrame.size.width < expectedWidth && currentFrame.size.width > 0) {
            currentFrame.size.width = expectedWidth;
            label.frame = currentFrame;
            label.clipsToBounds = NO;
        }
    }
}

- (void)setFrame:(CGRect)frame {
    if (!DYYYGetBool(@"DYYYCommentExactTime") || ![self respondsToSelector:@selector(text)]) {
        %orig(frame);
        return;
    }

    UILabel *label = (UILabel *)self;
    NSString *text = label.text;

    if (text && text.length > 0) {
        // --- 1. 拦截翻译文本，将其绝对定位在屏幕右侧 100 像素 ---
        if ([text isEqualToString:@"翻译"] || [text isEqualToString:@"隐藏翻译"]) {
            CGFloat screenWidth = [UIScreen mainScreen].bounds.size.width;
            frame.origin.x = screenWidth - 100.0 - frame.size.width;
        }
        // --- 2. 拦截时间文本，如果不够宽则扩充宽度 ---
        else if ([self respondsToSelector:@selector(font)]) {
            UIFont *font = label.font;
            if (font) {
                CGFloat expectedWidth = ceilf([text sizeWithAttributes:@{NSFontAttributeName: font}].width);
                if (frame.size.width < expectedWidth && frame.size.width > 0) {
                    frame.size.width = expectedWidth;
                    label.clipsToBounds = NO;
                }
            }
        }
    }

    %orig(frame);
}

%end
%end

// 前面的AWEDateTimeFormatter会导致图文视频展开时间文本变成时间戳，这里处理下
%hook YYLabel

// 1. Hook 富文本赋值方法 (核心)
- (void)setAttributedText:(NSAttributedString *)attributedText {
    if (!DYYYGetBool(@"DYYYCommentExactTime") || !attributedText || attributedText.length == 0) {
        %orig(attributedText);
        return;
    }

    NSString *plainText = [attributedText string];

    NSError *error = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^(\\d{10,13})" options:0 error:&error];
    NSTextCheckingResult *match = [regex firstMatchInString:plainText options:0 range:NSMakeRange(0, plainText.length)];

    if (match) {
        NSString *rawTs = [plainText substringWithRange:[match rangeAtIndex:1]];
        long long ts = [rawTs longLongValue];

        if (ts > 100000000000) {
            ts = ts / 1000;
        }

        NSDate *date = [NSDate dateWithTimeIntervalSince1970:ts];
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
        NSString *formattedDate = [formatter stringFromDate:date];

        NSMutableAttributedString *newAttrStr = [attributedText mutableCopy];
        [newAttrStr replaceCharactersInRange:[match rangeAtIndex:1] withString:formattedDate];

        %orig(newAttrStr);
    } else {
        %orig(attributedText);
    }
}

%end

// 禁用自动进入直播间
%hook AWELiveGuideElement

- (BOOL)enableAutoEnterRoom {
    if (DYYYGetBool(@"DYYYDisableAutoEnterLive")) {
        return NO;
    }
    return %orig;
}

- (BOOL)enableNewAutoEnter {
    if (DYYYGetBool(@"DYYYDisableAutoEnterLive")) {
        return NO;
    }
    return %orig;
}

%end

%hook AWEFeedChannelManager

- (void)reloadChannelWithChannelModels:(id)arg1 currentChannelIDList:(id)arg2 reloadType:(id)arg3 selectedChannelID:(id)arg4 {
    NSArray *channelModels = arg1;
    NSMutableArray *newChannelModels = [NSMutableArray array];
    NSArray *currentChannelIDList = arg2;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableArray *newCurrentChannelIDList = [NSMutableArray arrayWithArray:currentChannelIDList];

    if (!arg1 || !arg2) {
        %orig(arg1, arg2, arg3, arg4);
        return;
    }

    if (![channelModels isKindOfClass:[NSArray class]] || ![currentChannelIDList isKindOfClass:[NSArray class]]) {
        %orig(arg1, arg2, arg3, arg4);
        return;
    }

    if (channelModels.count == 0) {
        %orig(arg1, arg2, arg3, arg4);
        return;
    }

    for (AWEHPTopTabItemModel *tabItemModel in channelModels) {
        NSString *channelID = tabItemModel.channelID;
        BOOL isHideChannel = NO;

        if ([channelID isEqualToString:@"homepage_hot_container"]) {
            isHideChannel = [defaults boolForKey:@"DYYYHideHotContainer"];
        } else if ([channelID isEqualToString:@"homepage_follow"]) {
            isHideChannel = [defaults boolForKey:@"DYYYHideFollow"];
        } else if ([channelID isEqualToString:@"homepage_mall"]) {
            isHideChannel = [defaults boolForKey:@"DYYYHideMall"];
        } else if ([channelID isEqualToString:@"homepage_nearby"]) {
            isHideChannel = [defaults boolForKey:@"DYYYHideNearby"];
        } else if ([channelID isEqualToString:@"homepage_groupon"]) {
            isHideChannel = [defaults boolForKey:@"DYYYHideGroupon"];
        } else if ([channelID isEqualToString:@"homepage_tablive"]) {
            isHideChannel = [defaults boolForKey:@"DYYYHideTabLive"];
        } else if ([channelID isEqualToString:@"homepage_pad_hot"]) {
            isHideChannel = [defaults boolForKey:@"DYYYHidePadHot"];
        } else if ([channelID isEqualToString:@"homepage_hangout"]) {
            isHideChannel = [defaults boolForKey:@"DYYYHideHangout"];
        } else if ([channelID isEqualToString:@"homepage_familiar"]) {
            isHideChannel = [defaults boolForKey:@"DYYYHideFriend"];
        } else if ([channelID isEqualToString:@"homepage_playlet_stream"]) {
            isHideChannel = [defaults boolForKey:@"DYYYHidePlaylet"];
        } else if ([channelID isEqualToString:@"homepage_pad_cinema"]) {
            isHideChannel = [defaults boolForKey:@"DYYYHideCinema"];
        } else if ([channelID isEqualToString:@"homepage_pad_kids_v2"]) {
            isHideChannel = [defaults boolForKey:@"DYYYHideKidsV2"];
        } else if ([channelID isEqualToString:@"homepage_pad_game"]) {
            isHideChannel = [defaults boolForKey:@"DYYYHideGame"];
        } else if ([channelID isEqualToString:@"homepage_mediumvideo"]) {
            isHideChannel = [defaults boolForKey:@"DYYYHideMediumVideo"];
        }

        if (!isHideChannel) {
            [newChannelModels addObject:tabItemModel];
        } else {
            [newCurrentChannelIDList removeObject:channelID];
        }
    }

    %orig(newChannelModels, newCurrentChannelIDList, arg3, arg4);
}

%end

%hook AWELandscapeFeedViewController
- (void)viewDidLoad {
    %orig;

    // 尝试优先走属性
    gFeedCV = self.collectionView;

    // 保险起见再fallback,遍历 subviews
    if (!gFeedCV) {
        gFeedCV = [DYYYUtils findSubviewOfClass:[UICollectionView class] inContainer:self.view];
    }
}
%end

%hook UICollectionView

// 拦截手指拖动
- (void)handlePan:(UIPanGestureRecognizer *)pan {
    /* 仅处理横屏Feed列表。其余collectionView直接走系统逻辑 */
    if (self != gFeedCV || !DYYYGetBool(@"DYYYVideoGesture")) {
        %orig;
        return;
    }

    /* 取触点坐标、手势状态 */
    CGPoint loc = [pan locationInView:self];
    CGFloat w = self.bounds.size.width;
    CGFloat xPct = loc.x / w; // 0.0 ~ 1.0
    UIGestureRecognizerState st = pan.state;

    /* BEGAN：判定左右 20 % 区域 → 进入亮度 / 音量模式 */
    if (st == UIGestureRecognizerStateBegan) {
        gStartY = loc.y;

        if (xPct <= 0.20) { // 左边缘 → 亮度
            gMode = DYEdgeModeBrightness;
            gStartVal = [UIScreen mainScreen].brightness;
        } else if (xPct >= 0.80) { // 右边缘 → 音量
            gMode = DYEdgeModeVolume;
            gStartVal = [[objc_getClass("AVSystemController") sharedAVSystemController] volumeForCategory:@"Audio/Video"];
        } else {
            gMode = DYEdgeModeNone; // 中间区域走原逻辑
        }
    }

    /* 调节阶段：左右边缘时吞掉滚动、修改亮度/音量 */
    if (gMode != DYEdgeModeNone) {
        if (st == UIGestureRecognizerStateChanged) {
            CGFloat delta = (gStartY - loc.y) / self.bounds.size.height; // ↑ 为正
            const CGFloat kScale = 2.0;                                  // 灵敏度
            float newVal = gStartVal + delta * kScale;
            newVal = fminf(fmaxf(newVal, 0.0), 1.0); // Clamp 0~1

            if (gMode == DYEdgeModeBrightness) {
                [UIScreen mainScreen].brightness = newVal;
                // 弹系统亮度 HUD
                [[%c(SBHUDController) sharedInstance] presentHUDWithIcon:@"Brightness" level:newVal];
            } else { // DYEdgeModeVolume
                // iOS 18 音量控制 + 系统音量 HUD
                [[objc_getClass("AVSystemController") sharedAVSystemController] setVolumeTo:newVal forCategory:@"Audio/Video"];
            }

            // 吞掉滚动：归零 translation，防止内容位移
            [pan setTranslation:CGPointZero inView:self];
        }

        /* 结束／取消：状态复位 */
        if (st == UIGestureRecognizerStateEnded || st == UIGestureRecognizerStateCancelled || st == UIGestureRecognizerStateFailed) {
            gMode = DYEdgeModeNone;
        }

        return; // 左右边缘：彻底阻断 %orig，避免翻页
    }

    /* 中间区域：直接执行原先翻页逻辑 */
    %orig;
}

%end

%hook AWELeftSideBarAddChildTransitionObject

- (void)handleShowSliderPanGesture:(id)gr {
    if (DYYYGetBool(@"DYYYDisableSidebarGesture")) {
        return;
    }
    %orig(gr);
}

%end

// 关注二次确认：弹窗关闭后再触发原逻辑，且不再传入已失效的手势对象。
static void DYYYRunDeferredFollowConfirm(void (^action)(void)) {
    if (!action) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            action();
        });
    });
}

%hook AWEPlayInteractionUserAvatarElement
- (void)onFollowViewClicked:(UITapGestureRecognizer *)gesture {
    if (DYYYGetBool(@"DYYYFollowTips")) {
        // 获取用户信息
        AWEUserModel *author = nil;
        NSString *nickname = @"";
        NSString *signature = @"";
        NSString *avatarURL = @"";

        if ([self respondsToSelector:@selector(model)]) {
            id model = [self model];
            if ([model isKindOfClass:NSClassFromString(@"AWEAwemeModel")]) {
                author = [model valueForKey:@"author"];
            }
        }

        if (author) {
            // 获取昵称
            if ([author respondsToSelector:@selector(nickname)]) {
                nickname = [author valueForKey:@"nickname"] ?: @"";
            }

            // 获取签名
            if ([author respondsToSelector:@selector(signature)]) {
                signature = [author valueForKey:@"signature"] ?: @"";
            }

            // 获取头像URL
            if ([author respondsToSelector:@selector(avatarThumb)]) {
                AWEURLModel *avatarThumb = [author valueForKey:@"avatarThumb"];
                if (avatarThumb && avatarThumb.originURLList.count > 0) {
                    avatarURL = avatarThumb.originURLList.firstObject;
                }
            }
        }

        NSMutableString *messageContent = [NSMutableString string];
        if (signature.length > 0) {
            [messageContent appendFormat:@"%@", signature];
        }

        NSString *title = nickname.length > 0 ? nickname : @"关注确认";

        [DYYYBottomAlertView showAlertWithTitle:title
                                        message:messageContent
                                      avatarURL:avatarURL
                               cancelButtonText:@"取消"
                              confirmButtonText:@"关注"
                                   cancelAction:nil
                                    closeAction:nil
                                  confirmAction:^{
                                    DYYYRunDeferredFollowConfirm(^{
                                        %orig(nil);
                                    });
                                  }];
    } else {
        %orig;
    }
}

%end

%hook AWEPlayInteractionUserAvatarFollowController
- (void)onFollowViewClicked:(UITapGestureRecognizer *)gesture {
    if (DYYYGetBool(@"DYYYFollowTips")) {
        // 获取用户信息
        AWEUserModel *author = nil;
        NSString *nickname = @"";
        NSString *signature = @"";
        NSString *avatarURL = @"";

        if ([self respondsToSelector:@selector(model)]) {
            id model = [self model];
            if ([model isKindOfClass:NSClassFromString(@"AWEAwemeModel")]) {
                author = [model valueForKey:@"author"];
            }
        }

        if (author) {
            // 获取昵称
            if ([author respondsToSelector:@selector(nickname)]) {
                nickname = [author valueForKey:@"nickname"] ?: @"";
            }

            // 获取签名
            if ([author respondsToSelector:@selector(signature)]) {
                signature = [author valueForKey:@"signature"] ?: @"";
            }

            // 获取头像URL
            if ([author respondsToSelector:@selector(avatarThumb)]) {
                AWEURLModel *avatarThumb = [author valueForKey:@"avatarThumb"];
                if (avatarThumb && avatarThumb.originURLList.count > 0) {
                    avatarURL = avatarThumb.originURLList.firstObject;
                }
            }
        }

        NSMutableString *messageContent = [NSMutableString string];
        if (signature.length > 0) {
            [messageContent appendFormat:@"%@", signature];
        }

        NSString *title = nickname.length > 0 ? nickname : @"关注确认";

        [DYYYBottomAlertView showAlertWithTitle:title
                                        message:messageContent
                                      avatarURL:avatarURL
                               cancelButtonText:@"取消"
                              confirmButtonText:@"关注"
                                   cancelAction:nil
                                    closeAction:nil
                                  confirmAction:^{
                                    DYYYRunDeferredFollowConfirm(^{
                                        %orig(nil);
                                    });
                                  }];
    } else {
        %orig;
    }
}

%end

static BOOL DYYYIsFollowRelationToastText(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) {
        return NO;
    }
    return [text containsString:@"已取消关注"] || [text containsString:@"关注成功"] || [text isEqualToString:@"已关注"] ||
           [text containsString:@"取消关注成功"];
}

// 统一到视频页「已取消关注」高度：安全区顶部 + 76pt（对齐用户参考图1）
static const CGFloat kDYYYFollowToastTopOffset = 76.0;

static UIWindow *DYYYToastReferenceWindow(void) {
    UIWindow *window = [DYYYUtils getActiveWindow];
    if (!window) {
        window = UIApplication.sharedApplication.windows.firstObject;
    }
    return window;
}

static CGPoint DYYYTopToastCenterPointInView(UIView *view) {
    UIWindow *window = DYYYToastReferenceWindow();
    if (!window) {
        return CGPointMake(UIScreen.mainScreen.bounds.size.width / 2.0, kDYYYFollowToastTopOffset);
    }

    CGFloat safeTop = 0.0;
    if (@available(iOS 11.0, *)) {
        safeTop = window.safeAreaInsets.top;
    }
    CGPoint windowPoint = CGPointMake(CGRectGetMidX(window.bounds), safeTop + kDYYYFollowToastTopOffset);

    if (view && view != window) {
        return [view convertPoint:windowPoint fromView:window];
    }
    return windowPoint;
}

%hook DUXToast
+ (void)showText:(NSString *)text {
    if (DYYYIsFollowRelationToastText(text) && [self respondsToSelector:@selector(showText:withCenterPoint:)]) {
        [self showText:text withCenterPoint:DYYYTopToastCenterPointInView(nil)];
        return;
    }
    %orig;
}

+ (void)showText:(NSString *)text withCenterPoint:(CGPoint)centerPoint {
    if (DYYYIsFollowRelationToastText(text)) {
        centerPoint = DYYYTopToastCenterPointInView(nil);
    }
    %orig(text, centerPoint);
}

+ (void)showText:(NSString *)text onView:(UIView *)view {
    if (DYYYIsFollowRelationToastText(text) && [self respondsToSelector:@selector(showText:onView:withCenterPoint:)]) {
        [self showText:text onView:view withCenterPoint:DYYYTopToastCenterPointInView(view)];
        return;
    }
    %orig;
}

+ (void)showText:(NSString *)text onView:(UIView *)view withCenterPoint:(CGPoint)centerPoint {
    if (DYYYIsFollowRelationToastText(text)) {
        centerPoint = DYYYTopToastCenterPointInView(view);
    }
    %orig(text, view, centerPoint);
}

- (void)show {
    NSString *text = nil;
    if ([self respondsToSelector:@selector(text)]) {
        text = [(id)self text];
    }
    if (DYYYIsFollowRelationToastText(text) && [self respondsToSelector:@selector(showWithCenterPoint:)]) {
        [(id)self showWithCenterPoint:DYYYTopToastCenterPointInView(nil)];
        return;
    }
    %orig;
}

- (void)showOnView:(UIView *)view {
    NSString *text = nil;
    if ([self respondsToSelector:@selector(text)]) {
        text = [(id)self text];
    }
    if (DYYYIsFollowRelationToastText(text) && [self respondsToSelector:@selector(showOnView:withCenterPoint:)]) {
        [(id)self showOnView:view withCenterPoint:DYYYTopToastCenterPointInView(view)];
        return;
    }
    %orig;
}

- (void)showWithCenterPoint:(CGPoint)centerPoint {
    NSString *text = nil;
    if ([self respondsToSelector:@selector(text)]) {
        text = [(id)self text];
    }
    if (DYYYIsFollowRelationToastText(text)) {
        centerPoint = DYYYTopToastCenterPointInView(nil);
    }
    %orig(centerPoint);
}

- (void)showOnView:(UIView *)view withCenterPoint:(CGPoint)centerPoint {
    NSString *text = nil;
    if ([self respondsToSelector:@selector(text)]) {
        text = [(id)self text];
    }
    if (DYYYIsFollowRelationToastText(text)) {
        centerPoint = DYYYTopToastCenterPointInView(view);
    }
    %orig(view, centerPoint);
}
%end

static BOOL DYYYProfileFollowConfirmIsShowing = NO;

static id DYYYUserModelFromProfileHeaderContext(id headerContext) {
    if (!headerContext) {
        return nil;
    }
    if ([headerContext respondsToSelector:@selector(userModel)]) {
        return [headerContext userModel];
    }
    return nil;
}

static void DYYYShowProfileFollowGlassConfirm(id user, void (^confirmAction)(void)) {
    if (!confirmAction || DYYYProfileFollowConfirmIsShowing) {
        return;
    }

    NSString *nickname = @"";
    NSString *signature = @"";
    if (user) {
        if ([user respondsToSelector:@selector(nickname)]) {
            nickname = [user valueForKey:@"nickname"] ?: @"";
        }
        if ([user respondsToSelector:@selector(signature)]) {
            signature = [user valueForKey:@"signature"] ?: @"";
        }
    }

    NSString *title = nickname.length > 0 ? nickname : @"关注确认";
    NSString *message = signature.length > 0 ? signature : @"确定要关注该用户吗？";

    DYYYProfileFollowConfirmIsShowing = YES;
    [DYYYGlassConfirmView showWithTitle:title
                                message:message
                       cancelButtonText:@"取消"
                      confirmButtonText:@"确定"
                            cancelAction:^{
                              DYYYProfileFollowConfirmIsShowing = NO;
                            }
                           confirmAction:^{
                              DYYYProfileFollowConfirmIsShowing = NO;
                              DYYYRunDeferredFollowConfirm(confirmAction);
                            }];
}

%hook AWEProfileFollowAreaFollowComponent
- (void)handleFollowEventWithHeaderContext:(id)headerContext
                               enterMethod:(id)enterMethod
                             fromTopButton:(BOOL)fromTopButton
                                completion:(id)completion {
    if (DYYYGetBool(@"DYYYFollowTips")) {
        id user = DYYYUserModelFromProfileHeaderContext(headerContext);
        DYYYShowProfileFollowGlassConfirm(user, ^{
          %orig(headerContext, enterMethod, fromTopButton, completion);
        });
        return;
    }

    %orig;
}
%end

%hook AWEProfileHeaderFollowAreaCell
- (void)p_follow:(id)sender {
    if (DYYYGetBool(@"DYYYFollowTips")) {
        id user = DYYYUserModelFromProfileHeaderContext(self.context);
        DYYYShowProfileFollowGlassConfirm(user, ^{
          %orig(sender);
        });
        return;
    }

    %orig;
}

- (void)followUser {
    if (DYYYGetBool(@"DYYYFollowTips")) {
        id user = DYYYUserModelFromProfileHeaderContext(self.context);
        DYYYShowProfileFollowGlassConfirm(user, ^{
          %orig;
        });
        return;
    }

    %orig;
}
%end

%hook AWEFeedTopBarContainer
- (void)didMoveToSuperview {
    %orig;
    applyTopBarTransparency(self);
}
- (void)setAlpha:(CGFloat)alpha {
    NSString *transparentValue = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYTopBarTransparent"];
    if (transparentValue && transparentValue.length > 0) {
        CGFloat alphaValue = [transparentValue floatValue];
        if (alphaValue >= 0.0 && alphaValue <= 1.0) {
            CGFloat finalAlpha = (alphaValue < 0.011) ? 0.011 : alphaValue;
            %orig(finalAlpha);
        } else {
            %orig(1.0);
        }
    } else {
        %orig(1.0);
    }
}
%end

// 设置修改顶栏标题
%hook AWEHPTopTabItemTextContentView

- (void)layoutSubviews {
    %orig;
    NSDictionary<NSString *, NSString *> *titleMapping = DYYYTopTabTitleMapping();
    if (titleMapping.count == 0) {
        return;
    }

    NSString *accessibilityLabel = nil;
    if ([self.superview respondsToSelector:@selector(accessibilityLabel)]) {
        accessibilityLabel = self.superview.accessibilityLabel;
    }
    if (accessibilityLabel.length == 0) {
        return;
    }

    NSString *newTitle = titleMapping[accessibilityLabel];
    if (newTitle.length == 0) {
        return;
    }

    if ([self respondsToSelector:@selector(setContentText:)]) {
        [self setContentText:newTitle];
    } else {
        [self setValue:newTitle forKey:@"contentText"];
    }
}

%end

%hook AWEDanmakuContentLabel
- (void)setTextColor:(UIColor *)textColor {
    if (DYYYGetBool(@"DYYYEnableDanmuColor")) {
        NSString *danmuColor = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYDanmuColor"];
        if (DYYYGetBool(@"DYYYDanmuRainbowRotating")) {
            danmuColor = @"rainbow_rotating";
        }
        [DYYYUtils applyColorSettingsToLabel:self colorHexString:danmuColor];
    } else {
        %orig(textColor);
    }
}

- (void)setStrokeWidth:(double)strokeWidth {
    if (DYYYGetBool(@"DYYYEnableDanmuColor")) {
        %orig(FLT_MIN);
    } else {
        %orig(strokeWidth);
    }
}

- (void)setStrokeColor:(UIColor *)strokeColor {
    if (DYYYGetBool(@"DYYYEnableDanmuColor")) {
        %orig(nil);
    } else {
        %orig(strokeColor);
    }
}

%end

%hook XIGDanmakuPlayerView

- (id)initWithFrame:(CGRect)frame {
    id orig = %orig;

    ((UIView *)orig).tag = DYYY_IGNORE_GLOBAL_ALPHA_TAG;

    return orig;
}

- (void)setAlpha:(CGFloat)alpha {
    if (DYYYGetBool(@"DYYYCommentShowDanmaku") && alpha == 0.0) {
        return;
    } else {
        %orig(alpha);
    }
}

%end

%hook DDanmakuPlayerView

- (void)setAlpha:(CGFloat)alpha {
    if (DYYYGetBool(@"DYYYCommentShowDanmaku") && alpha == 0.0) {
        return;
    } else {
        %orig(alpha);
    }
}

%end

%hook AWEFeedAnchorPOIConfig

+ (BOOL)hasAnchorViewDataWithAwemeModelForFeed:(id)awemeModel extraInfo:(id)extraInfo {
    if (DYYYGetBool(@"DYYYHideLocation")) {
        return NO;
    }
    return %orig(awemeModel, extraInfo);
}

%end

%hook AWEFeedAnchorPOITradeConfig

+ (BOOL)hasAnchorViewDataWithAwemeModelForFeed:(id)awemeModel extraInfo:(id)extraInfo {
    if (DYYYGetBool(@"DYYYHideLocation")) {
        return NO;
    }
    return %orig(awemeModel, extraInfo);
}

%end

static char kDYYYFeedLocationContainerManagedHiddenKey;
static char kDYYYFeedLocationContainerOriginalHiddenKey;
static char kDYYYFeedAnchorArrangedManagedHiddenKey;
static char kDYYYFeedAnchorArrangedOriginalHiddenKey;

static void DYYYApplyPlayInteractionElementLayout(UIView *view, NSString *fallbackClassName);
static void DYYYSyncHiddenFeedAnchorArrangedView(UIView *inner);

%hook AWEFeedAnchorContainerView

- (void)layoutSubviews {
    %orig;

    BOOL containsLocationAnchor = NO;
    Class poiEntryClass = NSClassFromString(@"AWEPOIEntryAnchorView");
    Class poiTradeEntryClass = NSClassFromString(@"AWEPOITradeEntryAnchorView");
    if ((poiEntryClass && [DYYYUtils containsSubviewOfClass:poiEntryClass inContainer:self]) ||
        (poiTradeEntryClass && [DYYYUtils containsSubviewOfClass:poiTradeEntryClass inContainer:self])) {
        containsLocationAnchor = YES;
    }

    if (!containsLocationAnchor) {
        Class templateAnchorV2Class = NSClassFromString(@"AWEFeedTemplateAnchorViewV2");
        NSArray<UIView *> *templateAnchorViews = [DYYYUtils findAllSubviewsOfClass:templateAnchorV2Class inContainer:self];
        for (AWEFeedTemplateAnchorViewV2 *templateAnchorView in templateAnchorViews) {
            AWECodeGenCommonAnchorBasicInfoModel *anchorInfo = templateAnchorView.templateAnchorInfo;
            if ([anchorInfo.name isEqualToString:@"poi_poi"]) {
                containsLocationAnchor = YES;
                break;
            }
        }
    }

    NSNumber *managedHidden = objc_getAssociatedObject(self, &kDYYYFeedLocationContainerManagedHiddenKey);
    if (DYYYGetBool(@"DYYYHideLocation") && containsLocationAnchor) {
        if (![managedHidden boolValue]) {
            objc_setAssociatedObject(self, &kDYYYFeedLocationContainerOriginalHiddenKey, @(self.hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, &kDYYYFeedLocationContainerManagedHiddenKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        self.hidden = YES;
        return;
    }

    DYYYSyncHiddenFeedAnchorArrangedView(self);
    if (DYYYGetBool(@"DYYYHideFeedAnchorContainer")) {
        return;
    }

    if ([managedHidden boolValue]) {
        NSNumber *originalHidden = objc_getAssociatedObject(self, &kDYYYFeedLocationContainerOriginalHiddenKey);
        objc_setAssociatedObject(self, &kDYYYFeedLocationContainerManagedHiddenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &kDYYYFeedLocationContainerOriginalHiddenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        self.hidden = originalHidden ? originalHidden.boolValue : NO;
    }

    // 定位/特效锚点未必是左侧栏的直接子项，这里补一次跟随昵称的缩放与 Y 轴
    UIViewController *anchorViewController = [DYYYUtils firstAvailableViewControllerFromView:self];
    if ([anchorViewController isKindOfClass:%c(AWEPlayInteractionViewController)]) {
        DYYYApplyPlayInteractionElementLayout(self, @"AWEPlayInteractionAnchorElement");
    }
}

%end

%hook AWEMarkView

- (void)layoutSubviews {
    %orig;

    Class poiConfigClass = NSClassFromString(@"AWEFeedAnchorPOIConfig");
    Class poiTradeConfigClass = NSClassFromString(@"AWEFeedAnchorPOITradeConfig");
    SEL feedVisibilitySelector = @selector(hasAnchorViewDataWithAwemeModelForFeed:extraInfo:);
    BOOL supportsPOIConfigVisibility =
        (poiConfigClass && class_getClassMethod(poiConfigClass, feedVisibilitySelector)) ||
        (poiTradeConfigClass && class_getClassMethod(poiTradeConfigClass, feedVisibilitySelector));
    if (DYYYGetBool(@"DYYYHideLocation") && !supportsPOIConfigVisibility) {
        self.hidden = YES;
        return;
    }
}

%end

%group DYYYSettingsGesture

%hook UIWindow
- (instancetype)initWithFrame:(CGRect)frame {
    UIWindow *window = %orig(frame);
    if (window) {
        UILongPressGestureRecognizer *doubleFingerLongPressGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleDoubleFingerLongPressGesture:)];
        doubleFingerLongPressGesture.numberOfTouchesRequired = 2;
        [window addGestureRecognizer:doubleFingerLongPressGesture];
    }
    return window;
}

%new
- (void)handleDoubleFingerLongPressGesture:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        UIViewController *rootViewController = self.rootViewController;
        if (rootViewController) {
            UIViewController *settingVC = [[DYYYSettingViewController alloc] init];

            if (settingVC) {
                BOOL isIPad = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad;
                if (@available(iOS 15.0, *)) {
                    if (!isIPad) {
                        settingVC.modalPresentationStyle = UIModalPresentationPageSheet;
                    } else {
                        settingVC.modalPresentationStyle = UIModalPresentationFullScreen;
                    }
                } else {
                    settingVC.modalPresentationStyle = UIModalPresentationFullScreen;
                }

                if (settingVC.modalPresentationStyle == UIModalPresentationFullScreen) {
                    UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
                    [closeButton setTitle:@"关闭" forState:UIControlStateNormal];
                    closeButton.translatesAutoresizingMaskIntoConstraints = NO;

                    [settingVC.view addSubview:closeButton];

                    [NSLayoutConstraint activateConstraints:@[
                        [closeButton.trailingAnchor constraintEqualToAnchor:settingVC.view.trailingAnchor constant:-10],
                        [closeButton.topAnchor constraintEqualToAnchor:settingVC.view.topAnchor constant:40], [closeButton.widthAnchor constraintEqualToConstant:80],
                        [closeButton.heightAnchor constraintEqualToConstant:40]
                    ]];

                    [closeButton addTarget:self action:@selector(closeSettings:) forControlEvents:UIControlEventTouchUpInside];
                }

                UIView *handleBar = [[UIView alloc] init];
                handleBar.backgroundColor = [UIColor whiteColor];
                handleBar.layer.cornerRadius = 2.5;
                handleBar.translatesAutoresizingMaskIntoConstraints = NO;
                [settingVC.view addSubview:handleBar];

                [NSLayoutConstraint activateConstraints:@[
                    [handleBar.centerXAnchor constraintEqualToAnchor:settingVC.view.centerXAnchor], [handleBar.topAnchor constraintEqualToAnchor:settingVC.view.topAnchor constant:8],
                    [handleBar.widthAnchor constraintEqualToConstant:40], [handleBar.heightAnchor constraintEqualToConstant:5]
                ]];

                [rootViewController presentViewController:settingVC animated:YES completion:nil];
            }
        }
    }
}

%new
- (void)closeSettings:(UIButton *)button {
    [button.superview.window.rootViewController dismissViewControllerAnimated:YES completion:nil];
}

%end

%end

%hook AWEBaseListViewController
- (void)viewDidLayoutSubviews {
    %orig;
    // v102: 搜索页详情元素上移 60（递归查找，只对搜索入口生效）
    {
        NSString *refer = @"";
        @try {
            id ctx = [self valueForKey:@"context"];
            if (ctx) {
                @try { refer = [NSString stringWithFormat:@"%@", [ctx valueForKey:@"referString"]]; } @catch (NSException *e) {}
            }
        } @catch (NSException *e) {}
        
        BOOL fromSearch = [refer containsString:@"search"];
        
        if (fromSearch) {
            // 递归查找 AWEElementStackView 和 AWEPlayInteractionProgressContainerView
            UIView *stackView = nil;
            UIView *progressView = nil;
            NSMutableArray *queue = [NSMutableArray arrayWithObject:self.view];
            int depth = 0;
            while (queue.count > 0 && depth++ < 800) {
                UIView *v = queue.firstObject;
                [queue removeObjectAtIndex:0];
                NSString *cls = NSStringFromClass([v class]);
                if (!stackView && [cls isEqualToString:@"AWEElementStackView"]) {
                    stackView = v;
                }
                if (!progressView && [cls isEqualToString:@"AWEPlayInteractionProgressContainerView"]) {
                    progressView = v;
                }
                if (stackView && progressView) break;
                [queue addObjectsFromArray:v.subviews];
            }
            
            if (stackView && stackView.frame.origin.y > 100.0) {
                stackView.transform = CGAffineTransformMakeTranslation(0, -60);
            }
            if (progressView && progressView.frame.origin.y > 100.0) {
                progressView.transform = CGAffineTransformMakeTranslation(0, -60);
            }
        }
    }

    if (DYYYGetBool(@"DYYYHideVideoAIParse")) {
        DYYYHideVideoAIParseBar(self.view);
    }

    if (self.view.window && !self.view.hidden) {
        dyyyInteractionViewVisible = YES;
        dyyyActivePlaybackInteractionController = self;
        DYYYEnsureFloatSpeedButton(self);
        reloadClearButtonConfiguration();
    } else {
        updateSpeedButtonVisibility();
        updateClearButtonVisibility();
    }

    UIWindow *keyWindow = [DYYYUtils getActiveWindow];
    if (keyWindow && keyWindow.safeAreaInsets.bottom == 0) {
        return;
    }

    if (!DYYYGetBool(@"DYYYEnableFullScreen")) {
        return;
    }

    UIViewController *directParentVC = self.parentViewController;
    UIViewController *parentVC = directParentVC;
    int maxIterations = 3;
    int count = 0;

    while (parentVC && count < maxIterations) {
        if ([parentVC isKindOfClass:%c(AFDPlayRemoteFeedTableViewController)]) {
            return;
        }
        parentVC = parentVC.parentViewController;
        count++;
    }

    BOOL isShowingRelatedMixViewController = NO;
    UIViewController *sceneParentVC = directParentVC;
    int sceneDepth = 0;
    while (sceneParentVC && sceneDepth < 8) {
        if ([sceneParentVC isKindOfClass:%c(AWEMixVideoPanelDetailTableViewController)]) {
            AWEMixVideoPanelDetailTableViewController *mixDetailVC = (AWEMixVideoPanelDetailTableViewController *)sceneParentVC;
            isShowingRelatedMixViewController = mixDetailVC.isShowingRelatedMixViewController;
            break;
        }
        sceneParentVC = sceneParentVC.parentViewController;
        sceneDepth++;
    }

    if (!self.view.superview) {
        return;
    }

    CGRect frame = self.view.frame;
    CGFloat screenWidth = [UIScreen mainScreen].bounds.size.width;
    CGFloat superviewHeight = self.view.superview.frame.size.height;

    if (frame.size.width != screenWidth && frame.size.height < superviewHeight) {
        return;
    }

    NSString *currentReferString = self.referString;

    BOOL useFullHeight = [currentReferString isEqualToString:@"general_search"] || [currentReferString isEqualToString:@"search_result"] || [currentReferString isEqualToString:@"search_ecommerce"] ||
                         [currentReferString isEqualToString:@"close_friends_moment"] || [currentReferString isEqualToString:@"offline_mode"] || [currentReferString isEqualToString:@"challenge"] ||
                         [currentReferString isEqualToString:@"general_search_scan"] || currentReferString == nil || isShowingRelatedMixViewController;

    if (!useFullHeight && [currentReferString isEqualToString:@"co_play_watch"]) {
        Class richContentVCClass = NSClassFromString(@"AWEFriendsImpl.RichContentNewListViewController");
        if (richContentVCClass && [directParentVC isKindOfClass:richContentVCClass]) {
            useFullHeight = YES;
        }
    }

    if (!useFullHeight && [currentReferString isEqualToString:@"chat"]) {
        AWEAwemeModel *currentModel = self.model;
        BOOL isLiveModel = currentModel && (([currentModel respondsToSelector:@selector(isLive)] && currentModel.isLive) ||
                                            ([currentModel respondsToSelector:@selector(cellRoom)] && currentModel.cellRoom != nil) ||
                                            ([currentModel respondsToSelector:@selector(videoFeedTag)] && [currentModel.videoFeedTag isEqualToString:@"直播中"]));

        // 私信视频的信息区依赖完整高度；直播内容保持原布局，避免影响直播文案位置。
        if (!isLiveModel) {
            useFullHeight = YES;
        }
    }

    // DYYY修复：全屏开关打开时，强制走 if 分支，UI层撑满852
    // 详情页原生走 else 是 732，比推荐页少120pt，这里统一到 852
    // v92: UI 层保留底栏 60pt，进度条不再贴屏底
    frame.size.height = superviewHeight - 60.0;

    if (fabs(frame.size.height - self.view.frame.size.height) > 0.5) {
        self.view.frame = frame;
    }

}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    if (dyyyActivePlaybackInteractionController == self) {
        __weak AWEPlayInteractionViewController *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
          AWEPlayInteractionViewController *strongSelf = weakSelf;
          AWEPlayInteractionViewController *replacementController =
              DYYYResolvePlaybackInteractionController(nil, dyyyCurrentSpeedAweme, YES);
          if (replacementController == strongSelf) {
              replacementController = nil;
          }
          dyyyActivePlaybackInteractionController = replacementController;
          BOOL hasVisibleInteractionController = replacementController != nil;
          dyyyInteractionViewVisible = hasVisibleInteractionController;
          dyyyCommentViewVisible = strongSelf.isCommentVCShowing;
          updateSpeedButtonVisibility();
          updateClearButtonVisibility();
        });
    }
}

%new
- (void)speedButtonTapped:(UIButton *)sender {
    [(FloatingSpeedButton *)sender resetFadeTimer];
    NSArray *speeds = getSpeedOptions();
    if (speeds.count == 0) {
        return;
    }

    NSInteger newIndex = (getCurrentSpeedIndex() + 1) % speeds.count;
    setCurrentSpeedIndex(newIndex);
    float newSpeed = [speeds[(NSUInteger)newIndex] floatValue];
    if (!isfinite(newSpeed) || newSpeed <= 0.0f) {
        newSpeed = 1.0f;
    }
    updateSpeedButtonUI();

    if (!DYYYApplyPlaybackSpeedThroughInteractionController(self, newSpeed)) {
        [DYYYUtils showToast:@"无法找到视频控制器"];
    }
}

%new
- (void)buttonTouchDown:(UIButton *)sender {
    [UIView animateWithDuration:0.1
                     animations:^{
                       sender.alpha = 0.7;
                       sender.transform = CGAffineTransformMakeScale(0.95, 0.95);
                     }];
}

%new
- (void)buttonTouchUp:(UIButton *)sender {
    [UIView animateWithDuration:0.1
                     animations:^{
                       sender.alpha = 1.0;
                       sender.transform = CGAffineTransformIdentity;
                     }];
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    // AI 解析隐藏：布局完全稳定后执行一次，避免在 layout 过程中改视图导致上移
    if (DYYYGetBool(@"DYYYHideVideoAIParse")) {
        // 延迟一帧，确保所有布局完成
        dispatch_async(dispatch_get_main_queue(), ^{
            DYYYHideVideoAIParseBar(self.view);
        });
    }
}

%end

%hook AWEAwemePlayVideoViewController

- (void)setIsAutoPlay:(BOOL)arg0 {
    %orig(arg0);
    DYYYApplyNormalPlaybackSpeedToPlayerFallback(self);
}

- (void)prepareForDisplay {
    %orig;
    if (!DYYYShouldHandleSpeedFeatures()) {
        return;
    }

    BOOL autoRestoreSpeed = [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYAutoRestoreSpeed"];
    if (isFloatSpeedButtonEnabled && autoRestoreSpeed) {
        setCurrentSpeedIndex(0);
    }
    DYYYApplyNormalPlaybackSpeedToPlayerFallback(self);
    updateSpeedButtonUI();
}

%end

%hook AWEDPlayerFeedPlayerViewController

- (BOOL)enableHDR {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (DYYYGetBool(@"DYYYEnableFullScreen")) {
        // DYYY修复：直接改主视图高度到屏幕高度，并解除裁剪
        // 里面的 TTMetalViewVP 是 clips=0，会自动溢出到 852
        CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
        UIView *vw = self.view;
        if (vw) {
            vw.clipsToBounds = NO;
            if (fabs(CGRectGetHeight(vw.frame) - screenH) > 0.5) {
                CGRect f = vw.frame;
                f.size.height = screenH;
                vw.frame = f;
            }
        }
    }
}

- (void)setIsAutoPlay:(BOOL)arg0 {
    %orig(arg0);
    DYYYApplyNormalPlaybackSpeedToPlayerFallback(self);
}

- (void)prepareForDisplay {
    %orig;
    if (!DYYYShouldHandleSpeedFeatures()) {
        return;
    }
    BOOL autoRestoreSpeed = [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYAutoRestoreSpeed"];
    if (isFloatSpeedButtonEnabled && autoRestoreSpeed) {
        setCurrentSpeedIndex(0);
    }
    DYYYApplyNormalPlaybackSpeedToPlayerFallback(self);
    updateSpeedButtonUI();
}

%end

%hook AWEDPlayerViewController_Merge

- (BOOL)enableHDR {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (DYYYGetBool(@"DYYYEnableFullScreen")) {
        // DYYY修复：直接改主视图高度到屏幕高度，并解除裁剪
        // 里面的 TTMetalViewVP 是 clips=0，会自动溢出到 852
        CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
        UIView *vw = self.view;
        if (vw) {
            vw.clipsToBounds = NO;
            if (fabs(CGRectGetHeight(vw.frame) - screenH) > 0.5) {
                CGRect f = vw.frame;
                f.size.height = screenH;
                vw.frame = f;
            }
        }
    }
}

- (void)setIsAutoPlay:(BOOL)arg0 {
    %orig(arg0);
    DYYYApplyNormalPlaybackSpeedToPlayerFallback(self);
}

- (void)prepareForDisplay {
    %orig;
    if (!DYYYShouldHandleSpeedFeatures()) {
        return;
    }
    BOOL autoRestoreSpeed = [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYAutoRestoreSpeed"];
    if (isFloatSpeedButtonEnabled && autoRestoreSpeed) {
        setCurrentSpeedIndex(0);
    }
    DYYYApplyNormalPlaybackSpeedToPlayerFallback(self);
    updateSpeedButtonUI();
}

%end

static char kDYYYFeedTableOriginalHeightGapKey;
static char kDYYYFeedTableFullScreenAppliedKey;

%hook AWEFeedTableView
- (void)layoutSubviews {
    %orig;

    UIView *superview = self.superview;
    if (!superview) {
        return;
    }

    BOOL enableFullScreen = DYYYGetBool(@"DYYYEnableFullScreen");
    BOOL fullScreenApplied = [objc_getAssociatedObject(self, &kDYYYFeedTableFullScreenAppliedKey) boolValue];
    CGFloat superviewHeight = CGRectGetHeight(superview.bounds);

    if (!enableFullScreen) {
        if (fullScreenApplied) {
            NSNumber *storedGap = objc_getAssociatedObject(self, &kDYYYFeedTableOriginalHeightGapKey);
            CGFloat originalHeightGap = storedGap ? MAX(storedGap.doubleValue, 0.0) : 0.0;
            CGFloat restoredHeight = MAX(superviewHeight - originalHeightGap, 0.0);
            CGRect frame = self.frame;
            if (fabs(CGRectGetHeight(frame) - restoredHeight) > 0.5) {
                frame.size.height = restoredHeight;
                self.frame = frame;
            }
            objc_setAssociatedObject(self, &kDYYYFeedTableOriginalHeightGapKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, &kDYYYFeedTableFullScreenAppliedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }

    if (!fullScreenApplied) {
        CGFloat originalHeightGap = MAX(superviewHeight - CGRectGetHeight(self.frame), 0.0);
        objc_setAssociatedObject(self, &kDYYYFeedTableOriginalHeightGapKey, @(originalHeightGap), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &kDYYYFeedTableFullScreenAppliedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (fabs(CGRectGetHeight(self.frame) - superviewHeight) > 0.5) {
        CGRect frame = self.frame;
        frame.size.height = [UIScreen mainScreen].bounds.size.height;
        self.frame = frame;
    }
}
%end

%hook AWEFeedTableViewCell
- (void)prepareForReuse {
    if (hideButton && hideButton.isElementsHidden) {
        [hideButton hideUIElements];
    }
    %orig;
}

- (void)layoutSubviews {
    %orig;
    if (hideButton && hideButton.isElementsHidden) {
        [hideButton hideUIElements];
    }
}
%end

%hook AWEFeedViewCell
- (void)layoutSubviews {
    if (hideButton && hideButton.isElementsHidden) {
        [hideButton hideUIElements];
    }
    %orig;
}

- (void)setModel:(id)model {
    if (hideButton && hideButton.isElementsHidden) {
        [hideButton hideUIElements];
    }
    %orig;
}
%end

%hook UIViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    isAppInTransition = YES;
    if (hideButton && hideButton.isElementsHidden) {
        [hideButton hideUIElements];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      isAppInTransition = NO;
    });
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    isAppInTransition = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      isAppInTransition = NO;
    });
}
%end

%hook AFDPureModePageContainerViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    isPureViewVisible = YES;
    updateClearButtonVisibility();
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    isPureViewVisible = NO;
    updateClearButtonVisibility();
}
%end

%hook AWEFeedContainerViewController
- (void)aweme:(id)arg1 currentIndexWillChange:(NSInteger)arg2 {
    if (hideButton && hideButton.isElementsHidden) {
        [hideButton hideUIElements];
    }
    %orig;
}

- (void)aweme:(id)arg1 currentIndexDidChange:(NSInteger)arg2 {
    if (hideButton && hideButton.isElementsHidden) {
        [hideButton hideUIElements];
    }
    %orig;
    // This callback is the feed's committed index transition. Do not validate it
    // against the controller hierarchy: old/new controllers can overlap briefly
    // after a real switch, causing the old controller to win the visibility score.
    DYYYHandleCurrentAwemeChanged(arg1);
}

- (void)viewWillLayoutSubviews {
    %orig;
    if (hideButton && hideButton.isElementsHidden) {
        [hideButton hideUIElements];
    }
}
%end

%hook AWEFeedTableViewController

- (void)setCurrentPlayIndex:(NSInteger)index {
    %orig(index);
    DYYYHandleCommittedSpeedAwemeChanged([self currentAweme]);
}

- (void)playVideo:(id)video {
    %orig(video);
    DYYYHandleCommittedSpeedAwemeChanged([self currentAweme] ?: video);
}

- (void)playVideoOnScrollDidEnd {
    %orig;
    DYYYHandleCommittedSpeedAwemeChanged([self currentAweme]);
}

%end

static id dyyyWindowKeyObserverToken = nil;
static id dyyyDidBecomeActiveToken = nil;
static id dyyyWillResignActiveToken = nil;
static void *DYYYGlobalTransparencyContext = &DYYYGlobalTransparencyContext;

static void DYYYRemoveAppLifecycleObservers(void) {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    if (dyyyWindowKeyObserverToken) {
        [center removeObserver:dyyyWindowKeyObserverToken];
        dyyyWindowKeyObserverToken = nil;
    }
    if (dyyyDidBecomeActiveToken) {
        [center removeObserver:dyyyDidBecomeActiveToken];
        dyyyDidBecomeActiveToken = nil;
    }
    if (dyyyWillResignActiveToken) {
        [center removeObserver:dyyyWillResignActiveToken];
        dyyyWillResignActiveToken = nil;
    }
}

%hook AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    BOOL result = %orig;
    initTargetClassNames();

    updateGlobalTransparencyCache();

    [[NSUserDefaults standardUserDefaults] addObserver:(NSObject *)self forKeyPath:kDYYYGlobalTransparencyKey options:NSKeyValueObservingOptionNew context:DYYYGlobalTransparencyContext];

    reloadClearButtonConfiguration();
    DYYYRemoveAppLifecycleObservers();

    dyyyWindowKeyObserverToken = [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeKeyNotification
                                                                                   object:nil
                                                                                    queue:[NSOperationQueue mainQueue]
                                                                               usingBlock:^(NSNotification *_Nonnull notification) {
                                                                                 reloadClearButtonConfiguration();
                                                                               }];

    dyyyDidBecomeActiveToken = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                                                 object:nil
                                                                                  queue:[NSOperationQueue mainQueue]
                                                                             usingBlock:^(NSNotification *_Nonnull notification) {
                                                                               isAppActive = YES;
                                                                               reloadClearButtonConfiguration();
                                                                             }];

    dyyyWillResignActiveToken = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillResignActiveNotification
                                                                                  object:nil
                                                                                   queue:[NSOperationQueue mainQueue]
                                                                              usingBlock:^(NSNotification *_Nonnull notification) {
                                                                                isAppActive = NO;
                                                                                updateClearButtonVisibility();
                                                                              }];

    return result;
}

- (void)applicationWillTerminate:(UIApplication *)application {
    DYYYRemoveAppLifecycleObservers();
    %orig;
}

- (void)dealloc {
    DYYYRemoveAppLifecycleObservers();
    @try {
        [[NSUserDefaults standardUserDefaults] removeObserver:(NSObject *)self forKeyPath:kDYYYGlobalTransparencyKey context:DYYYGlobalTransparencyContext];
    } @catch (NSException *exception) {
        NSLog(@"[DYYY] KVO removeObserver failed: %@", exception);
    }
    %orig;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey, id> *)change context:(void *)context {
    if (context == DYYYGlobalTransparencyContext) {
        dispatch_async(dispatch_get_main_queue(), ^{
          updateGlobalTransparencyCache();
          [[NSNotificationCenter defaultCenter] postNotificationName:kDYYYGlobalTransparencyDidChangeNotification object:nil];
        });
    } else {
        %orig(keyPath, object, change, context);
    }
}

%end

%hook AWELiveNewPreStreamViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    [DYYYLivePreStreamLayoutCoordinator activateLayoutForController:self];
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    [DYYYLivePreStreamLayoutCoordinator activateLayoutForController:self];
}

- (void)viewDidLayoutSubviews {
    %orig;
    [DYYYLivePreStreamLayoutCoordinator scheduleUpdateForController:self];
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    [DYYYLivePreStreamLayoutCoordinator restoreLayoutForController:self];
}

%end

%hook AWEElementStackView

- (void)setAlpha:(CGFloat)alpha {
    BOOL isApplyingGlobal = (dyyyGlobalTransparencyMutationDepth > 0);
    if (!isApplyingGlobal) {
        objc_setAssociatedObject(self, &kDYYYGlobalTransparencyBaseAlphaKey, @(alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // 纯净模式功能
    static AWMSafeDispatchTimer *pureModeTimer = nil;
    static int attempts = 0;
    static BOOL pureModeSet = NO;
    static BOOL pureModeTimerStarted = NO;
    static NSUInteger pureModeGeneration = 0;
    if (DYYYGetBool(@"DYYYEnablePure")) {
        %orig(0.0);
        if (pureModeSet) {
            return;
        }
        if (!pureModeTimer) {
            pureModeTimer = [[AWMSafeDispatchTimer alloc] init];
        }
        // Guard before isRunning: startWithInterval schedules asynchronously, so
        // repeated setAlpha (fullscreen/status-bar layout churn) can otherwise
        // enqueue many overlapping starts while running is still NO.
        if (!pureModeTimerStarted) {
            pureModeTimerStarted = YES;
            attempts = 0;
            NSUInteger generation = ++pureModeGeneration;
            __weak AWMSafeDispatchTimer *weakTimer = pureModeTimer;
            [pureModeTimer startWithInterval:0.5
                                      leeway:0.1
                                       queue:dispatch_get_main_queue()
                                     repeats:YES
                                     handler:^{
                                       if (generation != pureModeGeneration) {
                                           return;
                                       }
                                       AWMSafeDispatchTimer *strongTimer = weakTimer;
                                       if (!strongTimer) {
                                           return;
                                       }
                                       UIWindow *keyWindow = [DYYYUtils getActiveWindow];
                                       if (keyWindow && keyWindow.rootViewController) {
                                           UIViewController *feedVC = [DYYYUtils findViewControllerOfClass:NSClassFromString(@"AWEFeedTableViewController")
                                                                                          inViewController:keyWindow.rootViewController];
                                           if (feedVC) {
                                               [feedVC setValue:@YES forKey:@"pureMode"];
                                               pureModeSet = YES;
                                               attempts = 0;
                                               pureModeGeneration++;
                                               pureModeTimerStarted = NO;
                                               if (pureModeTimer == strongTimer) {
                                                   pureModeTimer = nil;
                                               }
                                               [strongTimer cancel];
                                               return;
                                           }
                                       }
                                       attempts++;
                                       if (attempts >= 10) {
                                           attempts = 0;
                                           pureModeGeneration++;
                                           pureModeTimerStarted = NO;
                                           if (pureModeTimer == strongTimer) {
                                               pureModeTimer = nil;
                                           }
                                           [strongTimer cancel];
                                       }
                                     }];
        }
        return;
    }

    // 清理纯净模式的残留状态
    if (pureModeTimer) {
        AWMSafeDispatchTimer *timer = pureModeTimer;
        pureModeTimer = nil;
        pureModeTimerStarted = NO;
        pureModeGeneration++;
        [timer cancel];
    }
    attempts = 0;
    pureModeSet = NO;

    // 值守全局透明度
    CGFloat finalAlpha = alpha;
    if (!isApplyingGlobal && self.tag != DYYY_IGNORE_GLOBAL_ALPHA_TAG && gGlobalTransparency != kInvalidAlpha) {
        CGFloat clampedAlpha = MIN(MAX(alpha, 0.0), 1.0);
        finalAlpha = clampedAlpha * gGlobalTransparency;
    }

    // 统一应用透明度
    if (fabs(self.alpha - finalAlpha) >= 0.01) {
        %orig(finalAlpha);
    }
}

- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        [self dyyy_applyGlobalTransparency];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(dyyy_applyGlobalTransparency) name:kDYYYGlobalTransparencyDidChangeNotification object:nil];
    } else {
        [[NSNotificationCenter defaultCenter] removeObserver:self name:kDYYYGlobalTransparencyDidChangeNotification object:nil];
    }
    [DYYYLivePreStreamLayoutCoordinator scheduleUpdateForView:self];
}

- (void)didAddSubview:(UIView *)subview {
    %orig(subview);
    [DYYYLivePreStreamLayoutCoordinator scheduleUpdateForView:self];
}

- (void)willRemoveSubview:(UIView *)subview {
    %orig(subview);
    [DYYYLivePreStreamLayoutCoordinator scheduleUpdateForView:self];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    %orig;
}

- (void)layoutSubviews {
    BOOL insidePlayInteraction = DYYYViewIsInsidePlayInteraction(self);
    // 只清理播放交互层左侧栏。全局 reset 会把作品详情等页面里 element hook 已写好的缩放清掉。
    if (insidePlayInteraction) {
        DYYYResetPlayInteractionLeftStackElementTransforms(self);
    }

    %orig;

    UIViewController *viewController = [DYYYUtils firstAvailableViewControllerFromView:self];

    if ([viewController isKindOfClass:%c(AWELiveNewPreStreamViewController)]) {
        [DYYYLivePreStreamLayoutCoordinator scheduleUpdateForController:viewController];
    }

    if (insidePlayInteraction) {
        NSString *label = self.accessibilityLabel ?: @"";
        BOOL hasAnchor = [DYYYUtils containsSubviewOfClass:NSClassFromString(@"AWEFeedAnchorContainerView") inContainer:self];
        BOOL hasAvatar = [DYYYUtils containsSubviewOfClass:NSClassFromString(@"AWEPlayInteractionUserAvatarView") inContainer:self];

        BOOL isRightStack = ([label isEqualToString:@"right"] || hasAvatar);
        if (!isRightStack) {
            NSArray *subviews = [self.subviews copy];
            for (NSInteger i = (NSInteger)subviews.count - 1; i >= 0; i--) {
                UIView *sub = subviews[i];
                if ([sub respondsToSelector:@selector(elementClassName)]) {
                    NSString *elementClassName = [sub performSelector:@selector(elementClassName)];
                    if ([elementClassName isEqualToString:@"AWEPlayInteractionUserAvatarOptElementElement"]) {
                        isRightStack = YES;
                        break;
                    }
                }
            }
        }

        BOOL hasScalableLeftElement = DYYYStackViewContainsScalableLeftElement(self);

        // 右侧元素的处理逻辑
        if (isRightStack) {
            NSString *scaleValue = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYElementScale"];
            self.transform = CGAffineTransformIdentity;
            if (scaleValue.length > 0) {
                CGFloat scale = [scaleValue floatValue];
                if (scale > 0 && scale != 1.0) {
                    NSArray *subviews = [self.subviews copy];
                    CGFloat ty = 0;
                    for (UIView *view in subviews) {
                        CGFloat viewHeight = view.frame.size.height;
                        ty += (viewHeight - viewHeight * scale) / 2;
                    }
                    CGFloat frameWidth = self.frame.size.width;
                    CGFloat right_tx = (frameWidth - frameWidth * scale) / 2;
                    self.transform = CGAffineTransformMake(scale, 0, 0, scale, right_tx, ty);
                } else {
                    self.transform = CGAffineTransformIdentity;
                }
            }
        }
        // 左侧昵称/文案元素按子元素分别缩放
        else if (hasScalableLeftElement) {
            DYYYApplyPlayInteractionLeftStackElementTransforms(self);
        }
    }
}

- (NSArray<__kindof UIView *> *)arrangedSubviews {
    NSArray *originalSubviews = %orig;
    return originalSubviews;
}

%end

%hook IESLiveStackView

- (void)setAlpha:(CGFloat)alpha {
    BOOL isApplyingGlobal = (dyyyGlobalTransparencyMutationDepth > 0);
    if (!isApplyingGlobal) {
        objc_setAssociatedObject(self, &kDYYYGlobalTransparencyBaseAlphaKey, @(alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    CGFloat finalAlpha = alpha;
    if (!isApplyingGlobal && self.tag != DYYY_IGNORE_GLOBAL_ALPHA_TAG && gGlobalTransparency != kInvalidAlpha) {
        CGFloat clampedAlpha = MIN(MAX(alpha, 0.0), 1.0);
        finalAlpha = clampedAlpha * gGlobalTransparency;
    }

    if (fabs(self.alpha - finalAlpha) >= 0.01) {
        %orig(finalAlpha);
    }
}

- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        [self dyyy_applyGlobalTransparency];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(dyyy_applyGlobalTransparency) name:kDYYYGlobalTransparencyDidChangeNotification object:nil];
    } else {
        [[NSNotificationCenter defaultCenter] removeObserver:self name:kDYYYGlobalTransparencyDidChangeNotification object:nil];
    }
    [DYYYLivePreStreamLayoutCoordinator scheduleUpdateForView:self];
}

- (void)didAddSubview:(UIView *)subview {
    %orig(subview);
    [DYYYLivePreStreamLayoutCoordinator scheduleUpdateForView:self];
}

- (void)willRemoveSubview:(UIView *)subview {
    %orig(subview);
    [DYYYLivePreStreamLayoutCoordinator scheduleUpdateForView:self];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    %orig;
}

- (void)layoutSubviews {
    %orig;

    UIViewController *viewController = [DYYYUtils firstAvailableViewControllerFromView:self];

    if ([viewController isKindOfClass:%c(AWELiveNewPreStreamViewController)]) {
        [DYYYLivePreStreamLayoutCoordinator scheduleUpdateForController:viewController];
    }
}

%end

%hook AWEStoryContainerCollectionView
- (void)layoutSubviews {
    %orig;
    if ([self.subviews count] == 2)
        return;

    // 获取 enableEnterProfile 属性来判断是否是主页
    id enableEnterProfile = [self valueForKey:@"enableEnterProfile"];
    BOOL isHome = (enableEnterProfile != nil && [enableEnterProfile boolValue]);

    // 检查是否在作者主页
    BOOL isAuthorProfile = NO;
    UIResponder *responder = self;
    while ((responder = [responder nextResponder])) {
        if ([NSStringFromClass([responder class]) containsString:@"UserHomeViewController"] || [NSStringFromClass([responder class]) containsString:@"ProfileViewController"]) {
            isAuthorProfile = YES;
            break;
        }
    }

    // 如果不是主页也不是作者主页，直接返回
    if (!isHome && !isAuthorProfile)
        return;

    for (UIView *subview in self.subviews) {
        if ([subview isKindOfClass:[UIView class]]) {
            UIView *nextResponder = (UIView *)subview.nextResponder;

            // 处理主页的情况
            if (isHome && [nextResponder isKindOfClass:%c(AWEPlayInteractionViewController)]) {
                UIViewController *awemeBaseViewController = [nextResponder valueForKey:@"awemeBaseViewController"];
                if (![awemeBaseViewController isKindOfClass:%c(AWEFeedCellViewController)]) {
                    continue;
                }

                CGRect frame = subview.frame;
                if (DYYYGetBool(@"DYYYEnableFullScreen")) {
                    frame.size.height = subview.superview.frame.size.height - gCurrentTabBarHeight;
                    subview.frame = frame;
                }
            }
            // 处理作者主页的情况
            else if (isAuthorProfile) {
                // 检查是否是作品图片
                BOOL isWorkImage = NO;

                // 可以通过检查子视图、标签或其他特性来确定是否是作品图片
                for (UIView *childView in subview.subviews) {
                    if ([NSStringFromClass([childView class]) containsString:@"ImageView"] || [NSStringFromClass([childView class]) containsString:@"ThumbnailView"]) {
                        isWorkImage = YES;
                        break;
                    }
                }

                if (isWorkImage) {
                    // 修复作者主页作品图片上移问题
                    CGRect frame = subview.frame;
                    frame.origin.y += gCurrentTabBarHeight;
                    subview.frame = frame;
                }
            }
        }
    }
}
%end

%hook AFDFastSpeedView

- (void)updateSpeedLockBottomWithText:(NSString *)text Type:(NSInteger)type {
    %orig(DYYYAdjustedNativeLongPressSpeedHint(text), type);
}

- (void)layoutSubviews {
    %orig;

    if (![[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYEnableFullScreen"]) {
        return;
    }

    static char kDYFastSpeedBgKey;
    NSArray *bgViews = objc_getAssociatedObject(self, &kDYFastSpeedBgKey);
    if (!bgViews) {
        NSMutableArray *tmp = [NSMutableArray array];
        for (UIView *subview in self.subviews) {
            if ([subview class] == [UIView class]) {
                [tmp addObject:subview];
            }
        }
        bgViews = [tmp copy];
        objc_setAssociatedObject(self, &kDYFastSpeedBgKey, bgViews, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    for (UIView *view in bgViews) {
        view.backgroundColor = [UIColor clearColor];
    }
}
%end

%hook TTPlayerView

- (void)layoutSubviews {
    %orig;
    UIView *parent = self.superview;
    if (parent) {
        parent.backgroundColor = self.backgroundColor;
    }
}

%end

%hook TTMetalView
- (void)setCenter:(CGPoint)center {
    BOOL shouldAdjust = NO;
    UIView *view = (UIView *)self;
    if (DYYYGetBool(@"DYYYEnableFullScreen")) {
        CGFloat viewWidth = CGRectGetWidth(view.bounds);
        CGFloat screenWidth = [UIScreen mainScreen].bounds.size.width;
        if (viewWidth + 0.5f >= screenWidth) {
            UIViewController *vc = [DYYYUtils firstAvailableViewControllerFromView:view];
            Class playClass = %c(AWEPlayVideoViewController);
            if (playClass && [vc isKindOfClass:playClass]) {
                AWEPlayVideoViewController *playVC = (AWEPlayVideoViewController *)vc;
                AWEAwemeModel *model = playVC.model;
                if ([model respondsToSelector:@selector(isShowLandscapeEntryView)] && model.isShowLandscapeEntryView) {
                    shouldAdjust = YES;
                }
            }
        }
    }

    if (shouldAdjust) {
        CGFloat offset = gCurrentTabBarHeight > 0 ? gCurrentTabBarHeight : originalTabBarHeight;
        if (offset > 0) {
            center.y -= offset * 0.5;
        }
    }

    %orig(center);
}
%end

%hook TTMetalViewNew
- (void)setCenter:(CGPoint)center {
    BOOL shouldAdjust = NO;
    UIView *view = (UIView *)self;
    if (DYYYGetBool(@"DYYYEnableFullScreen")) {
        CGFloat viewWidth = CGRectGetWidth(view.bounds);
        CGFloat screenWidth = [UIScreen mainScreen].bounds.size.width;
        if (viewWidth + 0.5f >= screenWidth) {
            UIViewController *vc = [DYYYUtils firstAvailableViewControllerFromView:view];
            Class playClass = %c(AWEPlayVideoViewController);
            if (playClass && [vc isKindOfClass:playClass]) {
                AWEPlayVideoViewController *playVC = (AWEPlayVideoViewController *)vc;
                AWEAwemeModel *model = playVC.model;
                if ([model respondsToSelector:@selector(isShowLandscapeEntryView)] && model.isShowLandscapeEntryView) {
                    shouldAdjust = YES;
                }
            }
        }
    }

    if (shouldAdjust) {
        CGFloat offset = gCurrentTabBarHeight > 0 ? gCurrentTabBarHeight : originalTabBarHeight;
        if (offset > 0) {
            center.y -= offset * 0.5;
        }
    }

    %orig(center);
}
%end

%hook TTMetalViewVP
- (void)setCenter:(CGPoint)center {
    BOOL shouldAdjust = NO;
    UIView *view = (UIView *)self;
    if (DYYYGetBool(@"DYYYEnableFullScreen")) {
        CGFloat viewWidth = CGRectGetWidth(view.bounds);
        CGFloat screenWidth = [UIScreen mainScreen].bounds.size.width;
        if (viewWidth + 0.5f >= screenWidth) {
            UIViewController *vc = [DYYYUtils firstAvailableViewControllerFromView:view];
            Class playClass = %c(AWEPlayVideoViewController);
            if (playClass && [vc isKindOfClass:playClass]) {
                AWEPlayVideoViewController *playVC = (AWEPlayVideoViewController *)vc;
                AWEAwemeModel *model = playVC.model;
                if ([model respondsToSelector:@selector(isShowLandscapeEntryView)] && model.isShowLandscapeEntryView) {
                    shouldAdjust = YES;
                }
            }
        }
    }

    if (shouldAdjust) {
        CGFloat offset = gCurrentTabBarHeight > 0 ? gCurrentTabBarHeight : originalTabBarHeight;
        if (offset > 0) {
            center.y -= offset * 0.5;
        }
    }

    %orig(center);
}
%end

// 隐藏图片滑条
%hook AWEStoryProgressContainerView
- (void)setCenter:(CGPoint)center {
    UIViewController *vc = [DYYYUtils firstAvailableViewControllerFromView:self];
    BOOL isPureModeImageBrowser = [vc isKindOfClass:NSClassFromString(@"AWEFeedPlayControlImpl.PureModePageCellViewController")];
    if (isPureModeImageBrowser && DYYYGetBool(@"DYYYEnableFullScreen")) {
        NSString *appVersion = [NSBundle mainBundle].infoDictionary[@"CFBundleShortVersionString"];
        BOOL needsLegacyOffset = appVersion.length == 0 || [DYYYUtils compareVersion:appVersion toVersion:@"37.2.0"] == NSOrderedAscending;
        if (needsLegacyOffset && gCurrentTabBarHeight > 0) {
            center.y -= gCurrentTabBarHeight;
        }
    }
    %orig(center);
}

- (BOOL)isHidden {
    BOOL originalValue = %orig;
    BOOL customHide = DYYYGetBool(@"DYYYHideDotsIndicator");
    return originalValue || customHide;
}

- (void)setHidden:(BOOL)hidden {
    BOOL forceHide = DYYYGetBool(@"DYYYHideDotsIndicator");
    %orig(forceHide ? YES : hidden);
}
%end

%hook AWELandscapeFeedEntryView

- (void)setAlpha:(CGFloat)alpha {
    BOOL isApplyingGlobal = (dyyyGlobalTransparencyMutationDepth > 0);
    if (!isApplyingGlobal) {
        objc_setAssociatedObject(self, &kDYYYGlobalTransparencyBaseAlphaKey, @(alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    CGFloat finalAlpha = alpha;
    if (!isApplyingGlobal && self.tag != DYYY_IGNORE_GLOBAL_ALPHA_TAG && gGlobalTransparency != kInvalidAlpha) {
        CGFloat clampedAlpha = MIN(MAX(alpha, 0.0), 1.0);
        finalAlpha = clampedAlpha * gGlobalTransparency;
    }

    if (fabs(self.alpha - finalAlpha) >= 0.01) {
        %orig(finalAlpha);
    }
}

- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        [self dyyy_applyGlobalTransparency];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(dyyy_applyGlobalTransparency) name:kDYYYGlobalTransparencyDidChangeNotification object:nil];
    } else {
        [[NSNotificationCenter defaultCenter] removeObserver:self name:kDYYYGlobalTransparencyDidChangeNotification object:nil];
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    %orig;
}

- (void)layoutSubviews {
    %orig;
    if (DYYYGetBool(@"DYYYRemoveEntry")) {
        [self removeFromSuperview];
        return;
    }
    if (DYYYGetBool(@"DYYYHideEntry")) {
        for (UIView *subview in self.subviews) {
            subview.hidden = YES;
        }
        return;
    }

    if (self.superview) {
        [self.superview bringSubviewToFront:self];
    }

    NSString *scaleValue = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYNicknameScale"];
    CGFloat scale = scaleValue.length > 0 ? [scaleValue floatValue] : 1.0;
    if (scale > 0 && scale != 1.0) {
        self.transform = CGAffineTransformMakeScale(scale, scale);
    } else {
        self.transform = CGAffineTransformIdentity;
    }
}

%end

static void DYYYExpandPlayInteraction(UIView *root) {
    if (!root) return;
    Class playCls = NSClassFromString(@"AWEPlayInteractionViewController");
    if (!playCls) return;
    NSMutableArray *q = [NSMutableArray arrayWithObject:root];
    int safety = 0;
    while (q.count > 0 && safety++ < 500) {
        UIView *v = q.firstObject;
        [q removeObjectAtIndex:0];
        UIResponder *r = v.nextResponder;
        int d = 0;
        while (r && d++ < 10) {
            if ([r isKindOfClass:playCls]) {
                UIView *vv = ((UIViewController *)r).view;
                UIView *sv = vv.superview;
                if (sv && vv.frame.size.height < sv.bounds.size.height - 1) {
                    CGRect f = vv.frame;
                    // v91: 不再强制 y=0，让 v77 的 -60 transform 生效
                    f.size.height = sv.bounds.size.height;
                    vv.frame = f;
                    vv.clipsToBounds = NO;
                    sv.clipsToBounds = NO;
                }
                break;
            }
            if ([r isKindOfClass:[UIViewController class]]) break;
            r = r.nextResponder;
        }
        [q addObjectsFromArray:v.subviews];
    }
}

%hook AWEAwemeDetailTableView

- (void)setFrame:(CGRect)frame {
    // DYYY修复：不改高度，避免污染分页算法
    %orig(frame);
}

- (void)layoutSubviews {
    %orig;
    // 关键：解除 TableView 的裁剪，让 cell 内撑到 852 的视频溢出显示
    if (DYYYGetBool(@"DYYYEnableFullScreen")) {
        self.clipsToBounds = NO;
        DYYYExpandPlayInteraction(self);
    }
}

%end

%hook AWEMixVideoPanelMoreView

- (void)setFrame:(CGRect)frame {
    if (DYYYGetBool(@"DYYYHideTemplateVideo")) {
        self.hidden = YES;
        %orig(frame);
        return;
    }

    if (DYYYGetBool(@"DYYYEnableFullScreen")) {
        CGFloat targetY = frame.origin.y - gCurrentTabBarHeight;
        CGFloat screenHeightMinusGDiff = [UIScreen mainScreen].bounds.size.height - gCurrentTabBarHeight;

        CGFloat tolerance = 10.0;

        if (fabs(targetY - screenHeightMinusGDiff) <= tolerance) {
            frame.origin.y = targetY;
        }
    }
    %orig(frame);
}

- (void)layoutSubviews {
    %orig;

    if (DYYYGetBool(@"DYYYHideTemplateVideo")) {
        self.hidden = YES;
        return;
    }

    if (DYYYGetBool(@"DYYYEnableFullScreen")) {
        self.backgroundColor = [UIColor clearColor];
    }
}

%end

%group DYYYCommentInputContainerGroup

%hook CommentInputContainerView

- (void)layoutSubviews {
    %orig;
    UIViewController *parentVC = nil;
    if ([self respondsToSelector:@selector(viewController)]) {
        id viewController = [self performSelector:@selector(viewController)];
        if ([viewController respondsToSelector:@selector(parentViewController)]) {
            parentVC = [viewController parentViewController];
        }
    }

    if (parentVC && ([parentVC isKindOfClass:%c(AWEAwemeDetailTableViewController)] || [parentVC isKindOfClass:%c(AWEAwemeDetailCellViewController)])) {
        static char kDYCommentHideCacheKey;
        UIView *target = objc_getAssociatedObject(self, &kDYCommentHideCacheKey);
        if (!target) {
            for (UIView *subview in [self subviews]) {
                if ([subview class] == [UIView class]) {
                    target = subview;
                    objc_setAssociatedObject(self, &kDYCommentHideCacheKey, target, OBJC_ASSOCIATION_ASSIGN);
                    break;
                }
            }
        }
        if (target) {
            target.hidden = ([(UIView *)self frame].size.height == gCurrentTabBarHeight);
        }
    }
}

%end

%end

// 聊天视频底部评论框背景透明
%hook AWEIMFeedBottomQuickEmojiInputBar

- (void)layoutSubviews {
    %orig;

    if (DYYYGetBool(@"DYYYEnableFullScreen")) {
        UIView *parentView = self.superview;
        while (parentView) {
            if ([NSStringFromClass([parentView class]) isEqualToString:@"UIView"]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                  parentView.backgroundColor = [UIColor clearColor];
                  parentView.layer.backgroundColor = [UIColor clearColor].CGColor;
                  parentView.opaque = NO;
                });
                break;
            }
            parentView = parentView.superview;
        }
    }
}

%end

// 隐藏上次看到
%hook DUXPopover
- (void)layoutSubviews {
    %orig;

    if (!DYYYGetBool(@"DYYYHidePopover")) {
        return;
    }

    id rawContent = nil;
    @try {
        rawContent = [self valueForKey:@"content"];
    } @catch (__unused NSException *e) {
        return;
    }

    NSString *text = [rawContent isKindOfClass:NSString.class] ? (NSString *)rawContent : [rawContent description];

    if ([text containsString:@"上次看到"]) {
        self.hidden = YES;
        return;
    }
}
%end

%hook _TtC21AWEIncentiveSwiftImpl29IncentivePendantContainerView
- (void)layoutSubviews {
    %orig;
    if (DYYYGetBool(@"DYYYHidePendantGroup")) {
        [self removeFromSuperview];
    }
}
%end

%hook UIImageView
- (void)setImage:(UIImage *)image {
    if (DYYYShouldForceHideFeedVideoCollectButtonView(self)) {
        %orig(nil);
        return;
    }

    DYYYApplySDRDynamicRangeToImageView(self);
    %orig;
    DYYYApplySDRDynamicRangeToImageView(self);
}

- (void)setHighlightedImage:(UIImage *)highlightedImage {
    if (DYYYShouldForceHideFeedVideoCollectButtonView(self)) {
        %orig(nil);
        return;
    }

    DYYYApplySDRDynamicRangeToImageView(self);
    %orig;
    DYYYApplySDRDynamicRangeToImageView(self);
}

- (void)setAnimationImages:(NSArray<UIImage *> *)animationImages {
    if (DYYYShouldForceHideFeedVideoCollectButtonView(self)) {
        %orig(nil);
        return;
    }

    DYYYApplySDRDynamicRangeToImageView(self);
    %orig;
    DYYYApplySDRDynamicRangeToImageView(self);
}

- (void)setHighlightedAnimationImages:(NSArray<UIImage *> *)highlightedAnimationImages {
    if (DYYYShouldForceHideFeedVideoCollectButtonView(self)) {
        %orig(nil);
        return;
    }

    DYYYApplySDRDynamicRangeToImageView(self);
    %orig;
    DYYYApplySDRDynamicRangeToImageView(self);
}

- (void)layoutSubviews {
    %orig;
    if (DYYYShouldForceHideFeedVideoCollectButtonView(self)) {
        DYYYClearFeedVideoCollectImageView(self);
        self.hidden = YES;
        return;
    }

    DYYYApplySDRDynamicRangeToImageView(self);
    if (DYYYGetBoolCached(@"DYYYHideCommentDiscover")) {
        if (!self.accessibilityLabel) {
            UIView *parentView = self.superview;

            if (parentView && [parentView class] == [UIView class] && [parentView.accessibilityLabel isEqualToString:@"搜索"]) {
                self.hidden = YES;
            }

            else if (parentView && [NSStringFromClass([parentView class]) isEqualToString:@"AWESearchEntryHalfScreenElement"] && [parentView.accessibilityLabel isEqualToString:@"搜索"]) {
                self.hidden = YES;
            }
        }
    }
    return;
}
%end

// 移除极速版我的片面红包横幅
%hook AWELuckyCatBannerView
- (id)initWithFrame:(CGRect)frame {
    return nil;
}

- (id)init {
    return nil;
}
%end

static NSString *const kHideRecentAppsKey = @"DYYYHideSidebarRecentApps";
static NSString *const kHideRecentUsersKey = @"DYYYHideSidebarRecentUsers";

%hook AWELeftSideBarModel

- (NSArray *)moduleModels {
    NSArray *originalModels = %orig;

    BOOL shouldHideRecentApps = DYYYGetBool(kHideRecentAppsKey);
    BOOL shouldHideRecentUsers = DYYYGetBool(kHideRecentUsersKey);

    if (!shouldHideRecentApps && !shouldHideRecentUsers) {
        return originalModels;
    }

    NSMutableArray *filteredModels = [NSMutableArray arrayWithCapacity:originalModels.count];

    for (id moduleModel in originalModels) {
        if ([moduleModel respondsToSelector:@selector(moduleID)]) {
            NSString *moduleID = [moduleModel moduleID];

            if (shouldHideRecentApps && [moduleID isEqualToString:@"recently_apps_module"]) {
                continue;
            }

            if (shouldHideRecentUsers && [moduleID isEqualToString:@"recently_users_module"]) {
                continue;
            }
        }

        id filteredModule = [self filterModuleItems:moduleModel];
        if (filteredModule) {
            [filteredModels addObject:filteredModule];
        }
    }

    return [filteredModels copy];
}

%new
- (id)filterModuleItems:(id)moduleModel {
    if (![moduleModel respondsToSelector:@selector(items)] || ![moduleModel respondsToSelector:@selector(moduleID)]) {
        return moduleModel;
    }

    NSString *moduleID = [moduleModel moduleID];
    NSArray *originalItems = [moduleModel items];

    if ([moduleID isEqualToString:@"top_area"]) {
        // 只保留天气、设置、扫一扫
        NSMutableArray *filteredItems = [NSMutableArray array];

        for (id item in originalItems) {
            if ([item respondsToSelector:@selector(businessType)]) {
                NSString *businessType = [item businessType];

                // 保留需要的组件
                if ([businessType isEqualToString:@"weather_time_tip_component"] || [businessType isEqualToString:@"setting_page_component"] ||
                    [businessType isEqualToString:@"top_area_vertical_cell"]) {
                    [filteredItems addObject:item];
                }
            }
        }

        // 创建新的模块对象，保持原有属性但更新items
        if ([moduleModel respondsToSelector:@selector(copy)]) {
            id newModule = [moduleModel copy];
            if ([newModule respondsToSelector:@selector(setItems:)]) {
                [newModule setItems:[filteredItems copy]];
            }
            return newModule;
        }
    }

    return moduleModel;
}

%end

%hook AFDViewedBottomView
- (void)layoutSubviews {
    %orig;

    if (DYYYGetBool(@"DYYYEnableFullScreen")) {
        self.backgroundColor = [UIColor clearColor];

        self.effectView.hidden = YES;
    }
}
%end

// 极速版红包激励挂件容器视图类组（移除逻辑）
%group IncentivePendantGroup
%hook AWEIncentiveSwiftImplDOUYINLite_IncentivePendantContainerView
- (void)layoutSubviews {
    %orig;
    if (DYYYGetBool(@"DYYYHidePendantGroup")) {
        [self removeFromSuperview];
    }
}
%end
%end

// View scaling fix when comment blur is enabled
%group BDMultiContentImageViewGroup
%hook BDMultiContentContainer_ImageContentView

- (void)setTransform:(CGAffineTransform)transform {
    if (DYYYGetBool(@"DYYYEnableCommentBlur")) {
        return;
    }
    %orig(transform);
}

%end
%end

%hook AWEStoryContainerCollectionView

- (void)setFrame:(CGRect)frame {
    if (DYYYGetBool(@"DYYYEnableCommentBlur")) {
        if (frame.origin.y != 0) {
            return;
        }
    }
    %orig(frame);
}

%end

%hook AWEDPlayerProgressContainerView

- (void)layoutSubviews {
    %orig;
    DYYYApplyFloatClearProgressStateToView(self);

    if (![[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYEnableFullScreen"]) {
        return;
    }

    for (UIView *subview in self.subviews) {
        if ([subview isMemberOfClass:[UIView class]]) {
            UIColor *bgColor = subview.backgroundColor;
            if (bgColor) {
                CGFloat h, s, v, a;
                if ([bgColor getHue:&h saturation:&s brightness:&v alpha:&a]) {
                    if (v < 0.2) {
                        subview.backgroundColor = [UIColor clearColor];
                    }
                }
            }
        }
    }
}

%end

// ===== v93fix: 4 个丢失的 group 定义（空实现，防 %init 报 undefined）=====
%group DYYYHidePlusButtonStickerOverlay
%end

%group DYYYHidePlusButtonSpecialPlusManager
%end

%group DYYYHidePlusButtonBigAnimation
%end

%group DYYYHidePlusButtonInnerBubble
%end


%ctor {
    [DYYYLoginBypassManager configureInitialStateIfNeeded];

    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        DYYY_DISABLE_FEED_NOW_PLAYING_INFO_KEY : @NO,
        @"DYYYSpeedSettings" : @"1.0,1.25,1.5,2.0",
        @"DYYYSpeedButtonSize" : @35.0,
        @"DYYYAutoHideSpeedButtonTime" : @30.0,
        kDYYYEnableLoginBypassKey : @YES
    }];

    DYYYMigrateCombinedHDRModeIfNeeded();
    DYYYMigrateScaleAndSizeSettingsIfNeeded();
    DYYYMigrateScaleAndSizeSettingsV2IfNeeded();

    // 仅在构造阶段准备 C Hook；UIKit 与宿主帧率对象延后至 App 激活后访问。
    DYYYHookManagerStartLoaderSafePhase();
    DYYYStartHideFeedAnchorHookInstaller();

    Class plusButtonOverlayClass = objc_getClass("AWENormalModeTabBarPlusButton");
    if (plusButtonOverlayClass && class_getInstanceMethod(plusButtonOverlayClass, @selector(addStickerImageViewAnimationView))) {
        %init(DYYYHidePlusButtonStickerOverlay);
    }
    Class specialPlusManagerClass = objc_getClass("AWEStudioSpecialPlusManager");
    if (specialPlusManagerClass &&
        class_getClassMethod(specialPlusManagerClass, @selector(shouldShowStudioSpecialPlusIconWithAwemeModel:))) {
        %init(DYYYHidePlusButtonSpecialPlusManager);
    }
    Class plusBigAnimationClass = objc_getClass("AWEStudioSpecialPlusBigAnimationManager");
    if (plusBigAnimationClass && class_getInstanceMethod(plusBigAnimationClass, @selector(enableShowSpecialPlusBigAnimation))) {
        %init(DYYYHidePlusButtonBigAnimation);
    }
    Class plusInnerButtonClass = objc_getClass("AWENormalModeTabBarGeneralPlusInnerButton");
    if (plusInnerButtonClass && class_getInstanceMethod(plusInnerButtonClass, @selector(showBubbleWithText:))) {
        %init(DYYYHidePlusButtonInnerBubble);
    }

    %init(DYYYLoginBypassCore);
    DYYYHookManagerStartAfterLoginCorePhase();

    Class loginListenerClass = objc_getClass("AWEUserServiceListener");
    if (loginListenerClass && class_getInstanceMethod(loginListenerClass, @selector(didFinishLoginWithUid:))) {
        %init(DYYYLoginBypassAccountLifecycle);
    }
    if (loginListenerClass && class_getInstanceMethod(loginListenerClass, @selector(didFinishLogoutWithUid:))) {
        %init(DYYYLoginBypassAccountLogout);
    }
    if (loginListenerClass && class_getInstanceMethod(loginListenerClass, @selector(didFinishLogin:))) {
        %init(DYYYLoginBypassAccountLifecycleDidFinishLogin);
    }
    Class accountMulticastClass = objc_getClass("TTAccountMulticast");
    if (accountMulticastClass &&
        class_getInstanceMethod(accountMulticastClass, @selector(broadcastLoginSuccess:platform:reason:))) {
        %init(DYYYLoginBypassAccountMulticast);
    }
    if (objc_getClass("AWEVersionUpdateManager")) {
        %init(DYYYLoginBypassVersionUpdateManager);
    }
    if (objc_getClass("AWEVersionUpdateAlert")) {
        %init(DYYYLoginBypassVersionUpdateAlert);
    }
    if (objc_getClass("AWEVersionUpdatePopup")) {
        %init(DYYYLoginBypassVersionUpdatePopup);
    }
    if (objc_getClass("AWEVersionUpdateWorkflow")) {
        %init(DYYYLoginBypassVersionUpdateWorkflow);
    }
    if (objc_getClass("AWETeenVersionUpdateManager")) {
        %init(DYYYLoginBypassTeenVersionUpdateManager);
    }
    Class preLoginAlertClass = objc_getClass("AWEPreLoginAlertManager");
    if (preLoginAlertClass && class_getInstanceMethod(preLoginAlertClass, @selector(canShow)) &&
        class_getInstanceMethod(preLoginAlertClass, @selector(canShowNow))) {
        %init(DYYYLoginBypassPreLoginAlert);
    }
    if (preLoginAlertClass && class_getInstanceMethod(preLoginAlertClass, @selector(isShowFrequencySatisfied)) &&
        class_getInstanceMethod(preLoginAlertClass, @selector(isShowFrequencySatisfiedByLoginStrategy))) {
        %init(DYYYLoginBypassPreLoginFrequency);
    }
    Class newVersionAlertClass = objc_getClass("AWENewVersionAlertManager");
    if (newVersionAlertClass && class_getInstanceMethod(newVersionAlertClass, @selector(canShow))) {
        %init(DYYYLoginBypassNewVersionAlert);
    }

    Class interactionBaseLabelClass = objc_getClass("AWECommentSwiftBizUI.CommentInteractionBaseLabel");
    if (interactionBaseLabelClass) {
        %init(DYYYCommentExactTimeGroup, AWECommentSwiftBizUI_CommentInteractionBaseLabel = interactionBaseLabelClass);
    }

    Class imMenuComponentClass = objc_getClass("AWEIMCustomMenuComponent");
    if (imMenuComponentClass) {
        SEL legacySelector = NSSelectorFromString(@"msg_showMenuForBubbleFrameInScreen:tapLocationInScreen:menuItemList:moreEmoticon:onCell:extra:");
        SEL tapLocationSelector = NSSelectorFromString(@"msg_showMenuForBubbleFrameInScreen:tapLocationInScreen:menuItemList:menuPanelOptions:moreEmoticon:onCell:extra:");
        SEL highLowSelector = NSSelectorFromString(@"msg_showMenuForBubbleFrameInScreen:highLocationInScreen:lowLocationInScreen:tryHighLocationFirst:menuItemList:menuPanelOptions:onCell:extra:");
        if (legacySelector && class_getInstanceMethod(imMenuComponentClass, legacySelector)) {
            %init(DYYYIMMenuLegacyGroup);
        }
        if (tapLocationSelector && class_getInstanceMethod(imMenuComponentClass, tapLocationSelector)) {
            %init(DYYYIMMenuTapLocationGroup);
        }
        if (highLowSelector && class_getInstanceMethod(imMenuComponentClass, highLowSelector)) {
            %init(DYYYIMMenuHighLowGroup);
        }
    }

    if (!DYYYGetBool(@"DYYYDisableSettingsGesture")) {
        %init(DYYYSettingsGesture);
    }
    if (DYYYGetBool(@"DYYYUserAgreementAccepted")) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        isFloatSpeedButtonEnabled = [defaults boolForKey:@"DYYYEnableFloatSpeedButton"];
        showSpeedX = [defaults boolForKey:@"DYYYSpeedButtonShowX"];
        CGFloat configuredSpeedButtonSize = [defaults floatForKey:@"DYYYSpeedButtonSize"];
        speedButtonSize = configuredSpeedButtonSize > 0.0 ? configuredSpeedButtonSize : 35.0;

        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
          %init;
          Class wSwiftImpl = objc_getClass("AWECommentInputViewSwiftImpl.CommentInputContainerView");
          if (wSwiftImpl) {
              %init(DYYYCommentInputContainerGroup, CommentInputContainerView = wSwiftImpl);
          }
        });
        BOOL isAutoPlayEnabled = DYYYGetBool(@"DYYYEnableAutoPlay");
        if (isAutoPlayEnabled) {
            %init(AutoPlay);
        }
        if (DYYYGetBool(@"DYYYForceDownloadEmotion") ||
            DYYYGetBool(@"DYYYForceDownloadCommentAudio") ||
            DYYYGetBool(@"DYYYForceDownloadCommentImage")) {
            %init(EnableStickerSaveMenu);
        }
        DYYYHookManagerStartAfterAgreementPhase();

        // 初始化红包激励挂件容器视图类组
        Class incentivePendantClass = objc_getClass("AWEIncentiveSwiftImplDOUYINLite.IncentivePendantContainerView");
        if (incentivePendantClass) {
            %init(IncentivePendantGroup, AWEIncentiveSwiftImplDOUYINLite_IncentivePendantContainerView = incentivePendantClass);
        }
        Class imageContentClass = objc_getClass("BDMultiContentContainer.ImageContentView");
        if (imageContentClass) {
            %init(BDMultiContentImageViewGroup, BDMultiContentContainer_ImageContentView = imageContentClass);
        }

        // 动态获取 Swift 类并初始化对应的组
        Class commentSearchAnchorViewClass = objc_getClass("AWECommentSearchAnchorView");
        if (commentSearchAnchorViewClass) {
            %init(CommentSearchAnchorGroup, AWECommentSearchAnchorView = commentSearchAnchorViewClass);
        }

        Class commentHeaderSectionControllerClass =
            NSClassFromString(@"AWECommentPanelHeaderSwiftImpl.CommentPanelHeaderSectionController");
        if (!commentHeaderSectionControllerClass) {
            commentHeaderSectionControllerClass =
                objc_getClass("_TtC30AWECommentPanelHeaderSwiftImpl40CommentPanelHeaderSectionController");
        }
        if (!commentHeaderSectionControllerClass) {
            commentHeaderSectionControllerClass =
                objc_getClass("AWECommentPanelHeaderSwiftImpl.CommentPanelHeaderSectionController");
        }
        if (commentHeaderSectionControllerClass) {
            %init(CommentPanelHeaderVerifiedCollapseGroup,
                  AWECommentPanelHeaderSwiftImpl_CommentPanelHeaderSectionController = commentHeaderSectionControllerClass);
        }

        Class commentHeaderGeneralClass = objc_getClass("AWECommentCommerceSwiftImpl.CommentHeaderGeneralView");
        if (!commentHeaderGeneralClass) {
            commentHeaderGeneralClass = objc_getClass("AWECommentPanelHeaderSwiftImpl.CommentHeaderGeneralView");
        }
        if (commentHeaderGeneralClass) {
            %init(CommentHeaderGeneralGroup, AWECommentPanelHeaderSwiftImpl_CommentHeaderGeneralView = commentHeaderGeneralClass);
        }

        Class commentHeaderGoodsClass = objc_getClass("AWECommentCommerceSwiftImpl.CommentHeaderGoodsView");
        if (!commentHeaderGoodsClass) {
            commentHeaderGoodsClass = objc_getClass("AWECommentPanelHeaderSwiftImpl.CommentHeaderGoodsView");
        }
        if (commentHeaderGoodsClass) {
            %init(CommentHeaderGoodsGroup, AWECommentPanelHeaderSwiftImpl_CommentHeaderGoodsView = commentHeaderGoodsClass);
        }
        Class commentHeaderTemplateClass = objc_getClass("AWECommentPanelHeaderSwiftImpl.CommentHeaderTemplateAnchorView");
        if (commentHeaderTemplateClass) {
            %init(CommentHeaderTemplateGroup, AWECommentPanelHeaderSwiftImpl_CommentHeaderTemplateAnchorView = commentHeaderTemplateClass);
        }

        Class tipsVCClass = objc_getClass("AWECommentPanelListSwiftImpl.CommentBottomTipsContainerViewController");
        if (tipsVCClass) {
            %init(CommentBottomTipsVCGroup, AWECommentPanelListSwiftImpl_CommentBottomTipsContainerViewController = tipsVCClass);
        }

    }
}


// ===== 详情页 Cell 撑满全屏（严格限定 AWEAwemeDetailTableView） =====


// ===== v29: 每个 table 只处理一次，不再每帧 dispatch =====
// v28 每次 layout 都 dispatch_async + layoutIfNeeded → 打断主页加载
// v29 用 associatedObject 标记已处理的 table，只动手一次
static const void *kDYYYV29Done = &kDYYYV29Done;

static void (*_o_v29)(id, SEL) = NULL;

static void _m_v29(id self, SEL _cmd) {
    if (_o_v29) _o_v29(self, _cmd);
    if (!DYYYGetBool(@"DYYYEnableFullScreen")) return;

    @autoreleasepool {
        UIViewController *vc = (UIViewController *)self;
        UIView *rootView = vc.view;
        if (!rootView || rootView.bounds.size.height < 800) return;

        // 找 table
        UIView *table = nil;
        NSMutableArray *q = [NSMutableArray arrayWithObject:rootView];
        int safety = 0;
        while (q.count > 0 && safety++ < 1000) {
            UIView *v = q.firstObject;
            [q removeObjectAtIndex:0];
            if ([NSStringFromClass([v class]) isEqualToString:@"AWEAwemeDetailTableView"]) {
                table = v; break;
            }
            for (UIView *s in v.subviews) [q addObject:s];
        }
        if (!table) return;

        // 已经处理过？直接退出
        if (objc_getAssociatedObject(table, kDYYYV29Done)) return;

        UIView *sv = table.superview;
        if (!sv) return;

        // 找 bottom 约束改 0
        BOOL changed = NO;
        NSMutableArray *pools = [NSMutableArray arrayWithObject:sv.constraints];
        if (sv.superview) [pools addObject:sv.superview.constraints];

        for (NSArray *pool in pools) {
            for (NSLayoutConstraint *c in pool) {
                if (c.firstItem != table && c.secondItem != table) continue;
                if (c.firstAttribute != NSLayoutAttributeBottom &&
                    c.secondAttribute != NSLayoutAttributeBottom) continue;
                if (fabs(c.constant) > 1.0) {
                    c.constant = 0;
                    changed = YES;
                }
            }
        }

        // 标记已处理（无论是否改过，都不再处理这个 table）
        objc_setAssociatedObject(table, kDYYYV29Done, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        if (changed) {
            // 只在真正改过约束时触发一次重排
            dispatch_async(dispatch_get_main_queue(), ^{
                [sv setNeedsLayout];
                [sv layoutIfNeeded];
            });
        }
    }
}

%ctor {
    Class c = objc_getClass("AWEAwemeDetailTableViewController");
    if (c) {
        Method m = class_getInstanceMethod(c, @selector(viewDidLayoutSubviews));
        if (m) {
            _o_v29 = (void(*)(id,SEL))method_getImplementation(m);
            method_setImplementation(m, (IMP)_m_v29);
        }
    }
}

// ===== 隐藏"暂时没有更多了"底部占位（只对详情页，主页不动） =====
%ctor {
    Class cls = objc_getClass("AWEFeedRefreshFooter");
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, @selector(layoutSubviews));
    if (!m) return;
    IMP origImp = method_getImplementation(m);
    IMP newImp = imp_implementationWithBlock(^(id self, SEL _cmd) {
        ((void (*)(id, SEL))origImp)(self, _cmd);
        // 只在详情页 table 里隐藏 footer；主页 feed 保持原生，让 loadMore 生效
        BOOL isDetail = NO;
        UIResponder *r = [self nextResponder];
        int d = 0;
        while (r && d++ < 12) {
            Class c = [r class];
            NSString *name = NSStringFromClass(c);
            if ([name isEqualToString:@"AWEAwemeDetailTableViewController"] ||
                [name isEqualToString:@"AWEAwemeDetailCellViewController"] ||
                [name isEqualToString:@"AWEAwemeDetailTableView"]) {
                isDetail = YES;
                break;
            }
            r = [r nextResponder];
        }
        if (isDetail) {
            [self setHidden:YES];
        }
    });
    method_setImplementation(m, newImp);
}



// 写沙盒日志（动态路径，不写死）
static void DYYYV54Log(NSString *fmt, ...) {
    @autoreleasepool {
        va_list ap; va_start(ap, fmt);
        NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
        if (!s) return;
        NSString *home = NSHomeDirectory();
        if (home.length == 0) return;
        NSString *path = [[home stringByAppendingPathComponent:@"Documents"]
                          stringByAppendingPathComponent:@"dyyy_v54.log"];
        FILE *fp = fopen(path.UTF8String, "a");
        if (!fp) return;
        fputs(([s stringByAppendingString:@"\n"]).UTF8String, fp);
        fclose(fp);
    }
}

