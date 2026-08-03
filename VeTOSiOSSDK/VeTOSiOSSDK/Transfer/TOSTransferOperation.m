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

#import "TOSTransferOperation.h"
#import <QuartzCore/QuartzCore.h>
#include <math.h>

static const int64_t TOSRateLimiterMinimumRate = 1024;
static const int64_t TOSRateLimiterMinimumCapacity = 10 * 1024;
static const int64_t TOSTransferProgressIntervalNanoseconds = 50 * NSEC_PER_MSEC;

NSError *TOSTransferValidateCompleteMultipartUploadOutput(id output,
                                                          NSString *bucket,
                                                          NSString *key,
                                                          BOOL callbackEnabled) {
    NSString *message = nil;
    if (![output isKindOfClass:[TOSCompleteMultipartUploadOutput class]]) {
        message = @"complete multipart upload returned an invalid response";
    } else {
        TOSCompleteMultipartUploadOutput *completeOutput = output;
        if (completeOutput.tosETag.length == 0) {
            message = @"complete multipart upload response is missing ETag";
        } else if (!callbackEnabled &&
                   (completeOutput.tosBucket.length == 0 ||
                    completeOutput.tosKey.length == 0 ||
                    completeOutput.tosLocation.length == 0)) {
            message = @"complete multipart upload response is incomplete";
        } else if (!callbackEnabled &&
                   (![completeOutput.tosBucket isEqualToString:bucket] ||
                    ![completeOutput.tosKey isEqualToString:key])) {
            message = @"complete multipart upload response does not match the request target";
        }
    }
    if (!message) {
        return nil;
    }
    return [NSError errorWithDomain:TOSClientErrorDomain
                               code:400
                           userInfo:@{TOSErrorMessageTOKEN: message}];
}

@interface TOSCancelHook ()
@property (nonatomic, strong) NSLock *tos_lock;
@property (nonatomic, copy, nullable) void (^tos_handler)(BOOL isAbort);
@property (nonatomic, assign) BOOL tos_handlerBound;
@property (nonatomic, assign) BOOL tos_handlerDelivered;
@property (nonatomic, assign, readwrite) BOOL tos_isCancelled;
@property (nonatomic, assign, readwrite) BOOL tos_shouldAbort;
@end

@implementation TOSCancelHook

- (instancetype)init {
    self = [super init];
    if (self) {
        _tos_lock = [NSLock new];
    }
    return self;
}

- (void)cancel:(BOOL)isAbort {
    void (^handler)(BOOL) = nil;
    [self.tos_lock lock];
    if (!_tos_isCancelled) {
        _tos_isCancelled = YES;
        _tos_shouldAbort = isAbort;
        if (self.tos_handler && !self.tos_handlerDelivered) {
            self.tos_handlerDelivered = YES;
            handler = self.tos_handler;
        }
    }
    [self.tos_lock unlock];

    if (handler) {
        handler(isAbort);
    }
}

- (void)tos_bindHandler:(void (^)(BOOL))handler {
    void (^handlerToDeliver)(BOOL) = nil;
    BOOL shouldAbort = NO;
    [self.tos_lock lock];
    if (!self.tos_handlerBound) {
        self.tos_handlerBound = YES;
        self.tos_handler = handler;
        if (_tos_isCancelled && !self.tos_handlerDelivered) {
            self.tos_handlerDelivered = YES;
            handlerToDeliver = self.tos_handler;
            shouldAbort = _tos_shouldAbort;
        }
    }
    [self.tos_lock unlock];

    if (handlerToDeliver) {
        handlerToDeliver(shouldAbort);
    }
}

- (BOOL)tos_isCancelled {
    [self.tos_lock lock];
    BOOL isCancelled = _tos_isCancelled;
    [self.tos_lock unlock];
    return isCancelled;
}

- (BOOL)tos_shouldAbort {
    [self.tos_lock lock];
    BOOL shouldAbort = _tos_shouldAbort;
    [self.tos_lock unlock];
    return shouldAbort;
}

@end

@interface TOSDefaultRateLimiter ()
@property (nonatomic, assign) int64_t tos_capacity;
@property (nonatomic, assign) int64_t tos_rate;
@property (nonatomic, assign) double tos_available;
@property (nonatomic, assign) NSTimeInterval tos_lastRefill;
@property (nonatomic, copy) TOSTransferMonotonicClock tos_clock;
@property (nonatomic, strong) NSLock *tos_lock;
@end

@implementation TOSDefaultRateLimiter

- (nullable instancetype)initWithCapacity:(int64_t)capacity rate:(int64_t)rate {
    return [self initWithCapacity:capacity rate:rate clock:^NSTimeInterval{
        return CACurrentMediaTime();
    }];
}

- (nullable instancetype)initWithCapacity:(int64_t)capacity
                                     rate:(int64_t)rate
                                    clock:(TOSTransferMonotonicClock)clock {
    if (capacity < TOSRateLimiterMinimumCapacity || rate < TOSRateLimiterMinimumRate || !clock) {
        return nil;
    }
    self = [super init];
    if (self) {
        _tos_capacity = capacity;
        _tos_rate = rate;
        _tos_available = capacity;
        _tos_clock = [clock copy];
        _tos_lastRefill = _tos_clock();
        _tos_lock = [NSLock new];
    }
    return self;
}

- (BOOL)acquire:(int64_t)want timeToWait:(NSTimeInterval *)timeToWait {
    if (timeToWait) {
        *timeToWait = 0;
    }
    if (want <= 0) {
        return YES;
    }

    [self.tos_lock lock];
    NSTimeInterval now = self.tos_clock();
    NSTimeInterval elapsed = MAX(0, now - self.tos_lastRefill);
    self.tos_available = MIN((double)self.tos_capacity,
                             self.tos_available + elapsed * (double)self.tos_rate);
    self.tos_lastRefill = now;

    int64_t requested = MIN(want, self.tos_capacity);
    BOOL acquired = self.tos_available >= (double)requested;
    if (acquired) {
        self.tos_available -= (double)requested;
    } else if (timeToWait) {
        *timeToWait = ((double)requested - self.tos_available) / (double)self.tos_rate;
    }
    [self.tos_lock unlock];
    return acquired;
}

- (int64_t)tos_maximumAcquisitionSize {
    return self.tos_capacity;
}

@end

@interface TOSTransferProgress ()
@property (nonatomic, copy, nullable) TOSDataTransferListener tos_listener;
@property (nonatomic, strong) dispatch_queue_t tos_stateQueue;
@property (nonatomic, assign) BOOL tos_started;
@property (nonatomic, assign) BOOL tos_terminal;
@property (nonatomic, assign) BOOL tos_flushScheduled;
@property (nonatomic, assign) int64_t tos_totalBytes;
@property (nonatomic, assign) int64_t tos_consumedBytes;
@property (nonatomic, assign) int64_t tos_pendingBytes;
- (void)tos_finishWithType:(TOSDataTransferType)type completion:(nullable dispatch_block_t)completion;
@end

@implementation TOSTransferProgress

- (instancetype)initWithListener:(nullable TOSDataTransferListener)listener {
    dispatch_queue_t queue = dispatch_queue_create("com.volces.tos.transfer.progress", DISPATCH_QUEUE_SERIAL);
    return [self initWithListener:listener stateQueue:queue];
}

- (instancetype)initWithListener:(nullable TOSDataTransferListener)listener
                       stateQueue:(dispatch_queue_t)stateQueue {
    self = [super init];
    if (self) {
        _tos_listener = [listener copy];
        _tos_stateQueue = stateQueue;
    }
    return self;
}

- (void)startWithTotal:(int64_t)total consumed:(int64_t)consumed {
    if (!self.tos_listener) {
        return;
    }
    dispatch_async(self.tos_stateQueue, ^{
        if (self.tos_started || self.tos_terminal) {
            return;
        }
        self.tos_started = YES;
        self.tos_totalBytes = MAX(0, total);
        self.tos_consumedBytes = MIN(MAX(0, consumed), self.tos_totalBytes);
        [self tos_emitType:TOSDataTransferStarted onceBytes:0];
    });
}

- (void)recordBytes:(int64_t)bytes {
    if (!self.tos_listener || bytes <= 0) {
        return;
    }
    dispatch_async(self.tos_stateQueue, ^{
        if (!self.tos_started || self.tos_terminal) {
            return;
        }
        int64_t remaining = self.tos_totalBytes - self.tos_consumedBytes;
        int64_t accepted = MIN(bytes, MAX(0, remaining));
        if (accepted <= 0) {
            return;
        }
        self.tos_consumedBytes += accepted;
        self.tos_pendingBytes += accepted;
        [self tos_scheduleFlushIfNeeded];
    });
}

- (void)finish {
    [self tos_finishWithType:TOSDataTransferSucceed completion:nil];
}

- (void)fail {
    [self tos_finishWithType:TOSDataTransferFailed completion:nil];
}

- (void)waitUntilIdle {
    if (!self.tos_listener) {
        return;
    }
    dispatch_sync(self.tos_stateQueue, ^{});
}

- (void)tos_finishWithType:(TOSDataTransferType)type completion:(nullable dispatch_block_t)completion {
    if (!self.tos_listener) {
        if (completion) {
            completion();
        }
        return;
    }
    dispatch_async(self.tos_stateQueue, ^{
        if (self.tos_terminal) {
            if (completion) {
                completion();
            }
            return;
        }
        [self tos_flushPendingBytes];
        self.tos_terminal = YES;
        self.tos_flushScheduled = NO;
        [self tos_emitType:type onceBytes:0];
        if (completion) {
            completion();
        }
    });
}

- (void)tos_scheduleFlushIfNeeded {
    if (self.tos_flushScheduled) {
        return;
    }
    self.tos_flushScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, TOSTransferProgressIntervalNanoseconds),
                   self.tos_stateQueue, ^{
        self.tos_flushScheduled = NO;
        if (!self.tos_terminal) {
            [self tos_flushPendingBytes];
        }
    });
}

- (void)tos_flushPendingBytes {
    if (self.tos_pendingBytes <= 0) {
        return;
    }
    int64_t onceBytes = self.tos_pendingBytes;
    self.tos_pendingBytes = 0;
    [self tos_emitType:TOSDataTransferRW onceBytes:onceBytes];
}

- (void)tos_emitType:(TOSDataTransferType)type onceBytes:(int64_t)onceBytes {
    TOSDataTransferStatus *status = [TOSDataTransferStatus new];
    status.tosTotalBytes = self.tos_totalBytes;
    status.tosConsumedBytes = self.tos_consumedBytes;
    status.tosRWOnceBytes = onceBytes;
    status.tosType = type;
    status.tosRetryCount = -1;
    self.tos_listener(status);
}

@end

@implementation TOSTransferAttemptResult
@end

@implementation TOSTransferResponseMetadata
@end

BOOL TOSTransferShouldRetry(NSError *error, NSInteger statusCode) {
    NSInteger effectiveStatusCode = statusCode;
    if (effectiveStatusCode <= 0 && [error.domain isEqualToString:TOSServerErrorDomain]) {
        effectiveStatusCode = error.code;
    }
    if (effectiveStatusCode == 408 || effectiveStatusCode == 429 ||
        (effectiveStatusCode >= 500 && effectiveStatusCode <= 599)) {
        return YES;
    }

    NSError *candidate = error;
    while (candidate) {
        if ([candidate.domain isEqualToString:TOSClientErrorDomain] &&
            candidate.code == TOSClientErrorCodeNetworkError) {
            id originCode = candidate.userInfo[@"OriginErrorCode"];
            if ([originCode respondsToSelector:@selector(integerValue)] &&
                [originCode integerValue] == NSURLErrorCancelled) {
                return NO;
            }
            return YES;
        }
        if ([candidate.domain isEqualToString:NSURLErrorDomain] && candidate.code == NSURLErrorTimedOut) {
            return YES;
        }
        id originCode = candidate.userInfo[@"OriginErrorCode"];
        if ([originCode respondsToSelector:@selector(integerValue)] &&
            [originCode integerValue] == NSURLErrorTimedOut) {
            return YES;
        }
        id underlying = candidate.userInfo[NSUnderlyingErrorKey];
        candidate = [underlying isKindOfClass:[NSError class]] ? underlying : nil;
    }
    return NO;
}

NSTimeInterval TOSTransferRetryAfterDelayForResponse(NSHTTPURLResponse *response) {
    __block id value = nil;
    [response.allHeaderFields enumerateKeysAndObjectsUsingBlock:^(id key, id candidate, BOOL *stop) {
        if ([[key description] caseInsensitiveCompare:@"Retry-After"] == NSOrderedSame) {
            value = candidate;
            *stop = YES;
        }
    }];
    NSString *text = [[value description] stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (text.length == 0) {
        return 0;
    }

    NSScanner *scanner = [NSScanner scannerWithString:text];
    double seconds = 0;
    if ([scanner scanDouble:&seconds] && scanner.isAtEnd) {
        return isfinite(seconds) && seconds > 0 ? seconds : 0;
    }

    static NSArray<NSString *> *formats;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formats = @[@"EEE',' dd MMM yyyy HH':'mm':'ss z",
                    @"EEEE',' dd-MMM-yy HH':'mm':'ss z",
                    @"EEE MMM d HH':'mm':'ss yyyy"];
    });
    for (NSString *format in formats) {
        NSDateFormatter *formatter = [NSDateFormatter new];
        formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
        formatter.dateFormat = format;
        NSDate *date = [formatter dateFromString:text];
        if (date) {
            NSTimeInterval delay = [date timeIntervalSinceNow];
            return isfinite(delay) && delay > 0 ? delay : 0;
        }
    }
    return 0;
}

TOSTransferResponseObserver
TOSTransferRetryAfterObserver(TOSTransferResponseMetadata *metadata) {
    return ^(NSHTTPURLResponse *response) {
        metadata.retryAfter = TOSTransferRetryAfterDelayForResponse(response);
    };
}

NSTimeInterval TOSTransferRetryDelay(NSInteger retryIndex,
                                     NSTimeInterval retryAfter,
                                     double randomUnit) {
    NSInteger safeIndex = MAX(0, retryIndex);
    double exponential = 0.1 * pow(2.0, MIN(safeIndex, 20));
    randomUnit = MIN(1.0, MAX(0.0, randomUnit));
    double jittered = exponential * (0.75 + 0.5 * randomUnit);
    double serverDelay = isfinite(retryAfter) && retryAfter > 0 ? retryAfter : 0;
    return MIN(60.0, MAX(jittered, serverDelay));
}

typedef NS_ENUM(NSInteger, TOSTransferWorkState) {
    TOSTransferWorkStatePending,
    TOSTransferWorkStateWaitingForPermit,
    TOSTransferWorkStateRunning,
    TOSTransferWorkStateWaitingForRetry,
    TOSTransferWorkStateFinished,
};

@class TOSTransferConcurrencyAcquisition;

@interface TOSTransferConcurrencyPermit : NSObject
@property (nonatomic, weak) TOSTransferConcurrencyController *tos_controller;
@property (nonatomic, assign) BOOL tos_released;
- (void)releasePermit;
@end

typedef void (^TOSTransferConcurrencyCompletion)(TOSTransferConcurrencyPermit * _Nullable permit);

@interface TOSTransferConcurrencyAcquisition : NSObject
@property (nonatomic, weak) TOSTransferConcurrencyController *tos_controller;
@property (nonatomic, copy) TOSTransferConcurrencyCompletion tos_completion;
@property (nonatomic, assign) BOOL tos_resolved;
- (void)cancel;
@end

@interface TOSTransferConcurrencyController ()
@property (nonatomic, assign, readwrite) NSInteger limit;
@property (nonatomic, strong) dispatch_queue_t tos_stateQueue;
@property (nonatomic, strong) NSMutableArray<TOSTransferConcurrencyAcquisition *> *tos_pending;
@property (nonatomic, assign) NSInteger tos_activeCount;
- (TOSTransferConcurrencyAcquisition *)tos_acquire:(TOSTransferConcurrencyCompletion)completion;
- (void)tos_cancelAcquisition:(TOSTransferConcurrencyAcquisition *)acquisition;
- (void)tos_releasePermit;
- (void)tos_drain;
@end

@implementation TOSTransferConcurrencyPermit

- (void)releasePermit {
    @synchronized (self) {
        if (self.tos_released) {
            return;
        }
        self.tos_released = YES;
    }
    [self.tos_controller tos_releasePermit];
}

@end

@implementation TOSTransferConcurrencyAcquisition

- (void)cancel {
    [self.tos_controller tos_cancelAcquisition:self];
}

@end

@implementation TOSTransferConcurrencyController

- (instancetype)initWithLimit:(NSInteger)limit {
    self = [super init];
    if (self) {
        _limit = TOSNormalizeResumableTransferTaskNum(limit);
        _tos_stateQueue = dispatch_queue_create("com.volces.tos.transfer.concurrency", DISPATCH_QUEUE_SERIAL);
        _tos_pending = [NSMutableArray array];
    }
    return self;
}

- (TOSTransferConcurrencyAcquisition *)tos_acquire:(TOSTransferConcurrencyCompletion)completion {
    TOSTransferConcurrencyAcquisition *acquisition = [TOSTransferConcurrencyAcquisition new];
    acquisition.tos_controller = self;
    acquisition.tos_completion = completion;
    dispatch_async(self.tos_stateQueue, ^{
        [self.tos_pending addObject:acquisition];
        [self tos_drain];
    });
    return acquisition;
}

- (void)tos_cancelAcquisition:(TOSTransferConcurrencyAcquisition *)acquisition {
    if (!acquisition) {
        return;
    }
    dispatch_async(self.tos_stateQueue, ^{
        if (acquisition.tos_resolved) {
            return;
        }
        NSUInteger index = [self.tos_pending indexOfObjectIdenticalTo:acquisition];
        if (index == NSNotFound) {
            return;
        }
        [self.tos_pending removeObjectAtIndex:index];
        acquisition.tos_resolved = YES;
        TOSTransferConcurrencyCompletion completion = acquisition.tos_completion;
        acquisition.tos_completion = nil;
        if (completion) {
            completion(nil);
        }
    });
}

- (void)tos_releasePermit {
    dispatch_async(self.tos_stateQueue, ^{
        if (self.tos_activeCount > 0) {
            self.tos_activeCount -= 1;
        }
        [self tos_drain];
    });
}

- (void)tos_drain {
    while (self.tos_activeCount < self.limit && self.tos_pending.count > 0) {
        TOSTransferConcurrencyAcquisition *acquisition = self.tos_pending.firstObject;
        [self.tos_pending removeObjectAtIndex:0];
        if (acquisition.tos_resolved) {
            continue;
        }
        acquisition.tos_resolved = YES;
        self.tos_activeCount += 1;
        TOSTransferConcurrencyPermit *permit = [TOSTransferConcurrencyPermit new];
        permit.tos_controller = self;
        TOSTransferConcurrencyCompletion completion = acquisition.tos_completion;
        acquisition.tos_completion = nil;
        if (completion) {
            completion(permit);
        } else {
            [permit releasePermit];
        }
    }
}

@end

@interface TOSTransferWorkItem : NSObject
@property (nonatomic, strong) id item;
@property (nonatomic, assign) NSInteger index;
@property (nonatomic, assign) NSInteger retryCount;
@property (nonatomic, assign) NSUInteger delayGeneration;
@property (nonatomic, assign) TOSTransferWorkState state;
@property (nonatomic, strong, nullable) TOSTransferConcurrencyAcquisition *concurrencyAcquisition;
@property (nonatomic, strong, nullable) TOSTransferConcurrencyPermit *concurrencyPermit;
@end

@implementation TOSTransferWorkItem
@end

static NSInteger const TOSResumableTransferMaxTaskNum = 1000;

NSInteger TOSNormalizeResumableTransferTaskNum(NSInteger taskNum) {
    return MIN(TOSResumableTransferMaxTaskNum, MAX(1, taskNum));
}

@interface TOSTransferOperation ()
@property (nonatomic, strong) TOSTaskCompletionSource<NSArray *> *tos_taskSource;
@property (nonatomic, strong, readwrite) TOSTask<NSArray *> *task;
@property (nonatomic, assign, readwrite) NSInteger effectiveTaskNum;
@property (nonatomic, strong, readwrite) TOSTransferNetworkCancellation *networkCancellation;
@property (nonatomic, assign) NSInteger tos_maxRetryCount;
@property (nonatomic, strong, nullable) TOSCancelHook *tos_cancelHook;
@property (nonatomic, strong) TOSTransferProgress *tos_progress;
@property (nonatomic, strong) dispatch_queue_t tos_stateQueue;
@property (nonatomic, copy) TOSTransferRandomSource tos_randomSource;
@property (nonatomic, copy) TOSTransferDelayScheduler tos_delayScheduler;
@property (nonatomic, strong) TOSTransferConcurrencyController *tos_concurrencyController;
@property (nonatomic, strong) NSArray<TOSTransferWorkItem *> *tos_workItems;
@property (nonatomic, strong) NSMutableArray *tos_results;
@property (nonatomic, assign) NSInteger tos_nextIndex;
@property (nonatomic, assign) NSInteger tos_activeCount;
@property (nonatomic, assign) BOOL tos_started;
@property (nonatomic, assign) BOOL tos_terminalRequested;
@property (nonatomic, assign) BOOL tos_terminalResolved;
@property (nonatomic, strong, nullable) NSError *tos_terminalError;
@end

@implementation TOSTransferOperation

- (instancetype)initWithTaskNum:(NSInteger)taskNum
                  maxRetryCount:(NSInteger)maxRetryCount
                      cancelHook:(TOSCancelHook *)cancelHook
                        progress:(TOSTransferProgress *)progress {
    return [self initWithTaskNum:taskNum
                  maxRetryCount:maxRetryCount
                      cancelHook:cancelHook
                        progress:progress
           concurrencyController:[[TOSTransferConcurrencyController alloc] initWithLimit:taskNum]];
}

- (instancetype)initWithTaskNum:(NSInteger)taskNum
                  maxRetryCount:(NSInteger)maxRetryCount
                      cancelHook:(TOSCancelHook *)cancelHook
                        progress:(TOSTransferProgress *)progress
           concurrencyController:(TOSTransferConcurrencyController *)concurrencyController {
    dispatch_queue_t stateQueue = dispatch_queue_create("com.volces.tos.transfer.operation", DISPATCH_QUEUE_SERIAL);
    TOSTransferRandomSource randomSource = ^double{
        return (double)arc4random_uniform(UINT32_MAX) / (double)UINT32_MAX;
    };
    TOSTransferDelayScheduler delayScheduler = ^(NSTimeInterval delay, dispatch_block_t block) {
        int64_t nanoseconds = (int64_t)(MAX(0, delay) * NSEC_PER_SEC);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, nanoseconds),
                       dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0),
                       block);
    };
    return [self initWithTaskNum:taskNum
                  maxRetryCount:maxRetryCount
                      cancelHook:cancelHook
                        progress:progress
                      stateQueue:stateQueue
                    randomSource:randomSource
                  delayScheduler:delayScheduler
           concurrencyController:concurrencyController];
}

- (instancetype)initWithTaskNum:(NSInteger)taskNum
                  maxRetryCount:(NSInteger)maxRetryCount
                      cancelHook:(TOSCancelHook *)cancelHook
                        progress:(TOSTransferProgress *)progress
                      stateQueue:(dispatch_queue_t)stateQueue
                    randomSource:(TOSTransferRandomSource)randomSource
                  delayScheduler:(TOSTransferDelayScheduler)delayScheduler {
    return [self initWithTaskNum:taskNum
                  maxRetryCount:maxRetryCount
                      cancelHook:cancelHook
                        progress:progress
                      stateQueue:stateQueue
                    randomSource:randomSource
                  delayScheduler:delayScheduler
           concurrencyController:[[TOSTransferConcurrencyController alloc] initWithLimit:taskNum]];
}

- (instancetype)initWithTaskNum:(NSInteger)taskNum
                  maxRetryCount:(NSInteger)maxRetryCount
                      cancelHook:(TOSCancelHook *)cancelHook
                        progress:(TOSTransferProgress *)progress
                      stateQueue:(dispatch_queue_t)stateQueue
                    randomSource:(TOSTransferRandomSource)randomSource
                  delayScheduler:(TOSTransferDelayScheduler)delayScheduler
           concurrencyController:(TOSTransferConcurrencyController *)concurrencyController {
    self = [super init];
    if (self) {
        _effectiveTaskNum = TOSNormalizeResumableTransferTaskNum(taskNum);
        _tos_maxRetryCount = MAX(0, maxRetryCount);
        _tos_cancelHook = cancelHook;
        _tos_progress = progress ?: [[TOSTransferProgress alloc] initWithListener:nil];
        _tos_stateQueue = stateQueue ?: dispatch_queue_create("com.volces.tos.transfer.operation", DISPATCH_QUEUE_SERIAL);
        _tos_randomSource = [randomSource copy];
        _tos_delayScheduler = [delayScheduler copy];
        _tos_concurrencyController = concurrencyController ?:
            [[TOSTransferConcurrencyController alloc] initWithLimit:_effectiveTaskNum];
        _networkCancellation = [TOSTransferNetworkCancellation new];
        _tos_taskSource = [TOSTaskCompletionSource taskCompletionSource];
        _task = _tos_taskSource.task;

        __weak typeof(self) weakSelf = self;
        [_tos_cancelHook tos_bindHandler:^(BOOL isAbort) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            [strongSelf.networkCancellation cancel];
            dispatch_async(strongSelf.tos_stateQueue, ^{
                [strongSelf tos_requestTerminalError:[strongSelf tos_cancellationError]];
            });
        }];
    }
    return self;
}

- (NSArray *)tos_pendingItems {
    return @[];
}

- (TOSTask<TOSTransferAttemptResult *> *)tos_attemptItem:(id)item
                                              retryCount:(NSInteger)retryCount
                                     networkCancellation:(TOSTransferNetworkCancellation *)networkCancellation {
    NSError *error = [NSError errorWithDomain:TOSClientErrorDomain
                                         code:400
                                     userInfo:@{TOSErrorMessageTOKEN: @"传输操作未实现分段尝试"}];
    return [TOSTask taskWithError:error];
}

- (void)start {
    dispatch_async(self.tos_stateQueue, ^{
        if (self.tos_started || self.tos_terminalRequested || self.tos_terminalResolved) {
            return;
        }
        self.tos_started = YES;
        NSArray *items = [[self tos_pendingItems] copy] ?: @[];
        NSMutableArray<TOSTransferWorkItem *> *workItems = [NSMutableArray arrayWithCapacity:items.count];
        self.tos_results = [NSMutableArray arrayWithCapacity:items.count];
        [items enumerateObjectsUsingBlock:^(id item, NSUInteger index, BOOL *stop) {
            TOSTransferWorkItem *workItem = [TOSTransferWorkItem new];
            workItem.item = item;
            workItem.index = (NSInteger)index;
            workItem.state = TOSTransferWorkStatePending;
            [workItems addObject:workItem];
            [self.tos_results addObject:NSNull.null];
        }];
        self.tos_workItems = workItems;
        [self tos_scheduleMore];
    });
}

- (void)tos_scheduleMore {
    if (self.tos_terminalRequested || self.tos_terminalResolved) {
        [self tos_resolveTerminalIfDrained];
        return;
    }
    NSInteger schedulingLimit = MIN(self.effectiveTaskNum, self.tos_concurrencyController.limit);
    while (self.tos_activeCount < schedulingLimit &&
           self.tos_nextIndex < self.tos_workItems.count) {
        TOSTransferWorkItem *workItem = self.tos_workItems[self.tos_nextIndex++];
        workItem.state = TOSTransferWorkStateWaitingForPermit;
        self.tos_activeCount += 1;
        [self tos_acquirePermitForWorkItem:workItem];
    }
    if (self.tos_nextIndex >= self.tos_workItems.count && self.tos_activeCount == 0) {
        [self tos_requestTerminalError:nil];
    }
}

- (void)tos_acquirePermitForWorkItem:(TOSTransferWorkItem *)workItem {
    if (self.tos_terminalRequested || workItem.state != TOSTransferWorkStateWaitingForPermit) {
        [self tos_finishWorkItem:workItem];
        return;
    }
    __weak typeof(self) weakSelf = self;
    workItem.concurrencyAcquisition =
        [self.tos_concurrencyController tos_acquire:^(TOSTransferConcurrencyPermit *permit) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            [permit releasePermit];
            return;
        }
        dispatch_async(strongSelf.tos_stateQueue, ^{
            workItem.concurrencyAcquisition = nil;
            if (!permit) {
                if (workItem.state == TOSTransferWorkStateWaitingForPermit) {
                    [strongSelf tos_finishWorkItem:workItem];
                }
                return;
            }
            if (strongSelf.tos_terminalRequested ||
                workItem.state != TOSTransferWorkStateWaitingForPermit) {
                [permit releasePermit];
                [strongSelf tos_finishWorkItem:workItem];
                return;
            }
            workItem.concurrencyPermit = permit;
            workItem.state = TOSTransferWorkStateRunning;
            [strongSelf tos_startAttemptForWorkItem:workItem];
        });
    }];
}

- (void)tos_startAttemptForWorkItem:(TOSTransferWorkItem *)workItem {
    if (self.tos_terminalRequested || workItem.state != TOSTransferWorkStateRunning) {
        [self tos_finishWorkItem:workItem];
        return;
    }

    TOSTask<TOSTransferAttemptResult *> *attemptTask = [self tos_attemptItem:workItem.item
                                                                 retryCount:workItem.retryCount
                                                        networkCancellation:self.networkCancellation];
    if (!attemptTask) {
        [workItem.concurrencyPermit releasePermit];
        workItem.concurrencyPermit = nil;
        NSError *error = [NSError errorWithDomain:TOSClientErrorDomain
                                             code:400
                                         userInfo:@{TOSErrorMessageTOKEN: @"传输分段尝试返回了空任务"}];
        [self tos_handleAttemptResult:nil taskError:error workItem:workItem];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [attemptTask continueWithBlock:^id(TOSTask<TOSTransferAttemptResult *> *task) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return nil;
        }
        dispatch_async(strongSelf.tos_stateQueue, ^{
            [workItem.concurrencyPermit releasePermit];
            workItem.concurrencyPermit = nil;
            [strongSelf tos_handleAttemptResult:task.result taskError:task.error workItem:workItem];
        });
        return nil;
    }];
}

- (void)tos_handleAttemptResult:(TOSTransferAttemptResult *)result
                      taskError:(NSError *)taskError
                       workItem:(TOSTransferWorkItem *)workItem {
    if (workItem.state != TOSTransferWorkStateRunning) {
        return;
    }
    if (self.tos_terminalRequested) {
        [self tos_finishWorkItem:workItem];
        return;
    }

    NSError *error = taskError ?: result.error;
    if (!result && !error) {
        error = [NSError errorWithDomain:TOSClientErrorDomain
                                    code:400
                                userInfo:@{TOSErrorMessageTOKEN: @"传输分段尝试缺少结果"}];
    }
    NSInteger statusCode = result.statusCode;
    if (error && TOSTransferShouldRetry(error, statusCode) &&
        workItem.retryCount < self.tos_maxRetryCount) {
        NSInteger retryIndex = workItem.retryCount;
        workItem.retryCount += 1;
        workItem.state = TOSTransferWorkStateWaitingForRetry;
        workItem.delayGeneration += 1;
        NSUInteger generation = workItem.delayGeneration;
        double randomUnit = self.tos_randomSource ? self.tos_randomSource() : 0.5;
        NSTimeInterval delay = TOSTransferRetryDelay(retryIndex, result.retryAfter, randomUnit);
        __weak typeof(self) weakSelf = self;
        self.tos_delayScheduler(delay, ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            dispatch_async(strongSelf.tos_stateQueue, ^{
                if (workItem.state != TOSTransferWorkStateWaitingForRetry ||
                    workItem.delayGeneration != generation) {
                    return;
                }
                if (strongSelf.tos_terminalRequested) {
                    [strongSelf tos_finishWorkItem:workItem];
                    return;
                }
                workItem.state = TOSTransferWorkStateWaitingForPermit;
                [strongSelf tos_acquirePermitForWorkItem:workItem];
            });
        });
        return;
    }

    if (error) {
        [self tos_requestTerminalError:error];
        [self tos_finishWorkItem:workItem];
        return;
    }

    self.tos_results[workItem.index] = result.value ?: NSNull.null;
    [self tos_finishWorkItem:workItem];
    [self tos_scheduleMore];
}

- (void)tos_finishWorkItem:(TOSTransferWorkItem *)workItem {
    if (workItem.state == TOSTransferWorkStateFinished ||
        workItem.state == TOSTransferWorkStatePending) {
        return;
    }
    workItem.state = TOSTransferWorkStateFinished;
    [workItem.concurrencyPermit releasePermit];
    workItem.concurrencyPermit = nil;
    self.tos_activeCount -= 1;
    [self tos_resolveTerminalIfDrained];
}

- (void)tos_requestTerminalError:(NSError *)error {
    if (self.tos_terminalRequested || self.tos_terminalResolved) {
        return;
    }
    self.tos_terminalRequested = YES;
    self.tos_terminalError = error;
    if (error) {
        [self.networkCancellation cancel];
    }
    for (TOSTransferWorkItem *workItem in self.tos_workItems) {
        if (workItem.state == TOSTransferWorkStateWaitingForPermit) {
            [workItem.concurrencyAcquisition cancel];
        } else if (workItem.state == TOSTransferWorkStateWaitingForRetry) {
            workItem.delayGeneration += 1;
            [self tos_finishWorkItem:workItem];
        }
    }
    [self tos_resolveTerminalIfDrained];
}

- (void)tos_resolveTerminalIfDrained {
    if (!self.tos_terminalRequested || self.tos_terminalResolved || self.tos_activeCount != 0) {
        return;
    }
    self.tos_terminalResolved = YES;
    NSError *terminalError = self.tos_terminalError;
    NSArray *results = [self.tos_results copy] ?: @[];
    dispatch_block_t completion = ^{
        if (terminalError) {
            [self.tos_taskSource trySetError:terminalError];
        } else {
            [self.tos_taskSource trySetResult:results];
        }
    };
    [self.tos_progress tos_finishWithType:terminalError ? TOSDataTransferFailed : TOSDataTransferSucceed
                              completion:completion];
}

- (NSError *)tos_cancellationError {
    return [NSError errorWithDomain:TOSClientErrorDomain
                               code:400
                           userInfo:@{TOSErrorMessageTOKEN: @"This task has been cancelled!"}];
}

@end
