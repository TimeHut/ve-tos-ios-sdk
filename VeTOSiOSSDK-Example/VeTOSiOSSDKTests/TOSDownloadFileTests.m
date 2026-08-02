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
#include <sys/stat.h>
#include <string.h>
#include <unistd.h>
#import "../../VeTOSiOSSDK/VeTOSiOSSDK/Transfer/TOSTransferCheckpoint.h"
#import "../../VeTOSiOSSDK/VeTOSiOSSDK/Transfer/TOSTransferIO.h"
#import "../../VeTOSiOSSDK/VeTOSiOSSDK/Transfer/TOSInput+TransferInternal.h"
#import "../../VeTOSiOSSDK/VeTOSiOSSDK/Transfer/TOSDownloadFileOperation.h"
#import <VeTOSiOSSDK/VeTOSiOSSDK.h>

@interface TOSTestDownloadClient : TOSClient
@property (nonatomic, assign) NSInteger tos_headCalls;
@property (nonatomic, assign) NSInteger tos_getCalls;
@property (nonatomic, strong) TOSTask *tos_headTask;
@property (nonatomic, strong) TOSHeadObjectOutput *tos_headOutput;
@property (nonatomic, copy) TOSTask *(^tos_headHandler)(TOSHeadObjectInput *input, NSInteger callIndex);
@property (nonatomic, strong) NSData *tos_objectData;
@property (nonatomic, strong) NSMutableArray<TOSGetObjectInput *> *tos_getInputs;
@property (nonatomic, copy) TOSTask *(^tos_getHandler)(TOSGetObjectInput *input, NSInteger callIndex);
@end

@implementation TOSTestDownloadClient

- (instancetype)init {
    self = [super init];
    if (self) {
        _tos_getInputs = [NSMutableArray array];
        _tos_objectData = [NSData data];
    }
    return self;
}

- (TOSTask *)headObject:(TOSHeadObjectInput *)request {
    NSInteger callIndex = self.tos_headCalls;
    self.tos_headCalls += 1;
    if (self.tos_headHandler) {
        TOSTask *task = self.tos_headHandler(request, callIndex);
        if (task) {
            return task;
        }
    }
    if (self.tos_headTask) {
        return self.tos_headTask;
    }
    TOSHeadObjectOutput *output = self.tos_headOutput ?: [TOSHeadObjectOutput new];
    return [TOSTask taskWithResult:output];
}

- (TOSTask *)getObject:(TOSGetObjectInput *)request {
    NSInteger callIndex = self.tos_getCalls;
    self.tos_getCalls += 1;
    [self.tos_getInputs addObject:request];
    if (self.tos_getHandler) {
        TOSTask *task = self.tos_getHandler(request, callIndex);
        if (task) {
            return task;
        }
    }

    long long start = 0;
    long long end = -1;
    NSString *range = request.tos_transferHeaders[@"Range"];
    if (sscanf(range.UTF8String, "bytes=%lld-%lld", &start, &end) != 2 ||
        start < 0 || end < start || end >= (long long)self.tos_objectData.length) {
        return [TOSTask taskWithError:[NSError errorWithDomain:TOSClientErrorDomain code:400 userInfo:nil]];
    }
    NSDictionary *headers = @{
        @"Content-Range": [NSString stringWithFormat:@"bytes %lld-%lld/%lu", start, end,
                            (unsigned long)self.tos_objectData.length],
        @"Content-Length": [NSString stringWithFormat:@"%lld", end - start + 1]
    };
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc]
                                   initWithURL:[NSURL URLWithString:@"https://example.com/object"]
                                   statusCode:206
                                   HTTPVersion:@"HTTP/1.1"
                                   headerFields:headers];
    NSError *validationError = request.tos_responseValidator ? request.tos_responseValidator(response) : nil;
    if (validationError) {
        return [TOSTask taskWithError:validationError];
    }
    NSData *data = [self.tos_objectData subdataWithRange:NSMakeRange((NSUInteger)start,
                                                                     (NSUInteger)(end - start + 1))];
    if (request.tosOnReceiveData) {
        request.tosOnReceiveData(data);
    }
    TOSGetObjectOutput *output = [TOSGetObjectOutput new];
    output.tosContentRange = headers[@"Content-Range"];
    output.tosContentLength = (int64_t)data.length;
    output.tosHeader = headers;
    return [TOSTask taskWithResult:output];
}

@end

@interface TOSDownloadFileOperation (TOSTestResumeWriter)
- (TOSDownloadFileWriter *)tos_resumeWriterForCheckpoint:(TOSDownloadCheckpoint *)checkpoint
                                                    error:(NSError **)error;
@end

@interface TOSTestResumeIdentityRacingDownloadOperation : TOSDownloadFileOperation
@property (nonatomic, copy) NSString *tos_replacementPath;
@property (nonatomic, strong) NSData *tos_replacementData;
@end

@implementation TOSTestResumeIdentityRacingDownloadOperation

- (TOSDownloadFileWriter *)tos_resumeWriterForCheckpoint:(TOSDownloadCheckpoint *)checkpoint
                                                    error:(NSError **)error {
    [[NSFileManager defaultManager] removeItemAtPath:self.tos_replacementPath error:nil];
    [self.tos_replacementData writeToFile:self.tos_replacementPath atomically:YES];
    return [super tos_resumeWriterForCheckpoint:checkpoint error:error];
}

@end

@interface TOSDownloadFileTests : XCTestCase
@property (nonatomic, copy) NSString *tos_root;
@end

@implementation TOSDownloadFileTests

- (void)setUp {
    [super setUp];
    self.tos_root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:self.tos_root
                                             withIntermediateDirectories:YES
                                                              attributes:nil
                                                                   error:nil]);
}

- (void)tearDown {
    [[NSFileManager defaultManager] removeItemAtPath:self.tos_root error:nil];
    [super tearDown];
}

- (TOSHeadObjectOutput *)tos_headOutputForData:(NSData *)data {
    TOSHeadObjectOutput *output = [TOSHeadObjectOutput new];
    output.tosContentLength = (int64_t)data.length;
    output.tosETag = @"head-etag";
    output.tosLastModified = [NSDate dateWithTimeIntervalSince1970:1234];
    output.tosHashCrc64ecma = 0;
    output.tosStatusCode = 200;
    output.tosRequestID = @"request-id";
    return output;
}

- (TOSDownloadFileInput *)tos_inputWithPath:(NSString *)path {
    TOSDownloadFileInput *input = [TOSDownloadFileInput new];
    input.tosBucket = @"valid-bucket";
    input.tosKey = @"object.bin";
    input.tosFilePath = path;
    input.tosPartSize = TOSMinPartSize;
    return input;
}

- (void)tos_waitForTask:(TOSTask *)task {
    XCTestExpectation *completion = [self expectationWithDescription:@"download completion"];
    [task continueWithBlock:^id(TOSTask *finishedTask) {
        [completion fulfill];
        return nil;
    }];
    [self waitForExpectations:@[completion] timeout:3.0];
}

- (NSString *)tos_messageForError:(NSError *)error {
    return error.userInfo[TOSErrorMessageTOKEN] ?: error.localizedDescription ?: @"";
}

- (NSHTTPURLResponse *)tos_responseWithStatusCode:(NSInteger)statusCode
                                           headers:(NSDictionary<NSString *, NSString *> *)headers {
    return [[NSHTTPURLResponse alloc]
            initWithURL:[NSURL URLWithString:@"https://example.com/object"]
            statusCode:statusCode
            HTTPVersion:@"HTTP/1.1"
            headerFields:headers];
}

- (TOSGetObjectOutput *)tos_getOutputWithHeaders:(NSDictionary<NSString *, NSString *> *)headers
                                      contentLength:(int64_t)contentLength {
    TOSGetObjectOutput *output = [TOSGetObjectOutput new];
    output.tosContentRange = headers[@"Content-Range"];
    output.tosContentLength = contentLength;
    output.tosHeader = headers;
    return output;
}

- (TOSDownloadCheckpoint *)tos_checkpointForInput:(TOSDownloadFileInput *)input
                                               head:(TOSHeadObjectOutput *)head {
    int64_t objectSize = head.tosSymlinkTargetSize > 0 ? head.tosSymlinkTargetSize : head.tosContentLength;
    NSError *partError = nil;
    NSArray<TOSTransferPart *> *parts = TOSDownloadParts(objectSize, input.tosPartSize, &partError);
    XCTAssertNotNil(parts);
    XCTAssertNil(partError);
    TOSDownloadCheckpoint *checkpoint = [TOSDownloadCheckpoint new];
    checkpoint.tos_schemaVersion = 1;
    checkpoint.tos_operation = @"download";
    checkpoint.tos_bucket = input.tosBucket;
    checkpoint.tos_key = input.tosKey;
    checkpoint.tos_partSize = input.tosPartSize;
    checkpoint.tos_checkpointPath = input.tosCheckpointFile;
    checkpoint.tos_parts = parts;
    checkpoint.tos_versionID = input.tosVersionID ?: @"";
    checkpoint.tos_ifMatch = input.tosIfMatch ?: @"";
    checkpoint.tos_ifModifiedSince = input.tosIfModifiedSince
        ? (int64_t)(input.tosIfModifiedSince.timeIntervalSince1970 * NSEC_PER_SEC) : 0;
    checkpoint.tos_ifNoneMatch = input.tosIfNoneMatch ?: @"";
    checkpoint.tos_ifUnmodifiedSince = input.tosIfUnmodifiedSince
        ? (int64_t)(input.tosIfUnmodifiedSince.timeIntervalSince1970 * NSEC_PER_SEC) : 0;
    checkpoint.tos_objectETag = head.tosETag ?: @"";
    checkpoint.tos_objectLastModified = head.tosLastModified
        ? (int64_t)(head.tosLastModified.timeIntervalSince1970 * NSEC_PER_SEC) : 0;
    checkpoint.tos_objectSize = objectSize;
    checkpoint.tos_objectCRC64 = head.tosHashCrc64ecma;
    checkpoint.tos_filePath = input.tosFilePath;
    checkpoint.tos_tempFilePath = input.tosTempFilePath;
    return checkpoint;
}

- (void)tos_writeCheckpoint:(TOSDownloadCheckpoint *)checkpoint {
    struct stat fileStat;
    if (checkpoint.tos_tempFilePath.length > 0 &&
        lstat(checkpoint.tos_tempFilePath.fileSystemRepresentation, &fileStat) == 0 &&
        S_ISREG(fileStat.st_mode)) {
        checkpoint.tos_hasTempFileIdentity = YES;
        checkpoint.tos_tempFileDevice = (uint64_t)fileStat.st_dev;
        checkpoint.tos_tempFileInode = (uint64_t)fileStat.st_ino;
    }
    NSError *error = nil;
    XCTAssertTrue([[[TOSTransferCheckpointStore alloc] init] writeCheckpoint:checkpoint error:&error]);
    XCTAssertNil(error);
}

- (void)testDownloadFilePublicSelectorAndSymlinkTargetSizeAreAvailable {
    XCTAssertTrue([TOSClient instancesRespondToSelector:@selector(downloadFile:)]);
    TOSHeadObjectOutput *output = [TOSHeadObjectOutput new];
    output.tosSymlinkTargetSize = 123;
    XCTAssertEqual(output.tosSymlinkTargetSize, 123);
}

- (void)testDownloadFileRejectsCheckpointAlreadyInUseBeforePartRequests {
    NSString *finalPath = [self.tos_root stringByAppendingPathComponent:@"lease-conflict.bin"];
    NSString *checkpointPath = [self.tos_root stringByAppendingPathComponent:@"lease-conflict.download"];
    NSError *leaseError = nil;
    TOSTransferCheckpointLease *lease =
        [TOSTransferCheckpointLease acquireCheckpointPath:checkpointPath error:&leaseError];
    XCTAssertNotNil(lease);
    XCTAssertNil(leaseError);

    NSData *data = [@"x" dataUsingEncoding:NSUTF8StringEncoding];
    TOSDownloadFileInput *input = [self tos_inputWithPath:finalPath];
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = checkpointPath;
    TOSTestDownloadClient *client = [TOSTestDownloadClient new];
    client.tos_objectData = data;
    client.tos_headOutput = [self tos_headOutputForData:data];

    TOSTask *task = [client downloadFile:input];
    [self tos_waitForTask:task];

    XCTAssertNotNil(task.error);
    XCTAssertEqual(client.tos_headCalls, 1);
    XCTAssertEqual(client.tos_getCalls, 0);
    [lease invalidate];
}

- (void)testHeadParserReadsSymlinkTargetSizeHeader {
    TOSNetworkingResponseParser *parser = [[TOSNetworkingResponseParser alloc]
                                            initWithOperationType:TOSOperationTypeHeadObject];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc]
                                   initWithURL:[NSURL URLWithString:@"https://example.com/object"]
                                   statusCode:200
                                   HTTPVersion:@"HTTP/1.1"
                                   headerFields:@{@"X-Tos-Symlink-Target-Size": @"456"}];
    [parser consumeNetworkingResponse:response];
    TOSHeadObjectOutput *output = [parser buildOutputObject:nil];

    XCTAssertEqual(output.tosSymlinkTargetSize, 456);
}

- (void)testDownloadOperationSnapshotsInputBeforeStart {
    TOSDownloadFileInput *input = [self tos_inputWithPath:[self.tos_root stringByAppendingPathComponent:@"snapshot.bin"]];
    input.tosIfMatch = @"before";
    TOSDownloadFileOperation *operation = [[TOSDownloadFileOperation alloc]
                                            initWithClient:[TOSTestDownloadClient new]
                                            request:input];

    input.tosBucket = @"changed";
    input.tosFilePath = @"/changed";
    input.tosIfMatch = @"after";

    XCTAssertEqualObjects(operation.request.tosBucket, @"valid-bucket");
    XCTAssertTrue([operation.request.tosFilePath hasSuffix:@"snapshot.bin"]);
    XCTAssertEqualObjects(operation.request.tosIfMatch, @"before");
}

- (void)testDownloadHeadFailureDoesNotCreateOrModifyFiles {
    NSString *path = [self.tos_root stringByAppendingPathComponent:@"head-failure.bin"];
    NSData *original = [@"original" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertTrue([original writeToFile:path atomically:YES]);
    TOSTestDownloadClient *client = [TOSTestDownloadClient new];
    client.tos_headTask = [TOSTask taskWithError:[NSError errorWithDomain:TOSServerErrorDomain code:404 userInfo:nil]];

    TOSTask *task = [client downloadFile:[self tos_inputWithPath:path]];
    [self tos_waitForTask:task];

    XCTAssertEqual(task.error.code, 404);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:path], original);
    XCTAssertEqual(client.tos_getCalls, 0);
}

- (void)testDownloadCreatesNestedParentAndReplacesFinalOnlyAfterPartSuccess {
    NSData *objectData = [@"new-data" dataUsingEncoding:NSUTF8StringEncoding];
    NSString *path = [self.tos_root stringByAppendingPathComponent:@"nested/final.bin"];
    TOSTestDownloadClient *client = [TOSTestDownloadClient new];
    client.tos_objectData = objectData;
    client.tos_headOutput = [self tos_headOutputForData:objectData];

    TOSTask *task = [client downloadFile:[self tos_inputWithPath:path]];
    [self tos_waitForTask:task];

    XCTAssertNil(task.error);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:path], objectData);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:path.stringByDeletingLastPathComponent]);
}

- (void)testDownloadDirectoryAppendsNestedObjectKeyWithoutEscapingDirectory {
    NSString *directory = [self.tos_root stringByAppendingPathComponent:@"downloads"];
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:directory
                                             withIntermediateDirectories:NO
                                                              attributes:nil
                                                                   error:nil]);
    TOSDownloadFileInput *input = [self tos_inputWithPath:directory];
    input.tosKey = @"nested/object.bin";
    TOSTestDownloadClient *client = [TOSTestDownloadClient new];
    client.tos_headOutput = [self tos_headOutputForData:[NSData data]];

    TOSTask *task = [client downloadFile:input];
    [self tos_waitForTask:task];

    NSString *expected = [directory stringByAppendingPathComponent:@"nested/object.bin"];
    XCTAssertNil(task.error);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:expected]);

    TOSDownloadFileInput *traversal = [self tos_inputWithPath:directory];
    traversal.tosKey = @"../escape.bin";
    TOSTask *traversalTask = [client downloadFile:traversal];
    [self tos_waitForTask:traversalTask];
    XCTAssertTrue([[self tos_messageForError:traversalTask.error] containsString:@"path"] ||
                  [[self tos_messageForError:traversalTask.error] containsString:@"路径"]);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:[self.tos_root stringByAppendingPathComponent:@"escape.bin"]]);
}

- (void)testDownloadDirectoryRejectsIntermediateSymlinkWithoutWritingOutsideRoot {
    NSString *directory = [self.tos_root stringByAppendingPathComponent:@"downloads"];
    NSString *outside = [self.tos_root stringByAppendingPathComponent:@"outside"];
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:directory
                                             withIntermediateDirectories:NO
                                                              attributes:nil
                                                                   error:nil]);
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:outside
                                             withIntermediateDirectories:NO
                                                              attributes:nil
                                                                   error:nil]);
    NSString *link = [directory stringByAppendingPathComponent:@"link"];
    XCTAssertEqual(symlink(outside.fileSystemRepresentation, link.fileSystemRepresentation), 0);

    NSData *objectData = [@"must-not-escape" dataUsingEncoding:NSUTF8StringEncoding];
    TOSDownloadFileInput *input = [self tos_inputWithPath:directory];
    input.tosKey = @"link/escaped.bin";
    TOSTestDownloadClient *client = [TOSTestDownloadClient new];
    client.tos_objectData = objectData;
    client.tos_headOutput = [self tos_headOutputForData:objectData];

    TOSTask *task = [client downloadFile:input];
    [self tos_waitForTask:task];

    XCTAssertNotNil(task.error);
    XCTAssertEqual(client.tos_getCalls, 0);
    XCTAssertFalse([[NSFileManager defaultManager]
                    fileExistsAtPath:[outside stringByAppendingPathComponent:@"escaped.bin"]]);
}

- (void)testDownloadRejectsCustomTempPathOnDifferentFilesystem {
    NSString *path = [self.tos_root stringByAppendingPathComponent:@"different-device.bin"];
    TOSDownloadFileInput *input = [self tos_inputWithPath:path];
    input.tosTempFilePath = [@"/dev" stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    TOSTestDownloadClient *client = [TOSTestDownloadClient new];
    client.tos_headOutput = [self tos_headOutputForData:[@"x" dataUsingEncoding:NSUTF8StringEncoding]];

    TOSTask *task = [client downloadFile:input];
    [self tos_waitForTask:task];

    XCTAssertTrue([[self tos_messageForError:task.error] containsString:@"file system"] ||
                  [[self tos_messageForError:task.error] containsString:@"文件系统"]);
    XCTAssertEqual(client.tos_getCalls, 0);
}

- (void)testDownloadUsesSymlinkTargetSizeAndHandlesEmptyObject {
    NSData *targetData = [@"abc" dataUsingEncoding:NSUTF8StringEncoding];
    NSString *symlinkPath = [self.tos_root stringByAppendingPathComponent:@"symlink.bin"];
    TOSTestDownloadClient *client = [TOSTestDownloadClient new];
    client.tos_objectData = targetData;
    client.tos_headOutput = [self tos_headOutputForData:[NSData data]];
    client.tos_headOutput.tosSymlinkTargetSize = (int64_t)targetData.length;

    TOSTask *symlinkTask = [client downloadFile:[self tos_inputWithPath:symlinkPath]];
    [self tos_waitForTask:symlinkTask];

    XCTAssertNil(symlinkTask.error);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:symlinkPath], targetData);
    XCTAssertEqualObjects(client.tos_getInputs.firstObject.tos_transferHeaders[@"Range"], @"bytes=0-2");

    NSString *emptyPath = [self.tos_root stringByAppendingPathComponent:@"empty.bin"];
    NSData *old = [@"old" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertTrue([old writeToFile:emptyPath atomically:YES]);
    TOSTestDownloadClient *emptyClient = [TOSTestDownloadClient new];
    emptyClient.tos_headOutput = [self tos_headOutputForData:[NSData data]];
    TOSTask *emptyTask = [emptyClient downloadFile:[self tos_inputWithPath:emptyPath]];
    [self tos_waitForTask:emptyTask];

    XCTAssertNil(emptyTask.error);
    XCTAssertEqual([NSData dataWithContentsOfFile:emptyPath].length, 0);
    XCTAssertEqual(emptyClient.tos_getCalls, 0);
}

- (void)testDownloadRejectsSSEBeforeHeadAndClampsTaskCountToResumableLimit {
    NSString *path = [self.tos_root stringByAppendingPathComponent:@"sse.bin"];
    TOSDownloadFileInput *sseInput = [self tos_inputWithPath:path];
    sseInput.tosSSECAlgorithm = @"AES256";
    TOSTestDownloadClient *sseClient = [TOSTestDownloadClient new];
    TOSTask *sseTask = [sseClient downloadFile:sseInput];
    [self tos_waitForTask:sseTask];
    XCTAssertTrue([[self tos_messageForError:sseTask.error] containsString:@"SSE"]);
    XCTAssertEqual(sseClient.tos_headCalls, 0);

    TOSDownloadFileInput *clampedInput = [self tos_inputWithPath:path];
    clampedInput.tosTaskNum = 1001;
    TOSTestDownloadClient *client = [TOSTestDownloadClient new];
    client.tos_headOutput = [self tos_headOutputForData:[NSData data]];
    TOSDownloadFileOperation *operation = [[TOSDownloadFileOperation alloc] initWithClient:client request:clampedInput];
    [operation start];
    [self tos_waitForTask:operation.task];
    XCTAssertEqual(operation.request.tosTaskNum, 1000);
    XCTAssertEqual(clampedInput.tosTaskNum, 1001);
}

- (void)testDownloadStartsSixPartsWhenTaskNumIsSix {
    NSString *path = [self.tos_root stringByAppendingPathComponent:@"six-parts.bin"];
    TOSDownloadFileInput *input = [self tos_inputWithPath:path];
    input.tosTaskNum = 6;
    input.tosMaxRetryCount = 0;
    TOSTestDownloadClient *client = [TOSTestDownloadClient new];
    client.tos_headOutput = [self tos_headOutputForData:[NSData data]];
    client.tos_headOutput.tosContentLength = TOSMinPartSize * 5 + 1;
    NSMutableArray<TOSTaskCompletionSource *> *sources = [NSMutableArray array];
    XCTestExpectation *initialWave = [self expectationWithDescription:@"five download parts started"];
    initialWave.expectedFulfillmentCount = 5;
    XCTestExpectation *sixthStarted = [self expectationWithDescription:@"sixth download part started"];
    client.tos_getHandler = ^TOSTask *(TOSGetObjectInput *getInput, NSInteger callIndex) {
        TOSTaskCompletionSource *source = [TOSTaskCompletionSource taskCompletionSource];
        [sources addObject:source];
        if (callIndex < 5) {
            [initialWave fulfill];
        } else {
            [sixthStarted fulfill];
        }
        return source.task;
    };
    TOSDownloadFileOperation *operation = [[TOSDownloadFileOperation alloc] initWithClient:client
                                                                                   request:input];

    [operation start];
    [self waitForExpectations:@[initialWave] timeout:2.0];
    XCTAssertEqual(client.tos_getCalls, 5);

    TOSGetObjectInput *firstInput = client.tos_getInputs.firstObject;
    NSDictionary *headers = @{
        @"Content-Range": [NSString stringWithFormat:@"bytes 0-%lld/%lld",
                           TOSMinPartSize - 1, TOSMinPartSize * 5 + 1],
        @"Content-Length": [NSString stringWithFormat:@"%lld", TOSMinPartSize]
    };
    NSError *validationError =
        firstInput.tos_responseValidator([self tos_responseWithStatusCode:206 headers:headers]);
    XCTAssertNil(validationError);
    firstInput.tosOnReceiveData([NSMutableData dataWithLength:(NSUInteger)TOSMinPartSize]);
    [sources.firstObject setResult:[self tos_getOutputWithHeaders:headers
                                                    contentLength:TOSMinPartSize]];
    [self waitForExpectations:@[sixthStarted] timeout:2.0];

    XCTAssertEqual(client.tos_getCalls, 6);
    XCTAssertEqual(operation.request.tosTaskNum, 6);
    for (TOSTaskCompletionSource *source in sources) {
        [source trySetError:[NSError errorWithDomain:TOSServerErrorDomain code:400 userInfo:nil]];
    }
    [self tos_waitForTask:operation.task];
    XCTAssertNotNil(operation.task.error);
}

- (void)testDownloadResumesOnlyPendingRangesAndUsesHeadETagAsIfMatch {
    NSMutableData *objectData = [NSMutableData dataWithLength:(NSUInteger)(TOSMinPartSize + 3)];
    memset(objectData.mutableBytes, 'a', objectData.length);
    NSString *finalPath = [self.tos_root stringByAppendingPathComponent:@"resume.bin"];
    NSString *tempPath = [self.tos_root stringByAppendingPathComponent:@"resume.bin.temp.fixed"];
    NSString *checkpointPath = [self.tos_root stringByAppendingPathComponent:@"resume.download"];
    TOSDownloadFileInput *input = [self tos_inputWithPath:finalPath];
    input.tosTempFilePath = tempPath;
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = checkpointPath;
    TOSHeadObjectOutput *head = [self tos_headOutputForData:objectData];
    TOSDownloadCheckpoint *checkpoint = [self tos_checkpointForInput:input head:head];
    TOSTransferPart *first = checkpoint.tos_parts.firstObject;
    first.tos_completed = YES;
    first.tos_crc64 = TOSTransferCRC64(0, objectData.bytes, (size_t)first.tos_size);
    XCTAssertTrue([objectData writeToFile:tempPath atomically:YES]);
    [self tos_writeCheckpoint:checkpoint];
    TOSTestDownloadClient *client = [TOSTestDownloadClient new];
    client.tos_objectData = objectData;
    client.tos_headOutput = head;

    TOSTask *task = [client downloadFile:input];
    [self tos_waitForTask:task];

    XCTAssertNil(task.error);
    XCTAssertEqual(client.tos_getCalls, 1);
    NSString *expectedRange = [NSString stringWithFormat:@"bytes=%lld-%lld",
                               TOSMinPartSize, TOSMinPartSize + 2];
    XCTAssertEqualObjects(client.tos_getInputs.firstObject.tos_transferHeaders[@"Range"],
                          expectedRange);
    XCTAssertEqualObjects(client.tos_getInputs.firstObject.tosIfMatch, @"head-etag");
    XCTAssertEqualObjects(client.tos_getInputs.firstObject.tos_transferHeaders[@"If-Match"],
                          @"head-etag");
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:finalPath], objectData);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:checkpointPath]);
}

- (void)testDownloadResumeRejectsReplacementBetweenCheckpointValidationAndOpen {
    NSMutableData *objectData = [NSMutableData dataWithLength:(NSUInteger)(TOSMinPartSize + 3)];
    memset(objectData.mutableBytes, 'a', objectData.length);
    NSMutableData *replacement = [NSMutableData dataWithLength:objectData.length];
    memset(replacement.mutableBytes, 'b', replacement.length);
    NSString *finalPath = [self.tos_root stringByAppendingPathComponent:@"resume-race.bin"];
    NSString *tempPath = [self.tos_root stringByAppendingPathComponent:@"resume-race.bin.temp.fixed"];
    NSString *checkpointPath = [self.tos_root stringByAppendingPathComponent:@"resume-race.download"];
    TOSDownloadFileInput *input = [self tos_inputWithPath:finalPath];
    input.tosTempFilePath = tempPath;
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = checkpointPath;
    TOSHeadObjectOutput *head = [self tos_headOutputForData:objectData];
    TOSDownloadCheckpoint *checkpoint = [self tos_checkpointForInput:input head:head];
    TOSTransferPart *first = checkpoint.tos_parts.firstObject;
    first.tos_completed = YES;
    first.tos_crc64 = TOSTransferCRC64(0, objectData.bytes, (size_t)first.tos_size);
    XCTAssertTrue([objectData writeToFile:tempPath atomically:YES]);
    [self tos_writeCheckpoint:checkpoint];
    TOSTestDownloadClient *client = [TOSTestDownloadClient new];
    client.tos_objectData = objectData;
    client.tos_headOutput = head;
    TOSTestResumeIdentityRacingDownloadOperation *operation =
        [[TOSTestResumeIdentityRacingDownloadOperation alloc] initWithClient:client request:input];
    operation.tos_replacementPath = tempPath;
    operation.tos_replacementData = replacement;

    [operation start];
    [self tos_waitForTask:operation.task];

    XCTAssertNotNil(operation.task.error);
    XCTAssertEqual(client.tos_getCalls, 0);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:tempPath], replacement);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:finalPath]);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:checkpointPath]);
}

- (void)testDownloadCheckpointPreservesUserConditionsAndMissingTempInvalidatesResume {
    NSData *objectData = [@"condition" dataUsingEncoding:NSUTF8StringEncoding];
    NSString *finalPath = [self.tos_root stringByAppendingPathComponent:@"condition.bin"];
    NSString *tempPath = [self.tos_root stringByAppendingPathComponent:@"condition.bin.temp.fixed"];
    NSString *checkpointPath = [self.tos_root stringByAppendingPathComponent:@"condition.download"];
    TOSDownloadFileInput *input = [self tos_inputWithPath:finalPath];
    input.tosTempFilePath = tempPath;
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = checkpointPath;
    input.tosIfMatch = @"user-etag";
    input.tosIfNoneMatch = @"none";
    input.tosIfModifiedSince = [NSDate dateWithTimeIntervalSince1970:100];
    input.tosIfUnmodifiedSince = [NSDate dateWithTimeIntervalSince1970:200];
    TOSHeadObjectOutput *head = [self tos_headOutputForData:objectData];
    TOSDownloadCheckpoint *checkpoint = [self tos_checkpointForInput:input head:head];
    [self tos_writeCheckpoint:checkpoint];
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:tempPath]);
    TOSTestDownloadClient *client = [TOSTestDownloadClient new];
    client.tos_objectData = objectData;
    client.tos_headOutput = head;

    TOSTask *task = [client downloadFile:input];
    [self tos_waitForTask:task];

    XCTAssertNil(task.error);
    XCTAssertEqual(client.tos_getCalls, 1);
    TOSGetObjectInput *getInput = client.tos_getInputs.firstObject;
    XCTAssertEqualObjects(getInput.tosIfMatch, @"user-etag");
    XCTAssertEqualObjects(getInput.tosIfNoneMatch, @"none");
    XCTAssertEqualObjects(getInput.tosIfModifiedSince, input.tosIfModifiedSince);
    XCTAssertEqualObjects(getInput.tosIfUnmodifiedSince, input.tosIfUnmodifiedSince);
    XCTAssertEqualObjects(getInput.tos_transferHeaders[@"If-Match"], @"user-etag");
    XCTAssertEqualObjects(getInput.tos_transferHeaders[@"If-None-Match"], @"none");
}

- (void)testDownloadCheckpointWithChangedObjectIdentityIsRedownloaded {
    NSData *oldData = [@"old-object" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *newData = [@"new-object" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertEqual(oldData.length, newData.length);
    NSString *finalPath = [self.tos_root stringByAppendingPathComponent:@"changed-object.bin"];
    NSString *tempPath = [finalPath stringByAppendingString:@".temp.fixed"];
    NSString *checkpointPath = [finalPath stringByAppendingString:@".download"];
    TOSDownloadFileInput *input = [self tos_inputWithPath:finalPath];
    input.tosTempFilePath = tempPath;
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = checkpointPath;
    TOSHeadObjectOutput *oldHead = [self tos_headOutputForData:oldData];
    oldHead.tosETag = @"old-etag";
    TOSDownloadCheckpoint *checkpoint = [self tos_checkpointForInput:input head:oldHead];
    checkpoint.tos_parts.firstObject.tos_completed = YES;
    checkpoint.tos_parts.firstObject.tos_crc64 = TOSTransferCRC64(0, oldData.bytes, oldData.length);
    XCTAssertTrue([oldData writeToFile:tempPath atomically:YES]);
    [self tos_writeCheckpoint:checkpoint];

    TOSTestDownloadClient *client = [TOSTestDownloadClient new];
    client.tos_objectData = newData;
    client.tos_headOutput = [self tos_headOutputForData:newData];
    client.tos_headOutput.tosETag = @"new-etag";

    TOSTask *task = [client downloadFile:input];
    [self tos_waitForTask:task];

    XCTAssertNil(task.error);
    XCTAssertEqual(client.tos_getCalls, 1);
    XCTAssertEqualObjects(client.tos_getInputs.firstObject.tosIfMatch, @"new-etag");
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:finalPath], newData);
}

- (void)testDownloadStaleCheckpointDoesNotDeleteReplacedOwnedTempFile {
    NSData *oldData = [@"old-object" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *replacement = [@"keep-local" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *newData = [@"new-object" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertEqual(oldData.length, replacement.length);
    XCTAssertEqual(oldData.length, newData.length);
    NSString *finalPath = [self.tos_root stringByAppendingPathComponent:@"stale-owned-temp.bin"];
    NSString *oldTempPath = [NSString stringWithFormat:@"%@.temp.%@", finalPath, NSUUID.UUID.UUIDString];
    NSString *checkpointPath = [finalPath stringByAppendingString:@".download"];
    TOSDownloadFileInput *checkpointInput = [self tos_inputWithPath:finalPath];
    checkpointInput.tosTempFilePath = oldTempPath;
    checkpointInput.tosEnableCheckpoint = YES;
    checkpointInput.tosCheckpointFile = checkpointPath;
    TOSHeadObjectOutput *oldHead = [self tos_headOutputForData:oldData];
    oldHead.tosETag = @"old-etag";
    TOSDownloadCheckpoint *checkpoint = [self tos_checkpointForInput:checkpointInput head:oldHead];
    XCTAssertTrue([oldData writeToFile:oldTempPath atomically:YES]);
    [self tos_writeCheckpoint:checkpoint];

    XCTAssertTrue([[NSFileManager defaultManager] removeItemAtPath:oldTempPath error:nil]);
    XCTAssertTrue([replacement writeToFile:oldTempPath atomically:YES]);
    TOSDownloadFileInput *input = [self tos_inputWithPath:finalPath];
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = checkpointPath;
    TOSTestDownloadClient *client = [TOSTestDownloadClient new];
    client.tos_objectData = newData;
    client.tos_headOutput = [self tos_headOutputForData:newData];
    client.tos_headOutput.tosETag = @"new-etag";

    TOSTask *task = [client downloadFile:input];
    [self tos_waitForTask:task];

    XCTAssertNil(task.error);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:finalPath], newData);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:oldTempPath], replacement);
    XCTAssertNotEqualObjects(input.tosTempFilePath, oldTempPath);
}

- (void)testDownloadRejectsCheckpointOwnedByAnotherTargetWithoutDeletingState {
    NSData *objectData = [@"foreign-object" dataUsingEncoding:NSUTF8StringEncoding];
    NSString *finalPath = [self.tos_root stringByAppendingPathComponent:@"foreign-target.bin"];
    NSString *tempPath = [finalPath stringByAppendingString:@".temp.fixed"];
    NSString *checkpointPath = [finalPath stringByAppendingString:@".download"];
    TOSDownloadFileInput *foreignInput = [self tos_inputWithPath:finalPath];
    foreignInput.tosBucket = @"another-valid-bucket";
    foreignInput.tosTempFilePath = tempPath;
    foreignInput.tosEnableCheckpoint = YES;
    foreignInput.tosCheckpointFile = checkpointPath;
    TOSHeadObjectOutput *head = [self tos_headOutputForData:objectData];
    TOSDownloadCheckpoint *checkpoint = [self tos_checkpointForInput:foreignInput head:head];
    XCTAssertTrue([objectData writeToFile:tempPath atomically:YES]);
    [self tos_writeCheckpoint:checkpoint];
    NSData *checkpointData = [NSData dataWithContentsOfFile:checkpointPath];

    TOSDownloadFileInput *input = [self tos_inputWithPath:finalPath];
    input.tosTempFilePath = tempPath;
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = checkpointPath;
    TOSTestDownloadClient *client = [TOSTestDownloadClient new];
    client.tos_objectData = objectData;
    client.tos_headOutput = head;

    TOSTask *task = [client downloadFile:input];
    [self tos_waitForTask:task];

    XCTAssertNotNil(task.error);
    XCTAssertTrue([[self tos_messageForError:task.error] containsString:@"其他下载目标"]);
    XCTAssertEqual(client.tos_getCalls, 0);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:checkpointPath], checkpointData);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:tempPath], objectData);
}

- (void)testDownloadMalformedCheckpointNeverDeletesClaimedUnrelatedPath {
    NSString *finalPath = [self.tos_root stringByAppendingPathComponent:@"malformed.bin"];
    NSString *checkpointPath = [self.tos_root stringByAppendingPathComponent:@"malformed.download"];
    NSString *unrelatedPath = [self.tos_root stringByAppendingPathComponent:@"unrelated.keep"];
    NSData *unrelated = [@"keep" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertTrue([unrelated writeToFile:unrelatedPath atomically:YES]);
    NSDictionary *malformed = @{
        @"schema_version": @1,
        @"operation": @"download",
        @"temp_file_path": unrelatedPath
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:malformed options:0 error:nil];
    XCTAssertTrue([json writeToFile:checkpointPath atomically:YES]);
    TOSDownloadFileInput *input = [self tos_inputWithPath:finalPath];
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = checkpointPath;
    TOSTestDownloadClient *client = [TOSTestDownloadClient new];
    client.tos_headOutput = [self tos_headOutputForData:[@"x" dataUsingEncoding:NSUTF8StringEncoding]];

    TOSTask *task = [client downloadFile:input];
    [self tos_waitForTask:task];

    XCTAssertNotNil(task.error);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:unrelatedPath], unrelated);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:checkpointPath]);
    XCTAssertEqual(client.tos_getCalls, 0);
}

- (void)testDownloadRejectsInvalidRangeResponsesAndPreservesResumableState {
    NSArray<NSDictionary *> *cases = @[
        @{@"name": @"status-200", @"status": @200,
          @"headers": @{@"Content-Length": @"4"}},
        @{@"name": @"missing-content-range", @"status": @206,
          @"headers": @{@"Content-Length": @"4"}},
        @{@"name": @"mismatched-content-range", @"status": @206,
          @"headers": @{@"Content-Range": @"bytes 1-4/5", @"Content-Length": @"4"}}
    ];
    NSData *original = [@"old" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *objectData = [@"data" dataUsingEncoding:NSUTF8StringEncoding];

    for (NSDictionary *testCase in cases) {
        NSString *name = testCase[@"name"];
        NSString *finalPath = [self.tos_root stringByAppendingPathComponent:[name stringByAppendingString:@".bin"]];
        NSString *tempPath = [finalPath stringByAppendingString:@".temp.fixed"];
        NSString *checkpointPath = [finalPath stringByAppendingString:@".download"];
        XCTAssertTrue([original writeToFile:finalPath atomically:YES]);
        TOSDownloadFileInput *input = [self tos_inputWithPath:finalPath];
        input.tosTempFilePath = tempPath;
        input.tosEnableCheckpoint = YES;
        input.tosCheckpointFile = checkpointPath;
        input.tosMaxRetryCount = 0;
        TOSTestDownloadClient *client = [TOSTestDownloadClient new];
        client.tos_headOutput = [self tos_headOutputForData:objectData];
        __weak typeof(self) weakSelf = self;
        client.tos_getHandler = ^TOSTask *(TOSGetObjectInput *getInput, NSInteger callIndex) {
            NSHTTPURLResponse *response = [weakSelf tos_responseWithStatusCode:[testCase[@"status"] integerValue]
                                                                       headers:testCase[@"headers"]];
            NSError *error = getInput.tos_responseValidator(response);
            return [TOSTask taskWithError:error];
        };

        TOSTask *task = [client downloadFile:input];
        [self tos_waitForTask:task];

        XCTAssertNotNil(task.error, @"%@", name);
        XCTAssertEqualObjects([NSData dataWithContentsOfFile:finalPath], original, @"%@", name);
        XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:tempPath], @"%@", name);
        XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:checkpointPath], @"%@", name);
    }
}

- (void)testDownloadRejectsShortAndLongBodiesWithoutReplacingFinalFile {
    NSArray<NSNumber *> *bodyLengths = @[@3, @5];
    NSData *objectData = [@"data" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *original = [@"old" dataUsingEncoding:NSUTF8StringEncoding];

    for (NSNumber *bodyLength in bodyLengths) {
        NSString *name = [NSString stringWithFormat:@"body-%@", bodyLength];
        NSString *finalPath = [self.tos_root stringByAppendingPathComponent:name];
        XCTAssertTrue([original writeToFile:finalPath atomically:YES]);
        TOSDownloadFileInput *input = [self tos_inputWithPath:finalPath];
        input.tosMaxRetryCount = 0;
        TOSTestDownloadClient *client = [TOSTestDownloadClient new];
        client.tos_headOutput = [self tos_headOutputForData:objectData];
        __weak typeof(self) weakSelf = self;
        client.tos_getHandler = ^TOSTask *(TOSGetObjectInput *getInput, NSInteger callIndex) {
            NSDictionary *headers = @{@"Content-Range": @"bytes 0-3/4", @"Content-Length": @"4"};
            NSError *validationError = getInput.tos_responseValidator(
                [weakSelf tos_responseWithStatusCode:206 headers:headers]);
            if (validationError) {
                return [TOSTask taskWithError:validationError];
            }
            NSMutableData *body = [NSMutableData dataWithLength:bodyLength.unsignedIntegerValue];
            memset(body.mutableBytes, 'x', body.length);
            getInput.tosOnReceiveData(body);
            return [TOSTask taskWithResult:[weakSelf tos_getOutputWithHeaders:headers
                                                               contentLength:(int64_t)body.length]];
        };

        TOSTask *task = [client downloadFile:input];
        [self tos_waitForTask:task];

        XCTAssertNotNil(task.error, @"%@", name);
        XCTAssertEqualObjects([NSData dataWithContentsOfFile:finalPath], original, @"%@", name);
    }
}

- (void)testDownloadRetriesWholePartAndEmitsSuccessOnlyAfterCheckpointPersistence {
    NSData *objectData = [@"retry-data" dataUsingEncoding:NSUTF8StringEncoding];
    NSString *finalPath = [self.tos_root stringByAppendingPathComponent:@"retry.bin"];
    NSString *checkpointPath = [self.tos_root stringByAppendingPathComponent:@"retry.download"];
    TOSDownloadFileInput *input = [self tos_inputWithPath:finalPath];
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = checkpointPath;
    input.tosMaxRetryCount = 1;
    __block NSInteger succeedEvents = 0;
    __block NSInteger failedEvents = 0;
    __block BOOL checkpointWasCompleteAtSuccessEvent = NO;
    NSMutableArray<TOSDataTransferStatus *> *progress = [NSMutableArray array];
    input.tosDataTransferListener = ^(TOSDataTransferStatus *status) {
        [progress addObject:status];
    };
    input.tosDownloadEventListener = ^(TOSDownloadEvent *event) {
        if (event.tosType == TOSDownloadEventDownloadPartSucceed) {
            succeedEvents += 1;
            NSData *data = [NSData dataWithContentsOfFile:checkpointPath];
            NSError *error = nil;
            TOSDownloadCheckpoint *checkpoint = [TOSDownloadCheckpoint tos_checkpointWithData:data
                                                                                checkpointPath:checkpointPath
                                                                                           error:&error];
            checkpointWasCompleteAtSuccessEvent = checkpoint.tos_parts.firstObject.tos_completed && error == nil;
        } else if (event.tosType == TOSDownloadEventDownloadPartFailed) {
            failedEvents += 1;
        }
    };
    TOSTestDownloadClient *client = [TOSTestDownloadClient new];
    client.tos_objectData = objectData;
    client.tos_headOutput = [self tos_headOutputForData:objectData];
    client.tos_getHandler = ^TOSTask *(TOSGetObjectInput *getInput, NSInteger callIndex) {
        if (callIndex == 0) {
            getInput.tosOnReceiveData(objectData);
            NSError *error = [NSError errorWithDomain:TOSServerErrorDomain code:500 userInfo:nil];
            return [TOSTask taskWithError:error];
        }
        return nil;
    };

    TOSTask *task = [client downloadFile:input];
    [self tos_waitForTask:task];

    XCTAssertNil(task.error);
    XCTAssertEqual(client.tos_getCalls, 2);
    XCTAssertEqual(succeedEvents, 1);
    XCTAssertEqual(failedEvents, 0);
    XCTAssertTrue(checkpointWasCompleteAtSuccessEvent);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:finalPath], objectData);
    for (TOSDataTransferStatus *status in progress) {
        XCTAssertLessThanOrEqual(status.tosConsumedBytes, status.tosTotalBytes);
    }
    XCTAssertEqual(progress.lastObject.tosConsumedBytes, objectData.length);
}

- (void)testDownloadFatalPartErrorsRemoveStateAndPreserveFinalFile {
    NSData *objectData = [@"fatal-data" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *original = [@"old" dataUsingEncoding:NSUTF8StringEncoding];
    for (NSNumber *statusCode in @[@403, @404, @405, @412]) {
        NSString *name = [NSString stringWithFormat:@"fatal-%@", statusCode];
        NSString *finalPath = [self.tos_root stringByAppendingPathComponent:[name stringByAppendingString:@".bin"]];
        NSString *tempPath = [finalPath stringByAppendingString:@".temp.fixed"];
        NSString *checkpointPath = [finalPath stringByAppendingString:@".download"];
        XCTAssertTrue([original writeToFile:finalPath atomically:YES]);
        TOSDownloadFileInput *input = [self tos_inputWithPath:finalPath];
        input.tosEnableCheckpoint = YES;
        input.tosCheckpointFile = checkpointPath;
        input.tosTempFilePath = tempPath;
        __block TOSDownloadEventType terminalPartEvent = 0;
        input.tosDownloadEventListener = ^(TOSDownloadEvent *event) {
            if (event.tosType == TOSDownloadEventDownloadPartAborted ||
                event.tosType == TOSDownloadEventDownloadPartFailed) {
                terminalPartEvent = event.tosType;
            }
        };
        TOSTestDownloadClient *client = [TOSTestDownloadClient new];
        client.tos_headOutput = [self tos_headOutputForData:objectData];
        client.tos_getHandler = ^TOSTask *(TOSGetObjectInput *getInput, NSInteger callIndex) {
            return [TOSTask taskWithError:[NSError errorWithDomain:TOSServerErrorDomain
                                                             code:statusCode.integerValue
                                                         userInfo:nil]];
        };

        TOSTask *task = [client downloadFile:input];
        [self tos_waitForTask:task];

        XCTAssertEqual(task.error.code, statusCode.integerValue, @"%@", name);
        XCTAssertEqual(terminalPartEvent, TOSDownloadEventDownloadPartAborted, @"%@", name);
        XCTAssertEqualObjects([NSData dataWithContentsOfFile:finalPath], original, @"%@", name);
        XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:tempPath], @"%@", name);
        XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:checkpointPath], @"%@", name);
    }
}

- (void)testDownloadPartFailureWithoutCheckpointRemovesOwnedTempFile {
    NSData *objectData = [@"part-error" dataUsingEncoding:NSUTF8StringEncoding];
    NSString *finalPath = [self.tos_root stringByAppendingPathComponent:@"part-error.bin"];
    NSString *tempPath = [finalPath stringByAppendingString:@".temp.fixed"];
    TOSDownloadFileInput *input = [self tos_inputWithPath:finalPath];
    input.tosTempFilePath = tempPath;
    TOSTestDownloadClient *client = [TOSTestDownloadClient new];
    client.tos_headOutput = [self tos_headOutputForData:objectData];
    client.tos_getHandler = ^TOSTask *(TOSGetObjectInput *getInput, NSInteger callIndex) {
        return [TOSTask taskWithError:[NSError errorWithDomain:TOSServerErrorDomain
                                                          code:400
                                                      userInfo:nil]];
    };

    TOSTask *task = [client downloadFile:input];
    [self tos_waitForTask:task];

    XCTAssertNotNil(task.error);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:tempPath]);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:finalPath]);
}

- (void)testDownloadPropagatesDiskWriteFailureAndPreservesCheckpoint {
    NSData *objectData = [@"disk-error" dataUsingEncoding:NSUTF8StringEncoding];
    NSString *finalPath = [self.tos_root stringByAppendingPathComponent:@"disk-error.bin"];
    NSString *checkpointPath = [self.tos_root stringByAppendingPathComponent:@"disk-error.download"];
    TOSDownloadFileInput *input = [self tos_inputWithPath:finalPath];
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = checkpointPath;
    input.tosMaxRetryCount = 0;
    TOSTestDownloadClient *client = [TOSTestDownloadClient new];
    client.tos_headOutput = [self tos_headOutputForData:objectData];
    __block TOSDownloadFileOperation *operation = nil;
    __weak typeof(self) weakSelf = self;
    client.tos_getHandler = ^TOSTask *(TOSGetObjectInput *getInput, NSInteger callIndex) {
        TOSDownloadFileWriter *writer = [operation valueForKey:@"tos_writer"];
        [writer close];
        NSDictionary *headers = @{@"Content-Range": @"bytes 0-9/10", @"Content-Length": @"10"};
        NSError *validationError = getInput.tos_responseValidator(
            [weakSelf tos_responseWithStatusCode:206 headers:headers]);
        if (validationError) {
            return [TOSTask taskWithError:validationError];
        }
        getInput.tosOnReceiveData(objectData);
        return [TOSTask taskWithResult:[weakSelf tos_getOutputWithHeaders:headers contentLength:10]];
    };
    operation = [[TOSDownloadFileOperation alloc] initWithClient:client request:input];
    [operation start];
    [self tos_waitForTask:operation.task];

    XCTAssertEqualObjects(operation.task.error.domain, NSPOSIXErrorDomain);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:checkpointPath]);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:finalPath]);
    operation = nil;
}

- (void)testDownloadValidatesCombinedCRCAndReportsProgressAndEvents {
    NSMutableData *objectData = [NSMutableData dataWithLength:(NSUInteger)(TOSMinPartSize + 3)];
    memset(objectData.mutableBytes, 'c', objectData.length);
    NSString *finalPath = [self.tos_root stringByAppendingPathComponent:@"crc-success.bin"];
    TOSDownloadFileInput *input = [self tos_inputWithPath:finalPath];
    input.tosTaskNum = 2;
    input.tosTrafficLimit = 8192;
    NSMutableArray<NSNumber *> *eventTypes = [NSMutableArray array];
    NSMutableArray<TOSDataTransferStatus *> *progress = [NSMutableArray array];
    input.tosDownloadEventListener = ^(TOSDownloadEvent *event) {
        [eventTypes addObject:@(event.tosType)];
    };
    input.tosDataTransferListener = ^(TOSDataTransferStatus *status) {
        [progress addObject:status];
    };
    TOSTestDownloadClient *client = [TOSTestDownloadClient new];
    client.tos_objectData = objectData;
    client.tos_headOutput = [self tos_headOutputForData:objectData];
    client.tos_headOutput.tosHashCrc64ecma = TOSTransferCRC64(0, objectData.bytes, objectData.length);
    client.tos_headOutput.tosContentType = @"application/octet-stream";

    TOSTask<TOSDownloadFileOutput *> *task = [client downloadFile:input];
    [self tos_waitForTask:task];

    XCTAssertNil(task.error);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:finalPath], objectData);
    XCTAssertEqual(task.result.tosHashCrc64ecma, client.tos_headOutput.tosHashCrc64ecma);
    XCTAssertEqualObjects(task.result.tosContentType, @"application/octet-stream");
    XCTAssertEqualObjects(eventTypes, (@[@(TOSDownloadEventCreateTempFileSucceed),
                                         @(TOSDownloadEventDownloadPartSucceed),
                                         @(TOSDownloadEventDownloadPartSucceed),
                                         @(TOSDownloadEventRenameTempFileSucceed)]));
    XCTAssertEqual(progress.firstObject.tosType, TOSDataTransferStarted);
    XCTAssertEqual(progress.lastObject.tosType, TOSDataTransferSucceed);
    XCTAssertEqual(progress.lastObject.tosConsumedBytes, (int64_t)objectData.length);
    XCTAssertEqual(progress.lastObject.tosTotalBytes, (int64_t)objectData.length);
    for (TOSGetObjectInput *getInput in client.tos_getInputs) {
        XCTAssertEqualObjects(getInput.tos_transferHeaders[@"x-tos-traffic-limit"], @"8192");
    }
}

- (void)testDownloadCRCMismatchRemovesStateWithoutReplacingFinalFile {
    NSData *objectData = [@"crc-mismatch" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *original = [@"old" dataUsingEncoding:NSUTF8StringEncoding];
    NSString *finalPath = [self.tos_root stringByAppendingPathComponent:@"crc-mismatch.bin"];
    NSString *tempPath = [finalPath stringByAppendingString:@".temp.fixed"];
    NSString *checkpointPath = [finalPath stringByAppendingString:@".download"];
    XCTAssertTrue([original writeToFile:finalPath atomically:YES]);
    TOSDownloadFileInput *input = [self tos_inputWithPath:finalPath];
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = checkpointPath;
    input.tosTempFilePath = tempPath;
    TOSTestDownloadClient *client = [TOSTestDownloadClient new];
    client.tos_objectData = objectData;
    client.tos_headOutput = [self tos_headOutputForData:objectData];
    client.tos_headOutput.tosHashCrc64ecma = 1;

    TOSTask *task = [client downloadFile:input];
    [self tos_waitForTask:task];

    XCTAssertTrue([[self tos_messageForError:task.error] containsString:@"crc"]);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:finalPath], original);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:tempPath]);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:checkpointPath]);
}

- (void)testDownloadRenameFailurePreservesTempAndCheckpoint {
    NSData *objectData = [@"rename-failure" dataUsingEncoding:NSUTF8StringEncoding];
    NSString *finalPath = [self.tos_root stringByAppendingPathComponent:@"rename-failure.bin"];
    NSString *tempPath = [finalPath stringByAppendingString:@".temp.fixed"];
    NSString *checkpointPath = [finalPath stringByAppendingString:@".download"];
    TOSDownloadFileInput *input = [self tos_inputWithPath:finalPath];
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = checkpointPath;
    input.tosTempFilePath = tempPath;
    __block BOOL renameFailedEvent = NO;
    input.tosDownloadEventListener = ^(TOSDownloadEvent *event) {
        renameFailedEvent |= event.tosType == TOSDownloadEventRenameTempFileFailed;
    };
    TOSTestDownloadClient *client = [TOSTestDownloadClient new];
    client.tos_objectData = objectData;
    client.tos_headOutput = [self tos_headOutputForData:objectData];
    __weak typeof(client) weakClient = client;
    __weak typeof(self) weakSelf = self;
    client.tos_getHandler = ^TOSTask *(TOSGetObjectInput *getInput, NSInteger callIndex) {
        TOSTestDownloadClient *strongClient = weakClient;
        NSString *range = getInput.tos_transferHeaders[@"Range"];
        long long start = 0;
        long long end = -1;
        sscanf(range.UTF8String, "bytes=%lld-%lld", &start, &end);
        NSDictionary *headers = @{
            @"Content-Range": [NSString stringWithFormat:@"bytes %lld-%lld/%lu", start, end,
                               (unsigned long)strongClient.tos_objectData.length],
            @"Content-Length": [NSString stringWithFormat:@"%lld", end - start + 1]
        };
        NSError *error = getInput.tos_responseValidator([weakSelf tos_responseWithStatusCode:206 headers:headers]);
        if (error) {
            return [TOSTask taskWithError:error];
        }
        getInput.tosOnReceiveData(strongClient.tos_objectData);
        [[NSFileManager defaultManager] createDirectoryAtPath:finalPath
                                  withIntermediateDirectories:NO
                                                   attributes:nil
                                                        error:nil];
        return [TOSTask taskWithResult:[weakSelf tos_getOutputWithHeaders:headers
                                                            contentLength:(int64_t)strongClient.tos_objectData.length]];
    };

    TOSTask *task = [client downloadFile:input];
    [self tos_waitForTask:task];

    XCTAssertNotNil(task.error);
    XCTAssertTrue(renameFailedEvent);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:tempPath]);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:checkpointPath]);
}

- (void)testDownloadRejectsTempPathReplacementBeforeAtomicRename {
    NSData *objectData = [@"expected-data" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *original = [@"old" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *replacement = [@"replaced-data" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertEqual(objectData.length, replacement.length);
    NSString *finalPath = [self.tos_root stringByAppendingPathComponent:@"identity.bin"];
    NSString *tempPath = [finalPath stringByAppendingString:@".temp.fixed"];
    XCTAssertTrue([original writeToFile:finalPath atomically:YES]);
    TOSDownloadFileInput *input = [self tos_inputWithPath:finalPath];
    input.tosTempFilePath = tempPath;
    TOSTestDownloadClient *client = [TOSTestDownloadClient new];
    client.tos_headOutput = [self tos_headOutputForData:objectData];
    __weak typeof(self) weakSelf = self;
    client.tos_getHandler = ^TOSTask *(TOSGetObjectInput *getInput, NSInteger callIndex) {
        NSDictionary *headers = @{@"Content-Range": @"bytes 0-12/13", @"Content-Length": @"13"};
        NSError *error = getInput.tos_responseValidator([weakSelf tos_responseWithStatusCode:206 headers:headers]);
        if (error) {
            return [TOSTask taskWithError:error];
        }
        getInput.tosOnReceiveData(objectData);
        [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];
        [replacement writeToFile:tempPath atomically:YES];
        return [TOSTask taskWithResult:[weakSelf tos_getOutputWithHeaders:headers contentLength:13]];
    };

    TOSTask *task = [client downloadFile:input];
    [self tos_waitForTask:task];

    XCTAssertNotNil(task.error);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:finalPath], original);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:tempPath], replacement);
}

- (void)testDownloadPublicFactoryKeepsOperationAliveAndFinalUnchangedUntilPartCompletes {
    NSData *objectData = [@"async-data" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *original = [@"old" dataUsingEncoding:NSUTF8StringEncoding];
    NSString *finalPath = [self.tos_root stringByAppendingPathComponent:@"async.bin"];
    XCTAssertTrue([original writeToFile:finalPath atomically:YES]);
    TOSDownloadFileInput *input = [self tos_inputWithPath:finalPath];
    TOSTestDownloadClient *client = [TOSTestDownloadClient new];
    client.tos_headOutput = [self tos_headOutputForData:objectData];
    TOSTaskCompletionSource<TOSGetObjectOutput *> *partSource = [TOSTaskCompletionSource taskCompletionSource];
    XCTestExpectation *partStarted = [self expectationWithDescription:@"part started"];
    __block TOSGetObjectInput *capturedInput = nil;
    client.tos_getHandler = ^TOSTask *(TOSGetObjectInput *getInput, NSInteger callIndex) {
        capturedInput = getInput;
        [partStarted fulfill];
        return partSource.task;
    };

    TOSTask *task = [client downloadFile:input];
    [self waitForExpectations:@[partStarted] timeout:2.0];
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:finalPath], original);
    XCTAssertNotNil(capturedInput.tos_responseObserver);
    NSDictionary *headers = @{@"Content-Range": @"bytes 0-9/10", @"Content-Length": @"10"};
    XCTAssertNil(capturedInput.tos_responseValidator([self tos_responseWithStatusCode:206 headers:headers]));
    capturedInput.tosOnReceiveData(objectData);
    [partSource setResult:[self tos_getOutputWithHeaders:headers contentLength:10]];
    [self tos_waitForTask:task];

    XCTAssertNil(task.error);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:finalPath], objectData);
}

- (void)testDownloadCancellationPreservesOrAbortsResumableStateAsRequested {
    NSData *objectData = [@"cancel-data" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *original = [@"old" dataUsingEncoding:NSUTF8StringEncoding];
    for (NSNumber *abortValue in @[@NO, @YES]) {
        BOOL abort = abortValue.boolValue;
        NSString *name = abort ? @"cancel-abort" : @"cancel-resume";
        NSString *finalPath = [self.tos_root stringByAppendingPathComponent:[name stringByAppendingString:@".bin"]];
        NSString *tempPath = [finalPath stringByAppendingString:@".temp.fixed"];
        NSString *checkpointPath = [finalPath stringByAppendingString:@".download"];
        XCTAssertTrue([original writeToFile:finalPath atomically:YES]);
        TOSDownloadFileInput *input = [self tos_inputWithPath:finalPath];
        input.tosEnableCheckpoint = YES;
        input.tosCheckpointFile = checkpointPath;
        input.tosTempFilePath = tempPath;
        input.tosCancelHook = [TOSCancelHook new];
        TOSTestDownloadClient *client = [TOSTestDownloadClient new];
        client.tos_headOutput = [self tos_headOutputForData:objectData];
        TOSTaskCompletionSource<TOSGetObjectOutput *> *partSource = [TOSTaskCompletionSource taskCompletionSource];
        XCTestExpectation *partStarted = [self expectationWithDescription:name];
        client.tos_getHandler = ^TOSTask *(TOSGetObjectInput *getInput, NSInteger callIndex) {
            [partStarted fulfill];
            return partSource.task;
        };

        TOSTask *task = [client downloadFile:input];
        [self waitForExpectations:@[partStarted] timeout:2.0];
        [input.tosCancelHook cancel:abort];
        [partSource setError:[NSError errorWithDomain:NSURLErrorDomain
                                                code:NSURLErrorCancelled
                                            userInfo:nil]];
        [self tos_waitForTask:task];

        XCTAssertNotNil(task.error);
        XCTAssertEqualObjects([NSData dataWithContentsOfFile:finalPath], original);
        XCTAssertEqual([[NSFileManager defaultManager] fileExistsAtPath:tempPath], !abort);
        XCTAssertEqual([[NSFileManager defaultManager] fileExistsAtPath:checkpointPath], !abort);
    }
}

- (void)testDownloadCancellationWithoutCheckpointRemovesOwnedTempFile {
    NSData *objectData = [@"cancel-data" dataUsingEncoding:NSUTF8StringEncoding];
    NSString *finalPath = [self.tos_root stringByAppendingPathComponent:@"cancel-no-checkpoint.bin"];
    NSString *tempPath = [finalPath stringByAppendingString:@".temp.fixed"];
    TOSDownloadFileInput *input = [self tos_inputWithPath:finalPath];
    input.tosTempFilePath = tempPath;
    input.tosCancelHook = [TOSCancelHook new];
    TOSTaskCompletionSource *partSource = [TOSTaskCompletionSource taskCompletionSource];
    XCTestExpectation *partStarted = [self expectationWithDescription:@"part started"];
    TOSTestDownloadClient *client = [TOSTestDownloadClient new];
    client.tos_headOutput = [self tos_headOutputForData:objectData];
    client.tos_getHandler = ^TOSTask *(TOSGetObjectInput *getInput, NSInteger callIndex) {
        [partStarted fulfill];
        return partSource.task;
    };

    TOSTask *task = [client downloadFile:input];
    [self waitForExpectations:@[partStarted] timeout:1.0];
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:tempPath]);

    [input.tosCancelHook cancel:NO];
    [partSource setError:[NSError errorWithDomain:TOSClientErrorDomain
                                              code:TOSClientErrorCodeTaskCancelled
                                          userInfo:nil]];
    [self tos_waitForTask:task];

    XCTAssertTrue([[self tos_messageForError:task.error] containsString:@"cancelled"]);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:tempPath]);
}

- (void)testDownloadRetriesHeadAndCanCancelPendingHead {
    NSData *objectData = [@"head-retry" dataUsingEncoding:NSUTF8StringEncoding];
    NSString *retryPath = [self.tos_root stringByAppendingPathComponent:@"head-retry.bin"];
    TOSTestDownloadClient *retryClient = [TOSTestDownloadClient new];
    retryClient.tos_objectData = objectData;
    retryClient.tos_headOutput = [self tos_headOutputForData:objectData];
    __weak typeof(retryClient) weakRetryClient = retryClient;
    retryClient.tos_headHandler = ^TOSTask *(TOSHeadObjectInput *headInput, NSInteger callIndex) {
        if (callIndex == 0) {
            return [TOSTask taskWithError:[NSError errorWithDomain:TOSServerErrorDomain code:500 userInfo:nil]];
        }
        return [TOSTask taskWithResult:weakRetryClient.tos_headOutput];
    };
    TOSDownloadFileInput *retryInput = [self tos_inputWithPath:retryPath];
    retryInput.tosMaxRetryCount = 1;
    TOSTask *retryTask = [retryClient downloadFile:retryInput];
    [self tos_waitForTask:retryTask];
    XCTAssertNil(retryTask.error);
    XCTAssertEqual(retryClient.tos_headCalls, 2);

    NSString *cancelPath = [self.tos_root stringByAppendingPathComponent:@"head-cancel.bin"];
    TOSDownloadFileInput *cancelInput = [self tos_inputWithPath:cancelPath];
    cancelInput.tosCancelHook = [TOSCancelHook new];
    TOSTestDownloadClient *cancelClient = [TOSTestDownloadClient new];
    TOSTaskCompletionSource<TOSHeadObjectOutput *> *headSource = [TOSTaskCompletionSource taskCompletionSource];
    XCTestExpectation *headStarted = [self expectationWithDescription:@"head started"];
    cancelClient.tos_headHandler = ^TOSTask *(TOSHeadObjectInput *headInput, NSInteger callIndex) {
        [headStarted fulfill];
        return headSource.task;
    };
    TOSTask *cancelTask = [cancelClient downloadFile:cancelInput];
    [self waitForExpectations:@[headStarted] timeout:2.0];
    [cancelInput.tosCancelHook cancel:NO];
    [self tos_waitForTask:cancelTask];
    XCTAssertNotNil(cancelTask.error);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:cancelPath]);
    [headSource trySetError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]];
}

- (void)testDownloadHonorsRetryAfterFromHeadResponse {
    NSString *path = [self.tos_root stringByAppendingPathComponent:@"head-retry-after.bin"];
    TOSDownloadFileInput *input = [self tos_inputWithPath:path];
    input.tosMaxRetryCount = 1;
    input.tosCancelHook = [TOSCancelHook new];
    XCTestExpectation *firstAttempt = [self expectationWithDescription:@"first head attempt"];
    XCTestExpectation *secondAttempt = [self expectationWithDescription:@"unexpected head retry"];
    secondAttempt.inverted = YES;
    TOSTestDownloadClient *client = [TOSTestDownloadClient new];
    __weak typeof(self) weakSelf = self;
    client.tos_headHandler = ^TOSTask *(TOSHeadObjectInput *headInput, NSInteger callIndex) {
        if (callIndex == 0) {
            XCTAssertNotNil(headInput.tos_responseObserver);
            if (headInput.tos_responseObserver) {
                headInput.tos_responseObserver(
                    [weakSelf tos_responseWithStatusCode:429 headers:@{@"Retry-After": @"60"}]);
            }
            [firstAttempt fulfill];
        } else {
            [secondAttempt fulfill];
        }
        return [TOSTask taskWithError:
                [NSError errorWithDomain:TOSServerErrorDomain code:429 userInfo:@{}]];
    };

    TOSTask *task = [client downloadFile:input];
    [self waitForExpectations:@[firstAttempt] timeout:1.0];
    [self waitForExpectations:@[secondAttempt] timeout:0.5];
    XCTAssertEqual(client.tos_headCalls, 1);
    [input.tosCancelHook cancel:NO];
    [self tos_waitForTask:task];

    XCTAssertTrue([[self tos_messageForError:task.error] containsString:@"cancelled"]);
}

@end
