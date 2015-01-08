//
//  MBXOfflineMapDownloader.h
//  MBXMapKit
//
//  Copyright (c) 2014 Mapbox. All rights reserved.
//

@import Foundation;
@import MapKit;

#pragma mark - Delegate protocol for progress updates

@class MBXMapDownloadOperation;
@class MBXOfflineMapDatabase;
@protocol MBXMapDescriptorDelegate;

/** The `MBXOfflineMapDownloaderDelegate` protocol provides notifications of download progress and state machine transitions for the shared offline map downloader. */
@protocol MBXOfflineMapDownloaderDelegate <NSObject>

@optional

/** @name Ending Download Jobs */

/** Notifies the delegate that something unexpected, but not necessarily bad, has happened. This is designed to provide an opportunity to recognize potential configuration problems with your map. For example, you might receive an HTTP 404 response for a map tile if you request a map region which extends outside of your map data's coverage area. 
*   @param offlineMapDownloader The offline map downloader. 
*   @param error The error encountered. */
- (void)offlineMapDownloader:(MBXMapDownloadOperation *)offlineMapDownloader didEncounterRecoverableError:(NSError *)error;

/** Notifies the delegate that an offline map download job has finished.
*
*   If the error parameter is `nil`, the job completed successfully. Otherwise, a non-recoverable error was encountered. 
*   @param offlineMapDownloader The offline map downloader which finished a job.
*   @param offlineMapDatabase An offline map database which you can use to create an `MBXRasterTileOverlay`. This paramtere may be `nil` if there was an error.
*   @param error The error which stopped the offline map download job. For successful completion, this parameter will be `nil`. */
- (void)offlineMapDownloader:(MBXMapDownloadOperation *)offlineMapDownloader didCompleteOfflineMapDatabase:(MBXOfflineMapDatabase *)offlineMapDatabase withError:(NSError *)error;

@end


#pragma mark -

/** `MBXOfflineMapDownloader` is a class for managing the downloading of offline maps.
*
*   A single, shared instance of `MBXOfflineMapDownloader` exists and should be accessed with the `sharedOfflineMapDownloader` class method. */
@interface MBXMapDownloadOperation : NSOperation


#pragma mark -

/** @name Initializer */

/** Returns a offline map downloader for the given MKTileOverlay and map descriptor. */
- (id)initWithMapDescriptorDelegate:(id<MBXMapDescriptorDelegate>) mapDescriptorDelegate tileOverlay: (MKTileOverlay*)tileOverlay;

#pragma mark -

/** @name Managing the Delegate */

/** The delegate which should receive notifications as the offline map downloader's state and progress change. */
@property (nonatomic) id<MBXOfflineMapDownloaderDelegate> delegate;

@end


@protocol MBXMapDescriptorDelegate <NSObject>

@required

-(int)tilesCount;
-(MKTileOverlayPath)tileAtIndex:(int)index;

-(NSInteger)minimumZ;
-(NSInteger)maximumZ;
-(MKCoordinateRegion) mapRegion;

-(NSString*)uniqueID;
@end