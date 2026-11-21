#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

// Refreshes shared settings cheaply and loads changed media asynchronously.
void loadReplacementMedia(void);
BOOL drawReplacementOntoBuffer(CVPixelBufferRef targetBuffer, BOOL orientForCapture);
