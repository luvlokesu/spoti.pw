// Builds the lock screen's fallback clip: the still cover panned sinusoidally with a translucent
// gradient painted from the cover's own palette rotating over it. The loop closes on its first
// frame (every sin/cos driven value is a function of a 0..1 progress that returns to the same
// phase), so the system plays it seamlessly. 6 s at 30 fps, H.264. The MP4 lands in the same cache
// directory as the fetched clips so SGArtworkFile's prune reaches it too.
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import "Core/SGCore.h"
#import "SGGeneratedArtwork.h"

static const CFTimeInterval kDuration = 6.0;
static const int32_t kFPS = 30;
static const int kLongSide = 720;

static dispatch_queue_t queue(void) {
    static dispatch_queue_t shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = dispatch_queue_create("com.spotifyglass.generatedartwork", DISPATCH_QUEUE_SERIAL); });
    return shared;
}

static NSURL *directory(void) {
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    NSURL *url = [NSURL fileURLWithPath:[caches stringByAppendingPathComponent:@"spoti.pw/LockArtwork"]];
    [NSFileManager.defaultManager createDirectoryAtURL:url withIntermediateDirectories:YES attributes:nil error:nil];
    return url;
}

static NSURL *fileFor(NSString *name) {
    return [directory() URLByAppendingPathComponent:name];
}

// H.264 wants even sides.
static CGSize sizeFor(CGFloat aspect) {
    int w, h;
    if (aspect >= 1.0) {
        w = kLongSide;
        h = (int)round(kLongSide / aspect);
    } else {
        h = kLongSide;
        w = (int)round(kLongSide * aspect);
    }
    return CGSizeMake(w & ~1, h & ~1);
}

// Scaled copy of the cover, kept small so the sampling is a bitmap read of a few bytes.
static UIImage *downsample(UIImage *image, int side) {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = YES;
    CGSize size = CGSizeMake(side, side);
    return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [image drawInRect:CGRectMake(0, 0, side, side)];
    }];
}

// Two colours from the cover: a point near the top left and one near the bottom right of a 16x16
// downsample, each saturation-boosted so the gradient reads over the still rather than vanishing
// into it. Grayscale covers answer with the same grey twice; the overlay then adds nothing, which
// is right for a cover with no colour of its own.
static void samplePalette(UIImage *cover, UIColor **outA, UIColor **outB) {
    const int side = 16;
    UIImage *small = downsample(cover, side);
    if (!small.CGImage) {
        *outA = UIColor.darkGrayColor;
        *outB = UIColor.lightGrayColor;
        return;
    }
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    unsigned char *rgba = calloc(side * side * 4, 1);
    CGContextRef ctx = CGBitmapContextCreate(rgba, side, side, 8, side * 4, cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGContextDrawImage(ctx, CGRectMake(0, 0, side, side), small.CGImage);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    int ax = side / 4, ay = side / 4;
    int bx = 3 * side / 4, by = 3 * side / 4;
    int ai = (ay * side + ax) * 4;
    int bi = (by * side + bx) * 4;
    UIColor *a = [UIColor colorWithRed:rgba[ai] / 255.0 green:rgba[ai + 1] / 255.0 blue:rgba[ai + 2] / 255.0 alpha:1.0];
    UIColor *b = [UIColor colorWithRed:rgba[bi] / 255.0 green:rgba[bi + 1] / 255.0 blue:rgba[bi + 2] / 255.0 alpha:1.0];
    free(rgba);
    CGFloat h, s, br, al;
    [a getHue:&h saturation:&s brightness:&br alpha:&al];
    *outA = [UIColor colorWithHue:h saturation:MIN(s * 1.4, 1.0) brightness:MIN(MAX(br, 0.25) * 1.1, 1.0) alpha:1.0];
    [b getHue:&h saturation:&s brightness:&br alpha:&al];
    *outB = [UIColor colorWithHue:h saturation:MIN(s * 1.4, 1.0) brightness:MIN(MAX(br, 0.25) * 1.1, 1.0) alpha:1.0];
}

// Progress is 0..1 across the loop; every value derived from it closes on its starting phase at 1
// so the clip has no seam when played back.
static void drawFrame(CGContextRef ctx, CGImageRef cover, CGFloat t, CGSize size, CGColorRef a, CGColorRef b) {
    CGFloat w = size.width, h = size.height;
    CGFloat angle = 2.0 * M_PI * t;

    // Cover scaled past the frame then panned sinusoidally so the edges never show.
    const CGFloat zoom = 1.1;
    CGFloat panX = 0.04 * w * sin(angle);
    CGFloat panY = 0.03 * h * cos(angle);
    CGFloat drawnW = w * zoom;
    CGFloat drawnH = h * zoom;
    CGFloat x = (w - drawnW) / 2 + panX;
    CGFloat y = (h - drawnH) / 2 + panY;
    CGContextSaveGState(ctx);
    CGContextDrawImage(ctx, CGRectMake(x, y, drawnW, drawnH), cover);
    CGContextRestoreGState(ctx);

    // The gradient's two ends orbit the frame's centre, so what the overlay paints shifts without a
    // cut: at every t the ends are a rotation of where they were.
    CGFloat r = fmax(w, h) * 0.7;
    CGPoint start = CGPointMake(w / 2 + r * cos(angle), h / 2 + r * sin(angle));
    CGPoint end = CGPointMake(w / 2 - r * cos(angle), h / 2 - r * sin(angle));

    const CGFloat alpha = 0.35;
    CGColorRef aLight = CGColorCreateCopyWithAlpha(a, alpha);
    CGColorRef bLight = CGColorCreateCopyWithAlpha(b, alpha);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CFArrayRef colors = CFArrayCreate(NULL, (const void *[]){aLight, bLight}, 2, &kCFTypeArrayCallBacks);
    CGFloat stops[] = {0.0, 1.0};
    CGGradientRef gradient = CGGradientCreateWithColors(cs, colors, stops);
    CGContextSaveGState(ctx);
    CGContextSetBlendMode(ctx, kCGBlendModeOverlay);
    CGContextDrawLinearGradient(ctx, gradient, start, end, 0);
    CGContextRestoreGState(ctx);
    CGGradientRelease(gradient);
    CFRelease(colors);
    CGColorSpaceRelease(cs);
    CGColorRelease(aLight);
    CGColorRelease(bLight);
}

// Serial-queue flag: a fresh build on the queue reads this to drop the one that was running.
static NSString *sg_wanted;

static BOOL isWanted(NSString *identifier) {
    __block BOOL wanted;
    @synchronized (queue()) { wanted = [sg_wanted isEqualToString:identifier]; }
    return wanted;
}

static BOOL writeMP4Sync(UIImage *cover, UIColor *colorA, UIColor *colorB, CGSize size, NSString *identifier, NSURL *into, NSString **note) {
    [NSFileManager.defaultManager removeItemAtURL:into error:nil];
    NSError *error = nil;
    AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:into fileType:AVFileTypeMPEG4 error:&error];
    if (!writer) {
        if (note) *note = [NSString stringWithFormat:@"writer failed: %@", error.localizedDescription];
        return NO;
    }
    NSDictionary *settings = @{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @((int)size.width),
        AVVideoHeightKey: @((int)size.height),
        AVVideoCompressionPropertiesKey: @{
            AVVideoAverageBitRateKey: @(2 * 1024 * 1024),
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        },
    };
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:settings];
    input.expectsMediaDataInRealTime = NO;
    NSDictionary *bufferAttributes = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (NSString *)kCVPixelBufferWidthKey: @((int)size.width),
        (NSString *)kCVPixelBufferHeightKey: @((int)size.height),
    };
    AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor
        assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input sourcePixelBufferAttributes:bufferAttributes];
    [writer addInput:input];
    [writer startWriting];
    [writer startSessionAtSourceTime:kCMTimeZero];
    int frames = (int)(kFPS * kDuration);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGImageRef coverCG = cover.CGImage;
    CGColorRef aCG = colorA.CGColor;
    CGColorRef bCG = colorB.CGColor;
    BOOL cancelled = NO;
    for (int i = 0; i < frames; i++) {
        if (!isWanted(identifier)) { cancelled = YES; break; }
        while (!input.readyForMoreMediaData && !cancelled) {
            [NSThread sleepForTimeInterval:0.005];
            if (!isWanted(identifier)) cancelled = YES;
        }
        if (cancelled) break;
        CVPixelBufferRef pixelBuffer = NULL;
        CVReturn status = kCVReturnError;
        CVPixelBufferPoolRef pool = adaptor.pixelBufferPool;
        if (pool) status = CVPixelBufferPoolCreatePixelBuffer(NULL, pool, &pixelBuffer);
        if (status != kCVReturnSuccess || !pixelBuffer) {
            // The pool is nil until the first append on some iOS versions; fall back to a direct
            // allocation so the first frame still lands.
            NSDictionary *attrs = @{
                (NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
                (NSString *)kCVPixelBufferCGImageCompatibilityKey: @YES,
            };
            status = CVPixelBufferCreate(NULL, (size_t)size.width, (size_t)size.height,
                                         kCVPixelFormatType_32BGRA,
                                         (__bridge CFDictionaryRef)attrs, &pixelBuffer);
        }
        if (status != kCVReturnSuccess || !pixelBuffer) {
            if (note) *note = [NSString stringWithFormat:@"pixel buffer failed %d", status];
            [writer cancelWriting];
            CGColorSpaceRelease(cs);
            return NO;
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, 0);
        void *base = CVPixelBufferGetBaseAddress(pixelBuffer);
        size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
        CGContextRef ctx = CGBitmapContextCreate(base, (size_t)size.width, (size_t)size.height, 8, bytesPerRow, cs,
                                                 kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
        if (!ctx) {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
            CVPixelBufferRelease(pixelBuffer);
            if (note) *note = @"bitmap context null";
            [writer cancelWriting];
            CGColorSpaceRelease(cs);
            return NO;
        }
        // CGBitmapContext has y=0 at the bottom; CVPixelBuffer memory is read top-down, so without
        // this flip the clip plays upside down.
        CGContextTranslateCTM(ctx, 0, size.height);
        CGContextScaleCTM(ctx, 1, -1);
        drawFrame(ctx, coverCG, (CGFloat)i / frames, size, aCG, bCG);
        CGContextRelease(ctx);
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        CMTime time = CMTimeMake(i, kFPS);
        [adaptor appendPixelBuffer:pixelBuffer withPresentationTime:time];
        CVPixelBufferRelease(pixelBuffer);
    }
    CGColorSpaceRelease(cs);
    [input markAsFinished];
    if (cancelled) {
        [writer cancelWriting];
        [NSFileManager.defaultManager removeItemAtURL:into error:nil];
        if (note) *note = @"cancelled";
        return NO;
    }
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(sem); }];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    if (writer.status != AVAssetWriterStatusCompleted) {
        if (note) *note = [NSString stringWithFormat:@"finish failed: %@", writer.error.localizedDescription];
        return NO;
    }
    if (note) *note = [NSString stringWithFormat:@"wrote %dx%d, %d frames", (int)size.width, (int)size.height, frames];
    return YES;
}

void SGGeneratedArtworkMake(UIImage *cover, NSString *identifier, CGFloat aspect, void (^done)(NSURL *file, NSString *note)) {
    if (!cover || !cover.CGImage || !identifier.length || aspect <= 0) {
        dispatch_async(dispatch_get_main_queue(), ^{ done(nil, @"missing input"); });
        return;
    }
    NSString *safe = [[[identifier componentsSeparatedByCharactersInSet:
        [NSCharacterSet.alphanumericCharacterSet invertedSet]] componentsJoinedByString:@"-"]
        stringByReplacingOccurrencesOfString:@"--" withString:@"-"];
    NSString *name = [NSString stringWithFormat:@"generated-%@-%.2f.mp4", safe, aspect];
    NSURL *into = fileFor(name);
    if ([NSFileManager.defaultManager fileExistsAtPath:into.path]) {
        [NSFileManager.defaultManager setAttributes:@{NSFileModificationDate: NSDate.date} ofItemAtPath:into.path error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{ done(into, @"cached"); });
        return;
    }
    @synchronized (queue()) { sg_wanted = identifier; }
    dispatch_async(queue(), ^{
        if (!isWanted(identifier)) {
            dispatch_async(dispatch_get_main_queue(), ^{ done(nil, @"cancelled before start"); });
            return;
        }
        CGSize size = sizeFor(aspect);
        UIColor *colorA, *colorB;
        samplePalette(cover, &colorA, &colorB);
        NSString *note = nil;
        BOOL ok = writeMP4Sync(cover, colorA, colorB, size, identifier, into, &note);
        @synchronized (queue()) {
            if ([sg_wanted isEqualToString:identifier]) sg_wanted = nil;
        }
        dispatch_async(dispatch_get_main_queue(), ^{ done(ok ? into : nil, note); });
    });
}

void SGGeneratedArtworkCancel(void) {
    @synchronized (queue()) { sg_wanted = nil; }
}
