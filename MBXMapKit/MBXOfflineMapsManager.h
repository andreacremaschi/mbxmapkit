//
//  MBXOfflineMapsManager.h
//  
//
//  Created by Andrea Cremaschi on 07/01/15.
//
//

#import <Foundation/Foundation.h>

@class MBXOfflineMapDatabase;
@interface MBXOfflineMapsManager : NSObject

#pragma mark -

/** @name Accessing the Shared Downloader */

/** Returns the shared offline map downloader. */
+ (MBXOfflineMapsManager *)sharedOfflineMapDownloader;

#pragma mark -

/** @name Getting and Setting Attributes */

/** An array of `MBXOfflineMapDatabase` objects representing all completed offline map databases on disk. This is designed, in combination with the properties provided by `MBXOfflineMapDatabase`, to allow enumeration and management of the maps which are available on disk. */
@property (readonly, nonatomic) NSArray *offlineMapDatabases;

/** Whether offline map databases should be excluded from iCloud and iTunes backups. This defaults to `YES`. If you want to make a change, the value will persist across app launches since it changes the offline map folder's resource value on disk. */
@property (nonatomic) BOOL offlineMapsAreExcludedFromBackup;

-(MBXOfflineMapDatabase*)databaseWithUniqueId:(NSString*)uniqueId;

/** @name Removing Offline Maps */

/** Invalidates a given offline map and removes its associated backing database on disk. This is designed for managing the disk storage consumed by offline maps.
 *   @param offlineMapDatabase The offline map database to invalidate. */
- (void)removeOfflineMapDatabase:(MBXOfflineMapDatabase *)offlineMapDatabase;

/** Invalidates the offline map with the given unique identifier and removes its associated backing database on disk. This is designed for managing the disk storage consumed by offline maps.
 *   @param uniqueID The unique ID of the map database to invalidate. */
- (void)removeOfflineMapDatabaseWithID:(NSString *)uniqueID;

@end
