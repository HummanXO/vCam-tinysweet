#import "image_utils.h"
#import "vcam_shared.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <dispatch/dispatch.h>
#import <VideoToolbox/VTPixelTransferSession.h>

// BWNodeOutput is declared by Apple's private CMCapture framework. On some
// iOS builds it is not registered when a camera daemon first loads third-party
// tweaks. Load CMCapture explicitly, then install the Logos group only after
// the class and selector are confirmed to exist.
%group VCamCaptureHooks

%hook BWNodeOutput

- (void)emitSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    unsigned int mediaType = ((unsigned int (*)(id, SEL))objc_msgSend)(self, sel_registerName("mediaType"));
    if (mediaType != 'vide') {
        %orig(sampleBuffer);
        return;
    }

    static dispatch_once_t sFirstVideoBuffer;
    dispatch_once(&sFirstVideoBuffer, ^{
        CVPixelBufferRef firstBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        NSString *dimensions = firstBuffer
            ? [NSString stringWithFormat:@"%zux%zu", CVPixelBufferGetWidth(firstBuffer), CVPixelBufferGetHeight(firstBuffer)]
            : @"unavailable";
        VCamSetRuntimeStatus(@"cameraFramesSeen", @YES);
        VCamSetRuntimeStatus(@"firstCameraFrameAt", [NSDate date]);
        VCamSetRuntimeStatus(@"cameraFrameSize", dimensions);
        NSLog(@"[VCam] first video frame reached BWNodeOutput (%@)", dimensions);
    });

    CVPixelBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!imageBuffer) {
        %orig(sampleBuffer);
        return;
    }

    @autoreleasepool {
        loadReplacementMedia();
        // On iOS 18 the capture service can hand out IOSurface-backed buffers.
        // Keep the buffer locked through the write so downstream consumers see
        // the completed replacement before emitSampleBuffer: forwards it.
        CVReturn lockStatus = CVPixelBufferLockBaseAddress(imageBuffer, 0);
        static dispatch_once_t sFirstLockResult;
        dispatch_once(&sFirstLockResult, ^{
            NSLog(@"[VCam] camera buffer lock status: %d (format %u)", lockStatus,
                  (unsigned int)CVPixelBufferGetPixelFormatType(imageBuffer));
        });
        @try {
            drawReplacementOntoBuffer(imageBuffer, NO);
        } @catch (NSException *exception) {
            VCamSetRuntimeStatus(@"renderError", exception.reason ?: @"Unknown render exception");
            NSLog(@"[VCam] Failed to render replacement media: %@", exception);
        } @finally {
            if (lockStatus == kCVReturnSuccess) CVPixelBufferUnlockBaseAddress(imageBuffer, 0);
        }
    }

    %orig(sampleBuffer);
}

%end
%end

static BOOL VCamRenderRecordingFrame(CVPixelBufferRef frame, CFDictionaryRef attributes) {
    if (CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_32BGRA) {
        return drawReplacementOntoBuffer(frame, YES);
    }

    static VTPixelTransferSessionRef transfer;
    static NSObject *transferLock;
    static dispatch_once_t setupTransfer;
    dispatch_once(&setupTransfer, ^{
        transferLock = [[NSObject alloc] init];
        VTPixelTransferSessionCreate(kCFAllocatorDefault, &transfer);
    });
    if (!transfer) return NO;

    CVPixelBufferRef rgb = NULL;
    CVReturn allocation = CVPixelBufferCreate(kCFAllocatorDefault, CVPixelBufferGetWidth(frame),
        CVPixelBufferGetHeight(frame), kCVPixelFormatType_32BGRA, attributes, &rgb);
    if (allocation != kCVReturnSuccess) return NO;

    @try {
        if (!drawReplacementOntoBuffer(rgb, YES)) return NO;
        OSStatus result;
        @synchronized (transferLock) {
            result = VTPixelTransferSessionTransferImage(transfer, rgb, frame);
        }
        if (result != noErr) {
            static dispatch_once_t transferFailure;
            dispatch_once(&transferFailure, ^{
                NSLog(@"[VCam] movie pixel transfer failed: %d, format %08x",
                      (int)result, (unsigned int)CVPixelBufferGetPixelFormatType(frame));
            });
        }
        return result == noErr;
    } @finally {
        CVPixelBufferRelease(rgb);
    }
}

static CMSampleBufferRef VCamCreateRecordingSample(CMSampleBufferRef original, CVPixelBufferRef input) {
    CMSampleTimingInfo timing;
    if (CMSampleBufferGetNumSamples(original) != 1 ||
        CMSampleBufferGetSampleTimingInfo(original, 0, &timing) != noErr) return NULL;

    NSDictionary *attributes = @{ (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{} };
    CVPixelBufferRef frame = NULL;
    CVReturn result = CVPixelBufferCreate(kCFAllocatorDefault, CVPixelBufferGetWidth(input),
        CVPixelBufferGetHeight(input), CVPixelBufferGetPixelFormatType(input),
        (__bridge CFDictionaryRef)attributes, &frame);
    if (result != kCVReturnSuccess) {
        static dispatch_once_t allocationFailure;
        dispatch_once(&allocationFailure, ^{
            NSLog(@"[VCam] recording buffer allocation failed: %d, format %08x",
                  result, (unsigned int)CVPixelBufferGetPixelFormatType(input));
        });
        return NULL;
    }

    CMSampleBufferRef replacement = NULL;
    CMVideoFormatDescriptionRef format = NULL;
    @try {
        CVBufferPropagateAttachments(input, frame);
        if (VCamRenderRecordingFrame(frame, (__bridge CFDictionaryRef)attributes) &&
            CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, frame, &format) == noErr &&
            CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, frame, format, &timing, &replacement) == noErr) {
            for (int mode = kCMAttachmentMode_ShouldNotPropagate; mode <= kCMAttachmentMode_ShouldPropagate; mode++) {
                CFDictionaryRef attachments = CMCopyDictionaryOfAttachments(kCFAllocatorDefault, original, mode);
                if (attachments) {
                    CMSetAttachments(replacement, attachments, mode);
                    CFRelease(attachments);
                }
            }
            CFArrayRef oldSamples = CMSampleBufferGetSampleAttachmentsArray(original, false);
            if (oldSamples && CFArrayGetCount(oldSamples) == 1) {
                CFArrayRef newSamples = CMSampleBufferGetSampleAttachmentsArray(replacement, true);
                if (newSamples && CFArrayGetCount(newSamples) == 1) {
                    NSDictionary *source = (__bridge NSDictionary *)CFArrayGetValueAtIndex(oldSamples, 0);
                    NSMutableDictionary *target = (__bridge NSMutableDictionary *)CFArrayGetValueAtIndex(newSamples, 0);
                    [target addEntriesFromDictionary:source];
                }
            }
        }
    } @catch (NSException *exception) {
        if (replacement) CFRelease(replacement);
        replacement = NULL;
        NSLog(@"[VCam] recording frame render failed: %@", exception.reason);
    } @finally {
        if (format) CFRelease(format);
        CVPixelBufferRelease(frame);
    }
    return replacement;
}

static CMSampleBufferRef VCamCopyLiveCaptureSample(CMSampleBufferRef sampleBuffer) {
    CVPixelBufferRef buffer = sampleBuffer ? CMSampleBufferGetImageBuffer(sampleBuffer) : NULL;
    if (!buffer || ![VCamCopySetting(VCamEnabledKey) boolValue] ||
        ![VCamCopySetting(VCamSourceModeKey) isEqualToString:@"live"]) return NULL;

    @autoreleasepool {
        loadReplacementMedia();
        return VCamCreateRecordingSample(sampleBuffer, buffer);
    }
}

%group VCamRecordingHook
%hook BWVideoCompressorNode

- (void)renderSampleBuffer:(CMSampleBufferRef)sampleBuffer forInput:(id)input {
    CMSampleBufferRef replacement = VCamCopyLiveCaptureSample(sampleBuffer);
    if (replacement) {
        static dispatch_once_t firstReplacement;
        dispatch_once(&firstReplacement, ^{
            NSLog(@"[VCam] sending replacement sample to movie compressor");
        });
    }
    @try {
        %orig(replacement ?: sampleBuffer, input);
    } @finally {
        if (replacement) CFRelease(replacement);
    }
}

%end
%end

%group VCamPhotoHook
%hook BWPhotoEncoderNode

- (void)renderSampleBuffer:(CMSampleBufferRef)sampleBuffer forInput:(id)input {
    CMSampleBufferRef replacement = VCamCopyLiveCaptureSample(sampleBuffer);
    if (replacement) {
        static dispatch_once_t firstReplacement;
        dispatch_once(&firstReplacement, ^{
            NSLog(@"[VCam] sending replacement sample to photo encoder");
        });
    }
    @try {
        %orig(replacement ?: sampleBuffer, input);
    } @finally {
        if (replacement) CFRelease(replacement);
    }
}

%end
%end

static void *sCMCaptureHandle = NULL;
static BOOL sVCamHookInstalled = NO;
static NSUInteger sVCamHookAttempts = 0;

static void VCamTryInstallCaptureHook(void) {
    if (sVCamHookInstalled) return;
    sVCamHookAttempts++;

    if (!sCMCaptureHandle) {
        sCMCaptureHandle = dlopen("/System/Library/PrivateFrameworks/CMCapture.framework/CMCapture", RTLD_NOW | RTLD_GLOBAL);
        if (!sCMCaptureHandle) {
            // Keep the fallback for OS builds exposing the framework through a different dyld path.
            sCMCaptureHandle = dlopen("/System/Library/PrivateFrameworks/CMCapture.framework", RTLD_NOW | RTLD_GLOBAL);
        }
    }
    if (sCMCaptureHandle) VCamSetRuntimeStatus(@"frameworkLoaded", @YES);
    else NSLog(@"[VCam] CMCapture dlopen failed: %s", dlerror() ?: "unknown");

    Class outputClass = objc_getClass("BWNodeOutput");
    SEL outputSelector = sel_registerName("emitSampleBuffer:");
    Method outputMethod = outputClass ? class_getInstanceMethod(outputClass, outputSelector) : NULL;
    if (outputClass) VCamSetRuntimeStatus(@"hookClassFound", @YES);
    if (outputMethod) VCamSetRuntimeStatus(@"hookSelectorFound", @YES);

    if (outputClass && outputMethod) {
        %init(VCamCaptureHooks);
        Class compressor = objc_getClass("BWVideoCompressorNode");
        SEL render = sel_registerName("renderSampleBuffer:forInput:");
        if (compressor && class_getInstanceMethod(compressor, render)) {
            %init(VCamRecordingHook);
            NSLog(@"[VCam] installed recording input hook");
        }
        Class photoEncoder = objc_getClass("BWPhotoEncoderNode");
        if (photoEncoder && class_getInstanceMethod(photoEncoder, render)) {
            %init(VCamPhotoHook);
            NSLog(@"[VCam] installed photo encoder input hook");
        }
        sVCamHookInstalled = YES;
        VCamSetRuntimeStatus(@"hookState", @"installed");
        VCamSetRuntimeStatus(@"hookInstalledAt", [NSDate date]);
        VCamSetRuntimeStatus(@"hookAttempts", @(sVCamHookAttempts));
        NSLog(@"[VCam] installed BWNodeOutput emitSampleBuffer: hook from CMCapture");
        return;
    }

    NSString *state = outputClass ? @"selector-not-found" : @"class-not-found";
    VCamSetRuntimeStatus(@"hookState", state);
    VCamSetRuntimeStatus(@"hookAttempts", @(sVCamHookAttempts));
    if (!outputClass) {
        const char *error = dlerror();
        VCamSetRuntimeStatus(@"hookDetail", error ? [NSString stringWithUTF8String:error] : @"BWNodeOutput is not registered yet");
    } else {
        VCamSetRuntimeStatus(@"hookDetail", @"BWNodeOutput exists but emitSampleBuffer: is missing");
    }

    // Retry while the camera daemon is still bringing up its capture framework stack.
    if (sVCamHookAttempts < 30) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            VCamTryInstallCaptureHook();
        });
    } else {
        VCamSetRuntimeStatus(@"hookState", @"failed");
    }
}

%ctor {
    @autoreleasepool {
        VCamResetRuntimeStatus();
        NSString *processName = NSProcessInfo.processInfo.processName;
        NSLog(@"[VCam] camera daemon tweak loaded in %@; CMCapture hook installation starting", processName);
        VCamTryInstallCaptureHook();
    }
}
