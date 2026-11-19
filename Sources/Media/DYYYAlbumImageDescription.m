#import "DYYYAlbumImageDescription.h"
#import <ImageIO/ImageIO.h>

NSURL *DYYYCopyImageWithAlbumDescription(NSURL *sourceURL, NSString *description) {
    if (!description.length || !sourceURL.isFileURL) return nil;
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)sourceURL, NULL);
    if (!source) return nil;
    CGImageDestinationRef destination = NULL;
    CGMutableImageMetadataRef metadata = NULL;
    NSURL *output = nil;
    BOOL copied = NO;
    do {
        CFStringRef type = CGImageSourceGetType(source);
        size_t count = CGImageSourceGetCount(source);
        if (!type || !count || CGImageSourceGetStatus(source) != kCGImageStatusComplete) break;
        metadata = CGImageMetadataCreateMutable();
        if (!metadata || !CGImageMetadataSetValueMatchingImageProperty(metadata,
                kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCCaptionAbstract,
                (__bridge CFStringRef)description)) break;
        CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary,
            kCGImagePropertyTIFFImageDescription, (__bridge CFStringRef)description);
        CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyExifDictionary,
            kCGImagePropertyExifUserComment, (__bridge CFStringRef)description);
        NSString *name = [NSString stringWithFormat:@"DYYYAlbumCaption-%@.%@",
            NSUUID.UUID.UUIDString, sourceURL.pathExtension];
        output = [sourceURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:name];
        destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)output, type, count, NULL);
        if (!destination) break;
        NSDictionary *options = @{
            (__bridge NSString *)kCGImageDestinationMetadata: (__bridge id)metadata,
            (__bridge NSString *)kCGImageDestinationMergeMetadata: @YES
        };
        CFErrorRef error = NULL;
        // CopyImageSource completes the file without recompressing the image.
        copied = CGImageDestinationCopyImageSource(destination, source, (__bridge CFDictionaryRef)options, &error) && !error;
        if (error) CFRelease(error);
        if (!copied) break;
        CGImageSourceRef result = CGImageSourceCreateWithURL((__bridge CFURLRef)output, NULL);
        CFStringRef resultType = result ? CGImageSourceGetType(result) : NULL;
        copied = resultType && CFEqual(type, resultType) && CGImageSourceGetCount(result) == count &&
            CGImageSourceGetStatus(result) == kCGImageStatusComplete;
        if (result) CFRelease(result);
    } while (NO);
    if (destination) CFRelease(destination);
    if (metadata) CFRelease(metadata);
    CFRelease(source);
    if (!copied && output) [NSFileManager.defaultManager removeItemAtURL:output error:nil];
    return copied ? output : nil;
}
