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

#import "TOSUploadFileV2Operation.h"
#import "TOSInput+TransferInternal.h"
#import "TOSTransferCheckpoint.h"
#import "TOSTransferIO.h"
#import "TOSTransferOperation.h"
#import <VeTOSiOSSDK/TOSClient.h>
#import <VeTOSiOSSDK/TOSUtil.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

@interface TOSClient (TransferConcurrencyInternal)
- (TOSTransferConcurrencyController *)tos_resumableTransferConcurrencyController;
@end

static NSError *TOSUploadV2Error(NSString *message) {
    return [NSError errorWithDomain:TOSClientErrorDomain
                               code:400
                           userInfo:@{TOSErrorMessageTOKEN: message ?: @"断点续传上传失败"}];
}

static int64_t TOSUploadV2ModifiedTime(struct stat fileStat) {
    if (fileStat.st_mtimespec.tv_sec > INT64_MAX / NSEC_PER_SEC) {
        return INT64_MAX;
    }
    return fileStat.st_mtimespec.tv_sec * NSEC_PER_SEC + fileStat.st_mtimespec.tv_nsec;
}

static NSInteger TOSUploadV2StatusCode(NSError *error) {
    return [error.domain isEqualToString:TOSServerErrorDomain] ? error.code : 0;
}

static id TOSUploadV2HeaderValue(TOSOutput *output, NSString *name) {
    for (id key in output.tosHeader) {
        if ([[key description] caseInsensitiveCompare:name] == NSOrderedSame) {
            return output.tosHeader[key];
        }
    }
    return nil;
}

static BOOL TOSUploadV2IsNoSuchUpload(NSError *error) {
    if (![error.domain isEqualToString:TOSServerErrorDomain]) {
        return NO;
    }
    NSString *errorCode = [error.userInfo[@"Code"] description];
    NSString *message = [error.userInfo[TOSErrorMessageTOKEN] description];
    return [errorCode isEqualToString:@"NoSuchUpload"] ||
           (message.length > 0 &&
            [message rangeOfString:@"NoSuchUpload" options:NSCaseInsensitiveSearch].location != NSNotFound);
}

static BOOL TOSUploadV2IsAbortStatus(NSError *error) {
    NSInteger statusCode = TOSUploadV2StatusCode(error);
    return statusCode == 403 || statusCode == 404 || statusCode == 405;
}

static BOOL TOSUploadV2IsCancellationError(NSError *error) {
    NSError *candidate = error;
    while (candidate) {
        if (([candidate.domain isEqualToString:TOSClientErrorDomain] &&
             candidate.code == TOSClientErrorCodeTaskCancelled) ||
            ([candidate.domain isEqualToString:NSURLErrorDomain] &&
             candidate.code == NSURLErrorCancelled)) {
            return YES;
        }
        id originCode = candidate.userInfo[@"OriginErrorCode"];
        if ([originCode respondsToSelector:@selector(integerValue)] &&
            [originCode integerValue] == NSURLErrorCancelled) {
            return YES;
        }
        id underlying = candidate.userInfo[NSUnderlyingErrorKey];
        candidate = [underlying isKindOfClass:[NSError class]] ? underlying : nil;
    }
    return NO;
}

@class TOSUploadFileV2Operation;

@interface TOSUploadV2PartOperation : TOSTransferOperation
@property (nonatomic, weak) TOSUploadFileV2Operation *tos_owner;
@end

@interface TOSUploadFileV2Operation ()
@property (nonatomic, strong) TOSClient *tos_client;
@property (nonatomic, strong) TOSTaskCompletionSource<TOSUploadFileOutputV2 *> *tos_taskSource;
@property (nonatomic, strong, readwrite) TOSTask<TOSUploadFileOutputV2 *> *task;
@property (nonatomic, strong, readwrite) TOSUploadFileInputV2 *request;
@property (nonatomic, assign) BOOL tos_started;
@property (nonatomic, strong) dispatch_queue_t tos_stateQueue;
@property (nonatomic, assign) int tos_sourceDescriptor;
@property (nonatomic, assign) dev_t tos_sourceDevice;
@property (nonatomic, assign) ino_t tos_sourceInode;
@property (nonatomic, assign) int64_t tos_fileSize;
@property (nonatomic, assign) int64_t tos_fileModifiedTime;
@property (nonatomic, strong) TOSUploadCheckpointV2 *tos_checkpoint;
@property (nonatomic, strong) TOSUploadCheckpointV2 *tos_staleCheckpoint;
@property (nonatomic, strong) TOSTransferCheckpointStore *tos_checkpointStore;
@property (nonatomic, strong) TOSTransferCheckpointLease *tos_checkpointLease;
@property (nonatomic, strong) TOSUploadV2PartOperation *tos_partOperation;
@property (nonatomic, strong) TOSTransferProgress *tos_progress;
@property (nonatomic, strong) TOSUploadFileV2Operation *tos_lifetimeAnchor;
@property (nonatomic, assign) BOOL tos_finished;
@property (nonatomic, assign) BOOL tos_cleanupInFlight;
@property (nonatomic, assign) BOOL tos_remoteRequestInFlight;
@property (nonatomic, assign) BOOL tos_partsStarted;
- (NSArray<TOSTransferPart *> *)tos_pendingParts;
- (TOSTask<TOSTransferAttemptResult *> *)tos_attemptPart:(TOSTransferPart *)part
                                              retryCount:(NSInteger)retryCount
                                     networkCancellation:(TOSTransferNetworkCancellation *)networkCancellation;
- (void)tos_attemptCreateMultipartWithRetryCount:(NSInteger)retryCount;
- (BOOL)tos_removeCheckpoint:(TOSUploadCheckpointV2 *)checkpoint
                       error:(NSError **)error;
@end

@implementation TOSUploadV2PartOperation

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

@implementation TOSUploadFileV2Operation

- (instancetype)initWithClient:(TOSClient *)client request:(TOSUploadFileInputV2 *)request {
    self = [super init];
    if (self) {
        _tos_client = client;
        _request = [request mutableCopy];
        _request.tosMeta = [request.tosMeta copy];
        _tos_taskSource = [TOSTaskCompletionSource taskCompletionSource];
        _task = _tos_taskSource.task;
        _tos_stateQueue = dispatch_queue_create("com.volces.tos.transfer.upload-v2", DISPATCH_QUEUE_SERIAL);
        _tos_sourceDescriptor = -1;
        _tos_checkpointStore = [[TOSTransferCheckpointStore alloc] init];
        _tos_progress = [[TOSTransferProgress alloc] initWithListener:_request.tosDataTransferListener];
    }
    return self;
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
        NSError *error = [self tos_prepareRequestAndCheckpoint];
        if (error) {
            [self tos_finishWithOutput:nil error:error];
            return;
        }
        TOSTransferProgress *schedulerProgress = [[TOSTransferProgress alloc] initWithListener:nil];
        self.tos_partOperation = [[TOSUploadV2PartOperation alloc]
                                  initWithTaskNum:self.request.tosTaskNum
                                  maxRetryCount:self.request.tosMaxRetryCount
                                  cancelHook:self.request.tosCancelHook
                                  progress:schedulerProgress
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
        [self tos_initializeRemoteState];
    });
}

- (NSError *)tos_prepareRequestAndCheckpoint {
    if (![TOSUtil isNotEmptyString:self.request.tosFilePath]) {
        return TOSUploadV2Error(@"tos: invalid file path");
    }

    NSString *standardizedPath = [[NSURL fileURLWithPath:self.request.tosFilePath]
                                  URLByStandardizingPath].path;
    int descriptor = open(standardizedPath.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (descriptor < 0) {
        return TOSUploadV2Error(@"tos: invalid file path, the file does not exist");
    }
    self.tos_sourceDescriptor = descriptor;
    self.request.tosFilePath = standardizedPath;

    struct stat fileStat;
    if (fstat(descriptor, &fileStat) != 0) {
        return TOSUploadV2Error(@"tos: cannot read source file information");
    }
    if (!S_ISREG(fileStat.st_mode)) {
        return TOSUploadV2Error(@"tos: does not support directory, please specific your file path");
    }
    if (fileStat.st_size < 0) {
        return TOSUploadV2Error(@"tos: invalid source file size");
    }
    self.tos_sourceDevice = fileStat.st_dev;
    self.tos_sourceInode = fileStat.st_ino;
    self.tos_fileSize = fileStat.st_size;
    self.tos_fileModifiedTime = TOSUploadV2ModifiedTime(fileStat);

    NSError *validationError = nil;
    if (!self.tos_client.clientConfiguration.tosEndpoint.isCustomDomain &&
        ![TOSUtil isValidBucketName:self.request.tosBucket withError:&validationError]) {
        return validationError;
    }
    if (![TOSUtil isValidObjectName:self.request.tosKey withError:&validationError]) {
        return validationError;
    }

    if (self.request.tosPartSize == 0) {
        self.request.tosPartSize = TOSDefaultPartSize;
    }
    if (self.request.tosPartSize < TOSMinPartSize || self.request.tosPartSize > TOSMaxPartSize) {
        return TOSUploadV2Error(@"tos: invalid part size, the size must be [5242880, 5368709120]");
    }
    self.request.tosTaskNum = (int)TOSNormalizeResumableTransferTaskNum(self.request.tosTaskNum);
    if (self.request.tosMaxRetryCount < 0) {
        return TOSUploadV2Error(@"tos: max retry count must not be negative");
    }
    if (self.request.tosTrafficLimit < 0) {
        return TOSUploadV2Error(@"tos: traffic limit must not be negative");
    }
    if (self.request.tosSSECAlgorithm.length > 0 ||
        self.request.tosSSECKey.length > 0 ||
        self.request.tosSSECKeyMD5.length > 0 ||
        self.request.tosServerSideEncryption.length > 0) {
        return TOSUploadV2Error(@"断点续传上传 V2 不支持 SSE 相关参数");
    }

    NSError *partError = nil;
    NSArray<TOSTransferPart *> *parts = TOSUploadParts(self.tos_fileSize,
                                                       self.request.tosPartSize,
                                                       &partError);
    if (!parts) {
        int64_t partCount = self.tos_fileSize / self.request.tosPartSize;
        if (self.tos_fileSize % self.request.tosPartSize != 0) {
            partCount += 1;
        }
        if (partCount > 10000) {
            return TOSUploadV2Error(@"tos: unsupported part number, the maximum is 10000");
        }
        return partError ?: TOSUploadV2Error(@"tos: cannot plan upload parts");
    }

    NSString *checkpointPath = @"";
    if (self.request.tosEnableCheckpoint) {
        checkpointPath = TOSUploadCheckpointPath(self.request.tosCheckpointFile,
                                                  self.request.tosFilePath,
                                                  self.request.tosBucket,
                                                  self.request.tosKey,
                                                  &validationError);
        if (!checkpointPath) {
            return validationError;
        }
        self.request.tosCheckpointFile = checkpointPath;
        self.tos_checkpointLease =
            [TOSTransferCheckpointLease acquireCheckpointPath:checkpointPath
                                                        error:&validationError];
        if (!self.tos_checkpointLease) {
            return validationError ?: TOSUploadV2Error(@"tos: checkpoint is already in use");
        }
        if ([[NSFileManager defaultManager] fileExistsAtPath:checkpointPath]) {
            NSData *data = [NSData dataWithContentsOfFile:checkpointPath options:0 error:&validationError];
            if (!data) {
                return validationError ?: TOSUploadV2Error(@"读取 checkpoint 失败");
            }
            TOSUploadCheckpointV2 *checkpoint = [TOSUploadCheckpointV2 tos_checkpointWithData:data
                                                                                checkpointPath:checkpointPath
                                                                                           error:&validationError];
            if (!checkpoint) {
                return TOSUploadV2Error(@"已有 checkpoint 不是兼容的上传 V2 JSON，已拒绝覆盖");
            }
            if (![checkpoint.tos_bucket isEqualToString:self.request.tosBucket] ||
                ![checkpoint.tos_key isEqualToString:self.request.tosKey]) {
                return TOSUploadV2Error(@"checkpoint 属于其他上传目标，已拒绝修改远端状态");
            }
            if (![checkpoint tos_validateForBucket:self.request.tosBucket
                                               key:self.request.tosKey
                                          partSize:self.request.tosPartSize
                                      encodingType:self.request.tosEncodingType
                                          filePath:self.request.tosFilePath
                                          fileSize:self.tos_fileSize
                                  fileModifiedTime:self.tos_fileModifiedTime
                                             error:&validationError]) {
                if (checkpoint.tos_uploadID.length > 0) {
                    self.tos_staleCheckpoint = checkpoint;
                }
            } else {
                self.tos_checkpoint = checkpoint;
                return nil;
            }
        }
    }

    self.tos_checkpoint = [self tos_newCheckpointWithParts:parts checkpointPath:checkpointPath];
    return nil;
}

- (TOSUploadCheckpointV2 *)tos_newCheckpointWithParts:(NSArray<TOSTransferPart *> *)parts
                                        checkpointPath:(NSString *)checkpointPath {
    TOSUploadCheckpointV2 *checkpoint = [TOSUploadCheckpointV2 new];
    checkpoint.tos_schemaVersion = 1;
    checkpoint.tos_operation = @"upload";
    checkpoint.tos_bucket = self.request.tosBucket;
    checkpoint.tos_key = self.request.tosKey;
    checkpoint.tos_partSize = self.request.tosPartSize;
    checkpoint.tos_checkpointPath = checkpointPath;
    checkpoint.tos_parts = parts;
    checkpoint.tos_encodingType = self.request.tosEncodingType ?: @"";
    checkpoint.tos_uploadID = @"";
    checkpoint.tos_filePath = self.request.tosFilePath;
    checkpoint.tos_fileSize = self.tos_fileSize;
    checkpoint.tos_fileModifiedTime = self.tos_fileModifiedTime;
    return checkpoint;
}

- (void)tos_initializeRemoteState {
    if (self.request.tosCancelHook.tos_isCancelled) {
        [self tos_handleCancellation];
        return;
    }
    if (self.tos_staleCheckpoint.tos_uploadID.length > 0) {
        TOSUploadCheckpointV2 *staleCheckpoint = self.tos_staleCheckpoint;
        self.tos_remoteRequestInFlight = YES;
        [self tos_abortBucket:self.request.tosBucket
                          key:self.request.tosKey
                     uploadID:staleCheckpoint.tos_uploadID
          networkCancellation:[TOSTransferNetworkCancellation new]
                   completion:^(NSError *error) {
            self.tos_remoteRequestInFlight = NO;
            if (error && !TOSUploadV2IsNoSuchUpload(error)) {
                [self tos_finishWithOutput:nil error:error];
                return;
            }
            NSError *removeError = nil;
            if (![self.tos_checkpointStore removeCheckpoint:staleCheckpoint error:&removeError]) {
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

    NSError *checkpointError = nil;
    if (![self tos_persistCheckpoint:&checkpointError]) {
        [self tos_finishWithOutput:nil error:checkpointError];
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
                NSInteger statusCode = TOSUploadV2StatusCode(task.error);
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
                [strongSelf tos_emitEventType:TOSUploadEventCreateMultipartUploadFailed
                                         part:nil
                                        error:task.error];
                [strongSelf tos_finishWithOutput:nil error:task.error];
                return;
            }
            TOSCreateMultipartUploadOutput *output = task.result;
            if (![output isKindOfClass:[TOSCreateMultipartUploadOutput class]] || output.tosUploadID.length == 0) {
                NSError *error = TOSUploadV2Error(@"tos: create multipart upload returned an empty upload ID");
                [strongSelf tos_emitEventType:TOSUploadEventCreateMultipartUploadFailed part:nil error:error];
                [strongSelf tos_finishWithOutput:nil error:error];
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
            [strongSelf tos_emitEventType:TOSUploadEventCreateMultipartUploadSucceed part:nil error:nil];
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
    int64_t completedBytes = 0;
    for (TOSTransferPart *part in self.tos_checkpoint.tos_parts) {
        if (part.tos_completed) {
            completedBytes += part.tos_size;
        }
    }
    [self.tos_progress startWithTotal:self.tos_fileSize consumed:completedBytes];

    __weak typeof(self) weakSelf = self;
    [self.tos_partOperation.task continueWithBlock:^id(TOSTask *task) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return nil;
        }
        dispatch_async(strongSelf.tos_stateQueue, ^{
            if (strongSelf.tos_finished) {
                return;
            }
            if (strongSelf.request.tosCancelHook.tos_isCancelled) {
                [strongSelf tos_handleCancellation];
            } else if (task.error) {
                if (TOSUploadV2IsAbortStatus(task.error)) {
                    [strongSelf tos_abortAfterFatalPartError:task.error];
                } else {
                    [strongSelf tos_finishFailureCleaningMultipartIfNeeded:task.error];
                }
            } else {
                NSError *sourceError = [strongSelf tos_validateSourceUnchanged];
                if (sourceError) {
                    [strongSelf tos_finishFailureCleaningMultipartIfNeeded:sourceError];
                } else {
                    [strongSelf tos_completeMultipartUpload];
                }
            }
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
    NSError *streamError = nil;
    TOSFileRangeInputStream *stream = [[TOSFileRangeInputStream alloc]
                                       initWithBorrowedFileDescriptor:self.tos_sourceDescriptor
                                       offset:part.tos_offset
                                       length:part.tos_size
                                       rateLimiter:self.request.tosRateLimiter
                                       cancelHook:self.request.tosCancelHook
                                       error:&streamError];
    if (!stream) {
        [source setError:streamError ?: TOSUploadV2Error(@"tos: cannot create part input stream")];
        return source.task;
    }
    __weak typeof(self) weakSelf = self;
    __block int64_t attemptConsumed = 0;
    stream.tos_bytesRead = ^(int64_t bytes) {
        attemptConsumed += bytes;
        int64_t delta = 0;
        @synchronized (part) {
            if (attemptConsumed > part.tos_reportedBytes) {
                delta = attemptConsumed - part.tos_reportedBytes;
                part.tos_reportedBytes = attemptConsumed;
            }
        }
        [weakSelf.tos_progress recordBytes:delta];
    };

    TOSUploadPartFromStreamInput *input = [TOSUploadPartFromStreamInput new];
    TOSTransferResponseMetadata *responseMetadata = [TOSTransferResponseMetadata new];
    input.tosBucket = self.request.tosBucket;
    input.tosKey = self.request.tosKey;
    input.tosUploadID = self.tos_checkpoint.tos_uploadID;
    input.tosPartNumber = (int)part.tos_partNumber;
    input.tosInputStream = stream;
    input.tosContentLength = part.tos_size;
    NSMutableDictionary *headers = [NSMutableDictionary dictionaryWithObject:[NSString stringWithFormat:@"%lld", part.tos_size]
                                                                       forKey:@"Content-Length"];
    if (self.request.tosTrafficLimit > 0) {
        headers[@"x-tos-traffic-limit"] = [NSString stringWithFormat:@"%lld", self.request.tosTrafficLimit];
    }
    input.tos_transferHeaders = headers;
    input.tos_transferCancellation = networkCancellation;
    input.tos_responseObserver = TOSTransferRetryAfterObserver(responseMetadata);

    [[self.tos_client uploadPartFromStream:input] continueWithBlock:^id(TOSTask *task) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            [stream close];
            return nil;
        }
        dispatch_async(strongSelf.tos_stateQueue, ^{
            if (strongSelf.tos_finished) {
                [stream close];
                TOSTransferAttemptResult *result = [TOSTransferAttemptResult new];
                result.error = [NSError errorWithDomain:TOSClientErrorDomain
                                                    code:TOSClientErrorCodeTaskCancelled
                                                userInfo:@{TOSErrorMessageTOKEN: @"This task has been cancelled!"}];
                [source setResult:result];
                return;
            }
            TOSTransferAttemptResult *result = [TOSTransferAttemptResult new];
            NSError *error = task.error;
            TOSUploadPartFromStreamOutput *output = task.result;
            if (!error && ![output isKindOfClass:[TOSUploadPartFromStreamOutput class]]) {
                error = TOSUploadV2Error(@"tos: upload part returned an invalid response");
            }
            if (!error && stream.tos_consumed != part.tos_size) {
                error = TOSUploadV2Error(@"tos: upload part did not consume the expected byte range");
            }
            if (!error && output.tosETag.length == 0) {
                error = TOSUploadV2Error(@"tos: upload part response is missing ETag");
            }
            id crcHeader = !error ? TOSUploadV2HeaderValue(output, @"x-tos-hash-crc64ecma") : nil;
            if (!error && crcHeader && output.tosHashCrc64ecma != stream.tos_crc64) {
                error = TOSUploadV2Error(@"tos: crc of upload part mismatch");
            }

            if (!error) {
                BOOL previousCompleted = part.tos_completed;
                NSString *previousETag = part.tos_eTag;
                uint64_t previousCRC = part.tos_crc64;
                part.tos_completed = YES;
                part.tos_eTag = output.tosETag;
                part.tos_crc64 = stream.tos_crc64;
                NSError *writeError = nil;
                if (![strongSelf tos_persistCheckpoint:&writeError]) {
                    part.tos_completed = previousCompleted;
                    part.tos_eTag = previousETag;
                    part.tos_crc64 = previousCRC;
                    error = writeError;
                }
            }
            [stream close];

            result.error = error;
            result.statusCode = TOSUploadV2StatusCode(error);
            result.retryAfter = responseMetadata.retryAfter;
            if (!error) {
                result.value = part;
                [strongSelf tos_emitEventType:TOSUploadEventUploadPartSucceed part:part error:nil];
            } else if (!TOSUploadV2IsCancellationError(error) &&
                       !(TOSTransferShouldRetry(error, result.statusCode) &&
                         retryCount < strongSelf.request.tosMaxRetryCount)) {
                TOSUploadEventType type = TOSUploadV2IsAbortStatus(error)
                    ? TOSUploadEventUploadPartAborted : TOSUploadEventUploadPartFailed;
                [strongSelf tos_emitEventType:type part:part error:error];
            }
            [source setResult:result];
        });
        return nil;
    }];
    return source.task;
}

- (NSError *)tos_validateSourceUnchanged {
    struct stat descriptorStat;
    struct stat pathStat;
    if (fstat(self.tos_sourceDescriptor, &descriptorStat) != 0 ||
        stat(self.request.tosFilePath.fileSystemRepresentation, &pathStat) != 0) {
        return TOSUploadV2Error(@"tos: source file cannot be verified before complete");
    }
    if (descriptorStat.st_dev != self.tos_sourceDevice ||
        descriptorStat.st_ino != self.tos_sourceInode ||
        pathStat.st_dev != self.tos_sourceDevice ||
        pathStat.st_ino != self.tos_sourceInode ||
        descriptorStat.st_size != self.tos_fileSize ||
        TOSUploadV2ModifiedTime(descriptorStat) != self.tos_fileModifiedTime) {
        return TOSUploadV2Error(@"tos: source file changed during resumable upload");
    }
    return nil;
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
                TOSUploadV2Error(@"tos: cannot complete with unfinished parts")];
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
    input.tosCallback = self.request.tosCallback;
    input.tosCallbackVar = self.request.tosCallbackVar;
    input.tos_transferCancellation = self.tos_partOperation.networkCancellation;

    __weak typeof(self) weakSelf = self;
    [[self.tos_client completeMultipartUpload:input] continueWithBlock:^id(TOSTask *task) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return nil;
        }
        dispatch_async(strongSelf.tos_stateQueue, ^{
            if (strongSelf.tos_finished) {
                return;
            }
            if (task.error) {
                if (strongSelf.request.tosCancelHook.tos_isCancelled) {
                    [strongSelf tos_handleCancellation];
                    return;
                }
                [strongSelf tos_emitEventType:TOSUploadEventCompleteMultipartUploadFailed part:nil error:task.error];
                if (TOSUploadV2IsNoSuchUpload(task.error)) {
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
                                                                 strongSelf.request.tosCallback.length > 0);
            if (validationError) {
                [strongSelf tos_emitEventType:TOSUploadEventCompleteMultipartUploadFailed
                                         part:nil
                                        error:validationError];
                [strongSelf tos_finishFailureCleaningMultipartIfNeeded:validationError];
                return;
            }
            [strongSelf tos_removeCheckpoint];
            uint64_t combinedCRC = 0;
            for (TOSTransferPart *part in parts) {
                combinedCRC = TOSTransferCRC64Combine(combinedCRC, part.tos_crc64, (uintmax_t)part.tos_size);
            }
            if (TOSUploadV2HeaderValue(output, @"x-tos-hash-crc64ecma") &&
                combinedCRC != output.tosHashCrc64ecma) {
                NSError *error = TOSUploadV2Error(@"tos: crc of entire file mismatch");
                [strongSelf tos_emitEventType:TOSUploadEventCompleteMultipartUploadFailed part:nil error:error];
                [strongSelf tos_finishWithOutput:nil error:error];
                return;
            }

            [strongSelf tos_emitEventType:TOSUploadEventCompleteMultipartUploadSucceed part:nil error:nil];
            TOSUploadFileOutputV2 *result = [TOSUploadFileOutputV2 new];
            result.tosRequestID = output.tosRequestID;
            result.tosID2 = output.tosID2;
            result.tosStatusCode = output.tosStatusCode;
            result.tosHeader = output.tosHeader;
            result.tosBucket = strongSelf.request.tosBucket;
            result.tosKey = strongSelf.request.tosKey;
            result.tosUploadID = strongSelf.tos_checkpoint.tos_uploadID;
            result.tosETag = output.tosETag;
            result.tosLocation = output.tosLocation;
            result.tosVersionID = output.tosVersionID;
            result.tosHashCrc64ecma = output.tosHashCrc64ecma;
            result.tosEncodingType = strongSelf.request.tosEncodingType;
            result.tosCallbackResult = output.tosCallbackResult;
            [strongSelf tos_finishWithOutput:result error:nil];
        });
        return nil;
    }];
}

- (void)tos_handleCancellation {
    if (self.tos_finished || self.tos_cleanupInFlight) {
        return;
    }
    NSError *cancelError = TOSUploadV2Error(@"This task has been cancelled!");
    if (self.request.tosEnableCheckpoint && !self.request.tosCancelHook.tos_shouldAbort) {
        [self tos_finishWithOutput:nil error:cancelError];
        return;
    }
    TOSUploadCheckpointV2 *checkpointToAbort =
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
        if (error && !TOSUploadV2IsNoSuchUpload(error)) {
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
        if (abortError && !TOSUploadV2IsNoSuchUpload(abortError)) {
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
        if (abortError && !TOSUploadV2IsNoSuchUpload(abortError)) {
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

- (BOOL)tos_removeCheckpoint:(TOSUploadCheckpointV2 *)checkpoint
                       error:(NSError **)error {
    if (!self.request.tosEnableCheckpoint || checkpoint.tos_checkpointPath.length == 0) {
        return YES;
    }
    return [self.tos_checkpointStore removeCheckpoint:checkpoint error:error];
}

- (void)tos_emitEventType:(TOSUploadEventType)type
                      part:(TOSTransferPart *)part
                     error:(NSError *)error {
    if (!self.request.tosUploadEventListener) {
        return;
    }
    TOSUploadEvent *event = [TOSUploadEvent new];
    event.tosType = type;
    if (error) {
        event.tosErr = error;
    }
    event.tosBucket = self.request.tosBucket;
    event.tosKey = self.request.tosKey;
    event.tosUploadID = self.tos_checkpoint.tos_uploadID;
    event.tosFilePath = self.request.tosFilePath;
    event.tosCheckpointPath = self.tos_checkpoint.tos_checkpointPath;
    if (part) {
        TOSUploadPartInfo *partInfo = [TOSUploadPartInfo new];
        partInfo.tosPartNumber = (int)part.tos_partNumber;
        partInfo.tosPartSize = part.tos_size;
        partInfo.tosOffset = part.tos_offset;
        partInfo.tosETag = part.tos_eTag;
        partInfo.tosHashCrc64ecma = part.tos_crc64;
        partInfo.tosIsCompleted = part.tos_completed;
        event.tosUploadPartInfo = partInfo;
    }
    self.request.tosUploadEventListener(event);
}

- (void)tos_finishWithOutput:(TOSUploadFileOutputV2 *)output error:(NSError *)error {
    if (self.tos_finished) {
        return;
    }
    self.tos_finished = YES;
    if (self.tos_sourceDescriptor >= 0) {
        close(self.tos_sourceDescriptor);
        self.tos_sourceDescriptor = -1;
    }
    if (error) {
        [self.tos_progress fail];
    } else {
        [self.tos_progress finish];
    }
    [self.tos_progress waitUntilIdle];
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
