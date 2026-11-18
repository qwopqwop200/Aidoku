#import <Foundation/Foundation.h>
#import "FontWeightSourceEvidence.h"
int main(int argc,const char** argv){@autoreleasepool {
 if(argc!=3)return 1;NSArray* records=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(argv[1])] options:0 error:nil];NSMutableArray* output=[NSMutableArray array];
 for(NSDictionary* original in records){NSMutableDictionary* packet=[original mutableCopy];for(NSString* key in @[@"rgb",@"ownership",@"valid",@"primary",@"boundary",@"rf",@"nativeMask"])packet[key]=[[NSData alloc]initWithBase64EncodedString:packet[key] options:0];NSError* error=nil;NSDictionary* result=AIDMeasureSourceWeightImageEvidence(packet,&error);if(!result){NSLog(@"%@",error);return 2;}[output addObject:result];}
 NSData* data=[NSJSONSerialization dataWithJSONObject:output options:0 error:nil];return [data writeToFile:@(argv[2]) atomically:YES]?0:3;
}}
