//
//  HLSContentAESKeyReader.m
//  SJMediaCacheServer
//
//  Created by 畅三江 on 2020/6/23.
//

#import "HLSContentAESKeyReader.h"
#import "HLSAsset.h"
#import "MCSFileManager.h"
#import "MCSError.h" 
#import "MCSLogger.h"
#import "MCSData.h"
#import "MCSUtils.h"
#import "MCSURLRecognizer.h"
#import "MCSAssetFileRead.h"
#import "MCSQueue.h"

@interface HLSContentAESKeyReader ()<MCSAssetDataReaderDelegate>
@property (nonatomic, weak) HLSAsset *asset;
@property (nonatomic, strong) NSURLRequest *request;
@property (nonatomic) float networkTaskPriority;

@property (nonatomic) BOOL isCalledPrepare;
@property (nonatomic) BOOL isClosed;

@property (nonatomic, strong, nullable) MCSAssetFileRead *reader;
@end

@implementation HLSContentAESKeyReader
@synthesize delegate = _delegate; 

- (instancetype)initWithAsset:(HLSAsset *)asset request:(NSURLRequest *)request networkTaskPriority:(float)networkTaskPriority delegate:(id<MCSAssetDataReaderDelegate>)delegate {
    self = [super init];
    if ( self ) {
        _asset = asset;
        _request = request;
        _networkTaskPriority = networkTaskPriority;
        _delegate = delegate;
    }
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"%@:<%p> { request: %@\n };", NSStringFromClass(self.class), self, _request];
}

- (void)prepare {
    dispatch_barrier_sync(HLSAESDataReaderQueue(), ^{
        if ( _isClosed || _isCalledPrepare )
            return;
        
        _isCalledPrepare = YES;
        
        MCSContentReaderDebugLog(@"%@: <%p>.prepare { request: %@\n };", NSStringFromClass(self.class), self, _request);
        
        NSString *name = [MCSURLRecognizer.shared nameWithUrl:_request.URL.absoluteString extension:HLSFileExtensionAESKey];
        NSString *filePath = [MCSFileManager HLS_AESKeyFilePathInAsset:_asset.name AESKeyName:name];
        
        if ( [MCSFileManager fileExistsAtPath:filePath] ) {
            // go to read the content
            [self _prepareReaderForLocalFile:filePath];
            return;
        }
        
        MCSContentReaderDebugLog(@"%@: <%p>.download { request: %@\n };", NSStringFromClass(self.class), self, _request);
        
        // download the content
        [self _downloadToFile:filePath];
    });
}

- (nullable MCSAssetFileRead *)reader {
    __block MCSAssetFileRead *reader = nil;
    dispatch_sync(HLSAESDataReaderQueue(), ^{
        reader = _reader;
    });
    return reader;
}

- (nullable NSData *)readDataOfLength:(NSUInteger)lengthParam {
    return [self.reader readDataOfLength:lengthParam];
}

- (BOOL)seekToOffset:(NSUInteger)offset {
    return [self.reader seekToOffset:offset];
}

- (void)close {
    dispatch_barrier_sync(HLSAESDataReaderQueue(), ^{
        [self _close];
    });
}

#pragma mark -

- (NSRange)range {
    return self.reader.range;
}

- (NSUInteger)availableLength {
    return self.reader.availableLength;
}

- (NSUInteger)offset {
    return self.reader.offset;
}

- (BOOL)isPrepared {
    return self.reader.isPrepared;
}

- (BOOL)isDone {
    return self.reader.isDone;
}
 
#pragma mark - MCSAssetDataReaderDelegate

- (void)readerPrepareDidFinish:(id<MCSAssetDataReader>)reader {
    [self.delegate readerPrepareDidFinish:self];
}

- (void)reader:(id<MCSAssetDataReader>)reader hasAvailableDataWithLength:(NSUInteger)length {
    [self.delegate reader:self hasAvailableDataWithLength:length];
}

- (void)reader:(id<MCSAssetDataReader>)reader anErrorOccurred:(NSError *)error {
    dispatch_barrier_sync(HLSAESDataReaderQueue(), ^{
        [self _onError:error];
    });
}

#pragma mark -

- (void)_onError:(NSError *)error {
    if ( _isClosed )
        return;
    
    MCSContentReaderErrorLog(@"%@: <%p>.error { error: %@ };\n", NSStringFromClass(self.class), self, error);

    [self _close];
    
    dispatch_async(MCSDelegateQueue(), ^{
        [self->_delegate reader:self anErrorOccurred:error];
    });
}

- (void)_downloadToFile:(NSString *)filePath {
    dispatch_async(HLSAESDataReaderQueue(), ^{
        NSError *downloadError = nil;
        // Wait until the download is complete
        NSData *contentData = [MCSData dataWithContentsOfRequest:[self->_request mcs_requestWithHTTPAdditionalHeaders:[self->_asset.configuration HTTPAdditionalHeadersForDataRequestsOfType:MCSDataTypeHLSAESKey]] networkTaskPriority:self->_networkTaskPriority error:&downloadError];
        
        // write to file
        __block NSError *writeError = nil;
        if ( contentData != nil ) {
            [MCSFileManager lockWithBlock:^{
                if ( ![MCSFileManager fileExistsAtPath:filePath] ) {
                    [contentData writeToFile:filePath options:NSDataWritingAtomic error:&writeError];
                }
            }];
        }

        dispatch_barrier_sync(HLSAESDataReaderQueue(), ^{
            if ( self->_isClosed ) return;
            NSError *error = downloadError ?: writeError;
            if ( error != nil ) {
                [self _onError:[NSError mcs_errorWithCode:MCSFileError userInfo:@{
                    MCSErrorUserInfoErrorKey : error,
                    MCSErrorUserInfoReasonKey : @"下载失败或写入文件失败!"
                }]];
                return;
            }
            
            [self _prepareReaderForLocalFile:filePath];
        });
    });
}

- (void)_prepareReaderForLocalFile:(NSString *)filePath {
    NSUInteger fileSize = [MCSFileManager fileSizeAtPath:filePath];
    NSRange range = NSMakeRange(0, fileSize);
    _reader = [MCSAssetFileRead.alloc initWithAsset:_asset inRange:range path:filePath readRange:range delegate:self];
    [_reader prepare];
}

- (void)_close {
    if ( _isClosed )
        return;
    
    [_reader close];
    _isClosed = YES;
    
    MCSContentReaderDebugLog(@"%@: <%p>.close;\n", NSStringFromClass(self.class), self);
}

@end
