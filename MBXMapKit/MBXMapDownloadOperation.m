//
//  MBXOfflineMapDownloader.m
//  MBXMapKit
//
//  Copyright (c) 2014 Mapbox. All rights reserved.
//

#import "MBXMapKit.h"

#import <sqlite3.h>

#import "MBXSparseMapDescriptor.h"

#import "TRVSURLSessionOperation.h"
#import "MBXOfflineMapsManager.h"

#pragma mark - Private API for creating verbose errors

@interface NSError (MBXError)

+ (NSError *)mbx_errorWithCode:(NSInteger)code reason:(NSString *)reason description:(NSString *)description;
+ (NSError *)mbx_errorCannotOpenOfflineMapDatabase:(NSString *)path sqliteError:(const char *)sqliteError;
+ (NSError *)mbx_errorQueryFailedForOfflineMapDatabase:(NSString *)path sqliteError:(const char *)sqliteError;

@end

#pragma mark - Private API for cooperating with MBXOfflineMapsManager

@interface MBXOfflineMapsManager ()
-(MBXOfflineMapDatabase *)completeDatabaseFromPartialFileAtURL: (NSURL *)partialFileURL error:(NSError **)error;
-(NSString*)pathForNewPartialDatabase;
@end


#pragma mark -

@interface MBXMapDownloadOperation ()

@property (readwrite, nonatomic) NSString *uniqueID;
@property (readwrite, nonatomic) BOOL includesMetadata;
@property (readwrite, nonatomic) BOOL includesMarkers;
@property (readwrite, nonatomic) MBXRasterImageQuality imageQuality;
@property (readwrite, nonatomic) MKCoordinateRegion mapRegion;
@property (readwrite,nonatomic) NSUInteger totalFilesWritten;
@property (readwrite,nonatomic) NSUInteger totalFilesExpectedToWrite;

@property (nonatomic) NSOperationQueue *backgroundWorkQueue;
@property (nonatomic) NSURLSession *dataSession;
@property (nonatomic) NSInteger activeDataSessionTasks;

@property (strong ) NSString *partialDatabasePath;
@end


#pragma mark -

@implementation MBXMapDownloadOperation

#pragma mark - Initialize and restore saved state from disk

- (id)initWithMapDescriptorDelegate:(id<MBXMapDescriptorDelegate>) mapDescriptorDelegate tileOverlay: (MKTileOverlay*)tileOverlay
{
    // MBXMapKit expects libsqlite to have been compiled with SQLITE_THREADSAFE=2 (multi-thread mode), which means
    // that it can handle its own thread safety as long as you don't attempt to re-use database connections.
    //
    assert(sqlite3_threadsafe()==2);

    self = [super init];

    if(!self) return nil;
    
    _partialDatabasePath = [[MBXOfflineMapsManager sharedOfflineMapDownloader] pathForNewPartialDatabase];

    // Configure the background and sqlite operation queues as a serial queues
    //
    _backgroundWorkQueue = [[NSOperationQueue alloc] init];
    [_backgroundWorkQueue setMaxConcurrentOperationCount:1];
    
    // Configure the download session
    //
    [self setUpNewDataSession];

    // Create the offline database tiles index
    //
    NSError *dbError;
    [self createSQLiteDatabaseWithMapID:@"test"
                          mapDescriptor:mapDescriptorDelegate
                            tileOverlay:tileOverlay
                        includeMetadata:NO
                         includeMarkers:NO
                           imageQuality:MBXRasterImageQualityFull
                                  error:&dbError];
    if (dbError) {
        NSLog(@"Error creating db: %@", dbError.localizedDescription);
        self = nil;
        return nil;
    }
    
    return self;
}


- (void)setUpNewDataSession
{
    // Create a new NSURLDataSession. This is necessary after a call to invalidateAndCancel
    //
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.allowsCellularAccess = YES;
    config.HTTPMaximumConnectionsPerHost = 4;
    config.URLCache = [NSURLCache sharedURLCache];
    config.HTTPAdditionalHeaders = @{ @"User-Agent" : [MBXMapKit userAgent] };
    _dataSession = [NSURLSession sessionWithConfiguration:config];
    _activeDataSessionTasks = 0;
}


#pragma mark - Delegate Notifications

- (void)notifyDelegateOfNetworkConnectivityError:(NSError *)error
{
    assert(![NSThread isMainThread]);

    if([_delegate respondsToSelector:@selector(offlineMapDownloader:didEncounterRecoverableError:)])
    {
        NSError *networkError = [NSError mbx_errorWithCode:MBXMapKitErrorCodeURLSessionConnectivity reason:[error localizedFailureReason] description:[error localizedDescription]];

        dispatch_async(dispatch_get_main_queue(), ^(void){
            [_delegate offlineMapDownloader:self didEncounterRecoverableError:networkError];
        });
    }
}


- (void)notifyDelegateOfSqliteError:(NSError *)error
{
    assert(![NSThread isMainThread]);

    if([_delegate respondsToSelector:@selector(offlineMapDownloader:didEncounterRecoverableError:)])
    {
        NSError *networkError = [NSError mbx_errorWithCode:MBXMapKitErrorCodeOfflineMapSqlite reason:[error localizedFailureReason] description:[error localizedDescription]];

        dispatch_async(dispatch_get_main_queue(), ^(void){
            [_delegate offlineMapDownloader:self didEncounterRecoverableError:networkError];
        });
    }
}


- (void)notifyDelegateOfHTTPStatusError:(NSInteger)status url:(NSURL *)url
{
    assert(![NSThread isMainThread]);

    if([_delegate respondsToSelector:@selector(offlineMapDownloader:didEncounterRecoverableError:)])
    {
        NSString *reason = [NSString stringWithFormat:@"HTTP status %li was received for %@", (long)status,[url absoluteString]];
        NSError *statusError = [NSError mbx_errorWithCode:MBXMapKitErrorCodeHTTPStatus reason:reason description:@"HTTP status error"];

        dispatch_async(dispatch_get_main_queue(), ^(void){
            [_delegate offlineMapDownloader:self didEncounterRecoverableError:statusError];
        });
    }
}


- (void)notifyDelegateOfCompletionWithOfflineMapDatabase:(MBXOfflineMapDatabase *)offlineMap withError:(NSError *)error
{
    assert(![NSThread isMainThread]);

    if([_delegate respondsToSelector:@selector(offlineMapDownloader:didCompleteOfflineMapDatabase:withError:)])
    {
        dispatch_async(dispatch_get_main_queue(), ^(void){
            [_delegate offlineMapDownloader:self didCompleteOfflineMapDatabase:offlineMap withError:error];
        });
    }
}

#pragma mark - Implementation: sqlite stuff

- (BOOL)sqliteSaveDownloadedData:(NSData *)data forURL:(NSURL *)url error: (NSError**)resultError
{
    assert(![NSThread isMainThread]);
    assert(_activeDataSessionTasks > 0);
    
    
    // Open the database read-write and multi-threaded. The slightly obscure c-style variable names here and below are
    // used to stay consistent with the sqlite documentaion.
    NSError *error;
    sqlite3 *db;
    int rc;
    const char *filename = [_partialDatabasePath cStringUsingEncoding:NSUTF8StringEncoding];
    rc = sqlite3_open_v2(filename, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL);
    if (rc)
    {
        // Opening the database failed... something is very wrong.
        //
        error = [NSError mbx_errorCannotOpenOfflineMapDatabase:_partialDatabasePath sqliteError:sqlite3_errmsg(db)];
    }
    else
    {
        // Creating the database file worked, so now start an atomic commit
        //
        NSMutableString *query = [[NSMutableString alloc] init];
        [query appendString:@"PRAGMA foreign_keys=ON;\n"];
        [query appendString:@"BEGIN TRANSACTION;\n"];
        const char *zSql = [query cStringUsingEncoding:NSUTF8StringEncoding];
        char *errmsg;
        sqlite3_exec(db, zSql, NULL, NULL, &errmsg);
        if(errmsg)
        {
            error = [NSError mbx_errorQueryFailedForOfflineMapDatabase:_partialDatabasePath sqliteError:errmsg];
            sqlite3_free(errmsg);
        }
        else
        {
            // Continue by inserting an image blob into the data table
            //
            NSString *query2 = @"INSERT INTO data(value) VALUES(?);";
            const char *zSql2 = [query2 cStringUsingEncoding:NSUTF8StringEncoding];
            int nByte2 = (int)[query2 lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            sqlite3_stmt *ppStmt2;
            const char *pzTail2;
            BOOL successfulBlobInsert = NO;
            if(sqlite3_prepare_v2(db, zSql2, nByte2, &ppStmt2, &pzTail2) == SQLITE_OK)
            {
                if(sqlite3_bind_blob(ppStmt2, 1, [data bytes], (int)[data length], SQLITE_TRANSIENT) == SQLITE_OK)
                {
                    if(sqlite3_step(ppStmt2) == SQLITE_DONE)
                    {
                        successfulBlobInsert = YES;
                    }
                }
            }
            if(!successfulBlobInsert)
            {
                error = [NSError mbx_errorQueryFailedForOfflineMapDatabase:_partialDatabasePath sqliteError:sqlite3_errmsg(db)];
            }
            sqlite3_finalize(ppStmt2);
            
            // Finish up by updating the url in the resources table with status and the blob id, then close out the commit
            //
            if(!error)
            {
                query  = [[NSMutableString alloc] init];
                [query appendFormat:@"UPDATE resources SET status=200,id=last_insert_rowid() WHERE url='%@';\n",[url absoluteString]];
                [query appendString:@"COMMIT;"];
                const char *zSql3 = [query cStringUsingEncoding:NSUTF8StringEncoding];
                sqlite3_exec(db, zSql3, NULL, NULL, &errmsg);
                if(errmsg)
                {
                    error = [NSError mbx_errorQueryFailedForOfflineMapDatabase:_partialDatabasePath sqliteError:errmsg];
                    sqlite3_free(errmsg);
                }
            }
            
        }
    }
    sqlite3_close(db);
    
    if (error && *resultError) *resultError = error;
    return error == nil;
    
}


- (NSArray *)sqliteReadArrayOfOfflineMapURLsToBeDownloadLimit:(NSInteger)limit withError:(NSError **)error
{
    assert(![NSThread isMainThread]);

    // Read up to limit undownloaded urls from the offline map database
    //
    NSMutableArray *urlArray = [[NSMutableArray alloc] init];
    NSString *query = [NSString stringWithFormat:@"SELECT url FROM resources WHERE status IS NULL LIMIT %ld;\n",(long)limit];

    // Open the database
    //
    sqlite3 *db;
    const char *filename = [_partialDatabasePath cStringUsingEncoding:NSUTF8StringEncoding];
    int rc = sqlite3_open_v2(filename, &db, SQLITE_OPEN_READONLY, NULL);
    if (rc)
    {
        // Opening the database failed... something is very wrong.
        //
        if(error)
        {
            *error = [NSError mbx_errorCannotOpenOfflineMapDatabase:_partialDatabasePath sqliteError:sqlite3_errmsg(db)];
        }
    }
    else
    {
        // Success! First prepare the query...
        //
        const char *zSql = [query cStringUsingEncoding:NSUTF8StringEncoding];
        int nByte = (int)[query lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        sqlite3_stmt *ppStmt;
        const char *pzTail;
        rc = sqlite3_prepare_v2(db, zSql, nByte, &ppStmt, &pzTail);
        if (rc)
        {
            // Preparing the query didn't work.
            //
            if(error)
            {
                *error = [NSError mbx_errorQueryFailedForOfflineMapDatabase:_partialDatabasePath sqliteError:sqlite3_errmsg(db)];
            }
        }
        else
        {
            // Evaluate the query
            //
            BOOL keepGoing = YES;
            while(keepGoing)
            {
                rc = sqlite3_step(ppStmt);
                if(rc == SQLITE_ROW && sqlite3_column_count(ppStmt)==1)
                {
                    // Success! We got a URL row, so add it to the array
                    //
                    [urlArray addObject:[NSURL URLWithString:[NSString stringWithUTF8String:(const char *)sqlite3_column_text(ppStmt, 0)]]];
                }
                else if(rc == SQLITE_DONE)
                {
                    keepGoing = NO;
                }
                else
                {
                    // Something unexpected happened.
                    //
                    keepGoing = NO;
                    if(error)
                    {
                        *error = [NSError mbx_errorQueryFailedForOfflineMapDatabase:_partialDatabasePath sqliteError:sqlite3_errmsg(db)];
                    }
                }
            }
        }
        sqlite3_finalize(ppStmt);
    }
    sqlite3_close(db);

    return [NSArray arrayWithArray:urlArray];
}


- (BOOL)sqliteQueryWrittenAndExpectedCountsWithError:(NSError **)error
{
    // NOTE: Unlike most of the sqlite code, this method is written with the expectation that it can and will be called on the main
    //       thread as part of init. This is also meant to be used in other contexts throught the normal serial operation queue.

    // Calculate how many files need to be written in total and how many of them have been written already
    //
    NSString *query = @"SELECT COUNT(url) AS totalFilesExpectedToWrite, (SELECT COUNT(url) FROM resources WHERE status IS NOT NULL) AS totalFilesWritten FROM resources;\n";

    BOOL success = NO;
    // Open the database
    //
    sqlite3 *db;
    const char *filename = [_partialDatabasePath cStringUsingEncoding:NSUTF8StringEncoding];
    int rc = sqlite3_open_v2(filename, &db, SQLITE_OPEN_READONLY, NULL);
    if (rc)
    {
        // Opening the database failed... something is very wrong.
        //
        if(error)
        {
            *error = [NSError mbx_errorCannotOpenOfflineMapDatabase:_partialDatabasePath sqliteError:sqlite3_errmsg(db)];
        }
    }
    else
    {
        // Success! First prepare the query...
        //
        const char *zSql = [query cStringUsingEncoding:NSUTF8StringEncoding];
        int nByte = (int)[query lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        sqlite3_stmt *ppStmt;
        const char *pzTail;
        rc = sqlite3_prepare_v2(db, zSql, nByte, &ppStmt, &pzTail);
        if (rc)
        {
            // Preparing the query didn't work.
            //
            if(error)
            {
                *error = [NSError mbx_errorQueryFailedForOfflineMapDatabase:_partialDatabasePath sqliteError:sqlite3_errmsg(db)];
            }
        }
        else
        {
            // Evaluate the query
            //
            rc = sqlite3_step(ppStmt);
            if (rc == SQLITE_ROW && sqlite3_column_count(ppStmt)==2)
            {
                // Success! We got a row with the counts for resource files
                //
                _totalFilesExpectedToWrite = [[NSString stringWithUTF8String:(const char *)sqlite3_column_text(ppStmt, 0)] integerValue];
                _totalFilesWritten = [[NSString stringWithUTF8String:(const char *)sqlite3_column_text(ppStmt, 1)] integerValue];
                success = YES;
            }
            else
            {
                // Something unexpected happened.
                //
                if(error)
                {
                    *error = [NSError mbx_errorQueryFailedForOfflineMapDatabase:_partialDatabasePath sqliteError:sqlite3_errmsg(db)];
                }
            }
        }
        sqlite3_finalize(ppStmt);
    }
    sqlite3_close(db);

    return success;
}


- (BOOL)sqliteCreateDatabaseUsingMetadata:(NSDictionary *)metadata urlArray:(NSArray *)urlStrings withError:(NSError **)error
{
    BOOL success = NO;

    // Build a query to populate the database (map metadata and list of map resource urls)
    //
    NSMutableString *query = [[NSMutableString alloc] init];
    [query appendString:@"PRAGMA foreign_keys=ON;\n"];
    [query appendString:@"BEGIN TRANSACTION;\n"];
    [query appendString:@"CREATE TABLE metadata (name TEXT UNIQUE, value TEXT);\n"];
    [query appendString:@"CREATE TABLE data (id INTEGER PRIMARY KEY, value BLOB);\n"];
    [query appendString:@"CREATE TABLE resources (url TEXT UNIQUE, status TEXT, id INTEGER REFERENCES data);\n"];
    for(NSString *key in metadata) {
        [query appendFormat:@"INSERT INTO \"metadata\" VALUES('%@','%@');\n", key, [metadata valueForKey:key]];
    }
    for(NSString *url in urlStrings)
    {
        [query appendFormat:@"INSERT INTO \"resources\" VALUES('%@',NULL,NULL);\n",url];
    }
    [query appendString:@"COMMIT;"];
    _totalFilesExpectedToWrite = [urlStrings count];
    _totalFilesWritten = 0;


    // Open the database read-write and multi-threaded. The slightly obscure c-style variable names here and below are
    // used to stay consistent with the sqlite documentaion.
    sqlite3 *db;
    int rc;
    const char *filename = [_partialDatabasePath cStringUsingEncoding:NSUTF8StringEncoding];
    rc = sqlite3_open_v2(filename, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL);
    if (rc)
    {
        // Opening the database failed... something is very wrong.
        //
        if(error != NULL)
        {
            *error = [NSError mbx_errorCannotOpenOfflineMapDatabase:_partialDatabasePath sqliteError:sqlite3_errmsg(db)];
        }
        sqlite3_close(db);
    }
    else
    {
        // Success! Creating the database file worked, so now populate the tables we'll need to hold the offline map
        //
        const char *zSql = [query cStringUsingEncoding:NSUTF8StringEncoding];
        char *errmsg;
        sqlite3_exec(db, zSql, NULL, NULL, &errmsg);
        if(error && errmsg != NULL)
        {
            *error = [NSError mbx_errorQueryFailedForOfflineMapDatabase:_partialDatabasePath sqliteError:errmsg];
            sqlite3_free(errmsg);
        }
        sqlite3_close(db);
        success = YES;
    }
    return success;
}


#pragma mark - API: Create an offline map download operation

- (BOOL)createSQLiteDatabaseWithMapID:(NSString *)mapID mapDescriptor:(id<MBXMapDescriptorDelegate>)mapDescriptor tileOverlay: (MKTileOverlay*)tileOverlay includeMetadata:(BOOL)includeMetadata includeMarkers:(BOOL)includeMarkers imageQuality:(MBXRasterImageQuality)imageQuality error: (NSError **)dbError{
    
    
        // Start a download job to retrieve all the resources needed for using the specified map offline
        //
        NSString *uniqueID = [mapDescriptor uniqueID];
        assert(uniqueID.length>0);
        _uniqueID =  uniqueID;
        _includesMetadata = includeMetadata;
        _includesMarkers = includeMarkers;
        _imageQuality = imageQuality;
        MKCoordinateRegion mapRegion = _mapRegion = [mapDescriptor mapRegion];
        
    NSDictionary *metadataDictionary =  @{
                                          @"uniqueID": _uniqueID,
                                          @"mapID": mapID,
                                          @"includesMetadata" : includeMetadata ? @"YES":@"NO",
                                          @"includesMarkers" : includeMarkers ? @"YES":@"NO",
                                          @"imageQuality" : [NSString stringWithFormat:@"%ld",(long)imageQuality],
                                          // TODO: estrarre lat/lon e deltas
                                          @"region_latitude" : [NSString stringWithFormat:@"%.8f",mapRegion.center.latitude],
                                          @"region_longitude" : [NSString stringWithFormat:@"%.8f",mapRegion.center.longitude],
                                          @"region_latitude_delta" : [NSString stringWithFormat:@"%.8f",mapRegion.span.latitudeDelta],
                                          @"region_longitude_delta" : [NSString stringWithFormat:@"%.8f",mapRegion.span.longitudeDelta],
                                          @"minimumZ" : [NSString stringWithFormat:@"%ld",(long)mapDescriptor.minimumZ],
                                          @"maximumZ" : [NSString stringWithFormat:@"%ld",(long)mapDescriptor.maximumZ]
                                          };
    
        NSMutableArray *urls = [[NSMutableArray alloc] init];
    
        // Include URLs for the metadata and markers json if applicable
        //
//        if(includeMetadata)
//        {
//            [urls addObject:[NSString stringWithFormat:@"https://a.tiles.mapbox.com/%@/%@.json?secure%@",
//                             version,
//                             mapID,
//                             (accessToken ? [@"&" stringByAppendingString:accessToken] : @"")]];
//        }
//        if(includeMarkers)
//        {
//            [urls addObject:[NSString stringWithFormat:@"https://a.tiles.mapbox.com/%@/%@/%@%@",
//                             version,
//                             mapID,
//                             dataName,
//                             (accessToken ? [@"?" stringByAppendingString:accessToken] : @"")]];
//        }
        
        for (long i=0;i<mapDescriptor.tilesCount;i++) {
            MKTileOverlayPath tile = [mapDescriptor tileAtIndex:i];
            NSURL *tileURL = [tileOverlay URLForTilePath: tile];
            [urls addObject:tileURL];
        }
     
        // Determine if we need to add marker icon urls (i.e. parse markers.geojson/features.json), and if so, add them
        //
//        if(includeMarkers)
//        {
//            NSString *dataName = ([MBXMapKit accessToken] ? @"features.json" : @"markers.geojson");
//            NSURL *geojson = [NSURL URLWithString:[NSString stringWithFormat:@"https://a.tiles.mapbox.com/v3/%@/%@", mapID, dataName]];
//            NSURLSessionDataTask *task;
//            NSURLRequest *request = [NSURLRequest requestWithURL:geojson cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:60];
//            task = [_dataSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error)
//                    {
//                        if(error)
//                        {
//                            // We got a session level error which probably indicates a connectivity problem such as airplane mode.
//                            // Since we must fetch and parse markers.geojson/features.json in order to determine which marker icons need to be
//                            // added to the list of urls to download, the lack of network connectivity is a non-recoverable error
//                            // here.
//                            //
//                            [self notifyDelegateOfNetworkConnectivityError:error];
//                            [self cancelImmediatelyWithError:error];
//                        }
//                        else
//                        {
//                            if ([response isKindOfClass:[NSHTTPURLResponse class]] && ((NSHTTPURLResponse *)response).statusCode != 200)
//                            {
//                                // The url for markers.geojson/features.json didn't work (some maps don't have any markers). Notify the delegate of the
//                                // problem, and stop attempting to add marker icons, but don't bail out on whole the offline map download.
//                                // The delegate can decide for itself whether it wants to continue or cancel.
//                                //
//                                [self notifyDelegateOfHTTPStatusError:((NSHTTPURLResponse *)response).statusCode url:response.URL];
//                            }
//                            else
//                            {
//                                // The marker geojson was successfully retrieved, so parse it for marker icons. Note that we shouldn't
//                                // try to save it here, because it may already be in the download queue and saving it twice will mess
//                                // up the count of urls to be downloaded!
//                                //
//                                NSArray *markerIconURLStrings = [self parseMarkerIconURLStringsFromGeojsonData:(NSData *)data];
//                                if(markerIconURLStrings)
//                                {
//                                    [urls addObjectsFromArray:markerIconURLStrings];
//                                }
//                            }
//                            
//                            
//                            // ==========================================================================================================
//                            // == WARNING! WARNING! WARNING!                                                                           ==
//                            // == This stuff is a duplicate of the code immediately below it, but this copy is inside of a completion  ==
//                            // == block while the other isn't. You will be sad and confused if you try to eliminate the "duplication". ==
//                            //===========================================================================================================
//                            
//                            // Create the database and start the download
//                            //
//                            NSError *error;
//                            [self sqliteCreateDatabaseUsingMetadata:metadataDictionary urlArray:urls withError:&error];
//                            if(error)
//                            {
//                                [self cancelImmediatelyWithError:error];
//                            }
//                            else
//                            {
//                                [self notifyDelegateOfInitialCount];
//                                [self startDownloading];
//                            }
//                        }
//                    }];
//            [task resume];
//        }
//        else
        {
            // There aren't any marker icons to worry about, so just create database and start downloading
            //
            NSError *error;
            [self sqliteCreateDatabaseUsingMetadata:metadataDictionary urlArray:urls withError:&error];
            if(error && *dbError) {
                *dbError = error;
            }
            return error == nil;
        }
}

- (void)cancelImmediatelyWithError:(NSError *)error
{
//    // Creating the database failed for some reason, so clean up and change the state back to available
//    //
//    _state = MBXOfflineMapDownloaderStateCanceling;
//    [self notifyDelegateOfStateChange];
//
//    if([_delegate respondsToSelector:@selector(offlineMapDownloader:didCompleteOfflineMapDatabase:withError:)])
//    {
//        dispatch_async(dispatch_get_main_queue(), ^(void){
//            [_delegate offlineMapDownloader:self didCompleteOfflineMapDatabase:nil withError:error];
//        });
//    }
//
//    [_dataSession invalidateAndCancel];
//    [_sqliteQueue cancelAllOperations];
//
//    [_sqliteQueue addOperationWithBlock:^{
//        [self setUpNewDataSession];
//        _totalFilesWritten = 0;
//        _totalFilesExpectedToWrite = 0;
//
//        [[NSFileManager defaultManager] removeItemAtPath:_partialDatabasePath error:nil];
//
//        _state = MBXOfflineMapDownloaderStateAvailable;
//        [self notifyDelegateOfStateChange];
//    }];
}


#pragma mark - API: Control an in-progress offline map download

//- (void)cancel
//{
//    if(_state != MBXOfflineMapDownloaderStateCanceling && _state != MBXOfflineMapDownloaderStateAvailable)
//    {
//        // Stop a download job and discard the associated files
//        //
//        [_backgroundWorkQueue addOperationWithBlock:^{
//            _state = MBXOfflineMapDownloaderStateCanceling;
//            [self notifyDelegateOfStateChange];
//
//            [_dataSession invalidateAndCancel];
//            [_sqliteQueue cancelAllOperations];
//
//            [_sqliteQueue addOperationWithBlock:^{
//                [self setUpNewDataSession];
//                _totalFilesWritten = 0;
//                _totalFilesExpectedToWrite = 0;
//                [[NSFileManager defaultManager] removeItemAtPath:_partialDatabasePath error:nil];
//
//                if([_delegate respondsToSelector:@selector(offlineMapDownloader:didCompleteOfflineMapDatabase:withError:)])
//                {
//                    NSError *canceled = [NSError mbx_errorWithCode:MBXMapKitErrorCodeDownloadingCanceled reason:@"The download job was canceled" description:@"Download canceled"];
//                    dispatch_async(dispatch_get_main_queue(), ^(void){
//                        [_delegate offlineMapDownloader:self didCompleteOfflineMapDatabase:nil withError:canceled];
//                    });
//                }
//
//                _state = MBXOfflineMapDownloaderStateAvailable;
//                [self notifyDelegateOfStateChange];
//            }];
//
//        }];
//    }
//}


//- (void)resume
//{
//    assert(_state == MBXOfflineMapDownloaderStateSuspended);
//
//    // Resume a previously suspended download job
//    //
//    [_backgroundWorkQueue addOperationWithBlock:^{
//        _state = MBXOfflineMapDownloaderStateRunning;
//        [self startDownloading];
//        [self notifyDelegateOfStateChange];
//    }];
//}


//- (void)suspend
//{
//    if(_state == MBXOfflineMapDownloaderStateRunning)
//    {
//        // Stop a download job, preserving the necessary state to resume later
//        //
//        [_backgroundWorkQueue addOperationWithBlock:^{
//            [_sqliteQueue cancelAllOperations];
//            _state = MBXOfflineMapDownloaderStateSuspended;
//            _activeDataSessionTasks = 0;
//            [self notifyDelegateOfStateChange];
//        }];
//    }
//}


#pragma mark -

-(NSInteger)enqueueABatchOfDownloadTasks {
    NSError *error;
    NSArray *urls = [self sqliteReadArrayOfOfflineMapURLsToBeDownloadLimit:30 withError:&error];
    if(error)
    {
        NSLog(@"Error while reading offline map urls: %@",error);
        return -1;
    }
    
    for(NSURL *url in urls)
    {
        NSURLRequest *request = [NSURLRequest requestWithURL:url cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:60];
        _activeDataSessionTasks += 1;
        
        TRVSURLSessionOperation *sessionOperation = [[TRVSURLSessionOperation alloc] initWithSession:self.dataSession request:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) {
            if (!networkError)
            {
                BOOL responseError = [response isKindOfClass:[NSHTTPURLResponse class]] && ((NSHTTPURLResponse *)response).statusCode != 200;
                if (!responseError)
                {
                    // Since the URL was successfully retrieved, save the data
                    //
                    NSError *error;
                    BOOL result = [self sqliteSaveDownloadedData:data forURL:url error:&error ];
                    if (result) {
                        // TODO: update NSProgress
                    } else
                    {
                        // Oops, that didn't work. Notify the delegate.
                        //
                        [self notifyDelegateOfSqliteError:error];
                    }
                }
                else {
                    // This url didn't work. For now, use the primitive error handling method of notifying the delegate and
                    // continuing to request the url (this will eventually cycle back through the download queue since we're
                    // not marking the url as done in the database).
                    //
                    [self notifyDelegateOfHTTPStatusError:((NSHTTPURLResponse *)response).statusCode url:response.URL];
                }
                
            } else {
                // We got a session level error which probably indicates a connectivity problem such as airplane mode.
                // Notify the delegate.
                //
                [self notifyDelegateOfNetworkConnectivityError:error];
            }
        }];
        
        [self.backgroundWorkQueue addOperation: sessionOperation];
    }
    return urls.count;
}

#pragma mark - NSOperation

-(void)start {
        
    NSInteger tasksNumber = [self enqueueABatchOfDownloadTasks];
    do {
        [self.backgroundWorkQueue waitUntilAllOperationsAreFinished];
        tasksNumber = [self enqueueABatchOfDownloadTasks];
    } while (tasksNumber > 0);
    
    if (tasksNumber == 0) {
        // This is what to do when we've downloaded all the files
        //
        NSError *error;
        NSURL *partialFileURL = [NSURL fileURLWithPath:_partialDatabasePath];
        MBXOfflineMapDatabase *offlineMap = [[MBXOfflineMapsManager sharedOfflineMapDownloader] completeDatabaseFromPartialFileAtURL: partialFileURL error: &error];
        [self notifyDelegateOfCompletionWithOfflineMapDatabase:offlineMap withError:error];
    }
}

@end
