#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <AudioToolbox/AudioToolbox.h>
#import "../../Sources/Features/DYYYLikeLivePhotoBuilder.h"
#import "../../Sources/Media/DYYYAlbumImageDescription.h"
#import "../../Sources/Features/DYYYLikeAnimatedImage.h"
#include <stdarg.h>
#include <stdint.h>
#include <string.h>
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

static NSString *IPTCCaptionAtURL(NSURL *url) {
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    CGImageMetadataRef metadata = source ? CGImageSourceCopyMetadataAtIndex(source, 0, NULL) : NULL;
    // IPTC CaptionAbstract maps to dc:description, an alternate-text XMP tag.
    // The raw tag value can be an array rather than an NSString.
    NSString *caption = metadata ? CFBridgingRelease(CGImageMetadataCopyStringValueWithPath(
        metadata, NULL, CFSTR("dc:description"))) : nil;
    if (!caption && source) {
        NSDictionary *fields = PropertiesAt(source, 0)[(__bridge NSString *)kCGImagePropertyIPTCDictionary];
        id legacy = fields[(__bridge NSString *)kCGImagePropertyIPTCCaptionAbstract];
        if ([legacy isKindOfClass:NSString.class]) caption = legacy;
    }
    if (metadata) CFRelease(metadata);
    if (source) CFRelease(source);
    return caption;
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

static NSString *const kTestLivePhotoDescription = @"旧菜单实况说明：春の花火 🎆";

static NSData *MakeStillVariant(uint8_t variant, CFStringRef type) {
    const size_t w = 32, h = 24;
    uint8_t pixels[w * h * 4];
    for (size_t y = 0; y < h; y++) for (size_t x = 0; x < w; x++) {
        size_t p = (y * w + x) * 4;
        pixels[p] = (uint8_t)(x * 7 + variant * 71); pixels[p + 1] = (uint8_t)(y * 9);
        pixels[p + 2] = (uint8_t)((x + y) * 3 + variant * 43); pixels[p + 3] = 255;
    }
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(pixels, w, h, 8, w * 4, cs,
        kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast);
    CGImageRef image = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data,
        type, 1, NULL);
    if (dest && image) {
        NSDictionary *properties = CFEqual(type, CFSTR("public.jpeg")) ? @{
            (NSString *)kCGImageDestinationLossyCompressionQuality: @0.83,
            (NSString *)kCGImagePropertyOrientation: @6} : nil;
        CGImageDestinationAddImage(dest, image, (__bridge CFDictionaryRef)properties);
        CGImageDestinationFinalize(dest);
    }
    if (dest) CFRelease(dest); if (image) CGImageRelease(image);
    if (ctx) CGContextRelease(ctx); CGColorSpaceRelease(cs);
    return data;
}

static NSData *MakeJPEGVariant(uint8_t variant) { return MakeStillVariant(variant, CFSTR("public.jpeg")); }
static NSData *MakeJPEG(void) { return MakeJPEGVariant(0); }

static NSURL *MakeMovieVariant(NSURL *directory, NSString *name, uint8_t variant) {
    NSURL *url = [directory URLByAppendingPathComponent:name];
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
    AVMutableMetadataItem *oldQuickTimeDescription = [AVMutableMetadataItem metadataItem];
    oldQuickTimeDescription.keySpace = AVMetadataKeySpaceQuickTimeMetadata;
    oldQuickTimeDescription.key = AVMetadataQuickTimeMetadataKeyDescription;
    oldQuickTimeDescription.dataType = (__bridge NSString *)kCMMetadataBaseDataType_UTF8;
    oldQuickTimeDescription.value = @"source QuickTime description";
    writer.metadata = @[oldQuickTimeDescription];
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
            p[0] = (uint8_t)((frame & 1 ? 220 : 20) + variant * 67);
            p[1] = (uint8_t)(x * 6 + variant * 53);
            p[2] = (uint8_t)((frame & 1 ? 25 : 210) + variant * 29); p[3] = 255;
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

static NSURL *MakeMovie(NSURL *directory) {
    return MakeMovieVariant(directory, @"synthetic-source.mov", 0);
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
        if (!length) {
            CFTypeRef empty = CMGetAttachment(sample, kCMSampleBufferAttachmentKey_EmptyMedia, NULL);
            BOOL intentional = empty && CFGetTypeID(empty) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)empty);
            if (intentional || CMSampleBufferGetNumSamples(sample) == 0) {
                fprintf(stdout, "INFO legal empty-media event, not an encoded picture packet\n");
                fflush(stdout);
                CFRelease(sample);
                continue;
            }
        }
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

static NSArray<AVMetadataItem *> *QuickTimeDescriptionItems(AVAsset *asset) {
    NSMutableArray<AVMetadataItem *> *matches = [NSMutableArray array];
    for (AVMetadataItem *item in asset.metadata) {
        if ([item.keySpace isEqualToString:AVMetadataKeySpaceQuickTimeMetadata] &&
            [item.key isEqual:AVMetadataQuickTimeMetadataKeyDescription]) [matches addObject:item];
    }
    return matches;
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
    NSURL *describedPhoto = photo ? DYYYCopyImageWithAlbumDescription(photo, kTestLivePhotoDescription) : nil;
    Check(describedPhoto != nil, @"ImageIO writes test IPTC description without recompression");
    NSURL *movie = MakeMovie(directory);
    if (!photo || !describedPhoto || !movie) return;
    NSData *photoBefore = [NSData dataWithContentsOfURL:photo];
    NSData *sourceScan = JPEGScan(photo), *injectedScan = JPEGScan(describedPhoto);
    Check(sourceScan && [sourceScan isEqualToData:injectedScan],
          @"ImageIO description copy preserves original JPEG compressed scan");
    Check([IPTCCaptionAtURL(describedPhoto) isEqualToString:kTestLivePhotoDescription],
          @"ImageIO-described builder input reads back non-ASCII IPTC caption");
    NSError *assetError = nil;
    AVURLAsset *sourceAsset = LoadedAsset(movie, @[@"tracks", @"metadata"], @"source movie");
    if (!sourceAsset) return;
    NSArray<AVMetadataItem *> *sourceDescriptions = QuickTimeDescriptionItems(sourceAsset);
    Check(sourceDescriptions.count == 1 &&
          [@"source QuickTime description" isEqual:sourceDescriptions.firstObject.value],
          @"source fixture has one pre-existing QuickTime Description");
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
    DYYYLikeBuildLivePhoto(describedPhoto, movie, kTestLivePhotoDescription, ^(NSURL *p, NSURL *v, NSError *e) {
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
    Check([IPTCCaptionAtURL(pairedPhoto) isEqualToString:kTestLivePhotoDescription],
          @"paired JPEG preserves non-ASCII IPTC description");
    if (originalSource) CFRelease(originalSource); if (pairedSource) CFRelease(pairedSource);

    AVURLAsset *pairedAsset = LoadedAsset(pairedMovie, @[@"tracks", @"metadata"], @"paired movie");
    if (pairedAsset) {
        NSString *movID = ContentIdentifier(pairedAsset);
        Check(movID.length > 0, @"paired MOV has QuickTime content.identifier");
        NSArray<AVMetadataItem *> *descriptions = QuickTimeDescriptionItems(pairedAsset);
        Check(descriptions.count == 1 && [kTestLivePhotoDescription isEqual:descriptions.firstObject.value],
              @"paired MOV replaces old tag with one UTF-8 QuickTime Description");
        NSUInteger commonDescriptions = 0;
        for (AVMetadataItem *item in pairedAsset.metadata) {
            if ([item.keySpace isEqualToString:AVMetadataKeySpaceCommon] &&
                [item.key isEqual:AVMetadataCommonKeyDescription]) commonDescriptions++;
        }
        Check(commonDescriptions == 0, @"paired MOV does not retain a duplicate common Description");
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

// Submit all pages before pumping; the middle failure must not poison either pair.
static void TestIndependentLivePhotos(NSURL *directory) {
    NSData *jpegA = MakeJPEGVariant(1), *jpegB = MakeJPEGVariant(2);
    Check(jpegA.length > 0 && jpegB.length > 0 && ![jpegA isEqualToData:jpegB],
          @"album fixtures have distinct nonempty JPEG covers");
    NSURL *photoA = WriteData(jpegA, directory, @"album-page-0.jpg");
    NSURL *photoB = WriteData(jpegB, directory, @"album-page-2.jpg");
    NSURL *movieA = MakeMovieVariant(directory, @"album-page-0.mov", 1);
    NSURL *movieB = MakeMovieVariant(directory, @"album-page-2.mov", 2);
    if (!photoA || !photoB || !movieA || !movieB) return;
    NSArray *photos = @[photoA, [directory URLByAppendingPathComponent:@"album-missing-1.jpg"], photoB];
    NSArray *movies = @[movieA, [directory URLByAppendingPathComponent:@"album-missing-1.mov"], movieB];
    NSMutableArray *sourceHashes = [NSMutableArray array];
    for (NSNumber *index in @[@0, @2]) {
        NSUInteger page = index.unsignedIntegerValue;
        AVURLAsset *asset = LoadedAsset(movies[page], @[@"tracks"], @"album source");
        AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
        NSError *error = nil;
        NSArray *hashes = track ? SampleHashes(asset, track, &error) : nil;
        Check(hashes.count > 0 && !error, @"album page %lu source packets are nonempty", (unsigned long)page);
        [sourceHashes addObject:hashes ?: @[]];
    }
    Check([sourceHashes[0] count] > 0 && [sourceHashes[1] count] > 0 &&
          ![sourceHashes[0] isEqualToArray:sourceHashes[1]], @"album source H.264 packet hashes really differ");
    NSMutableArray<NSDictionary *> *results = [NSMutableArray arrayWithArray:@[@{}, @{}, @{}]];
    __block NSUInteger completed = 0;
    __block BOOL accepting = YES;
    for (NSUInteger page = 0; page < 3; page++) {
        DYYYLikeBuildLivePhoto(photos[page], movies[page], nil, ^(NSURL *p, NSURL *v, NSError *e) {
            if (!accepting) {
                if (p) [[NSFileManager defaultManager] removeItemAtURL:p error:NULL];
                if (v) [[NSFileManager defaultManager] removeItemAtURL:v error:NULL];
                return;
            }
            NSMutableDictionary *result = [@{@"calls": @([results[page][@"calls"] unsignedIntegerValue] + 1),
                @"main": @(NSThread.isMainThread)} mutableCopy];
            if (p) result[@"photo"] = p;
            if (v) result[@"movie"] = v;
            if (e) result[@"error"] = e;
            results[page] = result; completed++;
        });
    }
    BOOL timely = PumpUntil(^BOOL{ return completed >= 3; }, 90);
    accepting = NO;
    Check(timely, @"all three album page callbacks complete within 90 seconds");
    for (NSUInteger page = 0; page < 3; page++) {
        Check([results[page][@"calls"] unsignedIntegerValue] == 1 && [results[page][@"main"] boolValue],
              @"album page %lu completes once on main", (unsigned long)page);
    }
    Check(!results[1][@"photo"] && !results[1][@"movie"] &&
          [results[1][@"error"] isKindOfClass:NSError.class], @"missing album page returns nil outputs plus error");
    NSMutableArray *identifiers = [NSMutableArray array], *outputHashes = [NSMutableArray array];
    for (NSUInteger pair = 0; pair < 2; pair++) {
        NSUInteger page = pair * 2;
        NSURL *photo = results[page][@"photo"], *movie = results[page][@"movie"];
        Check(photo && movie && !results[page][@"error"], @"album page %lu still succeeds", (unsigned long)page);
        NSString *makerID = nil;
        NSArray *hashes = nil;
        if (photo && movie) {
            CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)photo, NULL);
            CGImageRef image = source ? CGImageSourceCreateImageAtIndex(source, 0, NULL) : NULL;
            Check(image != NULL, @"album page %lu JPEG remains decodable after all callbacks", (unsigned long)page);
            makerID = PropertiesAt(source, 0)[(NSString *)kCGImagePropertyMakerAppleDictionary][@"17"];
            NSData *scan = JPEGScan(photos[page]);
            Check(scan && [scan isEqualToData:JPEGScan(photo)], @"album page %lu retains its own JPEG scan", (unsigned long)page);
            if (image) CGImageRelease(image);
            if (source) CFRelease(source);
            AVURLAsset *asset = LoadedAsset(movie, @[@"tracks", @"metadata"], @"album paired movie");
            NSString *movID = ContentIdentifier(asset);
            Check(makerID.length > 0 && movID.length > 0 && [makerID isEqualToString:movID],
                  @"album page %lu MakerApple 17 matches its own MOV ID", (unsigned long)page);
            AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
            NSError *error = nil;
            hashes = track ? SampleHashes(asset, track, &error) : nil;
            Check(hashes.count > 0 && !error && [hashes isEqualToArray:sourceHashes[pair]],
                  @"album page %lu nonempty packet hashes match only its own source", (unsigned long)page);
            AVAssetImageGenerator *generator = asset ? [AVAssetImageGenerator assetImageGeneratorWithAsset:asset] : nil;
            CGImageRef frame = [generator copyCGImageAtTime:kCMTimeZero actualTime:NULL error:NULL];
            Check(frame != NULL, @"album page %lu MOV remains decodable after all callbacks", (unsigned long)page);
            if (frame) CGImageRelease(frame);
        }
        [identifiers addObject:makerID ?: @""]; [outputHashes addObject:hashes ?: @[]];
    }
    Check([identifiers[0] length] > 0 && [identifiers[1] length] > 0 &&
          ![identifiers[0] isEqualToString:identifiers[1]], @"successful album pages have independent pairing IDs");
    Check([outputHashes[0] count] > 0 && [outputHashes[1] count] > 0 &&
          ![outputHashes[0] isEqualToArray:outputHashes[1]], @"successful album outputs retain distinct H.264 packets");
    for (NSDictionary *result in results) for (NSString *key in @[@"photo", @"movie"]) {
        NSURL *url = result[key];
        if (url) [[NSFileManager defaultManager] removeItemAtURL:url error:NULL];
    }
}

// A PNG compatibility still must not be re-encoded merely to carry its pair ID.
static NSData *PNGWithoutExif(NSData *png, NSUInteger *exifCount) {
    static const uint8_t signature[] = {137, 'P', 'N', 'G', 13, 10, 26, 10};
    const uint8_t *bytes = png.bytes;
    if (png.length < sizeof(signature) || memcmp(bytes, signature, sizeof(signature))) return nil;
    NSMutableData *original = [NSMutableData dataWithBytes:signature length:sizeof(signature)];
    NSUInteger count = 0, offset = sizeof(signature);
    while (png.length - offset >= 12) {
        const uint8_t *p = bytes + offset;
        NSUInteger length = ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
        if (length > png.length - offset - 12) return nil;
        if (!memcmp(p + 4, "eXIf", 4)) count++;
        else [original appendBytes:p length:length + 12];
        offset += length + 12;
    }
    if (offset != png.length) return nil;
    *exifCount = count;
    return original;
}

static void TestFullResolutionLivePNG(NSURL *directory) {
    NSData *source = MakeStillVariant(3, CFSTR("public.png"));
    NSURL *photo = WriteData(source, directory, @"live-compatibility.png");
    // TestLivePhoto builds and verifies this movie first.
    NSURL *movie = [directory URLByAppendingPathComponent:@"synthetic-source.mov"];
    if (!photo) return;
    __block BOOL completed = NO;
    __block NSURL *pairedPhoto = nil, *pairedMovie = nil;
    __block NSError *failure = nil;
    DYYYLikeBuildLivePhoto(photo, movie, nil, ^(NSURL *p, NSURL *v, NSError *error) {
        pairedPhoto = p; pairedMovie = v; failure = error; completed = YES;
    });
    BOOL timely = PumpUntil(^BOOL{ return completed; }, 90);
    Check(timely && pairedPhoto && pairedMovie, @"full-resolution PNG creates an independent pair%@",
        failure ? [NSString stringWithFormat:@" (%@)", failure] : @"");
    if (!pairedPhoto || !pairedMovie) return;
    NSUInteger before = 0, after = 0;
    NSData *plain = PNGWithoutExif(source, &before);
    NSData *written = PNGWithoutExif([NSData dataWithContentsOfURL:pairedPhoto], &after);
    Check(plain && [plain isEqualToData:written] && after == 1,
        @"PNG IDAT, dimensions, color and all non-eXIf chunks are byte-identical");
    CGImageSourceRef image = CGImageSourceCreateWithURL((__bridge CFURLRef)pairedPhoto, NULL);
    NSDictionary *properties = image ? PropertiesAt(image, 0) : nil;
    if (image) CFRelease(image);
    NSString *identifier = properties[(__bridge NSString *)kCGImagePropertyMakerAppleDictionary][@"17"];
    AVURLAsset *asset = LoadedAsset(pairedMovie, @[@"metadata"], @"PNG paired clip");
    Check(identifier.length > 0 && [identifier isEqualToString:ContentIdentifier(asset)],
        @"PNG Apple Maker 17 and paired MOV ID match");
    Check(SameFileBytes(photo, source), @"PNG source is never modified");
    [NSFileManager.defaultManager removeItemAtURL:pairedPhoto error:NULL];
    [NSFileManager.defaultManager removeItemAtURL:pairedMovie error:NULL];
}

static void TestLivePhotoAlbumDates(void) {
    NSDate *now = [NSDate dateWithTimeIntervalSince1970:1795128000.0];
    Check(!DYYYLikeLivePhotoAlbumDates(@[], now), @"empty selection keeps normal PhotoKit date");
    Check(!DYYYLikeLivePhotoAlbumDates(@[@NO, @NO], now), @"ordinary image batch keeps normal PhotoKit dates");
    Check(!DYYYLikeLivePhotoAlbumDates(@[@YES], now), @"single Live Photo keeps its ordinary date");
    Check(!DYYYLikeLivePhotoAlbumDates(@[@NO, @YES, @NO], now), @"one Live Photo among stills needs no date change");

    NSArray<NSDate *> *dates = DYYYLikeLivePhotoAlbumDates(@[@YES, @YES, @YES], now);
    Check(dates.count == 3, @"all three live pages have an explicit PhotoKit date");
    Check(dates.count == 3 && [dates[1] timeIntervalSinceDate:dates[0]] == 4.0 &&
        [dates[2] timeIntervalSinceDate:dates[1]] == 4.0, @"rapid commits still receive four-second gaps");
    Check([dates.lastObject isEqualToDate:now] && [dates.firstObject timeIntervalSinceDate:now] == -8.0,
        @"insertion schedule preserves page order without future dates");

    NSArray<NSDate *> *mixed = DYYYLikeLivePhotoAlbumDates(@[@YES, @NO, @YES], now);
    Check(mixed.count == 3 && [mixed[1] timeIntervalSinceDate:mixed[0]] == 4.0 &&
        [mixed[2] timeIntervalSinceDate:mixed[1]] == 4.0, @"mixed batch keeps the still between both live pages");
    Check(mixed.count == 3 && [mixed[2] timeIntervalSinceDate:mixed[0]] == 8.0,
        @"skipping a failed middle page cannot close the eight-second gap");
}

extern int DYYYRunMediaSourceSelectionTests(void);
extern int DYYYRunVideoQualityPolicyTests(void);
extern int DYYYRunSettingsBackupValidationTests(void);
extern int DYYYRunSettingsBackupTransactionTests(void);
extern int DYYYRunABConfigValidationTests(void);
extern int DYYYRunDownloadLifecycleTests(void);
extern int DYYYRunHDRMetadataTests(void);

int main(void) {
    @autoreleasepool {
        int sourceSelectionFailures = DYYYRunMediaSourceSelectionTests();
        int qualityPolicyFailures = DYYYRunVideoQualityPolicyTests();
        int maintenanceFailures = DYYYRunSettingsBackupValidationTests() + DYYYRunSettingsBackupTransactionTests() +
            DYYYRunABConfigValidationTests() + DYYYRunDownloadLifecycleTests() + DYYYRunHDRMetadataTests();
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
        TestFullResolutionLivePNG(directory);
        TestIndependentLivePhotos(directory);
        TestLivePhotoAlbumDates();
        fprintf(stdout, "\nMedia tests: %d PASS, %d FAIL\n", gPasses, gFailures);
        [[NSFileManager defaultManager] removeItemAtURL:directory error:NULL];
        return (gFailures || sourceSelectionFailures || qualityPolicyFailures || maintenanceFailures) ? 1 : 0;
    }
}
