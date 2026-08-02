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

#import <Foundation/Foundation.h>
#import <VeTOSiOSSDK/TOSTask.h>
#import <VeTOSiOSSDK/TOSTaskCompletionSource.h>
#import "../Request/TOSModel.h"
#import "TOSInput+TransferInternal.h"

NS_ASSUME_NONNULL_BEGIN

typedef NSTimeInterval (^TOSTransferMonotonicClock)(void);

@interface TOSCancelHook (TransferInternal)
- (void)tos_bindHandler:(void (^)(BOOL isAbort))handler;
@property (nonatomic, assign, readonly) BOOL tos_isCancelled;
@property (nonatomic, assign, readonly) BOOL tos_shouldAbort;
@end

@interface TOSDefaultRateLimiter (TransferInternal)
- (nullable instancetype)initWithCapacity:(int64_t)capacity
                                     rate:(int64_t)rate
                                    clock:(TOSTransferMonotonicClock)clock;
- (int64_t)tos_maximumAcquisitionSize;
@end

@interface TOSTransferProgress : NSObject
- (instancetype)initWithListener:(nullable TOSDataTransferListener)listener;
- (instancetype)initWithListener:(nullable TOSDataTransferListener)listener
                       stateQueue:(dispatch_queue_t)stateQueue;
- (void)startWithTotal:(int64_t)total consumed:(int64_t)consumed;
- (void)recordBytes:(int64_t)bytes;
- (void)finish;
- (void)fail;
- (void)waitUntilIdle;
@end

@interface TOSTransferAttemptResult : NSObject
@property (nonatomic, strong, nullable) id value;
@property (nonatomic, strong, nullable) NSError *error;
@property (nonatomic, assign) NSInteger statusCode;
@property (nonatomic, assign) NSTimeInterval retryAfter;
@end

@interface TOSTransferResponseMetadata : NSObject
@property (atomic, assign) NSTimeInterval retryAfter;
@end

typedef double (^TOSTransferRandomSource)(void);
typedef void (^TOSTransferDelayScheduler)(NSTimeInterval delay, dispatch_block_t block);

@interface TOSTransferConcurrencyController : NSObject
@property (nonatomic, assign, readonly) NSInteger limit;
- (instancetype)initWithLimit:(NSInteger)limit;
@end

FOUNDATION_EXPORT BOOL TOSTransferShouldRetry(NSError * _Nullable error, NSInteger statusCode);
FOUNDATION_EXPORT NSTimeInterval
TOSTransferRetryAfterDelayForResponse(NSHTTPURLResponse * _Nullable response);
FOUNDATION_EXPORT TOSTransferResponseObserver
TOSTransferRetryAfterObserver(TOSTransferResponseMetadata *metadata);
FOUNDATION_EXPORT NSTimeInterval TOSTransferRetryDelay(NSInteger retryIndex,
                                                       NSTimeInterval retryAfter,
                                                       double randomUnit);
FOUNDATION_EXPORT NSInteger TOSNormalizeResumableTransferTaskNum(NSInteger taskNum);
FOUNDATION_EXPORT NSError * _Nullable
TOSTransferValidateCompleteMultipartUploadOutput(id _Nullable output,
                                                 NSString *bucket,
                                                 NSString *key,
                                                 BOOL callbackEnabled);

@interface TOSTransferOperation : NSObject
@property (nonatomic, strong, readonly) TOSTask<NSArray *> *task;
@property (nonatomic, assign, readonly) NSInteger effectiveTaskNum;
@property (nonatomic, strong, readonly) TOSTransferNetworkCancellation *networkCancellation;

- (instancetype)initWithTaskNum:(NSInteger)taskNum
                  maxRetryCount:(NSInteger)maxRetryCount
                      cancelHook:(nullable TOSCancelHook *)cancelHook
                        progress:(TOSTransferProgress *)progress;

- (instancetype)initWithTaskNum:(NSInteger)taskNum
                  maxRetryCount:(NSInteger)maxRetryCount
                      cancelHook:(nullable TOSCancelHook *)cancelHook
                        progress:(TOSTransferProgress *)progress
           concurrencyController:(TOSTransferConcurrencyController *)concurrencyController;

- (instancetype)initWithTaskNum:(NSInteger)taskNum
                  maxRetryCount:(NSInteger)maxRetryCount
                      cancelHook:(nullable TOSCancelHook *)cancelHook
                        progress:(TOSTransferProgress *)progress
                      stateQueue:(dispatch_queue_t)stateQueue
                    randomSource:(TOSTransferRandomSource)randomSource
                  delayScheduler:(TOSTransferDelayScheduler)delayScheduler;

- (void)start;

// Subclasses provide an immutable pending-item snapshot and a fresh task for every attempt.
- (NSArray *)tos_pendingItems;
- (TOSTask<TOSTransferAttemptResult *> *)tos_attemptItem:(id)item
                                              retryCount:(NSInteger)retryCount
                                     networkCancellation:(TOSTransferNetworkCancellation *)networkCancellation;
@end

NS_ASSUME_NONNULL_END
