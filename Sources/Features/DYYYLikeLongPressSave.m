#import "DYYYLikeLongPressSave.h"
#import "DYYYLikeLivePhotoBuilder.h"
#import "DYYYLikeAnimatedImage.h"
#import "DYYYAlbumImageDescription.h"
#import "DYYYMediaSourceSelection.h"
#import "DYYYConstants.h"
#import "DYYYManager.h"
#import "DYYYUtils.h"
#import "DYYYToast.h"
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

static NSError *DYYYLikeSaveError(NSString *reason) {
    return [NSError errorWithDomain:@"DYYYLikeSaveMedia" code:1
        userInfo:@{NSLocalizedDescriptionKey: reason ?: @"保存失败"}];
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

static void DYYYLikeSaveMediaFiles(NSURL *fileURL, NSURL *pairedVideoURL, NSDate *creationDate, void (^completion)(NSError *)) {
    if (pairedVideoURL && ![PHAssetCreationRequest supportsAssetResourceTypes:
            @[@(PHAssetResourceTypePhoto), @(PHAssetResourceTypePairedVideo)]]) {
        completion(DYYYLikeSaveError(@"当前系统不支持实况入库"));
        return;
    }
    // One transaction per page. Never retry a rejected Live Photo as a still.
    [PHPhotoLibrary.sharedPhotoLibrary performChanges:^{
        PHAssetCreationRequest *request = [PHAssetCreationRequest creationRequestForAsset];
        if (creationDate) request.creationDate = creationDate;
        [request addResourceWithType:PHAssetResourceTypePhoto fileURL:fileURL options:nil];
        if (pairedVideoURL) {
            [request addResourceWithType:PHAssetResourceTypePairedVideo fileURL:pairedVideoURL options:nil];
        }
    } completionHandler:^(BOOL success, NSError *error) {
        NSError *failure = success ? nil : DYYYLikeSaveError(error ?
            [NSString stringWithFormat:@"相册入库失败（%@ %ld）", error.domain, (long)error.code] : @"相册入库失败");
        dispatch_async(dispatch_get_main_queue(), ^{ completion(failure); });
    }];
}

@interface DYYYLikeGallerySaveJob : NSObject
@property(nonatomic, copy) NSArray<NSDictionary *> *items;
@property(nonatomic, copy) NSArray<NSDate *> *albumDates;
@property(nonatomic, copy) NSString *albumDescription;
@property(nonatomic, strong) NSMutableSet<NSURL *> *temporaryURLs;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSURLSessionDownloadTask *task;
@property(nonatomic, strong) DYYYToast *progressView;
@property(nonatomic, strong) NSURL *videoFile;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *failedPages;
@property(nonatomic, copy) NSString *lastFailure;
@property(nonatomic, copy) NSString *pageFailure;
@property(nonatomic) NSUInteger candidate;
@property(nonatomic) NSUInteger videoCandidate;
@property(nonatomic) unsigned long long minimumPixels;
@property(nonatomic) NSUInteger minimumFrames;
@property(nonatomic) BOOL cancelled;
@property(nonatomic) NSUInteger index;
@property(nonatomic) NSUInteger succeeded;
@property(nonatomic) BOOL finished;
- (void)start;
- (void)saveNext;
- (void)finish;
- (void)completeItem:(NSString *)failure;
- (void)tryNextImage;
- (void)tryNextVideoForImage:(NSURL *)imageURL;
- (void)savePreparedImage:(NSURL *)imageURL;
@end

static DYYYLikeGallerySaveJob *gDYYYLikeSaveActiveGallery;

@implementation DYYYLikeGallerySaveJob
- (void)start {
    if (gDYYYLikeSaveActiveGallery) {
        [DYYYUtils showToast:@"已有图集正在保存，可点进度条取消"];
        return;
    }
    if (!self.items.count) return;
    gDYYYLikeSaveActiveGallery = self;
    self.temporaryURLs = [NSMutableSet set];
    self.failedPages = [NSMutableArray array];
    [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (status != PHAuthorizationStatusAuthorized && status != PHAuthorizationStatusLimited) {
                self.lastFailure = @"请允许添加照片到相册后重试";
                [self finish];
                return;
            }
            NSMutableArray<NSNumber *> *livePages = [NSMutableArray arrayWithCapacity:self.items.count];
            for (NSDictionary *item in self.items) {
                [livePages addObject:@([item[@"live"] boolValue] && [item[@"imageURLs"] count] && [item[@"videoURLs"] count])];
            }
            self.albumDates = DYYYLikeLivePhotoAlbumDates(livePages, NSDate.date);
            NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
            config.HTTPShouldSetCookies = NO;
            config.URLCredentialStorage = nil;
            config.timeoutIntervalForRequest = 20;
            config.timeoutIntervalForResource = 60;
            self.session = [NSURLSession sessionWithConfiguration:config];
            self.progressView = [[DYYYToast alloc] initWithFrame:UIScreen.mainScreen.bounds];
            __weak typeof(self) weakSelf = self;
            self.progressView.cancelBlock = ^{
                typeof(self) job = weakSelf;
                job.cancelled = YES;
                [job.task cancel];
                // Outstanding processing owns its files until its next callback.
            };
            [self.progressView show];
            [self saveNext];
        });
    }];
}
- (void)cleanupPage {
    for (NSURL *url in self.temporaryURLs) DYYYLikeSaveRemoveTemporaryURL(url);
    [self.temporaryURLs removeAllObjects];
    self.videoFile = nil;
}
- (void)completeItem:(NSString *)failure {
    if (self.finished) return;
    if (!failure) {
        self.succeeded++;
    } else if (!self.cancelled) {
        NSUInteger page = [self.items[self.index][@"page"] unsignedIntegerValue];
        [self.failedPages addObject:@(page ?: self.index + 1)];
        self.lastFailure = [NSString stringWithFormat:@"第 %@ 页：%@", self.failedPages.lastObject, failure];
    }
    [self cleanupPage];
    self.index++;
    [self.progressView setProgress:(float)self.index / self.items.count];
    dispatch_async(dispatch_get_main_queue(), ^{ [self saveNext]; });
}
- (void)finish {
    if (self.finished) return;
    self.finished = YES;
    [self cleanupPage];
    [self.session finishTasksAndInvalidate];
    self.session = nil;
    self.progressView.cancelBlock = nil;
    if (!self.cancelled) {
        self.progressView.allowSuccessAnimation = self.succeeded == self.items.count;
        [self.progressView dismiss];
    }
    self.progressView = nil;
    if (gDYYYLikeSaveActiveGallery == self) gDYYYLikeSaveActiveGallery = nil;
    NSMutableString *message = [NSMutableString stringWithFormat:@"%@：已保存 %lu/%lu 页",
        self.cancelled ? @"已取消" : @"保存完成", (unsigned long)self.succeeded, (unsigned long)self.items.count];
    if (self.failedPages.count) {
        NSMutableArray<NSString *> *pages = [NSMutableArray array];
        for (NSNumber *page in self.failedPages) {
            if (pages.count == 8) { [pages addObject:@"…"]; break; }
            [pages addObject:page.stringValue];
        }
        [message appendFormat:@"\n失败页：%@", [pages componentsJoinedByString:@"、"]];
    }
    if (self.lastFailure.length) [message appendFormat:@"\n%@", self.lastFailure];
    [DYYYUtils showToast:message];
}
- (void)download:(NSURL *)source extension:(NSString *)extension completion:(void (^)(NSURL *, NSString *))completion {
    if (self.cancelled) { [self finish]; return; }
    // Never share a basename between pages, image and clip, or other download features.
    NSURL *destination = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:
        [NSString stringWithFormat:@"DYYYLikePage-%@.%@", NSUUID.UUID.UUIDString, extension]];
    self.task = [self.session downloadTaskWithURL:source completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        NSString *failure = nil;
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        NSString *mime = response.MIMEType.lowercaseString;
        if (error) failure = [NSString stringWithFormat:@"网络下载失败（%ld）", (long)error.code];
        else if (status != 200) failure = [NSString stringWithFormat:@"资源下载失败（HTTP %ld）", (long)status];
        else if (!location || [mime hasPrefix:@"text/"] || [mime containsString:@"json"] || [mime containsString:@"xml"]) failure = @"服务器未返回媒体文件";
        else {
            NSNumber *size = nil;
            if (![location getResourceValue:&size forKey:NSURLFileSizeKey error:nil] || !size.unsignedLongLongValue)
                failure = @"媒体文件为空";
            else if (![NSFileManager.defaultManager moveItemAtURL:location toURL:destination error:nil])
                failure = @"媒体临时文件写入失败";
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.task = nil;
            if (!failure) [self.temporaryURLs addObject:destination];
            if (self.cancelled) { [self finish]; return; }
            completion(failure ? nil : destination, failure);
        });
    }];
    [self.task resume];
}
- (void)saveNext {
    if (self.finished) return;
    if (self.cancelled || self.index >= self.items.count) { [self finish]; return; }
    [self.progressView setProgress:(float)self.index / self.items.count];
    self.candidate = self.videoCandidate = 0;
    self.minimumPixels = 0;
    self.minimumFrames = 1;
    self.pageFailure = nil;
    NSDictionary *item = self.items[self.index];
    if ([item[@"live"] boolValue] && ![item[@"videoURLs"] count]) {
        [self completeItem:@"该页实况缺少配套视频，未保存为静图"];
        return;
    }
    [self tryNextImage];
}
- (void)tryNextImage {
    if (self.cancelled) { [self finish]; return; }
    // Retry a cover without touching this page's already downloaded video.
    for (NSURL *url in self.temporaryURLs.allObjects) {
        if ([url isEqual:self.videoFile]) continue;
        DYYYLikeSaveRemoveTemporaryURL(url);
        [self.temporaryURLs removeObject:url];
    }
    NSDictionary *item = self.items[self.index];
    NSArray<NSURL *> *sources = item[@"imageURLs"];
    if (self.candidate >= sources.count) {
        [self completeItem:self.pageFailure ?: @"该页没有可完整保存的无水印图片"];
        return;
    }
    [self download:sources[self.candidate++] extension:@"image" completion:^(NSURL *rawURL, NSString *failure) {
        if (!rawURL) {
            self.pageFailure = failure;
            [self tryNextImage];
            return;
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            @autoreleasepool {
                NSError *error = nil;
                BOOL converted = NO;
                CGImageSourceRef input = CGImageSourceCreateWithURL((__bridge CFURLRef)rawURL, NULL);
                CFStringRef inputType = input ? CGImageSourceGetType(input) : NULL;
                size_t inputFrames = input && (!inputType || !CFEqual(inputType, CFSTR("public.tiff"))) ? CGImageSourceGetCount(input) : 0;
                if (input) CFRelease(input);
                NSURL *prepared = DYYYLikeSavePrepareImage(rawURL, &converted, &error);
                CGImageSourceRef output = prepared ? CGImageSourceCreateWithURL((__bridge CFURLRef)prepared, NULL) : NULL;
                NSUInteger frames = output ? CGImageSourceGetCount(output) : 0;
                NSDictionary *properties = frames ? CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(output, CGImageSourceGetPrimaryImageIndex(output), NULL)) : nil;
                unsigned long long width = [properties[(NSString *)kCGImagePropertyPixelWidth] unsignedLongLongValue];
                unsigned long long height = [properties[(NSString *)kCGImagePropertyPixelHeight] unsignedLongLongValue];
                unsigned long long pixels = height && width <= ULLONG_MAX / height ? width * height : 0;
                if (output) CFRelease(output);
                NSURL *described = pixels ? DYYYCopyImageWithAlbumDescription(prepared, self.albumDescription) : nil;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (prepared) [self.temporaryURLs addObject:prepared];
                    if (described) [self.temporaryURLs addObject:described];
                    if (self.cancelled) { [self finish]; return; }
                    self.minimumFrames = MAX(self.minimumFrames, MAX(inputFrames, converted ? 2 : 1));
                    BOOL live = [item[@"live"] boolValue];
                    if (!prepared || !pixels || pixels < self.minimumPixels || (!live && frames < self.minimumFrames)) {
                        self.pageFailure = error.localizedDescription ?: @"该页图片不可解码、丢帧或画质降低";
                        [self tryNextImage];
                        return;
                    }
                    self.minimumPixels = MAX(self.minimumPixels, pixels);
                    NSURL *ready = described ?: prepared;
                    if (live && !self.videoFile) [self tryNextVideoForImage:ready];
                    else [self savePreparedImage:ready];
                });
            }
        });
    }];
}
- (void)tryNextVideoForImage:(NSURL *)imageURL {
    NSArray<NSURL *> *sources = self.items[self.index][@"videoURLs"];
    if (self.videoCandidate >= sources.count) {
        [self completeItem:self.pageFailure ?: @"该页实况视频不可用"];
        return;
    }
    [self download:sources[self.videoCandidate++] extension:@"mp4" completion:^(NSURL *video, NSString *failure) {
        if (!video) {
            self.pageFailure = [@"实况配套视频：" stringByAppendingString:failure ?: @"下载失败"];
            [self tryNextVideoForImage:imageURL];
            return;
        }
        self.videoFile = video;
        [self savePreparedImage:imageURL];
    }];
}
- (void)savePreparedImage:(NSURL *)imageURL {
    if (self.cancelled) { [self finish]; return; }
    NSDate *creationDate = self.albumDates[self.index];
    if (![self.items[self.index][@"live"] boolValue]) {
        DYYYLikeSaveMediaFiles(imageURL, nil, creationDate, ^(NSError *error) {
            [self completeItem:error.localizedDescription];
        });
        return;
    }
    DYYYLikeBuildLivePhoto(imageURL, self.videoFile, self.albumDescription, ^(NSURL *photo, NSURL *video, NSError *error) {
        if (photo) [self.temporaryURLs addObject:photo];
        if (video) [self.temporaryURLs addObject:video];
        if (self.cancelled) { [self finish]; return; }
        if (!photo || !video || error) {
            self.pageFailure = error.localizedDescription ?: @"该页实况配对失败，未退回静图";
            if (DYYYLikeLivePhotoHasVideoError(error)) {
                DYYYLikeSaveRemoveTemporaryURL(self.videoFile);
                [self.temporaryURLs removeObject:self.videoFile];
                self.videoFile = nil;
                [self tryNextVideoForImage:imageURL];
            } else {
                [self tryNextImage];
            }
            return;
        }
        // The builder validates the pair; PhotoKit, not the preview renderer,
        // is the final authority on whether both resources were committed.
        DYYYLikeSaveMediaFiles(photo, video, creationDate, ^(NSError *saveError) {
            [self completeItem:saveError.localizedDescription];
        });
    });
}
@end

static UIImage *DYYYLikeSaveSymbol(NSString *name) {
    return [UIImage systemImageNamed:name] ?: [UIImage systemImageNamed:@"photo"];
}

static NSString *DYYYLikeSaveImageKey(id image, NSString *selector) {
    id key = DYYYLikeSaveObject(image, selector);
    return [key isKindOfClass:NSString.class] && [key length] ? key : nil;
}

static id DYYYLikeSaveMatchingOriginal(id image, NSArray *originals) {
    // The album list may be filtered or reordered. Equal counts/indexes do not
    // prove that a cover and a clip belong to the same page.
    NSString *imageID = DYYYLikeSaveImageKey(image, @"imgId");
    NSString *uri = DYYYLikeSaveImageKey(image, @"uri");
    id match = nil;
    for (id candidate in originals) {
        if (image == candidate) return image;
        NSString *otherID = DYYYLikeSaveImageKey(candidate, @"imgId");
        BOOL same = imageID && otherID ? [imageID isEqualToString:otherID] :
            [uri isEqualToString:DYYYLikeSaveImageKey(candidate, @"uri")];
        if (!same) continue;
        if (match) return nil; // No cross-page fallback if the identifier is ambiguous.
        match = candidate;
    }
    return match;
}

static NSDictionary *DYYYLikeSaveItem(NSArray<NSURL *> *images, NSArray<NSURL *> *videos, BOOL live, NSUInteger page) {
    return @{@"imageURLs": [images copy] ?: @[], @"videoURLs": [videos copy] ?: @[], @"live": @(live), @"page": @(page)};
}

static NSDictionary *DYYYLikeSaveImageItem(id image, id original, id fallbackVideo, NSUInteger page) {
    id visibleClip = DYYYLikeSaveObject(image, @"clipVideo");
    id originalClip = DYYYLikeSaveObject(original, @"clipVideo");
    BOOL live = visibleClip || originalClip || fallbackVideo || DYYYLikeSaveInteger(image, @"livePhotoType") > 0 ||
        DYYYLikeSaveInteger(original, @"livePhotoType") > 0;
    NSArray<NSURL *> *videos = DYYYMediaSourceLiveVideoURLs(visibleClip);
    if (!videos.count) videos = DYYYMediaSourceLiveVideoURLs(originalClip ?: fallbackVideo);
    return DYYYLikeSaveItem(DYYYMediaSourceImageURLs(image, original), videos, live, page);
}

static BOOL DYYYLikeSaveItemAvailable(NSDictionary *item) {
    return [item[@"imageURLs"] count] > 0 && (![item[@"live"] boolValue] || [item[@"videoURLs"] count] > 0);
}

static NSArray<NSDictionary *> *DYYYLikeSaveGalleryItems(id model, NSArray *images) {
    NSArray *originals = DYYYLikeSaveArray(DYYYLikeSaveObject(model, @"originalAlbumImages"));
    BOOL singleLive = images.count == 1 && originals.count <= 1 && DYYYLikeSaveInteger(model, @"isLivePhoto");
    id clip = singleLive && DYYYLikeSaveObject(model, @"animatedImageVideoInfo") ?
        DYYYLikeSaveObject(model, @"video") : nil;
    NSMutableArray<NSDictionary *> *items = [NSMutableArray arrayWithCapacity:images.count];
    for (NSUInteger i = 0; i < images.count; i++) {
        id image = images[i];
        id original = DYYYLikeSaveMatchingOriginal(image, originals);
        NSDictionary *item = DYYYLikeSaveImageItem(image, original, clip, i + 1);
        if (singleLive && ![item[@"live"] boolValue]) item = DYYYLikeSaveItem(item[@"imageURLs"], @[], YES, i + 1);
        [items addObject:item];
    }
    return [items copy];
}

static NSUInteger DYYYLikeSaveCurrentIndex(id model, NSUInteger count) {
    NSInteger nativeIndex = DYYYLikeSaveInteger(model, @"currentImageIndex");
    return nativeIndex > 0 && (NSUInteger)nativeIndex <= count ? (NSUInteger)nativeIndex - 1 : 0;
}

static void DYYYLikeStartGallerySave(NSArray<NSDictionary *> *items, NSString *description) {
    if (!items.count) {
        [DYYYUtils showToast:@"没有找到合适格式的图片"];
        return;
    }
    DYYYLikeGallerySaveJob *job = [DYYYLikeGallerySaveJob new];
    job.items = items;
    job.albumDescription = description;
    [job start];
}

static NSURL *DYYYLikeSaveMusicURL(AWEAwemeModel *model) {
    id music = DYYYLikeSaveObject(model, @"music");
    return DYYYMediaSourceURLs(DYYYLikeSaveObject(music, @"playURL")).firstObject;
}

static void DYYYLikeSaveVideoResource(AWEAwemeModel *model, NSURL *videoURL, NSURL *audioURL) {
    if (!videoURL) {
        [DYYYUtils showToast:@"没有可用的无水印视频源"];
        return;
    }
    // The existing video writer imports the file as-is; optional audio and
    // album description use AVAssetExportPresetPassthrough.
    [DYYYManager setAlbumDescriptionContextWithAwemeModel:model];
    [DYYYManager downloadMedia:videoURL mediaType:MediaTypeVideo audio:audioURL completion:nil];
}

static NSArray<NSDictionary *> *DYYYLikeSaveCoverItems(id video) {
    NSArray<NSURL *> *covers = DYYYMediaSourceCoverURLs(video);
    return covers.count ? @[DYYYLikeSaveItem(covers, @[], NO, 1)] : @[];
}

void DYYYSaveMenuMedia(AWEAwemeModel *model, DYYYMenuMediaSaveAction action) {
    id video = DYYYLikeSaveObject(model, @"video");
    if (action == DYYYMenuMediaSaveVideo) {
        DYYYLikeSaveVideoResource(model, DYYYMediaSourceHighestVideoURLs(video).firstObject, DYYYLikeSaveMusicURL(model));
        return;
    }
    NSArray<NSDictionary *> *items = @[];
    if (action == DYYYMenuMediaSaveCover) {
        items = DYYYLikeSaveCoverItems(video);
    } else if (DYYYLikeSaveInteger(model, @"awemeType") == 68) {
        items = DYYYLikeSaveGalleryItems(model, DYYYLikeSaveArray(DYYYLikeSaveObject(model, @"albumImages")));
        if (action == DYYYMenuMediaSaveCurrent && items.count) {
            items = @[items[DYYYLikeSaveCurrentIndex(model, items.count)]];
        }
    } else if (action == DYYYMenuMediaSaveCurrent && DYYYLikeSaveObject(model, @"animatedImageVideoInfo")) {
        items = @[DYYYLikeSaveItem(DYYYMediaSourceCoverURLs(video), DYYYMediaSourceLiveVideoURLs(video), YES, 1)];
    }
    NSString *description = [NSUserDefaults.standardUserDefaults boolForKey:DYYY_ALBUM_MEDIA_DESCRIPTION_KEY] ?
        [DYYYManager albumDescriptionForAwemeModel:model] : nil;
    DYYYLikeStartGallerySave(items, description);
}

static UIAction *DYYYLikeSaveImagesAction(NSString *title, NSString *identifier, NSArray<NSDictionary *> *items) {
    // UIAction may be copied. Resources live in this immutable block snapshot.
    NSArray<NSDictionary *> *snapshot = [items copy];
    BOOL available = NO;
    for (NSDictionary *item in snapshot) if (DYYYLikeSaveItemAvailable(item)) { available = YES; break; }
    NSString *symbol = snapshot.count > 1 ? @"photo.stack" : ([snapshot.firstObject[@"live"] boolValue] ? @"livephoto" : @"photo");
    UIAction *action = [UIAction actionWithTitle:title image:DYYYLikeSaveSymbol(symbol)
        identifier:identifier handler:^(__kindof UIAction *selectedAction) {
            DYYYLikeStartGallerySave(snapshot, nil);
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
        NSArray<NSDictionary *> *snapshots = DYYYLikeSaveGalleryItems(model, images);
        NSUInteger index = DYYYLikeSaveCurrentIndex(model, snapshots.count);
        BOOL hasLive = NO, complete = YES;
        for (NSDictionary *item in snapshots) {
            hasLive |= [item[@"live"] boolValue];
            complete &= DYYYLikeSaveItemAvailable(item);
        }
        NSDictionary *current = snapshots[index];
        NSString *currentTitle = [current[@"live"] boolValue] ? @"保存当前无水印实况" : @"保存当前无水印图";
        if (images.count > 1) currentTitle = [currentTitle stringByAppendingFormat:@"（第 %lu 页）", (unsigned long)(index + 1)];
        [items addObject:DYYYLikeSaveImagesAction(currentTitle, @"DYYYLikeSave.CurrentImage", @[current])];
        if (images.count > 1) {
            NSString *title = [NSString stringWithFormat:hasLive ? @"逐页保存全部图片/实况（%lu项）" : @"保存全部无水印图（%lu张）", (unsigned long)images.count];
            UIAction *all = DYYYLikeSaveImagesAction(title, @"DYYYLikeSave.AllImages", snapshots);
            if (!complete) {
                if (@available(iOS 15.0, *)) all.subtitle = @"缺少资源的页会跳过，不影响其他页";
            }
            [items addObject:all];
        }
        return items;
    }
    id video = DYYYLikeSaveObject(model, @"video");
    NSURL *videoURL = DYYYMediaSourceHighestVideoURLs(video).firstObject;
    if (videoURL) {
        NSURL *audioURL = DYYYLikeSaveMusicURL(model);
        UIAction *saveVideo = [UIAction actionWithTitle:@"保存原画质视频" image:DYYYLikeSaveSymbol(@"square.and.arrow.down")
            identifier:@"DYYYLikeSave.Video" handler:^(__kindof UIAction *selectedAction) {
                DYYYLikeSaveVideoResource(model, videoURL, audioURL);
            }];
        [items addObject:saveVideo];
    }
    NSArray<NSDictionary *> *covers = DYYYLikeSaveCoverItems(video);
    if (covers.count) [items addObject:DYYYLikeSaveImagesAction(@"保存封面原图", @"DYYYLikeSave.Cover", covers)];
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
