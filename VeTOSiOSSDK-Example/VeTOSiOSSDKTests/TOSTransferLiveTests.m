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

#import <CommonCrypto/CommonDigest.h>
#import <XCTest/XCTest.h>
#import "TOSTestConstants.h"
#import "TOSTestUtil.h"
#import <VeTOSiOSSDK/VeTOSiOSSDK.h>

static const NSTimeInterval TOSLiveTaskTimeout = 900.0;
static const NSTimeInterval TOSLiveLargeTaskTimeout = 7200.0;
static const int64_t TOSLiveLargePartSize = 64LL * 1024 * 1024;

static BOOL TOSLiveIsPlaceholder(NSString *value, NSArray<NSString *> *placeholders) {
    if (value.length == 0) {
        return YES;
    }
    for (NSString *placeholder in placeholders) {
        if ([value caseInsensitiveCompare:placeholder] == NSOrderedSame) {
            return YES;
        }
    }
    return NO;
}

@interface TOSTransferLiveTests : XCTestCase
@property (nonatomic, strong) TOSClient *tos_client;
@property (nonatomic, copy) NSString *tos_bucket;
@property (nonatomic, copy) NSString *tos_prefix;
@property (nonatomic, copy) NSString *tos_root;
@property (nonatomic, assign) BOOL tos_liveEnabled;
@property (nonatomic, strong) NSMutableArray<NSString *> *tos_keys;
@property (nonatomic, strong) NSMutableArray<NSString *> *tos_localPaths;
@property (nonatomic, strong) NSMutableArray<NSDictionary<NSString *, NSString *> *> *tos_multipartUploads;
@property (nonatomic, strong) NSMapTable<TOSTask *, TOSCancelHook *> *tos_cancelHooks;
@end

@implementation TOSTransferLiveTests

- (void)setUp {
    [super setUp];
    self.tos_keys = [NSMutableArray array];
    self.tos_localPaths = [NSMutableArray array];
    self.tos_multipartUploads = [NSMutableArray array];
    self.tos_cancelHooks = [NSMapTable strongToStrongObjectsMapTable];
    self.tos_prefix =
        [NSString stringWithFormat:@"ve-tos-ios-sdk-resumable-transfer-tests/%@/",
                                   NSUUID.UUID.UUIDString];
    self.tos_root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:self.tos_root
                                             withIntermediateDirectories:YES
                                                              attributes:@{NSFilePosixPermissions: @0700}
                                                                   error:nil]);

    NSString *accessKey = TOSTestEnvironmentValue(@"TOS_ACCESS_KEY");
    NSString *secretKey = TOSTestEnvironmentValue(@"TOS_SECRET_KEY");
    NSString *endpoint = TOSTestEnvironmentValue(@"TOS_ENDPOINT");
    NSString *region = TOSTestEnvironmentValue(@"TOS_REGION");
    NSString *bucketPrefix = TOSTestEnvironmentValue(@"TOS_BUCKET");
    self.tos_liveEnabled = !TOSLiveIsPlaceholder(accessKey, @[@"AK", @"access-key"]) &&
        !TOSLiveIsPlaceholder(secretKey, @[@"SK", @"secret-key"]) &&
        !TOSLiveIsPlaceholder(endpoint, @[@"endpoint"]) &&
        !TOSLiveIsPlaceholder(region, @[@"region"]) &&
        !TOSLiveIsPlaceholder(bucketPrefix, @[@"bucket"]);
    if (self.tos_liveEnabled) {
        self.tos_bucket = [TOSTestUtil randomBucketNameWithPrefix:bucketPrefix testClass:self.class];
        TOSCredential *credential = [[TOSCredential alloc] initWithAccessKey:accessKey secretKey:secretKey];
        TOSEndpoint *tosEndpoint = [[TOSEndpoint alloc] initWithURLString:endpoint withRegion:region];
        TOSClientConfiguration *configuration = [[TOSClientConfiguration alloc] initWithEndpoint:tosEndpoint
                                                                                       credential:credential];
        self.tos_client = [[TOSClient alloc] initWithConfiguration:configuration];
        NSError *error = [TOSTestUtil createBucket:self.tos_bucket withClient:self.tos_client];
        XCTAssertNil(error, @"Failed to create isolated test bucket %@: %@", self.tos_bucket, error);
    }
}

- (void)tearDown {
    if (self.tos_liveEnabled) {
        for (TOSCancelHook *cancelHook in self.tos_cancelHooks.objectEnumerator) {
            [cancelHook cancel:YES];
        }
        NSArray<TOSTask *> *activeTasks = [self.tos_cancelHooks.keyEnumerator allObjects];
        NSDate *cancellationDeadline = [NSDate dateWithTimeIntervalSinceNow:30.0];
        for (TOSTask *task in activeTasks) {
            NSTimeInterval remaining = cancellationDeadline.timeIntervalSinceNow;
            if (remaining <= 0 || task.isCompleted) {
                continue;
            }
            dispatch_semaphore_t completion = dispatch_semaphore_create(0);
            [task continueWithBlock:^id(TOSTask *finishedTask) {
                (void)finishedTask;
                dispatch_semaphore_signal(completion);
                return nil;
            }];
            dispatch_semaphore_wait(completion,
                                    dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)));
        }
        NSArray<NSDictionary<NSString *, NSString *> *> *multipartUploads = nil;
        @synchronized (self.tos_multipartUploads) {
            multipartUploads = [self.tos_multipartUploads copy];
        }
        for (NSDictionary<NSString *, NSString *> *multipart in [multipartUploads reverseObjectEnumerator]) {
            TOSAbortMultipartUploadInput *abort = [TOSAbortMultipartUploadInput new];
            abort.tosBucket = self.tos_bucket;
            abort.tosKey = multipart[@"key"];
            abort.tosUploadID = multipart[@"uploadID"];
            [[self.tos_client abortMultipartUpload:abort] waitUntilFinished];
        }
        [self tos_abortRemainingMultipartUploads];
        for (NSString *key in [self.tos_keys reverseObjectEnumerator]) {
            TOSDeleteObjectInput *deleteInput = [TOSDeleteObjectInput new];
            deleteInput.tosBucket = self.tos_bucket;
            deleteInput.tosKey = key;
            [[self.tos_client deleteObject:deleteInput] waitUntilFinished];
        }
        [TOSTestUtil cleanBucket:self.tos_bucket withClient:self.tos_client];
    }
    for (NSString *path in self.tos_localPaths) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    }
    [[NSFileManager defaultManager] removeItemAtPath:self.tos_root error:nil];
    [super tearDown];
}

- (void)tos_abortRemainingMultipartUploads {
    TOSListMultipartUploadsOutput *output = nil;
    do {
        TOSListMultipartUploadsInput *input = [TOSListMultipartUploadsInput new];
        input.tosBucket = self.tos_bucket;
        input.tosPrefix = self.tos_prefix;
        input.tosMaxUploads = 1000;
        input.tosKeyMarker = output.tosNextKeyMarker;
        input.tosUploadIDMarker = output.tosNextUploadIDMarker;
        TOSTask<TOSListMultipartUploadsOutput *> *task =
            (TOSTask<TOSListMultipartUploadsOutput *> *)[self.tos_client listMultipartUploads:input];
        [task waitUntilFinished];
        if (task.error || !task.result) {
            return;
        }
        output = task.result;
        for (TOSListedUpload *upload in output.tosUploads) {
            if (![self.tos_keys containsObject:upload.tosKey]) {
                continue;
            }
            TOSAbortMultipartUploadInput *abort = [TOSAbortMultipartUploadInput new];
            abort.tosBucket = self.tos_bucket;
            abort.tosKey = upload.tosKey;
            abort.tosUploadID = upload.tosUploadID;
            [[self.tos_client abortMultipartUpload:abort] waitUntilFinished];
        }
    } while (output.tosIsTruncated);
}

- (void)tos_requireLiveConfiguration {
    if (!self.tos_liveEnabled) {
        XCTSkip(@"请通过本机环境变量配置 TOS 测试凭证、Endpoint、Region 和 Bucket");
    }
}

- (NSString *)tos_keyWithName:(NSString *)name {
    NSString *key = [self.tos_prefix stringByAppendingString:name];
    [self.tos_keys addObject:key];
    return key;
}

- (NSString *)tos_localPathWithName:(NSString *)name {
    NSString *path = [self.tos_root stringByAppendingPathComponent:name];
    [self.tos_localPaths addObject:path];
    return path;
}

- (NSString *)tos_createFileNamed:(NSString *)name size:(int64_t)size {
    return [self tos_createFileNamed:name size:size sha256:nil];
}

- (NSString *)tos_createFileNamed:(NSString *)name
                             size:(int64_t)size
                           sha256:(NSString **)sha256 {
    NSString *path = [self tos_localPathWithName:name];
    NSError *error = nil;
    uint64_t seed = UINT64_C(0x6a09e667f3bcc909) ^
        (uint64_t)size ^
        ((uint64_t)name.hash << 1);
    NSString *generatedSHA256 =
        [TOSTestUtil createDeterministicFileAtPath:path
                                             size:size
                                             seed:seed
                                            error:&error];
    XCTAssertNil(error);
    XCTAssertNotNil(generatedSHA256);
    if (sha256) {
        *sha256 = generatedSHA256;
    }
    return path;
}

- (void)tos_trackUploadID:(NSString *)uploadID key:(NSString *)key {
    if (uploadID.length == 0 || key.length == 0) {
        return;
    }
    @synchronized (self.tos_multipartUploads) {
        for (NSDictionary<NSString *, NSString *> *multipart in self.tos_multipartUploads) {
            if ([multipart[@"uploadID"] isEqualToString:uploadID] &&
                [multipart[@"key"] isEqualToString:key]) {
                return;
            }
        }
        [self.tos_multipartUploads addObject:@{@"uploadID": uploadID, @"key": key}];
    }
}

- (void)tos_registerTask:(TOSTask *)task cancelHook:(TOSCancelHook *)cancelHook {
    if (task && cancelHook) {
        [self.tos_cancelHooks setObject:cancelHook forKey:task];
    }
}

- (BOOL)tos_waitForTask:(TOSTask *)task description:(NSString *)description {
    return [self tos_waitForTask:task description:description timeout:TOSLiveTaskTimeout];
}

- (BOOL)tos_waitForTask:(TOSTask *)task
            description:(NSString *)description
                timeout:(NSTimeInterval)timeout {
    dispatch_semaphore_t completion = dispatch_semaphore_create(0);
    [task continueWithBlock:^id(TOSTask *finishedTask) {
        (void)finishedTask;
        dispatch_semaphore_signal(completion);
        return nil;
    }];
    long result = dispatch_semaphore_wait(completion,
                                          dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));
    if (result != 0) {
        TOSCancelHook *cancelHook = [self.tos_cancelHooks objectForKey:task];
        [cancelHook cancel:YES];
        long cancellationResult = cancelHook ?
            dispatch_semaphore_wait(completion,
                                    dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30.0 * NSEC_PER_SEC))) : -1;
        if (cancellationResult == 0) {
            [self.tos_cancelHooks removeObjectForKey:task];
        }
        XCTFail(@"%@ timed out after %.0f seconds", description, timeout);
        return NO;
    }
    [self.tos_cancelHooks removeObjectForKey:task];
    return YES;
}

- (NSString *)tos_SHA256ForFile:(NSString *)path {
    NSInputStream *stream = [NSInputStream inputStreamWithFileAtPath:path];
    [stream open];
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    uint8_t buffer[64 * 1024];
    NSInteger count = 0;
    while ((count = [stream read:buffer maxLength:sizeof(buffer)]) > 0) {
        CC_SHA256_Update(&context, buffer, (CC_LONG)count);
    }
    XCTAssertNil(stream.streamError);
    [stream close];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        [hex appendFormat:@"%02x", digest[index]];
    }
    return hex;
}

- (BOOL)tos_assertTaskSucceeded:(TOSTask *)task context:(NSString *)context {
    XCTAssertNil(task.error, @"%@ failed: %@", context, task.error);
    XCTAssertNotNil(task.result, @"%@ returned no output", context);
    return task.error == nil && task.result != nil;
}

- (TOSTask<TOSUploadFileOutputV2 *> *)tos_uploadFile:(NSString *)filePath
                                                 key:(NSString *)key
                                             taskNum:(int)taskNum
                                      checkpointPath:(NSString *)checkpointPath
                                            listener:(TOSUploadEventListener)listener
                                          cancelHook:(TOSCancelHook *)cancelHook {
    return [self tos_uploadFile:filePath
                            key:key
                        taskNum:taskNum
                       partSize:TOSMinPartSize
                 checkpointPath:checkpointPath
                       listener:listener
                     cancelHook:cancelHook];
}

- (TOSTask<TOSUploadFileOutputV2 *> *)tos_uploadFile:(NSString *)filePath
                                                 key:(NSString *)key
                                             taskNum:(int)taskNum
                                            partSize:(int64_t)partSize
                                      checkpointPath:(NSString *)checkpointPath
                                            listener:(TOSUploadEventListener)listener
                                          cancelHook:(TOSCancelHook *)cancelHook {
    TOSUploadFileInputV2 *input = [TOSUploadFileInputV2 new];
    input.tosBucket = self.tos_bucket;
    input.tosKey = key;
    input.tosFilePath = filePath;
    input.tosPartSize = partSize;
    input.tosTaskNum = taskNum;
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = checkpointPath;
    __weak typeof(self) weakSelf = self;
    input.tosUploadEventListener = ^(TOSUploadEvent *event) {
        [weakSelf tos_trackUploadID:event.tosUploadID key:key];
        if (listener) {
            listener(event);
        }
    };
    input.tosCancelHook = cancelHook ?: [TOSCancelHook new];
    TOSTask<TOSUploadFileOutputV2 *> *task = (TOSTask<TOSUploadFileOutputV2 *> *)[self.tos_client uploadFile:input];
    [self tos_registerTask:task cancelHook:input.tosCancelHook];
    return task;
}

- (TOSTask<TOSDownloadFileOutput *> *)tos_downloadKey:(NSString *)key
                                                toPath:(NSString *)filePath
                                                taskNum:(int)taskNum
                                         checkpointPath:(NSString *)checkpointPath
                                                listener:(TOSDownloadEventListener)listener
                                              cancelHook:(TOSCancelHook *)cancelHook {
    return [self tos_downloadKey:key
                          toPath:filePath
                         taskNum:taskNum
                        partSize:TOSMinPartSize
                  checkpointPath:checkpointPath
                        listener:listener
                      cancelHook:cancelHook];
}

- (TOSTask<TOSDownloadFileOutput *> *)tos_downloadKey:(NSString *)key
                                                toPath:(NSString *)filePath
                                               taskNum:(int)taskNum
                                              partSize:(int64_t)partSize
                                        checkpointPath:(NSString *)checkpointPath
                                              listener:(TOSDownloadEventListener)listener
                                            cancelHook:(TOSCancelHook *)cancelHook {
    TOSDownloadFileInput *input = [TOSDownloadFileInput new];
    input.tosBucket = self.tos_bucket;
    input.tosKey = key;
    input.tosFilePath = filePath;
    input.tosTempFilePath = [filePath stringByAppendingString:@".temp"];
    input.tosPartSize = partSize;
    input.tosTaskNum = taskNum;
    input.tosEnableCheckpoint = YES;
    input.tosCheckpointFile = checkpointPath;
    input.tosDownloadEventListener = listener;
    input.tosCancelHook = cancelHook ?: [TOSCancelHook new];
    [self.tos_localPaths addObject:input.tosTempFilePath];
    TOSTask<TOSDownloadFileOutput *> *task = (TOSTask<TOSDownloadFileOutput *> *)[self.tos_client downloadFile:input];
    [self tos_registerTask:task cancelHook:input.tosCancelHook];
    return task;
}

- (TOSTask<TOSResumableCopyObjectOutput *> *)tos_copyObject:(TOSResumableCopyObjectInput *)input {
    TOSCopyEventListener listener = input.tosCopyEventListener;
    NSString *key = input.tosKey;
    __weak typeof(self) weakSelf = self;
    input.tosCopyEventListener = ^(TOSCopyEvent *event) {
        [weakSelf tos_trackUploadID:event.tosUploadID key:key];
        if (listener) {
            listener(event);
        }
    };
    input.tosCancelHook = input.tosCancelHook ?: [TOSCancelHook new];
    TOSTask<TOSResumableCopyObjectOutput *> *task =
        (TOSTask<TOSResumableCopyObjectOutput *> *)[self.tos_client resumableCopyObject:input];
    [self tos_registerTask:task cancelHook:input.tosCancelHook];
    return task;
}

- (void)tos_requireLargeTransferConfiguration {
    [self tos_requireLiveConfiguration];
    NSString *value = [TOSTestEnvironmentValue(@"TOS_RUN_LARGE_TRANSFER_TESTS") lowercaseString];
    if (![@[@"1", @"true", @"yes"] containsObject:value ?: @""]) {
        XCTSkip(@"请设置 TOS_RUN_LARGE_TRANSFER_TESTS=1 后运行 1 GiB/5 GiB 在线测试");
    }
}

- (void)tos_requireFreeSpaceForFileSize:(int64_t)fileSize {
    NSError *error = nil;
    NSDictionary<NSFileAttributeKey, id> *attributes =
        [[NSFileManager defaultManager] attributesOfFileSystemForPath:self.tos_root error:&error];
    XCTAssertNil(error);
    NSNumber *freeSize = attributes[NSFileSystemFreeSize];
    XCTAssertNotNil(freeSize);
    uint64_t required = (uint64_t)fileSize + UINT64_C(1024) * 1024 * 1024;
    if (freeSize.unsignedLongLongValue < required) {
        XCTSkip(@"大文件在线测试至少需要 %.1f GiB 可用空间，当前只有 %.1f GiB",
                (double)required / (1024.0 * 1024.0 * 1024.0),
                (double)freeSize.unsignedLongLongValue / (1024.0 * 1024.0 * 1024.0));
    }
}

- (BOOL)tos_removeLocalFileAtPath:(NSString *)path context:(NSString *)context {
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return YES;
    }
    NSError *error = nil;
    BOOL removed = [[NSFileManager defaultManager] removeItemAtPath:path error:&error];
    XCTAssertTrue(removed, @"Failed to remove %@: %@", context, error);
    return removed;
}

- (BOOL)tos_assertObject:(NSString *)key
                 hasSize:(int64_t)size
                 context:(NSString *)context {
    TOSHeadObjectInput *input = [TOSHeadObjectInput new];
    input.tosBucket = self.tos_bucket;
    input.tosKey = key;
    TOSTask<TOSHeadObjectOutput *> *task =
        (TOSTask<TOSHeadObjectOutput *> *)[self.tos_client headObject:input];
    if (![self tos_waitForTask:task description:context timeout:TOSLiveLargeTaskTimeout] ||
        ![self tos_assertTaskSucceeded:task context:context]) {
        return NO;
    }
    XCTAssertEqual(task.result.tosContentLength, size);
    return task.result.tosContentLength == size;
}

- (BOOL)tos_runLargePauseResumeScenarioWithSize:(int64_t)size name:(NSString *)name {
    [self tos_requireFreeSpaceForFileSize:size];
    NSString *sourceSHA256 = nil;
    NSString *sourcePath = [self tos_createFileNamed:[name stringByAppendingString:@".source"]
                                               size:size
                                             sha256:&sourceSHA256];
    if (sourceSHA256.length == 0) {
        return NO;
    }

    NSString *sourceKey = [self tos_keyWithName:[name stringByAppendingString:@"-source"]];
    NSString *uploadCheckpoint =
        [self tos_localPathWithName:[name stringByAppendingString:@".upload.v2"]];
    TOSCancelHook *uploadCancel = [TOSCancelHook new];
    __block BOOL uploadCancelled = NO;
    __weak typeof(self) weakSelf = self;
    TOSUploadEventListener uploadListener = ^(TOSUploadEvent *event) {
        [weakSelf tos_trackUploadID:event.tosUploadID key:sourceKey];
        if (!uploadCancelled && event.tosType == TOSUploadEventUploadPartSucceed) {
            uploadCancelled = YES;
            [uploadCancel cancel:NO];
        }
    };
    TOSTask *pausedUpload = [self tos_uploadFile:sourcePath
                                             key:sourceKey
                                         taskNum:1
                                        partSize:TOSLiveLargePartSize
                                  checkpointPath:uploadCheckpoint
                                        listener:uploadListener
                                      cancelHook:uploadCancel];
    if (![self tos_waitForTask:pausedUpload
                   description:[name stringByAppendingString:@" paused upload"]
                       timeout:TOSLiveLargeTaskTimeout]) {
        return NO;
    }
    XCTAssertNotNil(pausedUpload.error);
    XCTAssertTrue(uploadCancelled, @"%@ upload did not reach the pause point: %@",
                  name, pausedUpload.error);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:uploadCheckpoint]);
    if (!pausedUpload.error || !uploadCancelled ||
        ![[NSFileManager defaultManager] fileExistsAtPath:uploadCheckpoint]) {
        return NO;
    }

    TOSTask<TOSUploadFileOutputV2 *> *resumedUpload =
        [self tos_uploadFile:sourcePath
                         key:sourceKey
                     taskNum:6
                    partSize:TOSLiveLargePartSize
              checkpointPath:uploadCheckpoint
                    listener:nil
                  cancelHook:nil];
    if (![self tos_waitForTask:resumedUpload
                   description:[name stringByAppendingString:@" resumed upload"]
                       timeout:TOSLiveLargeTaskTimeout] ||
        ![self tos_assertTaskSucceeded:resumedUpload
                               context:[name stringByAppendingString:@" resumed upload"]]) {
        return NO;
    }
    [self tos_trackUploadID:resumedUpload.result.tosUploadID key:sourceKey];
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:uploadCheckpoint]);
    if ([[NSFileManager defaultManager] fileExistsAtPath:uploadCheckpoint] ||
        ![self tos_assertObject:sourceKey
                       hasSize:size
                       context:[name stringByAppendingString:@" source head"]]) {
        return NO;
    }
    if (![self tos_removeLocalFileAtPath:sourcePath context:[name stringByAppendingString:@" source"]]) {
        return NO;
    }

    NSString *downloadPath = [self tos_localPathWithName:[name stringByAppendingString:@".download"]];
    XCTAssertTrue([[@"sentinel" dataUsingEncoding:NSUTF8StringEncoding]
                   writeToFile:downloadPath
                   atomically:YES]);
    NSString *downloadCheckpoint =
        [self tos_localPathWithName:[name stringByAppendingString:@".download.checkpoint"]];
    TOSCancelHook *downloadCancel = [TOSCancelHook new];
    __block BOOL downloadCancelled = NO;
    TOSDownloadEventListener downloadListener = ^(TOSDownloadEvent *event) {
        if (!downloadCancelled && event.tosType == TOSDownloadEventDownloadPartSucceed) {
            downloadCancelled = YES;
            [downloadCancel cancel:NO];
        }
    };
    TOSTask *pausedDownload = [self tos_downloadKey:sourceKey
                                             toPath:downloadPath
                                            taskNum:1
                                           partSize:TOSLiveLargePartSize
                                     checkpointPath:downloadCheckpoint
                                           listener:downloadListener
                                         cancelHook:downloadCancel];
    if (![self tos_waitForTask:pausedDownload
                   description:[name stringByAppendingString:@" paused download"]
                       timeout:TOSLiveLargeTaskTimeout]) {
        return NO;
    }
    XCTAssertNotNil(pausedDownload.error);
    XCTAssertTrue(downloadCancelled);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:downloadPath],
                          [@"sentinel" dataUsingEncoding:NSUTF8StringEncoding]);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:downloadCheckpoint]);
    if (!pausedDownload.error || !downloadCancelled ||
        ![[NSFileManager defaultManager] fileExistsAtPath:downloadCheckpoint]) {
        return NO;
    }

    TOSTask *resumedDownload = [self tos_downloadKey:sourceKey
                                               toPath:downloadPath
                                              taskNum:6
                                             partSize:TOSLiveLargePartSize
                                       checkpointPath:downloadCheckpoint
                                             listener:nil
                                           cancelHook:nil];
    if (![self tos_waitForTask:resumedDownload
                   description:[name stringByAppendingString:@" resumed download"]
                       timeout:TOSLiveLargeTaskTimeout] ||
        ![self tos_assertTaskSucceeded:resumedDownload
                               context:[name stringByAppendingString:@" resumed download"]]) {
        return NO;
    }
    NSString *downloadedSHA256 = [self tos_SHA256ForFile:downloadPath];
    XCTAssertEqualObjects(downloadedSHA256, sourceSHA256);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:downloadCheckpoint]);
    if (![downloadedSHA256 isEqualToString:sourceSHA256] ||
        [[NSFileManager defaultManager] fileExistsAtPath:downloadCheckpoint] ||
        ![self tos_removeLocalFileAtPath:downloadPath
                                 context:[name stringByAppendingString:@" downloaded source"]]) {
        return NO;
    }

    NSString *destinationKey =
        [self tos_keyWithName:[name stringByAppendingString:@"-copy-destination"]];
    NSString *copyCheckpoint =
        [self tos_localPathWithName:[name stringByAppendingString:@".copy.checkpoint"]];
    TOSCancelHook *copyCancel = [TOSCancelHook new];
    __block BOOL copyCancelled = NO;
    TOSCopyEventListener copyListener = ^(TOSCopyEvent *event) {
        [weakSelf tos_trackUploadID:event.tosUploadID key:destinationKey];
        if (!copyCancelled && event.tosType == TOSCopyEventUploadPartCopySucceed) {
            copyCancelled = YES;
            [copyCancel cancel:NO];
        }
    };
    TOSResumableCopyObjectInput *(^copyInput)(TOSCancelHook *, int) =
        ^TOSResumableCopyObjectInput *(TOSCancelHook *cancelHook, int taskNum) {
        TOSResumableCopyObjectInput *input = [TOSResumableCopyObjectInput new];
        input.tosBucket = weakSelf.tos_bucket;
        input.tosKey = destinationKey;
        input.tosSrcBucket = weakSelf.tos_bucket;
        input.tosSrcKey = sourceKey;
        input.tosPartSize = TOSLiveLargePartSize;
        input.tosTaskNum = taskNum;
        input.tosEnableCheckpoint = YES;
        input.tosCheckpointFile = copyCheckpoint;
        input.tosCopyEventListener = copyListener;
        input.tosCancelHook = cancelHook;
        return input;
    };
    TOSTask *pausedCopy = [self tos_copyObject:copyInput(copyCancel, 1)];
    if (![self tos_waitForTask:pausedCopy
                   description:[name stringByAppendingString:@" paused copy"]
                       timeout:TOSLiveLargeTaskTimeout]) {
        return NO;
    }
    XCTAssertNotNil(pausedCopy.error);
    XCTAssertTrue(copyCancelled);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:copyCheckpoint]);
    if (!pausedCopy.error || !copyCancelled ||
        ![[NSFileManager defaultManager] fileExistsAtPath:copyCheckpoint]) {
        return NO;
    }

    TOSTask<TOSResumableCopyObjectOutput *> *resumedCopy =
        [self tos_copyObject:copyInput(nil, 6)];
    if (![self tos_waitForTask:resumedCopy
                   description:[name stringByAppendingString:@" resumed copy"]
                       timeout:TOSLiveLargeTaskTimeout] ||
        ![self tos_assertTaskSucceeded:resumedCopy
                               context:[name stringByAppendingString:@" resumed copy"]]) {
        return NO;
    }
    [self tos_trackUploadID:resumedCopy.result.tosUploadID key:destinationKey];
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:copyCheckpoint]);
    if ([[NSFileManager defaultManager] fileExistsAtPath:copyCheckpoint] ||
        ![self tos_assertObject:destinationKey
                       hasSize:size
                       context:[name stringByAppendingString:@" copied object head"]]) {
        return NO;
    }

    NSString *copiedDownloadCheckpoint =
        [self tos_localPathWithName:[name stringByAppendingString:@".copy.download.checkpoint"]];
    TOSTask *copiedDownload = [self tos_downloadKey:destinationKey
                                             toPath:downloadPath
                                            taskNum:6
                                           partSize:TOSLiveLargePartSize
                                     checkpointPath:copiedDownloadCheckpoint
                                           listener:nil
                                         cancelHook:nil];
    if (![self tos_waitForTask:copiedDownload
                   description:[name stringByAppendingString:@" copied object download"]
                       timeout:TOSLiveLargeTaskTimeout] ||
        ![self tos_assertTaskSucceeded:copiedDownload
                               context:[name stringByAppendingString:@" copied object download"]]) {
        return NO;
    }
    NSString *copiedSHA256 = [self tos_SHA256ForFile:downloadPath];
    XCTAssertEqualObjects(copiedSHA256, sourceSHA256);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:copiedDownloadCheckpoint]);
    return [copiedSHA256 isEqualToString:sourceSHA256] &&
        ![[NSFileManager defaultManager] fileExistsAtPath:copiedDownloadCheckpoint];
}

- (void)testLiveUploadSizesAndDownloadConcurrency {
    [self tos_requireLiveConfiguration];
    NSArray<NSNumber *> *sizes = @[@0, @1024, @(6 * 1024 * 1024), @(31 * 1024 * 1024)];
    for (NSNumber *size in sizes) {
        NSString *name = [NSString stringWithFormat:@"size-%lld", size.longLongValue];
        NSString *sourcePath = [self tos_createFileNamed:[name stringByAppendingString:@".source"]
                                                    size:size.longLongValue];
        NSString *key = [self tos_keyWithName:name];
        NSString *checkpointPath = [self tos_localPathWithName:[name stringByAppendingString:@".upload.v2"]];
        int uploadTaskNum = size.longLongValue == 31 * 1024 * 1024 ? 6 : 1;
        TOSTask<TOSUploadFileOutputV2 *> *upload = [self tos_uploadFile:sourcePath
                                                                    key:key
                                                                taskNum:uploadTaskNum
                                                         checkpointPath:checkpointPath
                                                               listener:nil
                                                             cancelHook:nil];
        if (![self tos_waitForTask:upload description:[name stringByAppendingString:@" upload"]]) {
            return;
        }
        if (![self tos_assertTaskSucceeded:upload context:name]) {
            return;
        }
        [self tos_trackUploadID:upload.result.tosUploadID key:key];
        XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:checkpointPath]);

        TOSHeadObjectInput *headInput = [TOSHeadObjectInput new];
        headInput.tosBucket = self.tos_bucket;
        headInput.tosKey = key;
        TOSTask<TOSHeadObjectOutput *> *head = (TOSTask<TOSHeadObjectOutput *> *)[self.tos_client headObject:headInput];
        if (![self tos_waitForTask:head description:[name stringByAppendingString:@" head"]]) {
            return;
        }
        if (![self tos_assertTaskSucceeded:head context:[name stringByAppendingString:@" head"]]) {
            return;
        }
        XCTAssertEqual(head.result.tosContentLength, size.longLongValue);

        NSArray<NSNumber *> *taskNums = size.longLongValue == 31 * 1024 * 1024 ? @[@1, @5, @6] : @[@1];
        for (NSNumber *taskNum in taskNums) {
            NSString *downloadName = [NSString stringWithFormat:@"%@-download-%@", name, taskNum];
            NSString *downloadPath = [self tos_localPathWithName:downloadName];
            NSString *downloadCheckpoint = [self tos_localPathWithName:[downloadName stringByAppendingString:@".checkpoint"]];
            TOSTask *download = [self tos_downloadKey:key
                                               toPath:downloadPath
                                               taskNum:taskNum.intValue
                                        checkpointPath:downloadCheckpoint
                                               listener:nil
                                             cancelHook:nil];
            if (![self tos_waitForTask:download description:downloadName]) {
                return;
            }
            if (![self tos_assertTaskSucceeded:download context:downloadName]) {
                return;
            }
            XCTAssertEqualObjects([self tos_SHA256ForFile:sourcePath], [self tos_SHA256ForFile:downloadPath]);
            XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:downloadCheckpoint]);
        }
    }
}

- (void)testLiveUploadAndDownloadPauseResume {
    [self tos_requireLiveConfiguration];
    NSString *sourcePath = [self tos_createFileNamed:@"pause-resume.source" size:21 * 1024 * 1024];
    NSString *key = [self tos_keyWithName:@"pause-resume"];
    NSString *uploadCheckpoint = [self tos_localPathWithName:@"pause-resume.upload.v2"];
    TOSCancelHook *uploadCancel = [TOSCancelHook new];
    __block BOOL uploadCancelled = NO;
    __weak typeof(self) weakSelf = self;
    TOSUploadEventListener uploadListener = ^(TOSUploadEvent *event) {
        [weakSelf tos_trackUploadID:event.tosUploadID key:key];
        if (!uploadCancelled && event.tosType == TOSUploadEventUploadPartSucceed) {
            uploadCancelled = YES;
            [uploadCancel cancel:NO];
        }
    };
    TOSTask *pausedUpload = [self tos_uploadFile:sourcePath
                                             key:key
                                         taskNum:1
                                  checkpointPath:uploadCheckpoint
                                        listener:uploadListener
                                      cancelHook:uploadCancel];
    if (![self tos_waitForTask:pausedUpload description:@"paused upload"]) {
        return;
    }
    XCTAssertNotNil(pausedUpload.error);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:uploadCheckpoint]);

    TOSTask<TOSUploadFileOutputV2 *> *resumedUpload = [self tos_uploadFile:sourcePath
                                                                       key:key
                                                                   taskNum:1
                                                            checkpointPath:uploadCheckpoint
                                                                  listener:uploadListener
                                                                cancelHook:nil];
    if (![self tos_waitForTask:resumedUpload description:@"resumed upload"]) {
        return;
    }
    if (![self tos_assertTaskSucceeded:resumedUpload context:@"resumed upload"]) {
        return;
    }
    [self tos_trackUploadID:resumedUpload.result.tosUploadID key:key];
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:uploadCheckpoint]);

    NSString *destinationPath = [self tos_localPathWithName:@"pause-resume.download"];
    XCTAssertTrue([[@"sentinel" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:destinationPath atomically:YES]);
    NSString *downloadCheckpoint = [self tos_localPathWithName:@"pause-resume.download.checkpoint"];
    TOSCancelHook *downloadCancel = [TOSCancelHook new];
    __block BOOL downloadCancelled = NO;
    TOSDownloadEventListener downloadListener = ^(TOSDownloadEvent *event) {
        if (!downloadCancelled && event.tosType == TOSDownloadEventDownloadPartSucceed) {
            downloadCancelled = YES;
            [downloadCancel cancel:NO];
        }
    };
    TOSTask *pausedDownload = [self tos_downloadKey:key
                                             toPath:destinationPath
                                             taskNum:1
                                      checkpointPath:downloadCheckpoint
                                             listener:downloadListener
                                           cancelHook:downloadCancel];
    if (![self tos_waitForTask:pausedDownload description:@"paused download"]) {
        return;
    }
    XCTAssertNotNil(pausedDownload.error);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:destinationPath],
                          [@"sentinel" dataUsingEncoding:NSUTF8StringEncoding]);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:downloadCheckpoint]);

    TOSTask *resumedDownload = [self tos_downloadKey:key
                                              toPath:destinationPath
                                              taskNum:5
                                       checkpointPath:downloadCheckpoint
                                              listener:nil
                                            cancelHook:nil];
    if (![self tos_waitForTask:resumedDownload description:@"resumed download"]) {
        return;
    }
    if (![self tos_assertTaskSucceeded:resumedDownload context:@"resumed download"]) {
        return;
    }
    XCTAssertEqualObjects([self tos_SHA256ForFile:sourcePath], [self tos_SHA256ForFile:destinationPath]);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:downloadCheckpoint]);
}

- (void)testLiveResumableCopyPauseResume {
    [self tos_requireLiveConfiguration];
    NSString *sourcePath = [self tos_createFileNamed:@"copy.source" size:31 * 1024 * 1024];
    NSString *sourceKey = [self tos_keyWithName:@"copy-source"];
    NSString *sourceCheckpoint = [self tos_localPathWithName:@"copy-source.upload.v2"];
    TOSTask<TOSUploadFileOutputV2 *> *sourceUpload = [self tos_uploadFile:sourcePath
                                                                      key:sourceKey
                                                                  taskNum:6
                                                           checkpointPath:sourceCheckpoint
                                                                 listener:nil
                                                               cancelHook:nil];
    if (![self tos_waitForTask:sourceUpload description:@"copy source upload"]) {
        return;
    }
    if (![self tos_assertTaskSucceeded:sourceUpload context:@"copy source upload"]) {
        return;
    }
    [self tos_trackUploadID:sourceUpload.result.tosUploadID key:sourceKey];

    NSString *destinationKey = [self tos_keyWithName:@"copy-destination"];
    NSString *copyCheckpoint = [self tos_localPathWithName:@"copy.checkpoint"];
    TOSCancelHook *copyCancel = [TOSCancelHook new];
    __block BOOL copyCancelled = NO;
    __weak typeof(self) weakSelf = self;
    TOSCopyEventListener listener = ^(TOSCopyEvent *event) {
        [weakSelf tos_trackUploadID:event.tosUploadID key:destinationKey];
        if (!copyCancelled && event.tosType == TOSCopyEventUploadPartCopySucceed) {
            copyCancelled = YES;
            [copyCancel cancel:NO];
        }
    };
    TOSResumableCopyObjectInput *(^copyInput)(TOSCancelHook *, TOSCopyEventListener) =
        ^TOSResumableCopyObjectInput *(TOSCancelHook *cancelHook, TOSCopyEventListener eventListener) {
        TOSResumableCopyObjectInput *input = [TOSResumableCopyObjectInput new];
        input.tosBucket = weakSelf.tos_bucket;
        input.tosKey = destinationKey;
        input.tosSrcBucket = weakSelf.tos_bucket;
        input.tosSrcKey = sourceKey;
        input.tosPartSize = TOSMinPartSize;
        input.tosTaskNum = cancelHook ? 1 : 6;
        input.tosEnableCheckpoint = YES;
        input.tosCheckpointFile = copyCheckpoint;
        input.tosCopyEventListener = eventListener;
        input.tosCancelHook = cancelHook;
        return input;
    };

    TOSTask *pausedCopy = [self tos_copyObject:copyInput(copyCancel, listener)];
    if (![self tos_waitForTask:pausedCopy description:@"paused copy"]) {
        return;
    }
    XCTAssertNotNil(pausedCopy.error);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:copyCheckpoint]);

    TOSTask<TOSResumableCopyObjectOutput *> *resumedCopy =
        [self tos_copyObject:copyInput(nil, listener)];
    if (![self tos_waitForTask:resumedCopy description:@"resumed copy"]) {
        return;
    }
    if (![self tos_assertTaskSucceeded:resumedCopy context:@"resumed copy"]) {
        return;
    }
    [self tos_trackUploadID:resumedCopy.result.tosUploadID key:destinationKey];
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:copyCheckpoint]);

    NSString *downloadPath = [self tos_localPathWithName:@"copy.download"];
    NSString *downloadCheckpoint = [self tos_localPathWithName:@"copy.download.checkpoint"];
    TOSTask *download = [self tos_downloadKey:destinationKey
                                       toPath:downloadPath
                                       taskNum:5
                                checkpointPath:downloadCheckpoint
                                       listener:nil
                                     cancelHook:nil];
    if (![self tos_waitForTask:download description:@"copied object download"]) {
        return;
    }
    if (![self tos_assertTaskSucceeded:download context:@"copied object download"]) {
        return;
    }
    XCTAssertEqualObjects([self tos_SHA256ForFile:sourcePath], [self tos_SHA256ForFile:downloadPath]);
}

- (void)testLiveLargeOneGiBPauseResumeAndIntegrity {
    [self tos_requireLargeTransferConfiguration];
    XCTAssertTrue([self tos_runLargePauseResumeScenarioWithSize:1LL * 1024 * 1024 * 1024
                                                          name:@"large-1gib"]);
}

- (void)testLiveLargeFiveGiBPauseResumeAndIntegrity {
    [self tos_requireLargeTransferConfiguration];
    XCTAssertTrue([self tos_runLargePauseResumeScenarioWithSize:5LL * 1024 * 1024 * 1024
                                                          name:@"large-5gib"]);
}

@end
