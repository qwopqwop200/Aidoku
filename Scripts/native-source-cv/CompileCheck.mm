#import "AidokuNativeCV.h"
#import "AidokuSourceFeatures.h"
#import "AidokuAllSourceSignals.h"
int main() {
    @autoreleasepool {
        NSError *error = nil;
        if ([ACVSourceFeatureBridge coreSignalsForPacket:@{} error:&error] || !error) return 1;
        error = nil;
        if (AIDExtractAllSourceSignals(@{}, &error) || !error) return 2;
        return acv_opencv_version()[0] == '4' ? 0 : 3;
    }
}
