#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <AudioToolbox/AudioToolbox.h>
#import "../../Sources/Features/DYYYLikeLivePhotoBuilder.h"
#import "../../Sources/Features/DYYYLikeAnimatedImage.h"
#include <stdarg.h>
#include <stdint.h>
#include <math.h>
#include <CommonCrypto/CommonDigest.h>

static int gPasses = 0;
static int gFailures = 0;

static void Check(BOOL condition, NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (condition) {
        gPasses++;
        fprintf(stdout, "PASS %s\n", message.UTF8String);
    } else {
        gFailures++;
        fprintf(stderr, "FAIL %s\n", message.UTF8String);
    }
    fflush(stdout);
    fflush(stderr);
}

static BOOL PumpUntil(BOOL (^condition)(void), NSTimeInterval timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!condition() && [deadline timeIntervalSinceNow] > 0) {
        @autoreleasepool {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, true);
        }
    }
    return condition();
}

static NSURL *MakeTempDirectory(void) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"DYYYMediaTests-%@", NSUUID.UUID.UUIDString]];
    NSError *error = nil;
    BOOL made = [[NSFileManager defaultManager] createDirectoryAtPath:path
                                              withIntermediateDirectories:NO
                                                               attributes:nil error:&error];
    Check(made, @"create isolated temporary directory%@", error ? [NSString stringWithFormat:@" (%@)", error] : @"");
    return made ? [NSURL fileURLWithPath:path isDirectory:YES] : nil;
}

static NSURL *WriteData(NSData *data, NSURL *directory, NSString *name) {
    NSURL *url = [directory URLByAppendingPathComponent:name];
    NSError *error = nil;
    BOOL written = [data writeToURL:url options:NSDataWritingAtomic error:&error];
    Check(written, @"write fixture %@%@", name,
          error ? [NSString stringWithFormat:@" (%@)", error] : @"");
    return written ? url : nil;
}

static NSData *Base64(NSString *text) {
    return [[NSData alloc] initWithBase64EncodedString:text options:0];
}

static BOOL SameFileBytes(NSURL *url, NSData *before) {
    NSData *after = [NSData dataWithContentsOfURL:url];
    return after && before && [after isEqualToData:before];
}

static NSURL *RunConversion(NSURL *source, NSError **error) {
    __block NSURL *result = nil;
    __block NSError *conversionError = nil;
    dispatch_sync(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        result = DYYYLikeConvertAnimatedImageToGIF(source, &conversionError);
    });
    if (error) *error = conversionError;
    return result;
}

static NSDictionary *PropertiesAt(CGImageSourceRef source, size_t index) {
    return source ? CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, index, NULL)) : nil;
}

static double NumberInDictionary(NSDictionary *dictionary, NSArray<NSString *> *keys, BOOL *found) {
    for (NSString *key in keys) {
        id value = dictionary[key];
        if ([value respondsToSelector:@selector(doubleValue)]) {
            if (found) *found = YES;
            return [value doubleValue];
        }
    }
    if (found) *found = NO;
    return 0;
}

static BOOL ValidateGIF(NSURL *url, size_t expectedFrames, size_t width, size_t height,
                       NSArray<NSNumber *> *expectedDelays, NSInteger expectedLoop, NSString *label) {
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    BOOL valid = source && CGImageSourceGetStatus(source) == kCGImageStatusComplete;
    Check(valid, @"%@ is a complete ImageIO source", label);
    if (!valid) {
        if (source) CFRelease(source);
        return NO;
    }
    NSString *type = (__bridge NSString *)CGImageSourceGetType(source);
    Check([type isEqualToString:@"com.compuserve.gif"], @"%@ output type is GIF", label);
    size_t count = CGImageSourceGetCount(source);
    Check(count == expectedFrames, @"%@ frame count %zu == %zu", label, count, expectedFrames);
    NSDictionary *root = CFBridgingRelease(CGImageSourceCopyProperties(source, NULL));
    NSDictionary *first = PropertiesAt(source, 0);
    NSDictionary *gif = root[(NSString *)kCGImagePropertyGIFDictionary];
    if (!gif) gif = first[(NSString *)kCGImagePropertyGIFDictionary];
    NSNumber *loop = gif[(NSString *)kCGImagePropertyGIFLoopCount];
    if (expectedLoop >= 0) {
        Check(loop && loop.integerValue == expectedLoop, @"%@ loop count %@ == %ld", label,
              loop ?: @"missing", (long)expectedLoop);
    }
    for (size_t i = 0; i < expectedFrames && i < count; i++) {
        NSDictionary *properties = PropertiesAt(source, i);
        NSNumber *w = properties[(NSString *)kCGImagePropertyPixelWidth];
        NSNumber *h = properties[(NSString *)kCGImagePropertyPixelHeight];
        Check(w.unsignedIntegerValue == width && h.unsignedIntegerValue == height,
              @"%@ frame %zu dimensions %@x%@ == %zux%zu", label, i,
              w ?: @0, h ?: @0, width, height);
        NSDictionary *frameGIF = properties[(NSString *)kCGImagePropertyGIFDictionary];
        BOOL found = NO;
        double delay = NumberInDictionary(frameGIF,
            @[(NSString *)kCGImagePropertyGIFUnclampedDelayTime,
              (NSString *)kCGImagePropertyGIFDelayTime], &found);
        if (i < expectedDelays.count) {
            double expected = expectedDelays[i].doubleValue;
            Check(found && fabs(delay - expected) < 0.025,
                  @"%@ frame %zu delay %.3f == %.3f", label, i, delay, expected);
        }
    }
    CFRelease(source);
    return YES;
}

static NSInteger NativeLoopCount(NSURL *url) {
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!source) return -1;
    NSDictionary *root = CFBridgingRelease(CGImageSourceCopyProperties(source, NULL));
    NSDictionary *frame = PropertiesAt(source, 0); CFRelease(source);
    for (NSDictionary *properties in @[root ?: @{}, frame ?: @{}]) {
        for (id value in properties.allValues) {
            if ([value isKindOfClass:NSDictionary.class]) {
                NSNumber *loop = value[@"LoopCount"];
                if ([loop isKindOfClass:NSNumber.class]) return loop.integerValue;
            }
        }
    }
    return -1;
}

static void TestAnimatedFixture(NSURL *directory, NSString *name, NSString *base64,
                                NSString *extension) {
    NSData *bytes = Base64(base64);
    NSURL *source = WriteData(bytes, directory, [name stringByAppendingPathExtension:extension]);
    if (!source) return;
    NSError *error = nil;
    NSURL *output = RunConversion(source, &error);
    Check(output != nil && error == nil, @"%@ converts without error%@", name,
          error ? [NSString stringWithFormat:@" (%@)", error] : @"");
    Check(SameFileBytes(source, bytes), @"%@ source bytes remain unchanged", name);
    if (output) {
        NSInteger expectedLoop = NativeLoopCount(source);
        Check(expectedLoop >= 0, @"%@ exposes native loop metadata", name);
        ValidateGIF(output, 2, 2, 2, @[@0.12, @0.28], expectedLoop, name);
        [[NSFileManager defaultManager] removeItemAtURL:output error:NULL];
    }
}

static NSData *MakeJPEG(void) {
    const size_t w = 32, h = 24;
    uint8_t pixels[w * h * 4];
    for (size_t y = 0; y < h; y++) for (size_t x = 0; x < w; x++) {
        size_t p = (y * w + x) * 4;
        pixels[p] = (uint8_t)(x * 7); pixels[p + 1] = (uint8_t)(y * 9);
        pixels[p + 2] = (uint8_t)((x + y) * 3); pixels[p + 3] = 255;
    }
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(pixels, w, h, 8, w * 4, cs,
        kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast);
    CGImageRef image = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data,
        CFSTR("public.jpeg"), 1, NULL);
    if (dest && image) {
        CGImageDestinationAddImage(dest, image, (__bridge CFDictionaryRef)@{
            (NSString *)kCGImageDestinationLossyCompressionQuality: @0.83,
            (NSString *)kCGImagePropertyOrientation: @6});
        CGImageDestinationFinalize(dest);
    }
    if (dest) CFRelease(dest); if (image) CGImageRelease(image);
    if (ctx) CGContextRelease(ctx); CGColorSpaceRelease(cs);
    return data;
}

static NSURL *MakeMovie(NSURL *directory) {
    NSURL *url = [directory URLByAppendingPathComponent:@"synthetic-source.mov"];
    NSError *error = nil;
    AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:url
        fileType:AVFileTypeQuickTimeMovie error:&error];
    Check(writer != nil, @"create H.264 writer%@", error ? [NSString stringWithFormat:@" (%@)", error] : @"");
    if (!writer) return nil;
    NSDictionary *settings = @{AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @32, AVVideoHeightKey: @32,
        AVVideoCompressionPropertiesKey: @{AVVideoAverageBitRateKey: @90000,
            AVVideoExpectedSourceFrameRateKey: @2, AVVideoMaxKeyFrameIntervalKey: @2}};
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
        outputSettings:settings];
    input.expectsMediaDataInRealTime = NO;
    NSDictionary *attrs = @{(NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (NSString *)kCVPixelBufferWidthKey: @32, (NSString *)kCVPixelBufferHeightKey: @32,
        (NSString *)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES};
    AVAssetWriterInputPixelBufferAdaptor *adaptor =
        [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
                                                                     sourcePixelBufferAttributes:attrs];
    if (![writer canAddInput:input]) { Check(NO, @"writer accepts video input"); return nil; }
    [writer addInput:input];
    Check([writer startWriting], @"start synthetic H.264 writer%@",
          writer.error ? [NSString stringWithFormat:@" (%@)", writer.error] : @"");
    if (writer.status != AVAssetWriterStatusWriting) return nil;
    [writer startSessionAtSourceTime:kCMTimeZero];
    BOOL appended = YES;
    for (int frame = 0; frame < 4; frame++) {
        if (!input.readyForMoreMediaData) {
            appended = PumpUntil(^BOOL{ return input.readyForMoreMediaData || writer.status != AVAssetWriterStatusWriting; }, 5);
        }
        CVPixelBufferRef pixel = NULL;
        CVReturn rc = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, adaptor.pixelBufferPool, &pixel);
        if (rc != kCVReturnSuccess || !pixel) { appended = NO; break; }
        CVPixelBufferLockBaseAddress(pixel, 0);
        uint8_t *base = CVPixelBufferGetBaseAddress(pixel);
        size_t stride = CVPixelBufferGetBytesPerRow(pixel);
        for (int y = 0; y < 32; y++) for (int x = 0; x < 32; x++) {
            uint8_t *p = base + y * stride + x * 4;
            p[0] = frame & 1 ? 220 : 20; p[1] = (uint8_t)(x * 6);
            p[2] = frame & 1 ? 25 : 210; p[3] = 255;
        }
        CVPixelBufferUnlockBaseAddress(pixel, 0);
        BOOL ok = [adaptor appendPixelBuffer:pixel withPresentationTime:CMTimeMake(frame, 2)];
        CVPixelBufferRelease(pixel);
        if (!ok) { appended = NO; break; }
    }
    [input markAsFinished];
    [writer endSessionAtSourceTime:CMTimeMake(2, 1)];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(sem); }];
    long wait = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC));
    BOOL complete = appended && wait == 0 && writer.status == AVAssetWriterStatusCompleted;
    Check(complete, @"generate two-second 32x32 H.264 movie%@",
          writer.error ? [NSString stringWithFormat:@" (%@)", writer.error] : @"");
    return complete ? url : nil;
}

static NSArray<NSString *> *SampleHashes(AVURLAsset *asset, AVAssetTrack *track, NSError **error) {
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:error];
    AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:nil];
    output.alwaysCopiesSampleData = NO;
    if (!reader || ![reader canAddOutput:output]) {
        if (error && !*error) *error = [NSError errorWithDomain:@"MediaTest" code:10 userInfo:@{NSLocalizedDescriptionKey:@"reader rejected the supplied asset/track"}];
        return nil;
    }
    [reader addOutput:output];
    if (![reader startReading]) { if (error) *error = reader.error; return nil; }
    NSMutableArray *hashes = [NSMutableArray array];
    CMSampleBufferRef sample = NULL;
    while ((sample = [output copyNextSampleBuffer])) {
        CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
        size_t length = block ? CMBlockBufferGetDataLength(block) : 0;
        NSMutableData *bytes = [NSMutableData dataWithLength:length];
        OSStatus copied = length ? CMBlockBufferCopyDataBytes(block, 0, length, bytes.mutableBytes) : -1;
        if (!length || copied != kCMBlockBufferNoErr) {
            if (error) *error = [NSError errorWithDomain:@"MediaTest" code:11 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"compressed sample block length %zu, copy status %d", length, (int)copied]}];
            CFRelease(sample); [reader cancelReading]; return nil;
        }
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, digest);
        NSMutableString *hex = [NSMutableString stringWithCapacity:64];
        for (NSUInteger i = 0; i < sizeof(digest); i++) [hex appendFormat:@"%02x", digest[i]];
        [hashes addObject:hex]; CFRelease(sample);
    }
    if (reader.status != AVAssetReaderStatusCompleted && error) *error = reader.error ?: [NSError errorWithDomain:@"MediaTest" code:12 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"reader ended with status %ld",(long)reader.status]}];
    return reader.status == AVAssetReaderStatusCompleted ? hashes : nil;
}

static NSData *JPEGScan(NSURL *url) {
    NSData *data = [NSData dataWithContentsOfURL:url];
    const uint8_t *p = data.bytes;
    if (data.length < 4 || p[0] != 0xff || p[1] != 0xd8) return nil;
    for (NSUInteger i = 2; i + 1 < data.length; i++) {
        if (p[i] == 0xff && p[i + 1] == 0xda) return [data subdataWithRange:NSMakeRange(i, data.length - i)];
    }
    return nil;
}

static AVURLAsset *LoadedAsset(NSURL *url, NSArray<NSString *> *keys, NSString *label) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetPreferPreciseDurationAndTimingKey:@YES}];
    __block BOOL done = NO;
    [asset loadValuesAsynchronouslyForKeys:keys completionHandler:^{ done = YES; }];
    BOOL completed = PumpUntil(^BOOL{ return done; }, 30);
    Check(completed, @"%@ asset key loading completes", label);
    if (!completed) return nil;
    for (NSString *key in keys) {
        NSError *error = nil;
        AVKeyValueStatus status = [asset statusOfValueForKey:key error:&error];
        Check(status == AVKeyValueStatusLoaded, @"%@ asset key %@ loaded%@", label, key,
              error ? [NSString stringWithFormat:@" (%@)", error] : @"");
        if (status != AVKeyValueStatusLoaded) return nil;
    }
    return asset;
}

static NSString *ContentIdentifier(AVAsset *asset) {
    for (AVMetadataItem *item in asset.metadata) {
        if ([item.identifier isEqualToString:AVMetadataIdentifierQuickTimeMetadataContentIdentifier])
            return [item.value isKindOfClass:NSString.class] ? item.value : [item.value description];
    }
    return nil;
}

static void TestTimedStillTrack(AVURLAsset *asset) {
    AVAssetTrack *track = nil;
    for (AVAssetTrack *candidate in [asset tracksWithMediaType:AVMediaTypeMetadata]) {
        for (id object in candidate.formatDescriptions) {
            CMFormatDescriptionRef desc = (__bridge CMFormatDescriptionRef)object;
            // GetIdentifiers returns a borrowed array. Releasing it corrupts AVFoundation state.
            NSArray *ids = (__bridge NSArray *)CMMetadataFormatDescriptionGetIdentifiers(desc);
            for (NSString *identifier in ids) {
                if ([identifier hasSuffix:@"com.apple.quicktime.still-image-time"]) track = candidate;
            }
        }
    }
    Check(track != nil, @"paired MOV has still-image-time metadata track");
    if (!track) return;
    NSError *error = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
    AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:nil];
    if (!reader || ![reader canAddOutput:output]) { Check(NO, @"metadata reader accepts track"); return; }
    [reader addOutput:output];
    AVAssetReaderOutputMetadataAdaptor *adaptor = [[AVAssetReaderOutputMetadataAdaptor alloc] initWithAssetReaderTrackOutput:output];
    BOOL started = [reader startReading];
    Check(started, @"read still-image-time samples%@", reader.error ?: @"");
    if (!started) return;
    AVTimedMetadataGroup *group = [adaptor nextTimedMetadataGroup];
    Check(group != nil, @"still-image-time track has a timed metadata group");
    if (group) {
        CMTime pts = group.timeRange.start;
        Check(CMTIME_IS_NUMERIC(pts) && CMTimeCompare(pts, kCMTimeZero) == 0, @"still-image-time sample is at time zero");
        BOOL valueMatches = NO;
        for (AVMetadataItem *item in group.items) {
            NSString *key = item.identifier ?: [item.key description];
            id value = item.value;
            if ([key hasSuffix:@"com.apple.quicktime.still-image-time"] && [value respondsToSelector:@selector(integerValue)] && [value integerValue] == -1) valueMatches = YES;
        }
        Check(valueMatches, @"still-image-time metadata value is -1");
    }
    [reader cancelReading];
}

static void TestLivePhoto(NSURL *directory) {
    NSData *jpeg = MakeJPEG();
    NSURL *photo = WriteData(jpeg, directory, @"synthetic-source.jpg");
    NSURL *movie = MakeMovie(directory);
    if (!photo || !movie) return;
    NSData *photoBefore = [NSData dataWithContentsOfURL:photo];
    NSError *assetError = nil;
    AVURLAsset *sourceAsset = LoadedAsset(movie, @[@"tracks", @"metadata"], @"source movie");
    if (!sourceAsset) return;
    AVAssetTrack *sourceVideo = [sourceAsset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    Check(sourceVideo != nil, @"source movie has H.264 video track");
    if (!sourceVideo) return;
    NSError *hashError = nil;
    NSArray *sourceHashes = SampleHashes(sourceAsset, sourceVideo, &hashError);
    Check(sourceHashes.count > 0, @"read source compressed video samples%@",
          hashError ? [NSString stringWithFormat:@" (%@)", hashError] : @"");

    __block BOOL completed = NO;
    __block BOOL onMain = NO;
    __block NSURL *pairedPhoto = nil, *pairedMovie = nil;
    __block NSError *buildError = nil;
    DYYYLikeBuildLivePhoto(photo, movie, ^(NSURL *p, NSURL *v, NSError *e) {
        onMain = NSThread.isMainThread; pairedPhoto = p; pairedMovie = v; buildError = e; completed = YES;
    });
    BOOL timely = PumpUntil(^BOOL{ return completed; }, 90);
    Check(timely, @"Live Photo builder completes within 90 seconds");
    if (!timely) return;
    Check(onMain, @"Live Photo completion runs on main thread");
    Check(pairedPhoto != nil && pairedMovie != nil && buildError == nil,
          @"Live Photo builder returns both outputs%@",
          buildError ? [NSString stringWithFormat:@" (%@)", buildError] : @"");
    Check(SameFileBytes(photo, photoBefore), @"builder leaves source JPEG unchanged");
    if (!pairedPhoto || !pairedMovie) return;

    CGImageSourceRef originalSource = CGImageSourceCreateWithURL((__bridge CFURLRef)photo, NULL);
    CGImageSourceRef pairedSource = CGImageSourceCreateWithURL((__bridge CFURLRef)pairedPhoto, NULL);
    NSDictionary *originalProps = PropertiesAt(originalSource, 0);
    NSDictionary *pairedProps = PropertiesAt(pairedSource, 0);
    NSString *makerKey = (__bridge NSString *)kCGImagePropertyMakerAppleDictionary;
    NSString *makerID = pairedProps[makerKey][@"17"];
    Check(makerID.length > 0, @"paired JPEG has MakerApple 17 identifier");
    Check([originalProps[(NSString *)kCGImagePropertyOrientation]
           isEqual:pairedProps[(NSString *)kCGImagePropertyOrientation]], @"JPEG orientation is preserved");
    Check([originalProps[(NSString *)kCGImagePropertyPixelWidth]
           isEqual:pairedProps[(NSString *)kCGImagePropertyPixelWidth]] &&
          [originalProps[(NSString *)kCGImagePropertyPixelHeight]
           isEqual:pairedProps[(NSString *)kCGImagePropertyPixelHeight]], @"JPEG pixel dimensions are preserved");
    NSData *beforeScan = JPEGScan(photo), *afterScan = JPEGScan(pairedPhoto);
    Check(beforeScan && [beforeScan isEqualToData:afterScan], @"JPEG compressed scan bytes are unchanged (metadata-only edit)");
    if (originalSource) CFRelease(originalSource); if (pairedSource) CFRelease(pairedSource);

    AVURLAsset *pairedAsset = LoadedAsset(pairedMovie, @[@"tracks", @"metadata"], @"paired movie");
    if (pairedAsset) {
        NSString *movID = ContentIdentifier(pairedAsset);
        Check(movID.length > 0, @"paired MOV has QuickTime content.identifier");
        Check(makerID.length > 0 && [makerID isEqualToString:movID], @"MakerApple 17 equals MOV content.identifier");
        TestTimedStillTrack(pairedAsset);
        AVAssetTrack *pairedVideo = [pairedAsset tracksWithMediaType:AVMediaTypeVideo].firstObject;
        Check(pairedVideo != nil, @"paired MOV retains video track");
        if (pairedVideo) {
            CMFormatDescriptionRef a = (__bridge CMFormatDescriptionRef)sourceVideo.formatDescriptions.firstObject;
            CMFormatDescriptionRef b = (__bridge CMFormatDescriptionRef)pairedVideo.formatDescriptions.firstObject;
            CMVideoDimensions da = a ? CMVideoFormatDescriptionGetDimensions(a) : (CMVideoDimensions){0, 0};
            CMVideoDimensions db = b ? CMVideoFormatDescriptionGetDimensions(b) : (CMVideoDimensions){0, 0};
            Check(a && b && da.width == db.width && da.height == db.height, @"video coded dimensions unchanged");
            Check(CGAffineTransformEqualToTransform(sourceVideo.preferredTransform, pairedVideo.preferredTransform),
                  @"video orientation transform unchanged");
            NSError *pairedHashError = nil;
            NSArray *pairedHashes = SampleHashes(pairedAsset, pairedVideo, &pairedHashError);
            Check(sourceHashes && [sourceHashes isEqualToArray:pairedHashes],
                  @"compressed video sample SHA-256 sequence unchanged%@",
                  pairedHashError ? [NSString stringWithFormat:@" (%@)", pairedHashError] : @"");
        }
        NSArray *audio = [pairedAsset tracksWithMediaType:AVMediaTypeAudio];
        Check(audio.count == 0, @"AAC audio comparison not covered (fixture intentionally silent)");
    }
    [[NSFileManager defaultManager] removeItemAtURL:pairedPhoto error:NULL];
    [[NSFileManager defaultManager] removeItemAtURL:pairedMovie error:NULL];
}

int main(void) {
    @autoreleasepool {
        NSURL *directory = MakeTempDirectory();
        if (!directory) return 2;
        TestAnimatedFixture(directory, @"GIF", @"R0lGODlhAgACAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEDAAAh+QQADAAAACwAAAAAAgACAAAIBgABCAQQEAAh+QQAHAAAACwAAAAAAgACAIEAAP8AAAAAAAAAAAAIBgABCAQQEAA7", @"gif");
        TestAnimatedFixture(directory, @"WebP", @"UklGRoQAAABXRUJQVlA4WAoAAAACAAAAAQAAAQAAQU5JTQYAAAAAAAAAAwBBTk1GKAAAAAAAAAAAAAEAAAEAAHgAAAJWUDhMDwAAAC8BQAAABxD9j/4HIqL/AQBBTk1GKAAAAAAAAAAAAAEAAAEAABgBAABWUDhMDwAAAC8BQAAABxDR//4HIqL/AQA=", @"webp");
        TestAnimatedFixture(directory, @"APNG", @"iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAACGFjVEwAAAACAAAAA2qEwsoAAAAaZmNUTAAAAAAAAAACAAAAAgAAAAAAAAAAAHgD6AAApEX1ngAAABZJREFUeJxj/M/AwMDAwMTAwMDAwAAADR0BA2rCm+kAAAAaZmNUTAAAAAEAAAACAAAAAgAAAAAAAAAAARgD6AAAbVi7ogAAABpmZEFUAAAAAnicY2Rg+M/AwMDEwMDAwMAAAAsfAQM5oA0PAAAAAElFTkSuQmCC", @"png");
        NSData *bad = [@"not an image" dataUsingEncoding:NSUTF8StringEncoding];
        NSURL *badURL = WriteData(bad, directory, @"invalid.bin"); NSError *badError = nil;
        NSURL *badOutput = RunConversion(badURL, &badError);
        Check(!badOutput && badError != nil && SameFileBytes(badURL, bad), @"invalid media fails without changing source bytes");
        NSURL *staticURL = WriteData(MakeJPEG(), directory, @"still.jpg"); NSError *staticError = nil;
        NSURL *staticGIF = RunConversion(staticURL, &staticError);
        Check(staticGIF == nil && staticError != nil, @"static JPEG is rejected instead of masquerading as an animation");
        if (staticGIF) [[NSFileManager defaultManager] removeItemAtURL:staticGIF error:NULL];
        TestLivePhoto(directory);
        fprintf(stdout, "\nMedia tests: %d PASS, %d FAIL\n", gPasses, gFailures);
        [[NSFileManager defaultManager] removeItemAtURL:directory error:NULL];
        return gFailures ? 1 : 0;
    }
}
