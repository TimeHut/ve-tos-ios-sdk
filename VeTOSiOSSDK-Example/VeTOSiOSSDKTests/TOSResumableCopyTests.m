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
#import "../../VeTOSiOSSDK/VeTOSiOSSDK/Transfer/TOSInput+TransferInternal.h"
#import "../../VeTOSiOSSDK/VeTOSiOSSDK/Transfer/TOSResumableCopyOperation.h"
#import "../../VeTOSiOSSDK/VeTOSiOSSDK/Transfer/TOSTransferCheckpoint.h"
#import <VeTOSiOSSDK/VeTOSiOSSDK.h>

@interface TOSTestCopyClient : TOSClient
@property (nonatomic, assign) NSInteger tos_headCalls;
@property (nonatomic, assign) NSInteger tos_copyCalls;
@property (nonatomic, assign) NSInteger tos_createCalls;
@property (nonatomic, assign) NSInteger tos_uploadPartCalls;
@property (nonatomic, assign) NSInteger tos_partCopyCalls;
@property (nonatomic, assign) NSInteger tos_completeCalls;
@property (nonatomic, assign) NSInteger tos_abortCalls;
@property (nonatomic, strong) TOSTask *tos_headTask;
@property (nonatomic, strong) TOSHeadObjectOutput *tos_headOutput;
@property (nonatomic, strong) TOSTask *tos_copyTask;
@property (nonatomic, strong) TOSTask *tos_createTask;
@property (nonatomic, strong) TOSTask *tos_uploadPartTask;
@property (nonatomic, strong) TOSTask *tos_partCopyTask;
@property (nonatomic, strong) TOSTask *tos_completeTask;
@property (nonatomic, strong) TOSTask *tos_abortTask;
@property (nonatomic, copy) TOSTask *(^tos_headHandler)(TOSHeadObjectInput *input, NSInteger index);
@property (nonatomic, copy) TOSTask *(^tos_copyHandler)(TOSCopyObjectInput *input, NSInteger index);
@property (nonatomic, copy) TOSTask *(^tos_createHandler)(TOSCreateMultipartUploadInput *input, NSInteger index);
@property (nonatomic, copy) TOSTask *(^tos_uploadPartHandler)(TOSUploadPartInput *input, NSInteger index);
@property (nonatomic, copy) TOSTask *(^tos_partCopyHandler)(TOSUploadPartCopyInput *input, NSInteger index);
@property (nonatomic, copy) TOSTask *(^tos_completeHandler)(TOSCompleteMultipartUploadInput *input, NSInteger index);
@property (nonatomic, copy) TOSTask *(^tos_abortHandler)(TOSAbortMultipartUploadInput *input, NSInteger index);
@property (nonatomic, strong) NSMutableArray<TOSHeadObjectInput *> *tos_headInputs;
@property (nonatomic, strong) NSMutableArray<TOSCopyObjectInput *> *tos_copyInputs;
@property (nonatomic, strong) NSMutableArray<TOSCreateMultipartUploadInput *> *tos_createInputs;
@property (nonatomic, strong) NSMutableArray<TOSUploadPartInput *> *tos_uploadPartInputs;
@property (nonatomic, strong) NSMutableArray<TOSUploadPartCopyInput *> *tos_partCopyInputs;
@property (nonatomic, strong) NSMutableArray<TOSCompleteMultipartUploadInput *> *tos_completeInputs;
@property (nonatomic, strong) NSMutableArray<TOSAbortMultipartUploadInput *> *tos_abortInputs;
@property (nonatomic, strong) NSMutableArray<NSString *> *tos_callOrder;
@end

@implementation TOSTestCopyClient

- (instancetype)init {
    self = [super init];
    if (self) {
        _tos_headInputs = [NSMutableArray array];
        _tos_copyInputs = [NSMutableArray array];
        _tos_createInputs = [NSMutableArray array];
        _tos_uploadPartInputs = [NSMutableArray array];
        _tos_partCopyInputs = [NSMutableArray array];
        _tos_completeInputs = [NSMutableArray array];
        _tos_abortInputs = [NSMutableArray array];
        _tos_callOrder = [NSMutableArray array];
    }
    return self;
}

- (TOSTask *)headObject:(TOSHeadObjectInput *)request {
    self.tos_headCalls += 1;
    [self.tos_headInputs addObject:request];
    [self.tos_callOrder addObject:@"head"];
    if (self.tos_headHandler) {
        TOSTask *task = self.tos_headHandler(request, self.tos_headCalls - 1);
        if (task) {
            return task;
        }
    }
    if (self.tos_headTask) {
        return self.tos_headTask;
    }
    return [TOSTask taskWithResult:self.tos_headOutput ?: [TOSHeadObjectOutput new]];
}

- (TOSTask *)copyObject:(TOSCopyObjectInput *)request {
    self.tos_copyCalls += 1;
    [self.tos_copyInputs addObject:request];
    [self.tos_callOrder addObject:@"copy"];
    if (self.tos_copyHandler) {
        TOSTask *task = self.tos_copyHandler(request, self.tos_copyCalls - 1);
        if (task) {
            return task;
        }
    }
    if (self.tos_copyTask) {
        return self.tos_copyTask;
    }
    TOSCopyObjectOutput *output = [TOSCopyObjectOutput new];
    output.tosETag = @"copy-etag";
    output.tosVersionID = @"destination-version";
    output.tosRequestID = @"copy-request";
    output.tosStatusCode = 200;
    return [TOSTask taskWithResult:output];
}

- (TOSTask *)createMultipartUpload:(TOSCreateMultipartUploadInput *)request {
    self.tos_createCalls += 1;
    [self.tos_createInputs addObject:request];
    [self.tos_callOrder addObject:@"create"];
    if (self.tos_createHandler) {
        TOSTask *task = self.tos_createHandler(request, self.tos_createCalls - 1);
        if (task) {
            return task;
        }
    }
    if (self.tos_createTask) {
        return self.tos_createTask;
    }
    TOSCreateMultipartUploadOutput *output = [TOSCreateMultipartUploadOutput new];
    output.tosUploadID = @"upload-id";
    output.tosEncodingType = request.tosEncodingType;
    return [TOSTask taskWithResult:output];
}

- (TOSTask *)uploadPart:(TOSUploadPartInput *)request {
    self.tos_uploadPartCalls += 1;
    [self.tos_uploadPartInputs addObject:request];
    [self.tos_callOrder addObject:[NSString stringWithFormat:@"upload-part-%d", request.tosPartNumber]];
    if (self.tos_uploadPartHandler) {
        TOSTask *task = self.tos_uploadPartHandler(request, self.tos_uploadPartCalls - 1);
        if (task) {
            return task;
        }
    }
    if (self.tos_uploadPartTask) {
        return self.tos_uploadPartTask;
    }
    TOSUploadPartOutput *output = [TOSUploadPartOutput new];
    output.tosPartNumber = request.tosPartNumber;
    output.tosETag = @"empty-etag";
    return [TOSTask taskWithResult:output];
}

- (TOSTask *)uploadPartCopy:(TOSUploadPartCopyInput *)request {
    self.tos_partCopyCalls += 1;
    [self.tos_partCopyInputs addObject:request];
    [self.tos_callOrder addObject:[NSString stringWithFormat:@"copy-part-%d", request.tosPartNumber]];
    if (self.tos_partCopyHandler) {
        TOSTask *task = self.tos_partCopyHandler(request, self.tos_partCopyCalls - 1);
        if (task) {
            return task;
        }
    }
    if (self.tos_partCopyTask) {
        return self.tos_partCopyTask;
    }
    TOSUploadPartCopyOutput *output = [TOSUploadPartCopyOutput new];
    output.tosPartNumber = request.tosPartNumber;
    output.tosETag = [NSString stringWithFormat:@"part-%d-etag", request.tosPartNumber];
    return [TOSTask taskWithResult:output];
}

- (TOSTask *)completeMultipartUpload:(TOSCompleteMultipartUploadInput *)request {
    self.tos_completeCalls += 1;
    [self.tos_completeInputs addObject:request];
    [self.tos_callOrder addObject:@"complete"];
    if (self.tos_completeHandler) {
        TOSTask *task = self.tos_completeHandler(request, self.tos_completeCalls - 1);
        if (task) {
            return task;
        }
    }
    if (self.tos_completeTask) {
        return self.tos_completeTask;
    }
    TOSCompleteMultipartUploadOutput *output = [TOSCompleteMultipartUploadOutput new];
    output.tosBucket = request.tosBucket;
    output.tosKey = request.tosKey;
    output.tosETag = @"complete-etag";
    output.tosLocation = @"location";
    output.tosVersionID = @"destination-version";
    output.tosHashCrc64ecma = self.tos_headOutput.tosHashCrc64ecma;
    output.tosRequestID = @"complete-request";
    output.tosStatusCode = 200;
    return [TOSTask taskWithResult:output];
}

- (TOSTask *)abortMultipartUpload:(TOSAbortMultipartUploadInput *)request {
    self.tos_abortCalls += 1;
    [self.tos_abortInputs addObject:request];
    [self.tos_callOrder addObject:@"abort"];
    if (self.tos_abortHandler) {
        TOSTask *task = self.tos_abortHandler(request, self.tos_abortCalls - 1);
        if (task) {
            return task;
        }
    }
    return self.tos_abortTask ?: [TOSTask taskWithResult:[TOSAbortMultipartUploadOutput new]];
}

@end

@interface TOSTestLifetimeCopyOperation : TOSResumableCopyOperation
@property (nonatomic, copy) dispatch_block_t tos_deallocBlock;
@end

@implementation TOSTestLifetimeCopyOperation

- (void)dealloc {
    if (_tos_deallocBlock) {
        _tos_deallocBlock();
    }
}

@end

@interface TOSResumableCopyTests : XCTestCase
@property (nonatomic, copy) NSString *tos_root;
@end

@implementation TOSResumableCopyTests

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

- (void)testResumableCopyObjectPublicSelectorIsAvailable {
    XCTAssertTrue([TOSClient instancesRespondToSelector:@selector(resumableCopyObject:)]);
}

- (TOSResumableCopyObjectInput *)tos_input {
    TOSResumableCopyObjectInput *input = [TOSResumableCopyObjectInput new];
    input.tosBucket = @"destination-bucket";
    input.tosKey = @"destination-key";
    input.tosSrcBucket = @"source-bucket";
    input.tosSrcKey = @"source-key";
    input.tosPartSize = TOSMinPartSize;
    return input;
}

- (TOSHeadObjectOutput *)tos_headWithSize:(int64_t)size {
    TOSHeadObjectOutput *output = [TOSHeadObjectOutput new];
    output.tosContentLength = size;
    output.tosETag = @"source-etag";
    output.tosLastModified = [NSDate dateWithTimeIntervalSince1970:1234];
    output.tosHashCrc64ecma = 987654321;
    output.tosStatusCode = 200;
    output.tosRequestID = @"head-request";
    return output;
}

- (void)tos_waitForTask:(TOSTask *)task {
    XCTestExpectation *completion = [self expectationWithDescription:@"copy completion"];
    [task continueWithBlock:^id(TOSTask *finishedTask) {
        [completion fulfill];
        return nil;
    }];
    [self waitForExpectations:@[completion] timeout:3.0];
}

- (void)testResumableCopyRejectsCheckpointAlreadyInUseBeforeRemoteMutation {
    NSString *checkpointPath = [self.tos_root stringByAppendingPathComponent:@"lease-conflict.copy"];
    NSError *leaseError = nil;
    TOSTransferCheckpointLease *lease =
        [TOSTransferCheckpointLease acquireCheckpointPath:checkpointPath error:&leaseError];
    XCTAssertNotNil(lease);
    XCTAssertNil(leaseError);

    TOSResumableCopyObjectInput *input = [self tos_input];
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = checkpointPath;
    TOSTestCopyClient *client = [TOSTestCopyClient new];
    client.tos_headOutput = [self tos_headWithSize:1];

    TOSTask *task = [client resumableCopyObject:input];
    [self tos_waitForTask:task];

    XCTAssertNotNil(task.error);
    XCTAssertEqual(client.tos_headCalls, 0);
    XCTAssertEqual(client.tos_createCalls, 0);
    [lease invalidate];
}

- (NSString *)tos_messageForError:(NSError *)error {
    return error.userInfo[TOSErrorMessageTOKEN] ?: error.localizedDescription ?: @"";
}

- (TOSCopyCheckpoint *)tos_checkpointForInput:(TOSResumableCopyObjectInput *)input
                                         head:(TOSHeadObjectOutput *)head
                                     uploadID:(NSString *)uploadID {
    NSError *error = nil;
    NSArray<TOSTransferPart *> *parts = TOSCopyParts(head.tosContentLength,
                                                     input.tosPartSize,
                                                     &error);
    XCTAssertNotNil(parts);
    XCTAssertNil(error);
    TOSCopyCheckpoint *checkpoint = [TOSCopyCheckpoint new];
    checkpoint.tos_schemaVersion = 1;
    checkpoint.tos_operation = @"copy";
    checkpoint.tos_bucket = input.tosBucket;
    checkpoint.tos_key = input.tosKey;
    checkpoint.tos_partSize = input.tosPartSize;
    checkpoint.tos_checkpointPath = input.tosCheckpointFile;
    checkpoint.tos_parts = parts;
    checkpoint.tos_encodingType = input.tosEncodingType ?: @"";
    checkpoint.tos_srcBucket = input.tosSrcBucket;
    checkpoint.tos_srcKey = input.tosSrcKey;
    checkpoint.tos_srcVersionID = input.tosSrcVersionID ?: @"";
    checkpoint.tos_uploadID = uploadID ?: @"";
    checkpoint.tos_copySourceIfMatch = input.tosCopySourceIfMatch ?: @"";
    checkpoint.tos_copySourceIfModifiedSince = input.tosCopySourceIfModifiedSince
        ? (int64_t)(input.tosCopySourceIfModifiedSince.timeIntervalSince1970 * NSEC_PER_SEC) : 0;
    checkpoint.tos_copySourceIfNoneMatch = input.tosCopySourceIfNoneMatch ?: @"";
    checkpoint.tos_copySourceIfUnmodifiedSince = input.tosCopySourceIfUnmodifiedSince
        ? (int64_t)(input.tosCopySourceIfUnmodifiedSince.timeIntervalSince1970 * NSEC_PER_SEC) : 0;
    checkpoint.tos_sourceETag = head.tosETag ?: @"";
    checkpoint.tos_sourceLastModified = head.tosLastModified
        ? (int64_t)(head.tosLastModified.timeIntervalSince1970 * NSEC_PER_SEC) : 0;
    checkpoint.tos_sourceSize = head.tosContentLength;
    checkpoint.tos_sourceCRC64 = head.tosHashCrc64ecma;
    return checkpoint;
}

- (void)tos_writeCheckpoint:(TOSCopyCheckpoint *)checkpoint {
    NSError *error = nil;
    XCTAssertTrue([[[TOSTransferCheckpointStore alloc] init] writeCheckpoint:checkpoint error:&error]);
    XCTAssertNil(error);
}

- (void)testResumableCopyOperationSnapshotsAllInputFields {
    TOSResumableCopyObjectInput *input = [self tos_input];
    input.tosEncodingType = @"url";
    input.tosContentType = @"text/plain";
    input.tosMeta = @{@"key": @"value"};
    input.tosCopySourceIfMatch = @"before";
    input.tosCopySourceIfModifiedSince = [NSDate dateWithTimeIntervalSince1970:100];
    input.tosCheckpointFile = @"before.checkpoint";
    TOSResumableCopyOperation *operation = [[TOSResumableCopyOperation alloc]
                                             initWithClient:[TOSTestCopyClient new]
                                             request:input];

    input.tosBucket = @"changed";
    input.tosSrcKey = @"changed";
    input.tosContentType = @"changed";
    input.tosCopySourceIfMatch = @"changed";
    input.tosMeta = @{@"changed": @"changed"};

    XCTAssertEqualObjects(operation.request.tosBucket, @"destination-bucket");
    XCTAssertEqualObjects(operation.request.tosSrcKey, @"source-key");
    XCTAssertEqualObjects(operation.request.tosContentType, @"text/plain");
    XCTAssertEqualObjects(operation.request.tosCopySourceIfMatch, @"before");
    XCTAssertEqualObjects(operation.request.tosMeta, (@{@"key": @"value"}));
    XCTAssertEqualObjects(operation.request.tosCheckpointFile, @"before.checkpoint");
}

- (void)testResumableCopyValidatesNamesPartBoundsAndRejectsSSEBeforeHead {
    NSArray<TOSResumableCopyObjectInput *> *invalidInputs = @[
        ({ TOSResumableCopyObjectInput *v = [self tos_input]; v.tosSrcBucket = @"INVALID"; v; }),
        ({ TOSResumableCopyObjectInput *v = [self tos_input]; v.tosSrcKey = @""; v; }),
        ({ TOSResumableCopyObjectInput *v = [self tos_input]; v.tosBucket = @"INVALID"; v; }),
        ({ TOSResumableCopyObjectInput *v = [self tos_input]; v.tosKey = @""; v; }),
        ({ TOSResumableCopyObjectInput *v = [self tos_input]; v.tosPartSize = TOSMinPartSize - 1; v; }),
        ({ TOSResumableCopyObjectInput *v = [self tos_input]; v.tosMaxRetryCount = -1; v; }),
        ({ TOSResumableCopyObjectInput *v = [self tos_input]; v.tosTrafficLimit = -1; v; }),
        ({ TOSResumableCopyObjectInput *v = [self tos_input]; v.tosSSECAlgorithm = @"AES256"; v; }),
        ({ TOSResumableCopyObjectInput *v = [self tos_input]; v.tosServerSideEncryption = @"AES256"; v; })
    ];

    for (TOSResumableCopyObjectInput *input in invalidInputs) {
        TOSTestCopyClient *client = [TOSTestCopyClient new];
        TOSTask *task = [client resumableCopyObject:input];
        [self tos_waitForTask:task];
        XCTAssertNotNil(task.error);
        XCTAssertEqual(client.tos_headCalls, 0);
    }
}

- (void)testResumableCopyClampsTaskCountAndRejectsMoreThanTenThousandParts {
    TOSResumableCopyObjectInput *clampedInput = [self tos_input];
    clampedInput.tosTaskNum = 1001;
    TOSTestCopyClient *client = [TOSTestCopyClient new];
    client.tos_headOutput = [self tos_headWithSize:0];
    TOSResumableCopyOperation *operation = [[TOSResumableCopyOperation alloc] initWithClient:client request:clampedInput];
    [operation start];
    [self tos_waitForTask:operation.task];
    XCTAssertEqual(operation.request.tosTaskNum, 1000);
    XCTAssertEqual(clampedInput.tosTaskNum, 1001);

    TOSResumableCopyObjectInput *tooMany = [self tos_input];
    TOSTestCopyClient *tooManyClient = [TOSTestCopyClient new];
    tooManyClient.tos_headOutput = [self tos_headWithSize:TOSMinPartSize * 10000LL + 1];
    TOSTask *tooManyTask = [tooManyClient resumableCopyObject:tooMany];
    [self tos_waitForTask:tooManyTask];
    XCTAssertNotNil(tooManyTask.error);
    XCTAssertEqual(tooManyClient.tos_createCalls, 0);
}

- (void)testResumableCopyStartsSixPartsWhenTaskNumIsSix {
    TOSResumableCopyObjectInput *input = [self tos_input];
    input.tosTaskNum = 6;
    input.tosMaxRetryCount = 0;
    TOSTestCopyClient *client = [TOSTestCopyClient new];
    client.tos_headOutput = [self tos_headWithSize:TOSMinPartSize * 5 + 1];
    NSMutableArray<TOSTaskCompletionSource *> *sources = [NSMutableArray array];
    XCTestExpectation *initialWave = [self expectationWithDescription:@"five copy parts started"];
    initialWave.expectedFulfillmentCount = 5;
    XCTestExpectation *sixthStarted = [self expectationWithDescription:@"sixth copy part started"];
    client.tos_partCopyHandler = ^TOSTask *(TOSUploadPartCopyInput *partInput, NSInteger index) {
        TOSTaskCompletionSource *source = [TOSTaskCompletionSource taskCompletionSource];
        [sources addObject:source];
        if (index < 5) {
            [initialWave fulfill];
        } else {
            [sixthStarted fulfill];
        }
        return source.task;
    };
    TOSResumableCopyOperation *operation = [[TOSResumableCopyOperation alloc] initWithClient:client
                                                                                      request:input];

    [operation start];
    [self waitForExpectations:@[initialWave] timeout:2.0];
    XCTAssertEqual(client.tos_partCopyCalls, 5);

    TOSUploadPartCopyInput *firstInput = client.tos_partCopyInputs.firstObject;
    TOSUploadPartCopyOutput *firstOutput = [TOSUploadPartCopyOutput new];
    firstOutput.tosPartNumber = firstInput.tosPartNumber;
    firstOutput.tosETag = @"etag-first";
    [sources.firstObject setResult:firstOutput];
    [self waitForExpectations:@[sixthStarted] timeout:2.0];

    XCTAssertEqual(client.tos_partCopyCalls, 6);
    XCTAssertEqual(operation.request.tosTaskNum, 6);
    for (TOSTaskCompletionSource *source in sources) {
        [source trySetError:[NSError errorWithDomain:TOSServerErrorDomain code:400 userInfo:nil]];
    }
    [self tos_waitForTask:operation.task];
    XCTAssertNotNil(operation.task.error);
}

- (void)testResumableCopyPropagatesSourceHeadFailureWithoutMutation {
    TOSTestCopyClient *client = [TOSTestCopyClient new];
    client.tos_headTask = [TOSTask taskWithError:[NSError errorWithDomain:TOSServerErrorDomain code:404 userInfo:nil]];

    TOSTask *task = [client resumableCopyObject:[self tos_input]];
    [self tos_waitForTask:task];

    XCTAssertEqual(task.error.code, 404);
    XCTAssertEqual(client.tos_createCalls, 0);
    XCTAssertEqual(client.tos_copyCalls, 0);
}

- (void)testResumableCopyUsesDirectCopyForSymlinkAndPreservesMetadata {
    TOSResumableCopyObjectInput *input = [self tos_input];
    input.tosSrcVersionID = @"source-version";
    input.tosCacheControl = @"no-cache";
    input.tosContentDisposition = @"attachment";
    input.tosContentEncoding = @"gzip";
    input.tosContentLanguage = @"zh-CN";
    input.tosContentType = @"text/plain";
    input.tosACL = TOSACLPrivate;
    input.tosGrantRead = @"grant";
    input.tosMeta = @{@"meta": @"value"};
    input.tosWebsiteRedirectLocation = @"/redirect";
    input.tosStorageClass = TOSStorageClassStandard;
    input.tosTrafficLimit = 4096;
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    TOSTestCopyClient *client = [TOSTestCopyClient new];
    client.tos_headOutput = [self tos_headWithSize:8];
    client.tos_headOutput.tosObjectType = @"Symlink";

    TOSTask<TOSResumableCopyObjectOutput *> *task = [client resumableCopyObject:input];
    [self tos_waitForTask:task];

    XCTAssertTrue(task.completed);
    XCTAssertNil(task.error);
    XCTAssertNotNil(task.result);
    XCTAssertEqual(client.tos_headCalls, 1);
    XCTAssertEqual(client.tos_copyCalls, 1);
    XCTAssertEqual(client.tos_createCalls, 0);
    XCTAssertEqual(client.tos_partCopyCalls, 0);
    XCTAssertEqual(client.tos_completeCalls, 0);
    TOSCopyObjectInput *copyInput = client.tos_copyInputs.firstObject;
    XCTAssertEqualObjects(copyInput.tosSrcVersionID, @"source-version");
    XCTAssertEqualObjects(copyInput.tosCopySourceIfMatch, @"source-etag");
    XCTAssertEqualObjects(copyInput.tosCacheControl, @"no-cache");
    XCTAssertEqualObjects(copyInput.tosContentDisposition, @"attachment");
    XCTAssertEqualObjects(copyInput.tosContentEncoding, @"gzip");
    XCTAssertEqualObjects(copyInput.tosContentLanguage, @"zh-CN");
    XCTAssertEqualObjects(copyInput.tosContentType, @"text/plain");
    XCTAssertEqualObjects(copyInput.tosACL, TOSACLPrivate);
    XCTAssertEqualObjects(copyInput.tosGrantRead, @"grant");
    XCTAssertEqualObjects(copyInput.tosMeta, (@{@"meta": @"value"}));
    XCTAssertEqualObjects(copyInput.tosWebsiteRedirectLocation, @"/redirect");
    XCTAssertEqualObjects(copyInput.tosStorageClass, TOSStorageClassStandard);
    XCTAssertEqualObjects(copyInput.tos_transferHeaders[@"x-tos-copy-source-if-match"],
                          @"source-etag");
    XCTAssertEqualObjects(copyInput.tos_transferHeaders[@"x-tos-traffic-limit"], @"4096");
    XCTAssertEqualObjects(task.result.tosBucket, @"destination-bucket");
    XCTAssertEqualObjects(task.result.tosKey, @"destination-key");
    XCTAssertEqual(task.result.tosHashCrc64ecma, client.tos_headOutput.tosHashCrc64ecma);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:input.tosCheckpointFile]);
}

- (void)testResumableCopyCleansMatchingMultipartCheckpointBeforeSymlinkCopy {
    TOSResumableCopyObjectInput *input = [self tos_input];
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = [self.tos_root stringByAppendingPathComponent:@"symlink.copy"];
    TOSHeadObjectOutput *head = [self tos_headWithSize:8];
    head.tosObjectType = @"Symlink";
    TOSCopyCheckpoint *checkpoint = [self tos_checkpointForInput:input
                                                            head:head
                                                        uploadID:@"stale-upload-id"];
    [self tos_writeCheckpoint:checkpoint];
    TOSTestCopyClient *client = [TOSTestCopyClient new];
    client.tos_headOutput = head;

    TOSTask *task = [client resumableCopyObject:input];
    [self tos_waitForTask:task];

    XCTAssertNil(task.error);
    XCTAssertEqual(client.tos_abortCalls, 1);
    XCTAssertEqual(client.tos_copyCalls, 1);
    XCTAssertEqualObjects(client.tos_abortInputs.firstObject.tosBucket, input.tosBucket);
    XCTAssertEqualObjects(client.tos_abortInputs.firstObject.tosKey, input.tosKey);
    XCTAssertEqualObjects(client.tos_abortInputs.firstObject.tosUploadID, @"stale-upload-id");
    XCTAssertEqualObjects(client.tos_callOrder, (@[@"head", @"abort", @"copy"]));
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:input.tosCheckpointFile]);
}

- (void)testResumableCopyCleansStaleCheckpointOwnerBeforeSymlinkCopy {
    TOSResumableCopyObjectInput *input = [self tos_input];
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = [self.tos_root stringByAppendingPathComponent:
                               @"stale-symlink.copy"];
    TOSHeadObjectOutput *oldHead = [self tos_headWithSize:8];
    oldHead.tosETag = @"old-source-etag";
    TOSCopyCheckpoint *checkpoint = [self tos_checkpointForInput:input
                                                            head:oldHead
                                                        uploadID:@"stale-symlink-upload-id"];
    [self tos_writeCheckpoint:checkpoint];

    TOSTestCopyClient *client = [TOSTestCopyClient new];
    client.tos_headOutput = [self tos_headWithSize:8];
    client.tos_headOutput.tosETag = @"new-source-etag";
    client.tos_headOutput.tosObjectType = @"Symlink";

    TOSTask *task = [client resumableCopyObject:input];
    [self tos_waitForTask:task];

    XCTAssertNil(task.error);
    XCTAssertEqual(client.tos_abortCalls, 1);
    XCTAssertEqual(client.tos_copyCalls, 1);
    XCTAssertEqualObjects(client.tos_abortInputs.firstObject.tosUploadID,
                          @"stale-symlink-upload-id");
    XCTAssertFalse([[NSFileManager defaultManager]
                    fileExistsAtPath:input.tosCheckpointFile]);
}

- (void)testResumableCopyCancelWithAbortCleansStaleCheckpointOwner {
    for (NSNumber *abortFails in @[@NO, @YES]) {
        NSString *suffix = abortFails.boolValue ? @"failure" : @"success";
        TOSResumableCopyObjectInput *input = [self tos_input];
        input.tosEnableCheckpoint = YES;
        input.tosCheckpointFile = [self.tos_root stringByAppendingPathComponent:
                                   [NSString stringWithFormat:@"stale-cancel-%@.copy", suffix]];
        input.tosCancelHook = [TOSCancelHook new];
        TOSHeadObjectOutput *oldHead = [self tos_headWithSize:8];
        oldHead.tosETag = @"old-source-etag";
        TOSCopyCheckpoint *checkpoint = [self tos_checkpointForInput:input
                                                                head:oldHead
                                                            uploadID:@"stale-cancel-upload-id"];
        [self tos_writeCheckpoint:checkpoint];
        NSData *checkpointData = [NSData dataWithContentsOfFile:input.tosCheckpointFile];

        TOSTaskCompletionSource *headSource =
            [TOSTaskCompletionSource taskCompletionSource];
        XCTestExpectation *headStarted =
            [self expectationWithDescription:
             [NSString stringWithFormat:@"stale head %@", suffix]];
        TOSTestCopyClient *client = [TOSTestCopyClient new];
        client.tos_headHandler = ^TOSTask *(TOSHeadObjectInput *headInput,
                                            NSInteger index) {
            [headStarted fulfill];
            return headSource.task;
        };
        if (abortFails.boolValue) {
            client.tos_abortTask =
                [TOSTask taskWithError:[NSError errorWithDomain:TOSServerErrorDomain
                                                            code:500
                                                        userInfo:nil]];
        }

        TOSTask *task = [client resumableCopyObject:input];
        [self waitForExpectations:@[headStarted] timeout:1.0];
        [input.tosCancelHook cancel:YES];
        TOSHeadObjectOutput *newHead = [self tos_headWithSize:8];
        newHead.tosETag = @"new-source-etag";
        [headSource setResult:newHead];
        [self tos_waitForTask:task];

        XCTAssertEqual(client.tos_abortCalls, 1);
        XCTAssertEqualObjects(client.tos_abortInputs.firstObject.tosUploadID,
                              @"stale-cancel-upload-id");
        if (abortFails.boolValue) {
            XCTAssertEqual(task.error.code, 500);
            XCTAssertEqualObjects([NSData dataWithContentsOfFile:input.tosCheckpointFile],
                                  checkpointData);
        } else {
            XCTAssertTrue([[self tos_messageForError:task.error]
                           containsString:@"cancelled"]);
            XCTAssertFalse([[NSFileManager defaultManager]
                            fileExistsAtPath:input.tosCheckpointFile]);
        }
    }
}

- (void)testResumableCopyZeroSizeUsesOneEmptyUploadPart {
    TOSTestCopyClient *client = [TOSTestCopyClient new];
    client.tos_headOutput = [self tos_headWithSize:0];

    TOSTask *task = [client resumableCopyObject:[self tos_input]];
    [self tos_waitForTask:task];

    XCTAssertTrue(task.completed);
    XCTAssertNil(task.error);
    XCTAssertNotNil(task.result);
    XCTAssertEqual(client.tos_headCalls, 1);
    XCTAssertEqual(client.tos_createCalls, 1);
    XCTAssertEqual(client.tos_uploadPartCalls, 1);
    XCTAssertEqual(client.tos_partCopyCalls, 0);
    XCTAssertEqual(client.tos_completeCalls, 1);
    TOSUploadPartInput *partInput = client.tos_uploadPartInputs.firstObject;
    XCTAssertEqual(partInput.tosPartNumber, 1);
    XCTAssertEqual(partInput.tosContentLength, 0);
    XCTAssertEqual(partInput.tosContent.length, 0);
    XCTAssertNotNil(partInput.tos_responseObserver);
    TOSUploadedPart *completedPart = client.tos_completeInputs.firstObject.tosParts.firstObject;
    XCTAssertEqual(completedPart.tosPartNumber, 1);
    XCTAssertEqualObjects(completedPart.tosETag, @"empty-etag");
}

- (void)testResumableCopyResumesOnlyPendingPartsFromCompatibleCheckpoint {
    TOSResumableCopyObjectInput *input = [self tos_input];
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = [self.tos_root stringByAppendingPathComponent:@"resume.copy"];
    TOSHeadObjectOutput *head = [self tos_headWithSize:TOSMinPartSize + 3];
    TOSCopyCheckpoint *checkpoint = [self tos_checkpointForInput:input
                                                            head:head
                                                        uploadID:@"existing-upload-id"];
    checkpoint.tos_parts.firstObject.tos_completed = YES;
    checkpoint.tos_parts.firstObject.tos_eTag = @"existing-etag";
    [self tos_writeCheckpoint:checkpoint];
    TOSTestCopyClient *client = [TOSTestCopyClient new];
    client.tos_headOutput = head;

    TOSTask<TOSResumableCopyObjectOutput *> *task = [client resumableCopyObject:input];
    [self tos_waitForTask:task];

    XCTAssertNil(task.error);
    XCTAssertEqual(client.tos_createCalls, 0);
    XCTAssertEqual(client.tos_partCopyCalls, 1);
    TOSUploadPartCopyInput *partInput = client.tos_partCopyInputs.firstObject;
    XCTAssertEqual(partInput.tosPartNumber, 2);
    XCTAssertEqual(partInput.tosCopySourceRangeStart, TOSMinPartSize);
    XCTAssertEqual(partInput.tosCopySourceRangeEnd, TOSMinPartSize + 2);
    XCTAssertEqualObjects(partInput.tosCopySourceIfMatch, @"source-etag");
    XCTAssertEqual(client.tos_completeCalls, 1);
    NSArray<TOSUploadedPart *> *parts = client.tos_completeInputs.firstObject.tosParts;
    XCTAssertEqual(parts.count, 2);
    XCTAssertEqual(parts[0].tosPartNumber, 1);
    XCTAssertEqualObjects(parts[0].tosETag, @"existing-etag");
    XCTAssertEqual(parts[1].tosPartNumber, 2);
    XCTAssertEqualObjects(task.result.tosUploadID, @"existing-upload-id");
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:input.tosCheckpointFile]);
}

- (void)testResumableCopyPreservesSourceConditionsRangesAndTrafficLimit {
    TOSResumableCopyObjectInput *input = [self tos_input];
    input.tosSrcVersionID = @"source-version";
    input.tosCopySourceIfMatch = @"user-etag";
    input.tosCopySourceIfModifiedSince = [NSDate dateWithTimeIntervalSince1970:100];
    input.tosCopySourceIfNoneMatch = @"other-etag";
    input.tosCopySourceIfUnmodifiedSince = [NSDate dateWithTimeIntervalSince1970:200];
    input.tosTrafficLimit = 8192;
    TOSTestCopyClient *client = [TOSTestCopyClient new];
    client.tos_headOutput = [self tos_headWithSize:TOSMinPartSize + 1];

    TOSTask *task = [client resumableCopyObject:input];
    [self tos_waitForTask:task];

    XCTAssertNil(task.error);
    TOSHeadObjectInput *headInput = client.tos_headInputs.firstObject;
    XCTAssertEqualObjects(headInput.tosVersionID, @"source-version");
    XCTAssertEqualObjects(headInput.tosIfMatch, @"user-etag");
    XCTAssertEqualObjects(headInput.tosIfModifiedSince, input.tosCopySourceIfModifiedSince);
    XCTAssertEqualObjects(headInput.tosIfNoneMatch, @"other-etag");
    XCTAssertEqualObjects(headInput.tosIfUnmodifiedSince, input.tosCopySourceIfUnmodifiedSince);
    XCTAssertEqualObjects(headInput.tos_transferHeaders[@"If-Match"], @"user-etag");
    XCTAssertEqualObjects(headInput.tos_transferHeaders[@"If-None-Match"], @"other-etag");
    XCTAssertNotNil(headInput.tos_responseObserver);
    XCTAssertEqual(client.tos_partCopyInputs.count, 2);
    for (TOSUploadPartCopyInput *partInput in client.tos_partCopyInputs) {
        XCTAssertEqualObjects(partInput.tosSrcVersionID, @"source-version");
        XCTAssertEqualObjects(partInput.tosCopySourceIfMatch, @"user-etag");
        XCTAssertEqualObjects(partInput.tosCopySourceIfModifiedSince, input.tosCopySourceIfModifiedSince);
        XCTAssertEqualObjects(partInput.tosCopySourceIfNoneMatch, @"other-etag");
        XCTAssertEqualObjects(partInput.tosCopySourceIfUnmodifiedSince, input.tosCopySourceIfUnmodifiedSince);
        XCTAssertEqualObjects(partInput.tos_transferHeaders[@"x-tos-copy-source-if-match"],
                              @"user-etag");
        XCTAssertEqualObjects(partInput.tos_transferHeaders[@"x-tos-copy-source-if-none-match"],
                              @"other-etag");
        XCTAssertEqualObjects(partInput.tos_transferHeaders[@"x-tos-traffic-limit"], @"8192");
        XCTAssertNotNil(partInput.tos_transferCancellation);
        XCTAssertNotNil(partInput.tos_responseObserver);
    }
    XCTAssertEqual(client.tos_partCopyInputs[0].tosCopySourceRangeStart, 0);
    XCTAssertEqual(client.tos_partCopyInputs[0].tosCopySourceRangeEnd, TOSMinPartSize - 1);
    XCTAssertEqual(client.tos_partCopyInputs[1].tosCopySourceRangeStart, TOSMinPartSize);
    XCTAssertEqual(client.tos_partCopyInputs[1].tosCopySourceRangeEnd, TOSMinPartSize);
}

- (void)testResumableCopyNeverOverwritesMalformedCheckpoint {
    TOSResumableCopyObjectInput *input = [self tos_input];
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = [self.tos_root stringByAppendingPathComponent:@"legacy.copy"];
    NSData *legacyData = [@"legacy-binary-checkpoint" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertTrue([legacyData writeToFile:input.tosCheckpointFile atomically:YES]);
    TOSTestCopyClient *client = [TOSTestCopyClient new];
    client.tos_headOutput = [self tos_headWithSize:1];

    TOSTask *task = [client resumableCopyObject:input];
    [self tos_waitForTask:task];

    XCTAssertTrue([[self tos_messageForError:task.error] containsString:@"checkpoint"]);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:input.tosCheckpointFile], legacyData);
    XCTAssertEqual(client.tos_abortCalls, 0);
    XCTAssertEqual(client.tos_createCalls, 0);
}

- (void)testResumableCopyAbortsSameTargetStaleCheckpointBeforeReplacement {
    TOSResumableCopyObjectInput *input = [self tos_input];
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = [self.tos_root stringByAppendingPathComponent:@"stale.copy"];
    TOSHeadObjectOutput *head = [self tos_headWithSize:1];
    TOSCopyCheckpoint *checkpoint = [self tos_checkpointForInput:input
                                                            head:head
                                                        uploadID:@"stale-upload-id"];
    checkpoint.tos_sourceETag = @"stale-source-etag";
    [self tos_writeCheckpoint:checkpoint];
    TOSTaskCompletionSource *abortSource = [TOSTaskCompletionSource taskCompletionSource];
    XCTestExpectation *abortStarted = [self expectationWithDescription:@"stale abort started"];
    TOSTestCopyClient *client = [TOSTestCopyClient new];
    client.tos_headOutput = head;
    client.tos_abortHandler = ^TOSTask *(TOSAbortMultipartUploadInput *abortInput, NSInteger index) {
        [abortStarted fulfill];
        return abortSource.task;
    };

    TOSTask *task = [client resumableCopyObject:input];
    [self waitForExpectations:@[abortStarted] timeout:1.0];
    XCTAssertEqual(client.tos_createCalls, 0);
    XCTAssertEqualObjects(client.tos_abortInputs.firstObject.tosBucket, input.tosBucket);
    XCTAssertEqualObjects(client.tos_abortInputs.firstObject.tosKey, input.tosKey);
    XCTAssertEqualObjects(client.tos_abortInputs.firstObject.tosUploadID, @"stale-upload-id");
    [abortSource setResult:[TOSAbortMultipartUploadOutput new]];
    [self tos_waitForTask:task];

    XCTAssertNil(task.error);
    XCTAssertEqual(client.tos_createCalls, 1);
    XCTAssertEqualObjects(client.tos_callOrder[1], @"abort");
    XCTAssertEqualObjects(client.tos_callOrder[2], @"create");
}

- (void)testResumableCopyRejectsForeignTargetCheckpointWithoutRemoteMutation {
    TOSResumableCopyObjectInput *input = [self tos_input];
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = [self.tos_root stringByAppendingPathComponent:@"foreign-target.copy"];
    TOSHeadObjectOutput *head = [self tos_headWithSize:1];
    TOSCopyCheckpoint *checkpoint = [self tos_checkpointForInput:input
                                                            head:head
                                                        uploadID:@"foreign-upload-id"];
    checkpoint.tos_bucket = @"another-bucket";
    checkpoint.tos_key = @"another-key";
    [self tos_writeCheckpoint:checkpoint];
    NSData *before = [NSData dataWithContentsOfFile:input.tosCheckpointFile];
    TOSTestCopyClient *client = [TOSTestCopyClient new];
    client.tos_headOutput = head;

    TOSTask *task = [client resumableCopyObject:input];
    [self tos_waitForTask:task];

    XCTAssertNotNil(task.error);
    XCTAssertEqual(client.tos_abortCalls, 0);
    XCTAssertEqual(client.tos_createCalls, 0);
    XCTAssertEqual(client.tos_copyCalls, 0);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:input.tosCheckpointFile], before);
}

- (void)testResumableCopyPreservesSameTargetStaleCheckpointWhenAbortFails {
    TOSResumableCopyObjectInput *input = [self tos_input];
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = [self.tos_root stringByAppendingPathComponent:@"stale-abort-failure.copy"];
    TOSHeadObjectOutput *head = [self tos_headWithSize:1];
    TOSCopyCheckpoint *checkpoint = [self tos_checkpointForInput:input
                                                            head:head
                                                        uploadID:@"stale-upload-id"];
    checkpoint.tos_sourceETag = @"stale-source-etag";
    [self tos_writeCheckpoint:checkpoint];
    NSData *before = [NSData dataWithContentsOfFile:input.tosCheckpointFile];
    TOSTestCopyClient *client = [TOSTestCopyClient new];
    client.tos_headOutput = head;
    client.tos_abortTask = [TOSTask taskWithError:[NSError errorWithDomain:TOSServerErrorDomain
                                                                       code:500
                                                                   userInfo:nil]];

    TOSTask *task = [client resumableCopyObject:input];
    [self tos_waitForTask:task];

    XCTAssertEqual(task.error.code, 500);
    XCTAssertEqual(client.tos_abortCalls, 1);
    XCTAssertEqual(client.tos_createCalls, 0);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:input.tosCheckpointFile], before);
}

- (void)testResumableCopyCancellationDoesNotDeleteStaleCheckpointBeforeAbortConfirmation {
    TOSResumableCopyObjectInput *input = [self tos_input];
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = [self.tos_root stringByAppendingPathComponent:@"stale-cancel.copy"];
    input.tosCancelHook = [TOSCancelHook new];
    TOSHeadObjectOutput *head = [self tos_headWithSize:1];
    TOSCopyCheckpoint *checkpoint = [self tos_checkpointForInput:input
                                                            head:head
                                                        uploadID:@"stale-upload-id"];
    checkpoint.tos_sourceETag = @"stale-source-etag";
    [self tos_writeCheckpoint:checkpoint];
    NSData *before = [NSData dataWithContentsOfFile:input.tosCheckpointFile];
    TOSTaskCompletionSource *abortSource = [TOSTaskCompletionSource taskCompletionSource];
    XCTestExpectation *abortStarted = [self expectationWithDescription:@"stale abort started"];
    TOSTestCopyClient *client = [TOSTestCopyClient new];
    client.tos_headOutput = head;
    client.tos_abortHandler = ^TOSTask *(TOSAbortMultipartUploadInput *abortInput, NSInteger index) {
        [abortStarted fulfill];
        return abortSource.task;
    };

    TOSTask *task = [client resumableCopyObject:input];
    [self waitForExpectations:@[abortStarted] timeout:1.0];
    [input.tosCancelHook cancel:YES];
    XCTestExpectation *notFinished = [self expectationWithDescription:@"wait for abort confirmation"];
    notFinished.inverted = YES;
    [task continueWithBlock:^id(TOSTask *finishedTask) {
        [notFinished fulfill];
        return nil;
    }];
    [self waitForExpectations:@[notFinished] timeout:0.05];
    XCTAssertFalse(task.completed);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:input.tosCheckpointFile], before);

    [abortSource setError:[NSError errorWithDomain:TOSServerErrorDomain code:500 userInfo:nil]];
    [self tos_waitForTask:task];
    XCTAssertEqual(task.error.code, 500);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:input.tosCheckpointFile], before);
}

- (void)testResumableCopyPersistsUploadIDAndPartBeforeSuccessEvents {
    TOSResumableCopyObjectInput *input = [self tos_input];
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = [self.tos_root stringByAppendingPathComponent:@"event-order.copy"];
    NSString *checkpointPath = input.tosCheckpointFile;
    NSMutableArray<NSNumber *> *eventTypes = [NSMutableArray array];
    __block BOOL createPersisted = NO;
    __block BOOL partPersisted = NO;
    input.tosCopyEventListener = ^(TOSCopyEvent *event) {
        [eventTypes addObject:@(event.tosType)];
        NSData *data = [NSData dataWithContentsOfFile:checkpointPath];
        TOSCopyCheckpoint *stored = [TOSCopyCheckpoint tos_checkpointWithData:data
                                                               checkpointPath:checkpointPath
                                                                          error:nil];
        if (event.tosType == TOSCopyEventCreateMultipartUploadSucceed) {
            createPersisted = [stored.tos_uploadID isEqualToString:@"upload-id"];
        } else if (event.tosType == TOSCopyEventUploadPartCopySucceed) {
            partPersisted = stored.tos_parts.firstObject.tos_completed &&
                [stored.tos_parts.firstObject.tos_eTag isEqualToString:@"part-1-etag"];
        }
    };
    TOSTestCopyClient *client = [TOSTestCopyClient new];
    client.tos_headOutput = [self tos_headWithSize:1];

    TOSTask *task = [client resumableCopyObject:input];
    [self tos_waitForTask:task];

    XCTAssertNil(task.error);
    XCTAssertTrue(createPersisted);
    XCTAssertTrue(partPersisted);
    XCTAssertEqualObjects(eventTypes, (@[@(TOSCopyEventCreateMultipartUploadSucceed),
                                           @(TOSCopyEventUploadPartCopySucceed),
                                           @(TOSCopyEventCompleteMultipartUploadSucceed)]));
}

- (void)testResumableCopyRetriesTransientPartFailureAndEmitsOneSuccess {
    TOSResumableCopyObjectInput *input = [self tos_input];
    input.tosMaxRetryCount = 1;
    NSMutableArray<NSNumber *> *eventTypes = [NSMutableArray array];
    input.tosCopyEventListener = ^(TOSCopyEvent *event) {
        [eventTypes addObject:@(event.tosType)];
    };
    TOSTestCopyClient *client = [TOSTestCopyClient new];
    client.tos_headOutput = [self tos_headWithSize:1];
    client.tos_partCopyHandler = ^TOSTask *(TOSUploadPartCopyInput *partInput, NSInteger index) {
        if (index == 0) {
            return [TOSTask taskWithError:[NSError errorWithDomain:TOSServerErrorDomain
                                                               code:500
                                                           userInfo:nil]];
        }
        return nil;
    };

    TOSTask *task = [client resumableCopyObject:input];
    [self tos_waitForTask:task];

    XCTAssertNil(task.error);
    XCTAssertEqual(client.tos_partCopyCalls, 2);
    NSPredicate *success = [NSPredicate predicateWithBlock:^BOOL(NSNumber *value, NSDictionary *bindings) {
        return value.integerValue == TOSCopyEventUploadPartCopySucceed;
    }];
    NSPredicate *failure = [NSPredicate predicateWithBlock:^BOOL(NSNumber *value, NSDictionary *bindings) {
        return value.integerValue == TOSCopyEventUploadPartCopyFailed;
    }];
    XCTAssertEqual([[eventTypes filteredArrayUsingPredicate:success] count], 1);
    XCTAssertEqual([[eventTypes filteredArrayUsingPredicate:failure] count], 0);
}

- (void)testResumableCopyRetriesTransientCreateFailureBeforeStartingParts {
    TOSResumableCopyObjectInput *input = [self tos_input];
    input.tosMaxRetryCount = 1;
    NSMutableArray<NSNumber *> *eventTypes = [NSMutableArray array];
    input.tosCopyEventListener = ^(TOSCopyEvent *event) {
        [eventTypes addObject:@(event.tosType)];
    };
    TOSTestCopyClient *client = [TOSTestCopyClient new];
    client.tos_headOutput = [self tos_headWithSize:1];
    client.tos_createHandler =
        ^TOSTask *(TOSCreateMultipartUploadInput *createInput, NSInteger index) {
            if (index == 0) {
                return [TOSTask taskWithError:
                        [NSError errorWithDomain:TOSClientErrorDomain
                                           code:TOSClientErrorCodeNetworkError
                                       userInfo:@{@"OriginErrorCode": @(NSURLErrorNetworkConnectionLost)}]];
            }
            return nil;
        };

    TOSTask *task = [client resumableCopyObject:input];
    [self tos_waitForTask:task];

    XCTAssertNil(task.error);
    XCTAssertEqual(client.tos_createCalls, 2);
    XCTAssertEqual(client.tos_partCopyCalls, 1);
    XCTAssertEqual(client.tos_completeCalls, 1);
    NSPredicate *createSuccess = [NSPredicate predicateWithBlock:
        ^BOOL(NSNumber *value, NSDictionary *bindings) {
            return value.integerValue == TOSCopyEventCreateMultipartUploadSucceed;
        }];
    NSPredicate *createFailure = [NSPredicate predicateWithBlock:
        ^BOOL(NSNumber *value, NSDictionary *bindings) {
            return value.integerValue == TOSCopyEventCreateMultipartUploadFailed;
        }];
    XCTAssertEqual([[eventTypes filteredArrayUsingPredicate:createSuccess] count], 1);
    XCTAssertEqual([[eventTypes filteredArrayUsingPredicate:createFailure] count], 0);
}

- (void)testResumableCopyEmitsCreateFailureOnlyAfterRetryExhaustion {
    TOSResumableCopyObjectInput *input = [self tos_input];
    input.tosMaxRetryCount = 1;
    NSMutableArray<NSNumber *> *eventTypes = [NSMutableArray array];
    input.tosCopyEventListener = ^(TOSCopyEvent *event) {
        [eventTypes addObject:@(event.tosType)];
    };
    TOSTestCopyClient *client = [TOSTestCopyClient new];
    client.tos_headOutput = [self tos_headWithSize:1];
    client.tos_createHandler =
        ^TOSTask *(TOSCreateMultipartUploadInput *createInput, NSInteger index) {
            return [TOSTask taskWithError:
                    [NSError errorWithDomain:TOSServerErrorDomain code:500 userInfo:nil]];
        };

    TOSTask *task = [client resumableCopyObject:input];
    [self tos_waitForTask:task];

    XCTAssertEqual(task.error.code, 500);
    XCTAssertEqual(client.tos_createCalls, 2);
    XCTAssertEqual(client.tos_partCopyCalls, 0);
    XCTAssertEqual(client.tos_completeCalls, 0);
    NSPredicate *createFailure =
        [NSPredicate predicateWithFormat:@"self == %d", TOSCopyEventCreateMultipartUploadFailed];
    XCTAssertEqual([[eventTypes filteredArrayUsingPredicate:createFailure] count], 1);
}

- (void)testResumableCopyCancellationDuringCreateRetryBackoffFinishesPromptly {
    TOSResumableCopyObjectInput *input = [self tos_input];
    input.tosMaxRetryCount = 1;
    input.tosCancelHook = [TOSCancelHook new];
    XCTestExpectation *firstAttempt = [self expectationWithDescription:@"first copy create attempt"];
    XCTestExpectation *secondAttempt = [self expectationWithDescription:@"unexpected copy create retry"];
    secondAttempt.inverted = YES;
    TOSTestCopyClient *client = [TOSTestCopyClient new];
    client.tos_headOutput = [self tos_headWithSize:1];
    client.tos_createHandler =
        ^TOSTask *(TOSCreateMultipartUploadInput *createInput, NSInteger index) {
            if (index == 0) {
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

    TOSTask *task = [client resumableCopyObject:input];
    [self waitForExpectations:@[firstAttempt] timeout:1.0];
    [input.tosCancelHook cancel:NO];
    [self tos_waitForTask:task];
    [self waitForExpectations:@[secondAttempt] timeout:0.2];

    XCTAssertTrue([[self tos_messageForError:task.error] containsString:@"cancelled"]);
    XCTAssertEqual(client.tos_createCalls, 1);
    XCTAssertEqual(client.tos_partCopyCalls, 0);
    XCTAssertEqual(client.tos_completeCalls, 0);
}

- (void)testResumableCopyRejectsInvalidPartResponsesWithoutCompleting {
    for (NSString *mode in @[@"etag", @"part-number"]) {
        TOSResumableCopyObjectInput *input = [self tos_input];
        input.tosEnableCheckpoint = YES;
        input.tosCheckpointFile = [self.tos_root stringByAppendingPathComponent:[mode stringByAppendingString:@".copy"]];
        TOSTestCopyClient *client = [TOSTestCopyClient new];
        client.tos_headOutput = [self tos_headWithSize:1];
        client.tos_partCopyHandler = ^TOSTask *(TOSUploadPartCopyInput *partInput, NSInteger index) {
            TOSUploadPartCopyOutput *output = [TOSUploadPartCopyOutput new];
            output.tosPartNumber = [mode isEqualToString:@"part-number"] ? 2 : partInput.tosPartNumber;
            output.tosETag = [mode isEqualToString:@"etag"] ? @"" : @"etag";
            return [TOSTask taskWithResult:output];
        };

        TOSTask *task = [client resumableCopyObject:input];
        [self tos_waitForTask:task];

        XCTAssertNotNil(task.error, @"mode=%@", mode);
        XCTAssertEqual(client.tos_completeCalls, 0, @"mode=%@", mode);
        XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:input.tosCheckpointFile], @"mode=%@", mode);
    }
}

- (void)testResumableCopyFatalPartFailuresAbortAndRemoveCheckpointOnlyAfterSuccess {
    for (NSNumber *statusCode in @[@403, @404, @405, @412]) {
        TOSResumableCopyObjectInput *input = [self tos_input];
        input.tosEnableCheckpoint = YES;
        input.tosCheckpointFile = [self.tos_root stringByAppendingPathComponent:
                                   [NSString stringWithFormat:@"fatal-%@.copy", statusCode]];
        TOSTestCopyClient *client = [TOSTestCopyClient new];
        client.tos_headOutput = [self tos_headWithSize:1];
        client.tos_partCopyTask = [TOSTask taskWithError:[NSError errorWithDomain:TOSServerErrorDomain
                                                                              code:statusCode.integerValue
                                                                          userInfo:nil]];

        TOSTask *task = [client resumableCopyObject:input];
        [self tos_waitForTask:task];

        XCTAssertEqual(task.error.code, statusCode.integerValue);
        XCTAssertEqual(client.tos_abortCalls, 1);
        XCTAssertEqual(client.tos_completeCalls, 0);
        XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:input.tosCheckpointFile]);
    }

    TOSResumableCopyObjectInput *input = [self tos_input];
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = [self.tos_root stringByAppendingPathComponent:@"fatal-abort-failure.copy"];
    TOSTestCopyClient *client = [TOSTestCopyClient new];
    client.tos_headOutput = [self tos_headWithSize:1];
    client.tos_partCopyTask = [TOSTask taskWithError:[NSError errorWithDomain:TOSServerErrorDomain code:412 userInfo:nil]];
    client.tos_abortTask = [TOSTask taskWithError:[NSError errorWithDomain:TOSServerErrorDomain code:500 userInfo:nil]];
    TOSTask *task = [client resumableCopyObject:input];
    [self tos_waitForTask:task];
    XCTAssertEqual(task.error.code, 500);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:input.tosCheckpointFile]);
}

- (void)testResumableCopyAbortsMultipartOnPartFailureWithoutCheckpoint {
    TOSResumableCopyObjectInput *input = [self tos_input];
    TOSTestCopyClient *client = [TOSTestCopyClient new];
    client.tos_headOutput = [self tos_headWithSize:1];
    client.tos_partCopyTask =
        [TOSTask taskWithError:[NSError errorWithDomain:TOSServerErrorDomain
                                                   code:400
                                               userInfo:nil]];

    TOSTask *task = [client resumableCopyObject:input];
    [self tos_waitForTask:task];

    XCTAssertNotNil(task.error);
    XCTAssertEqual(client.tos_abortCalls, 1);
    XCTAssertEqual(client.tos_completeCalls, 0);
    XCTAssertEqualObjects(client.tos_abortInputs.firstObject.tosUploadID, @"upload-id");
}

- (void)testResumableCopyCompleteFailurePreservesCheckpointExceptNoSuchUpload {
    for (NSNumber *noSuchUpload in @[@NO, @YES]) {
        TOSResumableCopyObjectInput *input = [self tos_input];
        input.tosEnableCheckpoint = YES;
        input.tosCheckpointFile = [self.tos_root stringByAppendingPathComponent:
                                   [NSString stringWithFormat:@"complete-%@.copy", noSuchUpload]];
        NSMutableArray<NSNumber *> *events = [NSMutableArray array];
        input.tosCopyEventListener = ^(TOSCopyEvent *event) {
            [events addObject:@(event.tosType)];
        };
        NSDictionary *userInfo = noSuchUpload.boolValue ? @{@"Code": @"NoSuchUpload"} : @{};
        TOSTestCopyClient *client = [TOSTestCopyClient new];
        client.tos_headOutput = [self tos_headWithSize:1];
        client.tos_completeTask = [TOSTask taskWithError:[NSError errorWithDomain:TOSServerErrorDomain
                                                                              code:noSuchUpload.boolValue ? 404 : 500
                                                                          userInfo:userInfo]];

        TOSTask *task = [client resumableCopyObject:input];
        [self tos_waitForTask:task];

        XCTAssertNotNil(task.error);
        XCTAssertEqual([[NSFileManager defaultManager] fileExistsAtPath:input.tosCheckpointFile], !noSuchUpload.boolValue);
        XCTAssertTrue([events containsObject:@(TOSCopyEventCompleteMultipartUploadFailed)]);
        XCTAssertFalse([events containsObject:@(TOSCopyEventCompleteMultipartUploadSucceed)]);
    }
}

- (void)testResumableCopyAbortsMultipartOnCompleteFailureWithoutCheckpoint {
    TOSResumableCopyObjectInput *input = [self tos_input];
    TOSTestCopyClient *client = [TOSTestCopyClient new];
    client.tos_headOutput = [self tos_headWithSize:1];
    client.tos_completeTask =
        [TOSTask taskWithError:[NSError errorWithDomain:TOSServerErrorDomain
                                                   code:400
                                               userInfo:nil]];

    TOSTask *task = [client resumableCopyObject:input];
    [self tos_waitForTask:task];

    XCTAssertEqual(task.error.code, 400);
    XCTAssertEqual(client.tos_abortCalls, 1);
    XCTAssertEqual(client.tos_completeCalls, 1);
}

- (void)testResumableCopyRejectsMismatchedCompleteResponseAndPreservesCheckpoint {
    TOSResumableCopyObjectInput *input = [self tos_input];
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = [self.tos_root stringByAppendingPathComponent:@"mismatched-complete.copy"];
    NSMutableArray<NSNumber *> *events = [NSMutableArray array];
    input.tosCopyEventListener = ^(TOSCopyEvent *event) {
        [events addObject:@(event.tosType)];
    };
    TOSTestCopyClient *client = [TOSTestCopyClient new];
    client.tos_headOutput = [self tos_headWithSize:1];
    client.tos_completeHandler = ^TOSTask *(TOSCompleteMultipartUploadInput *completeInput, NSInteger index) {
        TOSCompleteMultipartUploadOutput *output = [TOSCompleteMultipartUploadOutput new];
        output.tosBucket = @"other-bucket";
        output.tosKey = completeInput.tosKey;
        output.tosETag = @"complete-etag";
        output.tosLocation = @"location";
        return [TOSTask taskWithResult:output];
    };

    TOSTask *task = [client resumableCopyObject:input];
    [self tos_waitForTask:task];

    XCTAssertNotNil(task.error);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:input.tosCheckpointFile]);
    XCTAssertTrue([events containsObject:@(TOSCopyEventCompleteMultipartUploadFailed)]);
    XCTAssertFalse([events containsObject:@(TOSCopyEventCompleteMultipartUploadSucceed)]);
}

- (void)testResumableCopyDetectsCRCMismatchAndRemovesCheckpoint {
    TOSResumableCopyObjectInput *input = [self tos_input];
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = [self.tos_root stringByAppendingPathComponent:@"crc-mismatch.copy"];
    TOSTestCopyClient *client = [TOSTestCopyClient new];
    client.tos_headOutput = [self tos_headWithSize:1];
    client.tos_completeHandler = ^TOSTask *(TOSCompleteMultipartUploadInput *completeInput, NSInteger index) {
        TOSCompleteMultipartUploadOutput *output = [TOSCompleteMultipartUploadOutput new];
        output.tosBucket = completeInput.tosBucket;
        output.tosKey = completeInput.tosKey;
        output.tosETag = @"complete-etag";
        output.tosLocation = @"location";
        output.tosHashCrc64ecma = client.tos_headOutput.tosHashCrc64ecma + 1;
        return [TOSTask taskWithResult:output];
    };

    TOSTask *task = [client resumableCopyObject:input];
    [self tos_waitForTask:task];

    XCTAssertTrue([[self tos_messageForError:task.error] containsString:@"crc"]);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:input.tosCheckpointFile]);
}

- (void)testResumableCopyCancellationPreservesOrAbortsAccordingToFlag {
    for (NSNumber *shouldAbort in @[@NO, @YES]) {
        TOSResumableCopyObjectInput *input = [self tos_input];
        input.tosEnableCheckpoint = YES;
        input.tosCheckpointFile = [self.tos_root stringByAppendingPathComponent:
                                   [NSString stringWithFormat:@"cancel-%@.copy", shouldAbort]];
        input.tosCancelHook = [TOSCancelHook new];
        TOSTaskCompletionSource *partSource = [TOSTaskCompletionSource taskCompletionSource];
        XCTestExpectation *partStarted = [self expectationWithDescription:@"part started"];
        TOSTestCopyClient *client = [TOSTestCopyClient new];
        client.tos_headOutput = [self tos_headWithSize:1];
        client.tos_partCopyHandler = ^TOSTask *(TOSUploadPartCopyInput *partInput, NSInteger index) {
            [partStarted fulfill];
            return partSource.task;
        };

        TOSTask *task = [client resumableCopyObject:input];
        [self waitForExpectations:@[partStarted] timeout:1.0];
        [input.tosCancelHook cancel:shouldAbort.boolValue];
        [partSource setError:[NSError errorWithDomain:TOSClientErrorDomain code:400 userInfo:nil]];
        [self tos_waitForTask:task];

        XCTAssertTrue([[self tos_messageForError:task.error] containsString:@"cancelled"]);
        XCTAssertEqual(client.tos_abortCalls, shouldAbort.boolValue ? 1 : 0);
        XCTAssertEqual([[NSFileManager defaultManager] fileExistsAtPath:input.tosCheckpointFile], !shouldAbort.boolValue);
    }
}

- (void)testResumableCopyCancellationWithoutCheckpointAlwaysAbortsMultipart {
    TOSResumableCopyObjectInput *input = [self tos_input];
    input.tosCancelHook = [TOSCancelHook new];
    TOSTaskCompletionSource *partSource = [TOSTaskCompletionSource taskCompletionSource];
    XCTestExpectation *partStarted = [self expectationWithDescription:@"part started"];
    TOSTestCopyClient *client = [TOSTestCopyClient new];
    client.tos_headOutput = [self tos_headWithSize:1];
    client.tos_partCopyHandler = ^TOSTask *(TOSUploadPartCopyInput *partInput, NSInteger index) {
        [partStarted fulfill];
        return partSource.task;
    };

    TOSTask *task = [client resumableCopyObject:input];
    [self waitForExpectations:@[partStarted] timeout:1.0];
    [input.tosCancelHook cancel:NO];
    [partSource setError:[NSError errorWithDomain:TOSClientErrorDomain
                                              code:TOSClientErrorCodeTaskCancelled
                                          userInfo:nil]];
    [self tos_waitForTask:task];

    XCTAssertTrue([[self tos_messageForError:task.error] containsString:@"cancelled"]);
    XCTAssertEqual(client.tos_abortCalls, 1);
    XCTAssertEqual(client.tos_completeCalls, 0);
}

- (void)testResumableCopyAsyncAbortCompletesOnceAndReleasesOperation {
    TOSResumableCopyObjectInput *input = [self tos_input];
    input.tosCancelHook = [TOSCancelHook new];
    TOSTaskCompletionSource *partSource = [TOSTaskCompletionSource taskCompletionSource];
    TOSTaskCompletionSource *abortSource = [TOSTaskCompletionSource taskCompletionSource];
    XCTestExpectation *partStarted = [self expectationWithDescription:@"part started"];
    XCTestExpectation *abortStarted = [self expectationWithDescription:@"abort started"];
    XCTestExpectation *deallocated = [self expectationWithDescription:@"copy operation deallocated"];
    TOSTestCopyClient *client = [TOSTestCopyClient new];
    client.tos_headOutput = [self tos_headWithSize:1];
    client.tos_partCopyHandler = ^TOSTask *(TOSUploadPartCopyInput *partInput, NSInteger index) {
        [partStarted fulfill];
        return partSource.task;
    };
    client.tos_abortHandler = ^TOSTask *(TOSAbortMultipartUploadInput *abortInput, NSInteger index) {
        [abortStarted fulfill];
        return abortSource.task;
    };
    __block NSInteger completionCount = 0;
    __weak TOSTestLifetimeCopyOperation *weakOperation = nil;

    @autoreleasepool {
        TOSTestLifetimeCopyOperation *operation =
            [[TOSTestLifetimeCopyOperation alloc] initWithClient:client request:input];
        operation.tos_deallocBlock = ^{
            [deallocated fulfill];
        };
        weakOperation = operation;
        [operation.task continueWithBlock:^id(TOSTask *finishedTask) {
            completionCount += 1;
            return nil;
        }];
        [operation start];
        [self waitForExpectations:@[partStarted] timeout:1.0];
        [input.tosCancelHook cancel:YES];
        [partSource setError:[NSError errorWithDomain:TOSClientErrorDomain
                                                  code:TOSClientErrorCodeTaskCancelled
                                              userInfo:nil]];
        [self waitForExpectations:@[abortStarted] timeout:1.0];
        [abortSource setResult:[TOSAbortMultipartUploadOutput new]];
        [self tos_waitForTask:operation.task];

        XCTAssertEqual(completionCount, 1);
        XCTAssertEqual(client.tos_abortCalls, 1);
    }

    [self waitForExpectations:@[deallocated] timeout:1.0];
    XCTAssertNil(weakOperation);
}

- (void)testResumableCopyPublicFactoryRetainsOperationUntilAsyncCompletion {
    TOSTaskCompletionSource *createSource = [TOSTaskCompletionSource taskCompletionSource];
    XCTestExpectation *createStarted = [self expectationWithDescription:@"create started"];
    TOSTestCopyClient *client = [TOSTestCopyClient new];
    client.tos_headOutput = [self tos_headWithSize:0];
    client.tos_createHandler = ^TOSTask *(TOSCreateMultipartUploadInput *createInput, NSInteger index) {
        [createStarted fulfill];
        return createSource.task;
    };

    TOSTask *task = [client resumableCopyObject:[self tos_input]];
    [self waitForExpectations:@[createStarted] timeout:1.0];
    TOSCreateMultipartUploadOutput *output = [TOSCreateMultipartUploadOutput new];
    output.tosUploadID = @"async-upload-id";
    [createSource setResult:output];
    [self tos_waitForTask:task];

    XCTAssertNil(task.error);
    XCTAssertEqual(client.tos_completeCalls, 1);
    XCTAssertEqualObjects(((TOSResumableCopyObjectOutput *)task.result).tosUploadID, @"async-upload-id");
}

- (void)testResumableCopyRejectsEmptyUploadIDAndPreservesCheckpointOnCreateFailure {
    for (NSNumber *serverFailure in @[@NO, @YES]) {
        TOSResumableCopyObjectInput *input = [self tos_input];
        input.tosMaxRetryCount = 0;
        input.tosEnableCheckpoint = YES;
        input.tosCheckpointFile = [self.tos_root stringByAppendingPathComponent:
                                   [NSString stringWithFormat:@"create-%@.copy", serverFailure]];
        NSMutableArray<NSNumber *> *events = [NSMutableArray array];
        input.tosCopyEventListener = ^(TOSCopyEvent *event) {
            [events addObject:@(event.tosType)];
        };
        TOSTestCopyClient *client = [TOSTestCopyClient new];
        client.tos_headOutput = [self tos_headWithSize:1];
        if (serverFailure.boolValue) {
            client.tos_createTask = [TOSTask taskWithError:[NSError errorWithDomain:TOSServerErrorDomain
                                                                                code:500
                                                                            userInfo:nil]];
        } else {
            client.tos_createTask = [TOSTask taskWithResult:[TOSCreateMultipartUploadOutput new]];
        }

        TOSTask *task = [client resumableCopyObject:input];
        [self tos_waitForTask:task];

        XCTAssertNotNil(task.error);
        XCTAssertEqual(client.tos_createCalls, 1);
        XCTAssertEqual(client.tos_partCopyCalls, 0);
        XCTAssertEqual(client.tos_completeCalls, 0);
        XCTAssertTrue([events containsObject:@(TOSCopyEventCreateMultipartUploadFailed)]);
        NSData *data = [NSData dataWithContentsOfFile:input.tosCheckpointFile];
        TOSCopyCheckpoint *stored = [TOSCopyCheckpoint tos_checkpointWithData:data
                                                               checkpointPath:input.tosCheckpointFile
                                                                          error:nil];
        XCTAssertNotNil(stored);
        XCTAssertEqualObjects(stored.tos_uploadID, @"");
    }
}

- (void)testResumableCopyCancellationDuringCreatePersistsUploadIDBeforeCleanup {
    for (NSNumber *shouldAbort in @[@NO, @YES]) {
        TOSResumableCopyObjectInput *input = [self tos_input];
        input.tosEnableCheckpoint = YES;
        input.tosCheckpointFile = [self.tos_root stringByAppendingPathComponent:
                                   [NSString stringWithFormat:@"create-cancel-%@.copy", shouldAbort]];
        input.tosCancelHook = [TOSCancelHook new];
        TOSTaskCompletionSource *createSource = [TOSTaskCompletionSource taskCompletionSource];
        XCTestExpectation *createStarted = [self expectationWithDescription:@"create started"];
        TOSTestCopyClient *client = [TOSTestCopyClient new];
        client.tos_headOutput = [self tos_headWithSize:1];
        client.tos_createHandler = ^TOSTask *(TOSCreateMultipartUploadInput *createInput, NSInteger index) {
            [createStarted fulfill];
            return createSource.task;
        };

        TOSTask *task = [client resumableCopyObject:input];
        [self waitForExpectations:@[createStarted] timeout:1.0];
        [input.tosCancelHook cancel:shouldAbort.boolValue];
        TOSCreateMultipartUploadOutput *output = [TOSCreateMultipartUploadOutput new];
        output.tosUploadID = @"create-cancel-upload-id";
        [createSource setResult:output];
        [self tos_waitForTask:task];

        XCTAssertTrue([[self tos_messageForError:task.error] containsString:@"cancelled"]);
        XCTAssertEqual(client.tos_abortCalls, shouldAbort.boolValue ? 1 : 0);
        BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:input.tosCheckpointFile];
        XCTAssertEqual(exists, !shouldAbort.boolValue);
        if (exists) {
            NSData *data = [NSData dataWithContentsOfFile:input.tosCheckpointFile];
            TOSCopyCheckpoint *stored = [TOSCopyCheckpoint tos_checkpointWithData:data
                                                                   checkpointPath:input.tosCheckpointFile
                                                                              error:nil];
            XCTAssertEqualObjects(stored.tos_uploadID, @"create-cancel-upload-id");
        }
    }
}

- (void)testResumableCopyCancelWithAbortPreservesCheckpointWhenAbortFails {
    TOSResumableCopyObjectInput *input = [self tos_input];
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = [self.tos_root stringByAppendingPathComponent:@"cancel-abort-failure.copy"];
    input.tosCancelHook = [TOSCancelHook new];
    TOSTaskCompletionSource *partSource = [TOSTaskCompletionSource taskCompletionSource];
    XCTestExpectation *partStarted = [self expectationWithDescription:@"part started"];
    TOSTestCopyClient *client = [TOSTestCopyClient new];
    client.tos_headOutput = [self tos_headWithSize:1];
    client.tos_abortTask = [TOSTask taskWithError:[NSError errorWithDomain:TOSServerErrorDomain code:500 userInfo:nil]];
    client.tos_partCopyHandler = ^TOSTask *(TOSUploadPartCopyInput *partInput, NSInteger index) {
        [partStarted fulfill];
        return partSource.task;
    };

    TOSTask *task = [client resumableCopyObject:input];
    [self waitForExpectations:@[partStarted] timeout:1.0];
    [input.tosCancelHook cancel:YES];
    [partSource setError:[NSError errorWithDomain:TOSClientErrorDomain
                                              code:TOSClientErrorCodeTaskCancelled
                                          userInfo:nil]];
    [self tos_waitForTask:task];

    XCTAssertEqual(task.error.code, 500);
    XCTAssertEqual(client.tos_abortCalls, 1);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:input.tosCheckpointFile]);
}

- (void)testResumableCopyCancellationDuringHeadRetryBackoffFinishesPromptly {
    TOSResumableCopyObjectInput *input = [self tos_input];
    input.tosCancelHook = [TOSCancelHook new];
    input.tosMaxRetryCount = 3;
    XCTestExpectation *headStarted = [self expectationWithDescription:@"head started"];
    TOSTestCopyClient *client = [TOSTestCopyClient new];
    client.tos_headHandler = ^TOSTask *(TOSHeadObjectInput *headInput, NSInteger index) {
        [headStarted fulfill];
        return [TOSTask taskWithError:[NSError errorWithDomain:TOSServerErrorDomain code:500 userInfo:nil]];
    };

    TOSTask *task = [client resumableCopyObject:input];
    [self waitForExpectations:@[headStarted] timeout:1.0];
    [input.tosCancelHook cancel:NO];
    [self tos_waitForTask:task];

    XCTAssertTrue([[self tos_messageForError:task.error] containsString:@"cancelled"]);
    XCTAssertEqual(client.tos_createCalls, 0);
    XCTAssertLessThanOrEqual(client.tos_headCalls, 1);
}

- (void)testResumableCopyHonorsRetryAfterFromHeadResponse {
    TOSResumableCopyObjectInput *input = [self tos_input];
    input.tosCancelHook = [TOSCancelHook new];
    input.tosMaxRetryCount = 1;
    XCTestExpectation *firstAttempt = [self expectationWithDescription:@"first copy head attempt"];
    XCTestExpectation *secondAttempt = [self expectationWithDescription:@"unexpected copy head retry"];
    secondAttempt.inverted = YES;
    TOSTestCopyClient *client = [TOSTestCopyClient new];
    client.tos_headHandler = ^TOSTask *(TOSHeadObjectInput *headInput, NSInteger index) {
        if (index == 0) {
            XCTAssertNotNil(headInput.tos_responseObserver);
            if (headInput.tos_responseObserver) {
                NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc]
                    initWithURL:[NSURL URLWithString:@"https://example.com/object"]
                    statusCode:429
                    HTTPVersion:@"HTTP/1.1"
                    headerFields:@{@"Retry-After": @"60"}];
                headInput.tos_responseObserver(response);
            }
            [firstAttempt fulfill];
        } else {
            [secondAttempt fulfill];
        }
        return [TOSTask taskWithError:
                [NSError errorWithDomain:TOSServerErrorDomain code:429 userInfo:@{}]];
    };

    TOSTask *task = [client resumableCopyObject:input];
    [self waitForExpectations:@[firstAttempt] timeout:1.0];
    [self waitForExpectations:@[secondAttempt] timeout:0.5];
    XCTAssertEqual(client.tos_headCalls, 1);
    [input.tosCancelHook cancel:NO];
    [self tos_waitForTask:task];

    XCTAssertTrue([[self tos_messageForError:task.error] containsString:@"cancelled"]);
}

- (void)testResumableCopyConfirmedCompleteSuccessWinsCancellationRace {
    TOSResumableCopyObjectInput *input = [self tos_input];
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = [self.tos_root stringByAppendingPathComponent:@"complete-race.copy"];
    input.tosCancelHook = [TOSCancelHook new];
    TOSTaskCompletionSource *completeSource = [TOSTaskCompletionSource taskCompletionSource];
    XCTestExpectation *completeStarted = [self expectationWithDescription:@"complete started"];
    TOSTestCopyClient *client = [TOSTestCopyClient new];
    client.tos_headOutput = [self tos_headWithSize:1];
    client.tos_completeHandler = ^TOSTask *(TOSCompleteMultipartUploadInput *completeInput, NSInteger index) {
        [completeStarted fulfill];
        return completeSource.task;
    };

    TOSTask *task = [client resumableCopyObject:input];
    [self waitForExpectations:@[completeStarted] timeout:1.0];
    [input.tosCancelHook cancel:YES];
    TOSCompleteMultipartUploadOutput *output = [TOSCompleteMultipartUploadOutput new];
    output.tosBucket = input.tosBucket;
    output.tosKey = input.tosKey;
    output.tosETag = @"complete-race-etag";
    output.tosLocation = @"location";
    output.tosHashCrc64ecma = client.tos_headOutput.tosHashCrc64ecma;
    [completeSource setResult:output];
    [self tos_waitForTask:task];

    XCTAssertNil(task.error);
    XCTAssertEqualObjects(((TOSResumableCopyObjectOutput *)task.result).tosETag, @"complete-race-etag");
    XCTAssertEqual(client.tos_abortCalls, 0);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:input.tosCheckpointFile]);
}

@end
