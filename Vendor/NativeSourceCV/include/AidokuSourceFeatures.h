#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Byte inputs are NSData: rgb8 = width*height*3 RGB; owned8=width*height.
/// bbox = [x,y,w,h], prior=original source em, characterCount=OCR character count.
/// Returns native156, masked180, cadence122, colorBodies128 and components.
@interface ACVSourceFeatureBridge : NSObject
+ (nullable NSDictionary<NSString *,id> *)coreSignalsForPacket:(NSDictionary<NSString *,id> *)packet
                                                      error:(NSError * _Nullable * _Nullable)error;
@end
NS_ASSUME_NONNULL_END
