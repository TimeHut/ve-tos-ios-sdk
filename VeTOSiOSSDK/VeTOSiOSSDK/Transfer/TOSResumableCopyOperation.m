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

#import "TOSResumableCopyOperation.h"
#import "TOSInput+TransferInternal.h"
#import "TOSTransferCheckpoint.h"
#import "TOSTransferOperation.h"
#import <VeTOSiOSSDK/TOSClient.h>
#import <VeTOSiOSSDK/TOSUtil.h>
#include <math.h>

@interface TOSClient (TransferConcurrencyInternal)
- (TOSTransferConcurrencyController *)tos_resumableTransferConcurrencyController;
@end

static NSError *TOSCopyError(NSString *message) {
    return [NSError errorWithDomain:TOSClientErrorDomain
                               code:400
                           userInfo:@{TOSErrorMessageTOKEN: message ?: @"断点续传拷贝失败"}];
}

static NSInteger TOSCopyStatusCode(NSError *error) {
    return [error.domain isEqualToString:TOSServerErrorDomain] ? error.code : 0;
}

static BOOL TOSCopyIsNoSuchUpload(NSError *error) {
    if (![error.domain isEqualToString:TOSServerErrorDomain]) {
        return NO;
    }
    NSString *errorCode = [error.userInfo[@"Code"] description];
    NSString *message = [error.userInfo[TOSErrorMessageTOKEN] description];
    return [errorCode isEqualToString:@"NoSuchUpload"] ||
           (message.length > 0 &&
            [message rangeOfString:@"NoSuchUpload" options:NSCaseInsensitiveSearch].location != NSNotFound);
}

static BOOL TOSCopyIsAbortStatus(NSError *error) {
    NSInteger statusCode = TOSCopyStatusCode(error);
    return statusCode == 403 || statusCode == 404 || statusCode == 405 || statusCode == 412;
}

static int64_t TOSCopyDateValue(NSDate *date) {
    if (!date) {
        return 0;
    }
    double value = date.timeIntervalSince1970 * (double)NSEC_PER_SEC;
    if (!isfinite(value) || value >= (double)INT64_MAX) {
        return INT64_MAX;
    }
    if (value <= (double)INT64_MIN) {
        return INT64_MIN;
    }
    return (int64_t)value;
}

@class TOSResumableCopyOperation;

@interface TOSCopyPartOperation : TOSTransferOperation
@property (nonatomic, weak) TOSResumableCopyOperation *tos_owner;
@end

@interface TOSResumableCopyOperation ()
@property (nonatomic, strong) TOSClient *tos_client;
@property (nonatomic, strong) TOSTaskCompletionSource<TOSResumableCopyObjectOutput *> *tos_taskSource;
@property (nonatomic, strong, readwrite) TOSTask<TOSResumableCopyObjectOutput *> *task;
@property (nonatomic, strong, readwrite) TOSResumableCopyObjectInput *request;
@property (nonatomic, strong) TOSResumableCopyOperation *tos_lifetimeAnchor;
@property (nonatomic, strong) dispatch_queue_t tos_stateQueue;
@property (nonatomic, strong) TOSTransferCheckpointStore *tos_checkpointStore;
@property (nonatomic, strong) TOSTransferCheckpointLease *tos_checkpointLease;
@property (nonatomic, strong) TOSCopyCheckpoint *tos_checkpoint;
@property (nonatomic, strong) TOSCopyCheckpoint *tos_staleCheckpoint;
@property (nonatomic, strong) TOSCopyPartOperation *tos_partOperation;
@property (nonatomic, strong) TOSHeadObjectOutput *tos_headOutput;
@property (nonatomic, copy) NSString *tos_effectiveIfMatch;
@property (nonatomic, assign) int64_t tos_sourceSize;
@property (nonatomic, assign) BOOL tos_started;
@property (nonatomic, assign) BOOL tos_finished;
@property (nonatomic, assign) BOOL tos_cleanupInFlight;
@property (nonatomic, assign) BOOL tos_remoteRequestInFlight;
@property (nonatomic, assign) BOOL tos_partsStarted;
@property (nonatomic, assign) BOOL tos_checkpointLoaded;
- (NSArray<TOSTransferPart *> *)tos_pendingParts;
- (TOSTask<TOSTransferAttemptResult *> *)tos_attemptPart:(TOSTransferPart *)part
                                              retryCount:(NSInteger)retryCount
                                     networkCancellation:(TOSTransferNetworkCancellation *)networkCancellation;
- (void)tos_attemptCreateMultipartWithRetryCount:(NSInteger)retryCount;
- (BOOL)tos_removeCheckpoint:(TOSCopyCheckpoint *)checkpoint
                       error:(NSError **)error;
@end

@implementation TOSCopyPartOperation

- (NSArray *)tos_pendingItems {
    return [self.tos_owner tos_pendingParts];
}

- (TOSTask<TOSTransferAttemptResult *> *)tos_attemptItem:(id)item
                                              retryCount:(NSInteger)retryCount
                                     networkCancellation:(TOSTransferNetworkCancellation *)networkCancellation {
    return [self.tos_owner tos_attemptPart:item
                                retryCount:retryCount
                       networkCancellation:networkCancellation];
}

@end

@implementation TOSResumableCopyOperation

- (instancetype)initWithClient:(TOSClient *)client request:(TOSResumableCopyObjectInput *)request {
    self = [super init];
    if (self) {
        _tos_client = client;
        _request = [self tos_snapshotRequest:request];
        _tos_taskSource = [TOSTaskCompletionSource taskCompletionSource];
        _task = _tos_taskSource.task;
        _tos_stateQueue = dispatch_queue_create("com.volces.tos.transfer.copy", DISPATCH_QUEUE_SERIAL);
        _tos_checkpointStore = [[TOSTransferCheckpointStore alloc] init];
    }
    return self;
}

- (TOSResumableCopyObjectInput *)tos_snapshotRequest:(TOSResumableCopyObjectInput *)request {
    TOSResumableCopyObjectInput *snapshot = [TOSResumableCopyObjectInput new];
    snapshot.isCancelled = request.isCancelled;
    snapshot.tosBucket = request.tosBucket;
    snapshot.tosKey = request.tosKey;
    snapshot.tosEncodingType = request.tosEncodingType;
    snapshot.tosCacheControl = request.tosCacheControl;
    snapshot.tosContentDisposition = request.tosContentDisposition;
    snapshot.tosContentEncoding = request.tosContentEncoding;
    snapshot.tosContentLanguage = request.tosContentLanguage;
    snapshot.tosContentType = request.tosContentType;
    snapshot.tosExpires = [request.tosExpires copy];
    snapshot.tosACL = request.tosACL;
    snapshot.tosGrantFullControl = request.tosGrantFullControl;
    snapshot.tosGrantRead = request.tosGrantRead;
    snapshot.tosGrantReadAcp = request.tosGrantReadAcp;
    snapshot.tosGrantWriteAcp = request.tosGrantWriteAcp;
    snapshot.tosSSECAlgorithm = request.tosSSECAlgorithm;
    snapshot.tosSSECKey = request.tosSSECKey;
    snapshot.tosSSECKeyMD5 = request.tosSSECKeyMD5;
    snapshot.tosServerSideEncryption = request.tosServerSideEncryption;
    snapshot.tosMeta = [request.tosMeta copy];
    snapshot.tosWebsiteRedirectLocation = request.tosWebsiteRedirectLocation;
    snapshot.tosStorageClass = request.tosStorageClass;
    snapshot.tosSrcBucket = request.tosSrcBucket;
    snapshot.tosSrcKey = request.tosSrcKey;
    snapshot.tosSrcVersionID = request.tosSrcVersionID;
    snapshot.tosCopySourceIfMatch = request.tosCopySourceIfMatch;
    snapshot.tosCopySourceIfModifiedSince = [request.tosCopySourceIfModifiedSince copy];
    snapshot.tosCopySourceIfNoneMatch = request.tosCopySourceIfNoneMatch;
    snapshot.tosCopySourceIfUnmodifiedSince = [request.tosCopySourceIfUnmodifiedSince copy];
    snapshot.tosPartSize = request.tosPartSize;
    snapshot.tosTaskNum = request.tosTaskNum;
    snapshot.tosEnableCheckpoint = request.tosEnableCheckpoint;
    snapshot.tosCheckpointFile = request.tosCheckpointFile;
    snapshot.tosTrafficLimit = request.tosTrafficLimit;
    snapshot.tosMaxRetryCount = request.tosMaxRetryCount;
    snapshot.tosCopyEventListener = request.tosCopyEventListener;
    snapshot.tosCancelHook = request.tosCancelHook;
    return snapshot;
}

- (void)start {
    @synchronized (self) {
        if (self.tos_started) {
            return;
        }
        self.tos_started = YES;
        self.tos_lifetimeAnchor = self;
    }
    dispatch_async(self.tos_stateQueue, ^{
        NSError *error = [self tos_validateRequest];
        if (error) {
            [self tos_finishWithOutput:nil error:error];
            return;
        }

        TOSTransferProgress *progress = [[TOSTransferProgress alloc] initWithListener:nil];
        self.tos_partOperation = [[TOSCopyPartOperation alloc]
                                  initWithTaskNum:self.request.tosTaskNum
                                  maxRetryCount:self.request.tosMaxRetryCount
                                  cancelHook:self.request.tosCancelHook
                                  progress:progress
                                  concurrencyController:
                                      [self.tos_client tos_resumableTransferConcurrencyController]];
        self.tos_partOperation.tos_owner = self;
        __weak typeof(self) weakSelf = self;
        [self.tos_partOperation.task continueWithBlock:^id(TOSTask *task) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) {
                return nil;
            }
            dispatch_async(strongSelf.tos_stateQueue, ^{
                if (strongSelf.request.tosCancelHook.tos_isCancelled &&
                    !strongSelf.tos_remoteRequestInFlight &&
                    !strongSelf.tos_partsStarted) {
                    [strongSelf tos_handleCancellation];
                }
            });
            return nil;
        }];
        if (self.request.tosCancelHook.tos_isCancelled) {
            [self tos_handleCancellation];
            return;
        }
        [self tos_attemptHeadWithRetryCount:0];
    });
}

- (NSError *)tos_validateRequest {
    NSError *error = nil;
    BOOL customDomain = self.tos_client.clientConfiguration.tosEndpoint.isCustomDomain;
    if (!customDomain && ![TOSUtil isValidBucketName:self.request.tosSrcBucket withError:&error]) {
        return error;
    }
    if (![TOSUtil isValidObjectName:self.request.tosSrcKey withError:&error]) {
        return error;
    }
    if (!customDomain && ![TOSUtil isValidBucketName:self.request.tosBucket withError:&error]) {
        return error;
    }
    if (![TOSUtil isValidObjectName:self.request.tosKey withError:&error]) {
        return error;
    }
    if (self.request.tosPartSize == 0) {
        self.request.tosPartSize = TOSDefaultPartSize;
    }
    if (self.request.tosPartSize < TOSMinPartSize || self.request.tosPartSize > TOSMaxPartSize) {
        return TOSCopyError(@"tos: invalid part size, the size must be [5242880, 5368709120]");
    }
    self.request.tosTaskNum = (int)TOSNormalizeResumableTransferTaskNum(self.request.tosTaskNum);
    if (self.request.tosMaxRetryCount < 0) {
        return TOSCopyError(@"tos: max retry count must not be negative");
    }
    if (self.request.tosTrafficLimit < 0) {
        return TOSCopyError(@"tos: traffic limit must not be negative");
    }
    if (self.request.tosSSECAlgorithm.length > 0 ||
        self.request.tosSSECKey.length > 0 ||
        self.request.tosSSECKeyMD5.length > 0 ||
        self.request.tosServerSideEncryption.length > 0) {
        return TOSCopyError(@"断点续传拷贝不支持 SSE 相关参数");
    }
    if (self.request.tosEnableCheckpoint) {
        NSString *path = TOSCopyCheckpointPath(self.request.tosCheckpointFile,
                                               self.request.tosSrcBucket,
                                               self.request.tosSrcKey,
                                               self.request.tosSrcVersionID,
                                               self.request.tosBucket,
                                               self.request.tosKey,
                                               &error);
        if (!path) {
            return error ?: TOSCopyError(@"tos: invalid copy checkpoint path");
        }
        self.request.tosCheckpointFile = path;
        self.tos_checkpointLease =
            [TOSTransferCheckpointLease acquireCheckpointPath:path error:&error];
        if (!self.tos_checkpointLease) {
            return error ?: TOSCopyError(@"tos: checkpoint is already in use");
        }
    } else {
        self.request.tosCheckpointFile = @"";
    }
    return nil;
}

- (TOSHeadObjectInput *)tos_headInput {
    TOSHeadObjectInput *input = [TOSHeadObjectInput new];
    input.tosBucket = self.request.tosSrcBucket;
    input.tosKey = self.request.tosSrcKey;
    input.tosVersionID = self.request.tosSrcVersionID;
    input.tosIfMatch = self.request.tosCopySourceIfMatch;
    input.tosIfModifiedSince = self.request.tosCopySourceIfModifiedSince;
    input.tosIfNoneMatch = self.request.tosCopySourceIfNoneMatch;
    input.tosIfUnmodifiedSince = self.request.tosCopySourceIfUnmodifiedSince;
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    if (self.request.tosCopySourceIfMatch.length > 0) {
        headers[@"If-Match"] = self.request.tosCopySourceIfMatch;
    }
    if (self.request.tosCopySourceIfNoneMatch.length > 0) {
        headers[@"If-None-Match"] = self.request.tosCopySourceIfNoneMatch;
    }
    input.tos_transferHeaders = headers.count > 0 ? headers : nil;
    input.tos_transferCancellation = self.tos_partOperation.networkCancellation;
    return input;
}

- (void)tos_attemptHeadWithRetryCount:(NSInteger)retryCount {
    if (self.tos_finished) {
        return;
    }
    if (self.request.tosCancelHook.tos_isCancelled) {
        [self tos_handleCancellation];
        return;
    }
    self.tos_remoteRequestInFlight = YES;
    __weak typeof(self) weakSelf = self;
    TOSHeadObjectInput *headInput = [self tos_headInput];
    TOSTransferResponseMetadata *responseMetadata = [TOSTransferResponseMetadata new];
    headInput.tos_responseObserver = TOSTransferRetryAfterObserver(responseMetadata);
    [[self.tos_client headObject:headInput] continueWithBlock:^id(TOSTask *task) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return nil;
        }
        dispatch_async(strongSelf.tos_stateQueue, ^{
            strongSelf.tos_remoteRequestInFlight = NO;
            if (strongSelf.tos_finished) {
                return;
            }
            if (task.error) {
                if (strongSelf.request.tosCancelHook.tos_isCancelled) {
                    [strongSelf tos_handleCancellation];
                    return;
                }
                NSInteger statusCode = TOSCopyStatusCode(task.error);
                if (TOSTransferShouldRetry(task.error, statusCode) &&
                    retryCount < strongSelf.request.tosMaxRetryCount) {
                    NSTimeInterval delay = TOSTransferRetryDelay(retryCount,
                                                                 responseMetadata.retryAfter,
                                                                 (double)arc4random_uniform(UINT32_MAX) / (double)UINT32_MAX);
                    __weak typeof(strongSelf) retrySelf = strongSelf;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                        __strong typeof(retrySelf) retryStrongSelf = retrySelf;
                        if (!retryStrongSelf) {
                            return;
                        }
                        dispatch_async(retryStrongSelf.tos_stateQueue, ^{
                            [retryStrongSelf tos_attemptHeadWithRetryCount:retryCount + 1];
                        });
                    });
                    return;
                }
                [strongSelf tos_finishWithOutput:nil error:task.error];
                return;
            }
            TOSHeadObjectOutput *output = task.result;
            if (![output isKindOfClass:[TOSHeadObjectOutput class]] || output.tosContentLength < 0) {
                [strongSelf tos_finishWithOutput:nil error:TOSCopyError(@"tos: source head returned an invalid response")];
                return;
            }
            strongSelf.tos_headOutput = output;
            strongSelf.tos_sourceSize = output.tosContentLength;
            strongSelf.tos_effectiveIfMatch = strongSelf.request.tosCopySourceIfMatch.length > 0
                ? strongSelf.request.tosCopySourceIfMatch : (output.tosETag ?: @"");
            NSError *checkpointError = [strongSelf tos_prepareCheckpoint];
            if (checkpointError) {
                [strongSelf tos_finishWithOutput:nil error:checkpointError];
                return;
            }
            if (output.tosObjectType.length > 0 &&
                [output.tosObjectType caseInsensitiveCompare:@"Symlink"] == NSOrderedSame) {
                [strongSelf tos_prepareSymlinkCopy];
                return;
            }
            [strongSelf tos_initializeRemoteState];
        });
        return nil;
    }];
}

- (NSError *)tos_prepareCheckpoint {
    NSError *error = nil;
    NSArray<TOSTransferPart *> *parts = TOSCopyParts(self.tos_sourceSize,
                                                     self.request.tosPartSize,
                                                     &error);
    if (!parts) {
        return error ?: TOSCopyError(@"tos: cannot plan copy parts");
    }
    NSString *checkpointPath = self.request.tosEnableCheckpoint ? self.request.tosCheckpointFile : @"";
    if (self.request.tosEnableCheckpoint &&
        [[NSFileManager defaultManager] fileExistsAtPath:checkpointPath]) {
        NSData *data = [NSData dataWithContentsOfFile:checkpointPath options:0 error:&error];
        if (!data) {
            return error ?: TOSCopyError(@"tos: cannot read copy checkpoint");
        }
        TOSCopyCheckpoint *loaded = [TOSCopyCheckpoint tos_checkpointWithData:data
                                                               checkpointPath:checkpointPath
                                                                          error:&error];
        if (!loaded) {
            return TOSCopyError(@"已有 checkpoint 不是兼容的拷贝 JSON，已拒绝覆盖");
        }
        self.tos_checkpointLoaded = YES;
        if (![loaded.tos_bucket isEqualToString:self.request.tosBucket] ||
            ![loaded.tos_key isEqualToString:self.request.tosKey]) {
            return TOSCopyError(@"checkpoint 属于其他拷贝目标，已拒绝修改远端状态");
        }
        if ([loaded tos_validateForSourceBucket:self.request.tosSrcBucket
                                      sourceKey:self.request.tosSrcKey
                                sourceVersionID:self.request.tosSrcVersionID
                                         bucket:self.request.tosBucket
                                            key:self.request.tosKey
                                       partSize:self.request.tosPartSize
                                   encodingType:self.request.tosEncodingType
                              copySourceIfMatch:self.request.tosCopySourceIfMatch
                      copySourceIfModifiedSince:TOSCopyDateValue(self.request.tosCopySourceIfModifiedSince)
                          copySourceIfNoneMatch:self.request.tosCopySourceIfNoneMatch
                    copySourceIfUnmodifiedSince:TOSCopyDateValue(self.request.tosCopySourceIfUnmodifiedSince)
                                     sourceETag:self.tos_headOutput.tosETag ?: @""
                             sourceLastModified:TOSCopyDateValue(self.tos_headOutput.tosLastModified)
                                     sourceSize:self.tos_sourceSize
                                    sourceCRC64:self.tos_headOutput.tosHashCrc64ecma
                                          error:&error]) {
            self.tos_checkpoint = loaded;
            return nil;
        }
        if (loaded.tos_uploadID.length > 0) {
            self.tos_staleCheckpoint = loaded;
        }
    }
    self.tos_checkpoint = [self tos_newCheckpointWithParts:parts checkpointPath:checkpointPath];
    return nil;
}

- (TOSCopyCheckpoint *)tos_newCheckpointWithParts:(NSArray<TOSTransferPart *> *)parts
                                    checkpointPath:(NSString *)checkpointPath {
    TOSCopyCheckpoint *checkpoint = [TOSCopyCheckpoint new];
    checkpoint.tos_schemaVersion = 1;
    checkpoint.tos_operation = @"copy";
    checkpoint.tos_bucket = self.request.tosBucket;
    checkpoint.tos_key = self.request.tosKey;
    checkpoint.tos_partSize = self.request.tosPartSize;
    checkpoint.tos_checkpointPath = checkpointPath;
    checkpoint.tos_parts = parts;
    checkpoint.tos_encodingType = self.request.tosEncodingType ?: @"";
    checkpoint.tos_srcBucket = self.request.tosSrcBucket;
    checkpoint.tos_srcKey = self.request.tosSrcKey;
    checkpoint.tos_srcVersionID = self.request.tosSrcVersionID ?: @"";
    checkpoint.tos_uploadID = @"";
    checkpoint.tos_copySourceIfMatch = self.request.tosCopySourceIfMatch ?: @"";
    checkpoint.tos_copySourceIfModifiedSince = TOSCopyDateValue(self.request.tosCopySourceIfModifiedSince);
    checkpoint.tos_copySourceIfNoneMatch = self.request.tosCopySourceIfNoneMatch ?: @"";
    checkpoint.tos_copySourceIfUnmodifiedSince = TOSCopyDateValue(self.request.tosCopySourceIfUnmodifiedSince);
    checkpoint.tos_sourceETag = self.tos_headOutput.tosETag ?: @"";
    checkpoint.tos_sourceLastModified = TOSCopyDateValue(self.tos_headOutput.tosLastModified);
    checkpoint.tos_sourceSize = self.tos_sourceSize;
    checkpoint.tos_sourceCRC64 = self.tos_headOutput.tosHashCrc64ecma;
    return checkpoint;
}

- (void)tos_initializeRemoteState {
    if (self.request.tosCancelHook.tos_isCancelled) {
        [self tos_handleCancellation];
        return;
    }
    if (self.tos_staleCheckpoint.tos_uploadID.length > 0) {
        TOSCopyCheckpoint *stale = self.tos_staleCheckpoint;
        self.tos_remoteRequestInFlight = YES;
        [self tos_abortBucket:self.request.tosBucket
                          key:self.request.tosKey
                     uploadID:stale.tos_uploadID
          networkCancellation:[TOSTransferNetworkCancellation new]
                   completion:^(NSError *error) {
            self.tos_remoteRequestInFlight = NO;
            if (error && !TOSCopyIsNoSuchUpload(error)) {
                [self tos_finishWithOutput:nil error:error];
                return;
            }
            NSError *removeError = nil;
            if (![self.tos_checkpointStore removeCheckpoint:stale error:&removeError]) {
                [self tos_finishWithOutput:nil error:removeError];
                return;
            }
            self.tos_staleCheckpoint = nil;
            [self tos_beginCreateOrResume];
        }];
        return;
    }
    [self tos_beginCreateOrResume];
}

- (void)tos_beginCreateOrResume {
    if (self.request.tosCancelHook.tos_isCancelled) {
        [self tos_handleCancellation];
        return;
    }
    if (self.tos_checkpoint.tos_uploadID.length > 0) {
        [self tos_startPendingParts];
        return;
    }
    NSError *error = nil;
    if (![self tos_persistCheckpoint:&error]) {
        [self tos_finishWithOutput:nil error:error];
        return;
    }
    [self tos_attemptCreateMultipartWithRetryCount:0];
}

- (void)tos_attemptCreateMultipartWithRetryCount:(NSInteger)retryCount {
    if (self.tos_finished) {
        return;
    }
    if (self.request.tosCancelHook.tos_isCancelled) {
        [self tos_handleCancellation];
        return;
    }
    TOSCreateMultipartUploadInput *input = [self tos_createMultipartInput];
    input.tos_transferCancellation = self.tos_partOperation.networkCancellation;
    TOSTransferResponseMetadata *responseMetadata = [TOSTransferResponseMetadata new];
    input.tos_responseObserver = TOSTransferRetryAfterObserver(responseMetadata);
    self.tos_remoteRequestInFlight = YES;
    __weak typeof(self) weakSelf = self;
    [[self.tos_client createMultipartUpload:input] continueWithBlock:^id(TOSTask *task) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return nil;
        }
        dispatch_async(strongSelf.tos_stateQueue, ^{
            strongSelf.tos_remoteRequestInFlight = NO;
            if (strongSelf.tos_finished) {
                return;
            }
            if (task.error) {
                if (strongSelf.request.tosCancelHook.tos_isCancelled) {
                    [strongSelf tos_handleCancellation];
                    return;
                }
                NSInteger statusCode = TOSCopyStatusCode(task.error);
                if (TOSTransferShouldRetry(task.error, statusCode) &&
                    retryCount < strongSelf.request.tosMaxRetryCount) {
                    NSTimeInterval delay = TOSTransferRetryDelay(
                        retryCount,
                        responseMetadata.retryAfter,
                        (double)arc4random_uniform(UINT32_MAX) / (double)UINT32_MAX);
                    __weak typeof(strongSelf) retrySelf = strongSelf;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                 (int64_t)(delay * NSEC_PER_SEC)),
                                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                        __strong typeof(retrySelf) retryStrongSelf = retrySelf;
                        if (!retryStrongSelf) {
                            return;
                        }
                        dispatch_async(retryStrongSelf.tos_stateQueue, ^{
                            [retryStrongSelf
                                tos_attemptCreateMultipartWithRetryCount:retryCount + 1];
                        });
                    });
                    return;
                }
                [strongSelf tos_emitEventType:TOSCopyEventCreateMultipartUploadFailed part:nil error:task.error];
                [strongSelf tos_finishWithOutput:nil error:task.error];
                return;
            }
            TOSCreateMultipartUploadOutput *output = task.result;
            if (![output isKindOfClass:[TOSCreateMultipartUploadOutput class]] || output.tosUploadID.length == 0) {
                NSError *outputError = TOSCopyError(@"tos: create multipart upload returned an empty upload ID");
                [strongSelf tos_emitEventType:TOSCopyEventCreateMultipartUploadFailed part:nil error:outputError];
                [strongSelf tos_finishWithOutput:nil error:outputError];
                return;
            }
            strongSelf.tos_checkpoint.tos_uploadID = output.tosUploadID;
            NSError *writeError = nil;
            if (![strongSelf tos_persistCheckpoint:&writeError]) {
                [strongSelf tos_abortAfterLocalFailure:writeError];
                return;
            }
            if (strongSelf.request.tosCancelHook.tos_isCancelled) {
                [strongSelf tos_handleCancellation];
                return;
            }
            [strongSelf tos_emitEventType:TOSCopyEventCreateMultipartUploadSucceed part:nil error:nil];
            [strongSelf tos_startPendingParts];
        });
        return nil;
    }];
}

- (TOSCreateMultipartUploadInput *)tos_createMultipartInput {
    TOSCreateMultipartUploadInput *input = [TOSCreateMultipartUploadInput new];
    input.tosBucket = self.request.tosBucket;
    input.tosKey = self.request.tosKey;
    input.tosEncodingType = self.request.tosEncodingType;
    input.tosCacheControl = self.request.tosCacheControl;
    input.tosContentDisposition = self.request.tosContentDisposition;
    input.tosContentEncoding = self.request.tosContentEncoding;
    input.tosContentLanguage = self.request.tosContentLanguage;
    input.tosContentType = self.request.tosContentType;
    input.tosExpires = self.request.tosExpires;
    input.tosACL = self.request.tosACL;
    input.tosGrantFullControl = self.request.tosGrantFullControl;
    input.tosGrantRead = self.request.tosGrantRead;
    input.tosGrantReadAcp = self.request.tosGrantReadAcp;
    input.tosGrantWriteAcp = self.request.tosGrantWriteAcp;
    input.tosMeta = self.request.tosMeta;
    input.tosWebsiteRedirectLocation = self.request.tosWebsiteRedirectLocation;
    input.tosStorageClass = self.request.tosStorageClass;
    return input;
}

- (void)tos_startPendingParts {
    self.tos_partsStarted = YES;
    __weak typeof(self) weakSelf = self;
    [self.tos_partOperation.task continueWithBlock:^id(TOSTask *task) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return nil;
        }
        dispatch_async(strongSelf.tos_stateQueue, ^{
            [strongSelf tos_partSchedulerFinished:task];
        });
        return nil;
    }];
    [self.tos_partOperation start];
}

- (NSArray<TOSTransferPart *> *)tos_pendingParts {
    NSMutableArray<TOSTransferPart *> *pending = [NSMutableArray array];
    for (TOSTransferPart *part in self.tos_checkpoint.tos_parts) {
        if (!part.tos_completed) {
            [pending addObject:part];
        }
    }
    return [pending copy];
}

- (TOSTask<TOSTransferAttemptResult *> *)tos_attemptPart:(TOSTransferPart *)part
                                              retryCount:(NSInteger)retryCount
                                     networkCancellation:(TOSTransferNetworkCancellation *)networkCancellation {
    TOSTaskCompletionSource<TOSTransferAttemptResult *> *source = [TOSTaskCompletionSource taskCompletionSource];
    TOSTask *networkTask = nil;
    TOSTransferResponseMetadata *responseMetadata = [TOSTransferResponseMetadata new];
    if (part.tos_zeroSize) {
        TOSUploadPartInput *input = [TOSUploadPartInput new];
        input.tosBucket = self.request.tosBucket;
        input.tosKey = self.request.tosKey;
        input.tosUploadID = self.tos_checkpoint.tos_uploadID;
        input.tosPartNumber = (int)part.tos_partNumber;
        input.tosContent = [NSData data];
        input.tosContentLength = 0;
        NSMutableDictionary *headers = [NSMutableDictionary dictionaryWithObject:@"0" forKey:@"Content-Length"];
        if (self.request.tosTrafficLimit > 0) {
            headers[@"x-tos-traffic-limit"] = [NSString stringWithFormat:@"%lld", self.request.tosTrafficLimit];
        }
        input.tos_transferHeaders = headers;
        input.tos_transferCancellation = networkCancellation;
        input.tos_responseObserver = TOSTransferRetryAfterObserver(responseMetadata);
        networkTask = [self.tos_client uploadPart:input];
    } else {
        TOSUploadPartCopyInput *input = [TOSUploadPartCopyInput new];
        input.tosBucket = self.request.tosBucket;
        input.tosKey = self.request.tosKey;
        input.tosUploadID = self.tos_checkpoint.tos_uploadID;
        input.tosPartNumber = (int)part.tos_partNumber;
        input.tosSrcBucket = self.request.tosSrcBucket;
        input.tosSrcKey = self.request.tosSrcKey;
        input.tosSrcVersionID = self.request.tosSrcVersionID;
        input.tosCopySourceRangeStart = part.tos_rangeStart;
        input.tosCopySourceRangeEnd = part.tos_rangeEnd;
        input.tosCopySourceIfMatch = self.tos_effectiveIfMatch;
        input.tosCopySourceIfModifiedSince = self.request.tosCopySourceIfModifiedSince;
        input.tosCopySourceIfNoneMatch = self.request.tosCopySourceIfNoneMatch;
        input.tosCopySourceIfUnmodifiedSince = self.request.tosCopySourceIfUnmodifiedSince;
        NSMutableDictionary *headers = [NSMutableDictionary dictionary];
        if (self.tos_effectiveIfMatch.length > 0) {
            headers[@"x-tos-copy-source-if-match"] = self.tos_effectiveIfMatch;
        }
        if (self.request.tosCopySourceIfNoneMatch.length > 0) {
            headers[@"x-tos-copy-source-if-none-match"] = self.request.tosCopySourceIfNoneMatch;
        }
        if (self.request.tosTrafficLimit > 0) {
            headers[@"x-tos-traffic-limit"] =
                [NSString stringWithFormat:@"%lld", self.request.tosTrafficLimit];
        }
        input.tos_transferHeaders = headers;
        input.tos_transferCancellation = networkCancellation;
        input.tos_responseObserver = TOSTransferRetryAfterObserver(responseMetadata);
        networkTask = [self.tos_client uploadPartCopy:input];
    }

    __weak typeof(self) weakSelf = self;
    [networkTask continueWithBlock:^id(TOSTask *task) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return nil;
        }
        dispatch_async(strongSelf.tos_stateQueue, ^{
            NSError *error = task.error;
            NSString *eTag = nil;
            NSInteger outputPartNumber = 0;
            if (!error && part.tos_zeroSize) {
                TOSUploadPartOutput *output = task.result;
                if (![output isKindOfClass:[TOSUploadPartOutput class]]) {
                    error = TOSCopyError(@"tos: empty upload part returned an invalid response");
                } else {
                    eTag = output.tosETag;
                    outputPartNumber = output.tosPartNumber;
                }
            } else if (!error) {
                TOSUploadPartCopyOutput *output = task.result;
                if (![output isKindOfClass:[TOSUploadPartCopyOutput class]]) {
                    error = TOSCopyError(@"tos: upload part copy returned an invalid response");
                } else {
                    eTag = output.tosETag;
                    outputPartNumber = output.tosPartNumber;
                }
            }
            if (!error && eTag.length == 0) {
                error = TOSCopyError(@"tos: copied part response is missing ETag");
            }
            if (!error && outputPartNumber != part.tos_partNumber) {
                error = TOSCopyError(@"tos: copied part response has an unexpected part number");
            }
            if (!error) {
                BOOL previousCompleted = part.tos_completed;
                NSString *previousETag = part.tos_eTag;
                part.tos_completed = YES;
                part.tos_eTag = eTag;
                NSError *checkpointError = nil;
                if (![strongSelf tos_persistCheckpoint:&checkpointError]) {
                    part.tos_completed = previousCompleted;
                    part.tos_eTag = previousETag;
                    error = checkpointError;
                }
            }

            TOSTransferAttemptResult *result = [TOSTransferAttemptResult new];
            result.error = error;
            result.statusCode = TOSCopyStatusCode(error);
            result.retryAfter = responseMetadata.retryAfter;
            if (!error) {
                result.value = part;
                [strongSelf tos_emitEventType:TOSCopyEventUploadPartCopySucceed part:part error:nil];
            } else if (!(TOSTransferShouldRetry(error, result.statusCode) &&
                         retryCount < strongSelf.request.tosMaxRetryCount)) {
                TOSCopyEventType type = TOSCopyIsAbortStatus(error)
                    ? TOSCopyEventUploadPartCopyAborted : TOSCopyEventUploadPartCopyFailed;
                [strongSelf tos_emitEventType:type part:part error:error];
            }
            [source setResult:result];
        });
        return nil;
    }];
    return source.task;
}

- (void)tos_partSchedulerFinished:(TOSTask *)task {
    if (self.tos_finished) {
        return;
    }
    if (self.request.tosCancelHook.tos_isCancelled) {
        [self tos_handleCancellation];
        return;
    }
    if (task.error) {
        if (TOSCopyIsAbortStatus(task.error)) {
            [self tos_abortAfterFatalPartError:task.error];
        } else {
            [self tos_finishFailureCleaningMultipartIfNeeded:task.error];
        }
        return;
    }
    [self tos_completeMultipartUpload];
}

- (void)tos_completeMultipartUpload {
    NSArray<TOSTransferPart *> *parts = [self.tos_checkpoint.tos_parts
                                         sortedArrayUsingComparator:^NSComparisonResult(TOSTransferPart *left,
                                                                                         TOSTransferPart *right) {
        if (left.tos_partNumber < right.tos_partNumber) return NSOrderedAscending;
        if (left.tos_partNumber > right.tos_partNumber) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    NSMutableArray<TOSUploadedPart *> *uploadedParts = [NSMutableArray arrayWithCapacity:parts.count];
    for (TOSTransferPart *part in parts) {
        if (!part.tos_completed || part.tos_eTag.length == 0) {
            [self tos_finishFailureCleaningMultipartIfNeeded:
                TOSCopyError(@"tos: cannot complete copy with unfinished parts")];
            return;
        }
        TOSUploadedPart *uploadedPart = [TOSUploadedPart new];
        uploadedPart.tosPartNumber = (int)part.tos_partNumber;
        uploadedPart.tosETag = part.tos_eTag;
        uploadedPart.tosSize = part.tos_size;
        [uploadedParts addObject:uploadedPart];
    }

    TOSCompleteMultipartUploadInput *input = [TOSCompleteMultipartUploadInput new];
    input.tosBucket = self.request.tosBucket;
    input.tosKey = self.request.tosKey;
    input.tosUploadID = self.tos_checkpoint.tos_uploadID;
    input.tosParts = uploadedParts;
    input.tos_transferCancellation = self.tos_partOperation.networkCancellation;
    self.tos_remoteRequestInFlight = YES;
    __weak typeof(self) weakSelf = self;
    [[self.tos_client completeMultipartUpload:input] continueWithBlock:^id(TOSTask *task) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return nil;
        }
        dispatch_async(strongSelf.tos_stateQueue, ^{
            strongSelf.tos_remoteRequestInFlight = NO;
            if (strongSelf.tos_finished) {
                return;
            }
            if (task.error) {
                if (strongSelf.request.tosCancelHook.tos_isCancelled) {
                    [strongSelf tos_handleCancellation];
                    return;
                }
                [strongSelf tos_emitEventType:TOSCopyEventCompleteMultipartUploadFailed part:nil error:task.error];
                if (TOSCopyIsNoSuchUpload(task.error)) {
                    [strongSelf tos_removeCheckpoint];
                    [strongSelf tos_finishWithOutput:nil error:task.error];
                } else {
                    [strongSelf tos_finishFailureCleaningMultipartIfNeeded:task.error];
                }
                return;
            }
            TOSCompleteMultipartUploadOutput *output = task.result;
            NSError *validationError =
                TOSTransferValidateCompleteMultipartUploadOutput(output,
                                                                 strongSelf.request.tosBucket,
                                                                 strongSelf.request.tosKey,
                                                                 NO);
            if (validationError) {
                [strongSelf tos_emitEventType:TOSCopyEventCompleteMultipartUploadFailed
                                         part:nil
                                        error:validationError];
                [strongSelf tos_finishFailureCleaningMultipartIfNeeded:validationError];
                return;
            }
            if (strongSelf.tos_headOutput.tosHashCrc64ecma != 0 &&
                output.tosHashCrc64ecma != 0 &&
                strongSelf.tos_headOutput.tosHashCrc64ecma != output.tosHashCrc64ecma) {
                NSError *error = TOSCopyError(@"tos: source and destination crc mismatch");
                [strongSelf tos_removeCheckpoint];
                [strongSelf tos_emitEventType:TOSCopyEventCompleteMultipartUploadFailed part:nil error:error];
                [strongSelf tos_finishWithOutput:nil error:error];
                return;
            }
            [strongSelf tos_removeCheckpoint];
            [strongSelf tos_emitEventType:TOSCopyEventCompleteMultipartUploadSucceed part:nil error:nil];
            [strongSelf tos_finishWithOutput:[strongSelf tos_outputFromComplete:output] error:nil];
        });
        return nil;
    }];
}

- (void)tos_prepareSymlinkCopy {
    TOSCopyCheckpoint *existingCheckpoint = self.tos_staleCheckpoint;
    if (!existingCheckpoint && self.tos_checkpointLoaded) {
        existingCheckpoint = self.tos_checkpoint;
    }
    if (existingCheckpoint.tos_uploadID.length == 0) {
        [self tos_copySymlink];
        return;
    }

    self.tos_remoteRequestInFlight = YES;
    __weak typeof(self) weakSelf = self;
    [self tos_abortBucket:self.request.tosBucket
                      key:self.request.tosKey
                 uploadID:existingCheckpoint.tos_uploadID
      networkCancellation:[TOSTransferNetworkCancellation new]
               completion:^(NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        strongSelf.tos_remoteRequestInFlight = NO;
        if (error && !TOSCopyIsNoSuchUpload(error)) {
            [strongSelf tos_finishWithOutput:nil error:error];
            return;
        }
        NSError *removeError = nil;
        if (![strongSelf tos_removeCheckpoint:existingCheckpoint error:&removeError]) {
            [strongSelf tos_finishWithOutput:nil error:removeError];
            return;
        }
        strongSelf.tos_staleCheckpoint = nil;
        strongSelf.tos_checkpointLoaded = NO;
        if (strongSelf.request.tosCancelHook.tos_isCancelled) {
            [strongSelf tos_handleCancellation];
            return;
        }
        [strongSelf tos_copySymlink];
    }];
}

- (void)tos_copySymlink {
    if (self.request.tosCancelHook.tos_isCancelled) {
        [self tos_handleCancellation];
        return;
    }
    TOSCopyObjectInput *input = [TOSCopyObjectInput new];
    input.tosBucket = self.request.tosBucket;
    input.tosKey = self.request.tosKey;
    input.tosSrcBucket = self.request.tosSrcBucket;
    input.tosSrcKey = self.request.tosSrcKey;
    input.tosSrcVersionID = self.request.tosSrcVersionID;
    input.tosCacheControl = self.request.tosCacheControl;
    input.tosContentDisposition = self.request.tosContentDisposition;
    input.tosContentEncoding = self.request.tosContentEncoding;
    input.tosContentLanguage = self.request.tosContentLanguage;
    input.tosContentType = self.request.tosContentType;
    input.tosExpires = self.request.tosExpires;
    input.tosCopySourceIfMatch = self.tos_effectiveIfMatch;
    input.tosCopySourceIfModifiedSince = self.request.tosCopySourceIfModifiedSince;
    input.tosCopySourceIfNoneMatch = self.request.tosCopySourceIfNoneMatch;
    input.tosCopySourceIfUnmodifiedSince = self.request.tosCopySourceIfUnmodifiedSince;
    input.tosACL = self.request.tosACL;
    input.tosGrantFullControl = self.request.tosGrantFullControl;
    input.tosGrantRead = self.request.tosGrantRead;
    input.tosGrantReadAcp = self.request.tosGrantReadAcp;
    input.tosGrantWriteAcp = self.request.tosGrantWriteAcp;
    input.tosMeta = self.request.tosMeta;
    input.tosWebsiteRedirectLocation = self.request.tosWebsiteRedirectLocation;
    input.tosStorageClass = self.request.tosStorageClass;
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    if (self.tos_effectiveIfMatch.length > 0) {
        headers[@"x-tos-copy-source-if-match"] = self.tos_effectiveIfMatch;
    }
    if (self.request.tosCopySourceIfNoneMatch.length > 0) {
        headers[@"x-tos-copy-source-if-none-match"] = self.request.tosCopySourceIfNoneMatch;
    }
    if (self.request.tosTrafficLimit > 0) {
        headers[@"x-tos-traffic-limit"] = [NSString stringWithFormat:@"%lld", self.request.tosTrafficLimit];
    }
    input.tos_transferHeaders = headers;
    input.tos_transferCancellation = self.tos_partOperation.networkCancellation;
    self.tos_remoteRequestInFlight = YES;
    __weak typeof(self) weakSelf = self;
    [[self.tos_client copyObject:input] continueWithBlock:^id(TOSTask *task) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return nil;
        }
        dispatch_async(strongSelf.tos_stateQueue, ^{
            strongSelf.tos_remoteRequestInFlight = NO;
            if (strongSelf.tos_finished) {
                return;
            }
            if (task.error) {
                if (strongSelf.request.tosCancelHook.tos_isCancelled) {
                    [strongSelf tos_handleCancellation];
                } else {
                    [strongSelf tos_finishWithOutput:nil error:task.error];
                }
                return;
            }
            TOSCopyObjectOutput *output = task.result;
            if (![output isKindOfClass:[TOSCopyObjectOutput class]]) {
                [strongSelf tos_finishWithOutput:nil error:TOSCopyError(@"tos: copy symlink returned an invalid response")];
                return;
            }
            [strongSelf tos_removeCheckpoint];
            [strongSelf tos_finishWithOutput:[strongSelf tos_outputFromCopy:output] error:nil];
        });
        return nil;
    }];
}

- (TOSResumableCopyObjectOutput *)tos_outputFromComplete:(TOSCompleteMultipartUploadOutput *)output {
    TOSResumableCopyObjectOutput *result = [TOSResumableCopyObjectOutput new];
    result.tosRequestID = output.tosRequestID;
    result.tosID2 = output.tosID2;
    result.tosStatusCode = output.tosStatusCode;
    result.tosHeader = output.tosHeader;
    result.tosBucket = self.request.tosBucket;
    result.tosKey = self.request.tosKey;
    result.tosUploadID = self.tos_checkpoint.tos_uploadID;
    result.tosETag = output.tosETag;
    result.tosLocation = output.tosLocation;
    result.tosVersionID = output.tosVersionID;
    result.tosHashCrc64ecma = output.tosHashCrc64ecma;
    result.tosEncodingType = self.request.tosEncodingType;
    return result;
}

- (TOSResumableCopyObjectOutput *)tos_outputFromCopy:(TOSCopyObjectOutput *)output {
    TOSResumableCopyObjectOutput *result = [TOSResumableCopyObjectOutput new];
    result.tosRequestID = output.tosRequestID;
    result.tosID2 = output.tosID2;
    result.tosStatusCode = output.tosStatusCode;
    result.tosHeader = output.tosHeader;
    result.tosBucket = self.request.tosBucket;
    result.tosKey = self.request.tosKey;
    result.tosETag = output.tosETag;
    result.tosVersionID = output.tosVersionID;
    result.tosHashCrc64ecma = self.tos_headOutput.tosHashCrc64ecma;
    result.tosEncodingType = self.request.tosEncodingType;
    return result;
}

- (void)tos_handleCancellation {
    if (self.tos_finished || self.tos_cleanupInFlight) {
        return;
    }
    NSError *cancelError = TOSCopyError(@"This task has been cancelled!");
    if (self.request.tosEnableCheckpoint && !self.request.tosCancelHook.tos_shouldAbort) {
        [self tos_finishWithOutput:nil error:cancelError];
        return;
    }
    TOSCopyCheckpoint *checkpointToAbort =
        self.tos_staleCheckpoint.tos_uploadID.length > 0
            ? self.tos_staleCheckpoint : self.tos_checkpoint;
    if (checkpointToAbort.tos_uploadID.length == 0) {
        NSError *removeError = nil;
        if (![self tos_removeCheckpoint:checkpointToAbort error:&removeError]) {
            [self tos_finishWithOutput:nil error:removeError];
            return;
        }
        [self tos_finishWithOutput:nil error:cancelError];
        return;
    }
    self.tos_cleanupInFlight = YES;
    [self tos_abortBucket:checkpointToAbort.tos_bucket
                      key:checkpointToAbort.tos_key
                 uploadID:checkpointToAbort.tos_uploadID
      networkCancellation:[TOSTransferNetworkCancellation new]
               completion:^(NSError *error) {
        self.tos_cleanupInFlight = NO;
        if (error && !TOSCopyIsNoSuchUpload(error)) {
            [self tos_finishWithOutput:nil error:error];
        } else {
            NSError *removeError = nil;
            if (![self tos_removeCheckpoint:checkpointToAbort error:&removeError]) {
                [self tos_finishWithOutput:nil error:removeError];
                return;
            }
            if (checkpointToAbort == self.tos_staleCheckpoint) {
                self.tos_staleCheckpoint = nil;
            }
            [self tos_finishWithOutput:nil error:cancelError];
        }
    }];
}

- (void)tos_finishFailureCleaningMultipartIfNeeded:(NSError *)error {
    if (self.request.tosEnableCheckpoint || self.tos_checkpoint.tos_uploadID.length == 0) {
        [self tos_finishWithOutput:nil error:error];
        return;
    }
    if (self.tos_cleanupInFlight) {
        return;
    }
    self.tos_cleanupInFlight = YES;
    [self tos_abortBucket:self.tos_checkpoint.tos_bucket
                      key:self.tos_checkpoint.tos_key
                 uploadID:self.tos_checkpoint.tos_uploadID
      networkCancellation:[TOSTransferNetworkCancellation new]
               completion:^(NSError *abortError) {
        self.tos_cleanupInFlight = NO;
        if (abortError && !TOSCopyIsNoSuchUpload(abortError)) {
            [self tos_finishWithOutput:nil error:abortError];
        } else {
            [self tos_finishWithOutput:nil error:error];
        }
    }];
}

- (void)tos_abortAfterFatalPartError:(NSError *)partError {
    if (self.tos_cleanupInFlight) {
        return;
    }
    self.tos_cleanupInFlight = YES;
    [self tos_abortBucket:self.tos_checkpoint.tos_bucket
                      key:self.tos_checkpoint.tos_key
                 uploadID:self.tos_checkpoint.tos_uploadID
      networkCancellation:[TOSTransferNetworkCancellation new]
               completion:^(NSError *abortError) {
        self.tos_cleanupInFlight = NO;
        if (abortError && !TOSCopyIsNoSuchUpload(abortError)) {
            [self tos_finishWithOutput:nil error:abortError];
        } else {
            [self tos_removeCheckpoint];
            [self tos_finishWithOutput:nil error:partError];
        }
    }];
}

- (void)tos_abortAfterLocalFailure:(NSError *)localError {
    [self tos_abortBucket:self.tos_checkpoint.tos_bucket
                      key:self.tos_checkpoint.tos_key
                 uploadID:self.tos_checkpoint.tos_uploadID
      networkCancellation:[TOSTransferNetworkCancellation new]
               completion:^(NSError *abortError) {
        [self tos_finishWithOutput:nil error:abortError ?: localError];
    }];
}

- (void)tos_abortBucket:(NSString *)bucket
                    key:(NSString *)key
               uploadID:(NSString *)uploadID
    networkCancellation:(TOSTransferNetworkCancellation *)networkCancellation
             completion:(void (^)(NSError *error))completion {
    TOSAbortMultipartUploadInput *input = [TOSAbortMultipartUploadInput new];
    input.tosBucket = bucket;
    input.tosKey = key;
    input.tosUploadID = uploadID;
    input.tos_transferCancellation = networkCancellation;
    __weak typeof(self) weakSelf = self;
    [[self.tos_client abortMultipartUpload:input] continueWithBlock:^id(TOSTask *task) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return nil;
        }
        dispatch_async(strongSelf.tos_stateQueue, ^{
            if (!strongSelf.tos_finished && completion) {
                completion(task.error);
            }
        });
        return nil;
    }];
}

- (BOOL)tos_persistCheckpoint:(NSError **)error {
    if (!self.request.tosEnableCheckpoint) {
        return YES;
    }
    return [self.tos_checkpointStore writeCheckpoint:self.tos_checkpoint error:error];
}

- (void)tos_removeCheckpoint {
    [self tos_removeCheckpoint:self.tos_checkpoint error:nil];
}

- (BOOL)tos_removeCheckpoint:(TOSCopyCheckpoint *)checkpoint
                       error:(NSError **)error {
    if (!self.request.tosEnableCheckpoint || checkpoint.tos_checkpointPath.length == 0) {
        return YES;
    }
    return [self.tos_checkpointStore removeCheckpoint:checkpoint error:error];
}

- (void)tos_emitEventType:(TOSCopyEventType)type
                      part:(TOSTransferPart *)part
                     error:(NSError *)error {
    if (!self.request.tosCopyEventListener) {
        return;
    }
    TOSCopyEvent *event = [TOSCopyEvent new];
    event.tosType = type;
    if (error) {
        event.tosErr = error;
    }
    event.tosBucket = self.request.tosBucket;
    event.tosKey = self.request.tosKey;
    event.tosUploadID = self.tos_checkpoint.tos_uploadID;
    event.tosSrcBucket = self.request.tosSrcBucket;
    event.tosSrcKey = self.request.tosSrcKey;
    event.tosSrcVersionID = self.request.tosSrcVersionID;
    event.tosCheckpointPath = self.request.tosCheckpointFile;
    if (part) {
        TOSCopyPartInfo *partInfo = [TOSCopyPartInfo new];
        partInfo.tosPartNumber = (int)part.tos_partNumber;
        partInfo.tosCopySourceRangeStart = part.tos_rangeStart;
        partInfo.tosCopySourceRangeEnd = part.tos_rangeEnd;
        partInfo.tosETag = part.tos_eTag;
        event.tosCopyPartInfo = partInfo;
    }
    self.request.tosCopyEventListener(event);
}

- (void)tos_finishWithOutput:(TOSResumableCopyObjectOutput *)output error:(NSError *)error {
    if (self.tos_finished) {
        return;
    }
    self.tos_finished = YES;
    [self.tos_checkpointLease invalidate];
    self.tos_checkpointLease = nil;
    if (error) {
        [self.tos_taskSource trySetError:error];
    } else {
        [self.tos_taskSource trySetResult:output];
    }
    self.tos_lifetimeAnchor = nil;
}

@end
