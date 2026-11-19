#import "DYYYLikeLongPressSave.h"
#import "DYYYConstants.h"
#import "DYYYManager.h"
#import "DYYYUtils.h"
#import <objc/message.h>
#import <objc/runtime.h>

static BOOL gDYYYLikeSaveStarted;
static BOOL gDYYYLikeSaveEnabled;
static NSHashTable<UIButton *> *gDYYYLikeSaveButtons;
static char kDYYYLikeSaveButtonStateKey;
static char kDYYYLikeSaveMaterialStateKey;
static const CGFloat kDYYYLikeSaveBackgroundOpacity = 0.2;

@interface DYYYManager (DYYYLikeLongPressSaveProgress)
- (void)finalizeDownloadWithFileURL:(NSURL *)fileURL success:(BOOL)success;
@end

static id DYYYLikeSaveObject(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (!object || ![object respondsToSelector:selector]) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(object, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

static NSInteger DYYYLikeSaveInteger(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (!object || ![object respondsToSelector:selector]) return 0;
    @try { return ((NSInteger (*)(id, SEL))objc_msgSend)(object, selector); }
    @catch (__unused NSException *exception) { return 0; }
}

static NSArray *DYYYLikeSaveArray(id value) {
    return [value isKindOfClass:NSArray.class] ? value : @[];
}

static NSURL *DYYYLikeSaveURL(id value) {
    if (!value || value == NSNull.null) return nil;
    if ([value isKindOfClass:NSURL.class]) {
        NSURL *url = value;
        NSString *scheme = url.scheme.lowercaseString;
        return ([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"]) && url.host.length ? url : nil;
    }
    if ([value isKindOfClass:NSString.class]) return DYYYLikeSaveURL([NSURL URLWithString:value]);
    if ([value isKindOfClass:NSArray.class]) {
        for (id item in value) {
            NSURL *url = DYYYLikeSaveURL(item);
            if (url) return url;
        }
        return nil;
    }
    return DYYYLikeSaveURL(DYYYLikeSaveObject(value, @"originURLList")) ?: DYYYLikeSaveURL(DYYYLikeSaveObject(value, @"URLList"));
}

static id DYYYLikeSaveModelForButton(UIButton *button) {
    Class modelClass = NSClassFromString(@"AWEAwemeModel");
    UIResponder *responder = button;
    for (NSUInteger depth = 0; responder && depth < 60; depth++, responder = responder.nextResponder) {
        for (NSString *key in @[@"awemeModel", @"currentAweme", @"model"]) {
            id value = DYYYLikeSaveObject(responder, key);
            if (modelClass && [value isKindOfClass:modelClass]) return value;
        }
    }
    return nil;
}

static NSURL *DYYYLikeSaveImageURL(id image) {
    // downloadURLList adds a platform watermark. Do not use it as a fallback.
    return DYYYLikeSaveURL(DYYYLikeSaveObject(image, @"watermarkFreeUrlList")) ?:
           DYYYLikeSaveURL(DYYYLikeSaveObject(image, @"urlList"));
}

static NSURL *DYYYLikeSaveBestVideoURL(id video) {
    NSURL *best;
    long long highest = -1;
    for (NSString *key in @[@"bitrateModels_origin", @"bitrateModels"]) {
        for (id row in DYYYLikeSaveArray(DYYYLikeSaveObject(video, key))) {
            id value = DYYYLikeSaveObject(row, @"bitrate");
            long long rate = [value respondsToSelector:@selector(longLongValue)] ? [value longLongValue] : 0;
            NSURL *url = DYYYLikeSaveURL(DYYYLikeSaveObject(row, @"playAddr"));
            if (url && rate > highest) { highest = rate; best = url; }
        }
    }
    return best ?: DYYYLikeSaveURL(DYYYLikeSaveObject(video, @"h264URL")) ?:
                   DYYYLikeSaveURL(DYYYLikeSaveObject(video, @"playURL"));
}

static void DYYYLikeSaveRemoveTemporaryURL(NSURL *url) {
    if (url.isFileURL) [NSFileManager.defaultManager removeItemAtURL:url error:nil];
}

static NSURL *DYYYLikeSavePrepareImage(NSURL *rawURL, NSError **error) {
    UIImage *image = [UIImage imageWithContentsOfFile:rawURL.path];
    if (image.CGImage) return rawURL;
    NSData *data = [NSData dataWithContentsOfURL:rawURL options:NSDataReadingMappedIfSafe error:error];
    if (!data) return nil;
    Class imageClass = NSClassFromString(@"BDImage");
    SEL selector = NSSelectorFromString(@"imageWithData:scale:decodeForDisplay:shouldScaleDown:error:");
    if ([imageClass respondsToSelector:selector]) {
        // Decodes VVIC using Douyin's decoder. Never resize/upscale or fall back to a watermarked URL.
        @try {
            image = ((UIImage *(*)(id, SEL, NSData *, double, BOOL, BOOL, NSError **))objc_msgSend)
                (imageClass, selector, data, 1.0, YES, NO, error);
        } @catch (__unused NSException *exception) { image = nil; }
    }
    if (!image.CGImage) return nil;
    NSData *png = UIImagePNGRepresentation(image);
    if (!png.length) return nil;
    NSURL *output = [rawURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:
        [NSString stringWithFormat:@"DYYYLikeSave-%@.png", NSUUID.UUID.UUIDString]];
    if (![png writeToURL:output options:NSDataWritingAtomic error:error]) return nil;
    return output;
}

@interface DYYYLikeImageSaveJob : NSObject
@property(nonatomic, copy) NSArray<NSURL *> *URLs;
@property(nonatomic, copy) NSString *albumDescription;
@property(nonatomic) NSUInteger index;
@property(nonatomic) NSUInteger succeeded;
@property(nonatomic) BOOL finished;
- (void)start;
- (void)saveNext;
- (void)finish;
@end

static DYYYLikeImageSaveJob *gDYYYLikeSaveActiveImageJob;

@implementation DYYYLikeImageSaveJob
- (void)start {
    if (gDYYYLikeSaveActiveImageJob && !gDYYYLikeSaveActiveImageJob.finished) {
        [DYYYUtils showToast:@"正在保存图片，请完成或取消后再试"];
        return;
    }
    gDYYYLikeSaveActiveImageJob = self;
    if (!self.URLs.count) { [self finish]; return; }
    [self saveNext];
}
- (void)finish {
    if (self.finished) return;
    self.finished = YES;
    if (gDYYYLikeSaveActiveImageJob == self) gDYYYLikeSaveActiveImageJob = nil;
    [DYYYUtils showToast:[NSString stringWithFormat:@"图片保存完成：%lu/%lu 张", (unsigned long)self.succeeded, (unsigned long)self.URLs.count]];
}
- (void)saveNext {
    if (self.finished) return;
    if (self.index >= self.URLs.count) { [self finish]; return; }
    NSURL *source = self.URLs[self.index];
    [DYYYManager downloadMediaWithProgress:source mediaType:MediaTypeImage audio:nil progress:nil
        completion:^(BOOL downloaded, NSURL *rawURL) {
            if (!downloaded || !rawURL) {
                // A cancelled download must not start the remaining images.
                [self finish];
                return;
            }
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                @autoreleasepool {
                    NSError *error;
                    NSURL *preparedURL = DYYYLikeSavePrepareImage(rawURL, &error);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (!preparedURL) {
                            [[DYYYManager shared] finalizeDownloadWithFileURL:rawURL success:NO];
                            DYYYLikeSaveRemoveTemporaryURL(rawURL);
                            self.index++;
                            [self saveNext];
                            return;
                        }
                        [DYYYManager saveMedia:preparedURL mediaType:MediaTypeImage albumDescription:self.albumDescription
                            completion:^(BOOL success) {
                                [[DYYYManager shared] finalizeDownloadWithFileURL:rawURL success:success];
                                DYYYLikeSaveRemoveTemporaryURL(rawURL);
                                if (![preparedURL isEqual:rawURL]) DYYYLikeSaveRemoveTemporaryURL(preparedURL);
                                if (success) self.succeeded++;
                                self.index++;
                                [self saveNext];
                            }];
                    });
                }
            });
        }];
}
@end

static UIImage *DYYYLikeSaveSymbol(NSString *name) {
    return [UIImage systemImageNamed:name] ?: [UIImage systemImageNamed:@"photo"];
}

static UIAction *DYYYLikeSaveImagesAction(NSString *title, NSString *identifier, NSArray<NSURL *> *URLs, id model) {
    // Capture immutable resources in the block itself: UIAction copies do not copy associated objects.
    NSArray<NSURL *> *snapshot = [URLs copy];
    NSString *description = [[DYYYManager albumDescriptionForAwemeModel:model] copy];
    UIAction *action = [UIAction actionWithTitle:title image:DYYYLikeSaveSymbol(snapshot.count > 1 ? @"photo.stack" : @"photo")
        identifier:identifier handler:^(__kindof UIAction *selectedAction) {
            if (!snapshot.count) { [DYYYUtils showToast:@"当前图片暂无无水印资源"]; return; }
            DYYYLikeImageSaveJob *job = [DYYYLikeImageSaveJob new];
            job.URLs = snapshot;
            job.albumDescription = description;
            [job start];
        }];
    if (!snapshot.count) action.attributes = UIMenuElementAttributesDisabled;
    return action;
}

static NSArray<UIMenuElement *> *DYYYLikeSaveMenuItems(UIButton *button) {
    id model = DYYYLikeSaveModelForButton(button);
    if (!model) return @[];
    NSArray *images = DYYYLikeSaveArray(DYYYLikeSaveObject(model, @"albumImages"));
    NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
    if (DYYYLikeSaveInteger(model, @"awemeType") == 68 && images.count) {
        NSInteger nativeIndex = DYYYLikeSaveInteger(model, @"currentImageIndex");
        NSUInteger index = nativeIndex > 0 && (NSUInteger)nativeIndex <= images.count ? (NSUInteger)nativeIndex - 1 : 0;
        NSURL *current = DYYYLikeSaveImageURL(images[index]);
        [items addObject:DYYYLikeSaveImagesAction(@"保存当前无水印图", @"DYYYLikeSave.CurrentImage", current ? @[current] : @[], model)];
        if (images.count > 1) {
            NSMutableArray<NSURL *> *URLs = [NSMutableArray arrayWithCapacity:images.count];
            for (id image in images) {
                NSURL *url = DYYYLikeSaveImageURL(image);
                if (url) [URLs addObject:url];
            }
            NSString *title = [NSString stringWithFormat:@"保存全部无水印图（%lu张）", (unsigned long)images.count];
            UIAction *all = DYYYLikeSaveImagesAction(title, @"DYYYLikeSave.AllImages", URLs, model);
            if (URLs.count != images.count) {
                all.attributes = UIMenuElementAttributesDisabled;
                if (@available(iOS 15.0, *)) all.subtitle = @"部分图片暂无无水印资源";
            }
            [items addObject:all];
        }
        return items;
    }
    id video = DYYYLikeSaveObject(model, @"video");
    NSURL *videoURL = DYYYLikeSaveBestVideoURL(video);
    if (videoURL) {
        NSURL *audioURL = DYYYLikeSaveURL(DYYYLikeSaveObject(DYYYLikeSaveObject(model, @"music"), @"playURL"));
        UIAction *saveVideo = [UIAction actionWithTitle:@"保存原画质视频" image:DYYYLikeSaveSymbol(@"square.and.arrow.down")
            identifier:@"DYYYLikeSave.Video" handler:^(__kindof UIAction *selectedAction) {
                [DYYYManager setAlbumDescriptionContextWithAwemeModel:model];
                [DYYYManager downloadMedia:videoURL mediaType:MediaTypeVideo audio:audioURL completion:nil];
            }];
        [items addObject:saveVideo];
    }
    NSURL *cover = DYYYLikeSaveURL(DYYYLikeSaveObject(video, @"originCover")) ?:
                   DYYYLikeSaveURL(DYYYLikeSaveObject(video, @"coverURL"));
    if (cover) [items addObject:DYYYLikeSaveImagesAction(@"保存封面原图", @"DYYYLikeSave.Cover", @[cover], model)];
    return items;
}

@interface DYYYLikeSaveButtonState : NSObject
@property(nonatomic, strong) UIMenu *originalMenu;
@property(nonatomic, strong) UIMenu *installedMenu;
@property(nonatomic, weak) id cachedModel;
@property(nonatomic) NSInteger cachedImageIndex;
@end
@implementation DYYYLikeSaveButtonState
@end

static BOOL DYYYLikeSaveIsLikeButton(UIButton *button) {
    if (![button isKindOfClass:NSClassFromString(@"AWEFeedVideoButton")]) return NO;
    NSString *label = button.accessibilityLabel ?: @"";
    return [label hasPrefix:@"点赞"] || [label hasPrefix:@"取消点赞"] ||
           [label isEqualToString:@"Like"] || [label isEqualToString:@"Unlike"];
}

static void DYYYLikeSaveRestoreButton(UIButton *button) {
    DYYYLikeSaveButtonState *state = objc_getAssociatedObject(button, &kDYYYLikeSaveButtonStateKey);
    if (!state) return;
    if (button.menu == state.installedMenu) {
        [button.contextMenuInteraction dismissMenu];
        button.menu = state.originalMenu;
    }
    objc_setAssociatedObject(button, &kDYYYLikeSaveButtonStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void DYYYLikeLongPressSaveUpdateButton(UIButton *button) {
    if (!gDYYYLikeSaveStarted || !gDYYYLikeSaveEnabled) return;
    if (!NSThread.isMainThread) return;
    DYYYLikeSaveButtonState *state = objc_getAssociatedObject(button, &kDYYYLikeSaveButtonStateKey);
    if (!DYYYLikeSaveIsLikeButton(button)) {
        if (state) DYYYLikeSaveRestoreButton(button);
        return;
    }
    id model = DYYYLikeSaveModelForButton(button);
    if (!model) return;
    NSInteger imageIndex = DYYYLikeSaveInteger(model, @"currentImageIndex");
    if (state && button.menu == state.installedMenu) {
        if (@available(iOS 15.0, *)) return; // uncached provider resolves the current post/page on every opening.
        if (state.cachedModel == model && state.cachedImageIndex == imageIndex) return;
    }
    if (state && button.menu != state.installedMenu) state.originalMenu = button.menu;
    if (!state) {
        state = [DYYYLikeSaveButtonState new];
        state.originalMenu = button.menu;
        objc_setAssociatedObject(button, &kDYYYLikeSaveButtonStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [gDYYYLikeSaveButtons addObject:button];
    }
    state.cachedModel = model;
    state.cachedImageIndex = imageIndex;
    __weak UIButton *weakButton = button;
    void (^provider)(void (^)(NSArray<UIMenuElement *> *)) = ^(void (^completion)(NSArray<UIMenuElement *> *)) {
        void (^resolve)(void) = ^{
            UIButton *liveButton = weakButton;
            completion(gDYYYLikeSaveEnabled && liveButton ? DYYYLikeSaveMenuItems(liveButton) : @[]);
        };
        if (NSThread.isMainThread) resolve();
        else dispatch_async(dispatch_get_main_queue(), resolve);
    };
    UIDeferredMenuElement *deferred;
    if (@available(iOS 15.0, *)) deferred = [UIDeferredMenuElement elementWithUncachedProvider:provider];
    else deferred = [UIDeferredMenuElement elementWithProvider:provider];
    // Keep the original menu only for restoring the disabled state, never as a submenu.
    UIMenu *menu = [UIMenu menuWithTitle:@"" children:@[deferred]];
    // Do not change showsMenuAsPrimaryAction, touch callbacks, or existing gesture recognizers.
    button.menu = menu;
    // UIButton.menu copies its input. Track the installed copy so layout and restore
    // recognize our own menu instead of recursively nesting it as an original menu.
    state.installedMenu = button.menu;
}

static void DYYYLikeSaveRefreshLiveButtons(void) {
    if (!gDYYYLikeSaveEnabled) return;
    UIWindow *window = [DYYYUtils getActiveWindow];
    if (!window) return;
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:window];
    NSUInteger visited = 0;
    while (pending.count && visited++ < 5000) {
        UIView *view = pending.lastObject;
        [pending removeLastObject];
        if ([view isKindOfClass:UIButton.class]) DYYYLikeLongPressSaveUpdateButton((UIButton *)view);
        [pending addObjectsFromArray:view.subviews];
    }
}

UITargetedPreview *DYYYLikeLongPressSavePreview(UIButton *button) {
    if (!gDYYYLikeSaveEnabled || !objc_getAssociatedObject(button, &kDYYYLikeSaveButtonStateKey)) return nil;
    UIView *imageView = DYYYLikeSaveObject(button, @"buttonImageView");
    if (![imageView isKindOfClass:UIImageView.class] || !imageView.window) return nil;
    UIPreviewParameters *parameters = [UIPreviewParameters new];
    parameters.backgroundColor = UIColor.clearColor;
    SEL shadow = NSSelectorFromString(@"setShadowPath:");
    if ([parameters respondsToSelector:shadow]) ((void (*)(id, SEL, id))objc_msgSend)(parameters, shadow, [UIBezierPath bezierPath]);
    return [[UITargetedPreview alloc] initWithView:imageView parameters:parameters];
}

@interface DYYYLikeSaveMaterialState : NSObject
@property(nonatomic, strong) UIColor *background;
@property(nonatomic, strong) UIVisualEffect *effect;
@property(nonatomic) CGFloat alpha;
@property(nonatomic) UIUserInterfaceStyle interfaceStyle;
@property(nonatomic) BOOL restoresEffect;
@property(nonatomic) BOOL restoresStyle;
@end
@implementation DYYYLikeSaveMaterialState
@end

static NSHashTable<UIView *> *gDYYYLikeSaveMaterialViews;
static NSHashTable<UIView *> *gDYYYLikeSaveMaterialRoots;
static __weak UIButton *gDYYYLikeSaveMenuOwner;
static NSUInteger gDYYYLikeSaveMenuGeneration;

static void DYYYLikeSaveRememberMaterial(UIView *view, BOOL effect, BOOL style) {
    if (objc_getAssociatedObject(view, &kDYYYLikeSaveMaterialStateKey)) return;
    DYYYLikeSaveMaterialState *state = [DYYYLikeSaveMaterialState new];
    state.background = view.backgroundColor;
    state.restoresEffect = effect;
    state.restoresStyle = style;
    if (effect) { state.effect = ((UIVisualEffectView *)view).effect; state.alpha = view.alpha; }
    if (style) state.interfaceStyle = view.overrideUserInterfaceStyle;
    objc_setAssociatedObject(view, &kDYYYLikeSaveMaterialStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [gDYYYLikeSaveMaterialViews addObject:view];
}

static void DYYYLikeSaveRestoreMaterials(void) {
    for (UIView *view in gDYYYLikeSaveMaterialViews.allObjects) {
        DYYYLikeSaveMaterialState *state = objc_getAssociatedObject(view, &kDYYYLikeSaveMaterialStateKey);
        if (!state) continue;
        view.backgroundColor = state.background;
        if (state.restoresEffect && [view isKindOfClass:UIVisualEffectView.class]) {
            ((UIVisualEffectView *)view).effect = state.effect;
            view.alpha = state.alpha;
        }
        if (state.restoresStyle) view.overrideUserInterfaceStyle = state.interfaceStyle;
        objc_setAssociatedObject(view, &kDYYYLikeSaveMaterialStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [gDYYYLikeSaveMaterialViews removeAllObjects];
    [gDYYYLikeSaveMaterialRoots removeAllObjects];
    gDYYYLikeSaveMenuOwner = nil;
}

static void DYYYLikeSaveApplyMenuMaterial(void) {
    if (!gDYYYLikeSaveEnabled || !gDYYYLikeSaveMenuOwner) return;
    if (!gDYYYLikeSaveMaterialRoots.allObjects.count) {
        NSMutableArray<UIView *> *pending = [NSMutableArray array];
        for (UIWindow *window in UIApplication.sharedApplication.windows) [pending addObject:window];
        NSUInteger count = 0;
        while (pending.count && count++ < 5000) {
            UIView *view = pending.lastObject;
            [pending removeLastObject];
            if ([NSStringFromClass(view.class) hasPrefix:@"_UIContextMenuListView"]) {
                [gDYYYLikeSaveMaterialRoots addObject:view];
                continue;
            }
            [pending addObjectsFromArray:view.subviews];
        }
    }
    for (UIView *root in gDYYYLikeSaveMaterialRoots.allObjects) {
        DYYYLikeSaveRememberMaterial(root, NO, YES);
        root.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        root.backgroundColor = UIColor.clearColor;
        NSMutableArray<UIView *> *pending = [root.subviews mutableCopy];
        NSUInteger visited = 0;
        while (pending.count && visited++ < 80) {
            UIView *view = pending.lastObject;
            [pending removeLastObject];
            if ([view isKindOfClass:UIVisualEffectView.class]) {
                DYYYLikeSaveRememberMaterial(view, YES, NO);
                ((UIVisualEffectView *)view).effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
                view.backgroundColor = UIColor.blackColor;
                view.alpha = kDYYYLikeSaveBackgroundOpacity;
                continue; // Never fade the foreground labels/icons or alter UIKit's effect internals.
            }
            if ([view isKindOfClass:UICollectionView.class]) {
                DYYYLikeSaveRememberMaterial(view, NO, NO);
                view.backgroundColor = UIColor.clearColor;
                continue;
            }
            if ([view isMemberOfClass:UIView.class]) {
                DYYYLikeSaveRememberMaterial(view, NO, NO);
                view.backgroundColor = UIColor.clearColor;
            }
            [pending addObjectsFromArray:view.subviews];
        }
    }
}

void DYYYLikeLongPressSaveWillDisplay(UIButton *button, id<UIContextMenuInteractionAnimating> animator) {
    if (!gDYYYLikeSaveEnabled || !objc_getAssociatedObject(button, &kDYYYLikeSaveButtonStateKey)) return;
    DYYYLikeSaveRestoreMaterials();
    gDYYYLikeSaveMenuOwner = button;
    NSUInteger generation = ++gDYYYLikeSaveMenuGeneration;
    void (^apply)(void) = ^{
        if (generation == gDYYYLikeSaveMenuGeneration && gDYYYLikeSaveMenuOwner == button) DYYYLikeSaveApplyMenuMaterial();
    };
    apply();
    [animator addAnimations:apply];
    [animator addCompletion:apply];
    dispatch_async(dispatch_get_main_queue(), apply);
}

void DYYYLikeLongPressSaveWillEnd(UIButton *button, id<UIContextMenuInteractionAnimating> animator) {
    if (gDYYYLikeSaveMenuOwner != button) return;
    NSUInteger generation = gDYYYLikeSaveMenuGeneration;
    void (^restore)(void) = ^{
        if (generation == gDYYYLikeSaveMenuGeneration && gDYYYLikeSaveMenuOwner == button) DYYYLikeSaveRestoreMaterials();
    };
    if (animator) [animator addCompletion:restore];
    else restore();
}

static void DYYYLikeSaveReadPreference(BOOL refreshVisibleButtons) {
    BOOL enabled = [NSUserDefaults.standardUserDefaults boolForKey:DYYY_LIKE_LONG_PRESS_SAVE_KEY];
    BOOL changed = enabled != gDYYYLikeSaveEnabled;
    gDYYYLikeSaveEnabled = enabled;
    if (!enabled) {
        if (changed) {
            ++gDYYYLikeSaveMenuGeneration;
            for (UIButton *button in gDYYYLikeSaveButtons.allObjects) DYYYLikeSaveRestoreButton(button);
            [gDYYYLikeSaveButtons removeAllObjects];
            DYYYLikeSaveRestoreMaterials();
        }
    } else if (changed || refreshVisibleButtons) {
        DYYYLikeSaveRefreshLiveButtons();
    }
}

void DYYYStartLikeLongPressSave(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            gDYYYLikeSaveButtons = [NSHashTable weakObjectsHashTable];
            gDYYYLikeSaveMaterialViews = [NSHashTable weakObjectsHashTable];
            gDYYYLikeSaveMaterialRoots = [NSHashTable weakObjectsHashTable];
            gDYYYLikeSaveStarted = YES;
            DYYYLikeSaveReadPreference(YES);
            NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
            [center addObserverForName:NSUserDefaultsDidChangeNotification object:NSUserDefaults.standardUserDefaults queue:nil
                usingBlock:^(__unused NSNotification *notification) {
                    dispatch_async(dispatch_get_main_queue(), ^{ DYYYLikeSaveReadPreference(NO); });
                }];
            [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *notification) { DYYYLikeSaveReadPreference(YES); }];
        });
    });
}

UIImage *DYYYLikeLongPressSaveSettingsIcon(CGSize size) {
    if (size.width <= 0 || size.height <= 0) size = CGSizeMake(20, 20);
    static NSCache<NSString *, UIImage *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; });
    NSString *key = [NSString stringWithFormat:@"%.2fx%.2f", size.width, size.height];
    UIImage *cached = [cache objectForKey:key];
    if (cached) return cached;
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    CGContextRef context = UIGraphicsGetCurrentContext();
    if (!context) { UIGraphicsEndImageContext(); return nil; }
    CGContextScaleCTM(context, size.width / 20.0, size.height / 20.0);
    [UIColor.blackColor setStroke];
    UIBezierPath *heart = [UIBezierPath bezierPath];
    [heart moveToPoint:CGPointMake(10, 4.9)];
    [heart addCurveToPoint:CGPointMake(2.4, 6.3) controlPoint1:CGPointMake(6.1, 0.0) controlPoint2:CGPointMake(0.5, 2.6)];
    [heart addCurveToPoint:CGPointMake(10, 13.4) controlPoint1:CGPointMake(3.7, 9.2) controlPoint2:CGPointMake(7.1, 12.0)];
    [heart addCurveToPoint:CGPointMake(17.6, 6.3) controlPoint1:CGPointMake(12.9, 12.0) controlPoint2:CGPointMake(16.3, 9.2)];
    [heart addCurveToPoint:CGPointMake(10, 4.9) controlPoint1:CGPointMake(19.5, 2.6) controlPoint2:CGPointMake(13.9, 0.0)];
    heart.lineWidth = 1.45;
    heart.lineCapStyle = kCGLineCapRound;
    heart.lineJoinStyle = kCGLineJoinRound;
    [heart stroke];
    UIBezierPath *arrow = [UIBezierPath bezierPath];
    [arrow moveToPoint:CGPointMake(10, 10.6)];
    [arrow addLineToPoint:CGPointMake(10, 17.8)];
    [arrow moveToPoint:CGPointMake(7.8, 15.5)];
    [arrow addLineToPoint:CGPointMake(10, 17.8)];
    [arrow addLineToPoint:CGPointMake(12.2, 15.5)];
    arrow.lineWidth = 1.5;
    arrow.lineCapStyle = kCGLineCapRound;
    arrow.lineJoinStyle = kCGLineJoinRound;
    [arrow stroke];
    UIImage *image = [UIGraphicsGetImageFromCurrentImageContext() imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    UIGraphicsEndImageContext();
    if (image) [cache setObject:image forKey:key];
    return image;
}
