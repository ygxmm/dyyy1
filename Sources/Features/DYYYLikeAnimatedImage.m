#import "DYYYLikeAnimatedImage.h"
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <math.h>
#import <stdint.h>

static NSString * const DYYYLikeAnimatedImageErrorDomain = @"DYYYLikeAnimatedImageErrorDomain";

enum {
    DYYYLikeAnimatedImageInvalidInput = 1,
    DYYYLikeAnimatedImageSourceError,
    DYYYLikeAnimatedImageNotAnimated,
    DYYYLikeAnimatedImageInvalidCanvas,
    DYYYLikeAnimatedImageFrameError,
    DYYYLikeAnimatedImageDestinationError,
    DYYYLikeAnimatedImageWriteError,
    DYYYLikeAnimatedImageVerificationError
};

static NSError *DYYYLikeAnimatedImageMakeError(NSInteger code, NSString *description) {
    return [NSError errorWithDomain:DYYYLikeAnimatedImageErrorDomain
                               code:code
                           userInfo:@{ NSLocalizedDescriptionKey : description }];
}

// ImageIO nests per-frame timing and loop metadata under format-specific dictionaries.
static NSNumber *DYYYLikeAnimatedImageNumber(NSDictionary *properties, NSString *fragment,
                                               BOOL preferUnclamped) {
    NSArray<NSString *> *needles = preferUnclamped
        ? @[ @"unclampeddelaytime", @"delaytime" ] : @[ fragment ];
    for (NSString *needle in needles) {
        for (id value in properties.allValues) {
            if (![value isKindOfClass:NSDictionary.class]) continue;
            NSDictionary *nested = (NSDictionary *)value;
            for (id key in nested) {
                if (![key isKindOfClass:NSString.class] ||
                    ![[(NSString *)key lowercaseString] containsString:needle]) continue;
                id number = nested[key];
                if (![number isKindOfClass:NSNumber.class]) continue;
                double scalar = [number doubleValue];
                if (isfinite(scalar) && scalar >= 0) return number;
            }
        }
    }
    return nil;
}

static size_t DYYYLikeAnimatedImageDimension(NSDictionary *properties, NSString *key) {
    id value = properties[key];
    if (![value respondsToSelector:@selector(unsignedLongLongValue)]) return 0;
    unsigned long long dimension = [value unsignedLongLongValue];
    return dimension > 0 && dimension <= SIZE_MAX ? (size_t)dimension : 0;
}

static NSString *DYYYLikeAnimatedImageOutputPath(void) {
    NSString *name = [NSString stringWithFormat:@"DYYYLike_%@.gif", NSUUID.UUID.UUIDString];
    return [NSTemporaryDirectory() stringByAppendingPathComponent:name];
}

NSURL *DYYYLikeConvertAnimatedImageToGIF(NSURL *sourceURL, NSError **error) {
    if (error) *error = nil;
    CGImageSourceRef source = NULL, verification = NULL;
    CGImageDestinationRef destination = NULL;
    NSError *failure = nil;
    NSURL *outputURL = nil;
    BOOL succeeded = NO;
    do {
        if (![sourceURL isKindOfClass:NSURL.class] || !sourceURL.isFileURL) {
            failure = DYYYLikeAnimatedImageMakeError(DYYYLikeAnimatedImageInvalidInput, @"需要本地动画文件URL");
            break;
        }
        NSDictionary *options = @{ (__bridge NSString *)kCGImageSourceShouldCache : @NO };
        source = CGImageSourceCreateWithURL((__bridge CFURLRef)sourceURL, (__bridge CFDictionaryRef)options);
        if (!source || CGImageSourceGetStatus(source) != kCGImageStatusComplete) {
            failure = DYYYLikeAnimatedImageMakeError(DYYYLikeAnimatedImageSourceError, @"ImageIO无法完整读取源文件");
            break;
        }
        size_t count = CGImageSourceGetCount(source);
        if (count < 2) {
            failure = DYYYLikeAnimatedImageMakeError(DYYYLikeAnimatedImageNotAnimated, @"源文件不是多帧动画；不允许降级为静图");
            break;
        }
        NSDictionary *global = CFBridgingRelease(CGImageSourceCopyProperties(source, NULL));
        NSDictionary *first = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
        size_t width = DYYYLikeAnimatedImageDimension(global, (__bridge NSString *)kCGImagePropertyPixelWidth);
        size_t height = DYYYLikeAnimatedImageDimension(global, (__bridge NSString *)kCGImagePropertyPixelHeight);
        if (!width) width = DYYYLikeAnimatedImageDimension(first, (__bridge NSString *)kCGImagePropertyPixelWidth);
        if (!height) height = DYYYLikeAnimatedImageDimension(first, (__bridge NSString *)kCGImagePropertyPixelHeight);
        if (!width || !height || width > 65535 || height > 65535) {
            failure = DYYYLikeAnimatedImageMakeError(DYYYLikeAnimatedImageInvalidCanvas, @"源画布缺失或超出GIF尺寸限制");
            break;
        }
        NSNumber *loop = DYYYLikeAnimatedImageNumber(global, @"loopcount", NO);
        if (!loop) loop = DYYYLikeAnimatedImageNumber(first, @"loopcount", NO);
        if (loop && (loop.doubleValue > 65535 || floor(loop.doubleValue) != loop.doubleValue)) {
            failure = DYYYLikeAnimatedImageMakeError(DYYYLikeAnimatedImageSourceError, @"循环次数无法用GIF表达");
            break;
        }
        outputURL = [NSURL fileURLWithPath:DYYYLikeAnimatedImageOutputPath()];
        // Stable GIF UTI: no newer UTType/WebP symbols or MobileCoreServices linkage.
        destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)outputURL,
                                                       CFSTR("com.compuserve.gif"), count, NULL);
        if (!destination) {
            failure = DYYYLikeAnimatedImageMakeError(DYYYLikeAnimatedImageDestinationError, @"无法创建GIF输出");
            break;
        }
        if (loop) {
            NSDictionary *properties = @{ (__bridge NSString *)kCGImagePropertyGIFDictionary :
                @{ (__bridge NSString *)kCGImagePropertyGIFLoopCount : loop } };
            CGImageDestinationSetProperties(destination, (__bridge CFDictionaryRef)properties);
        }
        // Absent loop metadata means no loop extension, not forced infinite playback.
        NSMutableArray<NSNumber *> *delays = [NSMutableArray arrayWithCapacity:count];
        for (size_t index = 0; index < count; index++) {
            @autoreleasepool {
                NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, index, NULL));
                NSNumber *delay = DYYYLikeAnimatedImageNumber(properties, @"delaytime", YES);
                CGImageRef frame = CGImageSourceCreateImageAtIndex(source, index, (__bridge CFDictionaryRef)options);
                if (!frame || CGImageSourceGetStatusAtIndex(source, index) != kCGImageStatusComplete ||
                    CGImageGetWidth(frame) != width || CGImageGetHeight(frame) != height ||
                    !delay || delay.doubleValue > 655.35) {
                    failure = DYYYLikeAnimatedImageMakeError(DYYYLikeAnimatedImageFrameError,
                        [NSString stringWithFormat:@"第%zu帧解码、完整画布或时长无效；不跳过坏帧", index]);
                } else {
                    NSDictionary *frameProperties = @{ (__bridge NSString *)kCGImagePropertyGIFDictionary : @{
                        (__bridge NSString *)kCGImagePropertyGIFDelayTime : delay,
                        (__bridge NSString *)kCGImagePropertyGIFUnclampedDelayTime : delay } };
                    CGImageDestinationAddImage(destination, frame, (__bridge CFDictionaryRef)frameProperties);
                    [delays addObject:delay];
                }
                if (frame) CGImageRelease(frame);
            }
            if (failure) break;
        }
        if (failure) break;
        if (!CGImageDestinationFinalize(destination)) {
            failure = DYYYLikeAnimatedImageMakeError(DYYYLikeAnimatedImageWriteError, @"GIF完整写入失败");
            break;
        }
        CFRelease(destination);
        destination = NULL;
        verification = CGImageSourceCreateWithURL((__bridge CFURLRef)outputURL, (__bridge CFDictionaryRef)options);
        if (!verification || CGImageSourceGetStatus(verification) != kCGImageStatusComplete ||
            !CGImageSourceGetType(verification) ||
            !CFEqual(CGImageSourceGetType(verification), CFSTR("com.compuserve.gif")) ||
            CGImageSourceGetCount(verification) != count) {
            failure = DYYYLikeAnimatedImageMakeError(DYYYLikeAnimatedImageVerificationError, @"输出GIF类型或完整帧数验证失败");
            break;
        }
        NSDictionary *written = CFBridgingRelease(CGImageSourceCopyProperties(verification, NULL));
        NSDictionary *writtenFirst = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(verification, 0, NULL));
        NSNumber *writtenLoop = DYYYLikeAnimatedImageNumber(written, @"loopcount", NO);
        if (!writtenLoop) writtenLoop = DYYYLikeAnimatedImageNumber(writtenFirst, @"loopcount", NO);
        if ((loop && (!writtenLoop || ![loop isEqualToNumber:writtenLoop])) || (!loop && writtenLoop)) {
            failure = DYYYLikeAnimatedImageMakeError(DYYYLikeAnimatedImageVerificationError, @"输出GIF循环次数验证失败");
            break;
        }
        for (size_t index = 0; index < count; index++) {
            @autoreleasepool {
                CGImageRef frame = CGImageSourceCreateImageAtIndex(verification, index, (__bridge CFDictionaryRef)options);
                NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(verification, index, NULL));
                NSNumber *delay = DYYYLikeAnimatedImageNumber(properties, @"delaytime", YES);
                // GIF stores centiseconds; do not invent a default or minimum source delay.
                if (!frame || CGImageSourceGetStatusAtIndex(verification, index) != kCGImageStatusComplete ||
                    CGImageGetWidth(frame) != width || CGImageGetHeight(frame) != height || !delay ||
                    fabs(delay.doubleValue - delays[index].doubleValue) > 0.0100001) {
                    failure = DYYYLikeAnimatedImageMakeError(DYYYLikeAnimatedImageVerificationError,
                        [NSString stringWithFormat:@"输出GIF第%zu帧、画布或时长验证失败", index]);
                }
                if (frame) CGImageRelease(frame);
            }
            if (failure) break;
        }
        succeeded = failure == nil;
    } while (NO);
    if (verification) CFRelease(verification);
    if (destination) CFRelease(destination);
    if (source) CFRelease(source);
    if (!succeeded) {
        if (outputURL) [[NSFileManager defaultManager] removeItemAtURL:outputURL error:NULL];
        if (error) *error = failure ?: DYYYLikeAnimatedImageMakeError(DYYYLikeAnimatedImageWriteError, @"GIF转换失败");
        return nil;
    }
    return outputURL;
}
