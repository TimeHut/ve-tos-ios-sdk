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

NS_ASSUME_NONNULL_BEGIN

@interface TOSTransferPart : NSObject
@property (nonatomic, assign) NSInteger tos_partNumber;
@property (nonatomic, assign) int64_t tos_offset;
@property (nonatomic, assign) int64_t tos_size;
@property (nonatomic, assign) int64_t tos_rangeStart;
@property (nonatomic, assign) int64_t tos_rangeEnd;
@property (nonatomic, assign) BOOL tos_zeroSize;
@property (nonatomic, assign) BOOL tos_completed;
@property (nonatomic, copy, nullable) NSString *tos_eTag;
@property (nonatomic, assign) uint64_t tos_crc64;
// Runtime-only logical progress watermark. It is deliberately not serialized.
@property (nonatomic, assign) int64_t tos_reportedBytes;
@end

@interface TOSTransferCheckpoint : NSObject
@property (nonatomic, assign) NSInteger tos_schemaVersion;
@property (nonatomic, copy) NSString *tos_checkpointID;
@property (nonatomic, copy) NSString *tos_operation;
@property (nonatomic, copy) NSString *tos_bucket;
@property (nonatomic, copy) NSString *tos_key;
@property (nonatomic, assign) int64_t tos_partSize;
@property (nonatomic, copy) NSString *tos_checkpointPath;
@property (nonatomic, strong) NSArray<TOSTransferPart *> *tos_parts;
@property (nonatomic, copy, readonly) NSDictionary *tos_dictionaryRepresentation;
@end

@interface TOSUploadCheckpointV2 : TOSTransferCheckpoint
@property (nonatomic, copy) NSString *tos_encodingType;
@property (nonatomic, copy) NSString *tos_uploadID;
@property (nonatomic, copy) NSString *tos_filePath;
@property (nonatomic, assign) int64_t tos_fileSize;
@property (nonatomic, assign) int64_t tos_fileModifiedTime;
+ (nullable instancetype)tos_checkpointWithData:(NSData *)data
                                 checkpointPath:(NSString *)checkpointPath
                                          error:(NSError * _Nullable * _Nullable)error;
- (BOOL)tos_validateForBucket:(NSString *)bucket
                          key:(NSString *)key
                     partSize:(int64_t)partSize
                 encodingType:(nullable NSString *)encodingType
                     filePath:(NSString *)filePath
                     fileSize:(int64_t)fileSize
             fileModifiedTime:(int64_t)fileModifiedTime
                        error:(NSError * _Nullable * _Nullable)error;
@end

@interface TOSDownloadCheckpoint : TOSTransferCheckpoint
@property (nonatomic, copy) NSString *tos_versionID;
@property (nonatomic, copy) NSString *tos_ifMatch;
@property (nonatomic, assign) int64_t tos_ifModifiedSince;
@property (nonatomic, copy) NSString *tos_ifNoneMatch;
@property (nonatomic, assign) int64_t tos_ifUnmodifiedSince;
@property (nonatomic, copy) NSString *tos_objectETag;
@property (nonatomic, assign) int64_t tos_objectLastModified;
@property (nonatomic, assign) int64_t tos_objectSize;
@property (nonatomic, assign) uint64_t tos_objectCRC64;
@property (nonatomic, copy) NSString *tos_filePath;
@property (nonatomic, copy) NSString *tos_tempFilePath;
@property (nonatomic, assign) BOOL tos_hasTempFileIdentity;
@property (nonatomic, assign) uint64_t tos_tempFileDevice;
@property (nonatomic, assign) uint64_t tos_tempFileInode;
+ (nullable instancetype)tos_checkpointWithData:(NSData *)data
                                 checkpointPath:(NSString *)checkpointPath
                                          error:(NSError * _Nullable * _Nullable)error;
- (BOOL)tos_validateForBucket:(NSString *)bucket
                          key:(NSString *)key
                    versionID:(nullable NSString *)versionID
                     partSize:(int64_t)partSize
                     filePath:(NSString *)filePath
                 tempFilePath:(NSString *)tempFilePath
                      ifMatch:(nullable NSString *)ifMatch
              ifModifiedSince:(int64_t)ifModifiedSince
                  ifNoneMatch:(nullable NSString *)ifNoneMatch
            ifUnmodifiedSince:(int64_t)ifUnmodifiedSince
                   objectETag:(NSString *)objectETag
           objectLastModified:(int64_t)objectLastModified
                   objectSize:(int64_t)objectSize
                  objectCRC64:(uint64_t)objectCRC64
           actualTempFileSize:(int64_t)actualTempFileSize
                        error:(NSError * _Nullable * _Nullable)error;
@end

@interface TOSCopyCheckpoint : TOSTransferCheckpoint
@property (nonatomic, copy) NSString *tos_encodingType;
@property (nonatomic, copy) NSString *tos_srcBucket;
@property (nonatomic, copy) NSString *tos_srcKey;
@property (nonatomic, copy) NSString *tos_srcVersionID;
@property (nonatomic, copy) NSString *tos_uploadID;
@property (nonatomic, copy) NSString *tos_copySourceIfMatch;
@property (nonatomic, assign) int64_t tos_copySourceIfModifiedSince;
@property (nonatomic, copy) NSString *tos_copySourceIfNoneMatch;
@property (nonatomic, assign) int64_t tos_copySourceIfUnmodifiedSince;
@property (nonatomic, copy) NSString *tos_sourceETag;
@property (nonatomic, assign) int64_t tos_sourceLastModified;
@property (nonatomic, assign) int64_t tos_sourceSize;
@property (nonatomic, assign) uint64_t tos_sourceCRC64;
+ (nullable instancetype)tos_checkpointWithData:(NSData *)data
                                 checkpointPath:(NSString *)checkpointPath
                                          error:(NSError * _Nullable * _Nullable)error;
- (BOOL)tos_validateForSourceBucket:(NSString *)srcBucket
                          sourceKey:(NSString *)srcKey
                    sourceVersionID:(nullable NSString *)srcVersionID
                             bucket:(NSString *)bucket
                                key:(NSString *)key
                           partSize:(int64_t)partSize
                       encodingType:(nullable NSString *)encodingType
                copySourceIfMatch:(nullable NSString *)copySourceIfMatch
        copySourceIfModifiedSince:(int64_t)copySourceIfModifiedSince
            copySourceIfNoneMatch:(nullable NSString *)copySourceIfNoneMatch
      copySourceIfUnmodifiedSince:(int64_t)copySourceIfUnmodifiedSince
                         sourceETag:(NSString *)sourceETag
                 sourceLastModified:(int64_t)sourceLastModified
                         sourceSize:(int64_t)sourceSize
                        sourceCRC64:(uint64_t)sourceCRC64
                              error:(NSError * _Nullable * _Nullable)error;
@end

@protocol TOSTransferCheckpointFileSystem <NSObject>
- (BOOL)tos_fileExistsAtPath:(NSString *)path isDirectory:(BOOL * _Nullable)isDirectory;
- (BOOL)tos_createDirectoryAtPath:(NSString *)path error:(NSError * _Nullable * _Nullable)error;
- (nullable NSData *)tos_dataAtPath:(NSString *)path error:(NSError * _Nullable * _Nullable)error;
- (BOOL)tos_writeData:(NSData *)data toPath:(NSString *)path error:(NSError * _Nullable * _Nullable)error;
- (BOOL)tos_setPosixPermissions:(NSNumber *)permissions atPath:(NSString *)path error:(NSError * _Nullable * _Nullable)error;
- (BOOL)tos_replaceItemAtPath:(NSString *)path withItemAtPath:(NSString *)temporaryPath error:(NSError * _Nullable * _Nullable)error;
- (void)tos_removeItemAtPath:(NSString *)path;
@end

@interface TOSTransferCheckpointStore : NSObject
- (instancetype)initWithFileSystem:(id<TOSTransferCheckpointFileSystem>)fileSystem;
- (BOOL)writeCheckpoint:(TOSTransferCheckpoint *)checkpoint error:(NSError * _Nullable * _Nullable)error;
- (BOOL)removeCheckpoint:(TOSTransferCheckpoint *)checkpoint error:(NSError * _Nullable * _Nullable)error;
@end

@interface TOSTransferCheckpointLease : NSObject
@property (nonatomic, copy, readonly) NSString *checkpointPath;
+ (nullable instancetype)acquireCheckpointPath:(NSString *)checkpointPath
                                         error:(NSError * _Nullable * _Nullable)error;
- (void)invalidate;
@end

FOUNDATION_EXPORT NSArray<TOSTransferPart *> * _Nullable TOSUploadParts(int64_t size,
                                                                        int64_t partSize,
                                                                        NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT NSArray<TOSTransferPart *> * _Nullable TOSDownloadParts(int64_t size,
                                                                          int64_t partSize,
                                                                          NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT NSArray<TOSTransferPart *> * _Nullable TOSCopyParts(int64_t size,
                                                                      int64_t partSize,
                                                                      NSError * _Nullable * _Nullable error);

FOUNDATION_EXPORT NSString * _Nullable TOSUploadCheckpointPath(NSString * _Nullable checkpointFile,
                                                                NSString *filePath,
                                                                NSString *bucket,
                                                                NSString *key,
                                                                NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT NSString * _Nullable TOSDownloadCheckpointPath(NSString * _Nullable checkpointFile,
                                                                  NSString *filePath,
                                                                  NSString *bucket,
                                                                  NSString *key,
                                                                  NSString * _Nullable versionID,
                                                                  NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT NSString * _Nullable TOSCopyCheckpointPath(NSString * _Nullable checkpointFile,
                                                              NSString *srcBucket,
                                                              NSString *srcKey,
                                                              NSString * _Nullable srcVersionID,
                                                              NSString *bucket,
                                                              NSString *key,
                                                              NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
