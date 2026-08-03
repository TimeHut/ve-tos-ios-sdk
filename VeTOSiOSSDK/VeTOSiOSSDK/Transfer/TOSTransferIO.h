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
#import "TOSTransferOperation.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^TOSTransferBytesBlock)(int64_t bytes);

@interface TOSFileRangeInputStream : NSInputStream
@property (nonatomic, assign, readonly) int tos_fileDescriptor;
@property (nonatomic, assign, readonly) int64_t tos_consumed;
@property (nonatomic, assign, readonly) uint64_t tos_crc64;
@property (nonatomic, copy, nullable) TOSTransferBytesBlock tos_bytesRead;
- (nullable instancetype)initWithFileDescriptor:(int)fileDescriptor
                                          offset:(int64_t)offset
                                          length:(int64_t)length
                                     rateLimiter:(nullable id<TOSRateLimiter>)rateLimiter
                                      cancelHook:(nullable TOSCancelHook *)cancelHook
                                           error:(NSError **)error;
- (nullable instancetype)initWithBorrowedFileDescriptor:(int)fileDescriptor
                                                  offset:(int64_t)offset
                                                  length:(int64_t)length
                                             rateLimiter:(nullable id<TOSRateLimiter>)rateLimiter
                                              cancelHook:(nullable TOSCancelHook *)cancelHook
                                                   error:(NSError **)error;
@end

@protocol TOSTransferPositionalWriting <NSObject>
- (ssize_t)tos_writeFileDescriptor:(int)fileDescriptor
                             buffer:(const void *)buffer
                             length:(size_t)length
                             offset:(off_t)offset
                         posixError:(int *)posixError;
@end

@class TOSDownloadPartWriter;

@interface TOSDownloadFileWriter : NSObject
@property (nonatomic, assign, readonly) int tos_fileDescriptor;
@property (nonatomic, copy, nullable) TOSTransferBytesBlock tos_bytesWritten;
- (nullable instancetype)initWithFilePath:(NSString *)filePath
                                     size:(int64_t)size
                                    error:(NSError **)error;
- (nullable instancetype)initWithFilePath:(NSString *)filePath
                                     size:(int64_t)size
                              rateLimiter:(nullable id<TOSRateLimiter>)rateLimiter
                               cancelHook:(nullable TOSCancelHook *)cancelHook
                                    error:(NSError **)error;
- (nullable instancetype)initWithDirectoryFileDescriptor:(int)directoryFileDescriptor
                                                 fileName:(NSString *)fileName
                                                     size:(int64_t)size
                                              rateLimiter:(nullable id<TOSRateLimiter>)rateLimiter
                                               cancelHook:(nullable TOSCancelHook *)cancelHook
                                                    error:(NSError **)error;
- (nullable instancetype)initWithDirectoryFileDescriptor:(int)directoryFileDescriptor
                                                 fileName:(NSString *)fileName
                                                     size:(int64_t)size
                                           expectedDevice:(uint64_t)expectedDevice
                                            expectedInode:(uint64_t)expectedInode
                                              rateLimiter:(nullable id<TOSRateLimiter>)rateLimiter
                                               cancelHook:(nullable TOSCancelHook *)cancelHook
                                                    error:(NSError **)error;
- (nullable instancetype)initWithFilePath:(NSString *)filePath
                                     size:(int64_t)size
                         positionalWriter:(id<TOSTransferPositionalWriting>)positionalWriter
                              rateLimiter:(nullable id<TOSRateLimiter>)rateLimiter
                               cancelHook:(nullable TOSCancelHook *)cancelHook
                                    error:(NSError **)error;
- (nullable TOSDownloadPartWriter *)partWriterWithOffset:(int64_t)offset
                                                   length:(int64_t)length
                                                    error:(NSError **)error;
- (void)close;
@end

@interface TOSDownloadPartWriter : NSObject
@property (nonatomic, assign, readonly) int64_t tos_consumed;
@property (nonatomic, assign, readonly) uint64_t tos_crc64;
@property (nonatomic, copy, nullable) TOSTransferBytesBlock tos_bytesWritten;
- (BOOL)writeData:(NSData *)data error:(NSError **)error;
- (BOOL)finish:(NSError **)error;
@end

FOUNDATION_EXPORT uint64_t TOSTransferCRC64(uint64_t crc, const void *bytes, size_t length);
FOUNDATION_EXPORT uint64_t TOSTransferCRC64Combine(uint64_t crc1, uint64_t crc2, uintmax_t length2);
FOUNDATION_EXPORT BOOL TOSTransferRenameFileAt(int sourceDirectoryFileDescriptor,
                                              NSString *sourceFileName,
                                              int destinationDirectoryFileDescriptor,
                                              NSString *destinationFileName,
                                              NSError **error);
FOUNDATION_EXPORT BOOL TOSTransferCommitFileAt(int sourceDirectoryFileDescriptor,
                                              NSString *sourceFileName,
                                              int sourceFileDescriptor,
                                              int destinationDirectoryFileDescriptor,
                                              NSString *destinationFileName,
                                              NSError **error);
FOUNDATION_EXPORT BOOL TOSTransferRemoveFileAtIfIdentity(int directoryFileDescriptor,
                                                        NSString *fileName,
                                                        uint64_t expectedDevice,
                                                        uint64_t expectedInode);

NS_ASSUME_NONNULL_END
