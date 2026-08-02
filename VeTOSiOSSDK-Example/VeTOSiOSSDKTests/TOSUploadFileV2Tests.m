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
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#import "../../VeTOSiOSSDK/VeTOSiOSSDK/Transfer/TOSInput+TransferInternal.h"
#import "../../VeTOSiOSSDK/VeTOSiOSSDK/Transfer/TOSTransferCheckpoint.h"
#import "../../VeTOSiOSSDK/VeTOSiOSSDK/Transfer/TOSTransferIO.h"
#import "../../VeTOSiOSSDK/VeTOSiOSSDK/Transfer/TOSTransferOperation.h"
#import "../../VeTOSiOSSDK/VeTOSiOSSDK/Transfer/TOSUploadFileV2Operation.h"
#import <VeTOSiOSSDK/VeTOSiOSSDK.h>

@interface TOSClient (UploadFileV2Testing)
- (TOSTask *)validateUploadFileRequest:(TOSUploadFileInput *)request;
- (TOSTask *)tos_uploadFileV2:(TOSUploadFileInputV2 *)request;
@end

@interface TOSUploadFileV2Operation (LifecycleTesting)
- (void)tos_finishWithOutput:(TOSUploadFileOutputV2 *)output error:(NSError *)error;
@property (nonatomic, strong, readonly) dispatch_queue_t tos_stateQueue;
@property (nonatomic, strong, readonly) TOSTransferOperation *tos_partOperation;
@end

@interface TOSTestUnrelatedUploadInput : TOSUploadFileInput
@end

@implementation TOSTestUnrelatedUploadInput
@end

@interface TOSTestUploadRoutingClient : TOSClient
@property (nonatomic, assign) NSInteger tos_legacyCalls;
@property (nonatomic, assign) NSInteger tos_v2Calls;
@end

@implementation TOSTestUploadRoutingClient

- (TOSTask *)validateUploadFileRequest:(TOSUploadFileInput *)request {
    self.tos_legacyCalls += 1;
    return [TOSTask taskWithResult:@"legacy"];
}

- (TOSTask *)tos_uploadFileV2:(TOSUploadFileInputV2 *)request {
    self.tos_v2Calls += 1;
    return [TOSTask taskWithResult:@"v2"];
}

@end

@interface TOSTestUploadV2Client : TOSClient
@property (nonatomic, assign) NSInteger tos_createCalls;
@property (nonatomic, assign) NSInteger tos_abortCalls;
@property (nonatomic, assign) NSInteger tos_uploadPartCalls;
@property (nonatomic, assign) NSInteger tos_completeCalls;
@property (nonatomic, copy) NSString *tos_createUploadID;
@property (nonatomic, strong) TOSTask *tos_abortTask;
@property (nonatomic, copy) void (^tos_abortObserver)(void);
@property (nonatomic, strong) NSMutableArray<NSString *> *tos_callOrder;
@property (nonatomic, strong) NSMutableArray<TOSAbortMultipartUploadInput *> *tos_abortInputs;
@property (nonatomic, strong) NSMutableArray<TOSUploadPartFromStreamInput *> *tos_uploadPartInputs;
@property (nonatomic, strong) TOSCompleteMultipartUploadInput *tos_completeInput;
@property (nonatomic, copy) TOSTask *(^tos_createHandler)(TOSCreateMultipartUploadInput *input);
@property (nonatomic, copy) TOSTask *(^tos_uploadPartHandler)(TOSUploadPartFromStreamInput *input,
                                                                  NSInteger callIndex);
@property (nonatomic, copy) void (^tos_afterPartConsumed)(TOSUploadPartFromStreamInput *input,
                                                              TOSFileRangeInputStream *stream);
@property (nonatomic, copy) TOSTask *(^tos_completeHandler)(TOSCompleteMultipartUploadInput *input);
@end

@implementation TOSTestUploadV2Client

- (instancetype)init {
    self = [super init];
    if (self) {
        _tos_callOrder = [NSMutableArray array];
        _tos_abortInputs = [NSMutableArray array];
        _tos_uploadPartInputs = [NSMutableArray array];
        _tos_createUploadID = @"new-upload-id";
    }
    return self;
}

- (TOSTask *)createMultipartUpload:(TOSCreateMultipartUploadInput *)request {
    self.tos_createCalls += 1;
    [self.tos_callOrder addObject:@"create"];
    if (self.tos_createHandler) {
        TOSTask *customTask = self.tos_createHandler(request);
        if (customTask) {
            return customTask;
        }
    }
    TOSCreateMultipartUploadOutput *output = [TOSCreateMultipartUploadOutput new];
    output.tosUploadID = self.tos_createUploadID;
    return [TOSTask taskWithResult:output];
}

- (TOSTask *)abortMultipartUpload:(TOSAbortMultipartUploadInput *)request {
    self.tos_abortCalls += 1;
    [self.tos_callOrder addObject:@"abort"];
    [self.tos_abortInputs addObject:request];
    if (self.tos_abortObserver) {
        self.tos_abortObserver();
    }
    return self.tos_abortTask ?: [TOSTask taskWithResult:[TOSAbortMultipartUploadOutput new]];
}

- (TOSTask *)uploadPartFromStream:(TOSUploadPartFromStreamInput *)request {
    self.tos_uploadPartCalls += 1;
    [self.tos_callOrder addObject:[NSString stringWithFormat:@"part-%d", request.tosPartNumber]];
    [self.tos_uploadPartInputs addObject:request];
    if (self.tos_uploadPartHandler) {
        TOSTask *customTask = self.tos_uploadPartHandler(request, self.tos_uploadPartCalls - 1);
        if (customTask) {
            return customTask;
        }
    }

    NSInputStream *stream = request.tosInputStream;
    [stream open];
    uint8_t buffer[4096];
    while ([stream read:buffer maxLength:sizeof(buffer)] > 0) {
    }
    NSError *streamError = stream.streamError;
    if (streamError) {
        [stream close];
        return [TOSTask taskWithError:streamError];
    }
    TOSFileRangeInputStream *fileStream = (TOSFileRangeInputStream *)stream;
    if (self.tos_afterPartConsumed) {
        self.tos_afterPartConsumed(request, fileStream);
    }
    TOSUploadPartFromStreamOutput *output = [TOSUploadPartFromStreamOutput new];
    output.tosPartNumber = request.tosPartNumber;
    output.tosETag = [NSString stringWithFormat:@"etag-%d", request.tosPartNumber];
    output.tosHashCrc64ecma = fileStream.tos_crc64;
    output.tosHeader = @{ @"x-tos-hash-crc64ecma": [NSString stringWithFormat:@"%llu", output.tosHashCrc64ecma] };
    [stream close];
    return [TOSTask taskWithResult:output];
}

- (TOSTask *)completeMultipartUpload:(TOSCompleteMultipartUploadInput *)request {
    self.tos_completeCalls += 1;
    self.tos_completeInput = request;
    [self.tos_callOrder addObject:@"complete"];
    if (self.tos_completeHandler) {
        TOSTask *customTask = self.tos_completeHandler(request);
        if (customTask) {
            return customTask;
        }
    }
    TOSCompleteMultipartUploadOutput *output = [TOSCompleteMultipartUploadOutput new];
    output.tosBucket = request.tosBucket;
    output.tosKey = request.tosKey;
    output.tosETag = @"complete-etag";
    output.tosLocation = @"location";
    output.tosVersionID = @"version-id";
    output.tosCallbackResult = @"callback-result";
    return [TOSTask taskWithResult:output];
}

@end

@interface TOSUploadFileV2Tests : XCTestCase
@property (nonatomic, copy) NSString *tos_root;
@end

@implementation TOSUploadFileV2Tests

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

- (NSString *)tos_createFileNamed:(NSString *)name size:(int64_t)size {
    NSString *path = [self.tos_root stringByAppendingPathComponent:name];
    int descriptor = open(path.fileSystemRepresentation, O_CREAT | O_TRUNC | O_WRONLY, 0600);
    XCTAssertGreaterThanOrEqual(descriptor, 0);
    if (descriptor >= 0) {
        XCTAssertEqual(ftruncate(descriptor, size), 0);
        close(descriptor);
    }
    return path;
}

- (TOSUploadFileInputV2 *)tos_inputWithFilePath:(NSString *)filePath {
    TOSUploadFileInputV2 *input = [TOSUploadFileInputV2 new];
    input.tosBucket = @"valid-bucket";
    input.tosKey = @"object";
    input.tosFilePath = filePath;
    return input;
}

- (void)tos_waitForTask:(TOSTask *)task {
    XCTestExpectation *completion = [self expectationWithDescription:@"upload task completion"];
    [task continueWithBlock:^id(TOSTask *finishedTask) {
        [completion fulfill];
        return nil;
    }];
    [self waitForExpectations:@[completion] timeout:2.0];
}

- (NSString *)tos_messageForError:(NSError *)error {
    return error.userInfo[TOSErrorMessageTOKEN] ?: error.localizedDescription ?: @"";
}

- (int64_t)tos_modifiedTimeForPath:(NSString *)path {
    struct stat fileStat;
    XCTAssertEqual(stat(path.fileSystemRepresentation, &fileStat), 0);
    return fileStat.st_mtimespec.tv_sec * NSEC_PER_SEC + fileStat.st_mtimespec.tv_nsec;
}

- (TOSUploadCheckpointV2 *)tos_checkpointForInput:(TOSUploadFileInputV2 *)input
                                         uploadID:(NSString *)uploadID {
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:input.tosFilePath error:nil];
    int64_t fileSize = [attributes[NSFileSize] longLongValue];
    NSError *partError = nil;
    NSArray<TOSTransferPart *> *parts = TOSUploadParts(fileSize, input.tosPartSize, &partError);
    XCTAssertNotNil(parts);
    XCTAssertNil(partError);

    TOSUploadCheckpointV2 *checkpoint = [TOSUploadCheckpointV2 new];
    checkpoint.tos_schemaVersion = 1;
    checkpoint.tos_operation = @"upload";
    checkpoint.tos_bucket = input.tosBucket;
    checkpoint.tos_key = input.tosKey;
    checkpoint.tos_partSize = input.tosPartSize;
    checkpoint.tos_checkpointPath = input.tosCheckpointFile;
    checkpoint.tos_parts = parts;
    checkpoint.tos_encodingType = input.tosEncodingType ?: @"";
    checkpoint.tos_uploadID = uploadID ?: @"";
    checkpoint.tos_filePath = input.tosFilePath;
    checkpoint.tos_fileSize = fileSize;
    checkpoint.tos_fileModifiedTime = [self tos_modifiedTimeForPath:input.tosFilePath];
    return checkpoint;
}

- (void)tos_writeCheckpoint:(TOSUploadCheckpointV2 *)checkpoint {
    NSError *error = nil;
    XCTAssertTrue([[[TOSTransferCheckpointStore alloc] init] writeCheckpoint:checkpoint error:&error]);
    XCTAssertNil(error);
}

- (void)testUploadFileRoutesOnlyV2InputToNewEngine {
    TOSTestUploadRoutingClient *client = [TOSTestUploadRoutingClient new];

    TOSTask *legacy = [client uploadFile:[TOSUploadFileInput new]];
    TOSTask *unrelated = [client uploadFile:[TOSTestUnrelatedUploadInput new]];
    TOSTask *v2 = [client uploadFile:[TOSUploadFileInputV2 new]];

    XCTAssertEqualObjects(legacy.result, @"legacy");
    XCTAssertEqualObjects(unrelated.result, @"legacy");
    XCTAssertEqualObjects(v2.result, @"v2");
    XCTAssertEqual(client.tos_legacyCalls, 2);
    XCTAssertEqual(client.tos_v2Calls, 1);
}

- (void)testUploadFilePublicSelectorRemainsAvailable {
    XCTAssertTrue([TOSClient instancesRespondToSelector:@selector(uploadFile:)]);
    NSMethodSignature *signature = [TOSClient instanceMethodSignatureForSelector:@selector(uploadFile:)];
    XCTAssertNotNil(signature);
    XCTAssertEqual(signature.numberOfArguments, 3);
}

- (void)testUploadV2RejectsCheckpointAlreadyInUseBeforeRemoteMutation {
    NSString *filePath = [self tos_createFileNamed:@"lease-conflict.bin" size:1];
    NSString *checkpointPath = [self.tos_root stringByAppendingPathComponent:@"lease-conflict.upload.v2"];
    NSError *leaseError = nil;
    TOSTransferCheckpointLease *lease =
        [TOSTransferCheckpointLease acquireCheckpointPath:checkpointPath error:&leaseError];
    XCTAssertNotNil(lease);
    XCTAssertNil(leaseError);

    TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
    input.tosPartSize = TOSMinPartSize;
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = checkpointPath;
    TOSTestUploadV2Client *client = [TOSTestUploadV2Client new];
    TOSUploadFileV2Operation *operation =
        [[TOSUploadFileV2Operation alloc] initWithClient:client request:input];

    [operation start];
    [self tos_waitForTask:operation.task];

    XCTAssertNotNil(operation.task.error);
    XCTAssertEqual(client.tos_createCalls, 0);
    XCTAssertEqual(client.tos_uploadPartCalls, 0);
    [lease invalidate];
}

- (void)testUploadFilePublicTaskRetainsV2OperationUntilAsynchronousCompletion {
    NSString *filePath = [self tos_createFileNamed:@"public-lifetime.bin" size:0];
    TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
    TOSTaskCompletionSource *createSource = [TOSTaskCompletionSource taskCompletionSource];
    XCTestExpectation *createStarted = [self expectationWithDescription:@"create started"];
    TOSTestUploadV2Client *client = [TOSTestUploadV2Client new];
    client.tos_createHandler = ^TOSTask *(TOSCreateMultipartUploadInput *createInput) {
        [createStarted fulfill];
        return createSource.task;
    };

    TOSTask *task = [client uploadFile:input];
    [self waitForExpectations:@[createStarted] timeout:1.0];
    TOSCreateMultipartUploadOutput *createOutput = [TOSCreateMultipartUploadOutput new];
    createOutput.tosUploadID = @"public-lifetime-upload-id";
    [createSource setResult:createOutput];
    [self tos_waitForTask:task];

    XCTAssertNil(task.error);
    XCTAssertEqual(client.tos_completeCalls, 1);
    XCTAssertEqualObjects(((TOSUploadFileOutputV2 *)task.result).tosUploadID,
                          @"public-lifetime-upload-id");
}

- (void)testUploadV2SnapshotsInputBeforeAsynchronousWork {
    NSString *filePath = [self tos_createFileNamed:@"snapshot.bin" size:0];
    TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
    input.tosMeta = @{@"owner": @"before"};
    TOSUploadFileV2Operation *operation = [[TOSUploadFileV2Operation alloc]
                                           initWithClient:[TOSTestUploadV2Client new]
                                           request:input];

    input.tosBucket = @"changed-bucket";
    input.tosFilePath = @"/changed/path";
    input.tosMeta = @{@"owner": @"after"};

    XCTAssertEqualObjects(operation.request.tosBucket, @"valid-bucket");
    XCTAssertEqualObjects(operation.request.tosFilePath, filePath);
    XCTAssertEqualObjects(operation.request.tosMeta, (@{@"owner": @"before"}));
}

- (void)testUploadV2RejectsMissingFileAndDirectoryWithoutNetworkCalls {
    TOSTestUploadV2Client *client = [TOSTestUploadV2Client new];
    TOSUploadFileV2Operation *missing = [[TOSUploadFileV2Operation alloc]
                                        initWithClient:client
                                        request:[self tos_inputWithFilePath:[self.tos_root stringByAppendingPathComponent:@"missing.bin"]]];
    [missing start];
    [self tos_waitForTask:missing.task];
    XCTAssertTrue([[self tos_messageForError:missing.task.error] containsString:@"file does not exist"]);

    NSString *directory = [self.tos_root stringByAppendingPathComponent:@"directory"];
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:directory
                                             withIntermediateDirectories:NO
                                                              attributes:nil
                                                                   error:nil]);
    TOSUploadFileV2Operation *directoryOperation = [[TOSUploadFileV2Operation alloc]
                                                    initWithClient:client
                                                    request:[self tos_inputWithFilePath:directory]];
    [directoryOperation start];
    [self tos_waitForTask:directoryOperation.task];
    XCTAssertTrue([[self tos_messageForError:directoryOperation.task.error] containsString:@"does not support directory"]);
    XCTAssertEqual(client.tos_createCalls, 0);
}

- (void)testUploadV2RejectsPartSizeOutsideSupportedBounds {
    NSString *filePath = [self tos_createFileNamed:@"part-size.bin" size:0];
    NSArray<NSNumber *> *invalidSizes = @[@(TOSMinPartSize - 1), @(TOSMaxPartSize + 1)];
    for (NSNumber *invalidSize in invalidSizes) {
        TOSTestUploadV2Client *client = [TOSTestUploadV2Client new];
        TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
        input.tosPartSize = invalidSize.longLongValue;
        TOSUploadFileV2Operation *operation = [[TOSUploadFileV2Operation alloc] initWithClient:client request:input];
        [operation start];
        [self tos_waitForTask:operation.task];

        XCTAssertTrue([[self tos_messageForError:operation.task.error] containsString:@"invalid part size"]);
        XCTAssertEqual(client.tos_createCalls, 0);
    }
}

- (void)testUploadV2RejectsMoreThanTenThousandPartsBeforeNetworkCalls {
    int64_t size = TOSMinPartSize * 10000 + 1;
    NSString *filePath = [self tos_createFileNamed:@"too-many-parts.bin" size:size];
    TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
    input.tosPartSize = TOSMinPartSize;
    TOSTestUploadV2Client *client = [TOSTestUploadV2Client new];
    TOSUploadFileV2Operation *operation = [[TOSUploadFileV2Operation alloc] initWithClient:client request:input];

    [operation start];
    [self tos_waitForTask:operation.task];

    XCTAssertTrue([[self tos_messageForError:operation.task.error] containsString:@"maximum is 10000"]);
    XCTAssertEqual(client.tos_createCalls, 0);
}

- (void)testUploadV2RejectsSSEFieldsDeterministically {
    NSString *filePath = [self tos_createFileNamed:@"sse.bin" size:0];
    TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
    input.tosSSECAlgorithm = @"AES256";
    TOSTestUploadV2Client *client = [TOSTestUploadV2Client new];
    TOSUploadFileV2Operation *operation = [[TOSUploadFileV2Operation alloc] initWithClient:client request:input];

    [operation start];
    [self tos_waitForTask:operation.task];

    XCTAssertTrue([[self tos_messageForError:operation.task.error] containsString:@"SSE"]);
    XCTAssertEqual(client.tos_createCalls, 0);
}

- (void)testUploadV2NeverOverwritesLegacyCheckpointCollision {
    NSString *filePath = [self tos_createFileNamed:@"collision.bin" size:0];
    NSString *checkpointPath = [self.tos_root stringByAppendingPathComponent:@"legacy.upload"];
    NSData *legacyData = [@"legacy-binary-checkpoint" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertTrue([legacyData writeToFile:checkpointPath atomically:YES]);
    TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = checkpointPath;
    TOSTestUploadV2Client *client = [TOSTestUploadV2Client new];
    TOSUploadFileV2Operation *operation = [[TOSUploadFileV2Operation alloc] initWithClient:client request:input];

    [operation start];
    [self tos_waitForTask:operation.task];

    XCTAssertTrue([[self tos_messageForError:operation.task.error] containsString:@"checkpoint"]);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:checkpointPath], legacyData);
    XCTAssertEqual(client.tos_createCalls, 0);
    XCTAssertEqual(client.tos_abortCalls, 0);
}

- (void)testUploadV2ResumesOnlyPendingPartsFromValidCheckpoint {
    NSString *filePath = [self tos_createFileNamed:@"resume.bin" size:TOSMinPartSize + 7];
    NSString *checkpointPath = [self.tos_root stringByAppendingPathComponent:@"resume.upload.v2"];
    TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
    input.tosPartSize = TOSMinPartSize;
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = checkpointPath;
    TOSUploadCheckpointV2 *checkpoint = [self tos_checkpointForInput:input uploadID:@"existing-upload-id"];
    TOSTransferPart *completedPart = checkpoint.tos_parts.firstObject;
    completedPart.tos_completed = YES;
    completedPart.tos_eTag = @"existing-etag";
    completedPart.tos_crc64 = 123;
    [self tos_writeCheckpoint:checkpoint];
    TOSTestUploadV2Client *client = [TOSTestUploadV2Client new];
    TOSUploadFileV2Operation *operation = [[TOSUploadFileV2Operation alloc] initWithClient:client request:input];

    [operation start];
    [self tos_waitForTask:operation.task];

    XCTAssertNil(operation.task.error);
    XCTAssertEqual(client.tos_createCalls, 0);
    XCTAssertEqual(client.tos_uploadPartCalls, 1);
    XCTAssertEqual(client.tos_uploadPartInputs.firstObject.tosPartNumber, 2);
    XCTAssertEqual(client.tos_completeCalls, 1);
    XCTAssertEqualObjects(client.tos_completeInput.tosUploadID, @"existing-upload-id");
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:checkpointPath]);
}

- (void)testUploadV2RejectsEmptyUploadIDBeforeSchedulingParts {
    NSString *filePath = [self tos_createFileNamed:@"empty-upload-id.bin" size:0];
    TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
    TOSTestUploadV2Client *client = [TOSTestUploadV2Client new];
    client.tos_createUploadID = @"";
    TOSUploadFileV2Operation *operation = [[TOSUploadFileV2Operation alloc] initWithClient:client request:input];

    [operation start];
    [self tos_waitForTask:operation.task];

    XCTAssertTrue([[self tos_messageForError:operation.task.error] containsString:@"upload ID"]);
    XCTAssertEqual(client.tos_createCalls, 1);
    XCTAssertEqual(client.tos_uploadPartCalls, 0);
    XCTAssertEqual(client.tos_completeCalls, 0);
}

- (void)testUploadV2AbortsSameTargetIncompatibleCheckpointBeforeReplacement {
    NSString *filePath = [self tos_createFileNamed:@"replace.bin" size:0];
    NSString *checkpointPath = [self.tos_root stringByAppendingPathComponent:@"replace.upload.v2"];
    TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
    input.tosPartSize = TOSMinPartSize;
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = checkpointPath;
    TOSUploadCheckpointV2 *checkpoint = [self tos_checkpointForInput:input uploadID:@"stale-upload-id"];
    checkpoint.tos_fileModifiedTime += 1;
    [self tos_writeCheckpoint:checkpoint];
    NSData *staleData = [NSData dataWithContentsOfFile:checkpointPath];

    TOSTaskCompletionSource *abortSource = [TOSTaskCompletionSource taskCompletionSource];
    TOSTestUploadV2Client *client = [TOSTestUploadV2Client new];
    client.tos_abortTask = abortSource.task;
    XCTestExpectation *abortCalled = [self expectationWithDescription:@"stale upload aborted"];
    client.tos_abortObserver = ^{
        [abortCalled fulfill];
    };
    TOSUploadFileV2Operation *operation = [[TOSUploadFileV2Operation alloc] initWithClient:client request:input];
    [operation start];

    [self waitForExpectations:@[abortCalled] timeout:1.0];
    XCTAssertEqual(client.tos_createCalls, 0);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:checkpointPath], staleData);
    XCTAssertEqualObjects(client.tos_abortInputs.firstObject.tosBucket, input.tosBucket);
    XCTAssertEqualObjects(client.tos_abortInputs.firstObject.tosKey, input.tosKey);
    XCTAssertEqualObjects(client.tos_abortInputs.firstObject.tosUploadID, @"stale-upload-id");

    [abortSource setResult:[TOSAbortMultipartUploadOutput new]];
    [self tos_waitForTask:operation.task];

    XCTAssertNil(operation.task.error);
    XCTAssertEqual(client.tos_createCalls, 1);
    XCTAssertEqualObjects(client.tos_callOrder.firstObject, @"abort");
    if (client.tos_callOrder.count > 1) {
        XCTAssertEqualObjects(client.tos_callOrder[1], @"create");
    }
}

- (void)testUploadV2RejectsForeignTargetCheckpointWithoutRemoteMutation {
    NSString *filePath = [self tos_createFileNamed:@"foreign-target.bin" size:0];
    NSString *checkpointPath = [self.tos_root stringByAppendingPathComponent:@"foreign-target.upload.v2"];
    TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
    input.tosPartSize = TOSMinPartSize;
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = checkpointPath;
    TOSUploadCheckpointV2 *checkpoint = [self tos_checkpointForInput:input uploadID:@"foreign-upload-id"];
    checkpoint.tos_bucket = @"another-bucket";
    checkpoint.tos_key = @"another-object";
    [self tos_writeCheckpoint:checkpoint];
    NSData *before = [NSData dataWithContentsOfFile:checkpointPath];
    TOSTestUploadV2Client *client = [TOSTestUploadV2Client new];

    TOSUploadFileV2Operation *operation = [[TOSUploadFileV2Operation alloc] initWithClient:client request:input];
    [operation start];
    [self tos_waitForTask:operation.task];

    XCTAssertNotNil(operation.task.error);
    XCTAssertEqual(client.tos_abortCalls, 0);
    XCTAssertEqual(client.tos_createCalls, 0);
    XCTAssertEqual(client.tos_uploadPartCalls, 0);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:checkpointPath], before);
}

- (void)testUploadV2PreservesSameTargetIncompatibleCheckpointWhenAbortFails {
    NSString *filePath = [self tos_createFileNamed:@"abort-stale-failure.bin" size:0];
    NSString *checkpointPath = [self.tos_root stringByAppendingPathComponent:@"abort-stale-failure.upload.v2"];
    TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
    input.tosPartSize = TOSMinPartSize;
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = checkpointPath;
    TOSUploadCheckpointV2 *checkpoint = [self tos_checkpointForInput:input uploadID:@"stale-upload-id"];
    checkpoint.tos_fileModifiedTime += 1;
    [self tos_writeCheckpoint:checkpoint];
    NSData *staleData = [NSData dataWithContentsOfFile:checkpointPath];

    TOSTestUploadV2Client *client = [TOSTestUploadV2Client new];
    client.tos_abortTask = [TOSTask taskWithError:[NSError errorWithDomain:TOSServerErrorDomain
                                                                       code:500
                                                                   userInfo:nil]];
    TOSUploadFileV2Operation *operation = [[TOSUploadFileV2Operation alloc] initWithClient:client request:input];

    [operation start];
    [self tos_waitForTask:operation.task];

    XCTAssertEqual(operation.task.error.code, 500);
    XCTAssertEqual(client.tos_abortCalls, 1);
    XCTAssertEqual(client.tos_createCalls, 0);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:checkpointPath], staleData);
}

- (void)testUploadV2CancellationDoesNotRaceStaleCheckpointAbort {
    NSString *filePath = [self tos_createFileNamed:@"stale-cancel-race.bin" size:0];
    NSString *checkpointPath =
        [self.tos_root stringByAppendingPathComponent:@"stale-cancel-race.upload.v2"];
    TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
    input.tosPartSize = TOSMinPartSize;
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = checkpointPath;
    input.tosCancelHook = [TOSCancelHook new];
    TOSUploadCheckpointV2 *checkpoint =
        [self tos_checkpointForInput:input uploadID:@"stale-upload-id"];
    checkpoint.tos_fileModifiedTime += 1;
    [self tos_writeCheckpoint:checkpoint];
    NSData *before = [NSData dataWithContentsOfFile:checkpointPath];
    TOSTaskCompletionSource *abortSource = [TOSTaskCompletionSource taskCompletionSource];
    XCTestExpectation *abortStarted = [self expectationWithDescription:@"stale abort started"];
    TOSTestUploadV2Client *client = [TOSTestUploadV2Client new];
    client.tos_abortTask = abortSource.task;
    client.tos_abortObserver = ^{
        [abortStarted fulfill];
    };
    TOSUploadFileV2Operation *operation =
        [[TOSUploadFileV2Operation alloc] initWithClient:client request:input];

    [operation start];
    [self waitForExpectations:@[abortStarted] timeout:1.0];
    [input.tosCancelHook cancel:YES];
    XCTestExpectation *notFinished = [self expectationWithDescription:@"wait for abort confirmation"];
    notFinished.inverted = YES;
    [operation.task continueWithBlock:^id(TOSTask *finishedTask) {
        [notFinished fulfill];
        return nil;
    }];
    [self waitForExpectations:@[notFinished] timeout:0.05];

    XCTAssertFalse(operation.task.completed);
    XCTAssertEqual(client.tos_abortCalls, 1);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:checkpointPath], before);

    [abortSource setError:[NSError errorWithDomain:TOSServerErrorDomain code:500 userInfo:nil]];
    [self tos_waitForTask:operation.task];
    XCTAssertEqual(operation.task.error.code, 500);
    XCTAssertEqual(client.tos_abortCalls, 1);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:checkpointPath], before);
}

- (void)testUploadV2PreCancelledAbortCleansStaleCheckpointOwner {
    for (NSNumber *abortFails in @[@NO, @YES]) {
        NSString *suffix = abortFails.boolValue ? @"failure" : @"success";
        NSString *filePath = [self tos_createFileNamed:
                              [NSString stringWithFormat:@"stale-cancel-%@.bin", suffix]
                                                     size:0];
        NSString *checkpointPath = [self.tos_root stringByAppendingPathComponent:
                                    [NSString stringWithFormat:@"stale-cancel-%@.upload.v2", suffix]];
        TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
        input.tosPartSize = TOSMinPartSize;
        input.tosEnableCheckpoint = YES;
        input.tosCheckpointFile = checkpointPath;
        input.tosCancelHook = [TOSCancelHook new];
        TOSUploadCheckpointV2 *checkpoint =
            [self tos_checkpointForInput:input uploadID:@"stale-cancel-upload-id"];
        checkpoint.tos_fileModifiedTime += 1;
        [self tos_writeCheckpoint:checkpoint];
        NSData *checkpointData = [NSData dataWithContentsOfFile:checkpointPath];
        [input.tosCancelHook cancel:YES];

        TOSTestUploadV2Client *client = [TOSTestUploadV2Client new];
        if (abortFails.boolValue) {
            client.tos_abortTask =
                [TOSTask taskWithError:[NSError errorWithDomain:TOSServerErrorDomain
                                                            code:500
                                                        userInfo:nil]];
        }
        TOSUploadFileV2Operation *operation =
            [[TOSUploadFileV2Operation alloc] initWithClient:client request:input];

        [operation start];
        [self tos_waitForTask:operation.task];

        XCTAssertEqual(client.tos_abortCalls, 1);
        XCTAssertEqualObjects(client.tos_abortInputs.firstObject.tosUploadID,
                              @"stale-cancel-upload-id");
        if (abortFails.boolValue) {
            XCTAssertEqual(operation.task.error.code, 500);
            XCTAssertEqualObjects([NSData dataWithContentsOfFile:checkpointPath],
                                  checkpointData);
        } else {
            XCTAssertTrue([[self tos_messageForError:operation.task.error]
                           containsString:@"cancelled"]);
            XCTAssertFalse([[NSFileManager defaultManager]
                            fileExistsAtPath:checkpointPath]);
        }
    }
}

- (void)testUploadV2PreservesInitialCheckpointAndEmitsFailureWhenCreateFails {
    NSString *filePath = [self tos_createFileNamed:@"create-failure.bin" size:1];
    NSString *checkpointPath = [self.tos_root stringByAppendingPathComponent:@"create-failure.upload.v2"];
    TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
    input.tosPartSize = TOSMinPartSize;
    input.tosMaxRetryCount = 0;
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = checkpointPath;
    NSMutableArray<NSNumber *> *eventTypes = [NSMutableArray array];
    input.tosUploadEventListener = ^(TOSUploadEvent *event) {
        [eventTypes addObject:@(event.tosType)];
    };
    TOSTestUploadV2Client *client = [TOSTestUploadV2Client new];
    client.tos_createHandler = ^TOSTask *(TOSCreateMultipartUploadInput *createInput) {
        return [TOSTask taskWithError:[NSError errorWithDomain:TOSServerErrorDomain
                                                       code:500
                                                   userInfo:nil]];
    };
    TOSUploadFileV2Operation *operation = [[TOSUploadFileV2Operation alloc] initWithClient:client request:input];

    [operation start];
    [self tos_waitForTask:operation.task];

    XCTAssertEqual(operation.task.error.code, 500);
    XCTAssertEqual(client.tos_createCalls, 1);
    XCTAssertEqual(client.tos_uploadPartCalls, 0);
    XCTAssertEqual(client.tos_completeCalls, 0);
    XCTAssertTrue([eventTypes containsObject:@(TOSUploadEventCreateMultipartUploadFailed)]);
    NSData *data = [NSData dataWithContentsOfFile:checkpointPath];
    TOSUploadCheckpointV2 *stored = [TOSUploadCheckpointV2 tos_checkpointWithData:data
                                                                    checkpointPath:checkpointPath
                                                                               error:nil];
    XCTAssertNotNil(stored);
    XCTAssertEqualObjects(stored.tos_uploadID, @"");
}

- (void)testUploadV2RetriesTransientCreateFailureBeforeStartingParts {
    NSString *filePath = [self tos_createFileNamed:@"create-retry.bin" size:1];
    TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
    input.tosPartSize = TOSMinPartSize;
    input.tosMaxRetryCount = 1;
    NSMutableArray<NSNumber *> *eventTypes = [NSMutableArray array];
    input.tosUploadEventListener = ^(TOSUploadEvent *event) {
        [eventTypes addObject:@(event.tosType)];
    };
    TOSTestUploadV2Client *client = [TOSTestUploadV2Client new];
    __block NSInteger createAttempt = 0;
    client.tos_createHandler = ^TOSTask *(TOSCreateMultipartUploadInput *createInput) {
        createAttempt += 1;
        if (createAttempt == 1) {
            return [TOSTask taskWithError:
                    [NSError errorWithDomain:TOSClientErrorDomain
                                       code:TOSClientErrorCodeNetworkError
                                   userInfo:@{@"OriginErrorCode": @(NSURLErrorNetworkConnectionLost)}]];
        }
        return nil;
    };
    TOSUploadFileV2Operation *operation =
        [[TOSUploadFileV2Operation alloc] initWithClient:client request:input];

    [operation start];
    [self tos_waitForTask:operation.task];

    XCTAssertNil(operation.task.error);
    XCTAssertEqual(client.tos_createCalls, 2);
    XCTAssertEqual(client.tos_uploadPartCalls, 1);
    XCTAssertEqual(client.tos_completeCalls, 1);
    NSPredicate *createSuccess =
        [NSPredicate predicateWithFormat:@"self == %d", TOSUploadEventCreateMultipartUploadSucceed];
    NSPredicate *createFailure =
        [NSPredicate predicateWithFormat:@"self == %d", TOSUploadEventCreateMultipartUploadFailed];
    XCTAssertEqual([[eventTypes filteredArrayUsingPredicate:createSuccess] count], 1);
    XCTAssertEqual([[eventTypes filteredArrayUsingPredicate:createFailure] count], 0);
}

- (void)testUploadV2EmitsCreateFailureOnlyAfterRetryExhaustion {
    NSString *filePath = [self tos_createFileNamed:@"create-retry-exhausted.bin" size:1];
    TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
    input.tosPartSize = TOSMinPartSize;
    input.tosMaxRetryCount = 1;
    NSMutableArray<NSNumber *> *eventTypes = [NSMutableArray array];
    input.tosUploadEventListener = ^(TOSUploadEvent *event) {
        [eventTypes addObject:@(event.tosType)];
    };
    TOSTestUploadV2Client *client = [TOSTestUploadV2Client new];
    client.tos_createHandler = ^TOSTask *(TOSCreateMultipartUploadInput *createInput) {
        return [TOSTask taskWithError:
                [NSError errorWithDomain:TOSServerErrorDomain code:500 userInfo:nil]];
    };
    TOSUploadFileV2Operation *operation =
        [[TOSUploadFileV2Operation alloc] initWithClient:client request:input];

    [operation start];
    [self tos_waitForTask:operation.task];

    XCTAssertEqual(operation.task.error.code, 500);
    XCTAssertEqual(client.tos_createCalls, 2);
    XCTAssertEqual(client.tos_uploadPartCalls, 0);
    XCTAssertEqual(client.tos_completeCalls, 0);
    NSPredicate *createFailure =
        [NSPredicate predicateWithFormat:@"self == %d", TOSUploadEventCreateMultipartUploadFailed];
    XCTAssertEqual([[eventTypes filteredArrayUsingPredicate:createFailure] count], 1);
}

- (void)testUploadV2CancellationDuringCreateRetryBackoffFinishesPromptly {
    NSString *filePath = [self tos_createFileNamed:@"create-retry-cancel.bin" size:1];
    TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
    input.tosPartSize = TOSMinPartSize;
    input.tosMaxRetryCount = 1;
    input.tosCancelHook = [TOSCancelHook new];
    XCTestExpectation *firstAttempt = [self expectationWithDescription:@"first create attempt"];
    XCTestExpectation *secondAttempt = [self expectationWithDescription:@"unexpected create retry"];
    secondAttempt.inverted = YES;
    TOSTestUploadV2Client *client = [TOSTestUploadV2Client new];
    __block NSInteger createAttempt = 0;
    client.tos_createHandler = ^TOSTask *(TOSCreateMultipartUploadInput *createInput) {
        createAttempt += 1;
        if (createAttempt == 1) {
            XCTAssertNotNil(createInput.tos_responseObserver);
            NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc]
                initWithURL:[NSURL URLWithString:@"https://example.com/object"]
                statusCode:429
                HTTPVersion:@"HTTP/1.1"
                headerFields:@{@"Retry-After": @"60"}];
            createInput.tos_responseObserver(response);
            [firstAttempt fulfill];
        } else {
            [secondAttempt fulfill];
        }
        return [TOSTask taskWithError:
                [NSError errorWithDomain:TOSServerErrorDomain code:429 userInfo:nil]];
    };
    TOSUploadFileV2Operation *operation =
        [[TOSUploadFileV2Operation alloc] initWithClient:client request:input];

    [operation start];
    [self waitForExpectations:@[firstAttempt] timeout:1.0];
    [input.tosCancelHook cancel:NO];
    [self tos_waitForTask:operation.task];
    [self waitForExpectations:@[secondAttempt] timeout:0.2];

    XCTAssertTrue([[self tos_messageForError:operation.task.error] containsString:@"cancelled"]);
    XCTAssertEqual(client.tos_createCalls, 1);
    XCTAssertEqual(client.tos_uploadPartCalls, 0);
    XCTAssertEqual(client.tos_completeCalls, 0);
}

- (void)testUploadV2RetryRecreatesPartStreamAndEmitsOnlyFinalSuccess {
    NSString *filePath = [self tos_createFileNamed:@"retry.bin" size:1];
    TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
    input.tosPartSize = TOSMinPartSize;
    input.tosMaxRetryCount = 1;
    NSMutableArray<NSNumber *> *eventTypes = [NSMutableArray array];
    NSMutableArray<TOSDataTransferStatus *> *progress = [NSMutableArray array];
    input.tosUploadEventListener = ^(TOSUploadEvent *event) {
        [eventTypes addObject:@(event.tosType)];
    };
    input.tosDataTransferListener = ^(TOSDataTransferStatus *status) {
        [progress addObject:status];
    };
    TOSTestUploadV2Client *client = [TOSTestUploadV2Client new];
    client.tos_uploadPartHandler = ^TOSTask *(TOSUploadPartFromStreamInput *partInput, NSInteger callIndex) {
        if (callIndex == 0) {
            [partInput.tosInputStream open];
            uint8_t buffer[16];
            while ([partInput.tosInputStream read:buffer maxLength:sizeof(buffer)] > 0) {
            }
            [partInput.tosInputStream close];
            NSError *error = [NSError errorWithDomain:TOSServerErrorDomain code:500 userInfo:nil];
            return [TOSTask taskWithError:error];
        }
        return nil;
    };
    TOSUploadFileV2Operation *operation = [[TOSUploadFileV2Operation alloc] initWithClient:client request:input];

    [operation start];
    [self tos_waitForTask:operation.task];

    XCTAssertNil(operation.task.error);
    XCTAssertEqual(client.tos_uploadPartCalls, 2);
    XCTAssertNotEqual(client.tos_uploadPartInputs[0].tosInputStream,
                      client.tos_uploadPartInputs[1].tosInputStream);
    NSPredicate *partSuccess = [NSPredicate predicateWithFormat:@"self == %d", TOSUploadEventUploadPartSucceed];
    XCTAssertEqual([[eventTypes filteredArrayUsingPredicate:partSuccess] count], 1);
    NSPredicate *partFailure = [NSPredicate predicateWithFormat:@"self == %d", TOSUploadEventUploadPartFailed];
    XCTAssertEqual([[eventTypes filteredArrayUsingPredicate:partFailure] count], 0);
    for (TOSDataTransferStatus *status in progress) {
        XCTAssertLessThanOrEqual(status.tosConsumedBytes, status.tosTotalBytes);
    }
    XCTAssertEqual(progress.lastObject.tosConsumedBytes, 1);
}

- (void)testUploadV2HonorsRetryAfterFromPartResponse {
    NSString *filePath = [self tos_createFileNamed:@"retry-after.bin" size:1];
    TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
    input.tosPartSize = TOSMinPartSize;
    input.tosMaxRetryCount = 1;
    input.tosCancelHook = [TOSCancelHook new];
    XCTestExpectation *firstAttempt = [self expectationWithDescription:@"first upload attempt"];
    XCTestExpectation *secondAttempt = [self expectationWithDescription:@"unexpected upload retry"];
    secondAttempt.inverted = YES;
    TOSTestUploadV2Client *client = [TOSTestUploadV2Client new];
    client.tos_uploadPartHandler =
        ^TOSTask *(TOSUploadPartFromStreamInput *partInput, NSInteger callIndex) {
            if (callIndex == 0) {
                XCTAssertNotNil(partInput.tos_responseObserver);
                if (partInput.tos_responseObserver) {
                    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc]
                        initWithURL:[NSURL URLWithString:@"https://example.com/object"]
                        statusCode:429
                        HTTPVersion:@"HTTP/1.1"
                        headerFields:@{@"Retry-After": @"60"}];
                    partInput.tos_responseObserver(response);
                }
                [firstAttempt fulfill];
            } else {
                [secondAttempt fulfill];
            }
            return [TOSTask taskWithError:
                    [NSError errorWithDomain:TOSServerErrorDomain code:429 userInfo:@{}]];
        };
    TOSUploadFileV2Operation *operation =
        [[TOSUploadFileV2Operation alloc] initWithClient:client request:input];

    [operation start];
    [self waitForExpectations:@[firstAttempt] timeout:1.0];
    [self waitForExpectations:@[secondAttempt] timeout:0.5];
    XCTAssertEqual(client.tos_uploadPartCalls, 1);
    [input.tosCancelHook cancel:NO];
    [self tos_waitForTask:operation.task];

    XCTAssertTrue([[self tos_messageForError:operation.task.error] containsString:@"cancelled"]);
}

- (void)testUploadV2RejectsUnconsumedPartResponseAndNeverCompletes {
    NSString *filePath = [self tos_createFileNamed:@"unconsumed.bin" size:1];
    TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
    input.tosPartSize = TOSMinPartSize;
    TOSTestUploadV2Client *client = [TOSTestUploadV2Client new];
    client.tos_uploadPartHandler = ^TOSTask *(TOSUploadPartFromStreamInput *partInput, NSInteger callIndex) {
        TOSUploadPartFromStreamOutput *output = [TOSUploadPartFromStreamOutput new];
        output.tosETag = @"etag";
        return [TOSTask taskWithResult:output];
    };
    TOSUploadFileV2Operation *operation = [[TOSUploadFileV2Operation alloc] initWithClient:client request:input];

    [operation start];
    [self tos_waitForTask:operation.task];

    XCTAssertTrue([[self tos_messageForError:operation.task.error] containsString:@"expected byte range"]);
    XCTAssertEqual(client.tos_completeCalls, 0);
    XCTAssertEqual(client.tos_abortCalls, 1);
}

- (void)testUploadV2UnconsumedPartResponsePreservesEnabledCheckpoint {
    NSString *filePath = [self tos_createFileNamed:@"unconsumed-checkpoint.bin" size:1];
    NSString *checkpointPath =
        [self.tos_root stringByAppendingPathComponent:@"unconsumed.upload.v2"];
    TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
    input.tosPartSize = TOSMinPartSize;
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = checkpointPath;
    TOSTestUploadV2Client *client = [TOSTestUploadV2Client new];
    client.tos_uploadPartHandler = ^TOSTask *(TOSUploadPartFromStreamInput *partInput,
                                               NSInteger callIndex) {
        TOSUploadPartFromStreamOutput *output = [TOSUploadPartFromStreamOutput new];
        output.tosETag = @"etag";
        return [TOSTask taskWithResult:output];
    };
    TOSUploadFileV2Operation *operation =
        [[TOSUploadFileV2Operation alloc] initWithClient:client request:input];

    [operation start];
    [self tos_waitForTask:operation.task];

    XCTAssertTrue([[self tos_messageForError:operation.task.error] containsString:@"expected byte range"]);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:checkpointPath]);
    XCTAssertEqual(client.tos_completeCalls, 0);
    XCTAssertEqual(client.tos_abortCalls, 0);
}

- (void)testUploadV2RejectsMissingETagAndCRCMismatch {
    NSArray<NSString *> *modes = @[@"etag", @"crc"];
    for (NSString *mode in modes) {
        NSString *filePath = [self tos_createFileNamed:[mode stringByAppendingString:@".bin"] size:1];
        TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
        input.tosPartSize = TOSMinPartSize;
        TOSTestUploadV2Client *client = [TOSTestUploadV2Client new];
        client.tos_uploadPartHandler = ^TOSTask *(TOSUploadPartFromStreamInput *partInput, NSInteger callIndex) {
            TOSFileRangeInputStream *stream = (TOSFileRangeInputStream *)partInput.tosInputStream;
            [stream open];
            uint8_t buffer[16];
            while ([stream read:buffer maxLength:sizeof(buffer)] > 0) {
            }
            TOSUploadPartFromStreamOutput *output = [TOSUploadPartFromStreamOutput new];
            if ([mode isEqualToString:@"etag"]) {
                output.tosETag = @"";
            } else {
                output.tosETag = @"etag";
                output.tosHashCrc64ecma = stream.tos_crc64 + 1;
                output.tosHeader = @{ @"X-Tos-Hash-Crc64ecma": [NSString stringWithFormat:@"%llu", output.tosHashCrc64ecma] };
            }
            return [TOSTask taskWithResult:output];
        };
        TOSUploadFileV2Operation *operation = [[TOSUploadFileV2Operation alloc] initWithClient:client request:input];

        [operation start];
        [self tos_waitForTask:operation.task];

        NSString *expected = [mode isEqualToString:@"etag"] ? @"ETag" : @"crc";
        XCTAssertTrue([[self tos_messageForError:operation.task.error] containsString:expected]);
        XCTAssertEqual(client.tos_completeCalls, 0);
    }
}

- (void)testUploadV2PersistsCompletedPartBeforeSuccessEvent {
    NSString *filePath = [self tos_createFileNamed:@"event-order.bin" size:1];
    NSString *checkpointPath = [self.tos_root stringByAppendingPathComponent:@"event-order.upload.v2"];
    TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
    input.tosPartSize = TOSMinPartSize;
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = checkpointPath;
    __block BOOL persistedBeforeEvent = NO;
    input.tosUploadEventListener = ^(TOSUploadEvent *event) {
        if (event.tosType != TOSUploadEventUploadPartSucceed) {
            return;
        }
        NSData *data = [NSData dataWithContentsOfFile:checkpointPath];
        TOSUploadCheckpointV2 *stored = [TOSUploadCheckpointV2 tos_checkpointWithData:data
                                                                        checkpointPath:checkpointPath
                                                                                   error:nil];
        persistedBeforeEvent = stored.tos_parts.firstObject.tos_completed &&
                               stored.tos_parts.firstObject.tos_eTag.length > 0;
    };
    TOSUploadFileV2Operation *operation = [[TOSUploadFileV2Operation alloc]
                                           initWithClient:[TOSTestUploadV2Client new]
                                           request:input];

    [operation start];
    [self tos_waitForTask:operation.task];

    XCTAssertNil(operation.task.error);
    XCTAssertTrue(persistedBeforeEvent);
}

- (void)testUploadV2PreservesCheckpointOnNonfatalPartFailure {
    NSString *filePath = [self tos_createFileNamed:@"preserve.bin" size:1];
    NSString *checkpointPath = [self.tos_root stringByAppendingPathComponent:@"preserve.upload.v2"];
    TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
    input.tosPartSize = TOSMinPartSize;
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = checkpointPath;
    TOSTestUploadV2Client *client = [TOSTestUploadV2Client new];
    client.tos_uploadPartHandler = ^TOSTask *(TOSUploadPartFromStreamInput *partInput, NSInteger callIndex) {
        return [TOSTask taskWithError:[NSError errorWithDomain:TOSServerErrorDomain code:400 userInfo:nil]];
    };
    TOSUploadFileV2Operation *operation = [[TOSUploadFileV2Operation alloc] initWithClient:client request:input];

    [operation start];
    [self tos_waitForTask:operation.task];

    XCTAssertNotNil(operation.task.error);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:checkpointPath]);
    XCTAssertEqual(client.tos_abortCalls, 0);
    XCTAssertEqual(client.tos_completeCalls, 0);
}

- (void)testUploadV2AbortsMultipartOnPartFailureWithoutCheckpoint {
    NSString *filePath = [self tos_createFileNamed:@"no-checkpoint-failure.bin" size:1];
    TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
    input.tosPartSize = TOSMinPartSize;
    TOSTestUploadV2Client *client = [TOSTestUploadV2Client new];
    client.tos_uploadPartHandler = ^TOSTask *(TOSUploadPartFromStreamInput *partInput,
                                               NSInteger callIndex) {
        return [TOSTask taskWithError:[NSError errorWithDomain:TOSServerErrorDomain
                                                          code:400
                                                      userInfo:nil]];
    };

    TOSUploadFileV2Operation *operation =
        [[TOSUploadFileV2Operation alloc] initWithClient:client request:input];
    [operation start];
    [self tos_waitForTask:operation.task];

    XCTAssertNotNil(operation.task.error);
    XCTAssertEqual(client.tos_abortCalls, 1);
    XCTAssertEqual(client.tos_completeCalls, 0);
    XCTAssertEqualObjects(client.tos_abortInputs.firstObject.tosUploadID, @"new-upload-id");
}

- (void)testUploadV2AbortsAndRemovesCheckpointForFatalPartStatus {
    for (NSNumber *statusCode in @[@403, @404, @405]) {
        NSString *filePath = [self tos_createFileNamed:[NSString stringWithFormat:@"fatal-%@.bin", statusCode] size:1];
        NSString *checkpointPath = [self.tos_root stringByAppendingPathComponent:[NSString stringWithFormat:@"fatal-%@.upload.v2", statusCode]];
        TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
        input.tosPartSize = TOSMinPartSize;
        input.tosEnableCheckpoint = YES;
        input.tosCheckpointFile = checkpointPath;
        TOSTestUploadV2Client *client = [TOSTestUploadV2Client new];
        client.tos_uploadPartHandler = ^TOSTask *(TOSUploadPartFromStreamInput *partInput, NSInteger callIndex) {
            NSError *error = [NSError errorWithDomain:TOSServerErrorDomain code:statusCode.integerValue userInfo:nil];
            return [TOSTask taskWithError:error];
        };
        TOSUploadFileV2Operation *operation = [[TOSUploadFileV2Operation alloc] initWithClient:client request:input];

        [operation start];
        [self tos_waitForTask:operation.task];

        XCTAssertNotNil(operation.task.error);
        XCTAssertEqual(client.tos_abortCalls, 1);
        XCTAssertEqual(client.tos_completeCalls, 0);
        XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:checkpointPath]);
    }
}

- (void)testUploadV2CompletesWithSortedPartsCallbacksHeadersAndTerminalProgress {
    NSString *filePath = [self tos_createFileNamed:@"complete.bin" size:TOSMinPartSize + 1];
    TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
    input.tosPartSize = TOSMinPartSize;
    input.tosTaskNum = 1001;
    input.tosTrafficLimit = 8192;
    input.tosCallback = @"callback";
    input.tosCallbackVar = @"callback-var";
    NSMutableArray<TOSDataTransferStatus *> *progress = [NSMutableArray array];
    input.tosDataTransferListener = ^(TOSDataTransferStatus *status) {
        [progress addObject:status];
    };
    TOSTestUploadV2Client *client = [TOSTestUploadV2Client new];
    TOSUploadFileV2Operation *operation = [[TOSUploadFileV2Operation alloc] initWithClient:client request:input];

    [operation start];
    [self tos_waitForTask:operation.task];

    XCTAssertNil(operation.task.error);
    XCTAssertEqual(operation.request.tosTaskNum, 1000);
    XCTAssertEqual(input.tosTaskNum, 1001);
    XCTAssertEqual(client.tos_completeCalls, 1);
    XCTAssertEqualObjects(client.tos_completeInput.tosCallback, @"callback");
    XCTAssertEqualObjects(client.tos_completeInput.tosCallbackVar, @"callback-var");
    XCTAssertEqual(client.tos_completeInput.tosParts.count, 2);
    XCTAssertEqual(client.tos_completeInput.tosParts[0].tosPartNumber, 1);
    XCTAssertEqual(client.tos_completeInput.tosParts[1].tosPartNumber, 2);
    for (TOSUploadPartFromStreamInput *partInput in client.tos_uploadPartInputs) {
        NSString *expectedContentLength = [NSString stringWithFormat:@"%lld", partInput.tosContentLength];
        XCTAssertEqualObjects(partInput.tos_transferHeaders[@"Content-Length"],
                              expectedContentLength);
        XCTAssertEqualObjects(partInput.tos_transferHeaders[@"x-tos-traffic-limit"], @"8192");
    }
    TOSUploadFileOutputV2 *output = operation.task.result;
    XCTAssertEqualObjects(output.tosUploadID, @"new-upload-id");
    XCTAssertEqualObjects(output.tosCallbackResult, @"callback-result");
    XCTAssertEqual(progress.firstObject.tosType, TOSDataTransferStarted);
    XCTAssertEqual(progress.lastObject.tosType, TOSDataTransferSucceed);
    XCTAssertEqual(progress.lastObject.tosConsumedBytes, TOSMinPartSize + 1);
}

- (void)testUploadV2StartsSixPartsWhenTaskNumIsSix {
    NSString *filePath = [self tos_createFileNamed:@"six-parts.bin"
                                               size:TOSMinPartSize * 6];
    TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
    input.tosPartSize = TOSMinPartSize;
    input.tosTaskNum = 6;
    input.tosMaxRetryCount = 0;
    NSMutableArray<TOSTaskCompletionSource *> *sources = [NSMutableArray array];
    XCTestExpectation *initialWave = [self expectationWithDescription:@"five upload parts started"];
    initialWave.expectedFulfillmentCount = 5;
    XCTestExpectation *sixthStarted = [self expectationWithDescription:@"sixth upload part started"];
    TOSTestUploadV2Client *client = [TOSTestUploadV2Client new];
    client.tos_uploadPartHandler = ^TOSTask *(TOSUploadPartFromStreamInput *partInput,
                                               NSInteger callIndex) {
        TOSTaskCompletionSource *source = [TOSTaskCompletionSource taskCompletionSource];
        [sources addObject:source];
        if (callIndex < 5) {
            [initialWave fulfill];
        } else {
            [sixthStarted fulfill];
        }
        return source.task;
    };
    TOSUploadFileV2Operation *operation = [[TOSUploadFileV2Operation alloc] initWithClient:client
                                                                                   request:input];

    [operation start];
    [self waitForExpectations:@[initialWave] timeout:2.0];
    XCTAssertEqual(client.tos_uploadPartCalls, 5);

    TOSUploadPartFromStreamInput *firstInput = client.tos_uploadPartInputs.firstObject;
    TOSFileRangeInputStream *firstStream = (TOSFileRangeInputStream *)firstInput.tosInputStream;
    [firstStream open];
    uint8_t buffer[4096];
    while ([firstStream read:buffer maxLength:sizeof(buffer)] > 0) {
    }
    TOSUploadPartFromStreamOutput *firstOutput = [TOSUploadPartFromStreamOutput new];
    firstOutput.tosPartNumber = firstInput.tosPartNumber;
    firstOutput.tosETag = @"etag-first";
    firstOutput.tosHashCrc64ecma = firstStream.tos_crc64;
    firstOutput.tosHeader = @{ @"x-tos-hash-crc64ecma":
                               [NSString stringWithFormat:@"%llu", firstStream.tos_crc64] };
    [firstStream close];
    [sources.firstObject setResult:firstOutput];
    [self waitForExpectations:@[sixthStarted] timeout:2.0];

    XCTAssertEqual(client.tos_uploadPartCalls, 6);
    XCTAssertEqual(operation.request.tosTaskNum, 6);
    NSMutableSet<NSNumber *> *descriptors = [NSMutableSet set];
    for (NSUInteger index = 1; index < client.tos_uploadPartInputs.count; index++) {
        TOSUploadPartFromStreamInput *partInput = client.tos_uploadPartInputs[index];
        [descriptors addObject:@(((TOSFileRangeInputStream *)partInput.tosInputStream).tos_fileDescriptor)];
    }
    XCTAssertEqual(descriptors.count, 1);
    for (TOSTaskCompletionSource *source in sources) {
        [source trySetError:[NSError errorWithDomain:TOSServerErrorDomain code:400 userInfo:nil]];
    }
    [self tos_waitForTask:operation.task];
    XCTAssertNotNil(operation.task.error);
}

- (void)testUploadV2DetectsSourceReplacementBeforeComplete {
    NSString *filePath = [self tos_createFileNamed:@"source-change.bin" size:1];
    NSString *checkpointPath = [self.tos_root stringByAppendingPathComponent:@"source-change.upload.v2"];
    TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
    input.tosPartSize = TOSMinPartSize;
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = checkpointPath;
    TOSTestUploadV2Client *client = [TOSTestUploadV2Client new];
    client.tos_afterPartConsumed = ^(TOSUploadPartFromStreamInput *partInput, TOSFileRangeInputStream *stream) {
        NSData *replacement = [@"x" dataUsingEncoding:NSUTF8StringEncoding];
        XCTAssertTrue([replacement writeToFile:filePath atomically:YES]);
    };
    TOSUploadFileV2Operation *operation = [[TOSUploadFileV2Operation alloc] initWithClient:client request:input];

    [operation start];
    [self tos_waitForTask:operation.task];

    XCTAssertTrue([[self tos_messageForError:operation.task.error] containsString:@"source file changed"]);
    XCTAssertEqual(client.tos_completeCalls, 0);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:checkpointPath]);
}

- (void)testUploadV2PreservesCheckpointOnCompleteServerFailure {
    NSString *filePath = [self tos_createFileNamed:@"server-complete.bin" size:1];
    NSString *checkpointPath = [self.tos_root stringByAppendingPathComponent:@"server.upload.v2"];
    TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
    input.tosPartSize = TOSMinPartSize;
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = checkpointPath;
    TOSTestUploadV2Client *client = [TOSTestUploadV2Client new];
    client.tos_completeHandler = ^TOSTask *(TOSCompleteMultipartUploadInput *completeInput) {
        return [TOSTask taskWithError:[NSError errorWithDomain:TOSServerErrorDomain
                                                          code:400
                                                      userInfo:nil]];
    };
    TOSUploadFileV2Operation *operation =
        [[TOSUploadFileV2Operation alloc] initWithClient:client request:input];

    [operation start];
    [self tos_waitForTask:operation.task];

    XCTAssertNotNil(operation.task.error);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:checkpointPath]);
}

- (void)testUploadV2AbortsMultipartOnCompleteFailureWithoutCheckpoint {
    NSString *filePath = [self tos_createFileNamed:@"complete-no-checkpoint.bin" size:1];
    TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
    input.tosPartSize = TOSMinPartSize;
    TOSTestUploadV2Client *client = [TOSTestUploadV2Client new];
    client.tos_completeHandler = ^TOSTask *(TOSCompleteMultipartUploadInput *completeInput) {
        return [TOSTask taskWithError:[NSError errorWithDomain:TOSServerErrorDomain
                                                          code:400
                                                      userInfo:nil]];
    };
    TOSUploadFileV2Operation *operation =
        [[TOSUploadFileV2Operation alloc] initWithClient:client request:input];

    [operation start];
    [self tos_waitForTask:operation.task];

    XCTAssertEqual(operation.task.error.code, 400);
    XCTAssertEqual(client.tos_abortCalls, 1);
    XCTAssertEqual(client.tos_completeCalls, 1);
}

- (void)testUploadV2RejectsEmptyCompleteResponseAndPreservesCheckpoint {
    NSString *filePath = [self tos_createFileNamed:@"empty-complete.bin" size:1];
    NSString *checkpointPath = [self.tos_root stringByAppendingPathComponent:@"empty-complete.upload.v2"];
    TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
    input.tosPartSize = TOSMinPartSize;
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = checkpointPath;
    NSMutableArray<NSNumber *> *eventTypes = [NSMutableArray array];
    input.tosUploadEventListener = ^(TOSUploadEvent *event) {
        [eventTypes addObject:@(event.tosType)];
    };
    TOSTestUploadV2Client *client = [TOSTestUploadV2Client new];
    client.tos_completeHandler = ^TOSTask *(TOSCompleteMultipartUploadInput *completeInput) {
        return [TOSTask taskWithResult:[TOSCompleteMultipartUploadOutput new]];
    };
    TOSUploadFileV2Operation *operation =
        [[TOSUploadFileV2Operation alloc] initWithClient:client request:input];

    [operation start];
    [self tos_waitForTask:operation.task];

    XCTAssertNotNil(operation.task.error);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:checkpointPath]);
    XCTAssertTrue([eventTypes containsObject:@(TOSUploadEventCompleteMultipartUploadFailed)]);
    XCTAssertFalse([eventTypes containsObject:@(TOSUploadEventCompleteMultipartUploadSucceed)]);
}

- (void)testUploadV2AcceptsCallbackCompleteResponseWithETagOnly {
    NSString *filePath = [self tos_createFileNamed:@"callback-complete.bin" size:1];
    TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
    input.tosPartSize = TOSMinPartSize;
    input.tosCallback = @"callback";
    TOSTestUploadV2Client *client = [TOSTestUploadV2Client new];
    client.tos_completeHandler = ^TOSTask *(TOSCompleteMultipartUploadInput *completeInput) {
        TOSCompleteMultipartUploadOutput *output = [TOSCompleteMultipartUploadOutput new];
        output.tosETag = @"callback-etag";
        output.tosCallbackResult = @"callback-result";
        return [TOSTask taskWithResult:output];
    };
    TOSUploadFileV2Operation *operation =
        [[TOSUploadFileV2Operation alloc] initWithClient:client request:input];

    [operation start];
    [self tos_waitForTask:operation.task];

    XCTAssertNil(operation.task.error);
    XCTAssertEqualObjects(((TOSUploadFileOutputV2 *)operation.task.result).tosETag, @"callback-etag");
    XCTAssertEqualObjects(((TOSUploadFileOutputV2 *)operation.task.result).tosCallbackResult,
                          @"callback-result");
}

- (void)testUploadV2RemovesCheckpointAfterCompleteSuccessWithCRCMismatch {
    NSString *filePath = [self tos_createFileNamed:@"crc-complete.bin" size:1];
    NSString *checkpointPath = [self.tos_root stringByAppendingPathComponent:@"crc.upload.v2"];
    TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
    input.tosPartSize = TOSMinPartSize;
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = checkpointPath;
    NSMutableArray<NSNumber *> *eventTypes = [NSMutableArray array];
    input.tosUploadEventListener = ^(TOSUploadEvent *event) {
        [eventTypes addObject:@(event.tosType)];
    };
    TOSTestUploadV2Client *client = [TOSTestUploadV2Client new];
    client.tos_completeHandler = ^TOSTask *(TOSCompleteMultipartUploadInput *completeInput) {
        TOSCompleteMultipartUploadOutput *output = [TOSCompleteMultipartUploadOutput new];
        output.tosBucket = completeInput.tosBucket;
        output.tosKey = completeInput.tosKey;
        output.tosETag = @"complete-etag";
        output.tosLocation = @"location";
        output.tosHashCrc64ecma = 1;
        output.tosHeader = @{ @"x-tos-hash-crc64ecma": @"1" };
        return [TOSTask taskWithResult:output];
    };
    TOSUploadFileV2Operation *operation =
        [[TOSUploadFileV2Operation alloc] initWithClient:client request:input];

    [operation start];
    [self tos_waitForTask:operation.task];

    XCTAssertNotNil(operation.task.error);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:checkpointPath]);
    XCTAssertTrue([eventTypes containsObject:@(TOSUploadEventCompleteMultipartUploadFailed)]);
    XCTAssertFalse([eventTypes containsObject:@(TOSUploadEventCompleteMultipartUploadSucceed)]);
}

- (void)testUploadV2RemovesCheckpointOnlyForConfirmedNoSuchUploadOnComplete {
    NSString *filePath = [self tos_createFileNamed:@"no-such-upload.bin" size:1];
    NSString *checkpointPath = [self.tos_root stringByAppendingPathComponent:@"no-such-upload.upload.v2"];
    TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
    input.tosPartSize = TOSMinPartSize;
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = checkpointPath;
    TOSTestUploadV2Client *client = [TOSTestUploadV2Client new];
    client.tos_completeHandler = ^TOSTask *(TOSCompleteMultipartUploadInput *completeInput) {
        NSError *error = [NSError errorWithDomain:TOSServerErrorDomain
                                             code:404
                                         userInfo:@{ @"Code": @"NoSuchUpload" }];
        return [TOSTask taskWithError:error];
    };
    TOSUploadFileV2Operation *operation = [[TOSUploadFileV2Operation alloc] initWithClient:client request:input];

    [operation start];
    [self tos_waitForTask:operation.task];

    XCTAssertNotNil(operation.task.error);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:checkpointPath]);
}

- (void)testUploadV2CancelWithoutAbortPreservesCheckpoint {
    NSString *filePath = [self tos_createFileNamed:@"cancel-resume.bin" size:1];
    NSString *checkpointPath = [self.tos_root stringByAppendingPathComponent:@"cancel-resume.upload.v2"];
    TOSCancelHook *cancelHook = [TOSCancelHook new];
    TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
    input.tosPartSize = TOSMinPartSize;
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = checkpointPath;
    input.tosCancelHook = cancelHook;
    TOSTaskCompletionSource *partSource = [TOSTaskCompletionSource taskCompletionSource];
    XCTestExpectation *partStarted = [self expectationWithDescription:@"part started"];
    TOSTestUploadV2Client *client = [TOSTestUploadV2Client new];
    client.tos_uploadPartHandler = ^TOSTask *(TOSUploadPartFromStreamInput *partInput, NSInteger callIndex) {
        [partStarted fulfill];
        return partSource.task;
    };
    TOSUploadFileV2Operation *operation = [[TOSUploadFileV2Operation alloc] initWithClient:client request:input];
    [operation start];
    [self waitForExpectations:@[partStarted] timeout:1.0];

    [cancelHook cancel:NO];
    [partSource setError:[NSError errorWithDomain:TOSClientErrorDomain
                                              code:TOSClientErrorCodeTaskCancelled
                                          userInfo:nil]];
    [self tos_waitForTask:operation.task];

    XCTAssertTrue([[self tos_messageForError:operation.task.error] containsString:@"cancelled"]);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:checkpointPath]);
    XCTAssertEqual(client.tos_abortCalls, 0);
    XCTAssertEqual(client.tos_completeCalls, 0);
}

- (void)testUploadV2CancelWithoutCheckpointAlwaysAbortsMultipart {
    NSString *filePath = [self tos_createFileNamed:@"cancel-no-checkpoint.bin" size:1];
    TOSCancelHook *cancelHook = [TOSCancelHook new];
    TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
    input.tosPartSize = TOSMinPartSize;
    input.tosCancelHook = cancelHook;
    NSMutableArray<TOSUploadEvent *> *events = [NSMutableArray array];
    input.tosUploadEventListener = ^(TOSUploadEvent *event) {
        [events addObject:event];
    };
    TOSTaskCompletionSource *partSource = [TOSTaskCompletionSource taskCompletionSource];
    XCTestExpectation *partStarted = [self expectationWithDescription:@"part started"];
    TOSTestUploadV2Client *client = [TOSTestUploadV2Client new];
    client.tos_uploadPartHandler = ^TOSTask *(TOSUploadPartFromStreamInput *partInput,
                                               NSInteger callIndex) {
        [partStarted fulfill];
        return partSource.task;
    };
    TOSUploadFileV2Operation *operation =
        [[TOSUploadFileV2Operation alloc] initWithClient:client request:input];
    [operation start];
    [self waitForExpectations:@[partStarted] timeout:1.0];

    [cancelHook cancel:NO];
    [partSource setError:[NSError errorWithDomain:TOSClientErrorDomain
                                              code:TOSClientErrorCodeTaskCancelled
                                          userInfo:nil]];
    [self tos_waitForTask:operation.task];

    XCTAssertTrue([[self tos_messageForError:operation.task.error] containsString:@"cancelled"]);
    XCTAssertEqual(client.tos_abortCalls, 1);
    XCTAssertEqual(client.tos_completeCalls, 0);
    NSPredicate *partFailure = [NSPredicate predicateWithBlock:^BOOL(TOSUploadEvent *event,
                                                                     NSDictionary *bindings) {
        return event.tosType == TOSUploadEventUploadPartFailed;
    }];
    XCTAssertEqual([[events filteredArrayUsingPredicate:partFailure] count], 0);
}

- (void)testUploadV2EmitsOnlyRootFailureWhenSiblingPartIsCancelled {
    NSString *filePath = [self tos_createFileNamed:@"sibling-cancel.bin"
                                             size:TOSMinPartSize + 1];
    TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
    input.tosPartSize = TOSMinPartSize;
    input.tosTaskNum = 2;
    NSMutableArray<TOSUploadEvent *> *events = [NSMutableArray array];
    XCTestExpectation *rootFailureEvent = [self expectationWithDescription:@"root part failure emitted"];
    input.tosUploadEventListener = ^(TOSUploadEvent *event) {
        [events addObject:event];
        if (event.tosType == TOSUploadEventUploadPartFailed && event.tosErr.code == 400) {
            [rootFailureEvent fulfill];
        }
    };
    TOSTaskCompletionSource *firstPartSource = [TOSTaskCompletionSource taskCompletionSource];
    TOSTaskCompletionSource *secondPartSource = [TOSTaskCompletionSource taskCompletionSource];
    XCTestExpectation *partsStarted = [self expectationWithDescription:@"both parts started"];
    partsStarted.expectedFulfillmentCount = 2;
    TOSTestUploadV2Client *client = [TOSTestUploadV2Client new];
    client.tos_uploadPartHandler = ^TOSTask *(TOSUploadPartFromStreamInput *partInput,
                                               NSInteger callIndex) {
        [partsStarted fulfill];
        return callIndex == 0 ? firstPartSource.task : secondPartSource.task;
    };
    TOSUploadFileV2Operation *operation =
        [[TOSUploadFileV2Operation alloc] initWithClient:client request:input];
    [operation start];
    [self waitForExpectations:@[partsStarted] timeout:1.0];

    [firstPartSource setError:[NSError errorWithDomain:TOSServerErrorDomain
                                                  code:400
                                              userInfo:nil]];
    [self waitForExpectations:@[rootFailureEvent] timeout:1.0];
    [secondPartSource setError:[NSError errorWithDomain:TOSClientErrorDomain
                                                   code:TOSClientErrorCodeTaskCancelled
                                               userInfo:nil]];
    [self tos_waitForTask:operation.task];

    NSPredicate *partFailure = [NSPredicate predicateWithBlock:^BOOL(TOSUploadEvent *event,
                                                                     NSDictionary *bindings) {
        return event.tosType == TOSUploadEventUploadPartFailed;
    }];
    NSArray<TOSUploadEvent *> *partFailures = [events filteredArrayUsingPredicate:partFailure];
    XCTAssertEqual(partFailures.count, 1);
    XCTAssertEqual(partFailures.firstObject.tosErr.code, 400);
}

- (void)testUploadV2DoesNotEmitPartEventAfterOperationFinished {
    NSString *filePath = [self tos_createFileNamed:@"late-part-event.bin" size:1];
    TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
    input.tosPartSize = TOSMinPartSize;
    NSMutableArray<TOSUploadEvent *> *events = [NSMutableArray array];
    input.tosUploadEventListener = ^(TOSUploadEvent *event) {
        [events addObject:event];
    };
    TOSTaskCompletionSource *partSource = [TOSTaskCompletionSource taskCompletionSource];
    XCTestExpectation *partStarted = [self expectationWithDescription:@"part started"];
    TOSTestUploadV2Client *client = [TOSTestUploadV2Client new];
    client.tos_uploadPartHandler = ^TOSTask *(TOSUploadPartFromStreamInput *partInput,
                                               NSInteger callIndex) {
        [partStarted fulfill];
        return partSource.task;
    };
    TOSUploadFileV2Operation *operation =
        [[TOSUploadFileV2Operation alloc] initWithClient:client request:input];
    [operation start];
    [self waitForExpectations:@[partStarted] timeout:1.0];

    [operation tos_finishWithOutput:nil
                              error:[NSError errorWithDomain:TOSClientErrorDomain
                                                       code:TOSClientErrorCodeTaskCancelled
                                                   userInfo:nil]];
    [partSource setError:[NSError errorWithDomain:TOSClientErrorDomain
                                             code:TOSClientErrorCodeTaskCancelled
                                         userInfo:nil]];
    dispatch_sync(operation.tos_stateQueue, ^{
    });
    [self tos_waitForTask:operation.tos_partOperation.task];

    NSPredicate *partEvent = [NSPredicate predicateWithBlock:^BOOL(TOSUploadEvent *event,
                                                                   NSDictionary *bindings) {
        return event.tosType == TOSUploadEventUploadPartSucceed ||
               event.tosType == TOSUploadEventUploadPartFailed ||
               event.tosType == TOSUploadEventUploadPartAborted;
    }];
    XCTAssertEqual([[events filteredArrayUsingPredicate:partEvent] count], 0);
}

- (void)testUploadV2IgnoresLatePartCompletionAfterOperationIsReleased {
    NSString *filePath = [self tos_createFileNamed:@"late-part-completion.bin" size:1];
    TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
    input.tosPartSize = TOSMinPartSize;
    TOSTaskCompletionSource *partSource = [TOSTaskCompletionSource taskCompletionSource];
    XCTestExpectation *partStarted = [self expectationWithDescription:@"part started"];
    TOSTestUploadV2Client *client = [TOSTestUploadV2Client new];
    client.tos_uploadPartHandler = ^TOSTask *(TOSUploadPartFromStreamInput *partInput,
                                               NSInteger callIndex) {
        [partStarted fulfill];
        return partSource.task;
    };

    __weak TOSUploadFileV2Operation *weakOperation = nil;
    @autoreleasepool {
        TOSUploadFileV2Operation *operation =
            [[TOSUploadFileV2Operation alloc] initWithClient:client request:input];
        weakOperation = operation;
        [operation start];
        [self waitForExpectations:@[partStarted] timeout:1.0];
        [operation tos_finishWithOutput:nil
                                 error:[NSError errorWithDomain:TOSClientErrorDomain
                                                          code:TOSClientErrorCodeTaskCancelled
                                                      userInfo:nil]];
        operation = nil;
    }
    XCTAssertNil(weakOperation);

    XCTestExpectation *partCompleted = [self expectationWithDescription:@"late part completion delivered"];
    [partSource.task continueWithBlock:^id(TOSTask *task) {
        [partCompleted fulfill];
        return nil;
    }];
    [partSource setError:[NSError errorWithDomain:TOSClientErrorDomain
                                              code:TOSClientErrorCodeTaskCancelled
                                          userInfo:nil]];
    [self waitForExpectations:@[partCompleted] timeout:1.0];
}

- (void)testUploadV2CancelWithAbortDeletesOnlyAfterConfirmedAbort {
    for (NSNumber *abortFails in @[@NO, @YES]) {
        NSString *name = abortFails.boolValue ? @"abort-fails" : @"abort-succeeds";
        NSString *filePath = [self tos_createFileNamed:[name stringByAppendingString:@".bin"] size:1];
        NSString *checkpointPath = [self.tos_root stringByAppendingPathComponent:[name stringByAppendingString:@".upload.v2"]];
        TOSCancelHook *cancelHook = [TOSCancelHook new];
        TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
        input.tosPartSize = TOSMinPartSize;
        input.tosEnableCheckpoint = YES;
        input.tosCheckpointFile = checkpointPath;
        input.tosCancelHook = cancelHook;
        TOSTaskCompletionSource *partSource = [TOSTaskCompletionSource taskCompletionSource];
        XCTestExpectation *partStarted = [self expectationWithDescription:name];
        TOSTestUploadV2Client *client = [TOSTestUploadV2Client new];
        if (abortFails.boolValue) {
            client.tos_abortTask = [TOSTask taskWithError:[NSError errorWithDomain:TOSServerErrorDomain code:500 userInfo:nil]];
            XCTAssertEqual(client.tos_abortTask.error.code, 500);
        }
        client.tos_uploadPartHandler = ^TOSTask *(TOSUploadPartFromStreamInput *partInput, NSInteger callIndex) {
            [partStarted fulfill];
            return partSource.task;
        };
        TOSUploadFileV2Operation *operation = [[TOSUploadFileV2Operation alloc] initWithClient:client request:input];
        [operation start];
        [self waitForExpectations:@[partStarted] timeout:1.0];

        [cancelHook cancel:YES];
        [partSource setError:[NSError errorWithDomain:TOSClientErrorDomain
                                                  code:TOSClientErrorCodeTaskCancelled
                                              userInfo:nil]];
        [self tos_waitForTask:operation.task];

        XCTAssertEqual(client.tos_abortCalls, 1);
        XCTAssertEqual([[NSFileManager defaultManager] fileExistsAtPath:checkpointPath], abortFails.boolValue,
                       @"abortFails=%@ callOrder=%@ error=%@", abortFails, client.tos_callOrder, operation.task.error);
        if (abortFails.boolValue) {
            XCTAssertEqual(operation.task.error.code, 500);
        } else {
            XCTAssertTrue([[self tos_messageForError:operation.task.error] containsString:@"cancelled"]);
        }
    }
}

- (void)testUploadV2CancellationDuringCreatePersistsReturnedUploadIDBeforeTerminalHandling {
    for (NSNumber *shouldAbort in @[@NO, @YES]) {
        NSString *name = shouldAbort.boolValue ? @"create-cancel-abort" : @"create-cancel-resume";
        NSString *filePath = [self tos_createFileNamed:[name stringByAppendingString:@".bin"] size:1];
        NSString *checkpointPath = [self.tos_root stringByAppendingPathComponent:[name stringByAppendingString:@".upload.v2"]];
        TOSCancelHook *cancelHook = [TOSCancelHook new];
        TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
        input.tosPartSize = TOSMinPartSize;
        input.tosEnableCheckpoint = YES;
        input.tosCheckpointFile = checkpointPath;
        input.tosCancelHook = cancelHook;
        TOSTaskCompletionSource *createSource = [TOSTaskCompletionSource taskCompletionSource];
        XCTestExpectation *createStarted = [self expectationWithDescription:name];
        TOSTestUploadV2Client *client = [TOSTestUploadV2Client new];
        client.tos_createHandler = ^TOSTask *(TOSCreateMultipartUploadInput *createInput) {
            [createStarted fulfill];
            return createSource.task;
        };
        TOSUploadFileV2Operation *operation = [[TOSUploadFileV2Operation alloc] initWithClient:client request:input];
        [operation start];
        [self waitForExpectations:@[createStarted] timeout:1.0];

        [cancelHook cancel:shouldAbort.boolValue];
        TOSCreateMultipartUploadOutput *createOutput = [TOSCreateMultipartUploadOutput new];
        createOutput.tosUploadID = @"create-race-upload-id";
        [createSource setResult:createOutput];
        [self tos_waitForTask:operation.task];

        XCTAssertNotNil(operation.task.error);
        if (shouldAbort.boolValue) {
            XCTAssertEqual(client.tos_abortCalls, 1);
            XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:checkpointPath]);
        } else {
            NSData *data = [NSData dataWithContentsOfFile:checkpointPath];
            TOSUploadCheckpointV2 *stored = [TOSUploadCheckpointV2 tos_checkpointWithData:data
                                                                            checkpointPath:checkpointPath
                                                                                       error:nil];
            XCTAssertEqualObjects(stored.tos_uploadID, @"create-race-upload-id");
            XCTAssertEqual(client.tos_abortCalls, 0);
        }
    }
}

- (void)testUploadV2ConfirmedCompleteSuccessWinsCancellationRace {
    NSString *filePath = [self tos_createFileNamed:@"complete-race.bin" size:1];
    NSString *checkpointPath = [self.tos_root stringByAppendingPathComponent:@"complete-race.upload.v2"];
    TOSCancelHook *cancelHook = [TOSCancelHook new];
    TOSUploadFileInputV2 *input = [self tos_inputWithFilePath:filePath];
    input.tosPartSize = TOSMinPartSize;
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = checkpointPath;
    input.tosCancelHook = cancelHook;
    TOSTaskCompletionSource *completeSource = [TOSTaskCompletionSource taskCompletionSource];
    XCTestExpectation *completeStarted = [self expectationWithDescription:@"complete started"];
    TOSTestUploadV2Client *client = [TOSTestUploadV2Client new];
    client.tos_completeHandler = ^TOSTask *(TOSCompleteMultipartUploadInput *completeInput) {
        [completeStarted fulfill];
        return completeSource.task;
    };
    TOSUploadFileV2Operation *operation = [[TOSUploadFileV2Operation alloc] initWithClient:client request:input];
    [operation start];
    [self waitForExpectations:@[completeStarted] timeout:1.0];

    [cancelHook cancel:YES];
    TOSCompleteMultipartUploadOutput *completeOutput = [TOSCompleteMultipartUploadOutput new];
    completeOutput.tosBucket = input.tosBucket;
    completeOutput.tosKey = input.tosKey;
    completeOutput.tosETag = @"complete-etag";
    completeOutput.tosLocation = @"location";
    [completeSource setResult:completeOutput];
    [self tos_waitForTask:operation.task];

    XCTAssertNil(operation.task.error);
    XCTAssertEqualObjects(((TOSUploadFileOutputV2 *)operation.task.result).tosETag, @"complete-etag");
    XCTAssertEqual(client.tos_abortCalls, 0);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:checkpointPath]);
}

@end
