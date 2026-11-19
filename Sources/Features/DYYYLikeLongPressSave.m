#import "DYYYLikeLongPressSave.h"
#import "DYYYLikeLivePhotoBuilder.h"
#import "DYYYLikeAnimatedImage.h"
#import "DYYYConstants.h"
#import "DYYYManager.h"
#import "DYYYUtils.h"
#import <ImageIO/ImageIO.h>
#import <Photos/Photos.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <limits.h>

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

static NSArray<NSURL *> *DYYYLikeSaveImageURLs(id image, id originalImage) {
    // Preserve server-issued alternatives, never rewrite signatures or use the
    // watermarked downloadURLList. Alternatives let Live Photos use a compatible
    // original container without a local lossy JPEG conversion.
    NSMutableArray<NSURL *> *result = [NSMutableArray array];
    NSMutableSet<NSURL *> *seen = [NSMutableSet set];
    NSArray *models = originalImage ? @[originalImage, image] : @[image];
    for (NSString *key in @[@"watermarkFreeUrlList", @"urlList"]) {
        for (id model in models) {
            for (id value in DYYYLikeSaveArray(DYYYLikeSaveObject(model, key))) {
                NSURL *url = DYYYLikeSaveURL(value);
                if (!url || [seen containsObject:url] || [url.path containsString:@"tplv-dy-water"]) continue;
                [seen addObject:url];
                [result addObject:url];
                if (result.count >= 12) return [result copy];
            }
        }
    }
    return [result copy];
}

static NSError *DYYYLikeSaveError(NSString *reason) {
    return [NSError errorWithDomain:@"DYYYLikeSaveMedia" code:1
        userInfo:@{NSLocalizedDescriptionKey: reason ?: @"保存失败"}];
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

static NSURL *DYYYLikeSavePrepareImage(NSURL *rawURL, BOOL *convertedAnimation, NSError **error) {
    if (convertedAnimation) *convertedAnimation = NO;
    // Inspect the actual file, not a URL's advertised size or extension. Preserve
    // native HEIC/JPEG/PNG/GIF/TIFF bytes (including colour profiles and metadata).
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)rawURL,
        (__bridge CFDictionaryRef)@{(NSString *)kCGImageSourceShouldCache: @NO});
    if (source) {
        NSString *type = (__bridge NSString *)CGImageSourceGetType(source);
        size_t frameCount = CGImageSourceGetCount(source);
        if (frameCount > 1 && ![type isEqualToString:@"com.compuserve.gif"] &&
            ![type isEqualToString:@"public.tiff"]) {
            CFRelease(source);
            NSURL *animation = DYYYLikeConvertAnimatedImageToGIF(rawURL, error);
            if (animation && convertedAnimation) *convertedAnimation = YES;
            return animation; // Never flatten WebP/APNG/HEIC sequences to one PNG.
        }
        NSDictionary *extensions = @{@"public.jpeg": @"jpg", @"public.png": @"png",
            @"public.heic": @"heic", @"public.heif": @"heif", @"public.heics": @"heics",
            @"com.compuserve.gif": @"gif", @"public.tiff": @"tiff"};
        NSString *extension = extensions[type ?: @""];
        NSDictionary *properties = CGImageSourceGetCount(source) ?
            CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL)) : nil;
        BOOL valid = [properties[(NSString *)kCGImagePropertyPixelWidth] unsignedLongLongValue] > 0 &&
                     [properties[(NSString *)kCGImagePropertyPixelHeight] unsignedLongLongValue] > 0;
        CFRelease(source);
        if (valid && extension) {
            if ([rawURL.pathExtension.lowercaseString isEqualToString:extension]) return rawURL;
            NSURL *output = [rawURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:
                [NSString stringWithFormat:@"DYYYLikeSave-%@.%@", NSUUID.UUID.UUIDString, extension]];
            // Correct a misleading download suffix without transcoding the file.
            return [NSFileManager.defaultManager copyItemAtURL:rawURL toURL:output error:error] ? output : nil;
        }
    }
    UIImage *image = [UIImage imageWithContentsOfFile:rawURL.path];
    if (!image.CGImage) {
        NSData *data = [NSData dataWithContentsOfURL:rawURL options:NSDataReadingMappedIfSafe error:error];
        if (!data) return nil;
        Class imageClass = NSClassFromString(@"BDImage");
        SEL selector = NSSelectorFromString(@"imageWithData:scale:decodeForDisplay:shouldScaleDown:error:");
        if ([imageClass respondsToSelector:selector]) {
            @try {
                image = ((UIImage *(*)(id, SEL, NSData *, double, BOOL, BOOL, NSError **))objc_msgSend)
                    (imageClass, selector, data, 1.0, NO, NO, error);
            } @catch (__unused NSException *exception) { image = nil; }
        }
    }
    if (!image.CGImage) return nil;
    NSUInteger decodedFrames = MAX((NSUInteger)MAX(0, DYYYLikeSaveInteger(image, @"frameCount")),
        DYYYLikeSaveArray(DYYYLikeSaveObject(image, @"images")).count);
    if (decodedFrames > 1) {
        if (convertedAnimation) *convertedAnimation = YES;
        if (error) *error = DYYYLikeSaveError(@"该动态图编码暂不支持完整转换，未降级为静图");
        return nil;
    }
    // Unsupported encodings such as VVIC need a compatible container. PNG is
    // lossless at the decoder's actual pixels; never resize or manufacture detail.
    NSData *png = UIImagePNGRepresentation(image);
    if (!png.length) return nil;
    NSURL *output = [rawURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:
        [NSString stringWithFormat:@"DYYYLikeSave-%@.png", NSUUID.UUID.UUIDString]];
    if (![png writeToURL:output options:NSDataWritingAtomic error:error]) return nil;
    return output;
}

static void DYYYLikeValidateLivePhoto(NSURL *photo, NSURL *video, void (^completion)(NSError *)) {
    __block BOOL completed = NO;
    __block PHLivePhotoRequestID requestID = PHLivePhotoRequestIDInvalid;
    void (^finish)(NSError *) = ^(NSError *error) {
        if (completed) return;
        completed = YES;
        completion(error);
    };
    requestID = [PHLivePhoto requestLivePhotoWithResourceFileURLs:@[photo, video]
        placeholderImage:nil targetSize:CGSizeMake(256, 256)
        contentMode:PHImageContentModeAspectFit resultHandler:^(PHLivePhoto *livePhoto, NSDictionary *info) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([info[PHLivePhotoInfoIsDegradedKey] boolValue]) return;
                finish(livePhoto ? nil : (info[PHLivePhotoInfoErrorKey] ?:
                    DYYYLikeSaveError(@"实况配对校验失败，未保存为静图")));
            });
        }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (completed) return;
        [PHLivePhoto cancelLivePhotoRequestWithRequestID:requestID];
        finish(DYYYLikeSaveError(@"实况配对校验超时"));
    });
}

static void DYYYLikeSaveMediaFiles(NSURL *fileURL, NSURL *pairedVideoURL, void (^completion)(BOOL)) {
    // The pair is one asset or a failure, never a misleading static-photo success.
    if (pairedVideoURL && ![PHAssetCreationRequest supportsAssetResourceTypes:
            @[@(PHAssetResourceTypePhoto), @(PHAssetResourceTypePairedVideo)]]) {
        [DYYYUtils showToast:@"当前系统不支持实况照片入库"];
        completion(NO);
        return;
    }
    // Deliberately avoid DYYYManager's caption re-encode and UIImage retry.
    [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus status) {
        if (status != PHAuthorizationStatusAuthorized && status != PHAuthorizationStatusLimited) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [DYYYUtils showToast:@"请允许添加照片到相册后重试"];
                completion(NO);
            });
            return;
        }
        [PHPhotoLibrary.sharedPhotoLibrary performChanges:^{
            PHAssetCreationRequest *request = [PHAssetCreationRequest creationRequestForAsset];
            [request addResourceWithType:PHAssetResourceTypePhoto fileURL:fileURL options:nil];
            if (pairedVideoURL) {
                [request addResourceWithType:PHAssetResourceTypePairedVideo fileURL:pairedVideoURL options:nil];
            }
        } completionHandler:^(BOOL success, __unused NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(success); });
        }];
    }];
}

@interface DYYYLikeImageSaveJob : NSObject
@property(nonatomic, copy) NSArray<NSDictionary *> *items;
@property(nonatomic, strong) NSMutableSet<NSURL *> *temporaryURLs;
@property(nonatomic, strong) NSMutableArray<NSURL *> *downloadURLs;
@property(nonatomic, strong) NSURL *videoFile;
@property(nonatomic, copy) NSString *lastFailure;
@property(nonatomic) NSUInteger candidate;
@property(nonatomic) unsigned long long minimumPixels;
@property(nonatomic) NSUInteger minimumFrames;
@property(nonatomic) BOOL convertedAnimation;
@property(nonatomic) NSUInteger index;
@property(nonatomic) NSUInteger succeeded;
@property(nonatomic) BOOL finished;
- (void)start;
- (void)saveNext;
- (void)finish;
- (void)cleanup:(BOOL)success;
- (void)completeItem:(BOOL)success;
- (void)tryNextImage;
- (void)savePreparedImage:(NSURL *)imageURL;
@end

static DYYYLikeImageSaveJob *gDYYYLikeSaveActiveImageJob;

@implementation DYYYLikeImageSaveJob
- (void)start {
    if (gDYYYLikeSaveActiveImageJob && !gDYYYLikeSaveActiveImageJob.finished) {
        [DYYYUtils showToast:@"正在保存图片，请完成或取消后再试"];
        return;
    }
    gDYYYLikeSaveActiveImageJob = self;
    self.temporaryURLs = [NSMutableSet set];
    self.downloadURLs = [NSMutableArray array];
    if (!self.items.count) { [self finish]; return; }
    [self saveNext];
}
- (void)cleanup:(BOOL)success {
    for (NSURL *url in self.downloadURLs) [[DYYYManager shared] finalizeDownloadWithFileURL:url success:success];
    for (NSURL *url in self.temporaryURLs) DYYYLikeSaveRemoveTemporaryURL(url);
    [self.downloadURLs removeAllObjects];
    [self.temporaryURLs removeAllObjects];
    self.videoFile = nil;
}
- (void)completeItem:(BOOL)success {
    if (self.finished) return;
    if (success) self.succeeded++;
    [self cleanup:success];
    self.index++;
    [self saveNext];
}
- (void)finish {
    if (self.finished) return;
    self.finished = YES;
    [self cleanup:NO];
    if (gDYYYLikeSaveActiveImageJob == self) gDYYYLikeSaveActiveImageJob = nil;
    NSString *message = [NSString stringWithFormat:@"图片/实况保存完成：%lu/%lu 项", (unsigned long)self.succeeded, (unsigned long)self.items.count];
    if (self.convertedAnimation) message = [message stringByAppendingString:@"（动态图按原尺寸GIF保存）"];
    if (self.succeeded < self.items.count && self.lastFailure.length) message = [message stringByAppendingFormat:@"\n%@", self.lastFailure];
    [DYYYUtils showToast:message];
}
- (void)saveNext {
    if (self.finished) return;
    if (self.index >= self.items.count) { [self finish]; return; }
    self.candidate = 0;
    self.minimumPixels = 0;
    self.minimumFrames = 1;
    NSDictionary *item = self.items[self.index];
    if ([item[@"live"] boolValue] && ![item[@"videoURL"] isKindOfClass:NSURL.class]) {
        self.lastFailure = @"实况缺少配套视频，未降级为静图";
        [self completeItem:NO];
        return;
    }
    [self tryNextImage];
}
- (void)tryNextImage {
    if (self.finished) return;
    // Drop failed image alternatives, but retain an already downloaded clip.
    for (NSURL *url in [self.downloadURLs copy]) {
        if ([url isEqual:self.videoFile]) continue;
        [[DYYYManager shared] finalizeDownloadWithFileURL:url success:NO];
        [self.downloadURLs removeObject:url];
    }
    for (NSURL *url in [self.temporaryURLs copy]) {
        if ([url isEqual:self.videoFile]) continue;
        DYYYLikeSaveRemoveTemporaryURL(url);
        [self.temporaryURLs removeObject:url];
    }
    NSDictionary *item = self.items[self.index];
    NSArray<NSURL *> *sources = item[@"imageURLs"];
    if (self.candidate >= sources.count) {
        if (!self.lastFailure.length) self.lastFailure = @"没有可完整保存的无水印图片资源";
        [self completeItem:NO];
        return;
    }
    NSURL *source = sources[self.candidate++];
    [DYYYManager downloadMediaWithProgress:source mediaType:MediaTypeImage audio:nil progress:nil
        completion:^(BOOL downloaded, NSURL *rawURL) {
            if (!downloaded || !rawURL) {
                self.lastFailure = @"下载已取消或失败";
                [self finish]; // Never start further requests after cancellation.
                return;
            }
            [self.downloadURLs addObject:rawURL];
            [self.temporaryURLs addObject:rawURL];
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                @autoreleasepool {
                    NSError *error = nil;
                    BOOL converted = NO;
                    CGImageSourceRef input = CGImageSourceCreateWithURL((__bridge CFURLRef)rawURL, NULL);
                    CFStringRef inputType = input ? CGImageSourceGetType(input) : NULL;
                    BOOL animated = input && CGImageSourceGetCount(input) > 1 &&
                        (!inputType || !CFEqual(inputType, CFSTR("public.tiff")));
                    if (input) CFRelease(input);
                    NSURL *prepared = DYYYLikeSavePrepareImage(rawURL, &converted, &error);
                    CGImageSourceRef output = prepared ? CGImageSourceCreateWithURL((__bridge CFURLRef)prepared, NULL) : NULL;
                    NSDictionary *properties = output && CGImageSourceGetCount(output) ?
                        CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(output, 0, NULL)) : nil;
                    unsigned long long width = [properties[(NSString *)kCGImagePropertyPixelWidth] unsignedLongLongValue];
                    unsigned long long height = [properties[(NSString *)kCGImagePropertyPixelHeight] unsignedLongLongValue];
                    unsigned long long pixels = height && width <= ULLONG_MAX / height ? width * height : 0;
                    NSUInteger frames = output ? CGImageSourceGetCount(output) : 0;
                    if (output) CFRelease(output);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (prepared) [self.temporaryURLs addObject:prepared];
                        if (animated || converted) self.minimumFrames = MAX(self.minimumFrames, 2);
                        BOOL live = [item[@"live"] boolValue];
                        if (!prepared || !pixels || pixels < self.minimumPixels || (!live && frames < self.minimumFrames)) {
                            self.lastFailure = error.localizedDescription ?: @"备用图片丢帧或降低了原始分辨率，未保存";
                            [self tryNextImage];
                            return;
                        }
                        self.minimumPixels = MAX(self.minimumPixels, pixels);
                        self.convertedAnimation |= converted;
                        if (!live || self.videoFile) { [self savePreparedImage:prepared]; return; }
                        [DYYYManager downloadMediaWithProgress:item[@"videoURL"] mediaType:MediaTypeVideo audio:nil progress:nil
                            completion:^(BOOL videoDownloaded, NSURL *videoFile) {
                                if (!videoDownloaded || !videoFile) {
                                    self.lastFailure = @"实况视频下载已取消或失败";
                                    [self finish];
                                    return;
                                }
                                self.videoFile = videoFile;
                                [self.downloadURLs addObject:videoFile];
                                [self.temporaryURLs addObject:videoFile];
                                [self savePreparedImage:prepared];
                            }];
                    });
                }
            });
        }];
}
- (void)savePreparedImage:(NSURL *)imageURL {
    if (self.finished) return;
    NSDictionary *item = self.items[self.index];
    if (![item[@"live"] boolValue]) {
        DYYYLikeSaveMediaFiles(imageURL, nil, ^(BOOL success) {
            if (!success) self.lastFailure = @"图片入库失败，未重新压缩或丢帧重试";
            [self completeItem:success];
        });
        return;
    }
    DYYYLikeBuildLivePhoto(imageURL, self.videoFile, ^(NSURL *photo, NSURL *video, NSError *error) {
        if (self.finished) { DYYYLikeSaveRemoveTemporaryURL(photo); DYYYLikeSaveRemoveTemporaryURL(video); return; }
        if (!photo || !video || error) {
            self.lastFailure = error.localizedDescription ?: @"实况配对失败";
            [self tryNextImage];
            return;
        }
        [self.temporaryURLs addObject:photo];
        [self.temporaryURLs addObject:video];
        DYYYLikeValidateLivePhoto(photo, video, ^(NSError *validationError) {
            if (validationError) {
                self.lastFailure = validationError.localizedDescription;
                [self tryNextImage];
                return;
            }
            DYYYLikeSaveMediaFiles(photo, video, ^(BOOL success) {
                if (!success) self.lastFailure = @"实况照片入库失败，未降级为静图";
                [self completeItem:success];
            });
        });
    });
}
@end

static UIImage *DYYYLikeSaveSymbol(NSString *name) {
    return [UIImage systemImageNamed:name] ?: [UIImage systemImageNamed:@"photo"];
}

static NSDictionary *DYYYLikeSaveItem(NSArray<NSURL *> *URLs, NSURL *videoURL, BOOL live) {
    return @{@"imageURLs": [URLs copy] ?: @[], @"videoURL": videoURL ?: NSNull.null, @"live": @(live)};
}

static NSDictionary *DYYYLikeSaveImageItem(id image, id original, id fallbackVideo) {
    id clip = DYYYLikeSaveObject(original, @"clipVideo") ?: DYYYLikeSaveObject(image, @"clipVideo") ?: fallbackVideo;
    BOOL live = clip != nil || DYYYLikeSaveInteger(image, @"livePhotoType") > 0 ||
        DYYYLikeSaveInteger(original, @"livePhotoType") > 0;
    return DYYYLikeSaveItem(DYYYLikeSaveImageURLs(image, original), DYYYLikeSaveBestVideoURL(clip), live);
}

static BOOL DYYYLikeSaveItemAvailable(NSDictionary *item) {
    return [item[@"imageURLs"] count] > 0 &&
        (![item[@"live"] boolValue] || [item[@"videoURL"] isKindOfClass:NSURL.class]);
}

static UIAction *DYYYLikeSaveImagesAction(NSString *title, NSString *identifier, NSArray<NSDictionary *> *items) {
    // UIAction may be copied. Resources live in this immutable block snapshot.
    NSArray<NSDictionary *> *snapshot = [items copy];
    BOOL available = snapshot.count > 0;
    for (NSDictionary *item in snapshot) available &= DYYYLikeSaveItemAvailable(item);
    NSString *symbol = snapshot.count > 1 ? @"photo.stack" : ([snapshot.firstObject[@"live"] boolValue] ? @"livephoto" : @"photo");
    UIAction *action = [UIAction actionWithTitle:title image:DYYYLikeSaveSymbol(symbol)
        identifier:identifier handler:^(__kindof UIAction *selectedAction) {
            if (!available) { [DYYYUtils showToast:@"图片或实况配套视频资源缺失"]; return; }
            DYYYLikeImageSaveJob *job = [DYYYLikeImageSaveJob new];
            job.items = snapshot;
            [job start];
        }];
    if (!available) action.attributes = UIMenuElementAttributesDisabled;
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
        NSArray *originals = DYYYLikeSaveArray(DYYYLikeSaveObject(model, @"originalAlbumImages"));
        BOOL aligned = originals.count == images.count;
        id fallbackVideo = images.count == 1 && DYYYLikeSaveInteger(model, @"isLivePhoto") ?
            DYYYLikeSaveObject(model, @"video") : nil;
        NSDictionary *current = DYYYLikeSaveImageItem(images[index], aligned ? originals[index] : nil, fallbackVideo);
        NSString *currentTitle = [current[@"live"] boolValue] ? @"保存当前无水印实况" : @"保存当前无水印图";
        [items addObject:DYYYLikeSaveImagesAction(currentTitle, @"DYYYLikeSave.CurrentImage", @[current])];
        if (images.count > 1) {
            NSMutableArray<NSDictionary *> *snapshots = [NSMutableArray arrayWithCapacity:images.count];
            BOOL hasLive = NO, complete = YES;
            for (NSUInteger imageIndex = 0; imageIndex < images.count; imageIndex++) {
                NSDictionary *item = DYYYLikeSaveImageItem(images[imageIndex], aligned ? originals[imageIndex] : nil, nil);
                [snapshots addObject:item];
                hasLive |= [item[@"live"] boolValue];
                complete &= DYYYLikeSaveItemAvailable(item);
            }
            NSString *title = [NSString stringWithFormat:hasLive ? @"保存全部图片/实况（%lu项）" : @"保存全部无水印图（%lu张）", (unsigned long)images.count];
            UIAction *all = DYYYLikeSaveImagesAction(title, @"DYYYLikeSave.AllImages", snapshots);
            if (!complete) {
                if (@available(iOS 15.0, *)) all.subtitle = @"部分图片或实况配套视频资源缺失";
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
    if (cover) [items addObject:DYYYLikeSaveImagesAction(@"保存封面原图", @"DYYYLikeSave.Cover", @[DYYYLikeSaveItem(@[cover], nil, NO)])];
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
