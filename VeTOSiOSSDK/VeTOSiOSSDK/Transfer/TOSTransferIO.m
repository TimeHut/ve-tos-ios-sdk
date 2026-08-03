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

#import "TOSTransferIO.h"
#import "../Utility/TOSConstants.h"
#import "../Utility/aos_crc64.h"
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <sys/stat.h>
#include <unistd.h>

static NSError *TOSTransferIOError(NSString *message) {
    return [NSError errorWithDomain:TOSClientErrorDomain
                               code:400
                           userInfo:@{TOSErrorMessageTOKEN: message}];
}

static NSError *TOSTransferPOSIXError(int posixError) {
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:posixError userInfo:nil];
}

static BOOL TOSTransferIsValidFileName(NSString *fileName) {
    return fileName.length > 0 &&
           ![fileName isEqualToString:@"."] &&
           ![fileName isEqualToString:@".."] &&
           [fileName rangeOfString:@"/"].location == NSNotFound;
}

BOOL TOSTransferRenameFileAt(int sourceDirectoryFileDescriptor,
                             NSString *sourceFileName,
                             int destinationDirectoryFileDescriptor,
                             NSString *destinationFileName,
                             NSError **error) {
    if (sourceDirectoryFileDescriptor < 0 ||
        destinationDirectoryFileDescriptor < 0 ||
        !TOSTransferIsValidFileName(sourceFileName) ||
        !TOSTransferIsValidFileName(destinationFileName)) {
        if (error) {
            *error = TOSTransferIOError(@"下载临时文件或目标文件位置无效");
        }
        return NO;
    }
    if (renameat(sourceDirectoryFileDescriptor,
                 sourceFileName.fileSystemRepresentation,
                 destinationDirectoryFileDescriptor,
                 destinationFileName.fileSystemRepresentation) != 0) {
        if (error) {
            *error = TOSTransferPOSIXError(errno);
        }
        return NO;
    }
    return YES;
}

static BOOL TOSTransferStatMatches(struct stat first, struct stat second) {
    return first.st_dev == second.st_dev && first.st_ino == second.st_ino;
}

BOOL TOSTransferRemoveFileAtIfIdentity(int directoryFileDescriptor,
                                       NSString *fileName,
                                       uint64_t expectedDevice,
                                       uint64_t expectedInode) {
    if (directoryFileDescriptor < 0 ||
        !TOSTransferIsValidFileName(fileName) ||
        expectedInode == 0) {
        return NO;
    }

    NSString *quarantineFileName =
        [NSString stringWithFormat:@".tos-remove-%@", NSUUID.UUID.UUIDString];
    if (renameat(directoryFileDescriptor,
                 fileName.fileSystemRepresentation,
                 directoryFileDescriptor,
                 quarantineFileName.fileSystemRepresentation) != 0) {
        return NO;
    }

    struct stat quarantineStat;
    BOOL matches = fstatat(directoryFileDescriptor,
                           quarantineFileName.fileSystemRepresentation,
                           &quarantineStat,
                           AT_SYMLINK_NOFOLLOW) == 0 &&
                   S_ISREG(quarantineStat.st_mode) &&
                   (uint64_t)quarantineStat.st_dev == expectedDevice &&
                   (uint64_t)quarantineStat.st_ino == expectedInode;
    if (!matches) {
        if (linkat(directoryFileDescriptor,
                   quarantineFileName.fileSystemRepresentation,
                   directoryFileDescriptor,
                   fileName.fileSystemRepresentation,
                   0) == 0) {
            unlinkat(directoryFileDescriptor, quarantineFileName.fileSystemRepresentation, 0);
        }
        return NO;
    }

    if (unlinkat(directoryFileDescriptor, quarantineFileName.fileSystemRepresentation, 0) == 0) {
        return YES;
    }
    if (linkat(directoryFileDescriptor,
               quarantineFileName.fileSystemRepresentation,
               directoryFileDescriptor,
               fileName.fileSystemRepresentation,
               0) == 0) {
        unlinkat(directoryFileDescriptor, quarantineFileName.fileSystemRepresentation, 0);
    }
    return NO;
}

BOOL TOSTransferCommitFileAt(int sourceDirectoryFileDescriptor,
                             NSString *sourceFileName,
                             int sourceFileDescriptor,
                             int destinationDirectoryFileDescriptor,
                             NSString *destinationFileName,
                             NSError **error) {
    if (sourceDirectoryFileDescriptor < 0 ||
        sourceFileDescriptor < 0 ||
        destinationDirectoryFileDescriptor < 0 ||
        !TOSTransferIsValidFileName(sourceFileName) ||
        !TOSTransferIsValidFileName(destinationFileName)) {
        if (error) {
            *error = TOSTransferIOError(@"下载临时文件或目标文件位置无效");
        }
        return NO;
    }

    struct stat sourceDirectoryStat;
    struct stat destinationDirectoryStat;
    struct stat expectedSourceStat;
    if (fstat(sourceDirectoryFileDescriptor, &sourceDirectoryStat) != 0 ||
        fstat(destinationDirectoryFileDescriptor, &destinationDirectoryStat) != 0 ||
        fstat(sourceFileDescriptor, &expectedSourceStat) != 0) {
        if (error) {
            *error = TOSTransferPOSIXError(errno);
        }
        return NO;
    }
    if (!S_ISDIR(sourceDirectoryStat.st_mode) ||
        !S_ISDIR(destinationDirectoryStat.st_mode) ||
        !S_ISREG(expectedSourceStat.st_mode) ||
        (TOSTransferStatMatches(sourceDirectoryStat, destinationDirectoryStat) &&
         [sourceFileName isEqualToString:destinationFileName])) {
        if (error) {
            *error = TOSTransferIOError(@"下载临时文件或目标文件身份无效");
        }
        return NO;
    }

    NSString *stagingFileName =
        [NSString stringWithFormat:@".tos-commit-%@", NSUUID.UUID.UUIDString];
    if (linkat(sourceDirectoryFileDescriptor,
               sourceFileName.fileSystemRepresentation,
               destinationDirectoryFileDescriptor,
               stagingFileName.fileSystemRepresentation,
               0) != 0) {
        if (error) {
            *error = TOSTransferPOSIXError(errno);
        }
        return NO;
    }

    struct stat stagedStat;
    int stagedStatResult = fstatat(destinationDirectoryFileDescriptor,
                                  stagingFileName.fileSystemRepresentation,
                                  &stagedStat,
                                  AT_SYMLINK_NOFOLLOW);
    if (stagedStatResult != 0 ||
        !S_ISREG(stagedStat.st_mode) ||
        !TOSTransferStatMatches(stagedStat, expectedSourceStat)) {
        int posixError = stagedStatResult != 0 ? errno : 0;
        unlinkat(destinationDirectoryFileDescriptor, stagingFileName.fileSystemRepresentation, 0);
        if (error) {
            *error = posixError == 0
                ? TOSTransferIOError(@"下载临时文件身份在提交前发生变化")
                : TOSTransferPOSIXError(posixError);
        }
        return NO;
    }

    if (!TOSTransferRemoveFileAtIfIdentity(sourceDirectoryFileDescriptor,
                                           sourceFileName,
                                           (uint64_t)expectedSourceStat.st_dev,
                                           (uint64_t)expectedSourceStat.st_ino)) {
        unlinkat(destinationDirectoryFileDescriptor, stagingFileName.fileSystemRepresentation, 0);
        if (error) {
            *error = TOSTransferIOError(@"下载临时文件身份在清理前发生变化");
        }
        return NO;
    }

    if (renameat(destinationDirectoryFileDescriptor,
                 stagingFileName.fileSystemRepresentation,
                 destinationDirectoryFileDescriptor,
                 destinationFileName.fileSystemRepresentation) != 0) {
        int posixError = errno;
        if (linkat(destinationDirectoryFileDescriptor,
                   stagingFileName.fileSystemRepresentation,
                   sourceDirectoryFileDescriptor,
                   sourceFileName.fileSystemRepresentation,
                   0) == 0) {
            unlinkat(destinationDirectoryFileDescriptor, stagingFileName.fileSystemRepresentation, 0);
        }
        if (error) {
            *error = TOSTransferPOSIXError(posixError);
        }
        return NO;
    }
    return YES;
}

static BOOL TOSTransferAcquireLimiter(id<TOSRateLimiter> rateLimiter,
                                      int64_t length,
                                      TOSCancelHook *cancelHook,
                                      NSError **error) {
    if (length <= 0 || !rateLimiter) {
        return YES;
    }
    while (YES) {
        if (cancelHook.tos_isCancelled) {
            if (error) {
                *error = TOSTransferIOError(@"This task has been cancelled!");
            }
            return NO;
        }
        NSTimeInterval wait = 0;
        if ([rateLimiter acquire:length timeToWait:&wait]) {
            return YES;
        }
        if (!isfinite(wait) || wait <= 0) {
            if (error) {
                *error = TOSTransferIOError(@"限速器返回了无效的等待时间");
            }
            return NO;
        }
        [NSThread sleepForTimeInterval:MIN(wait, 0.05)];
    }
}

static int64_t TOSTransferLimiterMaximumAcquisitionSize(id<TOSRateLimiter> rateLimiter,
                                                         int64_t fallback) {
    if (!rateLimiter || ![rateLimiter respondsToSelector:@selector(tos_maximumAcquisitionSize)]) {
        return fallback;
    }
    int64_t maximum = [(TOSDefaultRateLimiter *)rateLimiter tos_maximumAcquisitionSize];
    return maximum > 0 ? maximum : fallback;
}

uint64_t TOSTransferCRC64(uint64_t crc, const void *bytes, size_t length) {
    return aos_crc64(crc, (void *)bytes, length);
}

uint64_t TOSTransferCRC64Combine(uint64_t crc1, uint64_t crc2, uintmax_t length2) {
    return aos_crc64_combine(crc1, crc2, length2);
}


@interface TOSFileRangeInputStreamSchedule : NSObject
@property (nonatomic, strong) NSRunLoop *runLoop;
@property (nonatomic, copy) NSRunLoopMode mode;
@property (nonatomic, assign) BOOL active;
@end

@implementation TOSFileRangeInputStreamSchedule
@end

@interface TOSFileRangeInputStream ()
@property (nonatomic, assign, readwrite) int tos_fileDescriptor;
@property (nonatomic, assign) int64_t tos_offset;
@property (nonatomic, assign) int64_t tos_length;
@property (nonatomic, assign, readwrite) int64_t tos_consumed;
@property (nonatomic, assign, readwrite) uint64_t tos_crc64;
@property (nonatomic, strong) id<TOSRateLimiter> tos_rateLimiter;
@property (nonatomic, strong) TOSCancelHook *tos_cancelHook;
@property (nonatomic, assign) NSStreamStatus tos_status;
@property (nonatomic, strong) NSError *tos_error;
@property (nonatomic, weak) id<NSStreamDelegate> tos_delegate;
@property (nonatomic, strong) NSMutableArray<TOSFileRangeInputStreamSchedule *> *tos_schedules;
@property (nonatomic, strong) NSLock *tos_scheduleLock;
@property (nonatomic, assign) BOOL tos_endEventSent;
@property (nonatomic, assign) BOOL tos_ownsFileDescriptor;
- (void)tos_signalEvent:(NSStreamEvent)event;
- (nullable instancetype)initWithFileDescriptor:(int)fileDescriptor
                                          offset:(int64_t)offset
                                          length:(int64_t)length
                                     rateLimiter:(nullable id<TOSRateLimiter>)rateLimiter
                                      cancelHook:(nullable TOSCancelHook *)cancelHook
                                 duplicateSource:(BOOL)duplicateSource
                                           error:(NSError **)error;
@end

@implementation TOSFileRangeInputStream

- (instancetype)initWithFileDescriptor:(int)fileDescriptor
                                  offset:(int64_t)offset
                                  length:(int64_t)length
                             rateLimiter:(id<TOSRateLimiter>)rateLimiter
                              cancelHook:(TOSCancelHook *)cancelHook
                                   error:(NSError **)error {
    return [self initWithFileDescriptor:fileDescriptor
                                 offset:offset
                                 length:length
                            rateLimiter:rateLimiter
                             cancelHook:cancelHook
                        duplicateSource:YES
                                  error:error];
}

- (instancetype)initWithBorrowedFileDescriptor:(int)fileDescriptor
                                          offset:(int64_t)offset
                                          length:(int64_t)length
                                     rateLimiter:(id<TOSRateLimiter>)rateLimiter
                                      cancelHook:(TOSCancelHook *)cancelHook
                                           error:(NSError **)error {
    return [self initWithFileDescriptor:fileDescriptor
                                 offset:offset
                                 length:length
                            rateLimiter:rateLimiter
                             cancelHook:cancelHook
                        duplicateSource:NO
                                  error:error];
}

- (instancetype)initWithFileDescriptor:(int)fileDescriptor
                                  offset:(int64_t)offset
                                  length:(int64_t)length
                             rateLimiter:(id<TOSRateLimiter>)rateLimiter
                              cancelHook:(TOSCancelHook *)cancelHook
                         duplicateSource:(BOOL)duplicateSource
                                   error:(NSError **)error {
    self = [super init];
    if (!self) {
        return nil;
    }
    _tos_fileDescriptor = -1;
    if (fileDescriptor < 0 || offset < 0 || length < 0 || length > INT64_MAX - offset) {
        if (error) {
            *error = TOSTransferIOError(@"文件描述符或读取范围无效");
        }
        return nil;
    }
    struct stat fileStat;
    if (fstat(fileDescriptor, &fileStat) != 0) {
        if (error) {
            *error = TOSTransferPOSIXError(errno);
        }
        return nil;
    }
    if (S_ISREG(fileStat.st_mode) && offset + length > fileStat.st_size) {
        if (error) {
            *error = TOSTransferIOError(@"读取范围超过源文件大小");
        }
        return nil;
    }

    int streamDescriptor = fileDescriptor;
    if (duplicateSource) {
        streamDescriptor = dup(fileDescriptor);
        if (streamDescriptor < 0) {
            if (error) {
                *error = TOSTransferPOSIXError(errno);
            }
            return nil;
        }
        fcntl(streamDescriptor, F_SETFD, FD_CLOEXEC);
    }

    _tos_fileDescriptor = streamDescriptor;
    _tos_ownsFileDescriptor = duplicateSource;
    _tos_offset = offset;
    _tos_length = length;
    _tos_rateLimiter = rateLimiter;
    _tos_cancelHook = cancelHook;
    _tos_status = NSStreamStatusNotOpen;
    _tos_schedules = [NSMutableArray array];
    _tos_scheduleLock = [NSLock new];
    return self;
}

- (void)dealloc {
    [self close];
}

- (void)open {
    if (self.tos_status == NSStreamStatusNotOpen) {
        self.tos_status = NSStreamStatusOpen;
        [self tos_signalEvent:NSStreamEventOpenCompleted];
        if (self.tos_length == 0) {
            self.tos_status = NSStreamStatusAtEnd;
            self.tos_endEventSent = YES;
            [self tos_signalEvent:NSStreamEventEndEncountered];
        } else {
            [self tos_signalEvent:NSStreamEventHasBytesAvailable];
        }
    }
}

- (void)close {
    if (self.tos_fileDescriptor >= 0) {
        if (self.tos_ownsFileDescriptor) {
            close(self.tos_fileDescriptor);
        }
        self.tos_fileDescriptor = -1;
    }
    if (self.tos_status != NSStreamStatusError) {
        self.tos_status = NSStreamStatusClosed;
    }
}

- (NSInteger)read:(uint8_t *)buffer maxLength:(NSUInteger)length {
    if (length == 0) {
        return 0;
    }
    if (self.tos_status != NSStreamStatusOpen && self.tos_status != NSStreamStatusAtEnd) {
        self.tos_error = TOSTransferIOError(@"输入流尚未打开或已经关闭");
        self.tos_status = NSStreamStatusError;
        [self tos_signalEvent:NSStreamEventErrorOccurred];
        return -1;
    }
    if (self.tos_status == NSStreamStatusAtEnd || self.tos_consumed == self.tos_length) {
        self.tos_status = NSStreamStatusAtEnd;
        if (!self.tos_endEventSent) {
            self.tos_endEventSent = YES;
            [self tos_signalEvent:NSStreamEventEndEncountered];
        }
        return 0;
    }
    if (self.tos_cancelHook.tos_isCancelled) {
        self.tos_error = TOSTransferIOError(@"This task has been cancelled!");
        self.tos_status = NSStreamStatusError;
        [self tos_signalEvent:NSStreamEventErrorOccurred];
        return -1;
    }

    int64_t remaining = self.tos_length - self.tos_consumed;
    size_t requested = (size_t)MIN((uint64_t)length, (uint64_t)remaining);
    requested = (size_t)MIN((uint64_t)requested,
                            (uint64_t)TOSTransferLimiterMaximumAcquisitionSize(self.tos_rateLimiter,
                                                                              (int64_t)requested));
    NSError *limiterError = nil;
    if (!TOSTransferAcquireLimiter(self.tos_rateLimiter, (int64_t)requested, self.tos_cancelHook, &limiterError)) {
        self.tos_error = limiterError;
        self.tos_status = NSStreamStatusError;
        [self tos_signalEvent:NSStreamEventErrorOccurred];
        return -1;
    }

    ssize_t bytesRead = -1;
    do {
        bytesRead = pread(self.tos_fileDescriptor,
                          buffer,
                          requested,
                          (off_t)(self.tos_offset + self.tos_consumed));
    } while (bytesRead < 0 && errno == EINTR);
    if (bytesRead < 0) {
        self.tos_error = TOSTransferPOSIXError(errno);
        self.tos_status = NSStreamStatusError;
        [self tos_signalEvent:NSStreamEventErrorOccurred];
        return -1;
    }
    if (bytesRead == 0) {
        self.tos_error = TOSTransferIOError(@"源文件在读取完成前结束");
        self.tos_status = NSStreamStatusError;
        [self tos_signalEvent:NSStreamEventErrorOccurred];
        return -1;
    }

    self.tos_crc64 = TOSTransferCRC64(self.tos_crc64, buffer, (size_t)bytesRead);
    self.tos_consumed += bytesRead;
    if (self.tos_bytesRead) {
        self.tos_bytesRead(bytesRead);
    }
    if (self.tos_consumed == self.tos_length) {
        self.tos_status = NSStreamStatusAtEnd;
        self.tos_endEventSent = YES;
        [self tos_signalEvent:NSStreamEventEndEncountered];
    } else {
        [self tos_signalEvent:NSStreamEventHasBytesAvailable];
    }
    return bytesRead;
}

- (BOOL)getBuffer:(uint8_t * _Nullable *)buffer length:(NSUInteger *)len {
    return NO;
}

- (BOOL)hasBytesAvailable {
    return self.tos_status == NSStreamStatusOpen &&
           self.tos_consumed < self.tos_length &&
           !self.tos_cancelHook.tos_isCancelled;
}

- (NSStreamStatus)streamStatus {
    return self.tos_status;
}

- (NSError *)streamError {
    return self.tos_error;
}

- (id<NSStreamDelegate>)delegate {
    return self.tos_delegate ?: (id<NSStreamDelegate>)self;
}

- (void)setDelegate:(id<NSStreamDelegate>)delegate {
    self.tos_delegate = delegate;
}

- (void)scheduleInRunLoop:(NSRunLoop *)aRunLoop forMode:(NSRunLoopMode)mode {
    if (!aRunLoop || mode.length == 0) {
        return;
    }
    [self.tos_scheduleLock lock];
    for (TOSFileRangeInputStreamSchedule *schedule in self.tos_schedules) {
        if (schedule.runLoop == aRunLoop && [schedule.mode isEqualToString:mode]) {
            [self.tos_scheduleLock unlock];
            return;
        }
    }
    TOSFileRangeInputStreamSchedule *schedule = [TOSFileRangeInputStreamSchedule new];
    schedule.runLoop = aRunLoop;
    schedule.mode = mode;
    schedule.active = YES;
    [self.tos_schedules addObject:schedule];
    [self.tos_scheduleLock unlock];

    if (self.tos_status == NSStreamStatusOpen) {
        [self tos_signalEvent:NSStreamEventOpenCompleted];
        [self tos_signalEvent:NSStreamEventHasBytesAvailable];
    } else if (self.tos_status == NSStreamStatusAtEnd) {
        [self tos_signalEvent:NSStreamEventEndEncountered];
    } else if (self.tos_status == NSStreamStatusError) {
        [self tos_signalEvent:NSStreamEventErrorOccurred];
    }
}

- (void)removeFromRunLoop:(NSRunLoop *)aRunLoop forMode:(NSRunLoopMode)mode {
    [self.tos_scheduleLock lock];
    NSIndexSet *matches = [self.tos_schedules indexesOfObjectsPassingTest:^BOOL(TOSFileRangeInputStreamSchedule *schedule,
                                                                                NSUInteger index,
                                                                                BOOL *stop) {
        BOOL matches = schedule.runLoop == aRunLoop && [schedule.mode isEqualToString:mode];
        if (matches) {
            schedule.active = NO;
        }
        return matches;
    }];
    [self.tos_schedules removeObjectsAtIndexes:matches];
    [self.tos_scheduleLock unlock];
}

- (id)propertyForKey:(NSStreamPropertyKey)key {
    return nil;
}

- (BOOL)setProperty:(id)property forKey:(NSStreamPropertyKey)key {
    return NO;
}

- (void)tos_signalEvent:(NSStreamEvent)event {
    [self.tos_scheduleLock lock];
    NSArray<TOSFileRangeInputStreamSchedule *> *schedules = [self.tos_schedules copy];
    [self.tos_scheduleLock unlock];
    for (TOSFileRangeInputStreamSchedule *schedule in schedules) {
        CFRunLoopRef runLoop = schedule.runLoop.getCFRunLoop;
        CFStringRef mode = (__bridge CFStringRef)schedule.mode;
        __weak typeof(self) weakSelf = self;
        CFRunLoopPerformBlock(runLoop, mode, ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            [strongSelf.tos_scheduleLock lock];
            BOOL active = schedule.active;
            [strongSelf.tos_scheduleLock unlock];
            id<NSStreamDelegate> delegate = strongSelf.delegate;
            if (active && [delegate respondsToSelector:@selector(stream:handleEvent:)]) {
                [delegate stream:strongSelf handleEvent:event];
            }
        });
        CFRunLoopWakeUp(runLoop);
    }
}

@end


@interface TOSDefaultPositionalWriter : NSObject <TOSTransferPositionalWriting>
@end


@implementation TOSDefaultPositionalWriter

- (ssize_t)tos_writeFileDescriptor:(int)fileDescriptor
                             buffer:(const void *)buffer
                             length:(size_t)length
                             offset:(off_t)offset
                         posixError:(int *)posixError {
    ssize_t result = pwrite(fileDescriptor, buffer, length, offset);
    if (result < 0 && posixError) {
        *posixError = errno;
    }
    return result;
}

@end


@interface TOSDownloadFileWriter ()
@property (nonatomic, copy) NSString *tos_filePath;
@property (nonatomic, assign) int64_t tos_size;
@property (nonatomic, assign, readwrite) int tos_fileDescriptor;
@property (nonatomic, strong) id<TOSTransferPositionalWriting> tos_positionalWriter;
@property (nonatomic, strong) id<TOSRateLimiter> tos_rateLimiter;
@property (nonatomic, strong) TOSCancelHook *tos_cancelHook;
@property (nonatomic, strong) NSCondition *tos_condition;
@property (nonatomic, assign) NSInteger tos_activeWrites;
- (BOOL)tos_beginWriteWithFileDescriptor:(int *)fileDescriptor;
- (void)tos_endWrite;
- (BOOL)tos_configureWithFileDescriptor:(int)fileDescriptor
                               filePath:(NSString *)filePath
                                   size:(int64_t)size
                       positionalWriter:(id<TOSTransferPositionalWriting>)positionalWriter
                            rateLimiter:(id<TOSRateLimiter>)rateLimiter
                             cancelHook:(TOSCancelHook *)cancelHook
                                  error:(NSError **)error;
- (instancetype)initWithDirectoryFileDescriptor:(int)directoryFileDescriptor
                                        fileName:(NSString *)fileName
                                            size:(int64_t)size
                                  expectedDevice:(uint64_t)expectedDevice
                                   expectedInode:(uint64_t)expectedInode
                             requireExpectedFile:(BOOL)requireExpectedFile
                                     rateLimiter:(id<TOSRateLimiter>)rateLimiter
                                      cancelHook:(TOSCancelHook *)cancelHook
                                           error:(NSError **)error;
@end

@interface TOSDownloadPartWriter ()
@property (nonatomic, strong) TOSDownloadFileWriter *tos_writer;
@property (nonatomic, assign) int64_t tos_offset;
@property (nonatomic, assign) int64_t tos_length;
@property (nonatomic, assign, readwrite) int64_t tos_consumed;
@property (nonatomic, assign, readwrite) uint64_t tos_crc64;
@property (nonatomic, assign) BOOL tos_finished;
@property (nonatomic, strong) NSLock *tos_lock;
- (instancetype)initWithWriter:(TOSDownloadFileWriter *)writer offset:(int64_t)offset length:(int64_t)length;
@end

@implementation TOSDownloadFileWriter

- (instancetype)initWithFilePath:(NSString *)filePath
                             size:(int64_t)size
                            error:(NSError **)error {
    return [self initWithFilePath:filePath
                             size:size
                      rateLimiter:nil
                       cancelHook:nil
                            error:error];
}

- (instancetype)initWithFilePath:(NSString *)filePath
                             size:(int64_t)size
                      rateLimiter:(id<TOSRateLimiter>)rateLimiter
                       cancelHook:(TOSCancelHook *)cancelHook
                            error:(NSError **)error {
    return [self initWithFilePath:filePath
                             size:size
                 positionalWriter:[TOSDefaultPositionalWriter new]
                      rateLimiter:rateLimiter
                       cancelHook:cancelHook
                            error:error];
}

- (instancetype)initWithFilePath:(NSString *)filePath
                             size:(int64_t)size
                 positionalWriter:(id<TOSTransferPositionalWriting>)positionalWriter
                      rateLimiter:(id<TOSRateLimiter>)rateLimiter
                       cancelHook:(TOSCancelHook *)cancelHook
                            error:(NSError **)error {
    self = [super init];
    if (!self) {
        return nil;
    }
    _tos_fileDescriptor = -1;
    if (filePath.length == 0 || size < 0 || !positionalWriter) {
        if (error) {
            *error = TOSTransferIOError(@"下载临时文件路径、大小或写入器无效");
        }
        return nil;
    }
    BOOL created = NO;
    int fileDescriptor = open(filePath.fileSystemRepresentation,
                              O_RDWR | O_CLOEXEC | O_NOFOLLOW);
    if (fileDescriptor < 0 && errno == ENOENT) {
        fileDescriptor = open(filePath.fileSystemRepresentation,
                              O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                              0600);
        created = fileDescriptor >= 0;
    }
    if (fileDescriptor < 0) {
        if (error) {
            *error = TOSTransferPOSIXError(errno);
        }
        return nil;
    }
    struct stat createdStat = {0};
    BOOL hasCreatedIdentity = created && fstat(fileDescriptor, &createdStat) == 0;
    if (![self tos_configureWithFileDescriptor:fileDescriptor
                                      filePath:filePath
                                          size:size
                              positionalWriter:positionalWriter
                                   rateLimiter:rateLimiter
                                    cancelHook:cancelHook
                                         error:error]) {
        if (hasCreatedIdentity) {
            NSString *parentPath = filePath.stringByDeletingLastPathComponent;
            NSString *fileName = filePath.lastPathComponent;
            int directoryFileDescriptor =
                open(parentPath.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
            if (directoryFileDescriptor >= 0) {
                TOSTransferRemoveFileAtIfIdentity(directoryFileDescriptor,
                                                  fileName,
                                                  (uint64_t)createdStat.st_dev,
                                                  (uint64_t)createdStat.st_ino);
                close(directoryFileDescriptor);
            }
        }
        return nil;
    }
    return self;
}

- (instancetype)initWithDirectoryFileDescriptor:(int)directoryFileDescriptor
                                         fileName:(NSString *)fileName
                                             size:(int64_t)size
                                      rateLimiter:(id<TOSRateLimiter>)rateLimiter
                                       cancelHook:(TOSCancelHook *)cancelHook
                                            error:(NSError **)error {
    return [self initWithDirectoryFileDescriptor:directoryFileDescriptor
                                        fileName:fileName
                                            size:size
                                  expectedDevice:0
                                   expectedInode:0
                             requireExpectedFile:NO
                                     rateLimiter:rateLimiter
                                      cancelHook:cancelHook
                                           error:error];
}

- (instancetype)initWithDirectoryFileDescriptor:(int)directoryFileDescriptor
                                         fileName:(NSString *)fileName
                                             size:(int64_t)size
                                   expectedDevice:(uint64_t)expectedDevice
                                    expectedInode:(uint64_t)expectedInode
                                      rateLimiter:(id<TOSRateLimiter>)rateLimiter
                                       cancelHook:(TOSCancelHook *)cancelHook
                                            error:(NSError **)error {
    return [self initWithDirectoryFileDescriptor:directoryFileDescriptor
                                        fileName:fileName
                                            size:size
                                  expectedDevice:expectedDevice
                                   expectedInode:expectedInode
                             requireExpectedFile:YES
                                     rateLimiter:rateLimiter
                                      cancelHook:cancelHook
                                           error:error];
}

- (instancetype)initWithDirectoryFileDescriptor:(int)directoryFileDescriptor
                                        fileName:(NSString *)fileName
                                            size:(int64_t)size
                                  expectedDevice:(uint64_t)expectedDevice
                                   expectedInode:(uint64_t)expectedInode
                             requireExpectedFile:(BOOL)requireExpectedFile
                                     rateLimiter:(id<TOSRateLimiter>)rateLimiter
                                      cancelHook:(TOSCancelHook *)cancelHook
                                           error:(NSError **)error {
    self = [super init];
    if (!self) {
        return nil;
    }
    _tos_fileDescriptor = -1;
    if (directoryFileDescriptor < 0 ||
        !TOSTransferIsValidFileName(fileName) ||
        size < 0 ||
        (requireExpectedFile && expectedInode == 0)) {
        if (error) {
            *error = TOSTransferIOError(@"下载临时文件位置或大小无效");
        }
        return nil;
    }
    BOOL created = NO;
    int fileDescriptor = openat(directoryFileDescriptor,
                                fileName.fileSystemRepresentation,
                                O_RDWR | O_CLOEXEC | O_NOFOLLOW);
    if (fileDescriptor < 0 && errno == ENOENT && !requireExpectedFile) {
        fileDescriptor = openat(directoryFileDescriptor,
                                fileName.fileSystemRepresentation,
                                O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                                0600);
        created = fileDescriptor >= 0;
    }
    if (fileDescriptor < 0) {
        if (error) {
            *error = TOSTransferPOSIXError(errno);
        }
        return nil;
    }
    struct stat openedStat;
    int statResult = fstat(fileDescriptor, &openedStat);
    int statError = statResult != 0 ? errno : 0;
    if (statResult != 0 ||
        !S_ISREG(openedStat.st_mode) ||
        (requireExpectedFile &&
         ((uint64_t)openedStat.st_dev != expectedDevice ||
          (uint64_t)openedStat.st_ino != expectedInode))) {
        close(fileDescriptor);
        if (error) {
            *error = statError != 0
                ? TOSTransferPOSIXError(statError)
                : TOSTransferIOError(@"下载临时文件身份与断点记录不一致");
        }
        return nil;
    }
    struct stat createdStat = {0};
    BOOL hasCreatedIdentity = created;
    if (created) {
        createdStat = openedStat;
    }
    if (![self tos_configureWithFileDescriptor:fileDescriptor
                                      filePath:fileName
                                          size:size
                              positionalWriter:[TOSDefaultPositionalWriter new]
                                   rateLimiter:rateLimiter
                                    cancelHook:cancelHook
                                         error:error]) {
        if (hasCreatedIdentity) {
            TOSTransferRemoveFileAtIfIdentity(directoryFileDescriptor,
                                              fileName,
                                              (uint64_t)createdStat.st_dev,
                                              (uint64_t)createdStat.st_ino);
        }
        return nil;
    }
    return self;
}

- (BOOL)tos_configureWithFileDescriptor:(int)fileDescriptor
                               filePath:(NSString *)filePath
                                   size:(int64_t)size
                       positionalWriter:(id<TOSTransferPositionalWriting>)positionalWriter
                            rateLimiter:(id<TOSRateLimiter>)rateLimiter
                             cancelHook:(TOSCancelHook *)cancelHook
                                  error:(NSError **)error {
    if (fchmod(fileDescriptor, 0600) != 0 || ftruncate(fileDescriptor, (off_t)size) != 0) {
        int posixError = errno;
        close(fileDescriptor);
        if (error) {
            *error = TOSTransferPOSIXError(posixError);
        }
        return NO;
    }

    _tos_filePath = [filePath copy];
    _tos_size = size;
    _tos_fileDescriptor = fileDescriptor;
    _tos_positionalWriter = positionalWriter;
    _tos_rateLimiter = rateLimiter;
    _tos_cancelHook = cancelHook;
    _tos_condition = [NSCondition new];
    return YES;
}

- (void)dealloc {
    [self close];
}

- (TOSDownloadPartWriter *)partWriterWithOffset:(int64_t)offset
                                          length:(int64_t)length
                                           error:(NSError **)error {
    [self.tos_condition lock];
    BOOL isOpen = self.tos_fileDescriptor >= 0;
    [self.tos_condition unlock];
    if (!isOpen || offset < 0 || length < 0 || offset > self.tos_size || length > self.tos_size - offset) {
        if (error) {
            *error = TOSTransferIOError(@"下载分段写入范围无效");
        }
        return nil;
    }
    return [[TOSDownloadPartWriter alloc] initWithWriter:self offset:offset length:length];
}

- (BOOL)tos_beginWriteWithFileDescriptor:(int *)fileDescriptor {
    [self.tos_condition lock];
    if (self.tos_fileDescriptor < 0) {
        [self.tos_condition unlock];
        return NO;
    }
    self.tos_activeWrites += 1;
    if (fileDescriptor) {
        *fileDescriptor = self.tos_fileDescriptor;
    }
    [self.tos_condition unlock];
    return YES;
}

- (void)tos_endWrite {
    [self.tos_condition lock];
    self.tos_activeWrites -= 1;
    if (self.tos_activeWrites == 0) {
        [self.tos_condition broadcast];
    }
    [self.tos_condition unlock];
}

- (void)close {
    [self.tos_condition lock];
    int fileDescriptor = self.tos_fileDescriptor;
    self.tos_fileDescriptor = -1;
    while (self.tos_activeWrites > 0) {
        [self.tos_condition wait];
    }
    [self.tos_condition unlock];
    if (fileDescriptor >= 0) {
        close(fileDescriptor);
    }
}

@end


@implementation TOSDownloadPartWriter

- (instancetype)initWithWriter:(TOSDownloadFileWriter *)writer offset:(int64_t)offset length:(int64_t)length {
    self = [super init];
    if (self) {
        _tos_writer = writer;
        _tos_offset = offset;
        _tos_length = length;
        _tos_lock = [NSLock new];
    }
    return self;
}

- (BOOL)writeData:(NSData *)data error:(NSError **)error {
    [self.tos_lock lock];
    if (self.tos_finished) {
        [self.tos_lock unlock];
        if (error) {
            *error = TOSTransferIOError(@"下载分段已经结束");
        }
        return NO;
    }
    if ((int64_t)data.length > self.tos_length - self.tos_consumed) {
        [self.tos_lock unlock];
        if (error) {
            *error = TOSTransferIOError(@"下载数据超过分段范围");
        }
        return NO;
    }
    if (self.tos_writer.tos_cancelHook.tos_isCancelled) {
        [self.tos_lock unlock];
        if (error) {
            *error = TOSTransferIOError(@"This task has been cancelled!");
        }
        return NO;
    }

    const uint8_t *bytes = data.bytes;
    size_t written = 0;
    while (written < data.length) {
        size_t remaining = data.length - written;
        size_t requested = (size_t)MIN((uint64_t)remaining,
                                      (uint64_t)TOSTransferLimiterMaximumAcquisitionSize(
                                          self.tos_writer.tos_rateLimiter,
                                          (int64_t)remaining));
        NSError *limiterError = nil;
        if (!TOSTransferAcquireLimiter(self.tos_writer.tos_rateLimiter,
                                       (int64_t)requested,
                                       self.tos_writer.tos_cancelHook,
                                       &limiterError)) {
            [self.tos_lock unlock];
            if (error) {
                *error = limiterError;
            }
            return NO;
        }
        int fileDescriptor = -1;
        if (![self.tos_writer tos_beginWriteWithFileDescriptor:&fileDescriptor]) {
            [self.tos_lock unlock];
            if (error) {
                *error = TOSTransferPOSIXError(EBADF);
            }
            return NO;
        }
        int posixError = 0;
        ssize_t result = [self.tos_writer.tos_positionalWriter tos_writeFileDescriptor:fileDescriptor
                                                                                 buffer:bytes + written
                                                                                 length:requested
                                                                                 offset:(off_t)(self.tos_offset + self.tos_consumed)
                                                                             posixError:&posixError];
        [self.tos_writer tos_endWrite];
        if (result < 0 && posixError == EINTR) {
            continue;
        }
        if (result <= 0) {
            [self.tos_lock unlock];
            if (error) {
                *error = TOSTransferPOSIXError(posixError ?: EIO);
            }
            return NO;
        }
        if ((size_t)result > requested) {
            [self.tos_lock unlock];
            if (error) {
                *error = TOSTransferPOSIXError(EIO);
            }
            return NO;
        }
        self.tos_crc64 = TOSTransferCRC64(self.tos_crc64, bytes + written, (size_t)result);
        self.tos_consumed += result;
        written += (size_t)result;
        TOSTransferBytesBlock bytesWritten = self.tos_bytesWritten ?: self.tos_writer.tos_bytesWritten;
        if (bytesWritten) {
            bytesWritten(result);
        }
    }
    [self.tos_lock unlock];
    return YES;
}

- (BOOL)finish:(NSError **)error {
    [self.tos_lock lock];
    if (self.tos_finished) {
        BOOL complete = self.tos_consumed == self.tos_length;
        [self.tos_lock unlock];
        return complete;
    }
    self.tos_finished = YES;
    BOOL complete = self.tos_consumed == self.tos_length;
    [self.tos_lock unlock];
    if (!complete && error) {
        *error = TOSTransferIOError(@"下载分段数据长度不足");
    }
    return complete;
}

@end
