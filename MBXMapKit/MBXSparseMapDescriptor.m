//
//  MBXOfflineMapDescriptor.m
//  OrobieOutdoor
//
//  Created by Andrea Cremaschi on 25/08/14.
//  Copyright (c) 2014 moma comunicazione. All rights reserved.
//

#import "MBXSparseMapDescriptor.h"

@interface MBXSparseMapDescriptor ()
@property (strong) NSDictionary *regionsDictionary;
@property (strong) NSArray *tilesArray;
@property BOOL shouldRebuildTilesCache;
// Properties
@property NSInteger minimumZ;
@property NSInteger maximumZ;

@end

@implementation MBXSparseMapDescriptor

-(id)initWithMinimumZ: (NSInteger) minimumZ maximumZ: (NSInteger) maximumZ {

    self = [super init];
    if (!self) return nil;
    
    _minimumZ = minimumZ;
    _maximumZ = maximumZ;
    
    _regionsDictionary = [NSDictionary dictionary];
    _shouldRebuildTilesCache = YES;

    return self;
}

-(void)addRegion: (MKCoordinateRegion) region identifier: (NSString *)identifier {
    
    _shouldRebuildTilesCache = YES;
    // region to NSData
    NSData *data = [NSData dataWithBytes:&region length:sizeof(region)];
    
    NSMutableDictionary *dict = [self.regionsDictionary mutableCopy];
    [dict setObject: data forKey: identifier];
    self.regionsDictionary = dict;
    
}

-(int)regionsCount {
    return self.regionsDictionary.count;
}

-(NSArray*)regionsIdentifiers {
    return self.regionsDictionary.allKeys;
}

-(void)invalidate {
    _shouldRebuildTilesCache = YES;
    self.tilesArray = nil;
}

-(void) rebuildTilesCache {
    if (_shouldRebuildTilesCache==NO) return;
 
    NSInteger minimumZ = self.minimumZ;
    NSInteger maximumZ = self.maximumZ;
    
    NSMutableDictionary *tilesDict = [NSMutableDictionary dictionary];
    for (NSString *mapRegionIdentifier in self.regionsDictionary.allKeys) {
        
        MKCoordinateRegion mapRegion = [self regionForKey: mapRegionIdentifier];
        CLLocationDegrees minLat = mapRegion.center.latitude - (mapRegion.span.latitudeDelta / 2.0);
        CLLocationDegrees maxLat = minLat + mapRegion.span.latitudeDelta;
        CLLocationDegrees minLon = mapRegion.center.longitude - (mapRegion.span.longitudeDelta / 2.0);
        CLLocationDegrees maxLon = minLon + mapRegion.span.longitudeDelta;
        NSUInteger minX;
        NSUInteger maxX;
        NSUInteger minY;
        NSUInteger maxY;
        NSUInteger tilesPerSide;
        for(NSUInteger zoom = minimumZ; zoom <= maximumZ; zoom++)
        {
            tilesPerSide = pow(2.0, zoom);
            minX = floor(((minLon + 180.0) / 360.0) * tilesPerSide);
            maxX = floor(((maxLon + 180.0) / 360.0) * tilesPerSide);
            minY = floor((1.0 - (logf(tanf(maxLat * M_PI / 180.0) + 1.0 / cosf(maxLat * M_PI / 180.0)) / M_PI)) / 2.0 * tilesPerSide);
            maxY = floor((1.0 - (logf(tanf(minLat * M_PI / 180.0) + 1.0 / cosf(minLat * M_PI / 180.0)) / M_PI)) / 2.0 * tilesPerSide);
            for(NSUInteger x=minX; x<=maxX; x++)
            {
                for(NSUInteger y=minY; y<=maxY; y++)
                {
                    RMTile tile = RMTileMake(x, y, zoom);
                    uint64_t tileHash = RMTileHash(tile);
                    NSData *tileData = [NSData dataWithBytes:&tile length:sizeof(tile)];

                    [tilesDict setObject: tileData forKey:@(tileHash)];
                }
            }
        }
    }
    self.tilesArray = tilesDict.allValues;
}

-(MKCoordinateRegion)regionForKey:(NSString*)identifier {

    NSData *data = self.regionsDictionary[identifier];
    MKCoordinateRegion region;
    [data getBytes:&region length:sizeof(region)];

    return region;
}

#pragma mark - MBXMapDescriptorDelegate

-(int)tilesCount {
    if (_shouldRebuildTilesCache) [self rebuildTilesCache];
    return self.tilesArray.count;
}

-(RMTile)tileAtIndex:(int)index {
    if (_shouldRebuildTilesCache) [self rebuildTilesCache];
    
    RMTile tile;
    NSData *data = self.tilesArray[index];
    [data getBytes: &tile length:sizeof(tile)];
    
    return tile;
}

-(MKCoordinateRegion)mapRegion {
    MKMapRect globalMaprect = MKMapRectNull;
    for (NSString *key in self.regionsDictionary.allKeys) {
        MKCoordinateRegion region = [self regionForKey:key];
        MKMapRect maprect = [self mapRectForCoordinateRegion:region];
        globalMaprect =MKMapRectUnion(maprect, globalMaprect);
    }
    return MKCoordinateRegionForMapRect(globalMaprect);
}

- (MKMapRect)mapRectForCoordinateRegion:(MKCoordinateRegion)coordinateRegion
{
    CLLocationCoordinate2D topLeftCoordinate =
    CLLocationCoordinate2DMake(coordinateRegion.center.latitude
                               + (coordinateRegion.span.latitudeDelta/2.0),
                               coordinateRegion.center.longitude
                               - (coordinateRegion.span.longitudeDelta/2.0));
    
    MKMapPoint topLeftMapPoint = MKMapPointForCoordinate(topLeftCoordinate);
    
    CLLocationCoordinate2D bottomRightCoordinate =
    CLLocationCoordinate2DMake(coordinateRegion.center.latitude
                               - (coordinateRegion.span.latitudeDelta/2.0),
                               coordinateRegion.center.longitude
                               + (coordinateRegion.span.longitudeDelta/2.0));
    
    MKMapPoint bottomRightMapPoint = MKMapPointForCoordinate(bottomRightCoordinate);
    
    MKMapRect mapRect = MKMapRectMake(topLeftMapPoint.x,
                                      topLeftMapPoint.y,
                                      fabs(bottomRightMapPoint.x-topLeftMapPoint.x),
                                      fabs(bottomRightMapPoint.y-topLeftMapPoint.y));
    
    return mapRect;
}

-(NSString *)uniqueID {
    return [[NSUUID UUID] UUIDString];
}

@end
