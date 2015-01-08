//
//  MBXMapBoxMapDownloadOperation.m
//  
//
//  Created by Andrea Cremaschi on 07/01/15.
//
//

#import "MBXMapBoxMapDownloadOperation.h"
#import "MBXRasterTileOverlay.h"

#pragma mark - Private API for cooperating with MBXRasterTileOverlay

@interface MBXRasterTileOverlay ()

+ (NSString *)qualityExtensionForImageQuality:(MBXRasterImageQuality)imageQuality;
+ (NSURL *)markerIconURLForSize:(NSString *)size symbol:(NSString *)symbol color:(NSString *)color;

@end

@implementation MBXMapBoxMapDownloadOperation

- (NSArray *)parseMarkerIconURLStringsFromGeojsonData:(NSData *)data
{
    id markers;
    id value;
    NSMutableArray *iconURLStrings = [[NSMutableArray alloc] init];
    NSError *error;
    NSDictionary *simplestyleJSONDictionary = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if(!error)
    {
        // Find point features in the markers dictionary (if there are any) and add them to the map.
        //
        markers = simplestyleJSONDictionary[@"features"];
        
        if (markers && [markers isKindOfClass:[NSArray class]])
        {
            for (value in (NSArray *)markers)
            {
                if ([value isKindOfClass:[NSDictionary class]])
                {
                    NSDictionary *feature = (NSDictionary *)value;
                    NSString *type = feature[@"geometry"][@"type"];
                    
                    if ([@"Point" isEqualToString:type])
                    {
                        NSString *size        = feature[@"properties"][@"marker-size"];
                        NSString *color       = feature[@"properties"][@"marker-color"];
                        NSString *symbol      = feature[@"properties"][@"marker-symbol"];
                        if (size && color && symbol)
                        {
                            NSURL *markerURL = [MBXRasterTileOverlay markerIconURLForSize:size symbol:symbol color:color];
                            if(markerURL && iconURLStrings )
                            {
                                [iconURLStrings addObject:[markerURL absoluteString]];
                            }
                        }
                    }
                }
                // This is the last line of the loop
            }
        }
    }
    
    // Return only the unique icon urls
    //
    NSSet *uniqueIcons = [NSSet setWithArray:iconURLStrings];
    return [uniqueIcons allObjects];
}
@end
