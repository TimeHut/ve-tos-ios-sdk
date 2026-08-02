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

#import "TOSDownloadFileOperation.h"
#import "TOSInput+TransferInternal.h"
#import "TOSTransferCheckpoint.h"
#import "TOSTransferIO.h"
#import "TOSTransferOperation.h"
#import <VeTOSiOSSDK/TOSClient.h>
#import <VeTOSiOSSDK/TOSUtil.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

@interface TOSClient (TransferConcurrencyInternal)
- (TOSTransferConcurrencyController *)tos_resumableTransferConcurrencyController;
@end

static NSError *TOSDownloadError(NSString *message) {
    return [NSError errorWithDomain:TOSClientErrorDomain
                               code:400
                           userInfo:@{TOSErrorMessageTOKEN: message ?: @"断点续传下载失败"}];
}

static NSInteger TOSDownloadStatusCode(NSError *error) {
    return [error.domain isEqualToString:TOSServerErrorDomain] ? error.code : 0;
}

static int64_t TOSDownloadDateValue(NSDate *date) {
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

static BOOL TOSDownloadIsFatalPartError(NSError *error) {
    NSInteger statusCode = TOSDownloadStatusCode(error);
    return statusCode == 403 || statusCode == 404 || statusCode == 405 || statusCode == 412;
}

static BOOL TOSDownloadPathIsSymlink(NSString *path) {
    struct stat fileStat;
    return path.length > 0 &&
           lstat(path.fileSystemRepresentation, &fileStat) == 0 &&
           S_ISLNK(fileStat.st_mode);
}

static BOOL TOSDownloadPathIsWithinDirectory(NSString *path, NSString *directory) {
    if ([path isEqualToString:directory]) {
        return YES;
    }
    NSString *prefix = [directory hasSuffix:@"/"] ? directory : [directory stringByAppendingString:@"/"];
    return [path hasPrefix:prefix];
}

static BOOL TOSDownloadPathHasSymlinkBelowDirectory(NSString *path, NSString *directory) {
    if (!TOSDownloadPathIsWithinDirectory(path, directory)) {
        return YES;
    }
    NSString *prefix = [directory hasSuffix:@"/"] ? directory : [directory stringByAppendingString:@"/"];
    NSString *relativePath = [path isEqualToString:directory] ? @"" : [path substringFromIndex:prefix.length];
    NSString *currentPath = directory;
    for (NSString *component in relativePath.pathComponents) {
        if (component.length == 0 || [component isEqualToString:@"/"]) {
            continue;
        }
        currentPath = [currentPath stringByAppendingPathComponent:component];
        struct stat fileStat;
        if (lstat(currentPath.fileSystemRepresentation, &fileStat) == 0) {
            if (S_ISLNK(fileStat.st_mode)) {
                return YES;
            }
            continue;
        }
        if (errno == ENOENT) {
            break;
        }
        return YES;
    }
    return NO;
}

static BOOL TOSDownloadIsValidFileName(NSString *fileName) {
    return fileName.length > 0 &&
           ![fileName isEqualToString:@"."] &&
           ![fileName isEqualToString:@".."] &&
           [fileName rangeOfString:@"/"].location == NSNotFound;
}

static BOOL TOSDownloadRemoveFileAtIfIdentity(int directoryFileDescriptor,
                                              NSString *fileName,
                                              uint64_t expectedDevice,
                                              uint64_t expectedInode) {
    return TOSTransferRemoveFileAtIfIdentity(directoryFileDescriptor,
                                             fileName,
                                             expectedDevice,
                                             expectedInode);
}

static int TOSDownloadDuplicateDirectoryDescriptor(int directoryFileDescriptor, NSError **error) {
    int duplicatedDescriptor = fcntl(directoryFileDescriptor, F_DUPFD_CLOEXEC, 0);
    if (duplicatedDescriptor < 0 && error) {
        *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
    }
    return duplicatedDescriptor;
}

static int TOSDownloadOpenAbsoluteDirectory(NSString *directory, NSError **error) {
    NSString *standardized = [[NSURL fileURLWithPath:directory] URLByStandardizingPath].path;
    if (![standardized hasPrefix:@"/"]) {
        if (error) {
            *error = TOSDownloadError(@"tos: download directory must be an absolute path");
        }
        return -1;
    }
    int directoryFileDescriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (directoryFileDescriptor < 0) {
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        }
        return -1;
    }
    for (NSString *component in standardized.pathComponents) {
        if ([component isEqualToString:@"/"] || component.length == 0) {
            continue;
        }
        if ([component isEqualToString:@"."] || [component isEqualToString:@".."]) {
            close(directoryFileDescriptor);
            if (error) {
                *error = TOSDownloadError(@"tos: download directory contains an invalid component");
            }
            return -1;
        }
        int nextDescriptor = openat(directoryFileDescriptor,
                                    component.fileSystemRepresentation,
                                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (nextDescriptor < 0) {
            int posixError = errno;
            close(directoryFileDescriptor);
            if (error) {
                *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:posixError userInfo:nil];
            }
            return -1;
        }
        close(directoryFileDescriptor);
        directoryFileDescriptor = nextDescriptor;
    }
    return directoryFileDescriptor;
}

static int TOSDownloadOpenRelativeDirectory(int rootDirectoryFileDescriptor,
                                            NSString *relativeDirectory,
                                            BOOL create,
                                            NSError **error) {
    int directoryFileDescriptor = TOSDownloadDuplicateDirectoryDescriptor(rootDirectoryFileDescriptor, error);
    if (directoryFileDescriptor < 0) {
        return -1;
    }
    for (NSString *component in relativeDirectory.pathComponents) {
        if ([component isEqualToString:@"/"] ||
            [component isEqualToString:@"."] ||
            component.length == 0) {
            continue;
        }
        if ([component isEqualToString:@".."]) {
            close(directoryFileDescriptor);
            if (error) {
                *error = TOSDownloadError(@"tos: download directory contains an invalid component");
            }
            return -1;
        }
        if (create &&
            mkdirat(directoryFileDescriptor, component.fileSystemRepresentation, 0755) != 0 &&
            errno != EEXIST) {
            int posixError = errno;
            close(directoryFileDescriptor);
            if (error) {
                *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:posixError userInfo:nil];
            }
            return -1;
        }
        int nextDescriptor = openat(directoryFileDescriptor,
                                    component.fileSystemRepresentation,
                                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (nextDescriptor < 0) {
            int posixError = errno;
            close(directoryFileDescriptor);
            if (error) {
                *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:posixError userInfo:nil];
            }
            return -1;
        }
        close(directoryFileDescriptor);
        directoryFileDescriptor = nextDescriptor;
    }
    return directoryFileDescriptor;
}

@class TOSDownloadFileOperation;

@interface TOSDownloadPartOperation : TOSTransferOperation
@property (nonatomic, weak) TOSDownloadFileOperation *tos_owner;
@end

@interface TOSDownloadFileOperation ()
@property (nonatomic, strong) TOSClient *tos_client;
@property (nonatomic, strong) TOSTaskCompletionSource<TOSDownloadFileOutput *> *tos_taskSource;
@property (nonatomic, strong, readwrite) TOSTask<TOSDownloadFileOutput *> *task;
@property (nonatomic, strong, readwrite) TOSDownloadFileInput *request;
@property (nonatomic, strong) TOSDownloadFileOperation *tos_lifetimeAnchor;
@property (nonatomic, strong) dispatch_queue_t tos_stateQueue;
@property (nonatomic, strong) TOSDownloadPartOperation *tos_partOperation;
@property (nonatomic, strong) TOSTransferCheckpointStore *tos_checkpointStore;
@property (nonatomic, strong) TOSTransferCheckpointLease *tos_checkpointLease;
@property (nonatomic, strong) TOSDownloadCheckpoint *tos_checkpoint;
@property (nonatomic, strong) TOSDownloadFileWriter *tos_writer;
@property (nonatomic, strong) TOSTransferProgress *tos_progress;
@property (nonatomic, strong) TOSHeadObjectOutput *tos_headOutput;
@property (nonatomic, copy) NSString *tos_finalPath;
@property (nonatomic, copy) NSString *tos_finalFileName;
@property (nonatomic, copy) NSString *tos_destinationDirectory;
@property (nonatomic, copy) NSString *tos_tempPath;
@property (nonatomic, copy) NSString *tos_tempFileName;
@property (nonatomic, copy) NSString *tos_checkpointPath;
@property (nonatomic, copy) NSString *tos_effectiveIfMatch;
@property (nonatomic, assign) int64_t tos_objectSize;
@property (nonatomic, assign) dev_t tos_tempDevice;
@property (nonatomic, assign) ino_t tos_tempInode;
@property (nonatomic, assign) int tos_finalParentDescriptor;
@property (nonatomic, assign) int tos_tempParentDescriptor;
@property (nonatomic, assign) BOOL tos_hasTempIdentity;
@property (nonatomic, assign) BOOL tos_userProvidedTempPath;
@property (nonatomic, assign) BOOL tos_started;
@property (nonatomic, assign) BOOL tos_finished;
- (NSArray<TOSTransferPart *> *)tos_pendingParts;
- (TOSTask<TOSTransferAttemptResult *> *)tos_attemptPart:(TOSTransferPart *)part
                                              retryCount:(NSInteger)retryCount
                                     networkCancellation:(TOSTransferNetworkCancellation *)networkCancellation;
- (NSError *)tos_captureTempIdentityExpectedDevice:(uint64_t)expectedDevice
                                     expectedInode:(uint64_t)expectedInode
                                  updateCheckpoint:(BOOL)updateCheckpoint;
- (TOSDownloadFileWriter *)tos_resumeWriterForCheckpoint:(TOSDownloadCheckpoint *)checkpoint
                                                    error:(NSError **)error;
- (void)tos_closeDirectoryDescriptors;
@end

@implementation TOSDownloadPartOperation

- (NSArray *)tos_pendingItems {
    return [self.tos_owner tos_pendingParts];
}

- (TOSTask<TOSTransferAttemptResult *> *)tos_attemptItem:(id)item
                                              retryCount:(NSInteger)retryCount
                                     networkCancellation:(TOSTransferNetworkCancellation *)networkCancellation {
    return [self.tos_owner tos_attemptPart:item retryCount:retryCount networkCancellation:networkCancellation];
}

@end

@implementation TOSDownloadFileOperation

- (instancetype)initWithClient:(TOSClient *)client request:(TOSDownloadFileInput *)request {
    self = [super init];
    if (self) {
        _tos_client = client;
        _request = [self tos_snapshotRequest:request];
        _tos_taskSource = [TOSTaskCompletionSource taskCompletionSource];
        _task = _tos_taskSource.task;
        _tos_stateQueue = dispatch_queue_create("com.volces.tos.transfer.download", DISPATCH_QUEUE_SERIAL);
        _tos_checkpointStore = [[TOSTransferCheckpointStore alloc] init];
        _tos_progress = [[TOSTransferProgress alloc] initWithListener:_request.tosDataTransferListener];
        _tos_finalParentDescriptor = -1;
        _tos_tempParentDescriptor = -1;
    }
    return self;
}

- (TOSDownloadFileInput *)tos_snapshotRequest:(TOSDownloadFileInput *)request {
    TOSDownloadFileInput *snapshot = [TOSDownloadFileInput new];
    snapshot.isCancelled = request.isCancelled;
    snapshot.tosBucket = request.tosBucket;
    snapshot.tosKey = request.tosKey;
    snapshot.tosVersionID = request.tosVersionID;
    snapshot.tosIfMatch = request.tosIfMatch;
    snapshot.tosIfModifiedSince = [request.tosIfModifiedSince copy];
    snapshot.tosIfNoneMatch = request.tosIfNoneMatch;
    snapshot.tosIfUnmodifiedSince = [request.tosIfUnmodifiedSince copy];
    snapshot.tosSSECAlgorithm = request.tosSSECAlgorithm;
    snapshot.tosSSECKey = request.tosSSECKey;
    snapshot.tosSSECKeyMD5 = request.tosSSECKeyMD5;
    snapshot.tosFilePath = request.tosFilePath;
    snapshot.tosTempFilePath = request.tosTempFilePath;
    snapshot.tosPartSize = request.tosPartSize;
    snapshot.tosTaskNum = request.tosTaskNum;
    snapshot.tosEnableCheckpoint = request.tosEnableCheckpoint;
    snapshot.tosCheckpointFile = request.tosCheckpointFile;
    snapshot.tosDataTransferListener = request.tosDataTransferListener;
    snapshot.tosDownloadEventListener = request.tosDownloadEventListener;
    snapshot.tosRateLimiter = request.tosRateLimiter;
    snapshot.tosCancelHook = request.tosCancelHook;
    snapshot.tosTrafficLimit = request.tosTrafficLimit;
    snapshot.tosMaxRetryCount = request.tosMaxRetryCount;
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

        TOSTransferProgress *schedulerProgress = [[TOSTransferProgress alloc] initWithListener:nil];
        self.tos_partOperation = [[TOSDownloadPartOperation alloc]
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
                [strongSelf tos_partSchedulerFinished:task];
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
    if (![TOSUtil isNotEmptyString:self.request.tosFilePath]) {
        return TOSDownloadError(@"tos: invalid download file path");
    }
    NSError *error = nil;
    if (!self.tos_client.clientConfiguration.tosEndpoint.isCustomDomain &&
        ![TOSUtil isValidBucketName:self.request.tosBucket withError:&error]) {
        return error;
    }
    if (![TOSUtil isValidObjectName:self.request.tosKey withError:&error]) {
        return error;
    }
    if (self.request.tosPartSize == 0) {
        self.request.tosPartSize = TOSDefaultPartSize;
    }
    if (self.request.tosPartSize < TOSMinPartSize || self.request.tosPartSize > TOSMaxPartSize) {
        return TOSDownloadError(@"tos: invalid part size, the size must be [5242880, 5368709120]");
    }
    self.request.tosTaskNum = (int)TOSNormalizeResumableTransferTaskNum(self.request.tosTaskNum);
    if (self.request.tosMaxRetryCount < 0) {
        return TOSDownloadError(@"tos: max retry count must not be negative");
    }
    if (self.request.tosTrafficLimit < 0) {
        return TOSDownloadError(@"tos: traffic limit must not be negative");
    }
    if (self.request.tosSSECAlgorithm.length > 0 ||
        self.request.tosSSECKey.length > 0 ||
        self.request.tosSSECKeyMD5.length > 0) {
        return TOSDownloadError(@"断点续传下载不支持 SSE 相关参数");
    }
    return nil;
}

- (TOSHeadObjectInput *)tos_headInput {
    TOSHeadObjectInput *input = [TOSHeadObjectInput new];
    input.tosBucket = self.request.tosBucket;
    input.tosKey = self.request.tosKey;
    input.tosVersionID = self.request.tosVersionID;
    input.tosIfMatch = self.request.tosIfMatch;
    input.tosIfModifiedSince = self.request.tosIfModifiedSince;
    input.tosIfNoneMatch = self.request.tosIfNoneMatch;
    input.tosIfUnmodifiedSince = self.request.tosIfUnmodifiedSince;
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    if (self.request.tosIfMatch.length > 0) {
        headers[@"If-Match"] = self.request.tosIfMatch;
    }
    if (self.request.tosIfNoneMatch.length > 0) {
        headers[@"If-None-Match"] = self.request.tosIfNoneMatch;
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
            if (strongSelf.tos_finished) {
                return;
            }
            if (task.error) {
                if (strongSelf.request.tosCancelHook.tos_isCancelled) {
                    [strongSelf tos_handleCancellation];
                    return;
                }
                NSInteger statusCode = TOSDownloadStatusCode(task.error);
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
            if (![output isKindOfClass:[TOSHeadObjectOutput class]] ||
                output.tosContentLength < 0 || output.tosSymlinkTargetSize < 0) {
                [strongSelf tos_finishWithOutput:nil error:TOSDownloadError(@"tos: head object returned an invalid response")];
                return;
            }
            strongSelf.tos_headOutput = output;
            strongSelf.tos_objectSize = output.tosSymlinkTargetSize > 0
                ? output.tosSymlinkTargetSize : output.tosContentLength;
            strongSelf.tos_effectiveIfMatch = strongSelf.request.tosIfMatch.length > 0
                ? strongSelf.request.tosIfMatch : (output.tosETag ?: @"");
            NSError *prepareError = [strongSelf tos_prepareLocalState];
            if (prepareError) {
                [strongSelf tos_finishWithOutput:nil error:prepareError];
                return;
            }
            if (strongSelf.tos_finished) {
                return;
            }
            [strongSelf tos_startParts];
        });
        return nil;
    }];
}

- (NSError *)tos_prepareLocalState {
    NSString *requestedPath = [[NSURL fileURLWithPath:self.request.tosFilePath] URLByStandardizingPath].path;
    BOOL isDirectory = NO;
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:requestedPath isDirectory:&isDirectory];
    if (!exists && [self.request.tosFilePath hasSuffix:@"/"]) {
        isDirectory = YES;
    }
    if (isDirectory) {
        NSError *directoryError = nil;
        if (!exists && ![[NSFileManager defaultManager] createDirectoryAtPath:requestedPath
                                                   withIntermediateDirectories:YES
                                                                    attributes:nil
                                                                         error:&directoryError]) {
            return directoryError;
        }
        requestedPath = [[NSURL fileURLWithPath:requestedPath] URLByResolvingSymlinksInPath].path;
        self.tos_destinationDirectory = requestedPath;
        NSString *candidate = [[NSURL fileURLWithPath:[requestedPath stringByAppendingPathComponent:self.request.tosKey]]
                               URLByStandardizingPath].path;
        if (!TOSDownloadPathIsWithinDirectory(candidate, requestedPath)) {
            return TOSDownloadError(@"tos: resolved download path escapes the supplied directory");
        }
        if (TOSDownloadPathHasSymlinkBelowDirectory(candidate, requestedPath)) {
            return TOSDownloadError(@"tos: resolved download path contains a symbolic link");
        }
        self.tos_finalPath = candidate;
        if ([self.request.tosKey hasSuffix:@"/"]) {
            NSError *markerError = nil;
            if (![[NSFileManager defaultManager] createDirectoryAtPath:candidate
                                            withIntermediateDirectories:YES
                                                             attributes:nil
                                                                 error:&markerError]) {
                return markerError;
            }
            if (TOSDownloadPathHasSymlinkBelowDirectory(candidate, requestedPath)) {
                return TOSDownloadError(@"tos: resolved download path contains a symbolic link");
            }
            [self tos_finishWithOutput:[self tos_outputFromHead] error:nil];
            return nil;
        }
    } else {
        self.tos_finalPath = requestedPath;
    }
    self.request.tosFilePath = self.tos_finalPath;
    if (TOSDownloadPathIsSymlink(self.tos_finalPath)) {
        return TOSDownloadError(@"tos: download destination must not be a symlink");
    }

    NSError *error = nil;
    NSString *finalParent = self.tos_finalPath.stringByDeletingLastPathComponent;
    self.tos_finalFileName = self.tos_finalPath.lastPathComponent;
    if (!TOSDownloadIsValidFileName(self.tos_finalFileName)) {
        return TOSDownloadError(@"tos: invalid download destination file name");
    }
    if (self.tos_destinationDirectory.length > 0) {
        int rootDirectoryFileDescriptor =
            TOSDownloadOpenAbsoluteDirectory(self.tos_destinationDirectory, &error);
        if (rootDirectoryFileDescriptor < 0) {
            return error;
        }
        NSString *prefix = [self.tos_destinationDirectory hasSuffix:@"/"]
            ? self.tos_destinationDirectory
            : [self.tos_destinationDirectory stringByAppendingString:@"/"];
        NSString *relativeParent = [finalParent isEqualToString:self.tos_destinationDirectory]
            ? @""
            : [finalParent substringFromIndex:prefix.length];
        self.tos_finalParentDescriptor =
            TOSDownloadOpenRelativeDirectory(rootDirectoryFileDescriptor,
                                             relativeParent,
                                             YES,
                                             &error);
        close(rootDirectoryFileDescriptor);
        if (self.tos_finalParentDescriptor < 0) {
            return error;
        }
    } else {
        if (![[NSFileManager defaultManager] createDirectoryAtPath:finalParent
                                       withIntermediateDirectories:YES
                                                        attributes:nil
                                                             error:&error]) {
            return error;
        }
        NSString *resolvedFinalParent =
            [[NSURL fileURLWithPath:finalParent] URLByResolvingSymlinksInPath].path;
        self.tos_finalParentDescriptor = TOSDownloadOpenAbsoluteDirectory(resolvedFinalParent, &error);
        if (self.tos_finalParentDescriptor < 0) {
            return error;
        }
    }

    TOSDownloadCheckpoint *loadedCheckpoint = nil;
    if (self.request.tosEnableCheckpoint) {
        self.tos_checkpointPath = TOSDownloadCheckpointPath(self.request.tosCheckpointFile,
                                                            self.tos_finalPath,
                                                            self.request.tosBucket,
                                                            self.request.tosKey,
                                                            self.request.tosVersionID,
                                                            &error);
        if (!self.tos_checkpointPath) {
            return error;
        }
        self.request.tosCheckpointFile = self.tos_checkpointPath;
        self.tos_checkpointLease =
            [TOSTransferCheckpointLease acquireCheckpointPath:self.tos_checkpointPath error:&error];
        if (!self.tos_checkpointLease) {
            return error ?: TOSDownloadError(@"tos: checkpoint is already in use");
        }
        if ([[NSFileManager defaultManager] fileExistsAtPath:self.tos_checkpointPath]) {
            NSData *data = [NSData dataWithContentsOfFile:self.tos_checkpointPath options:0 error:&error];
            if (!data) {
                return error;
            }
            loadedCheckpoint = [TOSDownloadCheckpoint tos_checkpointWithData:data
                                                               checkpointPath:self.tos_checkpointPath
                                                                          error:&error];
            if (!loadedCheckpoint) {
                return TOSDownloadError(@"已有 checkpoint 不是兼容的下载 JSON，已拒绝覆盖");
            }
            if (![loadedCheckpoint.tos_bucket isEqualToString:self.request.tosBucket] ||
                ![loadedCheckpoint.tos_key isEqualToString:self.request.tosKey] ||
                ![loadedCheckpoint.tos_versionID isEqualToString:self.request.tosVersionID ?: @""] ||
                ![loadedCheckpoint.tos_filePath isEqualToString:self.tos_finalPath]) {
                return TOSDownloadError(@"checkpoint 属于其他下载目标，已拒绝修改本地状态");
            }
        }
    } else {
        self.tos_checkpointPath = @"";
    }

    self.tos_userProvidedTempPath = self.request.tosTempFilePath.length > 0;
    if (self.tos_userProvidedTempPath) {
        self.tos_tempPath = [[NSURL fileURLWithPath:self.request.tosTempFilePath] URLByStandardizingPath].path;
    } else if (loadedCheckpoint.tos_tempFilePath.length > 0 &&
               [self tos_canRemoveOwnedTempPath:loadedCheckpoint.tos_tempFilePath]) {
        self.tos_tempPath = loadedCheckpoint.tos_tempFilePath;
    } else {
        self.tos_tempPath = [NSString stringWithFormat:@"%@.temp.%@", self.tos_finalPath, NSUUID.UUID.UUIDString];
    }
    self.request.tosTempFilePath = self.tos_tempPath;
    if ([self.tos_tempPath isEqualToString:self.tos_finalPath] || TOSDownloadPathIsSymlink(self.tos_tempPath)) {
        return TOSDownloadError(@"tos: invalid or symlink download temporary path");
    }

    NSString *tempParent = self.tos_tempPath.stringByDeletingLastPathComponent;
    self.tos_tempFileName = self.tos_tempPath.lastPathComponent;
    if (!TOSDownloadIsValidFileName(self.tos_tempFileName)) {
        return TOSDownloadError(@"tos: invalid download temporary file name");
    }
    if ([tempParent isEqualToString:finalParent]) {
        self.tos_tempParentDescriptor =
            TOSDownloadDuplicateDirectoryDescriptor(self.tos_finalParentDescriptor, &error);
    } else {
        if (![[NSFileManager defaultManager] createDirectoryAtPath:tempParent
                                       withIntermediateDirectories:YES
                                                        attributes:nil
                                                             error:&error]) {
            return error;
        }
        NSString *resolvedTempParent =
            [[NSURL fileURLWithPath:tempParent] URLByResolvingSymlinksInPath].path;
        self.tos_tempParentDescriptor = TOSDownloadOpenAbsoluteDirectory(resolvedTempParent, &error);
    }
    if (self.tos_tempParentDescriptor < 0) {
        return error;
    }
    struct stat finalParentStat;
    struct stat tempParentStat;
    if (fstat(self.tos_finalParentDescriptor, &finalParentStat) != 0 ||
        fstat(self.tos_tempParentDescriptor, &tempParentStat) != 0) {
        return [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
    }
    if (finalParentStat.st_dev != tempParentStat.st_dev) {
        return TOSDownloadError(@"tos: final file and temporary file must be on the same file system");
    }

    if (loadedCheckpoint) {
        int64_t actualTempSize = -1;
        struct stat tempStat;
        BOOL hasActualTempIdentity =
            fstatat(self.tos_tempParentDescriptor,
                    self.tos_tempFileName.fileSystemRepresentation,
                    &tempStat,
                    AT_SYMLINK_NOFOLLOW) == 0 &&
            S_ISREG(tempStat.st_mode);
        if (hasActualTempIdentity) {
            actualTempSize = tempStat.st_size;
        }
        BOOL checkpointTempIdentityMatches =
            loadedCheckpoint.tos_hasTempFileIdentity &&
            hasActualTempIdentity &&
            loadedCheckpoint.tos_tempFileDevice == (uint64_t)tempStat.st_dev &&
            loadedCheckpoint.tos_tempFileInode == (uint64_t)tempStat.st_ino;
        if (checkpointTempIdentityMatches &&
            [loadedCheckpoint tos_validateForBucket:self.request.tosBucket
                                                key:self.request.tosKey
                                          versionID:self.request.tosVersionID
                                           partSize:self.request.tosPartSize
                                           filePath:self.tos_finalPath
                                       tempFilePath:self.tos_tempPath
                                            ifMatch:self.request.tosIfMatch
                                    ifModifiedSince:TOSDownloadDateValue(self.request.tosIfModifiedSince)
                                        ifNoneMatch:self.request.tosIfNoneMatch
                                  ifUnmodifiedSince:TOSDownloadDateValue(self.request.tosIfUnmodifiedSince)
                                         objectETag:self.tos_headOutput.tosETag ?: @""
                                 objectLastModified:TOSDownloadDateValue(self.tos_headOutput.tosLastModified)
                                         objectSize:self.tos_objectSize
                                        objectCRC64:self.tos_headOutput.tosHashCrc64ecma
                                 actualTempFileSize:actualTempSize
                                              error:&error]) {
            self.tos_checkpoint = loadedCheckpoint;
            self.tos_writer = [self tos_resumeWriterForCheckpoint:loadedCheckpoint error:&error];
            if (!self.tos_writer) {
                [self tos_emitEventType:TOSDownloadEventCreateTempFileFailed part:nil error:error];
                return error;
            }
            error = [self tos_captureTempIdentityExpectedDevice:loadedCheckpoint.tos_tempFileDevice
                                                  expectedInode:loadedCheckpoint.tos_tempFileInode
                                               updateCheckpoint:NO];
            if (error) {
                [self tos_emitEventType:TOSDownloadEventCreateTempFileFailed part:nil error:error];
                return error;
            }
            return nil;
        }
        if (![self.tos_checkpointStore removeCheckpoint:loadedCheckpoint error:&error]) {
            return error ?: TOSDownloadError(@"tos: cannot replace stale download checkpoint");
        }
        if ([self tos_canRemoveOwnedTempPath:loadedCheckpoint.tos_tempFilePath] &&
            loadedCheckpoint.tos_hasTempFileIdentity &&
            self.tos_tempParentDescriptor >= 0 &&
            TOSDownloadIsValidFileName(self.tos_tempFileName)) {
            TOSDownloadRemoveFileAtIfIdentity(self.tos_tempParentDescriptor,
                                              self.tos_tempFileName,
                                              loadedCheckpoint.tos_tempFileDevice,
                                              loadedCheckpoint.tos_tempFileInode);
        }
        if (!self.tos_userProvidedTempPath) {
            self.tos_tempPath = [NSString stringWithFormat:@"%@.temp.%@", self.tos_finalPath, NSUUID.UUID.UUIDString];
            self.request.tosTempFilePath = self.tos_tempPath;
            self.tos_tempFileName = self.tos_tempPath.lastPathComponent;
        }
    }

    NSArray<TOSTransferPart *> *parts = TOSDownloadParts(self.tos_objectSize,
                                                         self.request.tosPartSize,
                                                         &error);
    if (!parts) {
        return error ?: TOSDownloadError(@"tos: cannot plan download parts");
    }
    self.tos_checkpoint = [self tos_newCheckpointWithParts:parts];
    self.tos_writer = [[TOSDownloadFileWriter alloc]
                       initWithDirectoryFileDescriptor:self.tos_tempParentDescriptor
                       fileName:self.tos_tempFileName
                       size:self.tos_objectSize
                       rateLimiter:self.request.tosRateLimiter
                       cancelHook:self.request.tosCancelHook
                       error:&error];
    if (!self.tos_writer) {
        [self tos_emitEventType:TOSDownloadEventCreateTempFileFailed part:nil error:error];
        return error;
    }
    error = [self tos_captureTempIdentityExpectedDevice:0
                                          expectedInode:0
                                       updateCheckpoint:YES];
    if (error) {
        [self tos_emitEventType:TOSDownloadEventCreateTempFileFailed part:nil error:error];
        return error;
    }
    if (![self tos_persistCheckpoint:&error]) {
        [self.tos_writer close];
        TOSDownloadRemoveFileAtIfIdentity(self.tos_tempParentDescriptor,
                                          self.tos_tempFileName,
                                          (uint64_t)self.tos_tempDevice,
                                          (uint64_t)self.tos_tempInode);
        [self tos_emitEventType:TOSDownloadEventCreateTempFileFailed part:nil error:error];
        return error;
    }
    [self tos_emitEventType:TOSDownloadEventCreateTempFileSucceed part:nil error:nil];
    return nil;
}

- (TOSDownloadFileWriter *)tos_resumeWriterForCheckpoint:(TOSDownloadCheckpoint *)checkpoint
                                                    error:(NSError **)error {
    return [[TOSDownloadFileWriter alloc]
            initWithDirectoryFileDescriptor:self.tos_tempParentDescriptor
            fileName:self.tos_tempFileName
            size:self.tos_objectSize
            expectedDevice:checkpoint.tos_tempFileDevice
            expectedInode:checkpoint.tos_tempFileInode
            rateLimiter:self.request.tosRateLimiter
            cancelHook:self.request.tosCancelHook
            error:error];
}

- (NSError *)tos_captureTempIdentityExpectedDevice:(uint64_t)expectedDevice
                                     expectedInode:(uint64_t)expectedInode
                                  updateCheckpoint:(BOOL)updateCheckpoint {
    if (!self.tos_writer) {
        return TOSDownloadError(@"tos: download temporary file is not open");
    }
    struct stat fileStat;
    if (fstat(self.tos_writer.tos_fileDescriptor, &fileStat) != 0) {
        return [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
    }
    if (!S_ISREG(fileStat.st_mode) ||
        fileStat.st_size != self.tos_objectSize ||
        (expectedInode != 0 &&
         ((uint64_t)fileStat.st_dev != expectedDevice ||
          (uint64_t)fileStat.st_ino != expectedInode))) {
        return TOSDownloadError(@"tos: download temporary file has an invalid identity");
    }
    self.tos_tempDevice = fileStat.st_dev;
    self.tos_tempInode = fileStat.st_ino;
    self.tos_hasTempIdentity = YES;
    if (updateCheckpoint) {
        self.tos_checkpoint.tos_hasTempFileIdentity = YES;
        self.tos_checkpoint.tos_tempFileDevice = (uint64_t)fileStat.st_dev;
        self.tos_checkpoint.tos_tempFileInode = (uint64_t)fileStat.st_ino;
    }
    return nil;
}

- (BOOL)tos_canRemoveOwnedTempPath:(NSString *)path {
    if (path.length == 0 || [path isEqualToString:self.tos_finalPath]) {
        return NO;
    }
    NSString *standardized = [[NSURL fileURLWithPath:path] URLByStandardizingPath].path;
    if (self.tos_userProvidedTempPath) {
        NSString *configured = [[NSURL fileURLWithPath:self.request.tosTempFilePath] URLByStandardizingPath].path;
        return [standardized isEqualToString:configured];
    }
    NSString *prefix = [self.tos_finalPath stringByAppendingString:@".temp."];
    return [standardized hasPrefix:prefix] &&
           [standardized.stringByDeletingLastPathComponent isEqualToString:self.tos_finalPath.stringByDeletingLastPathComponent];
}

- (TOSDownloadCheckpoint *)tos_newCheckpointWithParts:(NSArray<TOSTransferPart *> *)parts {
    TOSDownloadCheckpoint *checkpoint = [TOSDownloadCheckpoint new];
    checkpoint.tos_schemaVersion = 1;
    checkpoint.tos_operation = @"download";
    checkpoint.tos_bucket = self.request.tosBucket;
    checkpoint.tos_key = self.request.tosKey;
    checkpoint.tos_partSize = self.request.tosPartSize;
    checkpoint.tos_checkpointPath = self.tos_checkpointPath ?: @"";
    checkpoint.tos_parts = parts;
    checkpoint.tos_versionID = self.request.tosVersionID ?: @"";
    checkpoint.tos_ifMatch = self.request.tosIfMatch ?: @"";
    checkpoint.tos_ifModifiedSince = TOSDownloadDateValue(self.request.tosIfModifiedSince);
    checkpoint.tos_ifNoneMatch = self.request.tosIfNoneMatch ?: @"";
    checkpoint.tos_ifUnmodifiedSince = TOSDownloadDateValue(self.request.tosIfUnmodifiedSince);
    checkpoint.tos_objectETag = self.tos_headOutput.tosETag ?: @"";
    checkpoint.tos_objectLastModified = TOSDownloadDateValue(self.tos_headOutput.tosLastModified);
    checkpoint.tos_objectSize = self.tos_objectSize;
    checkpoint.tos_objectCRC64 = self.tos_headOutput.tosHashCrc64ecma;
    checkpoint.tos_filePath = self.tos_finalPath;
    checkpoint.tos_tempFilePath = self.tos_tempPath;
    return checkpoint;
}

- (BOOL)tos_persistCheckpoint:(NSError **)error {
    if (!self.request.tosEnableCheckpoint) {
        return YES;
    }
    return [self.tos_checkpointStore writeCheckpoint:self.tos_checkpoint error:error];
}

- (void)tos_startParts {
    int64_t completedBytes = 0;
    for (TOSTransferPart *part in self.tos_checkpoint.tos_parts) {
        if (part.tos_completed) {
            completedBytes += part.tos_size;
        }
    }
    [self.tos_progress startWithTotal:self.tos_objectSize consumed:completedBytes];
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
    NSError *writerError = nil;
    TOSDownloadPartWriter *partWriter = [self.tos_writer partWriterWithOffset:part.tos_offset
                                                                        length:part.tos_size
                                                                         error:&writerError];
    if (!partWriter) {
        [source setError:writerError ?: TOSDownloadError(@"tos: cannot create download part writer")];
        return source.task;
    }
    __weak typeof(self) weakSelf = self;
    __block int64_t attemptConsumed = 0;
    partWriter.tos_bytesWritten = ^(int64_t bytes) {
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

    TOSGetObjectInput *input = [TOSGetObjectInput new];
    TOSTransferResponseMetadata *responseMetadata = [TOSTransferResponseMetadata new];
    input.tosBucket = self.request.tosBucket;
    input.tosKey = self.request.tosKey;
    input.tosVersionID = self.request.tosVersionID;
    input.tosIfMatch = self.tos_effectiveIfMatch;
    input.tosIfModifiedSince = self.request.tosIfModifiedSince;
    input.tosIfNoneMatch = self.request.tosIfNoneMatch;
    input.tosIfUnmodifiedSince = self.request.tosIfUnmodifiedSince;
    input.tosRangeStart = part.tos_rangeStart;
    input.tosRangeEnd = part.tos_rangeEnd;
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    headers[@"Range"] = [NSString stringWithFormat:@"bytes=%lld-%lld",
                           part.tos_rangeStart, part.tos_rangeEnd];
    if (self.tos_effectiveIfMatch.length > 0) {
        headers[@"If-Match"] = self.tos_effectiveIfMatch;
    }
    if (self.request.tosIfNoneMatch.length > 0) {
        headers[@"If-None-Match"] = self.request.tosIfNoneMatch;
    }
    if (self.request.tosTrafficLimit > 0) {
        headers[@"x-tos-traffic-limit"] = [NSString stringWithFormat:@"%lld", self.request.tosTrafficLimit];
    }
    input.tos_transferHeaders = headers;
    input.tos_transferCancellation = networkCancellation;
    input.tos_responseObserver = TOSTransferRetryAfterObserver(responseMetadata);
    input.tos_responseValidator = TOSTransferRangeResponseValidator(part.tos_rangeStart,
                                                                     part.tos_rangeEnd);

    NSLock *callbackLock = [NSLock new];
    __block NSError *callbackError = nil;
    input.tosOnReceiveData = ^(NSData *data) {
        [callbackLock lock];
        if (!callbackError) {
            NSError *error = nil;
            if (![partWriter writeData:data error:&error]) {
                callbackError = error ?: TOSDownloadError(@"tos: cannot write download data");
            }
        }
        BOOL shouldCancel = callbackError != nil;
        [callbackLock unlock];
        if (shouldCancel) {
            [networkCancellation cancel];
        }
    };

    [[self.tos_client getObject:input] continueWithBlock:^id(TOSTask *task) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return nil;
        }
        dispatch_async(strongSelf.tos_stateQueue, ^{
            [callbackLock lock];
            NSError *error = callbackError;
            [callbackLock unlock];
            if (!error) {
                error = task.error;
            }
            TOSGetObjectOutput *output = task.result;
            if (!error && ![output isKindOfClass:[TOSGetObjectOutput class]]) {
                error = TOSDownloadError(@"tos: ranged get object returned an invalid response");
            }
            if (!error) {
                NSError *finishError = nil;
                if (![partWriter finish:&finishError]) {
                    error = finishError ?: TOSDownloadError(@"tos: ranged response length mismatch");
                }
            }
            if (!error) {
                BOOL previousCompleted = part.tos_completed;
                uint64_t previousCRC = part.tos_crc64;
                part.tos_completed = YES;
                part.tos_crc64 = partWriter.tos_crc64;
                NSError *checkpointError = nil;
                if (![strongSelf tos_persistCheckpoint:&checkpointError]) {
                    part.tos_completed = previousCompleted;
                    part.tos_crc64 = previousCRC;
                    error = checkpointError;
                }
            }

            TOSTransferAttemptResult *result = [TOSTransferAttemptResult new];
            result.error = error;
            result.statusCode = TOSDownloadStatusCode(error);
            result.retryAfter = responseMetadata.retryAfter;
            if (!error) {
                result.value = part;
                [strongSelf tos_emitEventType:TOSDownloadEventDownloadPartSucceed part:part error:nil];
            } else if (!(TOSTransferShouldRetry(error, result.statusCode) &&
                         retryCount < strongSelf.request.tosMaxRetryCount)) {
                TOSDownloadEventType type = TOSDownloadIsFatalPartError(error)
                    ? TOSDownloadEventDownloadPartAborted : TOSDownloadEventDownloadPartFailed;
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
        if (TOSDownloadIsFatalPartError(task.error)) {
            [self tos_removeDownloadState];
        }
        [self tos_finishWithOutput:nil error:task.error];
        return;
    }
    [self tos_finalizeDownload];
}

- (void)tos_finalizeDownload {
    uint64_t combinedCRC = 0;
    for (TOSTransferPart *part in self.tos_checkpoint.tos_parts) {
        if (!part.tos_completed) {
            [self tos_finishWithOutput:nil error:TOSDownloadError(@"tos: cannot finalize with unfinished download parts")];
            return;
        }
        combinedCRC = TOSTransferCRC64Combine(combinedCRC, part.tos_crc64, (uintmax_t)part.tos_size);
    }
    if (self.tos_headOutput.tosHashCrc64ecma != 0 &&
        combinedCRC != self.tos_headOutput.tosHashCrc64ecma) {
        NSError *error = TOSDownloadError(@"tos: crc of entire file mismatch");
        [self tos_removeDownloadState];
        [self tos_finishWithOutput:nil error:error];
        return;
    }

    struct stat tempStat;
    if (!self.tos_writer ||
        fstat(self.tos_writer.tos_fileDescriptor, &tempStat) != 0 ||
        !S_ISREG(tempStat.st_mode) || tempStat.st_size != self.tos_objectSize ||
        !self.tos_hasTempIdentity || tempStat.st_dev != self.tos_tempDevice ||
        tempStat.st_ino != self.tos_tempInode) {
        NSError *error = TOSDownloadError(@"tos: temporary download file identity changed before rename");
        [self tos_emitEventType:TOSDownloadEventRenameTempFileFailed part:nil error:error];
        [self tos_finishWithOutput:nil error:error];
        return;
    }
    NSError *renameError = nil;
    if (!TOSTransferCommitFileAt(self.tos_tempParentDescriptor,
                                 self.tos_tempFileName,
                                 self.tos_writer.tos_fileDescriptor,
                                 self.tos_finalParentDescriptor,
                                 self.tos_finalFileName,
                                 &renameError)) {
        NSError *error = renameError ?: TOSDownloadError(@"tos: cannot rename download temporary file");
        [self tos_emitEventType:TOSDownloadEventRenameTempFileFailed part:nil error:error];
        [self tos_finishWithOutput:nil error:error];
        return;
    }
    [self.tos_writer close];
    self.tos_writer = nil;
    [self tos_emitEventType:TOSDownloadEventRenameTempFileSucceed part:nil error:nil];
    [self tos_removeCheckpoint];
    [self tos_finishWithOutput:[self tos_outputFromHead] error:nil];
}

- (void)tos_handleCancellation {
    if (self.tos_finished) {
        return;
    }
    NSError *cancelError = TOSDownloadError(@"This task has been cancelled!");
    if (self.request.tosCancelHook.tos_shouldAbort) {
        [self tos_removeDownloadState];
    }
    [self tos_finishWithOutput:nil error:cancelError];
}

- (void)tos_removeDownloadState {
    [self.tos_writer close];
    self.tos_writer = nil;
    if ([self tos_canRemoveOwnedTempPath:self.tos_tempPath] &&
        self.tos_hasTempIdentity &&
        self.tos_tempParentDescriptor >= 0 &&
        TOSDownloadIsValidFileName(self.tos_tempFileName)) {
        TOSDownloadRemoveFileAtIfIdentity(self.tos_tempParentDescriptor,
                                          self.tos_tempFileName,
                                          (uint64_t)self.tos_tempDevice,
                                          (uint64_t)self.tos_tempInode);
    }
    [self tos_removeCheckpoint];
}

- (void)tos_removeCheckpoint {
    if (!self.request.tosEnableCheckpoint || self.tos_checkpoint.tos_checkpointPath.length == 0) {
        return;
    }
    [self.tos_checkpointStore removeCheckpoint:self.tos_checkpoint error:nil];
}

- (void)tos_emitEventType:(TOSDownloadEventType)type
                      part:(TOSTransferPart *)part
                     error:(NSError *)error {
    if (!self.request.tosDownloadEventListener) {
        return;
    }
    TOSDownloadEvent *event = [TOSDownloadEvent new];
    event.tosType = type;
    if (error) {
        event.tosErr = error;
    }
    event.tosBucket = self.request.tosBucket;
    event.tosKey = self.request.tosKey;
    event.tosVersionID = self.request.tosVersionID;
    event.tosFilePath = self.tos_finalPath ?: self.request.tosFilePath;
    event.tosCheckpointPath = self.tos_checkpointPath ?: self.request.tosCheckpointFile;
    event.tosTempFilePath = self.tos_tempPath ?: self.request.tosTempFilePath;
    if (part) {
        TOSDownloadPartInfo *partInfo = [TOSDownloadPartInfo new];
        partInfo.tosPartNumber = (int)part.tos_partNumber;
        partInfo.tosRangeStart = part.tos_rangeStart;
        partInfo.tosRangeEnd = part.tos_rangeEnd;
        event.tosDownloadPartInfo = partInfo;
    }
    self.request.tosDownloadEventListener(event);
}

- (TOSDownloadFileOutput *)tos_outputFromHead {
    TOSHeadObjectOutput *head = self.tos_headOutput;
    TOSDownloadFileOutput *output = [TOSDownloadFileOutput new];
    output.tosRequestID = head.tosRequestID;
    output.tosID2 = head.tosID2;
    output.tosStatusCode = head.tosStatusCode;
    output.tosHeader = head.tosHeader;
    output.tosETag = head.tosETag;
    output.tosLastModified = head.tosLastModified;
    output.tosDeleteMarker = head.tosDeleteMarker;
    output.tosSSECAlgorithm = head.tosSSECAlgorithm;
    output.tosSSECKeyMD5 = head.tosSSECKeyMD5;
    output.tosVersionID = head.tosVersionID;
    output.tosWebsiteRedirectLocation = head.tosWebsiteRedirectLocation;
    output.tosObjectType = head.tosObjectType;
    output.tosSymlinkTargetSize = head.tosSymlinkTargetSize;
    output.tosHashCrc64ecma = head.tosHashCrc64ecma;
    output.tosStorageClass = head.tosStorageClass;
    output.tosMeta = head.tosMeta;
    output.tosContentLength = head.tosContentLength;
    output.tosContentType = head.tosContentType;
    output.tosCacheControl = head.tosCacheControl;
    output.tosContentDisposition = head.tosContentDisposition;
    output.tosContentEncoding = head.tosContentEncoding;
    output.tosContentLanguage = head.tosContentLanguage;
    output.tosExpiration = head.tosExpiration;
    output.tosExpires = head.tosExpires;
    return output;
}

- (void)tos_finishWithOutput:(TOSDownloadFileOutput *)output error:(NSError *)error {
    if (self.tos_finished) {
        return;
    }
    if (error && !self.request.tosEnableCheckpoint) {
        [self tos_removeDownloadState];
    }
    self.tos_finished = YES;
    [self.tos_writer close];
    self.tos_writer = nil;
    if (error) {
        [self.tos_progress fail];
    } else {
        [self.tos_progress finish];
    }
    [self.tos_progress waitUntilIdle];
    [self tos_closeDirectoryDescriptors];
    [self.tos_checkpointLease invalidate];
    self.tos_checkpointLease = nil;
    if (error) {
        [self.tos_taskSource trySetError:error];
    } else {
        [self.tos_taskSource trySetResult:output];
    }
    self.tos_lifetimeAnchor = nil;
}

- (void)tos_closeDirectoryDescriptors {
    if (self.tos_finalParentDescriptor >= 0) {
        close(self.tos_finalParentDescriptor);
        self.tos_finalParentDescriptor = -1;
    }
    if (self.tos_tempParentDescriptor >= 0) {
        close(self.tos_tempParentDescriptor);
        self.tos_tempParentDescriptor = -1;
    }
}

- (void)dealloc {
    [self tos_closeDirectoryDescriptors];
}

@end
