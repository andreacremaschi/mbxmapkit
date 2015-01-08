//
//  MBXOfflineMapsManager.m
//  
//
//  Created by Andrea Cremaschi on 07/01/15.
//
//

#import "MBXOfflineMapsManager.h"
#import "MBXOfflineMapDatabase.h"

#pragma mark - Private API for cooperating with MBXOfflineMapDatabase

@interface MBXOfflineMapDatabase ()

@property (readonly, nonatomic) NSString *path;

- (id)initWithContentsOfFile:(NSString *)path;
- (void)invalidate;

@end

@interface MBXOfflineMapsManager ()
@property (nonatomic) NSMutableArray *mutableOfflineMapDatabases;
@property (nonatomic) NSURL *offlineMapDirectory;
@end

@implementation MBXOfflineMapsManager

#pragma mark - API: Shared downloader singleton

+ (MBXOfflineMapsManager *)sharedOfflineMapDownloader
{
    static id _sharedDownloader = nil;
    static dispatch_once_t onceToken;
    
    dispatch_once(&onceToken, ^{
        _sharedDownloader = [[self alloc] init];
    });
    
    return _sharedDownloader;
}

-(id)init {
    
    self = [super init];
    if (!self) return nil;
    
    // Calculate the path in Application Support for storing offline maps
    //
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *appSupport = [fm URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:NO error:nil];
    _offlineMapDirectory = [appSupport URLByAppendingPathComponent:@"MBXMapKit/OfflineMaps"];
    
    // Make sure the offline map directory exists
    //
    NSError *error;
    [fm createDirectoryAtURL:_offlineMapDirectory withIntermediateDirectories:YES attributes:nil error:&error];
    if(error)
    {
        NSLog(@"There was an error with creating the offline map directory: %@", error);
        error = nil;
    }
    
    // Figure out if the offline map directory already has a value for NSURLIsExcludedFromBackupKey. If so,
    // then leave that value alone. Otherwise, set a default value to exclude offline maps from backups.
    //
    NSNumber *excluded;
    [_offlineMapDirectory getResourceValue:&excluded forKey:NSURLIsExcludedFromBackupKey error:&error];
    if(error)
    {
        NSLog(@"There was an error with checking the offline map directory's resource values: %@", error);
        error = nil;
    }

    // Restore persistent state from disk
    //
    _mutableOfflineMapDatabases = [[NSMutableArray alloc] init];
    error = nil;
    NSArray *files = [fm contentsOfDirectoryAtPath:[_offlineMapDirectory path] error:&error];
    if(error)
    {
        NSLog(@"There was an error with listing the contents of the offline map directory: %@", error);
    }
    if (files)
    {
        MBXOfflineMapDatabase *db;
        for(NSString *path in files)
        {
            // Find the completed map databases
            //
            if([path hasSuffix:@".complete"])
            {
                db = [[MBXOfflineMapDatabase alloc] initWithContentsOfFile:[[_offlineMapDirectory URLByAppendingPathComponent:path] path]];
                if(db)
                {
                    [_mutableOfflineMapDatabases addObject:db];
                }
                else
                {
                    NSLog(@"Error: %@ is not a valid offline map database",path);
                }
            }
        }
    }

    
//    if([fm fileExistsAtPath:_partialDatabasePath])
//    {
//        NSError *error;
//        [self sqliteQueryWrittenAndExpectedCountsWithError:&error];
//        if(error)
//        {
//            NSLog(@"Error while querying how many files need to be downloaded %@",error);
//        }
//        else if(_totalFilesWritten >= _totalFilesExpectedToWrite)
//        {
//            // This isn't good... the offline map database is completely downloaded, but it's still in the location for
//            // a download in progress.
//            NSLog(@"Something strange happened. While restoring a supposedly partial offline map download from disk, init found that %ld of %ld urls are complete.",(long)_totalFilesWritten,(long)_totalFilesExpectedToWrite);
//        }
//    }

    return self;
}

- (void)setOfflineMapsAreExcludedFromBackup:(BOOL)offlineMapsAreExcludedFromBackup
{
    NSError *error;
    NSNumber *boolNumber = offlineMapsAreExcludedFromBackup ? @YES : @NO;
    [_offlineMapDirectory setResourceValue:boolNumber forKey:NSURLIsExcludedFromBackupKey error:&error];
    if(error)
    {
        NSLog(@"There was an error setting NSURLIsExcludedFromBackupKey on the offline map directory: %@",error);
    }
    else
    {
        _offlineMapsAreExcludedFromBackup = offlineMapsAreExcludedFromBackup;
    }
}

#pragma mark - API: Access or delete completed offline map databases on disk

- (NSArray *)offlineMapDatabases
{
    // Return an array with offline map database objects representing each of the *complete* map databases on disk
    //
    return [NSArray arrayWithArray:_mutableOfflineMapDatabases];
}

-(MBXOfflineMapDatabase*)databaseWithUniqueId:(NSString*)uniqueId {
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"uniqueID == %@", uniqueId];
    NSArray*array = [_mutableOfflineMapDatabases filteredArrayUsingPredicate:predicate];
    return array.firstObject;
}

- (void)removeOfflineMapDatabase:(MBXOfflineMapDatabase *)offlineMapDatabase
{
    // Mark the offline map object as invalid in case there are any references to it still floating around
    //
    [offlineMapDatabase invalidate];
    
    // If this assert fails, an MBXOfflineMapDatabase object has somehow been initialized with a database path which is not
    // inside of the directory for completed ofline map databases. That should definitely not be happening, and we should definitely
    // not proceed to recursively remove whatever the path string actually is pointed at.
    //
    assert([offlineMapDatabase.path hasPrefix:[_offlineMapDirectory path]]);
    
    // Remove the offline map object from the array and delete it's backing database
    //
    [_mutableOfflineMapDatabases removeObject:offlineMapDatabase];
    
    NSError *error;
    [[NSFileManager defaultManager] removeItemAtPath:offlineMapDatabase.path error:&error];
    if(error)
    {
        NSLog(@"There was an error while attempting to delete an offline map database: %@", error);
    }
}

- (void)removeOfflineMapDatabaseWithID:(NSString *)uniqueID
{
    for (MBXOfflineMapDatabase *database in [self offlineMapDatabases])
    {
        if ([database.uniqueID isEqualToString:uniqueID])
        {
            [self removeOfflineMapDatabase:database];
            return;
        }
    }
}

#pragma mark - 

-(NSString*)pathForNewPartialDatabase {
    // This is where partial offline map databases live (at most 1 at a time!) while their resources are being downloaded
    // TODO: check if partial db exists already
    return [[_offlineMapDirectory URLByAppendingPathComponent:@"newdatabase.partial"] path];
}

- (MBXOfflineMapDatabase *)completeDatabaseFromPartialFileAtURL: (NSURL *)partialFileURL error:(NSError **)error {

    // Rename the file using a unique prefix
    //
    CFUUIDRef uuid = CFUUIDCreate(kCFAllocatorDefault);
    CFStringRef uuidString = CFUUIDCreateString(kCFAllocatorDefault, uuid);
    NSString *newFilename = [NSString stringWithFormat:@"%@.complete",uuidString];
    NSString *newPath = [[_offlineMapDirectory URLByAppendingPathComponent:newFilename] path];
    CFRelease(uuidString);
    CFRelease(uuid);
    [[NSFileManager defaultManager] moveItemAtPath:partialFileURL.path toPath:newPath error:error];
    
    // If the move worked, instantiate and return offline map database
    //
    if(error && *error)
    {
        return nil;
    }
    else
    {
        MBXOfflineMapDatabase *offlineMap = [[MBXOfflineMapDatabase alloc] initWithContentsOfFile:newPath];
        if(offlineMap) {
            [_mutableOfflineMapDatabases addObject:offlineMap];
        }
        return offlineMap;
    }
}

@end
