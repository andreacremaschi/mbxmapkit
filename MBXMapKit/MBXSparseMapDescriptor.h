//
//  MBXOfflineMapDescriptor.h
//  OrobieOutdoor
//
//  Created by Andrea Cremaschi on 25/08/14.
//  Copyright (c) 2014 moma comunicazione. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "MBXConstantsAndTypes.h"
#import <MapKit/MapKit.h>
#import "RMTile.h"
#import "MBXOfflineMapDownloader.h"

@interface MBXSparseMapDescriptor : NSObject <MBXMapDescriptorDelegate>

// Initializator
-(id)initWithMinimumZ: (NSInteger) minimumZ
             maximumZ: (NSInteger) maximumZ;

// Regions
-(void)addRegion: (MKCoordinateRegion) region identifier: (NSString *)regionIdentifier;
-(NSArray*)regionsIdentifiers;
-(MKCoordinateRegion)regionForKey:(NSString*)identifier;

-(int)tilesCount;
-(RMTile)tileAtIndex:(int)index;

@end
