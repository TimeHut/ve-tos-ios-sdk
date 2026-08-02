/**
 * Copyright 2026 Beijing Volcano Engine Technology Ltd.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import <XCTest/XCTest.h>
#import <Security/Security.h>
#include <errno.h>
#include <fcntl.h>
#include <float.h>
#include <sys/stat.h>
#include <unistd.h>
#import "TOSTestConstants.h"
#import "../../VeTOSiOSSDK/VeTOSiOSSDK/Transfer/TOSTransferOperation.h"
#import "../../VeTOSiOSSDK/VeTOSiOSSDK/Transfer/TOSTransferCheckpoint.h"
#import "../../VeTOSiOSSDK/VeTOSiOSSDK/Transfer/TOSTransferIO.h"
#import "../../VeTOSiOSSDK/VeTOSiOSSDK/Transfer/TOSInput+TransferInternal.h"
#import <VeTOSiOSSDK/TOSNetworking.h>
#import <VeTOSiOSSDK/TOSNetworkingRequestDelegate.h>
#import <VeTOSiOSSDK/TOSClient.h>
#import <VeTOSiOSSDK/TOSCredential.h>
#import <VeTOSiOSSDK/TOSEndpoint.h>

@interface TOSClient (TOSTransferConcurrencyTesting)
- (TOSTransferConcurrencyController *)tos_resumableTransferConcurrencyController;
@end

@interface TOSTestUtil : NSObject
+ (NSString *)randomBucketNameWithPrefix:(NSString *)prefix testClass:(Class)testClass;
+ (nullable NSError *)createBucket:(NSString *)bucket withClient:(TOSClient *)client;
@end

static NSData *TOSTestJSONData(NSDictionary *dictionary) {
    return [NSJSONSerialization dataWithJSONObject:dictionary options:0 error:nil];
}

static NSMutableDictionary *TOSTestMutableJSONCopy(NSDictionary *dictionary) {
    return [[NSJSONSerialization JSONObjectWithData:TOSTestJSONData(dictionary)
                                             options:NSJSONReadingMutableContainers
                                               error:nil] mutableCopy];
}

static NSDictionary *TOSTestPart(NSInteger number,
                                 int64_t offset,
                                 int64_t size,
                                 BOOL completed,
                                 NSString *eTag) {
    return @{ @"part_number": @(number),
              @"offset": @(offset),
              @"size": @(size),
              @"range_start": @(offset),
              @"range_end": @(offset + size - 1),
              @"is_zero_size": @NO,
              @"is_completed": @(completed),
              @"etag": eTag ?: @"",
              @"crc64": @"0" };
}

static NSDictionary *TOSTestUploadCheckpointFixture(void) {
    return @{ @"schema_version": @1,
              @"operation": @"upload",
              @"bucket": @"bucket",
              @"key": @"key",
              @"part_size": @5,
              @"encoding_type": @"url",
              @"upload_id": @"upload-id",
              @"file_path": @"/tmp/source.bin",
              @"file_size": @10,
              @"file_modified_time": @123456,
              @"parts": @[TOSTestPart(1, 0, 5, YES, @"etag-1"),
                           TOSTestPart(2, 5, 5, NO, @"")] };
}

static NSDictionary *TOSTestDownloadCheckpointFixture(void) {
    return @{ @"schema_version": @1,
              @"operation": @"download",
              @"bucket": @"bucket",
              @"key": @"key",
              @"version_id": @"version",
              @"part_size": @5,
              @"if_match": @"condition-etag",
              @"if_modified_since": @100,
              @"if_none_match": @"none",
              @"if_unmodified_since": @200,
              @"object_etag": @"object-etag",
              @"object_last_modified": @300,
              @"object_size": @10,
              @"object_crc64": @"18446744073709551615",
              @"file_path": @"/tmp/destination.bin",
              @"temp_file_path": @"/tmp/destination.bin.temp",
              @"temp_file_device": @"123",
              @"temp_file_inode": @"456",
              @"parts": @[TOSTestPart(1, 0, 5, YES, @""),
                           TOSTestPart(2, 5, 5, NO, @"")] };
}

static NSDictionary *TOSTestCopyCheckpointFixture(void) {
    return @{ @"schema_version": @1,
              @"operation": @"copy",
              @"bucket": @"dst-bucket",
              @"key": @"dst-key",
              @"src_bucket": @"src-bucket",
              @"src_key": @"src-key",
              @"src_version_id": @"src-version",
              @"part_size": @5,
              @"encoding_type": @"url",
              @"upload_id": @"upload-id",
              @"copy_source_if_match": @"condition-etag",
              @"copy_source_if_modified_since": @100,
              @"copy_source_if_none_match": @"none",
              @"copy_source_if_unmodified_since": @200,
              @"source_etag": @"source-etag",
              @"source_last_modified": @300,
              @"source_size": @10,
              @"source_crc64": @"18446744073709551615",
              @"parts": @[TOSTestPart(1, 0, 5, YES, @"etag-1"),
                           TOSTestPart(2, 5, 5, NO, @"")] };
}

typedef NS_ENUM(NSInteger, TOSTestCheckpointFailureStage) {
    TOSTestCheckpointFailureNone,
    TOSTestCheckpointFailureCreateDirectory,
    TOSTestCheckpointFailureWrite,
    TOSTestCheckpointFailurePermissions,
    TOSTestCheckpointFailureReplace,
};

@interface TOSTestCheckpointFileSystem : NSObject <TOSTransferCheckpointFileSystem>
@property (nonatomic, assign) TOSTestCheckpointFailureStage failureStage;
@end

@implementation TOSTestCheckpointFileSystem

- (BOOL)tos_fileExistsAtPath:(NSString *)path isDirectory:(BOOL * _Nullable)isDirectory {
    return [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:isDirectory];
}

- (BOOL)tos_createDirectoryAtPath:(NSString *)path error:(NSError **)error {
    if (self.failureStage == TOSTestCheckpointFailureCreateDirectory) {
        if (error) {
            *error = [NSError errorWithDomain:@"TOSTestCheckpointFileSystem" code:1 userInfo:nil];
        }
        return NO;
    }
    return [[NSFileManager defaultManager] createDirectoryAtPath:path
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:error];
}

- (NSData *)tos_dataAtPath:(NSString *)path error:(NSError **)error {
    return [NSData dataWithContentsOfFile:path options:0 error:error];
}

- (BOOL)tos_writeData:(NSData *)data toPath:(NSString *)path error:(NSError **)error {
    if (self.failureStage == TOSTestCheckpointFailureWrite) {
        if (error) {
            *error = [NSError errorWithDomain:@"TOSTestCheckpointFileSystem" code:2 userInfo:nil];
        }
        return NO;
    }
    return [data writeToFile:path options:NSDataWritingAtomic error:error];
}

- (BOOL)tos_setPosixPermissions:(NSNumber *)permissions atPath:(NSString *)path error:(NSError **)error {
    if (self.failureStage == TOSTestCheckpointFailurePermissions) {
        if (error) {
            *error = [NSError errorWithDomain:@"TOSTestCheckpointFileSystem" code:3 userInfo:nil];
        }
        return NO;
    }
    return [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: permissions}
                                            ofItemAtPath:path
                                                   error:error];
}

- (BOOL)tos_replaceItemAtPath:(NSString *)path withItemAtPath:(NSString *)temporaryPath error:(NSError **)error {
    if (self.failureStage == TOSTestCheckpointFailureReplace) {
        if (error) {
            *error = [NSError errorWithDomain:@"TOSTestCheckpointFileSystem" code:4 userInfo:nil];
        }
        return NO;
    }
    return [[NSFileManager defaultManager] replaceItemAtURL:[NSURL fileURLWithPath:path]
                                               withItemAtURL:[NSURL fileURLWithPath:temporaryPath]
                                              backupItemName:nil
                                                     options:0
                                            resultingItemURL:nil
                                                       error:error];
}

- (void)tos_removeItemAtPath:(NSString *)path {
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
}

@end

@interface TOSTestRecordingLimiter : NSObject <TOSRateLimiter>
@property (nonatomic, strong) NSMutableArray<NSNumber *> *requests;
@end

@implementation TOSTestRecordingLimiter

- (instancetype)init {
    self = [super init];
    if (self) {
        _requests = [NSMutableArray array];
    }
    return self;
}

- (BOOL)acquire:(int64_t)want timeToWait:(NSTimeInterval *)timeToWait {
    [self.requests addObject:@(want)];
    if (timeToWait) {
        *timeToWait = 0;
    }
    return YES;
}

@end

@interface TOSTestCappedRecordingLimiter : NSObject <TOSRateLimiter>
@property (nonatomic, strong) NSMutableArray<NSNumber *> *requests;
@end

@implementation TOSTestCappedRecordingLimiter

- (instancetype)init {
    self = [super init];
    if (self) {
        _requests = [NSMutableArray array];
    }
    return self;
}

- (int64_t)tos_maximumAcquisitionSize {
    return 4;
}

- (BOOL)acquire:(int64_t)want timeToWait:(NSTimeInterval *)timeToWait {
    [self.requests addObject:@(want)];
    if (timeToWait) {
        *timeToWait = 0;
    }
    return YES;
}

@end


@interface TOSTestStreamDelegate : NSObject <NSStreamDelegate>
@property (nonatomic, strong) NSMutableArray<NSNumber *> *events;
@end

@implementation TOSTestStreamDelegate

- (instancetype)init {
    self = [super init];
    if (self) {
        _events = [NSMutableArray array];
    }
    return self;
}

- (void)stream:(NSStream *)aStream handleEvent:(NSStreamEvent)eventCode {
    [self.events addObject:@(eventCode)];
}

@end


@interface TOSTestFailingPositionalWriter : NSObject <TOSTransferPositionalWriting>
@end

@implementation TOSTestFailingPositionalWriter

- (ssize_t)tos_writeFileDescriptor:(int)fileDescriptor
                             buffer:(const void *)buffer
                             length:(size_t)length
                             offset:(off_t)offset
                         posixError:(int *)posixError {
    if (posixError) {
        *posixError = ENOSPC;
    }
    return -1;
}

@end

@interface TOSTestLongPositionalWriter : NSObject <TOSTransferPositionalWriting>
@end

@implementation TOSTestLongPositionalWriter

- (ssize_t)tos_writeFileDescriptor:(int)fileDescriptor
                             buffer:(const void *)buffer
                             length:(size_t)length
                             offset:(off_t)offset
                         posixError:(int *)posixError {
    return (ssize_t)length + 1;
}

@end

@interface TOSTestPartialPositionalWriter : NSObject <TOSTransferPositionalWriting>
@property (nonatomic, assign) NSInteger calls;
@end

@implementation TOSTestPartialPositionalWriter

- (ssize_t)tos_writeFileDescriptor:(int)fileDescriptor
                             buffer:(const void *)buffer
                             length:(size_t)length
                             offset:(off_t)offset
                         posixError:(int *)posixError {
    self.calls += 1;
    if (self.calls == 1) {
        if (posixError) {
            *posixError = EINTR;
        }
        return -1;
    }
    size_t partialLength = MIN(length, 2);
    ssize_t result = pwrite(fileDescriptor, buffer, partialLength, offset);
    if (result < 0 && posixError) {
        *posixError = errno;
    }
    return result;
}

@end

@interface TOSTestBlockingPositionalWriter : NSObject <TOSTransferPositionalWriting>
@property (nonatomic, strong) dispatch_semaphore_t tos_callsStarted;
@property (nonatomic, strong) dispatch_semaphore_t tos_allowWrites;
@property (nonatomic, strong) NSLock *tos_lock;
@property (nonatomic, assign) NSInteger tos_activeCalls;
@property (nonatomic, assign) NSInteger tos_maximumActiveCalls;
@end

@implementation TOSTestBlockingPositionalWriter

- (instancetype)init {
    self = [super init];
    if (self) {
        _tos_callsStarted = dispatch_semaphore_create(0);
        _tos_allowWrites = dispatch_semaphore_create(0);
        _tos_lock = [NSLock new];
    }
    return self;
}

- (ssize_t)tos_writeFileDescriptor:(int)fileDescriptor
                             buffer:(const void *)buffer
                             length:(size_t)length
                             offset:(off_t)offset
                         posixError:(int *)posixError {
    [self.tos_lock lock];
    self.tos_activeCalls += 1;
    self.tos_maximumActiveCalls = MAX(self.tos_maximumActiveCalls, self.tos_activeCalls);
    [self.tos_lock unlock];
    dispatch_semaphore_signal(self.tos_callsStarted);
    dispatch_semaphore_wait(self.tos_allowWrites, DISPATCH_TIME_FOREVER);

    ssize_t result = pwrite(fileDescriptor, buffer, length, offset);
    if (result < 0 && posixError) {
        *posixError = errno;
    }
    [self.tos_lock lock];
    self.tos_activeCalls -= 1;
    [self.tos_lock unlock];
    return result;
}

@end

@interface TOSDownloadFileWriter (TOSTestConfiguration)
- (BOOL)tos_configureWithFileDescriptor:(int)fileDescriptor
                               filePath:(NSString *)filePath
                                   size:(int64_t)size
                       positionalWriter:(id<TOSTransferPositionalWriting>)positionalWriter
                            rateLimiter:(id<TOSRateLimiter>)rateLimiter
                             cancelHook:(TOSCancelHook *)cancelHook
                                  error:(NSError **)error;
@end

@interface TOSTestFailingDownloadFileWriter : TOSDownloadFileWriter
@end

@implementation TOSTestFailingDownloadFileWriter

- (BOOL)tos_configureWithFileDescriptor:(int)fileDescriptor
                               filePath:(NSString *)filePath
                                   size:(int64_t)size
                       positionalWriter:(id<TOSTransferPositionalWriting>)positionalWriter
                            rateLimiter:(id<TOSRateLimiter>)rateLimiter
                             cancelHook:(TOSCancelHook *)cancelHook
                                  error:(NSError **)error {
    close(fileDescriptor);
    if (error) {
        *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOSPC userInfo:nil];
    }
    return NO;
}

@end


static NSData *TOSTestPatternData(NSUInteger length) {
    NSMutableData *data = [NSMutableData dataWithLength:length];
    uint8_t *bytes = data.mutableBytes;
    for (NSUInteger index = 0; index < length; index++) {
        bytes[index] = (uint8_t)(index % 251);
    }
    return data;
}

@interface TOSTestURLSessionTask : NSURLSessionDataTask
@property (nonatomic, assign) NSInteger tos_cancelCount;
@property (nonatomic, assign) NSUInteger tos_taskIdentifier;
@property (nonatomic, strong) NSURLResponse *tos_response;
@end

@implementation TOSTestURLSessionTask

- (void)cancel {
    self.tos_cancelCount += 1;
}

- (NSUInteger)taskIdentifier {
    return self.tos_taskIdentifier;
}

- (NSURLResponse *)response {
    return self.tos_response;
}

@end

static TOSTestURLSessionTask *TOSTestCreateURLSessionTask(void) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [TOSTestURLSessionTask new];
#pragma clang diagnostic pop
}

static NSHTTPURLResponse *TOSTestHTTPResponse(NSInteger statusCode, NSDictionary<NSString *, NSString *> *headers) {
    return [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://example.com/object"]
                                      statusCode:statusCode
                                     HTTPVersion:@"HTTP/1.1"
                                    headerFields:headers];
}

@interface TOSTestCapturingNetworking : TOSNetworking
@property (nonatomic, strong) TOSNetworkingRequestDelegate *tos_capturedDelegate;
@end

@implementation TOSTestCapturingNetworking

- (TOSTask *)sendRequest:(TOSNetworkingRequestDelegate *)request {
    self.tos_capturedDelegate = request;
    return [TOSTask taskWithResult:nil];
}

@end

@interface TOSClient (TOSTransferCoreTestsLegacyUpload)
- (TOSTask *)validateUploadFileRequest:(TOSUploadFileInput *)request;
@end

@interface TOSTestLegacyUploadClient : TOSClient
@property (nonatomic, assign) NSInteger tos_validatedTaskNum;
@end

@implementation TOSTestLegacyUploadClient

- (TOSTask *)validateUploadFileRequest:(TOSUploadFileInput *)request {
    TOSTask *task = [super validateUploadFileRequest:request];
    self.tos_validatedTaskNum = request.tosTaskNum;
    return task;
}

@end

@interface TOSTestCreateBucketClient : TOSClient
@property (nonatomic, copy) NSArray<TOSTask *> *tos_tasks;
@property (nonatomic, copy) NSArray<TOSTask *> *tos_headTasks;
@property (nonatomic, assign) NSInteger tos_createBucketCalls;
@property (nonatomic, assign) NSInteger tos_headBucketCalls;
@end

@implementation TOSTestCreateBucketClient

- (TOSTask *)createBucket:(TOSCreateBucketInput *)request {
    (void)request;
    NSInteger index = MIN(self.tos_createBucketCalls, (NSInteger)self.tos_tasks.count - 1);
    self.tos_createBucketCalls += 1;
    return self.tos_tasks[index];
}

- (TOSTask *)headBucket:(TOSHeadBucketInput *)request {
    (void)request;
    NSInteger index = MIN(self.tos_headBucketCalls, (NSInteger)self.tos_headTasks.count - 1);
    self.tos_headBucketCalls += 1;
    return self.tos_headTasks[index];
}

@end

@interface TOSTestServerTrustProtectionSpace : NSURLProtectionSpace
@property (nonatomic, assign) SecTrustRef tos_serverTrust;
@end

@implementation TOSTestServerTrustProtectionSpace

- (SecTrustRef)serverTrust {
    return self.tos_serverTrust;
}

@end

@interface TOSTestTransferOperation : TOSTransferOperation
@property (nonatomic, copy) NSArray *tos_items;
@property (nonatomic, strong) NSLock *tos_lock;
@property (nonatomic, assign) NSInteger tos_activeAttempts;
@property (nonatomic, assign) NSInteger tos_maxActiveAttempts;
@property (nonatomic, assign) NSInteger tos_startedAttempts;
@property (nonatomic, assign) NSInteger tos_failureIndex;
@property (nonatomic, assign) NSTimeInterval tos_attemptDelay;
@end

@implementation TOSTestTransferOperation

- (instancetype)initWithTaskNum:(NSInteger)taskNum
                  maxRetryCount:(NSInteger)maxRetryCount
                      cancelHook:(TOSCancelHook *)cancelHook
                        progress:(TOSTransferProgress *)progress {
    self = [super initWithTaskNum:taskNum
                   maxRetryCount:maxRetryCount
                       cancelHook:cancelHook
                         progress:progress];
    if (self) {
        _tos_lock = [NSLock new];
        _tos_failureIndex = NSNotFound;
        _tos_attemptDelay = 0.01;
    }
    return self;
}

- (NSArray *)tos_pendingItems {
    return self.tos_items ?: @[];
}

- (TOSTask<TOSTransferAttemptResult *> *)tos_attemptItem:(NSNumber *)item
                                              retryCount:(NSInteger)retryCount
                                     networkCancellation:(TOSTransferNetworkCancellation *)networkCancellation {
    TOSTaskCompletionSource<TOSTransferAttemptResult *> *source = [TOSTaskCompletionSource taskCompletionSource];
    [self.tos_lock lock];
    self.tos_startedAttempts += 1;
    self.tos_activeAttempts += 1;
    self.tos_maxActiveAttempts = MAX(self.tos_maxActiveAttempts, self.tos_activeAttempts);
    [self.tos_lock unlock];

    NSTimeInterval delay = item.integerValue == self.tos_failureIndex ? 0.001 : self.tos_attemptDelay;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        [self.tos_lock lock];
        self.tos_activeAttempts -= 1;
        [self.tos_lock unlock];

        TOSTransferAttemptResult *result = [TOSTransferAttemptResult new];
        if (item.integerValue == self.tos_failureIndex) {
            result.error = [NSError errorWithDomain:@"test.transfer" code:17 userInfo:nil];
            result.statusCode = 400;
        } else {
            result.value = item;
        }
        [source trySetResult:result];
    });
    return source.task;
}

@end

@interface TOSTestScriptedTransferOperation : TOSTransferOperation
@property (nonatomic, copy) NSArray<TOSTransferAttemptResult *> *tos_scriptedResults;
@property (nonatomic, strong) NSMutableArray *tos_attemptMarkers;
@property (nonatomic, assign) NSInteger tos_attemptCount;
@end

@implementation TOSTestScriptedTransferOperation

- (NSArray *)tos_pendingItems {
    return @[@"part"];
}

- (TOSTask<TOSTransferAttemptResult *> *)tos_attemptItem:(id)item
                                              retryCount:(NSInteger)retryCount
                                     networkCancellation:(TOSTransferNetworkCancellation *)networkCancellation {
    if (!self.tos_attemptMarkers) {
        self.tos_attemptMarkers = [NSMutableArray array];
    }
    [self.tos_attemptMarkers addObject:[NSObject new]];
    self.tos_attemptCount += 1;
    NSInteger index = MIN(retryCount, (NSInteger)self.tos_scriptedResults.count - 1);
    return [TOSTask taskWithResult:self.tos_scriptedResults[index]];
}

@end

@interface TOSTestControlledTransferOperation : TOSTransferOperation
@property (nonatomic, copy) NSArray *tos_items;
@property (nonatomic, strong) NSLock *tos_lock;
@property (nonatomic, strong) NSMutableArray<TOSTaskCompletionSource<TOSTransferAttemptResult *> *> *tos_sources;
@property (nonatomic, copy) dispatch_block_t tos_attemptStarted;
@property (nonatomic, assign) BOOL tos_autoCompleteAttempts;
@end

@implementation TOSTestControlledTransferOperation

- (instancetype)initWithTaskNum:(NSInteger)taskNum
                  maxRetryCount:(NSInteger)maxRetryCount
                      cancelHook:(TOSCancelHook *)cancelHook
                        progress:(TOSTransferProgress *)progress {
    self = [super initWithTaskNum:taskNum
                   maxRetryCount:maxRetryCount
                       cancelHook:cancelHook
                         progress:progress];
    if (self) {
        _tos_lock = [NSLock new];
        _tos_sources = [NSMutableArray array];
    }
    return self;
}

- (instancetype)initWithTaskNum:(NSInteger)taskNum
                  maxRetryCount:(NSInteger)maxRetryCount
                      cancelHook:(TOSCancelHook *)cancelHook
                        progress:(TOSTransferProgress *)progress
           concurrencyController:(TOSTransferConcurrencyController *)concurrencyController {
    self = [super initWithTaskNum:taskNum
                   maxRetryCount:maxRetryCount
                       cancelHook:cancelHook
                         progress:progress
            concurrencyController:concurrencyController];
    if (self) {
        _tos_lock = [NSLock new];
        _tos_sources = [NSMutableArray array];
    }
    return self;
}

- (NSArray *)tos_pendingItems {
    return self.tos_items ?: @[];
}

- (TOSTask<TOSTransferAttemptResult *> *)tos_attemptItem:(id)item
                                              retryCount:(NSInteger)retryCount
                                     networkCancellation:(TOSTransferNetworkCancellation *)networkCancellation {
    TOSTaskCompletionSource<TOSTransferAttemptResult *> *source = [TOSTaskCompletionSource taskCompletionSource];
    [self.tos_lock lock];
    [self.tos_sources addObject:source];
    [self.tos_lock unlock];
    if (self.tos_attemptStarted) {
        self.tos_attemptStarted();
    }
    if (self.tos_autoCompleteAttempts) {
        TOSTransferAttemptResult *result = [TOSTransferAttemptResult new];
        result.value = item;
        [source trySetResult:result];
    }
    return source.task;
}

- (NSArray<TOSTaskCompletionSource<TOSTransferAttemptResult *> *> *)tos_sourceSnapshot {
    [self.tos_lock lock];
    NSArray *sources = [self.tos_sources copy];
    [self.tos_lock unlock];
    return sources;
}

@end

@interface TOSTransferCoreTests : XCTestCase
@end

@implementation TOSTransferCoreTests

- (void)testClientResumableTransferConcurrencyConfigurationDefaultsAndClamps {
    NSString *credentialValue = NSUUID.UUID.UUIDString;
    TOSCredential *credential = [[TOSCredential alloc] initWithAccessKey:credentialValue
                                                                secretKey:credentialValue];
    TOSEndpoint *endpoint = [[TOSEndpoint alloc] initWithURLString:@"https://example.com"
                                                        withRegion:@"test-region"];
    TOSClientConfiguration *configuration =
        [[TOSClientConfiguration alloc] initWithEndpoint:endpoint credential:credential];

    XCTAssertEqual(configuration.maxConcurrentResumableTransferTaskCount, 5U);
    configuration.maxConcurrentResumableTransferTaskCount = 0;
    XCTAssertEqual(configuration.maxConcurrentResumableTransferTaskCount, 1U);
    configuration.maxConcurrentResumableTransferTaskCount = 1001;
    XCTAssertEqual(configuration.maxConcurrentResumableTransferTaskCount, 1000U);
    configuration.maxConcurrentResumableTransferTaskCount = 12;
    XCTAssertEqual(configuration.maxConcurrentResumableTransferTaskCount, 12U);

    configuration.maxConcurrentResumableTransferTaskCount = 2;
    TOSClient *client = [[TOSClient alloc] initWithConfiguration:configuration];
    configuration.maxConcurrentResumableTransferTaskCount = 8;
    XCTAssertEqual([client tos_resumableTransferConcurrencyController].limit, 2);
    TOSClient *updatedClient = [[TOSClient alloc] initWithConfiguration:configuration];
    XCTAssertEqual([updatedClient tos_resumableTransferConcurrencyController].limit, 8);
}

- (void)testTransferSchedulersShareClientConcurrencyController {
    TOSTransferConcurrencyController *controller =
        [[TOSTransferConcurrencyController alloc] initWithLimit:2];
    TOSTestControlledTransferOperation *first =
        [[TOSTestControlledTransferOperation alloc]
         initWithTaskNum:3
         maxRetryCount:0
         cancelHook:nil
         progress:[[TOSTransferProgress alloc] initWithListener:nil]
         concurrencyController:controller];
    TOSTestControlledTransferOperation *second =
        [[TOSTestControlledTransferOperation alloc]
         initWithTaskNum:3
         maxRetryCount:0
         cancelHook:nil
         progress:[[TOSTransferProgress alloc] initWithListener:nil]
         concurrencyController:controller];
    first.tos_items = @[@1, @2, @3];
    second.tos_items = @[@4, @5, @6];

    NSLock *startLock = [NSLock new];
    __block NSInteger startedCount = 0;
    XCTestExpectation *initialWave = [self expectationWithDescription:@"shared initial wave"];
    initialWave.expectedFulfillmentCount = 2;
    dispatch_block_t attemptStarted = ^{
        [startLock lock];
        startedCount += 1;
        NSInteger current = startedCount;
        [startLock unlock];
        if (current <= 2) {
            [initialWave fulfill];
        }
    };
    first.tos_attemptStarted = attemptStarted;
    second.tos_attemptStarted = attemptStarted;

    XCTestExpectation *firstFinished = [self expectationWithDescription:@"first transfer finished"];
    XCTestExpectation *secondFinished = [self expectationWithDescription:@"second transfer finished"];
    [first.task continueWithBlock:^id(TOSTask *task) {
        [firstFinished fulfill];
        return nil;
    }];
    [second.task continueWithBlock:^id(TOSTask *task) {
        [secondFinished fulfill];
        return nil;
    }];

    [first start];
    [second start];
    [self waitForExpectations:@[initialWave] timeout:2.0];
    XCTAssertEqual([first tos_sourceSnapshot].count + [second tos_sourceSnapshot].count, 2);

    first.tos_autoCompleteAttempts = YES;
    second.tos_autoCompleteAttempts = YES;
    TOSTransferAttemptResult *success = [TOSTransferAttemptResult new];
    success.value = @"ok";
    for (TOSTaskCompletionSource<TOSTransferAttemptResult *> *source in [first tos_sourceSnapshot]) {
        [source trySetResult:success];
    }
    for (TOSTaskCompletionSource<TOSTransferAttemptResult *> *source in [second tos_sourceSnapshot]) {
        [source trySetResult:success];
    }
    [self waitForExpectations:@[firstFinished, secondFinished] timeout:2.0];

    XCTAssertNil(first.task.error);
    XCTAssertNil(second.task.error);
    [startLock lock];
    NSInteger finalStartedCount = startedCount;
    [startLock unlock];
    XCTAssertEqual(finalStartedCount, 6);
}

- (void)testTransferWaitingForSharedPermitCanBeCancelledPromptly {
    TOSTransferConcurrencyController *controller =
        [[TOSTransferConcurrencyController alloc] initWithLimit:1];
    TOSTestControlledTransferOperation *first =
        [[TOSTestControlledTransferOperation alloc]
         initWithTaskNum:1
         maxRetryCount:0
         cancelHook:nil
         progress:[[TOSTransferProgress alloc] initWithListener:nil]
         concurrencyController:controller];
    TOSCancelHook *cancelHook = [TOSCancelHook new];
    TOSTestControlledTransferOperation *waiting =
        [[TOSTestControlledTransferOperation alloc]
         initWithTaskNum:1
         maxRetryCount:0
         cancelHook:cancelHook
         progress:[[TOSTransferProgress alloc] initWithListener:nil]
         concurrencyController:controller];
    first.tos_items = @[@1];
    waiting.tos_items = @[@2];
    XCTestExpectation *firstStarted = [self expectationWithDescription:@"first attempt started"];
    first.tos_attemptStarted = ^{
        [firstStarted fulfill];
    };
    XCTestExpectation *waitingFinished = [self expectationWithDescription:@"waiting transfer cancelled"];
    [waiting.task continueWithBlock:^id(TOSTask *task) {
        [waitingFinished fulfill];
        return nil;
    }];

    [first start];
    [self waitForExpectations:@[firstStarted] timeout:1.0];
    [waiting start];
    [cancelHook cancel:NO];
    [self waitForExpectations:@[waitingFinished] timeout:1.0];

    XCTAssertNotNil(waiting.task.error);
    XCTAssertEqual([waiting tos_sourceSnapshot].count, 0);

    TOSTransferAttemptResult *success = [TOSTransferAttemptResult new];
    success.value = @1;
    [[first tos_sourceSnapshot].firstObject trySetResult:success];
    XCTestExpectation *firstFinished = [self expectationWithDescription:@"first transfer finished"];
    [first.task continueWithBlock:^id(TOSTask *task) {
        [firstFinished fulfill];
        return nil;
    }];
    [self waitForExpectations:@[firstFinished] timeout:1.0];
}

- (void)testSharedConcurrencyDoesNotStarveLaterTransfer {
    TOSTransferConcurrencyController *controller =
        [[TOSTransferConcurrencyController alloc] initWithLimit:1];
    TOSCancelHook *firstCancelHook = [TOSCancelHook new];
    TOSCancelHook *secondCancelHook = [TOSCancelHook new];
    TOSTestControlledTransferOperation *first =
        [[TOSTestControlledTransferOperation alloc]
         initWithTaskNum:3
         maxRetryCount:0
         cancelHook:firstCancelHook
         progress:[[TOSTransferProgress alloc] initWithListener:nil]
         concurrencyController:controller];
    TOSTestControlledTransferOperation *second =
        [[TOSTestControlledTransferOperation alloc]
         initWithTaskNum:1
         maxRetryCount:0
         cancelHook:secondCancelHook
         progress:[[TOSTransferProgress alloc] initWithListener:nil]
         concurrencyController:controller];
    first.tos_items = @[@1, @2, @3];
    second.tos_items = @[@4];

    XCTestExpectation *firstStarted = [self expectationWithDescription:@"first transfer started"];
    XCTestExpectation *nextStarted = [self expectationWithDescription:@"next transfer started"];
    NSLock *orderLock = [NSLock new];
    __block NSInteger firstStartCount = 0;
    __block NSString *nextOwner = nil;
    first.tos_attemptStarted = ^{
        [orderLock lock];
        firstStartCount += 1;
        if (firstStartCount == 1) {
            [firstStarted fulfill];
        } else if (!nextOwner) {
            nextOwner = @"first";
            [nextStarted fulfill];
        }
        [orderLock unlock];
    };
    second.tos_attemptStarted = ^{
        [orderLock lock];
        if (!nextOwner) {
            nextOwner = @"second";
            [nextStarted fulfill];
        }
        [orderLock unlock];
    };

    [first start];
    [self waitForExpectations:@[firstStarted] timeout:1.0];
    [second start];
    dispatch_queue_t secondStateQueue = [second valueForKey:@"tos_stateQueue"];
    dispatch_sync(secondStateQueue, ^{});
    dispatch_queue_t controllerStateQueue = [controller valueForKey:@"tos_stateQueue"];
    dispatch_sync(controllerStateQueue, ^{});
    TOSTransferAttemptResult *success = [TOSTransferAttemptResult new];
    success.value = @1;
    [[first tos_sourceSnapshot].firstObject trySetResult:success];
    [self waitForExpectations:@[nextStarted] timeout:1.0];

    [orderLock lock];
    NSString *observedNextOwner = nextOwner;
    [orderLock unlock];
    XCTAssertEqualObjects(observedNextOwner, @"second");

    XCTestExpectation *firstFinished = [self expectationWithDescription:@"first cancelled"];
    XCTestExpectation *secondFinished = [self expectationWithDescription:@"second cancelled"];
    [first.task continueWithBlock:^id(TOSTask *task) {
        [firstFinished fulfill];
        return nil;
    }];
    [second.task continueWithBlock:^id(TOSTask *task) {
        [secondFinished fulfill];
        return nil;
    }];
    [firstCancelHook cancel:NO];
    [secondCancelHook cancel:NO];
    NSError *cancelError = [NSError errorWithDomain:TOSClientErrorDomain
                                               code:TOSClientErrorCodeTaskCancelled
                                           userInfo:nil];
    for (TOSTaskCompletionSource *source in [first tos_sourceSnapshot]) {
        [source trySetError:cancelError];
    }
    for (TOSTaskCompletionSource *source in [second tos_sourceSnapshot]) {
        [source trySetError:cancelError];
    }
    [self waitForExpectations:@[firstFinished, secondFinished] timeout:1.0];
}

- (void)testTestEnvironmentAndOnlineBucketHelpers {
    NSString *name = [NSString stringWithFormat:@"TOS_TEST_%@", NSUUID.UUID.UUIDString];
    setenv(name.UTF8String, "configured-value", 1);
    @try {
        XCTAssertEqualObjects(TOSTestEnvironmentValue(name), @"configured-value");
    } @finally {
        unsetenv(name.UTF8String);
    }

    NSString *first = [TOSTestUtil randomBucketNameWithPrefix:@"sdk"
                                                   testClass:self.class];
    NSString *second = [TOSTestUtil randomBucketNameWithPrefix:@"sdk"
                                                    testClass:self.class];
    NSString *longName = [TOSTestUtil randomBucketNameWithPrefix:
                          @"SDK_PREFIX_WITH_INVALID_Characters_And_A_Very_Long_Name_That_Must_Be_Truncated"
                                                      testClass:NSString.class];
    NSRegularExpression *validBucketPattern =
        [NSRegularExpression regularExpressionWithPattern:@"^[a-z0-9](?:[a-z0-9-]{1,61}[a-z0-9])?$"
                                                  options:0
                                                    error:nil];
    for (NSString *bucket in @[first, second, longName]) {
        XCTAssertGreaterThanOrEqual(bucket.length, 3U);
        XCTAssertLessThanOrEqual(bucket.length, 63U);
        XCTAssertEqual([validBucketPattern numberOfMatchesInString:bucket
                                                           options:0
                                                             range:NSMakeRange(0, bucket.length)],
                       1U);
    }
    XCTAssertTrue([first containsString:@"tostransfercoretests"]);
    XCTAssertTrue([longName containsString:@"nsstring"]);
    XCTAssertNotEqualObjects(first, second);

    NSError *underlyingTimeout = [NSError errorWithDomain:NSURLErrorDomain
                                                      code:NSURLErrorTimedOut
                                                  userInfo:nil];
    NSError *timeout = [NSError errorWithDomain:TOSClientErrorDomain
                                           code:TOSClientErrorCodeNetworkError
                                       userInfo:@{@"OriginErrorCode": @(NSURLErrorTimedOut),
                                                  NSUnderlyingErrorKey: underlyingTimeout}];
    TOSTestCreateBucketClient *client = [TOSTestCreateBucketClient new];
    client.tos_tasks = @[[TOSTask taskWithError:timeout],
                         [TOSTask taskWithResult:[TOSCreateBucketOutput new]]];
    client.tos_headTasks =
        @[[TOSTask taskWithError:[NSError errorWithDomain:TOSServerErrorDomain
                                                   code:404
                                               userInfo:@{@"Code": @"NoSuchBucket"}]]];

    NSError *error = [TOSTestUtil createBucket:@"test-bucket" withClient:client];

    XCTAssertNil(error);
    XCTAssertEqual(client.tos_createBucketCalls, 2);
    XCTAssertEqual(client.tos_headBucketCalls, 1);
}

- (void)testCreateBucketAcceptsSuccessfulHeadAfterAmbiguousTimeout {
    NSError *timeout = [NSError errorWithDomain:TOSClientErrorDomain
                                           code:TOSClientErrorCodeNetworkError
                                       userInfo:@{@"OriginErrorCode": @(NSURLErrorTimedOut)}];
    TOSTestCreateBucketClient *client = [TOSTestCreateBucketClient new];
    client.tos_tasks = @[[TOSTask taskWithError:timeout],
                         [TOSTask taskWithResult:[TOSCreateBucketOutput new]]];
    client.tos_headTasks = @[[TOSTask taskWithResult:[TOSHeadBucketOutput new]]];

    NSError *error = [TOSTestUtil createBucket:@"test-bucket" withClient:client];

    XCTAssertNil(error);
    XCTAssertEqual(client.tos_createBucketCalls, 1);
    XCTAssertEqual(client.tos_headBucketCalls, 1);
}

- (void)testTestEnvironmentValueTreatsEmptyValueAsMissing {
    NSString *name = [NSString stringWithFormat:@"TOS_TEST_%@", NSUUID.UUID.UUIDString];
    setenv(name.UTF8String, "", 1);
    @try {
        XCTAssertNil(TOSTestEnvironmentValue(name));
    } @finally {
        unsetenv(name.UTF8String);
    }
}

- (void)testRequiredTestEnvironmentValueReportsVariableName {
    NSString *name = [NSString stringWithFormat:@"TOS_TEST_%@", NSUUID.UUID.UUIDString];
    @try {
        TOSTestRequiredEnvironmentValue(name);
        XCTFail(@"Expected a missing-variable exception");
    } @catch (NSException *exception) {
        XCTAssertEqualObjects(exception.name, NSInvalidArgumentException);
        XCTAssertTrue([exception.reason containsString:name]);
    }
}

- (void)testCancelHookAcceptsOnlyFirstMode {
    TOSCancelHook *hook = [TOSCancelHook new];
    __block NSInteger calls = 0;
    __block BOOL abort = NO;
    [hook tos_bindHandler:^(BOOL value) {
        calls += 1;
        abort = value;
    }];

    [hook cancel:YES];
    [hook cancel:NO];

    XCTAssertEqual(calls, 1);
    XCTAssertTrue(abort);
    XCTAssertTrue(hook.tos_isCancelled);
    XCTAssertTrue(hook.tos_shouldAbort);
}

- (void)testCancelBeforeBindIsDeliveredOnce {
    TOSCancelHook *hook = [TOSCancelHook new];
    [hook cancel:NO];
    __block NSInteger calls = 0;
    [hook tos_bindHandler:^(BOOL isAbort) {
        calls += 1;
        XCTAssertFalse(isAbort);
    }];
    [hook tos_bindHandler:^(BOOL isAbort) {
        calls += 1;
    }];

    XCTAssertEqual(calls, 1);
    XCTAssertTrue(hook.tos_isCancelled);
    XCTAssertFalse(hook.tos_shouldAbort);
}

- (void)testConcurrentCancelInvokesHandlerOnce {
    TOSCancelHook *hook = [TOSCancelHook new];
    NSObject *guard = [NSObject new];
    __block NSInteger calls = 0;
    [hook tos_bindHandler:^(BOOL isAbort) {
        @synchronized (guard) {
            calls += 1;
        }
    }];

    dispatch_group_t group = dispatch_group_create();
    for (NSInteger index = 0; index < 100; index++) {
        dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [hook cancel:(index % 2 == 0)];
        });
    }
    XCTAssertEqual(dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)), 0);

    @synchronized (guard) {
        XCTAssertEqual(calls, 1);
    }
}

- (void)testRateLimiterRejectsInvalidConfiguration {
    XCTAssertNil([[TOSDefaultRateLimiter alloc] initWithCapacity:10239 rate:1024]);
    XCTAssertNil([[TOSDefaultRateLimiter alloc] initWithCapacity:10240 rate:1023]);
}

- (void)testRateLimiterConsumesAndRefillsWithMonotonicClock {
    __block NSTimeInterval now = 10;
    TOSDefaultRateLimiter *limiter = [[TOSDefaultRateLimiter alloc] initWithCapacity:10240
                                                                               rate:1024
                                                                              clock:^NSTimeInterval{
        return now;
    }];
    NSTimeInterval wait = 0;
    XCTAssertTrue([limiter acquire:10240 timeToWait:&wait]);
    XCTAssertEqualWithAccuracy(wait, 0, 0.0001);
    XCTAssertFalse([limiter acquire:1024 timeToWait:&wait]);
    XCTAssertEqualWithAccuracy(wait, 1, 0.0001);

    now += 0.5;
    XCTAssertFalse([limiter acquire:1024 timeToWait:&wait]);
    XCTAssertEqualWithAccuracy(wait, 0.5, 0.0001);

    now += 0.5;
    XCTAssertTrue([limiter acquire:1024 timeToWait:&wait]);
    XCTAssertEqualWithAccuracy(wait, 0, 0.0001);
}

- (void)testRateLimiterConcurrentAcquireNeverOverspendsCapacity {
    TOSDefaultRateLimiter *limiter = [[TOSDefaultRateLimiter alloc] initWithCapacity:10240
                                                                               rate:1024
                                                                              clock:^NSTimeInterval{
        return 1;
    }];
    NSObject *guard = [NSObject new];
    __block NSInteger successes = 0;
    dispatch_group_t group = dispatch_group_create();
    for (NSInteger index = 0; index < 40; index++) {
        dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSTimeInterval wait = 0;
            if ([limiter acquire:1024 timeToWait:&wait]) {
                @synchronized (guard) {
                    successes += 1;
                }
            }
        });
    }
    XCTAssertEqual(dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)), 0);

    @synchronized (guard) {
        XCTAssertEqual(successes, 10);
    }
}

- (void)testProgressIsMonotonicAndFlushesBeforeSuccess {
    NSMutableArray<TOSDataTransferStatus *> *statuses = [NSMutableArray array];
    TOSTransferProgress *progress = [[TOSTransferProgress alloc] initWithListener:^(TOSDataTransferStatus *status) {
        [statuses addObject:status];
    }];

    [progress startWithTotal:100 consumed:10];
    [progress recordBytes:20];
    [progress recordBytes:30];
    [progress finish];
    [progress waitUntilIdle];

    XCTAssertEqual(statuses.count, 3);
    XCTAssertEqual(statuses[0].tosType, TOSDataTransferStarted);
    XCTAssertEqual(statuses[0].tosConsumedBytes, 10);
    XCTAssertEqual(statuses[1].tosType, TOSDataTransferRW);
    XCTAssertEqual(statuses[1].tosRWOnceBytes, 50);
    XCTAssertEqual(statuses[1].tosConsumedBytes, 60);
    XCTAssertEqual(statuses[2].tosType, TOSDataTransferSucceed);
    XCTAssertEqual(statuses[2].tosConsumedBytes, 60);
    XCTAssertEqual(statuses[2].tosRetryCount, -1);
}

- (void)testProgressNeverExceedsDeclaredTotal {
    NSMutableArray<TOSDataTransferStatus *> *statuses = [NSMutableArray array];
    TOSTransferProgress *progress = [[TOSTransferProgress alloc] initWithListener:^(TOSDataTransferStatus *status) {
        [statuses addObject:status];
    }];

    [progress startWithTotal:100 consumed:90];
    [progress recordBytes:20];
    [progress finish];
    [progress waitUntilIdle];

    for (TOSDataTransferStatus *status in statuses) {
        XCTAssertLessThanOrEqual(status.tosConsumedBytes, status.tosTotalBytes);
    }
    XCTAssertEqual(statuses[1].tosRWOnceBytes, 10);
    XCTAssertEqual(statuses.lastObject.tosConsumedBytes, 100);
}

- (void)testRetryAfterParserSupportsDeltaSecondsAndHTTPDate {
    NSHTTPURLResponse *secondsResponse =
        TOSTestHTTPResponse(429, @{@"rEtRy-AfTeR": @"7"});
    XCTAssertEqualWithAccuracy(TOSTransferRetryAfterDelayForResponse(secondsResponse), 7, 0.001);

    NSDate *futureDate = [NSDate dateWithTimeIntervalSinceNow:120];
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    formatter.dateFormat = @"EEE',' dd MMM yyyy HH':'mm':'ss z";
    NSHTTPURLResponse *dateResponse =
        TOSTestHTTPResponse(503, @{@"Retry-After": [formatter stringFromDate:futureDate]});
    NSTimeInterval dateDelay = TOSTransferRetryAfterDelayForResponse(dateResponse);
    XCTAssertGreaterThan(dateDelay, 118);
    XCTAssertLessThanOrEqual(dateDelay, 120);

    NSHTTPURLResponse *invalidResponse =
        TOSTestHTTPResponse(503, @{@"Retry-After": @"later"});
    XCTAssertEqual(TOSTransferRetryAfterDelayForResponse(invalidResponse), 0);
    XCTAssertEqual(TOSTransferRetryAfterDelayForResponse(TOSTestHTTPResponse(503, @{})), 0);
    XCTAssertEqual(TOSTransferRetryAfterDelayForResponse(nil), 0);
}

- (void)testRetryAfterObserverStoresResponseMetadata {
    TOSTransferResponseMetadata *metadata = [TOSTransferResponseMetadata new];
    TOSTransferResponseObserver observer = TOSTransferRetryAfterObserver(metadata);

    observer(TOSTestHTTPResponse(429, @{@"Retry-After": @"11"}));

    XCTAssertEqualWithAccuracy(metadata.retryAfter, 11, 0.001);
}

- (void)testProgressEmitsOnlyOneTerminalStatusUnderRace {
    __block NSInteger terminalCount = 0;
    TOSTransferProgress *progress = [[TOSTransferProgress alloc] initWithListener:^(TOSDataTransferStatus *status) {
        if (status.tosType == TOSDataTransferSucceed || status.tosType == TOSDataTransferFailed) {
            terminalCount += 1;
        }
    }];
    [progress startWithTotal:1 consumed:0];

    dispatch_group_t group = dispatch_group_create();
    for (NSInteger index = 0; index < 100; index++) {
        dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            if (index % 2 == 0) {
                [progress finish];
            } else {
                [progress fail];
            }
        });
    }
    XCTAssertEqual(dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)), 0);
    [progress waitUntilIdle];

    XCTAssertEqual(terminalCount, 1);
}

- (void)testPartPlanningHandlesZeroAndExactSizes {
    NSError *error = nil;
    NSArray<TOSTransferPart *> *upload = TOSUploadParts(0, 5, &error);
    XCTAssertNil(error);
    XCTAssertEqual(upload.count, 1);
    XCTAssertEqual(upload[0].tos_partNumber, 1);
    XCTAssertEqual(upload[0].tos_size, 0);
    XCTAssertEqual(upload[0].tos_offset, 0);
    XCTAssertTrue(upload[0].tos_zeroSize);

    NSArray<TOSTransferPart *> *download = TOSDownloadParts(0, 5, &error);
    XCTAssertNil(error);
    XCTAssertEqual(download.count, 0);

    NSArray<TOSTransferPart *> *copy = TOSCopyParts(0, 5, &error);
    XCTAssertNil(error);
    XCTAssertEqual(copy.count, 1);
    XCTAssertTrue(copy[0].tos_zeroSize);

    upload = TOSUploadParts(10, 5, &error);
    XCTAssertEqual(upload.count, 2);
    XCTAssertEqual(upload[0].tos_offset, 0);
    XCTAssertEqual(upload[0].tos_size, 5);
    XCTAssertEqual(upload[1].tos_offset, 5);
    XCTAssertEqual(upload[1].tos_size, 5);
}

- (void)testPartPlanningCreatesContiguousTailRanges {
    NSError *error = nil;
    NSArray<TOSTransferPart *> *download = TOSDownloadParts(12, 5, &error);
    XCTAssertNil(error);
    XCTAssertEqual(download.count, 3);

    int64_t nextOffset = 0;
    for (NSInteger index = 0; index < download.count; index++) {
        TOSTransferPart *part = download[index];
        XCTAssertEqual(part.tos_partNumber, index + 1);
        XCTAssertEqual(part.tos_rangeStart, nextOffset);
        XCTAssertEqual(part.tos_rangeEnd - part.tos_rangeStart + 1, part.tos_size);
        nextOffset = part.tos_rangeEnd + 1;
    }
    XCTAssertEqual(nextOffset, 12);
    XCTAssertEqual(download.lastObject.tos_size, 2);

    NSArray<TOSTransferPart *> *copy = TOSCopyParts(12, 5, &error);
    XCTAssertEqual(copy.count, 3);
    XCTAssertEqual(copy.lastObject.tos_rangeStart, 10);
    XCTAssertEqual(copy.lastObject.tos_rangeEnd, 11);
}

- (void)testPartPlanningEnforcesTenThousandPartLimit {
    NSError *error = nil;
    NSArray<TOSTransferPart *> *parts = TOSUploadParts(50000, 5, &error);
    XCTAssertNil(error);
    XCTAssertEqual(parts.count, 10000);

    error = nil;
    parts = TOSUploadParts(50001, 5, &error);
    XCTAssertNil(parts);
    XCTAssertNotNil(error);

    error = nil;
    parts = TOSDownloadParts(-1, 5, &error);
    XCTAssertNil(parts);
    XCTAssertNotNil(error);

    error = nil;
    parts = TOSCopyParts(1, 0, &error);
    XCTAssertNil(parts);
    XCTAssertNotNil(error);
}

- (void)testCheckpointPathUsesSafeDeterministicNames {
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *source = [root stringByAppendingPathComponent:@"data.bin"];
    NSString *download = [root stringByAppendingPathComponent:@"download.bin"];
    NSError *error = nil;

    NSString *uploadPath = TOSUploadCheckpointPath(nil, source, @"bucket", @"key", &error);
    XCTAssertNil(error);
    XCTAssertEqualObjects(uploadPath, [root stringByAppendingPathComponent:@"data.bin.h2b7UGewt6QmZ-ZmS-710w.upload.v2"]);

    NSString *downloadPath = TOSDownloadCheckpointPath(nil, download, @"bucket", @"key", @"version", &error);
    XCTAssertNil(error);
    XCTAssertEqualObjects(downloadPath, [root stringByAppendingPathComponent:@"download.bin.FWf4fmhYda6ppnhWkxxttg.download"]);

    NSString *copyPath = TOSCopyCheckpointPath(nil,
                                               @"src-bucket",
                                               @"src/key",
                                               @"v1",
                                               @"dst-bucket",
                                               @"dst/key",
                                               &error);
    XCTAssertNil(error);
    XCTAssertEqualObjects(copyPath.lastPathComponent, @"tos-copy.mOMk2fgBxiWNkIeQGcpqDg.copy");
    XCTAssertEqualObjects(copyPath.stringByDeletingLastPathComponent.stringByStandardizingPath,
                          NSTemporaryDirectory().stringByStandardizingPath);
}

- (void)testCheckpointPathSupportsDirectoryAndCustomFile {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *directory = [root stringByAppendingPathComponent:@"checkpoints"];
    XCTAssertTrue([fileManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]);
    NSError *error = nil;

    NSString *directoryPath = TOSUploadCheckpointPath(directory,
                                                      [root stringByAppendingPathComponent:@"data.bin"],
                                                      @"bucket",
                                                      @"key",
                                                      &error);
    XCTAssertNil(error);
    XCTAssertEqualObjects(directoryPath,
                          [directory stringByAppendingPathComponent:@"data.bin.h2b7UGewt6QmZ-ZmS-710w.upload.v2"]);

    NSString *custom = [directory stringByAppendingPathComponent:@"custom.checkpoint"];
    NSString *customPath = TOSDownloadCheckpointPath(custom,
                                                     [root stringByAppendingPathComponent:@"download.bin"],
                                                     @"bucket",
                                                     @"key",
                                                     nil,
                                                     &error);
    XCTAssertNil(error);
    XCTAssertEqualObjects(customPath, custom.stringByStandardizingPath);
    [fileManager removeItemAtPath:root error:nil];
}

- (void)testCheckpointPathRejectsTraversalAndSymlinkTarget {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTAssertTrue([fileManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil]);
    NSError *error = nil;

    NSString *traversal = [root stringByAppendingPathComponent:@"../escape.checkpoint"];
    XCTAssertNil(TOSUploadCheckpointPath(traversal,
                                         [root stringByAppendingPathComponent:@"data.bin"],
                                         @"bucket",
                                         @"key",
                                         &error));
    XCTAssertNotNil(error);

    NSString *realPath = [root stringByAppendingPathComponent:@"real.checkpoint"];
    XCTAssertTrue([@"content" writeToFile:realPath atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    NSString *linkPath = [root stringByAppendingPathComponent:@"link.checkpoint"];
    XCTAssertTrue([fileManager createSymbolicLinkAtPath:linkPath withDestinationPath:realPath error:nil]);
    error = nil;
    XCTAssertNil(TOSDownloadCheckpointPath(linkPath,
                                           [root stringByAppendingPathComponent:@"download.bin"],
                                           @"bucket",
                                           @"key",
                                           nil,
                                           &error));
    XCTAssertNotNil(error);
    [fileManager removeItemAtPath:root error:nil];
}

- (void)testCheckpointJSONRoundTripsAllOperations {
    NSError *error = nil;
    TOSUploadCheckpointV2 *upload = [TOSUploadCheckpointV2 tos_checkpointWithData:TOSTestJSONData(TOSTestUploadCheckpointFixture())
                                                                    checkpointPath:@"/tmp/upload.checkpoint"
                                                                               error:&error];
    XCTAssertNotNil(upload);
    XCTAssertNil(error);
    XCTAssertEqualObjects(upload.tos_uploadID, @"upload-id");
    XCTAssertEqualObjects(upload.tos_encodingType, @"url");
    XCTAssertEqual(upload.tos_parts.count, 2);
    XCTAssertTrue(upload.tos_parts[0].tos_completed);

    NSData *roundTrip = TOSTestJSONData(upload.tos_dictionaryRepresentation);
    TOSUploadCheckpointV2 *uploadAgain = [TOSUploadCheckpointV2 tos_checkpointWithData:roundTrip
                                                                          checkpointPath:@"/tmp/upload.checkpoint"
                                                                                     error:&error];
    XCTAssertNotNil(uploadAgain);
    XCTAssertEqualObjects(uploadAgain.tos_dictionaryRepresentation, upload.tos_dictionaryRepresentation);

    TOSDownloadCheckpoint *download = [TOSDownloadCheckpoint tos_checkpointWithData:TOSTestJSONData(TOSTestDownloadCheckpointFixture())
                                                                      checkpointPath:@"/tmp/download.checkpoint"
                                                                                 error:&error];
    XCTAssertNotNil(download);
    XCTAssertNil(error);
    XCTAssertEqual(download.tos_objectCRC64, UINT64_MAX);
    XCTAssertTrue(download.tos_hasTempFileIdentity);
    XCTAssertEqual(download.tos_tempFileDevice, (uint64_t)123);
    XCTAssertEqual(download.tos_tempFileInode, (uint64_t)456);
    XCTAssertEqualObjects(download.tos_dictionaryRepresentation[@"temp_file_device"], @"123");
    XCTAssertEqualObjects(download.tos_dictionaryRepresentation[@"temp_file_inode"], @"456");

    TOSCopyCheckpoint *copy = [TOSCopyCheckpoint tos_checkpointWithData:TOSTestJSONData(TOSTestCopyCheckpointFixture())
                                                          checkpointPath:@"/tmp/copy.checkpoint"
                                                                     error:&error];
    XCTAssertNotNil(copy);
    XCTAssertNil(error);
    XCTAssertEqual(copy.tos_sourceCRC64, UINT64_MAX);
    XCTAssertEqualObjects(copy.tos_encodingType, @"url");
}

- (void)testDownloadCheckpointAcceptsLegacyMissingTempIdentityButRejectsPartialOrInvalidIdentity {
    NSMutableDictionary *fixture = TOSTestMutableJSONCopy(TOSTestDownloadCheckpointFixture());
    [fixture removeObjectForKey:@"temp_file_device"];
    [fixture removeObjectForKey:@"temp_file_inode"];
    NSError *error = nil;
    TOSDownloadCheckpoint *legacy =
        [TOSDownloadCheckpoint tos_checkpointWithData:TOSTestJSONData(fixture)
                                       checkpointPath:@"/tmp/checkpoint"
                                                error:&error];
    XCTAssertNotNil(legacy);
    XCTAssertNil(error);
    XCTAssertFalse(legacy.tos_hasTempFileIdentity);

    fixture = TOSTestMutableJSONCopy(TOSTestDownloadCheckpointFixture());
    [fixture removeObjectForKey:@"temp_file_inode"];
    error = nil;
    XCTAssertNil([TOSDownloadCheckpoint tos_checkpointWithData:TOSTestJSONData(fixture)
                                                checkpointPath:@"/tmp/checkpoint"
                                                         error:&error]);
    XCTAssertNotNil(error);

    fixture = TOSTestMutableJSONCopy(TOSTestDownloadCheckpointFixture());
    fixture[@"temp_file_inode"] = @"0";
    error = nil;
    XCTAssertNil([TOSDownloadCheckpoint tos_checkpointWithData:TOSTestJSONData(fixture)
                                                checkpointPath:@"/tmp/checkpoint"
                                                         error:&error]);
    XCTAssertNotNil(error);
}

- (void)testCheckpointJSONRejectsWrongSchemaOperationAndScalarTypes {
    NSError *error = nil;
    NSMutableDictionary *fixture = TOSTestMutableJSONCopy(TOSTestUploadCheckpointFixture());
    fixture[@"schema_version"] = @2;
    XCTAssertNil([TOSUploadCheckpointV2 tos_checkpointWithData:TOSTestJSONData(fixture)
                                                 checkpointPath:@"/tmp/checkpoint"
                                                            error:&error]);
    XCTAssertNotNil(error);

    fixture = TOSTestMutableJSONCopy(TOSTestUploadCheckpointFixture());
    fixture[@"operation"] = @"download";
    error = nil;
    XCTAssertNil([TOSUploadCheckpointV2 tos_checkpointWithData:TOSTestJSONData(fixture)
                                                 checkpointPath:@"/tmp/checkpoint"
                                                            error:&error]);
    XCTAssertNotNil(error);

    fixture = TOSTestMutableJSONCopy(TOSTestUploadCheckpointFixture());
    fixture[@"part_size"] = @"5";
    error = nil;
    XCTAssertNil([TOSUploadCheckpointV2 tos_checkpointWithData:TOSTestJSONData(fixture)
                                                 checkpointPath:@"/tmp/checkpoint"
                                                            error:&error]);
    XCTAssertNotNil(error);

    fixture = TOSTestMutableJSONCopy(TOSTestUploadCheckpointFixture());
    fixture[@"file_size"] = @YES;
    error = nil;
    XCTAssertNil([TOSUploadCheckpointV2 tos_checkpointWithData:TOSTestJSONData(fixture)
                                                 checkpointPath:@"/tmp/checkpoint"
                                                            error:&error]);
    XCTAssertNotNil(error);
}

- (void)testCheckpointJSONRejectsInvalidPartRecords {
    NSError *error = nil;
    NSMutableDictionary *fixture = TOSTestMutableJSONCopy(TOSTestUploadCheckpointFixture());
    NSMutableArray *parts = fixture[@"parts"];
    parts[1][@"part_number"] = @1;
    XCTAssertNil([TOSUploadCheckpointV2 tos_checkpointWithData:TOSTestJSONData(fixture)
                                                 checkpointPath:@"/tmp/checkpoint"
                                                            error:&error]);

    fixture = TOSTestMutableJSONCopy(TOSTestUploadCheckpointFixture());
    parts = fixture[@"parts"];
    parts[1][@"offset"] = @4;
    parts[1][@"range_start"] = @4;
    error = nil;
    XCTAssertNil([TOSUploadCheckpointV2 tos_checkpointWithData:TOSTestJSONData(fixture)
                                                 checkpointPath:@"/tmp/checkpoint"
                                                            error:&error]);

    fixture = TOSTestMutableJSONCopy(TOSTestUploadCheckpointFixture());
    parts = fixture[@"parts"];
    parts[0][@"etag"] = @"";
    error = nil;
    XCTAssertNil([TOSUploadCheckpointV2 tos_checkpointWithData:TOSTestJSONData(fixture)
                                                 checkpointPath:@"/tmp/checkpoint"
                                                            error:&error]);
    XCTAssertNotNil(error);
}

- (void)testCheckpointJSONRejectsCorruptAndMissingFieldsButAllowsUnknownFields {
    NSError *error = nil;
    NSData *truncated = [@"{\"schema_version\":1" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertNil([TOSUploadCheckpointV2 tos_checkpointWithData:truncated
                                                 checkpointPath:@"/tmp/checkpoint"
                                                            error:&error]);
    XCTAssertNotNil(error);

    NSMutableDictionary *fixture = TOSTestMutableJSONCopy(TOSTestUploadCheckpointFixture());
    [fixture removeObjectForKey:@"bucket"];
    error = nil;
    XCTAssertNil([TOSUploadCheckpointV2 tos_checkpointWithData:TOSTestJSONData(fixture)
                                                 checkpointPath:@"/tmp/checkpoint"
                                                            error:&error]);
    XCTAssertNotNil(error);

    fixture = TOSTestMutableJSONCopy(TOSTestUploadCheckpointFixture());
    fixture[@"future_optional_field"] = @{ @"value": @1 };
    error = nil;
    XCTAssertNotNil([TOSUploadCheckpointV2 tos_checkpointWithData:TOSTestJSONData(fixture)
                                                    checkpointPath:@"/tmp/checkpoint"
                                                               error:&error]);
    XCTAssertNil(error);

    fixture = TOSTestMutableJSONCopy(TOSTestUploadCheckpointFixture());
    fixture[@"parts"][0][@"crc64"] = @"18446744073709551616";
    error = nil;
    XCTAssertNil([TOSUploadCheckpointV2 tos_checkpointWithData:TOSTestJSONData(fixture)
                                                 checkpointPath:@"/tmp/checkpoint"
                                                            error:&error]);
    XCTAssertNotNil(error);
}

- (void)testCheckpointInvalidDataCanBeRejectedWithoutErrorPointer {
    NSMutableDictionary *upload = TOSTestMutableJSONCopy(TOSTestUploadCheckpointFixture());
    upload[@"upload_id"] = @"";
    XCTAssertNil([TOSUploadCheckpointV2 tos_checkpointWithData:TOSTestJSONData(upload)
                                               checkpointPath:@"/tmp/checkpoint"
                                                          error:nil]);

    NSMutableDictionary *download = TOSTestMutableJSONCopy(TOSTestDownloadCheckpointFixture());
    download[@"file_path"] = NSNull.null;
    XCTAssertNil([TOSDownloadCheckpoint tos_checkpointWithData:TOSTestJSONData(download)
                                               checkpointPath:@"/tmp/checkpoint"
                                                          error:nil]);

    NSMutableDictionary *copy = TOSTestMutableJSONCopy(TOSTestCopyCheckpointFixture());
    copy[@"upload_id"] = @"";
    XCTAssertNil([TOSCopyCheckpoint tos_checkpointWithData:TOSTestJSONData(copy)
                                           checkpointPath:@"/tmp/checkpoint"
                                                      error:nil]);
}

- (void)testUploadCheckpointValidatesRequestAndFileIdentity {
    TOSUploadCheckpointV2 *checkpoint = [TOSUploadCheckpointV2 tos_checkpointWithData:TOSTestJSONData(TOSTestUploadCheckpointFixture())
                                                                         checkpointPath:@"/tmp/checkpoint"
                                                                                    error:nil];
    XCTAssertTrue([checkpoint tos_validateForBucket:@"bucket"
                                               key:@"key"
                                          partSize:5
                                      encodingType:@"url"
                                          filePath:@"/tmp/source.bin"
                                          fileSize:10
                                  fileModifiedTime:123456
                                             error:nil]);
    XCTAssertFalse([checkpoint tos_validateForBucket:@"other"
                                                key:@"key"
                                           partSize:5
                                       encodingType:@"url"
                                           filePath:@"/tmp/source.bin"
                                           fileSize:10
                                   fileModifiedTime:123456
                                              error:nil]);
    XCTAssertFalse([checkpoint tos_validateForBucket:@"bucket"
                                                key:@"key"
                                           partSize:5
                                       encodingType:@"url"
                                           filePath:@"/tmp/other.bin"
                                           fileSize:10
                                   fileModifiedTime:123456
                                              error:nil]);
    XCTAssertFalse([checkpoint tos_validateForBucket:@"bucket"
                                                key:@"key"
                                           partSize:5
                                       encodingType:@"url"
                                           filePath:@"/tmp/source.bin"
                                           fileSize:11
                                   fileModifiedTime:123456
                                              error:nil]);
    XCTAssertFalse([checkpoint tos_validateForBucket:@"bucket"
                                                key:@"key"
                                           partSize:5
                                       encodingType:@"url"
                                           filePath:@"/tmp/source.bin"
                                           fileSize:10
                                   fileModifiedTime:123457
                                              error:nil]);
}

- (void)testDownloadCheckpointValidatesRemoteAndTemporaryFileIdentity {
    TOSDownloadCheckpoint *checkpoint = [TOSDownloadCheckpoint tos_checkpointWithData:TOSTestJSONData(TOSTestDownloadCheckpointFixture())
                                                                         checkpointPath:@"/tmp/checkpoint"
                                                                                    error:nil];
    XCTAssertTrue([checkpoint tos_validateForBucket:@"bucket"
                                               key:@"key"
                                         versionID:@"version"
                                          partSize:5
                                          filePath:@"/tmp/destination.bin"
                                      tempFilePath:@"/tmp/destination.bin.temp"
                                           ifMatch:@"condition-etag"
                                   ifModifiedSince:100
                                       ifNoneMatch:@"none"
                                 ifUnmodifiedSince:200
                                        objectETag:@"object-etag"
                                objectLastModified:300
                                        objectSize:10
                                       objectCRC64:UINT64_MAX
                                actualTempFileSize:10
                                             error:nil]);
    XCTAssertFalse([checkpoint tos_validateForBucket:@"bucket"
                                                key:@"key"
                                          versionID:@"other"
                                           partSize:5
                                           filePath:@"/tmp/destination.bin"
                                       tempFilePath:@"/tmp/destination.bin.temp"
                                            ifMatch:@"condition-etag"
                                    ifModifiedSince:100
                                        ifNoneMatch:@"none"
                                  ifUnmodifiedSince:200
                                         objectETag:@"object-etag"
                                 objectLastModified:300
                                         objectSize:10
                                        objectCRC64:UINT64_MAX
                                 actualTempFileSize:10
                                              error:nil]);
    XCTAssertFalse([checkpoint tos_validateForBucket:@"bucket"
                                                key:@"key"
                                          versionID:@"version"
                                           partSize:5
                                           filePath:@"/tmp/destination.bin"
                                       tempFilePath:@"/tmp/destination.bin.temp"
                                            ifMatch:@"condition-etag"
                                    ifModifiedSince:100
                                        ifNoneMatch:@"none"
                                  ifUnmodifiedSince:200
                                         objectETag:@"changed"
                                 objectLastModified:300
                                         objectSize:10
                                        objectCRC64:UINT64_MAX
                                 actualTempFileSize:10
                                              error:nil]);
    XCTAssertFalse([checkpoint tos_validateForBucket:@"bucket"
                                                key:@"key"
                                          versionID:@"version"
                                           partSize:5
                                           filePath:@"/tmp/destination.bin"
                                       tempFilePath:@"/tmp/destination.bin.temp"
                                            ifMatch:@"condition-etag"
                                    ifModifiedSince:100
                                        ifNoneMatch:@"none"
                                  ifUnmodifiedSince:200
                                         objectETag:@"object-etag"
                                 objectLastModified:300
                                         objectSize:10
                                        objectCRC64:UINT64_MAX
                                 actualTempFileSize:9
                                              error:nil]);
    XCTAssertFalse([checkpoint tos_validateForBucket:@"bucket"
                                                key:@"key"
                                          versionID:@"version"
                                           partSize:5
                                           filePath:@"/tmp/destination.bin"
                                       tempFilePath:@"/tmp/destination.bin.temp"
                                            ifMatch:@"changed-condition"
                                    ifModifiedSince:100
                                        ifNoneMatch:@"none"
                                  ifUnmodifiedSince:200
                                         objectETag:@"object-etag"
                                 objectLastModified:300
                                         objectSize:10
                                        objectCRC64:UINT64_MAX
                                 actualTempFileSize:10
                                              error:nil]);
}

- (void)testCopyCheckpointValidatesSourceAndDestinationIdentity {
    TOSCopyCheckpoint *checkpoint = [TOSCopyCheckpoint tos_checkpointWithData:TOSTestJSONData(TOSTestCopyCheckpointFixture())
                                                             checkpointPath:@"/tmp/checkpoint"
                                                                        error:nil];
    XCTAssertTrue([checkpoint tos_validateForSourceBucket:@"src-bucket"
                                                sourceKey:@"src-key"
                                          sourceVersionID:@"src-version"
                                                   bucket:@"dst-bucket"
                                                      key:@"dst-key"
                                                 partSize:5
                                             encodingType:@"url"
                                      copySourceIfMatch:@"condition-etag"
                              copySourceIfModifiedSince:100
                                  copySourceIfNoneMatch:@"none"
                            copySourceIfUnmodifiedSince:200
                                               sourceETag:@"source-etag"
                                       sourceLastModified:300
                                               sourceSize:10
                                              sourceCRC64:UINT64_MAX
                                                    error:nil]);
    XCTAssertFalse([checkpoint tos_validateForSourceBucket:@"src-bucket"
                                                 sourceKey:@"src-key"
                                           sourceVersionID:@"src-version"
                                                    bucket:@"dst-bucket"
                                                       key:@"other"
                                                  partSize:5
                                              encodingType:@"url"
                                       copySourceIfMatch:@"condition-etag"
                               copySourceIfModifiedSince:100
                                   copySourceIfNoneMatch:@"none"
                             copySourceIfUnmodifiedSince:200
                                                sourceETag:@"source-etag"
                                        sourceLastModified:300
                                                sourceSize:10
                                               sourceCRC64:UINT64_MAX
                                                     error:nil]);
    XCTAssertFalse([checkpoint tos_validateForSourceBucket:@"src-bucket"
                                                 sourceKey:@"src-key"
                                           sourceVersionID:@"src-version"
                                                    bucket:@"dst-bucket"
                                                       key:@"dst-key"
                                                  partSize:5
                                              encodingType:@"url"
                                       copySourceIfMatch:@"condition-etag"
                               copySourceIfModifiedSince:100
                                   copySourceIfNoneMatch:@"none"
                             copySourceIfUnmodifiedSince:200
                                                sourceETag:@"source-etag"
                                        sourceLastModified:301
                                                sourceSize:10
                                               sourceCRC64:UINT64_MAX
                                                     error:nil]);
    XCTAssertFalse([checkpoint tos_validateForSourceBucket:@"src-bucket"
                                                 sourceKey:@"src-key"
                                           sourceVersionID:@"src-version"
                                                    bucket:@"dst-bucket"
                                                       key:@"dst-key"
                                                  partSize:5
                                              encodingType:@"changed"
                                       copySourceIfMatch:@"condition-etag"
                               copySourceIfModifiedSince:100
                                   copySourceIfNoneMatch:@"none"
                             copySourceIfUnmodifiedSince:200
                                                sourceETag:@"source-etag"
                                        sourceLastModified:300
                                                sourceSize:10
                                               sourceCRC64:UINT64_MAX
                                                     error:nil]);
}

- (void)testCheckpointStoreWritesAtomicallyWithPrivatePermissions {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *path = [root stringByAppendingPathComponent:@"upload.checkpoint"];
    TOSUploadCheckpointV2 *checkpoint = [TOSUploadCheckpointV2 tos_checkpointWithData:TOSTestJSONData(TOSTestUploadCheckpointFixture())
                                                                         checkpointPath:path
                                                                                    error:nil];
    TOSTransferCheckpointStore *store = [TOSTransferCheckpointStore new];
    NSError *error = nil;
    XCTAssertTrue([store writeCheckpoint:checkpoint error:&error]);
    XCTAssertNil(error);

    NSData *data = [NSData dataWithContentsOfFile:path];
    XCTAssertNotNil([TOSUploadCheckpointV2 tos_checkpointWithData:data checkpointPath:path error:nil]);
    NSDictionary *attributes = [fileManager attributesOfItemAtPath:path error:nil];
    XCTAssertEqual([attributes[NSFilePosixPermissions] unsignedShortValue] & 0777, 0600);
    NSPredicate *temporaryPredicate = [NSPredicate predicateWithBlock:^BOOL(NSString *name, NSDictionary *bindings) {
        return [name containsString:@".tmp."];
    }];
    XCTAssertEqual([[fileManager contentsOfDirectoryAtPath:root error:nil] filteredArrayUsingPredicate:temporaryPredicate].count, 0);
    [fileManager removeItemAtPath:root error:nil];
}

- (void)testCheckpointStorePreservesOriginalAcrossInjectedFailures {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTAssertTrue([fileManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil]);
    NSString *path = [root stringByAppendingPathComponent:@"upload.checkpoint"];
    NSData *original = TOSTestJSONData(TOSTestUploadCheckpointFixture());
    TOSUploadCheckpointV2 *checkpoint = [TOSUploadCheckpointV2 tos_checkpointWithData:original
                                                                         checkpointPath:path
                                                                                    error:nil];
    checkpoint.tos_uploadID = @"changed-upload-id";

    NSArray<NSNumber *> *stages = @[@(TOSTestCheckpointFailureWrite),
                                    @(TOSTestCheckpointFailurePermissions),
                                    @(TOSTestCheckpointFailureReplace)];
    for (NSNumber *stage in stages) {
        XCTAssertTrue([original writeToFile:path atomically:YES]);
        TOSTestCheckpointFileSystem *fileSystem = [TOSTestCheckpointFileSystem new];
        fileSystem.failureStage = stage.integerValue;
        TOSTransferCheckpointStore *store = [[TOSTransferCheckpointStore alloc] initWithFileSystem:fileSystem];
        NSError *error = nil;
        XCTAssertFalse([store writeCheckpoint:checkpoint error:&error]);
        XCTAssertNotNil(error);
        XCTAssertEqualObjects([NSData dataWithContentsOfFile:path], original);
        NSPredicate *temporaryPredicate = [NSPredicate predicateWithBlock:^BOOL(NSString *name, NSDictionary *bindings) {
            return [name containsString:@".tmp."];
        }];
        XCTAssertEqual([[fileManager contentsOfDirectoryAtPath:root error:nil] filteredArrayUsingPredicate:temporaryPredicate].count, 0);
    }
    [fileManager removeItemAtPath:root error:nil];
}

- (void)testCheckpointStorePropagatesDirectoryCreationFailure {
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *path = [root stringByAppendingPathComponent:@"nested/upload.checkpoint"];
    TOSUploadCheckpointV2 *checkpoint = [TOSUploadCheckpointV2 tos_checkpointWithData:TOSTestJSONData(TOSTestUploadCheckpointFixture())
                                                                         checkpointPath:path
                                                                                    error:nil];
    TOSTestCheckpointFileSystem *fileSystem = [TOSTestCheckpointFileSystem new];
    fileSystem.failureStage = TOSTestCheckpointFailureCreateDirectory;
    TOSTransferCheckpointStore *store = [[TOSTransferCheckpointStore alloc] initWithFileSystem:fileSystem];
    NSError *error = nil;
    XCTAssertFalse([store writeCheckpoint:checkpoint error:&error]);
    XCTAssertNotNil(error);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:root]);
}

- (void)testCheckpointStoreDoesNotOverwriteLegacyOrCorruptFiles {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTAssertTrue([fileManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil]);
    NSString *path = [root stringByAppendingPathComponent:@"legacy.checkpoint"];
    NSData *legacy = [@"legacy-binary-checkpoint" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertTrue([legacy writeToFile:path atomically:YES]);
    TOSUploadCheckpointV2 *checkpoint = [TOSUploadCheckpointV2 tos_checkpointWithData:TOSTestJSONData(TOSTestUploadCheckpointFixture())
                                                                         checkpointPath:path
                                                                                    error:nil];
    NSError *error = nil;
    XCTAssertFalse([[TOSTransferCheckpointStore new] writeCheckpoint:checkpoint error:&error]);
    XCTAssertNotNil(error);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:path], legacy);
    [fileManager removeItemAtPath:root error:nil];
}

- (void)testCheckpointStoreRejectsNonStringOperationWithoutThrowingOnWrite {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTAssertTrue([fileManager createDirectoryAtPath:root
                         withIntermediateDirectories:YES
                                          attributes:nil
                                               error:nil]);
    NSString *path = [root stringByAppendingPathComponent:@"upload.checkpoint"];
    TOSUploadCheckpointV2 *checkpoint =
        [TOSUploadCheckpointV2 tos_checkpointWithData:TOSTestJSONData(TOSTestUploadCheckpointFixture())
                                       checkpointPath:path
                                                error:nil];
    TOSTransferCheckpointStore *store = [TOSTransferCheckpointStore new];

    for (id invalidOperation in @[@1, @[], @{}, NSNull.null]) {
        NSMutableDictionary *fixture = TOSTestMutableJSONCopy(TOSTestUploadCheckpointFixture());
        fixture[@"operation"] = invalidOperation;
        NSData *invalidData = TOSTestJSONData(fixture);
        XCTAssertTrue([invalidData writeToFile:path atomically:YES]);

        NSError *error = nil;
        __block BOOL success = YES;
        XCTAssertNoThrow(success = [store writeCheckpoint:checkpoint error:&error]);
        XCTAssertFalse(success);
        XCTAssertNotNil(error);
        XCTAssertEqualObjects([NSData dataWithContentsOfFile:path], invalidData);
    }

    [fileManager removeItemAtPath:root error:nil];
}

- (void)testCheckpointStoreRejectsNonStringOperationWithoutThrowingOnRemove {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTAssertTrue([fileManager createDirectoryAtPath:root
                         withIntermediateDirectories:YES
                                          attributes:nil
                                               error:nil]);
    NSString *path = [root stringByAppendingPathComponent:@"upload.checkpoint"];
    TOSUploadCheckpointV2 *checkpoint =
        [TOSUploadCheckpointV2 tos_checkpointWithData:TOSTestJSONData(TOSTestUploadCheckpointFixture())
                                       checkpointPath:path
                                                error:nil];
    TOSTransferCheckpointStore *store = [TOSTransferCheckpointStore new];

    for (id invalidOperation in @[@1, @[], @{}, NSNull.null]) {
        NSMutableDictionary *fixture = TOSTestMutableJSONCopy(TOSTestUploadCheckpointFixture());
        fixture[@"operation"] = invalidOperation;
        NSData *invalidData = TOSTestJSONData(fixture);
        XCTAssertTrue([invalidData writeToFile:path atomically:YES]);

        NSError *error = nil;
        __block BOOL success = YES;
        XCTAssertNoThrow(success = [store removeCheckpoint:checkpoint error:&error]);
        XCTAssertFalse(success);
        XCTAssertNotNil(error);
        XCTAssertEqualObjects([NSData dataWithContentsOfFile:path], invalidData);
    }

    [fileManager removeItemAtPath:root error:nil];
}

- (void)testCheckpointLeaseExclusivelyOwnsNormalizedPathUntilReleased {
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:root
                                             withIntermediateDirectories:YES
                                                              attributes:nil
                                                                   error:nil]);
    NSString *path = [root stringByAppendingPathComponent:@"transfer.checkpoint"];
    NSString *aliasPath = [root stringByAppendingPathComponent:@"nested/../transfer.checkpoint"];
    NSError *error = nil;
    TOSTransferCheckpointLease *firstLease =
        [TOSTransferCheckpointLease acquireCheckpointPath:path error:&error];
    XCTAssertNotNil(firstLease);
    XCTAssertNil(error);

    error = nil;
    TOSTransferCheckpointLease *conflictingLease =
        [TOSTransferCheckpointLease acquireCheckpointPath:aliasPath error:&error];
    XCTAssertNil(conflictingLease);
    XCTAssertNotNil(error);

    [firstLease invalidate];
    error = nil;
    TOSTransferCheckpointLease *nextLease =
        [TOSTransferCheckpointLease acquireCheckpointPath:path error:&error];
    XCTAssertNotNil(nextLease);
    XCTAssertNil(error);
    [nextLease invalidate];
    [[NSFileManager defaultManager] removeItemAtPath:root error:nil];
}

- (void)testCheckpointStoreRejectsDifferentOwnerOverwriteAndConditionalDelete {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *path = [root stringByAppendingPathComponent:@"upload.checkpoint"];
    TOSUploadCheckpointV2 *owner =
        [TOSUploadCheckpointV2 tos_checkpointWithData:TOSTestJSONData(TOSTestUploadCheckpointFixture())
                                       checkpointPath:path
                                                error:nil];
    TOSUploadCheckpointV2 *other =
        [TOSUploadCheckpointV2 tos_checkpointWithData:TOSTestJSONData(TOSTestUploadCheckpointFixture())
                                       checkpointPath:path
                                                error:nil];
    owner.tos_checkpointID = @"owner-id";
    other.tos_checkpointID = @"other-id";

    TOSTransferCheckpointStore *store = [TOSTransferCheckpointStore new];
    NSError *error = nil;
    XCTAssertTrue([store writeCheckpoint:owner error:&error]);
    XCTAssertNil(error);
    NSData *ownerData = [NSData dataWithContentsOfFile:path];

    error = nil;
    XCTAssertFalse([store writeCheckpoint:other error:&error]);
    XCTAssertNotNil(error);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:path], ownerData);

    error = nil;
    XCTAssertFalse([store removeCheckpoint:other error:&error]);
    XCTAssertNotNil(error);
    XCTAssertTrue([fileManager fileExistsAtPath:path]);

    error = nil;
    XCTAssertTrue([store removeCheckpoint:owner error:&error]);
    XCTAssertNil(error);
    XCTAssertFalse([fileManager fileExistsAtPath:path]);
    [fileManager removeItemAtPath:root error:nil];
}

- (void)testFileRangeInputStreamReadsOnlyRequestedRangeAndCRC {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTAssertTrue([fileManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil]);
    NSString *path = [root stringByAppendingPathComponent:@"source.bin"];
    NSData *source = TOSTestPatternData(1024 * 1024);
    XCTAssertTrue([source writeToFile:path atomically:YES]);

    int sourceDescriptor = open(path.fileSystemRepresentation, O_RDONLY);
    XCTAssertGreaterThanOrEqual(sourceDescriptor, 0);
    TOSTestRecordingLimiter *limiter = [TOSTestRecordingLimiter new];
    NSError *error = nil;
    TOSFileRangeInputStream *stream = [[TOSFileRangeInputStream alloc] initWithFileDescriptor:sourceDescriptor
                                                                                       offset:131072
                                                                                       length:262144
                                                                                  rateLimiter:limiter
                                                                                   cancelHook:nil
                                                                                        error:&error];
    XCTAssertNotNil(stream);
    XCTAssertNil(error);
    int ownedDescriptor = stream.tos_fileDescriptor;
    close(sourceDescriptor);

    [stream open];
    NSMutableData *actual = [NSMutableData data];
    uint8_t buffer[64 * 1024];
    NSInteger bytesRead = 0;
    while ((bytesRead = [stream read:buffer maxLength:sizeof(buffer)]) > 0) {
        [actual appendBytes:buffer length:(NSUInteger)bytesRead];
    }
    XCTAssertEqual(bytesRead, 0);
    XCTAssertEqual([stream read:buffer maxLength:sizeof(buffer)], 0);
    XCTAssertEqualObjects(actual, [source subdataWithRange:NSMakeRange(131072, 262144)]);
    XCTAssertEqual(stream.tos_consumed, 262144);
    XCTAssertEqual(stream.tos_crc64, TOSTransferCRC64(0, actual.bytes, actual.length));
    XCTAssertEqual(limiter.requests.count, 4);
    for (NSNumber *request in limiter.requests) {
        XCTAssertEqual(request.longLongValue, 64 * 1024);
    }

    [stream close];
    errno = 0;
    XCTAssertEqual(fcntl(ownedDescriptor, F_GETFD), -1);
    XCTAssertEqual(errno, EBADF);
    [fileManager removeItemAtPath:root error:nil];
}

- (void)testTransferIOChunksLimiterAcquisitionsToSupportedMaximum {
    NSString *sourcePath = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSData *source = TOSTestPatternData(32 * 1024);
    XCTAssertTrue([source writeToFile:sourcePath atomically:YES]);
    int descriptor = open(sourcePath.fileSystemRepresentation, O_RDONLY);
    XCTAssertGreaterThanOrEqual(descriptor, 0);
    __block NSTimeInterval now = 1;
    TOSDefaultRateLimiter *defaultLimiter = [[TOSDefaultRateLimiter alloc] initWithCapacity:10 * 1024
                                                                                      rate:1024
                                                                                     clock:^NSTimeInterval{
        return now;
    }];
    NSError *error = nil;
    TOSFileRangeInputStream *stream = [[TOSFileRangeInputStream alloc] initWithFileDescriptor:descriptor
                                                                                      offset:0
                                                                                      length:source.length
                                                                                 rateLimiter:defaultLimiter
                                                                                  cancelHook:nil
                                                                                       error:&error];
    XCTAssertNotNil(stream);
    [stream open];
    uint8_t buffer[32 * 1024];
    XCTAssertEqual([stream read:buffer maxLength:sizeof(buffer)], 10 * 1024);
    [stream close];
    close(descriptor);
    [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];

    NSString *destinationPath = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    TOSTestCappedRecordingLimiter *recordingLimiter = [TOSTestCappedRecordingLimiter new];
    TOSDownloadFileWriter *writer = [[TOSDownloadFileWriter alloc] initWithFilePath:destinationPath
                                                                               size:10
                                                                        rateLimiter:recordingLimiter
                                                                         cancelHook:nil
                                                                              error:&error];
    TOSDownloadPartWriter *partWriter = [writer partWriterWithOffset:0 length:10 error:&error];
    XCTAssertTrue([partWriter writeData:[@"0123456789" dataUsingEncoding:NSUTF8StringEncoding] error:&error]);
    XCTAssertTrue([partWriter finish:&error]);
    XCTAssertEqualObjects(recordingLimiter.requests, (@[@4, @4, @2]));
    [writer close];
    [[NSFileManager defaultManager] removeItemAtPath:destinationPath error:nil];
}

- (void)testDownloadWriterAndRenameRemainAnchoredToOpenedDirectory {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *parent = [root stringByAppendingPathComponent:@"parent"];
    NSString *movedParent = [root stringByAppendingPathComponent:@"moved-parent"];
    NSString *outside = [root stringByAppendingPathComponent:@"outside"];
    XCTAssertTrue([fileManager createDirectoryAtPath:parent
                         withIntermediateDirectories:YES
                                          attributes:nil
                                               error:nil]);
    XCTAssertTrue([fileManager createDirectoryAtPath:outside
                         withIntermediateDirectories:YES
                                          attributes:nil
                                               error:nil]);

    int directoryFileDescriptor = open(parent.fileSystemRepresentation,
                                       O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    XCTAssertGreaterThanOrEqual(directoryFileDescriptor, 0);
    XCTAssertEqual(rename(parent.fileSystemRepresentation, movedParent.fileSystemRepresentation), 0);
    XCTAssertEqual(symlink(outside.fileSystemRepresentation, parent.fileSystemRepresentation), 0);

    NSError *error = nil;
    TOSDownloadFileWriter *writer =
        [[TOSDownloadFileWriter alloc] initWithDirectoryFileDescriptor:directoryFileDescriptor
                                                              fileName:@"object.temp"
                                                                  size:4
                                                           rateLimiter:nil
                                                            cancelHook:nil
                                                                 error:&error];
    XCTAssertNotNil(writer);
    XCTAssertNil(error);
    TOSDownloadPartWriter *partWriter = [writer partWriterWithOffset:0 length:4 error:&error];
    XCTAssertTrue([partWriter writeData:[@"data" dataUsingEncoding:NSUTF8StringEncoding] error:&error]);
    XCTAssertTrue([partWriter finish:&error]);
    [writer close];

    XCTAssertTrue(TOSTransferRenameFileAt(directoryFileDescriptor,
                                         @"object.temp",
                                         directoryFileDescriptor,
                                         @"object.bin",
                                         &error));
    XCTAssertNil(error);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:[movedParent stringByAppendingPathComponent:@"object.bin"]],
                          [@"data" dataUsingEncoding:NSUTF8StringEncoding]);
    XCTAssertFalse([fileManager fileExistsAtPath:[outside stringByAppendingPathComponent:@"object.temp"]]);
    XCTAssertFalse([fileManager fileExistsAtPath:[outside stringByAppendingPathComponent:@"object.bin"]]);

    close(directoryFileDescriptor);
    [fileManager removeItemAtPath:root error:nil];
}

- (void)testDownloadCommitRejectsReplacedSourceWithoutTouchingFinalFile {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTAssertTrue([fileManager createDirectoryAtPath:root
                         withIntermediateDirectories:YES
                                          attributes:nil
                                               error:nil]);
    NSString *sourcePath = [root stringByAppendingPathComponent:@"object.temp"];
    NSString *finalPath = [root stringByAppendingPathComponent:@"object.bin"];
    NSData *expected = [@"expected" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *replacement = [@"replaced" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *original = [@"original" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertTrue([expected writeToFile:sourcePath atomically:YES]);
    XCTAssertTrue([original writeToFile:finalPath atomically:YES]);
    int sourceDescriptor = open(sourcePath.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    int directoryDescriptor = open(root.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    XCTAssertGreaterThanOrEqual(sourceDescriptor, 0);
    XCTAssertGreaterThanOrEqual(directoryDescriptor, 0);

    XCTAssertTrue([fileManager removeItemAtPath:sourcePath error:nil]);
    XCTAssertTrue([replacement writeToFile:sourcePath atomically:YES]);
    NSError *error = nil;
    XCTAssertFalse(TOSTransferCommitFileAt(directoryDescriptor,
                                          sourcePath.lastPathComponent,
                                          sourceDescriptor,
                                          directoryDescriptor,
                                          finalPath.lastPathComponent,
                                          &error));
    XCTAssertNotNil(error);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:finalPath], original);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:sourcePath], replacement);

    close(sourceDescriptor);
    close(directoryDescriptor);
    [fileManager removeItemAtPath:root error:nil];
}

- (void)testDownloadCommitAtomicallyReplacesFinalWithOpenedSourceIdentity {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTAssertTrue([fileManager createDirectoryAtPath:root
                         withIntermediateDirectories:YES
                                          attributes:nil
                                               error:nil]);
    NSString *sourcePath = [root stringByAppendingPathComponent:@"object.temp"];
    NSString *finalPath = [root stringByAppendingPathComponent:@"object.bin"];
    NSData *expected = [@"expected" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertTrue([expected writeToFile:sourcePath atomically:YES]);
    XCTAssertTrue([[@"original" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:finalPath atomically:YES]);
    int sourceDescriptor = open(sourcePath.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    int directoryDescriptor = open(root.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    NSError *error = nil;

    XCTAssertTrue(TOSTransferCommitFileAt(directoryDescriptor,
                                         sourcePath.lastPathComponent,
                                         sourceDescriptor,
                                         directoryDescriptor,
                                         finalPath.lastPathComponent,
                                         &error));
    XCTAssertNil(error);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:finalPath], expected);
    XCTAssertFalse([fileManager fileExistsAtPath:sourcePath]);

    close(sourceDescriptor);
    close(directoryDescriptor);
    [fileManager removeItemAtPath:root error:nil];
}

- (void)testDownloadCommitSupportsLongSourceAndDestinationNames {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTAssertTrue([fileManager createDirectoryAtPath:root
                         withIntermediateDirectories:YES
                                          attributes:nil
                                               error:nil]);
    NSString *sourceName = [@"" stringByPaddingToLength:240 withString:@"s" startingAtIndex:0];
    NSString *destinationName = [@"" stringByPaddingToLength:240 withString:@"d" startingAtIndex:0];
    NSString *sourcePath = [root stringByAppendingPathComponent:sourceName];
    NSString *destinationPath = [root stringByAppendingPathComponent:destinationName];
    NSData *expected = [@"expected" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertTrue([expected writeToFile:sourcePath atomically:YES]);
    int sourceDescriptor = open(sourcePath.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    int directoryDescriptor = open(root.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    XCTAssertGreaterThanOrEqual(sourceDescriptor, 0);
    XCTAssertGreaterThanOrEqual(directoryDescriptor, 0);
    NSError *error = nil;

    XCTAssertTrue(TOSTransferCommitFileAt(directoryDescriptor,
                                         sourceName,
                                         sourceDescriptor,
                                         directoryDescriptor,
                                         destinationName,
                                         &error));
    XCTAssertNil(error);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:destinationPath], expected);
    XCTAssertFalse([fileManager fileExistsAtPath:sourcePath]);

    close(sourceDescriptor);
    close(directoryDescriptor);
    [fileManager removeItemAtPath:root error:nil];
}

- (void)testDownloadCommitRestoresSourceWhenFinalRenameFails {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTAssertTrue([fileManager createDirectoryAtPath:root
                         withIntermediateDirectories:YES
                                          attributes:nil
                                               error:nil]);
    NSString *sourcePath = [root stringByAppendingPathComponent:@"object.temp"];
    NSString *destinationPath = [root stringByAppendingPathComponent:@"object.bin"];
    NSData *expected = [@"expected" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertTrue([expected writeToFile:sourcePath atomically:YES]);
    XCTAssertTrue([fileManager createDirectoryAtPath:destinationPath
                         withIntermediateDirectories:NO
                                          attributes:nil
                                               error:nil]);
    int sourceDescriptor = open(sourcePath.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    int directoryDescriptor = open(root.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    XCTAssertGreaterThanOrEqual(sourceDescriptor, 0);
    XCTAssertGreaterThanOrEqual(directoryDescriptor, 0);
    NSError *error = nil;

    XCTAssertFalse(TOSTransferCommitFileAt(directoryDescriptor,
                                          sourcePath.lastPathComponent,
                                          sourceDescriptor,
                                          directoryDescriptor,
                                          destinationPath.lastPathComponent,
                                          &error));
    XCTAssertNotNil(error);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:sourcePath], expected);
    BOOL isDirectory = NO;
    XCTAssertTrue([fileManager fileExistsAtPath:destinationPath isDirectory:&isDirectory]);
    XCTAssertTrue(isDirectory);

    close(sourceDescriptor);
    close(directoryDescriptor);
    [fileManager removeItemAtPath:root error:nil];
}

- (void)testDownloadWriterRejectsResumeIdentityReplacementBeforeConfiguration {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTAssertTrue([fileManager createDirectoryAtPath:root
                         withIntermediateDirectories:YES
                                          attributes:nil
                                               error:nil]);
    NSString *tempPath = [root stringByAppendingPathComponent:@"object.temp"];
    NSData *original = [@"completed-part" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *replacement = [@"replacement-must-not-be-truncated" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertTrue([original writeToFile:tempPath atomically:YES]);
    struct stat originalStat;
    XCTAssertEqual(lstat(tempPath.fileSystemRepresentation, &originalStat), 0);
    XCTAssertTrue([fileManager removeItemAtPath:tempPath error:nil]);
    XCTAssertTrue([replacement writeToFile:tempPath atomically:YES]);
    int directoryDescriptor = open(root.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    XCTAssertGreaterThanOrEqual(directoryDescriptor, 0);

    NSError *error = nil;
    TOSDownloadFileWriter *writer =
        [[TOSDownloadFileWriter alloc] initWithDirectoryFileDescriptor:directoryDescriptor
                                                              fileName:tempPath.lastPathComponent
                                                                  size:4
                                                        expectedDevice:(uint64_t)originalStat.st_dev
                                                         expectedInode:(uint64_t)originalStat.st_ino
                                                           rateLimiter:nil
                                                            cancelHook:nil
                                                                 error:&error];

    XCTAssertNil(writer);
    XCTAssertNotNil(error);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:tempPath], replacement);
    close(directoryDescriptor);
    [fileManager removeItemAtPath:root error:nil];
}

- (void)testDownloadIdentityRemovalNeverDeletesReplacement {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTAssertTrue([fileManager createDirectoryAtPath:root
                         withIntermediateDirectories:YES
                                          attributes:nil
                                               error:nil]);
    NSString *tempPath = [root stringByAppendingPathComponent:@"object.temp"];
    NSData *original = [@"original" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *replacement = [@"replacement" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertTrue([original writeToFile:tempPath atomically:YES]);
    struct stat originalStat;
    XCTAssertEqual(lstat(tempPath.fileSystemRepresentation, &originalStat), 0);
    XCTAssertTrue([fileManager removeItemAtPath:tempPath error:nil]);
    XCTAssertTrue([replacement writeToFile:tempPath atomically:YES]);
    int directoryDescriptor = open(root.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    XCTAssertGreaterThanOrEqual(directoryDescriptor, 0);

    XCTAssertFalse(TOSTransferRemoveFileAtIfIdentity(directoryDescriptor,
                                                    tempPath.lastPathComponent,
                                                    (uint64_t)originalStat.st_dev,
                                                    (uint64_t)originalStat.st_ino));
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:tempPath], replacement);

    struct stat replacementStat;
    XCTAssertEqual(lstat(tempPath.fileSystemRepresentation, &replacementStat), 0);
    XCTAssertTrue(TOSTransferRemoveFileAtIfIdentity(directoryDescriptor,
                                                   tempPath.lastPathComponent,
                                                   (uint64_t)replacementStat.st_dev,
                                                   (uint64_t)replacementStat.st_ino));
    XCTAssertFalse([fileManager fileExistsAtPath:tempPath]);
    close(directoryDescriptor);
    [fileManager removeItemAtPath:root error:nil];
}

- (void)testDownloadWriterRemovesOnlyNewFileWhenConfigurationFails {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTAssertTrue([fileManager createDirectoryAtPath:root
                         withIntermediateDirectories:YES
                                          attributes:nil
                                               error:nil]);
    NSString *newPath = [root stringByAppendingPathComponent:@"new.temp"];
    NSError *error = nil;
    XCTAssertNil([[TOSTestFailingDownloadFileWriter alloc] initWithFilePath:newPath size:4 error:&error]);
    XCTAssertNotNil(error);
    XCTAssertFalse([fileManager fileExistsAtPath:newPath]);

    NSData *original = [@"keep" dataUsingEncoding:NSUTF8StringEncoding];
    NSString *existingPath = [root stringByAppendingPathComponent:@"existing.temp"];
    XCTAssertTrue([original writeToFile:existingPath atomically:YES]);
    error = nil;
    XCTAssertNil([[TOSTestFailingDownloadFileWriter alloc] initWithFilePath:existingPath size:4 error:&error]);
    XCTAssertNotNil(error);
    XCTAssertTrue([fileManager fileExistsAtPath:existingPath]);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:existingPath], original);

    int directoryDescriptor = open(root.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    XCTAssertGreaterThanOrEqual(directoryDescriptor, 0);
    error = nil;
    XCTAssertNil([[TOSTestFailingDownloadFileWriter alloc]
                  initWithDirectoryFileDescriptor:directoryDescriptor
                  fileName:@"directory-new.temp"
                  size:4
                  rateLimiter:nil
                  cancelHook:nil
                  error:&error]);
    XCTAssertNotNil(error);
    XCTAssertFalse([fileManager fileExistsAtPath:[root stringByAppendingPathComponent:@"directory-new.temp"]]);

    NSString *directoryExistingPath = [root stringByAppendingPathComponent:@"directory-existing.temp"];
    XCTAssertTrue([original writeToFile:directoryExistingPath atomically:YES]);
    error = nil;
    XCTAssertNil([[TOSTestFailingDownloadFileWriter alloc]
                  initWithDirectoryFileDescriptor:directoryDescriptor
                  fileName:directoryExistingPath.lastPathComponent
                  size:4
                  rateLimiter:nil
                  cancelHook:nil
                  error:&error]);
    XCTAssertNotNil(error);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:directoryExistingPath], original);
    close(directoryDescriptor);
    [fileManager removeItemAtPath:root error:nil];
}

- (void)testBorrowedFileRangeInputStreamDoesNotCloseSourceDescriptor {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTAssertTrue([[@"content" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:YES]);
    int descriptor = open(path.fileSystemRepresentation, O_RDONLY);
    XCTAssertGreaterThanOrEqual(descriptor, 0);

    NSError *error = nil;
    TOSFileRangeInputStream *stream =
        [[TOSFileRangeInputStream alloc] initWithBorrowedFileDescriptor:descriptor
                                                                 offset:0
                                                                 length:7
                                                            rateLimiter:nil
                                                             cancelHook:nil
                                                                  error:&error];
    XCTAssertNotNil(stream);
    XCTAssertNil(error);
    XCTAssertEqual(stream.tos_fileDescriptor, descriptor);
    [stream close];
    XCTAssertNotEqual(fcntl(descriptor, F_GETFD), -1);

    close(descriptor);
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
}

- (void)testFileRangeInputStreamImplementsNSStreamSubclassPrimitives {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTAssertTrue([[NSData dataWithBytes:"x" length:1] writeToFile:path atomically:YES]);
    int descriptor = open(path.fileSystemRepresentation, O_RDONLY);
    XCTAssertGreaterThanOrEqual(descriptor, 0);
    NSError *error = nil;
    TOSFileRangeInputStream *stream = [[TOSFileRangeInputStream alloc] initWithFileDescriptor:descriptor
                                                                                      offset:0
                                                                                      length:1
                                                                                 rateLimiter:nil
                                                                                  cancelHook:nil
                                                                                       error:&error];
    close(descriptor);
    XCTAssertNotNil(stream);
    XCTAssertNil(error);

    TOSTestStreamDelegate *delegate = [TOSTestStreamDelegate new];
    XCTAssertNoThrow(stream.delegate = delegate);
    XCTAssertEqual(stream.delegate, delegate);
    XCTAssertNoThrow([stream scheduleInRunLoop:NSRunLoop.currentRunLoop forMode:NSDefaultRunLoopMode]);
    [stream open];
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    XCTAssertTrue([delegate.events containsObject:@(NSStreamEventOpenCompleted)]);
    XCTAssertTrue([delegate.events containsObject:@(NSStreamEventHasBytesAvailable)]);

    uint8_t byte = 0;
    XCTAssertEqual([stream read:&byte maxLength:1], 1);
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    XCTAssertTrue([delegate.events containsObject:@(NSStreamEventEndEncountered)]);
    XCTAssertNoThrow([stream removeFromRunLoop:NSRunLoop.currentRunLoop forMode:NSDefaultRunLoopMode]);
    XCTAssertNil([stream propertyForKey:@"unsupported"]);
    XCTAssertFalse([stream setProperty:@"value" forKey:@"unsupported"]);
    stream.delegate = nil;
    XCTAssertEqual(stream.delegate, stream);

    [stream close];
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
}

- (void)testFileRangeInputStreamHandlesZeroLengthAndCancellation {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTAssertTrue([[@"abc" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:YES]);
    int descriptor = open(path.fileSystemRepresentation, O_RDONLY);
    NSError *error = nil;
    TOSFileRangeInputStream *empty = [[TOSFileRangeInputStream alloc] initWithFileDescriptor:descriptor
                                                                                     offset:0
                                                                                     length:0
                                                                                rateLimiter:nil
                                                                                 cancelHook:nil
                                                                                      error:&error];
    close(descriptor);
    [empty open];
    uint8_t byte = 0;
    XCTAssertEqual([empty read:&byte maxLength:1], 0);
    XCTAssertFalse(empty.hasBytesAvailable);
    XCTAssertEqual(empty.tos_crc64, 0);
    [empty close];

    descriptor = open(path.fileSystemRepresentation, O_RDONLY);
    TOSCancelHook *hook = [TOSCancelHook new];
    TOSFileRangeInputStream *cancelled = [[TOSFileRangeInputStream alloc] initWithFileDescriptor:descriptor
                                                                                          offset:0
                                                                                          length:3
                                                                                     rateLimiter:nil
                                                                                      cancelHook:hook
                                                                                           error:&error];
    close(descriptor);
    [cancelled open];
    [hook cancel:NO];
    XCTAssertEqual([cancelled read:&byte maxLength:1], -1);
    XCTAssertEqualObjects(cancelled.streamError.domain, TOSClientErrorDomain);
    [cancelled close];
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
}

- (void)testDownloadWriterSupportsConcurrentNonOverlappingParts {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTAssertTrue([fileManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil]);
    NSString *path = [root stringByAppendingPathComponent:@"download.temp"];
    NSData *expected = TOSTestPatternData(3 * 64 * 1024);
    NSError *error = nil;
    TOSDownloadFileWriter *writer = [[TOSDownloadFileWriter alloc] initWithFilePath:path
                                                                               size:expected.length
                                                                              error:&error];
    XCTAssertNotNil(writer);
    XCTAssertNil(error);

    NSMutableArray<TOSDownloadPartWriter *> *partWriters = [NSMutableArray array];
    for (NSInteger index = 0; index < 3; index++) {
        TOSDownloadPartWriter *partWriter = [writer partWriterWithOffset:index * 64 * 1024
                                                                  length:64 * 1024
                                                                   error:&error];
        XCTAssertNotNil(partWriter);
        [partWriters addObject:partWriter];
    }

    NSObject *guard = [NSObject new];
    __block NSInteger failures = 0;
    dispatch_group_t group = dispatch_group_create();
    for (NSInteger index = 2; index >= 0; index--) {
        dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSData *partData = [expected subdataWithRange:NSMakeRange(index * 64 * 1024, 64 * 1024)];
            NSError *partError = nil;
            BOOL success = [partWriters[index] writeData:partData error:&partError] &&
                           [partWriters[index] finish:&partError];
            if (!success) {
                @synchronized (guard) {
                    failures += 1;
                }
            }
        });
    }
    XCTAssertEqual(dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)), 0);
    XCTAssertEqual(failures, 0);
    for (NSInteger index = 0; index < 3; index++) {
        NSData *partData = [expected subdataWithRange:NSMakeRange(index * 64 * 1024, 64 * 1024)];
        XCTAssertEqual(partWriters[index].tos_crc64, TOSTransferCRC64(0, partData.bytes, partData.length));
    }

    int descriptor = writer.tos_fileDescriptor;
    [writer close];
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:path], expected);
    errno = 0;
    XCTAssertEqual(fcntl(descriptor, F_GETFD), -1);
    XCTAssertEqual(errno, EBADF);
    [fileManager removeItemAtPath:root error:nil];
}

- (void)testDownloadFileWriterCloseWaitsForActivePositionalWrite {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTAssertTrue([fileManager createDirectoryAtPath:root
                         withIntermediateDirectories:YES
                                          attributes:nil
                                               error:nil]);
    NSString *path = [root stringByAppendingPathComponent:@"download.temp"];
    TOSTestBlockingPositionalWriter *positionalWriter = [TOSTestBlockingPositionalWriter new];
    NSError *error = nil;
    TOSDownloadFileWriter *writer =
        [[TOSDownloadFileWriter alloc] initWithFilePath:path
                                                   size:4
                                       positionalWriter:positionalWriter
                                            rateLimiter:nil
                                             cancelHook:nil
                                                  error:&error];
    TOSDownloadPartWriter *partWriter = [writer partWriterWithOffset:0 length:4 error:&error];
    dispatch_semaphore_t writeCompleted = dispatch_semaphore_create(0);
    dispatch_semaphore_t closeStarted = dispatch_semaphore_create(0);
    dispatch_semaphore_t closeCompleted = dispatch_semaphore_create(0);
    __block BOOL writeSucceeded = NO;
    __block NSError *writeError = nil;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        writeSucceeded = [partWriter writeData:[@"data" dataUsingEncoding:NSUTF8StringEncoding]
                                         error:&writeError];
        dispatch_semaphore_signal(writeCompleted);
    });
    XCTAssertEqual(dispatch_semaphore_wait(positionalWriter.tos_callsStarted,
                                           dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)),
                   0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        dispatch_semaphore_signal(closeStarted);
        [writer close];
        dispatch_semaphore_signal(closeCompleted);
    });

    XCTAssertEqual(dispatch_semaphore_wait(closeStarted,
                                           dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)),
                   0);
    XCTAssertNotEqual(dispatch_semaphore_wait(closeCompleted,
                                              dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC)),
                      0);
    dispatch_semaphore_signal(positionalWriter.tos_allowWrites);
    XCTAssertEqual(dispatch_semaphore_wait(writeCompleted,
                                           dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)),
                   0);
    XCTAssertEqual(dispatch_semaphore_wait(closeCompleted,
                                           dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)),
                   0);
    XCTAssertTrue(writeSucceeded);
    XCTAssertNil(writeError);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:path],
                          [@"data" dataUsingEncoding:NSUTF8StringEncoding]);
    [fileManager removeItemAtPath:root error:nil];
}

- (void)testDownloadFileWriterKeepsIndependentPositionalWritesConcurrent {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTAssertTrue([fileManager createDirectoryAtPath:root
                         withIntermediateDirectories:YES
                                          attributes:nil
                                               error:nil]);
    NSString *path = [root stringByAppendingPathComponent:@"download.temp"];
    TOSTestBlockingPositionalWriter *positionalWriter = [TOSTestBlockingPositionalWriter new];
    NSError *error = nil;
    TOSDownloadFileWriter *writer =
        [[TOSDownloadFileWriter alloc] initWithFilePath:path
                                                   size:8
                                       positionalWriter:positionalWriter
                                            rateLimiter:nil
                                             cancelHook:nil
                                                  error:&error];
    NSArray<TOSDownloadPartWriter *> *partWriters =
        @[[writer partWriterWithOffset:0 length:4 error:&error],
          [writer partWriterWithOffset:4 length:4 error:&error]];
    dispatch_group_t group = dispatch_group_create();
    __block NSInteger failures = 0;
    NSObject *guard = [NSObject new];
    for (TOSDownloadPartWriter *partWriter in partWriters) {
        dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *writeError = nil;
            if (![partWriter writeData:[@"data" dataUsingEncoding:NSUTF8StringEncoding]
                                 error:&writeError]) {
                @synchronized (guard) {
                    failures += 1;
                }
            }
        });
    }

    long firstStarted = dispatch_semaphore_wait(positionalWriter.tos_callsStarted,
                                                dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
    long secondStarted = dispatch_semaphore_wait(positionalWriter.tos_callsStarted,
                                                 dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
    dispatch_semaphore_signal(positionalWriter.tos_allowWrites);
    dispatch_semaphore_signal(positionalWriter.tos_allowWrites);
    XCTAssertEqual(firstStarted, 0);
    XCTAssertEqual(secondStarted, 0);
    XCTAssertEqual(dispatch_group_wait(group,
                                       dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)),
                   0);
    XCTAssertEqual(failures, 0);
    XCTAssertEqual(positionalWriter.tos_maximumActiveCalls, 2);

    [writer close];
    [fileManager removeItemAtPath:root error:nil];
}

- (void)testDownloadPartWriterRejectsShortLongAndDiskFailures {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTAssertTrue([fileManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil]);
    NSString *path = [root stringByAppendingPathComponent:@"download.temp"];
    NSError *error = nil;
    TOSDownloadFileWriter *writer = [[TOSDownloadFileWriter alloc] initWithFilePath:path size:16 error:&error];
    TOSDownloadPartWriter *shortPart = [writer partWriterWithOffset:0 length:5 error:&error];
    XCTAssertTrue([shortPart writeData:[@"abc" dataUsingEncoding:NSUTF8StringEncoding] error:&error]);
    error = nil;
    XCTAssertFalse([shortPart finish:&error]);
    XCTAssertNotNil(error);

    TOSDownloadPartWriter *longPart = [writer partWriterWithOffset:5 length:2 error:&error];
    error = nil;
    XCTAssertFalse([longPart writeData:[@"xyz" dataUsingEncoding:NSUTF8StringEncoding] error:&error]);
    XCTAssertNotNil(error);
    [writer close];
    NSData *contents = [NSData dataWithContentsOfFile:path];
    const uint8_t *bytes = contents.bytes;
    XCTAssertEqual(bytes[5], 0);
    XCTAssertEqual(bytes[6], 0);
    XCTAssertEqual(bytes[7], 0);

    NSString *failurePath = [root stringByAppendingPathComponent:@"failure.temp"];
    TOSDownloadFileWriter *failingWriter = [[TOSDownloadFileWriter alloc] initWithFilePath:failurePath
                                                                                       size:4
                                                                           positionalWriter:[TOSTestFailingPositionalWriter new]
                                                                                rateLimiter:nil
                                                                                 cancelHook:nil
                                                                                      error:&error];
    TOSDownloadPartWriter *failurePart = [failingWriter partWriterWithOffset:0 length:4 error:&error];
    error = nil;
    XCTAssertFalse([failurePart writeData:[@"data" dataUsingEncoding:NSUTF8StringEncoding] error:&error]);
    XCTAssertEqualObjects(error.domain, NSPOSIXErrorDomain);
    XCTAssertEqual(error.code, ENOSPC);
    [failingWriter close];

    NSString *longPath = [root stringByAppendingPathComponent:@"invalid-writer.temp"];
    TOSDownloadFileWriter *invalidWriter = [[TOSDownloadFileWriter alloc] initWithFilePath:longPath
                                                                                      size:4
                                                                          positionalWriter:[TOSTestLongPositionalWriter new]
                                                                               rateLimiter:nil
                                                                                cancelHook:nil
                                                                                     error:&error];
    TOSDownloadPartWriter *invalidPart = [invalidWriter partWriterWithOffset:0 length:4 error:&error];
    error = nil;
    XCTAssertFalse([invalidPart writeData:[@"data" dataUsingEncoding:NSUTF8StringEncoding] error:&error]);
    XCTAssertEqualObjects(error.domain, NSPOSIXErrorDomain);
    XCTAssertEqual(error.code, EIO);
    [invalidWriter close];

    NSString *partialPath = [root stringByAppendingPathComponent:@"partial-writer.temp"];
    TOSTestPartialPositionalWriter *partialAdapter = [TOSTestPartialPositionalWriter new];
    TOSDownloadFileWriter *partialWriter = [[TOSDownloadFileWriter alloc] initWithFilePath:partialPath
                                                                                      size:4
                                                                          positionalWriter:partialAdapter
                                                                               rateLimiter:nil
                                                                                cancelHook:nil
                                                                                     error:&error];
    TOSDownloadPartWriter *partialPart = [partialWriter partWriterWithOffset:0 length:4 error:&error];
    error = nil;
    XCTAssertTrue([partialPart writeData:[@"data" dataUsingEncoding:NSUTF8StringEncoding] error:&error]);
    XCTAssertTrue([partialPart finish:&error]);
    XCTAssertEqual(partialAdapter.calls, 3);
    [partialWriter close];
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:partialPath],
                          [@"data" dataUsingEncoding:NSUTF8StringEncoding]);
    [fileManager removeItemAtPath:root error:nil];
}

- (void)testCRC64CombineMatchesConcatenatedData {
    NSData *first = [@"a" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *second = [@"bcdef" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *third = TOSTestPatternData(1003);
    NSMutableData *all = [NSMutableData dataWithData:first];
    [all appendData:second];
    [all appendData:third];

    uint64_t firstCRC = TOSTransferCRC64(0, first.bytes, first.length);
    uint64_t secondCRC = TOSTransferCRC64(0, second.bytes, second.length);
    uint64_t thirdCRC = TOSTransferCRC64(0, third.bytes, third.length);
    XCTAssertEqual(firstCRC, TOSTransferCRC64(0, all.bytes, first.length));

    uint64_t combined = TOSTransferCRC64Combine(firstCRC, secondCRC, second.length);
    NSData *firstTwo = [all subdataWithRange:NSMakeRange(0, first.length + second.length)];
    XCTAssertEqual(combined, TOSTransferCRC64(0, firstTwo.bytes, firstTwo.length));
    combined = TOSTransferCRC64Combine(combined, thirdCRC, third.length);
    XCTAssertEqual(combined, TOSTransferCRC64(0, all.bytes, all.length));
}

- (void)testNetworkCancellationCancelsRegisteredTasksExactlyOnce {
    TOSTransferNetworkCancellation *cancellation = [TOSTransferNetworkCancellation new];
    TOSTestURLSessionTask *first = TOSTestCreateURLSessionTask();
    TOSTestURLSessionTask *second = TOSTestCreateURLSessionTask();

    [cancellation registerTask:first];
    [cancellation registerTask:second];
    [cancellation cancel];
    [cancellation cancel];

    XCTAssertEqual(first.tos_cancelCount, 1);
    XCTAssertEqual(second.tos_cancelCount, 1);
}

- (void)testNetworkCancellationCancelsTaskRegisteredAfterCancellation {
    TOSTransferNetworkCancellation *cancellation = [TOSTransferNetworkCancellation new];
    TOSTestURLSessionTask *task = TOSTestCreateURLSessionTask();

    [cancellation cancel];
    [cancellation registerTask:task];

    XCTAssertEqual(task.tos_cancelCount, 1);
}

- (void)testNetworkCancellationDoesNotCancelUnregisteredTask {
    TOSTransferNetworkCancellation *cancellation = [TOSTransferNetworkCancellation new];
    TOSTestURLSessionTask *task = TOSTestCreateURLSessionTask();

    [cancellation registerTask:task];
    [cancellation unregisterTask:task];
    [cancellation cancel];

    XCTAssertEqual(task.tos_cancelCount, 0);
}

- (void)testTransferInputMetadataIsStoredPerRequest {
    TOSHeadObjectInput *first = [TOSHeadObjectInput new];
    TOSHeadObjectInput *second = [TOSHeadObjectInput new];
    TOSTransferNetworkCancellation *cancellation = [TOSTransferNetworkCancellation new];
    NSDictionary *headers = @{@"x-tos-traffic-limit": @"8192"};
    NSError *sentinel = [NSError errorWithDomain:@"test.response.validator" code:19 userInfo:nil];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://example.com"]
                                                             statusCode:206
                                                            HTTPVersion:@"HTTP/1.1"
                                                           headerFields:nil];
    TOSTransferResponseValidator validator = ^NSError *(NSHTTPURLResponse *response) {
        return sentinel;
    };

    first.tos_transferCancellation = cancellation;
    first.tos_transferHeaders = headers;
    first.tos_responseValidator = validator;

    XCTAssertEqual(first.tos_transferCancellation, cancellation);
    XCTAssertEqualObjects(first.tos_transferHeaders, headers);
    XCTAssertEqual(first.tos_responseValidator(response), sentinel);
    XCTAssertNil(second.tos_transferCancellation);
    XCTAssertNil(second.tos_transferHeaders);
    XCTAssertNil(second.tos_responseValidator);
}

- (void)testRangeResponseValidatorAcceptsExactPartialResponse {
    TOSTransferResponseValidator validator = TOSTransferRangeResponseValidator(100, 199);
    NSHTTPURLResponse *response = TOSTestHTTPResponse(206, @{
        @"Content-Range": @"bytes 100-199/1000",
        @"Content-Length": @"100"
    });

    XCTAssertNil(validator(response));
}

- (void)testRangeResponseValidatorRejectsInvalidResponses {
    TOSTransferResponseValidator validator = TOSTransferRangeResponseValidator(100, 199);
    NSArray<NSHTTPURLResponse *> *responses = @[
        TOSTestHTTPResponse(200, @{@"Content-Range": @"bytes 100-199/1000", @"Content-Length": @"100"}),
        TOSTestHTTPResponse(206, @{@"Content-Range": @"bytes 101-200/1000", @"Content-Length": @"100"}),
        TOSTestHTTPResponse(206, @{@"Content-Length": @"100"}),
        TOSTestHTTPResponse(206, @{@"Content-Range": @"bytes 100-199/1000", @"Content-Length": @"101"})
    ];

    for (NSHTTPURLResponse *response in responses) {
        NSError *error = validator(response);
        XCTAssertNotNil(error);
        XCTAssertEqualObjects(error.domain, TOSClientErrorDomain);
        XCTAssertEqual(error.code, 400);
        XCTAssertNotNil(error.userInfo[TOSErrorMessageTOKEN]);
    }
}

- (void)testNetworkingCancelsResponseWhenTransferValidationFails {
    NSError *sentinel = [NSError errorWithDomain:@"test.validation" code:42 userInfo:@{@"reason": @"range"}];
    TOSNetworkingRequestDelegate *delegate = [TOSNetworkingRequestDelegate new];
    delegate.tos_responseValidator = ^NSError *(NSHTTPURLResponse *response) {
        return sentinel;
    };
    TOSTestURLSessionTask *task = TOSTestCreateURLSessionTask();
    task.tos_taskIdentifier = 7;
    TOSNetworking *networking = [TOSNetworking new];
    networking.sessionDelagateManager = [TOSSynchronizedMutableDictionary new];
    [networking.sessionDelagateManager setObject:delegate forKey:@(task.taskIdentifier)];
    NSURLSession *unusedSession = (NSURLSession *)[NSNull null];
    __block NSURLSessionResponseDisposition disposition = NSURLSessionResponseAllow;

    [networking URLSession:unusedSession
                  dataTask:task
        didReceiveResponse:TOSTestHTTPResponse(200, @{})
         completionHandler:^(NSURLSessionResponseDisposition value) {
        disposition = value;
    }];

    XCTAssertEqual(disposition, NSURLSessionResponseCancel);
    XCTAssertEqual(task.tos_cancelCount, 1);
    XCTAssertEqual(delegate.error, sentinel);
}

- (void)testNetworkingCompletesServerTrustChallengeExactlyOnceWithDefaultHandling {
    NSString *certificateBase64 =
        @"MIIDEzCCAfugAwIBAgIUXEOB3IvxzjjMFVG54InCcjepWgUwDQYJKoZIhvcNAQELBQAwGTEXMBUGA1UEAwwOdG9zLXRlc3QubG9jYWwwHhcNMjYwNzEzMTUxMTA1WhcNMzYwNzEwMTUxMTA1WjAZMRcwFQYDVQQDDA50b3MtdGVzdC5sb2NhbDCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBANIWG4Taa3siE+Zg4kSL0HJjGxuvmD3PUAO+nk+ONSFx8/q0gQMxe7N7tS0SPf2cyM3Q+6h0zmrFMjfuj0oLzro2PjQf4JGoWKnujd3aTw+Xb/ut3HE4Jgcsx8CulR+UQkR2AzvY+y15sKAEZsPENZpmPe8h+UANBlPYJq8XUZ/qSaBWZo2N2aJ2NJkYyRDjcVSjgUIjzgDniwAXSt4CPymrOUSgre0qFb75MjRDm3gNApixn2LOw75moD8jqWccqhyV6lrH5jKcLGzrOxFUOHyoC2Op8BIDl3mqo5ugIk/uHFRumifbGrbnLl9HzTmosX35vZBcj6UNqr+Azk6Ab1UCAwEAAaNTMFEwHQYDVR0OBBYEFJb+DDRAFUZn5x9m/puTOMCBDRJKMB8GA1UdIwQYMBaAFJb+DDRAFUZn5x9m/puTOMCBDRJKMA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQELBQADggEBAGKGQDjV9UspE9d0S/BGKPigp1rjXJE7Klcb26V82T0lPgBoFNySTP7LSMib4twiknjVpoxXvhTnZp127AUDUuDOhEkUcuZm0+uLS40QHQV0wm/RAMHDScnBYLOtxUpJICzCeXgN+GVUsLsQvECKnQJ+j3ABodsIfzLJmephrKY6eyJnNdiKjUgCCp3GeHS4/GzIq9fUfKJaJx8KP+2luv3YrwSWxzVLNGEHDYu3vUgTZpIY2f03svQZGDkXPz/Q3zm+W84itDY+x81rEGQ6HfITkf0oXShLov6vDwA8Puhv75T62CW/SLc387h8bX11cF8bOiBESJ+9M4XHo+NPooA=";
    NSData *certificateData = [[NSData alloc] initWithBase64EncodedString:certificateBase64 options:0];
    SecCertificateRef certificate = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)certificateData);
    XCTAssertNotEqual(certificate, NULL);
    if (!certificate) {
        return;
    }
    SecPolicyRef policy = SecPolicyCreateSSL(true, CFSTR("tos-test.local"));
    SecTrustRef trust = NULL;
    OSStatus trustStatus = SecTrustCreateWithCertificates(certificate, policy, &trust);
    XCTAssertEqual(trustStatus, errSecSuccess);
    XCTAssertNotEqual(trust, NULL);
    if (trustStatus != errSecSuccess || !trust) {
        CFRelease(policy);
        CFRelease(certificate);
        return;
    }

    TOSTestServerTrustProtectionSpace *protectionSpace =
        [[TOSTestServerTrustProtectionSpace alloc] initWithHost:@"tos-test.local"
                                                          port:443
                                                      protocol:NSURLProtectionSpaceHTTPS
                                                         realm:nil
                                          authenticationMethod:NSURLAuthenticationMethodServerTrust];
    protectionSpace.tos_serverTrust = trust;
    NSURLAuthenticationChallenge *challenge =
        [[NSURLAuthenticationChallenge alloc] initWithProtectionSpace:protectionSpace
                                                   proposedCredential:nil
                                                 previousFailureCount:0
                                                      failureResponse:nil
                                                                error:nil
                                                               sender:(id<NSURLAuthenticationChallengeSender>)[NSNull null]];
    TOSNetworking *networking = [TOSNetworking new];
    TOSTestURLSessionTask *task = TOSTestCreateURLSessionTask();
    __block NSInteger completionCount = 0;
    __block NSURLSessionAuthChallengeDisposition observedDisposition = NSURLSessionAuthChallengeCancelAuthenticationChallenge;
    __block NSURLCredential *observedCredential = nil;

    [networking URLSession:(NSURLSession *)[NSNull null]
                      task:task
       didReceiveChallenge:challenge
         completionHandler:^(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential) {
        completionCount += 1;
        observedDisposition = disposition;
        observedCredential = credential;
    }];

    XCTAssertEqual(completionCount, 1);
    XCTAssertEqual(observedDisposition, NSURLSessionAuthChallengePerformDefaultHandling);
    XCTAssertNil(observedCredential);
    CFRelease(trust);
    CFRelease(policy);
    CFRelease(certificate);
}

- (void)testNetworkingPreservesExactTransferValidationErrorOnCompletion {
    NSError *sentinel = [NSError errorWithDomain:@"test.validation" code:42 userInfo:@{@"reason": @"range"}];
    TOSNetworkingRequestDelegate *delegate = [TOSNetworkingRequestDelegate new];
    delegate.taskCompletionSource = [TOSTaskCompletionSource taskCompletionSource];
    delegate.tos_responseValidator = ^NSError *(NSHTTPURLResponse *response) {
        return sentinel;
    };
    TOSTestURLSessionTask *task = TOSTestCreateURLSessionTask();
    task.tos_taskIdentifier = 8;
    task.tos_response = TOSTestHTTPResponse(200, @{});
    TOSNetworking *networking = [TOSNetworking new];
    networking.sessionDelagateManager = [TOSSynchronizedMutableDictionary new];
    [networking.sessionDelagateManager setObject:delegate forKey:@(task.taskIdentifier)];
    NSURLSession *unusedSession = (NSURLSession *)[NSNull null];
    [networking URLSession:unusedSession
                  dataTask:task
        didReceiveResponse:(NSHTTPURLResponse *)task.response
         completionHandler:^(NSURLSessionResponseDisposition value) {}];

    NSError *cancelled = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];
    [networking URLSession:unusedSession task:task didCompleteWithError:cancelled];
    [delegate.taskCompletionSource.task waitUntilFinished];

    XCTAssertEqual(delegate.taskCompletionSource.task.error, sentinel);
}

- (void)testLegacyNetworkingServerErrorDoesNotExposeRetryAfterHeader {
    TOSNetworkingRequestDelegate *delegate = [TOSNetworkingRequestDelegate new];
    delegate.taskCompletionSource = [TOSTaskCompletionSource taskCompletionSource];
    delegate.isHttpRequestNotSuccessResponse = YES;
    delegate.httpRequestNotSuccessResponseBody =
        [[@"{\"Code\":\"SlowDown\"}" dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    TOSTestURLSessionTask *task = TOSTestCreateURLSessionTask();
    task.tos_taskIdentifier = 18;
    task.tos_response = TOSTestHTTPResponse(429, @{@"Retry-After": @"7"});
    TOSNetworking *networking = [TOSNetworking new];
    networking.sessionDelagateManager = [TOSSynchronizedMutableDictionary new];
    [networking.sessionDelagateManager setObject:delegate forKey:@(task.taskIdentifier)];

    [networking URLSession:(NSURLSession *)[NSNull null] task:task didCompleteWithError:nil];
    [delegate.taskCompletionSource.task waitUntilFinished];

    NSError *error = delegate.taskCompletionSource.task.error;
    XCTAssertEqualObjects(error.domain, TOSServerErrorDomain);
    XCTAssertEqual(error.code, 429);
    XCTAssertNil(error.userInfo[@"Retry-After"]);
    XCTAssertEqualObjects(error.userInfo[@"Code"], @"SlowDown");
    XCTAssertEqual(error.userInfo.count, 1U);
}

- (void)testNetworkingDeliversRetryAfterToTransferObserverWithoutMutatingServerError {
    TOSNetworkingRequestDelegate *delegate = [TOSNetworkingRequestDelegate new];
    delegate.taskCompletionSource = [TOSTaskCompletionSource taskCompletionSource];
    delegate.isHttpRequestNotSuccessResponse = YES;
    delegate.httpRequestNotSuccessResponseBody =
        [[@"{\"Code\":\"SlowDown\"}" dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    __block NSHTTPURLResponse *observedResponse = nil;
    delegate.tos_responseObserver = ^(NSHTTPURLResponse *response) {
        observedResponse = response;
    };
    TOSTestURLSessionTask *task = TOSTestCreateURLSessionTask();
    task.tos_taskIdentifier = 19;
    task.tos_response = TOSTestHTTPResponse(429, @{@"rEtRy-AfTeR": @"11"});
    TOSNetworking *networking = [TOSNetworking new];
    networking.sessionDelagateManager = [TOSSynchronizedMutableDictionary new];
    [networking.sessionDelagateManager setObject:delegate forKey:@(task.taskIdentifier)];
    NSURLSession *unusedSession = (NSURLSession *)[NSNull null];

    [networking URLSession:unusedSession
                  dataTask:task
        didReceiveResponse:(NSHTTPURLResponse *)task.response
         completionHandler:^(NSURLSessionResponseDisposition value) {}];
    [networking URLSession:unusedSession task:task didCompleteWithError:nil];
    [delegate.taskCompletionSource.task waitUntilFinished];

    XCTAssertEqual(observedResponse, task.response);
    XCTAssertEqualObjects(observedResponse.allHeaderFields[@"rEtRy-AfTeR"], @"11");
    NSError *error = delegate.taskCompletionSource.task.error;
    XCTAssertEqualObjects(error.domain, TOSServerErrorDomain);
    XCTAssertEqual(error.code, 429);
    XCTAssertNil(error.userInfo[@"Retry-After"]);
    XCTAssertEqualObjects(error.userInfo[@"Code"], @"SlowDown");
    XCTAssertEqual(error.userInfo.count, 1U);
}

- (void)testNetworkingClassifiesRangedServerErrorBeforeRangeValidation {
    TOSNetworkingRequestDelegate *delegate = [TOSNetworkingRequestDelegate new];
    delegate.taskCompletionSource = [TOSTaskCompletionSource taskCompletionSource];
    delegate.tos_responseValidator = TOSTransferRangeResponseValidator(100, 199);
    __block NSHTTPURLResponse *observedResponse = nil;
    delegate.tos_responseObserver = ^(NSHTTPURLResponse *response) {
        observedResponse = response;
    };
    TOSTestURLSessionTask *task = TOSTestCreateURLSessionTask();
    task.tos_taskIdentifier = 28;
    task.tos_response = TOSTestHTTPResponse(429, @{@"Retry-After": @"7"});
    TOSNetworking *networking = [TOSNetworking new];
    networking.sessionDelagateManager = [TOSSynchronizedMutableDictionary new];
    [networking.sessionDelagateManager setObject:delegate forKey:@(task.taskIdentifier)];
    NSURLSession *unusedSession = (NSURLSession *)[NSNull null];
    __block NSURLSessionResponseDisposition disposition = NSURLSessionResponseCancel;

    [networking URLSession:unusedSession
                  dataTask:task
        didReceiveResponse:(NSHTTPURLResponse *)task.response
         completionHandler:^(NSURLSessionResponseDisposition value) {
        disposition = value;
    }];

    XCTAssertEqual(disposition, NSURLSessionResponseAllow);
    XCTAssertEqual(task.tos_cancelCount, 0);
    XCTAssertTrue(delegate.isHttpRequestNotSuccessResponse);
    XCTAssertNil(delegate.tos_responseValidationError);

    NSData *body = [@"{\"Code\":\"SlowDown\"}" dataUsingEncoding:NSUTF8StringEncoding];
    [networking URLSession:unusedSession dataTask:task didReceiveData:body];
    [networking URLSession:unusedSession task:task didCompleteWithError:nil];
    [delegate.taskCompletionSource.task waitUntilFinished];

    NSError *error = delegate.taskCompletionSource.task.error;
    XCTAssertEqualObjects(error.domain, TOSServerErrorDomain);
    XCTAssertEqual(error.code, 429);
    XCTAssertEqual(observedResponse, task.response);
    XCTAssertEqualObjects(observedResponse.allHeaderFields[@"Retry-After"], @"7");
    XCTAssertNil(error.userInfo[@"Retry-After"]);
    XCTAssertEqualObjects(error.userInfo[@"Code"], @"SlowDown");
}

- (void)testNetworkingUnregistersCompletedTaskFromTransferCancellation {
    TOSTransferNetworkCancellation *cancellation = [TOSTransferNetworkCancellation new];
    TOSTestURLSessionTask *task = TOSTestCreateURLSessionTask();
    task.tos_taskIdentifier = 9;
    task.tos_response = TOSTestHTTPResponse(204, @{});
    [cancellation registerTask:task];

    TOSNetworkingRequestDelegate *delegate = [TOSNetworkingRequestDelegate new];
    delegate.taskCompletionSource = [TOSTaskCompletionSource taskCompletionSource];
    delegate.tos_transferCancellation = cancellation;
    TOSNetworking *networking = [TOSNetworking new];
    networking.sessionDelagateManager = [TOSSynchronizedMutableDictionary new];
    [networking.sessionDelagateManager setObject:delegate forKey:@(task.taskIdentifier)];

    [networking URLSession:(NSURLSession *)[NSNull null] task:task didCompleteWithError:nil];
    [cancellation cancel];

    XCTAssertEqual(task.tos_cancelCount, 0);
    XCTAssertNil([networking.sessionDelagateManager objectForKey:@(task.taskIdentifier)]);
}

- (void)testClientDoesNotMutateHeadersWhenTransferMetadataIsAbsent {
    NSString *credentialValue = NSUUID.UUID.UUIDString;
    TOSCredential *credential = [[TOSCredential alloc] initWithAccessKey:credentialValue secretKey:credentialValue];
    TOSEndpoint *endpoint = [[TOSEndpoint alloc] initWithURLString:@"https://example.com" withRegion:@"test-region"];
    TOSClientConfiguration *configuration = [[TOSClientConfiguration alloc] initWithEndpoint:endpoint credential:credential];
    TOSClient *client = [[TOSClient alloc] initWithConfiguration:configuration];
    TOSNetworking *existingNetworking = [client valueForKey:@"networking"];
    [existingNetworking.session invalidateAndCancel];
    TOSTestCapturingNetworking *networking = [TOSTestCapturingNetworking new];
    [client setValue:networking forKey:@"networking"];

    TOSHeadObjectInput *input = [TOSHeadObjectInput new];
    input.tosBucket = @"valid-bucket";
    input.tosKey = @"object";
    input.tosIfMatch = @"\"legacy head etag\"";
    NSDictionary *originalHeaders = [input headerParamsDict];
    [client headObject:input];

    XCTAssertEqualObjects(networking.tos_capturedDelegate.headerParams, originalHeaders);
    XCTAssertEqualObjects([networking.tos_capturedDelegate.internalRequest valueForHTTPHeaderField:@"If-Match"],
                          @"%22legacy%20head%20etag%22");
    XCTAssertNil(networking.tos_capturedDelegate.tos_transferCancellation);
    XCTAssertNil(networking.tos_capturedDelegate.tos_responseValidator);
    XCTAssertNil(networking.tos_capturedDelegate.tos_responseObserver);
}

- (void)testClientPlumbsTransferMetadataOnlyForLowLevelTransferRequests {
    NSString *credentialValue = NSUUID.UUID.UUIDString;
    TOSCredential *credential = [[TOSCredential alloc] initWithAccessKey:credentialValue secretKey:credentialValue];
    TOSEndpoint *endpoint = [[TOSEndpoint alloc] initWithURLString:@"https://example.com" withRegion:@"test-region"];
    TOSClientConfiguration *configuration = [[TOSClientConfiguration alloc] initWithEndpoint:endpoint credential:credential];
    TOSClient *client = [[TOSClient alloc] initWithConfiguration:configuration];
    TOSNetworking *existingNetworking = [client valueForKey:@"networking"];
    [existingNetworking.session invalidateAndCancel];
    TOSTestCapturingNetworking *networking = [TOSTestCapturingNetworking new];
    [client setValue:networking forKey:@"networking"];

    TOSTransferNetworkCancellation *cancellation = [TOSTransferNetworkCancellation new];
    NSDictionary *transferHeaders = @{@"x-tos-traffic-limit": @"8192",
                                      @"x-tos-transfer-test": @"\"raw transfer value\""};
    NSError *sentinel = [NSError errorWithDomain:@"test.client.metadata" code:51 userInfo:nil];
    TOSTransferResponseValidator validator = ^NSError *(NSHTTPURLResponse *response) {
        return sentinel;
    };
    __block NSHTTPURLResponse *observedResponse = nil;
    TOSTransferResponseObserver observer = ^(NSHTTPURLResponse *response) {
        observedResponse = response;
    };
    void (^attachMetadata)(TOSInput *) = ^(TOSInput *input) {
        input.tos_transferCancellation = cancellation;
        input.tos_transferHeaders = transferHeaders;
        input.tos_responseValidator = validator;
        input.tos_responseObserver = observer;
    };
    void (^assertMetadata)(TOSInput *) = ^(TOSInput *input) {
        TOSNetworkingRequestDelegate *delegate = networking.tos_capturedDelegate;
        XCTAssertEqual(delegate.tos_transferCancellation, cancellation);
        XCTAssertEqualObjects(delegate.headerParams[@"x-tos-traffic-limit"], @"8192");
        XCTAssertEqualObjects([delegate.internalRequest valueForHTTPHeaderField:@"x-tos-transfer-test"],
                              @"\"raw transfer value\"");
        for (NSString *key in [input headerParamsDict]) {
            XCTAssertEqualObjects(delegate.headerParams[key], [input headerParamsDict][key]);
        }
        XCTAssertNotNil(delegate.tos_responseValidator);
        if (delegate.tos_responseValidator) {
            XCTAssertEqual(delegate.tos_responseValidator(TOSTestHTTPResponse(206, @{})), sentinel);
        }
        XCTAssertNotNil(delegate.tos_responseObserver);
        if (delegate.tos_responseObserver) {
            NSHTTPURLResponse *response = TOSTestHTTPResponse(429, @{@"Retry-After": @"3"});
            delegate.tos_responseObserver(response);
            XCTAssertEqual(observedResponse, response);
        }
    };

    TOSHeadObjectInput *head = [TOSHeadObjectInput new];
    head.tosBucket = @"valid-bucket";
    head.tosKey = @"object";
    head.tosIfMatch = @"\"head-etag\"";
    attachMetadata(head);
    [client headObject:head];
    assertMetadata(head);

    TOSGetObjectInput *get = [TOSGetObjectInput new];
    get.tosBucket = @"valid-bucket";
    get.tosKey = @"object";
    attachMetadata(get);
    [client getObject:get];
    assertMetadata(get);

    TOSCreateMultipartUploadInput *create = [TOSCreateMultipartUploadInput new];
    create.tosBucket = @"valid-bucket";
    create.tosKey = @"object";
    attachMetadata(create);
    [client createMultipartUpload:create];
    assertMetadata(create);

    TOSUploadPartFromStreamInput *upload = [TOSUploadPartFromStreamInput new];
    upload.tosBucket = @"valid-bucket";
    upload.tosKey = @"object";
    upload.tosUploadID = @"upload-id";
    upload.tosPartNumber = 1;
    upload.tosInputStream = [NSInputStream inputStreamWithData:[NSData data]];
    attachMetadata(upload);
    [client uploadPartFromStream:upload];
    assertMetadata(upload);

    TOSUploadPartCopyInput *uploadCopy = [TOSUploadPartCopyInput new];
    uploadCopy.tosBucket = @"valid-bucket";
    uploadCopy.tosKey = @"object";
    uploadCopy.tosUploadID = @"upload-id";
    uploadCopy.tosPartNumber = 1;
    uploadCopy.tosSrcBucket = @"source-bucket";
    uploadCopy.tosSrcKey = @"source-object";
    attachMetadata(uploadCopy);
    [client uploadPartCopy:uploadCopy];
    assertMetadata(uploadCopy);

    TOSCompleteMultipartUploadInput *complete = [TOSCompleteMultipartUploadInput new];
    complete.tosBucket = @"valid-bucket";
    complete.tosKey = @"object";
    complete.tosUploadID = @"upload-id";
    TOSUploadedPart *uploadedPart = [TOSUploadedPart new];
    uploadedPart.tosPartNumber = 1;
    uploadedPart.tosETag = @"etag";
    complete.tosParts = @[uploadedPart];
    attachMetadata(complete);
    [client completeMultipartUpload:complete];
    assertMetadata(complete);

    TOSAbortMultipartUploadInput *abort = [TOSAbortMultipartUploadInput new];
    abort.tosBucket = @"valid-bucket";
    abort.tosKey = @"object";
    abort.tosUploadID = @"upload-id";
    attachMetadata(abort);
    [client abortMultipartUpload:abort];
    assertMetadata(abort);

    TOSCopyObjectInput *copy = [TOSCopyObjectInput new];
    copy.tosBucket = @"valid-bucket";
    copy.tosKey = @"object";
    copy.tosSrcBucket = @"source-bucket";
    copy.tosSrcKey = @"source-object";
    attachMetadata(copy);
    [client copyObject:copy];
    assertMetadata(copy);
}

- (void)testTransferMetadataKeepsOrdinaryHeadersPercentEncoded {
    NSString *credentialValue = NSUUID.UUID.UUIDString;
    TOSCredential *credential = [[TOSCredential alloc] initWithAccessKey:credentialValue secretKey:credentialValue];
    TOSEndpoint *endpoint = [[TOSEndpoint alloc] initWithURLString:@"https://example.com" withRegion:@"test-region"];
    TOSClientConfiguration *configuration = [[TOSClientConfiguration alloc] initWithEndpoint:endpoint credential:credential];
    TOSClient *client = [[TOSClient alloc] initWithConfiguration:configuration];
    TOSNetworking *existingNetworking = [client valueForKey:@"networking"];
    [existingNetworking.session invalidateAndCancel];
    TOSTestCapturingNetworking *networking = [TOSTestCapturingNetworking new];
    [client setValue:networking forKey:@"networking"];

    TOSHeadObjectInput *input = [TOSHeadObjectInput new];
    input.tosBucket = @"valid-bucket";
    input.tosKey = @"object";
    input.tosIfMatch = @"\"中文 etag\"";
    input.tos_transferHeaders = @{
        @"x-tos-traffic-limit": @"8192",
        @"x-tos-transfer-test": @"\"raw transfer value\"",
    };
    [client headObject:input];

    XCTAssertEqualObjects([networking.tos_capturedDelegate.internalRequest valueForHTTPHeaderField:@"If-Match"],
                          @"%22%E4%B8%AD%E6%96%87%20etag%22");
    XCTAssertEqualObjects([networking.tos_capturedDelegate.internalRequest valueForHTTPHeaderField:@"x-tos-transfer-test"],
                          @"\"raw transfer value\"");
}

- (void)testExplicitTransferHeaderOverridesOnlyItsOrdinaryHeaderWithRawValue {
    NSString *credentialValue = NSUUID.UUID.UUIDString;
    TOSCredential *credential = [[TOSCredential alloc] initWithAccessKey:credentialValue
                                                               secretKey:credentialValue];
    TOSEndpoint *endpoint = [[TOSEndpoint alloc] initWithURLString:@"https://example.com"
                                                        withRegion:@"test-region"];
    TOSClientConfiguration *configuration = [[TOSClientConfiguration alloc]
                                              initWithEndpoint:endpoint
                                              credential:credential];
    TOSClient *client = [[TOSClient alloc] initWithConfiguration:configuration];
    TOSNetworking *existingNetworking = [client valueForKey:@"networking"];
    [existingNetworking.session invalidateAndCancel];
    TOSTestCapturingNetworking *networking = [TOSTestCapturingNetworking new];
    [client setValue:networking forKey:@"networking"];

    TOSHeadObjectInput *input = [TOSHeadObjectInput new];
    input.tosBucket = @"valid-bucket";
    input.tosKey = @"object";
    input.tosIfMatch = @"\"ordinary etag\"";
    input.tosIfNoneMatch = @"\"ordinary none match\"";
    input.tos_transferHeaders = @{@"If-Match": @"\"raw etag\""};
    [client headObject:input];

    XCTAssertEqualObjects([networking.tos_capturedDelegate.internalRequest
                           valueForHTTPHeaderField:@"If-Match"],
                          @"\"raw etag\"");
    XCTAssertEqualObjects([networking.tos_capturedDelegate.internalRequest
                           valueForHTTPHeaderField:@"If-None-Match"],
                          @"%22ordinary%20none%20match%22");
}

- (void)testLegacyUploadFileKeepsFiveTaskLimit {
    NSString *filePath = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTAssertTrue([[NSData dataWithBytes:"x" length:1] writeToFile:filePath atomically:YES]);
    NSString *credentialValue = NSUUID.UUID.UUIDString;
    TOSCredential *credential = [[TOSCredential alloc] initWithAccessKey:credentialValue
                                                               secretKey:credentialValue];
    TOSEndpoint *endpoint = [[TOSEndpoint alloc] initWithURLString:@"https://example.com"
                                                        withRegion:@"test-region"];
    TOSClientConfiguration *configuration = [[TOSClientConfiguration alloc] initWithEndpoint:endpoint
                                                                                   credential:credential];
    TOSTestLegacyUploadClient *client = [[TOSTestLegacyUploadClient alloc]
                                         initWithConfiguration:configuration];
    TOSUploadFileInput *input = [TOSUploadFileInput new];
    input.tosBucket = @"valid-bucket";
    input.tosKey = @"legacy-object";
    input.tosFilePath = filePath;
    input.tosPartSize = TOSMinPartSize - 1;
    input.tosTaskNum = 1001;

    TOSTask *task = [client uploadFile:input];
    [task waitUntilFinished];

    XCTAssertNotNil(task.error);
    XCTAssertEqual(TOSMaxTaskNum, 5);
    XCTAssertEqual(client.tos_validatedTaskNum, 5);
    XCTAssertEqual(input.tosTaskNum, 1001);
    TOSNetworking *networking = [client valueForKey:@"networking"];
    [networking.session invalidateAndCancel];
    [[NSFileManager defaultManager] removeItemAtPath:filePath error:nil];
}

- (void)testTransferSchedulerClampsConcurrencyAndNeverExceedsIt {
    NSArray<NSNumber *> *taskValues = @[@(-1), @0, @1, @5, @6, @1000, @1001];
    NSArray<NSNumber *> *expectedValues = @[@1, @1, @1, @5, @6, @1000, @1000];
    NSArray<NSNumber *> *items = @[@0, @1, @2, @3, @4, @5, @6, @7, @8, @9];

    for (NSInteger index = 0; index < taskValues.count; index++) {
        TOSTestTransferOperation *operation = [[TOSTestTransferOperation alloc]
                                               initWithTaskNum:taskValues[index].integerValue
                                               maxRetryCount:0
                                               cancelHook:nil
                                               progress:[[TOSTransferProgress alloc] initWithListener:nil]];
        operation.tos_items = items;
        XCTestExpectation *completion = [self expectationWithDescription:@"scheduler completion"];
        [operation.task continueWithBlock:^id(TOSTask *task) {
            [completion fulfill];
            return nil;
        }];

        [operation start];
        [self waitForExpectations:@[completion] timeout:2.0];

        XCTAssertNil(operation.task.error);
        NSInteger expectedTaskNum = expectedValues[index].integerValue;
        XCTAssertEqual(operation.effectiveTaskNum, expectedTaskNum);
        XCTAssertEqual(operation.tos_maxActiveAttempts,
                       MIN(expectedTaskNum, (NSInteger)items.count));
        XCTAssertEqual(operation.tos_startedAttempts, items.count);
    }
}

- (void)testTransferSchedulerStartsNoNewItemsAfterTerminalFailure {
    TOSTestTransferOperation *operation = [[TOSTestTransferOperation alloc]
                                           initWithTaskNum:3
                                           maxRetryCount:0
                                           cancelHook:nil
                                           progress:[[TOSTransferProgress alloc] initWithListener:nil]];
    operation.tos_items = @[@0, @1, @2, @3, @4, @5];
    operation.tos_failureIndex = 0;
    XCTestExpectation *completion = [self expectationWithDescription:@"terminal failure"];
    [operation.task continueWithBlock:^id(TOSTask *task) {
        [completion fulfill];
        return nil;
    }];

    [operation start];
    [self waitForExpectations:@[completion] timeout:2.0];

    XCTAssertNotNil(operation.task.error);
    XCTAssertEqual(operation.tos_startedAttempts, 3);
    XCTAssertEqual(operation.tos_activeAttempts, 0);
}

- (void)testTransferRetryClassifierMatchesIdempotentPolicy {
    NSError *timeout = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil];
    NSError *wrappedTimeout = [NSError errorWithDomain:TOSClientErrorDomain
                                                   code:TOSClientErrorCodeNetworkError
                                               userInfo:@{@"OriginErrorCode": [NSString stringWithFormat:@"%ld", (long)NSURLErrorTimedOut]}];
    NSError *wrappedConnectionLost = [NSError errorWithDomain:TOSClientErrorDomain
                                                          code:TOSClientErrorCodeNetworkError
                                                      userInfo:@{@"OriginErrorCode": [NSString stringWithFormat:@"%ld", (long)NSURLErrorNetworkConnectionLost]}];
    NSError *wrappedCancellation = [NSError errorWithDomain:TOSClientErrorDomain
                                                        code:TOSClientErrorCodeNetworkError
                                                    userInfo:@{@"OriginErrorCode": [NSString stringWithFormat:@"%ld", (long)NSURLErrorCancelled]}];
    XCTAssertTrue(TOSTransferShouldRetry(timeout, 0));
    XCTAssertTrue(TOSTransferShouldRetry(wrappedTimeout, 0));
    XCTAssertTrue(TOSTransferShouldRetry(wrappedConnectionLost, 0));
    XCTAssertTrue(TOSTransferShouldRetry(nil, 408));
    XCTAssertTrue(TOSTransferShouldRetry(nil, 429));
    XCTAssertTrue(TOSTransferShouldRetry(nil, 500));
    XCTAssertTrue(TOSTransferShouldRetry(nil, 599));
    XCTAssertFalse(TOSTransferShouldRetry(nil, 400));
    XCTAssertFalse(TOSTransferShouldRetry(nil, 403));
    XCTAssertFalse(TOSTransferShouldRetry([NSError errorWithDomain:NSURLErrorDomain
                                                               code:NSURLErrorCancelled
                                                           userInfo:nil], 0));
    XCTAssertFalse(TOSTransferShouldRetry(wrappedCancellation, 0));
}

- (void)testTransferRetryCountThreeMeansFourFreshAttempts {
    NSMutableArray<NSNumber *> *delays = [NSMutableArray array];
    TOSTransferAttemptResult *failure = [TOSTransferAttemptResult new];
    failure.error = [NSError errorWithDomain:TOSServerErrorDomain code:500 userInfo:nil];
    failure.statusCode = 500;
    TOSTestScriptedTransferOperation *operation = [[TOSTestScriptedTransferOperation alloc]
                                                   initWithTaskNum:1
                                                   maxRetryCount:3
                                                   cancelHook:nil
                                                   progress:[[TOSTransferProgress alloc] initWithListener:nil]
                                                   stateQueue:dispatch_queue_create("test.transfer.retry", DISPATCH_QUEUE_SERIAL)
                                                   randomSource:^double{ return 0.5; }
                                                   delayScheduler:^(NSTimeInterval delay, dispatch_block_t block) {
        @synchronized (delays) {
            [delays addObject:@(delay)];
        }
        block();
    }];
    operation.tos_scriptedResults = @[failure];
    XCTestExpectation *completion = [self expectationWithDescription:@"retry exhausted"];
    [operation.task continueWithBlock:^id(TOSTask *task) {
        [completion fulfill];
        return nil;
    }];

    [operation start];
    [self waitForExpectations:@[completion] timeout:2.0];

    XCTAssertEqual(operation.tos_attemptCount, 4);
    XCTAssertEqual(operation.tos_attemptMarkers.count, 4);
    XCTAssertEqual([NSSet setWithArray:operation.tos_attemptMarkers].count, 4);
    XCTAssertEqualObjects(delays, (@[@0.1, @0.2, @0.4]));
    XCTAssertEqual(operation.task.error, failure.error);
}

- (void)testTransferRetryAfterDominatesBackoffAndIsCapped {
    NSMutableArray<NSNumber *> *delays = [NSMutableArray array];
    TOSTransferAttemptResult *failure = [TOSTransferAttemptResult new];
    failure.error = [NSError errorWithDomain:TOSServerErrorDomain code:429 userInfo:nil];
    failure.statusCode = 429;
    failure.retryAfter = 2.5;
    TOSTransferAttemptResult *success = [TOSTransferAttemptResult new];
    success.value = @"ok";
    TOSTestScriptedTransferOperation *operation = [[TOSTestScriptedTransferOperation alloc]
                                                   initWithTaskNum:1
                                                   maxRetryCount:1
                                                   cancelHook:nil
                                                   progress:[[TOSTransferProgress alloc] initWithListener:nil]
                                                   stateQueue:dispatch_queue_create("test.transfer.retry-after", DISPATCH_QUEUE_SERIAL)
                                                   randomSource:^double{ return 0.5; }
                                                   delayScheduler:^(NSTimeInterval delay, dispatch_block_t block) {
        [delays addObject:@(delay)];
        block();
    }];
    operation.tos_scriptedResults = @[failure, success];
    XCTestExpectation *completion = [self expectationWithDescription:@"retry succeeds"];
    [operation.task continueWithBlock:^id(TOSTask *task) {
        [completion fulfill];
        return nil;
    }];

    [operation start];
    [self waitForExpectations:@[completion] timeout:2.0];

    XCTAssertNil(operation.task.error);
    XCTAssertEqualObjects(delays, (@[@2.5]));
    XCTAssertEqualWithAccuracy(TOSTransferRetryDelay(0, 120, 0.5), 60, DBL_EPSILON);
}

- (void)testTransferCancellationDuringBackoffPreventsAnotherAttempt {
    TOSCancelHook *cancelHook = [TOSCancelHook new];
    TOSTransferAttemptResult *failure = [TOSTransferAttemptResult new];
    failure.error = [NSError errorWithDomain:TOSServerErrorDomain code:500 userInfo:nil];
    failure.statusCode = 500;
    __block dispatch_block_t delayedBlock = nil;
    XCTestExpectation *backoffScheduled = [self expectationWithDescription:@"backoff scheduled"];
    TOSTestScriptedTransferOperation *operation = [[TOSTestScriptedTransferOperation alloc]
                                                   initWithTaskNum:1
                                                   maxRetryCount:3
                                                   cancelHook:cancelHook
                                                   progress:[[TOSTransferProgress alloc] initWithListener:nil]
                                                   stateQueue:dispatch_queue_create("test.transfer.cancel-backoff", DISPATCH_QUEUE_SERIAL)
                                                   randomSource:^double{ return 0.5; }
                                                   delayScheduler:^(NSTimeInterval delay, dispatch_block_t block) {
        delayedBlock = [block copy];
        [backoffScheduled fulfill];
    }];
    operation.tos_scriptedResults = @[failure];
    XCTestExpectation *completion = [self expectationWithDescription:@"cancel completion"];
    [operation.task continueWithBlock:^id(TOSTask *task) {
        [completion fulfill];
        return nil;
    }];

    [operation start];
    [self waitForExpectations:@[backoffScheduled] timeout:2.0];
    [cancelHook cancel:NO];
    [self waitForExpectations:@[completion] timeout:2.0];
    if (delayedBlock) {
        delayedBlock();
    }

    XCTAssertEqual(operation.tos_attemptCount, 1);
    XCTAssertEqualObjects(operation.task.error.domain, TOSClientErrorDomain);
    XCTAssertEqual(operation.task.error.code, 400);
}

- (void)testTransferTerminalFailureWaitsForStartedAttemptsToDrain {
    TOSTestControlledTransferOperation *operation = [[TOSTestControlledTransferOperation alloc]
                                                     initWithTaskNum:3
                                                     maxRetryCount:0
                                                     cancelHook:nil
                                                     progress:[[TOSTransferProgress alloc] initWithListener:nil]];
    operation.tos_items = @[@0, @1, @2, @3];
    XCTestExpectation *started = [self expectationWithDescription:@"three attempts started"];
    started.expectedFulfillmentCount = 3;
    operation.tos_attemptStarted = ^{
        [started fulfill];
    };
    XCTestExpectation *completion = [self expectationWithDescription:@"drained completion"];
    [operation.task continueWithBlock:^id(TOSTask *task) {
        [completion fulfill];
        return nil;
    }];
    [operation start];
    [self waitForExpectations:@[started] timeout:2.0];

    NSArray<TOSTaskCompletionSource<TOSTransferAttemptResult *> *> *sources = [operation tos_sourceSnapshot];
    NSError *sentinel = [NSError errorWithDomain:@"test.transfer.terminal" code:81 userInfo:nil];
    [sources[0] trySetError:sentinel];
    XCTestExpectation *failureObserved = [self expectationWithDescription:@"failure state queued"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        [failureObserved fulfill];
    });
    [self waitForExpectations:@[failureObserved] timeout:1.0];
    XCTAssertFalse(operation.task.completed);

    TOSTransferAttemptResult *success = [TOSTransferAttemptResult new];
    success.value = @"ok";
    [sources[1] trySetResult:success];
    [sources[2] trySetResult:success];
    [self waitForExpectations:@[completion] timeout:2.0];

    XCTAssertEqual(operation.task.error, sentinel);
    XCTAssertEqual([operation tos_sourceSnapshot].count, 3);
}

- (void)testTransferTerminalRacesResolveTaskAndProgressExactlyOnce {
    for (NSInteger iteration = 0; iteration < 100; iteration++) {
        NSLock *listenerLock = [NSLock new];
        __block NSInteger terminalEvents = 0;
        TOSTransferProgress *progress = [[TOSTransferProgress alloc] initWithListener:^(TOSDataTransferStatus *status) {
            if (status.tosType == TOSDataTransferSucceed || status.tosType == TOSDataTransferFailed) {
                [listenerLock lock];
                terminalEvents += 1;
                [listenerLock unlock];
            }
        }];
        TOSCancelHook *cancelHook = [TOSCancelHook new];
        TOSTestControlledTransferOperation *operation = [[TOSTestControlledTransferOperation alloc]
                                                         initWithTaskNum:1
                                                         maxRetryCount:0
                                                         cancelHook:cancelHook
                                                         progress:progress];
        operation.tos_items = @[@0];
        XCTestExpectation *started = [self expectationWithDescription:@"race attempt started"];
        operation.tos_attemptStarted = ^{
            [started fulfill];
        };
        dispatch_semaphore_t completion = dispatch_semaphore_create(0);
        [operation.task continueWithBlock:^id(TOSTask *task) {
            dispatch_semaphore_signal(completion);
            return nil;
        }];
        [operation start];
        [self waitForExpectations:@[started] timeout:2.0];

        TOSTaskCompletionSource<TOSTransferAttemptResult *> *source = [operation tos_sourceSnapshot].firstObject;
        TOSTransferAttemptResult *success = [TOSTransferAttemptResult new];
        success.value = @"ok";
        NSError *failure = [NSError errorWithDomain:@"test.transfer.race" code:iteration userInfo:nil];
        dispatch_group_t race = dispatch_group_create();
        dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
        dispatch_group_async(race, queue, ^{ [source trySetResult:success]; });
        dispatch_group_async(race, queue, ^{ [source trySetError:failure]; });
        dispatch_group_async(race, queue, ^{ [cancelHook cancel:NO]; });
        dispatch_group_async(race, queue, ^{ [cancelHook cancel:YES]; });
        dispatch_group_wait(race, DISPATCH_TIME_FOREVER);
        XCTAssertEqual(dispatch_semaphore_wait(completion,
                                               dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)),
                       0);
        [progress waitUntilIdle];

        [listenerLock lock];
        NSInteger observedTerminalEvents = terminalEvents;
        [listenerLock unlock];
        XCTAssertTrue(operation.task.completed);
        XCTAssertEqual(observedTerminalEvents, 1);
    }
}

@end
