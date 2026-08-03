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

#import "TOSTransferCheckpoint.h"
#import "../Utility/TOSConstants.h"
#import <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

static const NSInteger TOSTransferCheckpointInvalidArgument = 1001;

@implementation TOSTransferPart
@end

static NSError *TOSTransferCheckpointError(NSString *message) {
    return [NSError errorWithDomain:TOSClientErrorDomain
                               code:TOSTransferCheckpointInvalidArgument
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSArray<TOSTransferPart *> *TOSPlanParts(int64_t size,
                                                int64_t partSize,
                                                BOOL createZeroPart,
                                                NSError * _Nullable * _Nullable error);

static BOOL TOSCheckpointFail(NSError * _Nullable * _Nullable error, NSString *message) {
    if (error) {
        *error = TOSTransferCheckpointError(message);
    }
    return NO;
}

static BOOL TOSCheckpointReadString(NSDictionary *dictionary,
                                    NSString *key,
                                    BOOL allowEmpty,
                                    NSString **result,
                                    NSError * _Nullable * _Nullable error) {
    id value = dictionary[key];
    if (![value isKindOfClass:[NSString class]] || (!allowEmpty && [value length] == 0)) {
        return TOSCheckpointFail(error, [NSString stringWithFormat:@"checkpoint 字段 %@ 必须是%@字符串", key, allowEmpty ? @"" : @"非空"]);
    }
    if (result) {
        *result = value;
    }
    return YES;
}

static BOOL TOSCheckpointReadInteger(NSDictionary *dictionary,
                                     NSString *key,
                                     int64_t minimum,
                                     int64_t *result,
                                     NSError * _Nullable * _Nullable error) {
    id value = dictionary[key];
    if (![value isKindOfClass:[NSNumber class]] ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
        return TOSCheckpointFail(error, [NSString stringWithFormat:@"checkpoint 字段 %@ 必须是整数", key]);
    }
    double number = [value doubleValue];
    if (!isfinite(number) || floor(number) != number || number < (double)minimum || number >= 9223372036854775808.0) {
        return TOSCheckpointFail(error, [NSString stringWithFormat:@"checkpoint 字段 %@ 超出整数范围", key]);
    }
    if (result) {
        *result = [value longLongValue];
    }
    return YES;
}

static BOOL TOSCheckpointReadBool(NSDictionary *dictionary,
                                  NSString *key,
                                  BOOL *result,
                                  NSError * _Nullable * _Nullable error) {
    id value = dictionary[key];
    if (![value isKindOfClass:[NSNumber class]] ||
        CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) {
        return TOSCheckpointFail(error, [NSString stringWithFormat:@"checkpoint 字段 %@ 必须是布尔值", key]);
    }
    if (result) {
        *result = [value boolValue];
    }
    return YES;
}

static BOOL TOSCheckpointParseUInt64(NSDictionary *dictionary,
                                     NSString *key,
                                     uint64_t *result,
                                     NSError * _Nullable * _Nullable error) {
    NSString *value = nil;
    if (!TOSCheckpointReadString(dictionary, key, NO, &value, error)) {
        return NO;
    }
    if (value.length > 1 && [value hasPrefix:@"0"]) {
        return TOSCheckpointFail(error, [NSString stringWithFormat:@"checkpoint 字段 %@ 不是规范的无符号整数", key]);
    }
    NSCharacterSet *notDigit = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    if ([value rangeOfCharacterFromSet:notDigit].location != NSNotFound) {
        return TOSCheckpointFail(error, [NSString stringWithFormat:@"checkpoint 字段 %@ 必须是十进制无符号整数", key]);
    }
    errno = 0;
    char *end = NULL;
    unsigned long long parsed = strtoull(value.UTF8String, &end, 10);
    if (errno == ERANGE || !end || *end != '\0') {
        return TOSCheckpointFail(error, [NSString stringWithFormat:@"checkpoint 字段 %@ 超出无符号整数范围", key]);
    }
    if (result) {
        *result = (uint64_t)parsed;
    }
    return YES;
}

static NSDictionary *TOSCheckpointJSONObject(NSData *data, NSError * _Nullable * _Nullable error) {
    if (data.length == 0) {
        TOSCheckpointFail(error, @"checkpoint JSON 为空");
        return nil;
    }
    NSError *jsonError = nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (![object isKindOfClass:[NSDictionary class]]) {
        NSString *message = jsonError.localizedDescription ?: @"根节点必须是对象";
        TOSCheckpointFail(error, [NSString stringWithFormat:@"checkpoint JSON 无效：%@", message]);
        return nil;
    }
    return object;
}

static NSString *TOSCheckpointUInt64String(uint64_t value) {
    return [NSString stringWithFormat:@"%llu", (unsigned long long)value];
}

static NSDictionary *TOSCheckpointPartDictionary(TOSTransferPart *part) {
    return @{ @"part_number": @(part.tos_partNumber),
              @"offset": @(part.tos_offset),
              @"size": @(part.tos_size),
              @"range_start": @(part.tos_rangeStart),
              @"range_end": @(part.tos_rangeEnd),
              @"is_zero_size": @(part.tos_zeroSize),
              @"is_completed": @(part.tos_completed),
              @"etag": part.tos_eTag ?: @"",
              @"crc64": TOSCheckpointUInt64String(part.tos_crc64) };
}

static NSArray<NSDictionary *> *TOSCheckpointPartDictionaries(NSArray<TOSTransferPart *> *parts) {
    NSMutableArray<NSDictionary *> *result = [NSMutableArray arrayWithCapacity:parts.count];
    for (TOSTransferPart *part in parts) {
        [result addObject:TOSCheckpointPartDictionary(part)];
    }
    return result;
}

static NSDictionary *TOSCheckpointBaseDictionary(TOSTransferCheckpoint *checkpoint) {
    return @{ @"schema_version": @(checkpoint.tos_schemaVersion),
              @"checkpoint_id": checkpoint.tos_checkpointID ?: @"",
              @"operation": checkpoint.tos_operation ?: @"",
              @"bucket": checkpoint.tos_bucket ?: @"",
              @"key": checkpoint.tos_key ?: @"",
              @"part_size": @(checkpoint.tos_partSize),
              @"parts": TOSCheckpointPartDictionaries(checkpoint.tos_parts ?: @[]) };
}

static NSArray<TOSTransferPart *> *TOSCheckpointParseParts(NSDictionary *dictionary,
                                                           int64_t totalSize,
                                                           int64_t partSize,
                                                           BOOL createZeroPart,
                                                           BOOL requiresCompletedETag,
                                                           NSError * _Nullable * _Nullable error) {
    id rawParts = dictionary[@"parts"];
    if (![rawParts isKindOfClass:[NSArray class]]) {
        TOSCheckpointFail(error, @"checkpoint 字段 parts 必须是数组");
        return nil;
    }
    NSArray<TOSTransferPart *> *planned = TOSPlanParts(totalSize, partSize, createZeroPart, error);
    if (!planned || [rawParts count] != planned.count) {
        if (planned) {
            TOSCheckpointFail(error, @"checkpoint 分段数量与对象大小不一致");
        }
        return nil;
    }

    NSMutableArray<TOSTransferPart *> *parts = [NSMutableArray arrayWithCapacity:planned.count];
    for (NSUInteger index = 0; index < planned.count; index++) {
        id rawPart = rawParts[index];
        if (![rawPart isKindOfClass:[NSDictionary class]]) {
            TOSCheckpointFail(error, @"checkpoint 分段必须是对象");
            return nil;
        }
        int64_t partNumber = 0;
        int64_t offset = 0;
        int64_t size = 0;
        int64_t rangeStart = 0;
        int64_t rangeEnd = 0;
        BOOL zeroSize = NO;
        BOOL completed = NO;
        NSString *eTag = nil;
        uint64_t crc64 = 0;
        if (!TOSCheckpointReadInteger(rawPart, @"part_number", 1, &partNumber, error) ||
            !TOSCheckpointReadInteger(rawPart, @"offset", 0, &offset, error) ||
            !TOSCheckpointReadInteger(rawPart, @"size", 0, &size, error) ||
            !TOSCheckpointReadInteger(rawPart, @"range_start", 0, &rangeStart, error) ||
            !TOSCheckpointReadInteger(rawPart, @"range_end", -1, &rangeEnd, error) ||
            !TOSCheckpointReadBool(rawPart, @"is_zero_size", &zeroSize, error) ||
            !TOSCheckpointReadBool(rawPart, @"is_completed", &completed, error) ||
            !TOSCheckpointReadString(rawPart, @"etag", YES, &eTag, error) ||
            !TOSCheckpointParseUInt64(rawPart, @"crc64", &crc64, error)) {
            return nil;
        }

        TOSTransferPart *expected = planned[index];
        if (partNumber != expected.tos_partNumber ||
            offset != expected.tos_offset ||
            size != expected.tos_size ||
            rangeStart != expected.tos_rangeStart ||
            rangeEnd != expected.tos_rangeEnd ||
            zeroSize != expected.tos_zeroSize) {
            TOSCheckpointFail(error, @"checkpoint 分段编号、偏移或范围不连续");
            return nil;
        }
        if (completed && requiresCompletedETag && eTag.length == 0) {
            TOSCheckpointFail(error, @"已完成的上传或复制分段必须包含 ETag");
            return nil;
        }

        expected.tos_completed = completed;
        expected.tos_eTag = eTag;
        expected.tos_crc64 = crc64;
        [parts addObject:expected];
    }
    return parts;
}

static BOOL TOSCheckpointParseBase(NSDictionary *dictionary,
                                   NSString *operation,
                                   int64_t totalSize,
                                   BOOL createZeroPart,
                                   BOOL requiresCompletedETag,
                                   TOSTransferCheckpoint *checkpoint,
                                   NSError * _Nullable * _Nullable error) {
    int64_t schemaVersion = 0;
    int64_t partSize = 0;
    NSString *parsedOperation = nil;
    NSString *checkpointID = nil;
    NSString *bucket = nil;
    NSString *key = nil;
    if (!TOSCheckpointReadInteger(dictionary, @"schema_version", 1, &schemaVersion, error) ||
        schemaVersion != 1) {
        if (schemaVersion != 1 && (!error || !*error)) {
            TOSCheckpointFail(error, @"不支持的 checkpoint schema_version");
        }
        return NO;
    }
    if (!TOSCheckpointReadString(dictionary, @"operation", NO, &parsedOperation, error) ||
        ![parsedOperation isEqualToString:operation]) {
        if (parsedOperation && (!error || !*error)) {
            TOSCheckpointFail(error, @"checkpoint operation 与当前传输类型不匹配");
        }
        return NO;
    }
    id rawCheckpointID = dictionary[@"checkpoint_id"];
    if (rawCheckpointID &&
        !TOSCheckpointReadString(dictionary, @"checkpoint_id", NO, &checkpointID, error)) {
        return NO;
    }
    if (!TOSCheckpointReadString(dictionary, @"bucket", NO, &bucket, error) ||
        !TOSCheckpointReadString(dictionary, @"key", NO, &key, error) ||
        !TOSCheckpointReadInteger(dictionary, @"part_size", 1, &partSize, error)) {
        return NO;
    }

    NSArray<TOSTransferPart *> *parts = TOSCheckpointParseParts(dictionary,
                                                                totalSize,
                                                                partSize,
                                                                createZeroPart,
                                                                requiresCompletedETag,
                                                                error);
    if (!parts) {
        return NO;
    }
    checkpoint.tos_schemaVersion = (NSInteger)schemaVersion;
    if (checkpointID.length > 0) {
        checkpoint.tos_checkpointID = checkpointID;
    }
    checkpoint.tos_operation = parsedOperation;
    checkpoint.tos_bucket = bucket;
    checkpoint.tos_key = key;
    checkpoint.tos_partSize = partSize;
    checkpoint.tos_parts = parts;
    return YES;
}

static BOOL TOSCheckpointHasCompletedParts(NSArray<TOSTransferPart *> *parts) {
    for (TOSTransferPart *part in parts) {
        if (part.tos_completed) {
            return YES;
        }
    }
    return NO;
}

@implementation TOSTransferCheckpoint

- (instancetype)init {
    self = [super init];
    if (self) {
        _tos_checkpointID = NSUUID.UUID.UUIDString;
    }
    return self;
}

- (NSDictionary *)tos_dictionaryRepresentation {
    return TOSCheckpointBaseDictionary(self);
}

@end

@implementation TOSUploadCheckpointV2

+ (instancetype)tos_checkpointWithData:(NSData *)data
                         checkpointPath:(NSString *)checkpointPath
                                  error:(NSError * _Nullable * _Nullable)error {
    NSDictionary *dictionary = TOSCheckpointJSONObject(data, error);
    if (!dictionary) {
        return nil;
    }
    NSString *uploadID = nil;
    NSString *encodingType = nil;
    NSString *filePath = nil;
    int64_t fileSize = 0;
    int64_t fileModifiedTime = 0;
    if (!TOSCheckpointReadString(dictionary, @"encoding_type", YES, &encodingType, error) ||
        !TOSCheckpointReadString(dictionary, @"upload_id", YES, &uploadID, error) ||
        !TOSCheckpointReadString(dictionary, @"file_path", NO, &filePath, error) ||
        !TOSCheckpointReadInteger(dictionary, @"file_size", 0, &fileSize, error) ||
        !TOSCheckpointReadInteger(dictionary, @"file_modified_time", INT64_MIN, &fileModifiedTime, error)) {
        return nil;
    }
    if (!encodingType || !uploadID || !filePath) {
        TOSCheckpointFail(error, @"上传 checkpoint 字符串字段解析失败");
        return nil;
    }
    TOSUploadCheckpointV2 *checkpoint = [TOSUploadCheckpointV2 new];
    if (!TOSCheckpointParseBase(dictionary, @"upload", fileSize, YES, YES, checkpoint, error)) {
        return nil;
    }
    if (uploadID.length == 0 && TOSCheckpointHasCompletedParts(checkpoint.tos_parts)) {
        TOSCheckpointFail(error, @"包含已完成分段的上传 checkpoint 必须包含 upload_id");
        return nil;
    }
    checkpoint.tos_checkpointPath = checkpointPath;
    checkpoint.tos_encodingType = encodingType;
    checkpoint.tos_uploadID = uploadID;
    checkpoint.tos_filePath = filePath;
    checkpoint.tos_fileSize = fileSize;
    checkpoint.tos_fileModifiedTime = fileModifiedTime;
    return checkpoint;
}

- (NSDictionary *)tos_dictionaryRepresentation {
    NSMutableDictionary *dictionary = [TOSCheckpointBaseDictionary(self) mutableCopy];
    dictionary[@"encoding_type"] = self.tos_encodingType ?: @"";
    dictionary[@"upload_id"] = self.tos_uploadID ?: @"";
    dictionary[@"file_path"] = self.tos_filePath ?: @"";
    dictionary[@"file_size"] = @(self.tos_fileSize);
    dictionary[@"file_modified_time"] = @(self.tos_fileModifiedTime);
    return [dictionary copy];
}

- (BOOL)tos_validateForBucket:(NSString *)bucket
                          key:(NSString *)key
                     partSize:(int64_t)partSize
                 encodingType:(NSString *)encodingType
                     filePath:(NSString *)filePath
                     fileSize:(int64_t)fileSize
             fileModifiedTime:(int64_t)fileModifiedTime
                        error:(NSError * _Nullable * _Nullable)error {
    if (![self.tos_bucket isEqualToString:bucket] ||
        ![self.tos_key isEqualToString:key] ||
        self.tos_partSize != partSize ||
        ![self.tos_encodingType isEqualToString:encodingType ?: @""] ||
        ![self.tos_filePath isEqualToString:filePath] ||
        self.tos_fileSize != fileSize ||
        self.tos_fileModifiedTime != fileModifiedTime) {
        return TOSCheckpointFail(error, @"上传 checkpoint 与请求或本地文件身份不一致");
    }
    return YES;
}

@end


@implementation TOSDownloadCheckpoint

+ (instancetype)tos_checkpointWithData:(NSData *)data
                         checkpointPath:(NSString *)checkpointPath
                                  error:(NSError * _Nullable * _Nullable)error {
    NSDictionary *dictionary = TOSCheckpointJSONObject(data, error);
    if (!dictionary) {
        return nil;
    }
    NSString *versionID = nil;
    NSString *ifMatch = nil;
    NSString *ifNoneMatch = nil;
    NSString *objectETag = nil;
    NSString *filePath = nil;
    NSString *tempFilePath = nil;
    int64_t ifModifiedSince = 0;
    int64_t ifUnmodifiedSince = 0;
    int64_t objectLastModified = 0;
    int64_t objectSize = 0;
    uint64_t objectCRC64 = 0;
    uint64_t tempFileDevice = 0;
    uint64_t tempFileInode = 0;
    if (!TOSCheckpointReadString(dictionary, @"version_id", YES, &versionID, error) ||
        !TOSCheckpointReadString(dictionary, @"if_match", YES, &ifMatch, error) ||
        !TOSCheckpointReadInteger(dictionary, @"if_modified_since", INT64_MIN, &ifModifiedSince, error) ||
        !TOSCheckpointReadString(dictionary, @"if_none_match", YES, &ifNoneMatch, error) ||
        !TOSCheckpointReadInteger(dictionary, @"if_unmodified_since", INT64_MIN, &ifUnmodifiedSince, error) ||
        !TOSCheckpointReadString(dictionary, @"object_etag", YES, &objectETag, error) ||
        !TOSCheckpointReadInteger(dictionary, @"object_last_modified", INT64_MIN, &objectLastModified, error) ||
        !TOSCheckpointReadInteger(dictionary, @"object_size", 0, &objectSize, error) ||
        !TOSCheckpointParseUInt64(dictionary, @"object_crc64", &objectCRC64, error) ||
        !TOSCheckpointReadString(dictionary, @"file_path", NO, &filePath, error) ||
        !TOSCheckpointReadString(dictionary, @"temp_file_path", NO, &tempFilePath, error)) {
        return nil;
    }
    BOOL hasTempFileDevice = dictionary[@"temp_file_device"] != nil;
    BOOL hasTempFileInode = dictionary[@"temp_file_inode"] != nil;
    if (hasTempFileDevice != hasTempFileInode) {
        TOSCheckpointFail(error, @"下载 checkpoint 临时文件身份字段必须同时存在");
        return nil;
    }
    if (hasTempFileDevice &&
        (!TOSCheckpointParseUInt64(dictionary, @"temp_file_device", &tempFileDevice, error) ||
         !TOSCheckpointParseUInt64(dictionary, @"temp_file_inode", &tempFileInode, error) ||
         tempFileInode == 0)) {
        if (tempFileInode == 0 && error && !*error) {
            TOSCheckpointFail(error, @"下载 checkpoint 临时文件 inode 必须大于 0");
        }
        return nil;
    }
    if (!versionID || !ifMatch || !ifNoneMatch || !objectETag || !filePath || !tempFilePath) {
        TOSCheckpointFail(error, @"下载 checkpoint 字符串字段解析失败");
        return nil;
    }
    TOSDownloadCheckpoint *checkpoint = [TOSDownloadCheckpoint new];
    if (!TOSCheckpointParseBase(dictionary, @"download", objectSize, NO, NO, checkpoint, error)) {
        return nil;
    }
    checkpoint.tos_checkpointPath = checkpointPath;
    checkpoint.tos_versionID = versionID;
    checkpoint.tos_ifMatch = ifMatch;
    checkpoint.tos_ifModifiedSince = ifModifiedSince;
    checkpoint.tos_ifNoneMatch = ifNoneMatch;
    checkpoint.tos_ifUnmodifiedSince = ifUnmodifiedSince;
    checkpoint.tos_objectETag = objectETag;
    checkpoint.tos_objectLastModified = objectLastModified;
    checkpoint.tos_objectSize = objectSize;
    checkpoint.tos_objectCRC64 = objectCRC64;
    checkpoint.tos_filePath = filePath;
    checkpoint.tos_tempFilePath = tempFilePath;
    checkpoint.tos_hasTempFileIdentity = hasTempFileDevice;
    checkpoint.tos_tempFileDevice = tempFileDevice;
    checkpoint.tos_tempFileInode = tempFileInode;
    return checkpoint;
}

- (NSDictionary *)tos_dictionaryRepresentation {
    NSMutableDictionary *dictionary = [TOSCheckpointBaseDictionary(self) mutableCopy];
    dictionary[@"version_id"] = self.tos_versionID ?: @"";
    dictionary[@"if_match"] = self.tos_ifMatch ?: @"";
    dictionary[@"if_modified_since"] = @(self.tos_ifModifiedSince);
    dictionary[@"if_none_match"] = self.tos_ifNoneMatch ?: @"";
    dictionary[@"if_unmodified_since"] = @(self.tos_ifUnmodifiedSince);
    dictionary[@"object_etag"] = self.tos_objectETag ?: @"";
    dictionary[@"object_last_modified"] = @(self.tos_objectLastModified);
    dictionary[@"object_size"] = @(self.tos_objectSize);
    dictionary[@"object_crc64"] = TOSCheckpointUInt64String(self.tos_objectCRC64);
    dictionary[@"file_path"] = self.tos_filePath ?: @"";
    dictionary[@"temp_file_path"] = self.tos_tempFilePath ?: @"";
    if (self.tos_hasTempFileIdentity) {
        dictionary[@"temp_file_device"] = TOSCheckpointUInt64String(self.tos_tempFileDevice);
        dictionary[@"temp_file_inode"] = TOSCheckpointUInt64String(self.tos_tempFileInode);
    }
    return [dictionary copy];
}

- (BOOL)tos_validateForBucket:(NSString *)bucket
                          key:(NSString *)key
                    versionID:(NSString *)versionID
                     partSize:(int64_t)partSize
                     filePath:(NSString *)filePath
                 tempFilePath:(NSString *)tempFilePath
                      ifMatch:(NSString *)ifMatch
              ifModifiedSince:(int64_t)ifModifiedSince
                  ifNoneMatch:(NSString *)ifNoneMatch
            ifUnmodifiedSince:(int64_t)ifUnmodifiedSince
                   objectETag:(NSString *)objectETag
           objectLastModified:(int64_t)objectLastModified
                   objectSize:(int64_t)objectSize
                  objectCRC64:(uint64_t)objectCRC64
           actualTempFileSize:(int64_t)actualTempFileSize
                        error:(NSError * _Nullable * _Nullable)error {
    NSString *resolvedVersionID = versionID ?: @"";
    if (![self.tos_bucket isEqualToString:bucket] ||
        ![self.tos_key isEqualToString:key] ||
        ![self.tos_versionID isEqualToString:resolvedVersionID] ||
        self.tos_partSize != partSize ||
        ![self.tos_filePath isEqualToString:filePath] ||
        ![self.tos_tempFilePath isEqualToString:tempFilePath] ||
        ![self.tos_ifMatch isEqualToString:ifMatch ?: @""] ||
        self.tos_ifModifiedSince != ifModifiedSince ||
        ![self.tos_ifNoneMatch isEqualToString:ifNoneMatch ?: @""] ||
        self.tos_ifUnmodifiedSince != ifUnmodifiedSince ||
        ![self.tos_objectETag isEqualToString:objectETag ?: @""] ||
        self.tos_objectLastModified != objectLastModified ||
        self.tos_objectSize != objectSize ||
        self.tos_objectCRC64 != objectCRC64 ||
        actualTempFileSize != objectSize) {
        return TOSCheckpointFail(error, @"下载 checkpoint 与请求、远端对象或临时文件身份不一致");
    }
    return YES;
}

@end


@implementation TOSCopyCheckpoint

+ (instancetype)tos_checkpointWithData:(NSData *)data
                         checkpointPath:(NSString *)checkpointPath
                                  error:(NSError * _Nullable * _Nullable)error {
    NSDictionary *dictionary = TOSCheckpointJSONObject(data, error);
    if (!dictionary) {
        return nil;
    }
    NSString *srcBucket = nil;
    NSString *srcKey = nil;
    NSString *srcVersionID = nil;
    NSString *encodingType = nil;
    NSString *uploadID = nil;
    NSString *ifMatch = nil;
    NSString *ifNoneMatch = nil;
    NSString *sourceETag = nil;
    int64_t ifModifiedSince = 0;
    int64_t ifUnmodifiedSince = 0;
    int64_t sourceLastModified = 0;
    int64_t sourceSize = 0;
    uint64_t sourceCRC64 = 0;
    if (!TOSCheckpointReadString(dictionary, @"encoding_type", YES, &encodingType, error) ||
        !TOSCheckpointReadString(dictionary, @"src_bucket", NO, &srcBucket, error) ||
        !TOSCheckpointReadString(dictionary, @"src_key", NO, &srcKey, error) ||
        !TOSCheckpointReadString(dictionary, @"src_version_id", YES, &srcVersionID, error) ||
        !TOSCheckpointReadString(dictionary, @"upload_id", YES, &uploadID, error) ||
        !TOSCheckpointReadString(dictionary, @"copy_source_if_match", YES, &ifMatch, error) ||
        !TOSCheckpointReadInteger(dictionary, @"copy_source_if_modified_since", INT64_MIN, &ifModifiedSince, error) ||
        !TOSCheckpointReadString(dictionary, @"copy_source_if_none_match", YES, &ifNoneMatch, error) ||
        !TOSCheckpointReadInteger(dictionary, @"copy_source_if_unmodified_since", INT64_MIN, &ifUnmodifiedSince, error) ||
        !TOSCheckpointReadString(dictionary, @"source_etag", YES, &sourceETag, error) ||
        !TOSCheckpointReadInteger(dictionary, @"source_last_modified", INT64_MIN, &sourceLastModified, error) ||
        !TOSCheckpointReadInteger(dictionary, @"source_size", 0, &sourceSize, error) ||
        !TOSCheckpointParseUInt64(dictionary, @"source_crc64", &sourceCRC64, error)) {
        return nil;
    }
    if (!encodingType || !srcBucket || !srcKey || !srcVersionID || !uploadID || !ifMatch || !ifNoneMatch || !sourceETag) {
        TOSCheckpointFail(error, @"复制 checkpoint 字符串字段解析失败");
        return nil;
    }
    TOSCopyCheckpoint *checkpoint = [TOSCopyCheckpoint new];
    if (!TOSCheckpointParseBase(dictionary, @"copy", sourceSize, YES, YES, checkpoint, error)) {
        return nil;
    }
    if (uploadID.length == 0 && TOSCheckpointHasCompletedParts(checkpoint.tos_parts)) {
        TOSCheckpointFail(error, @"包含已完成分段的复制 checkpoint 必须包含 upload_id");
        return nil;
    }
    checkpoint.tos_checkpointPath = checkpointPath;
    checkpoint.tos_encodingType = encodingType;
    checkpoint.tos_srcBucket = srcBucket;
    checkpoint.tos_srcKey = srcKey;
    checkpoint.tos_srcVersionID = srcVersionID;
    checkpoint.tos_uploadID = uploadID;
    checkpoint.tos_copySourceIfMatch = ifMatch;
    checkpoint.tos_copySourceIfModifiedSince = ifModifiedSince;
    checkpoint.tos_copySourceIfNoneMatch = ifNoneMatch;
    checkpoint.tos_copySourceIfUnmodifiedSince = ifUnmodifiedSince;
    checkpoint.tos_sourceETag = sourceETag;
    checkpoint.tos_sourceLastModified = sourceLastModified;
    checkpoint.tos_sourceSize = sourceSize;
    checkpoint.tos_sourceCRC64 = sourceCRC64;
    return checkpoint;
}

- (NSDictionary *)tos_dictionaryRepresentation {
    NSMutableDictionary *dictionary = [TOSCheckpointBaseDictionary(self) mutableCopy];
    dictionary[@"encoding_type"] = self.tos_encodingType ?: @"";
    dictionary[@"src_bucket"] = self.tos_srcBucket ?: @"";
    dictionary[@"src_key"] = self.tos_srcKey ?: @"";
    dictionary[@"src_version_id"] = self.tos_srcVersionID ?: @"";
    dictionary[@"upload_id"] = self.tos_uploadID ?: @"";
    dictionary[@"copy_source_if_match"] = self.tos_copySourceIfMatch ?: @"";
    dictionary[@"copy_source_if_modified_since"] = @(self.tos_copySourceIfModifiedSince);
    dictionary[@"copy_source_if_none_match"] = self.tos_copySourceIfNoneMatch ?: @"";
    dictionary[@"copy_source_if_unmodified_since"] = @(self.tos_copySourceIfUnmodifiedSince);
    dictionary[@"source_etag"] = self.tos_sourceETag ?: @"";
    dictionary[@"source_last_modified"] = @(self.tos_sourceLastModified);
    dictionary[@"source_size"] = @(self.tos_sourceSize);
    dictionary[@"source_crc64"] = TOSCheckpointUInt64String(self.tos_sourceCRC64);
    return [dictionary copy];
}

- (BOOL)tos_validateForSourceBucket:(NSString *)srcBucket
                          sourceKey:(NSString *)srcKey
                    sourceVersionID:(NSString *)srcVersionID
                             bucket:(NSString *)bucket
                                key:(NSString *)key
                           partSize:(int64_t)partSize
                       encodingType:(NSString *)encodingType
                copySourceIfMatch:(NSString *)copySourceIfMatch
        copySourceIfModifiedSince:(int64_t)copySourceIfModifiedSince
            copySourceIfNoneMatch:(NSString *)copySourceIfNoneMatch
      copySourceIfUnmodifiedSince:(int64_t)copySourceIfUnmodifiedSince
                         sourceETag:(NSString *)sourceETag
                 sourceLastModified:(int64_t)sourceLastModified
                         sourceSize:(int64_t)sourceSize
                        sourceCRC64:(uint64_t)sourceCRC64
                              error:(NSError * _Nullable * _Nullable)error {
    if (![self.tos_srcBucket isEqualToString:srcBucket] ||
        ![self.tos_srcKey isEqualToString:srcKey] ||
        ![self.tos_srcVersionID isEqualToString:srcVersionID ?: @""] ||
        ![self.tos_bucket isEqualToString:bucket] ||
        ![self.tos_key isEqualToString:key] ||
        self.tos_partSize != partSize ||
        ![self.tos_encodingType isEqualToString:encodingType ?: @""] ||
        ![self.tos_copySourceIfMatch isEqualToString:copySourceIfMatch ?: @""] ||
        self.tos_copySourceIfModifiedSince != copySourceIfModifiedSince ||
        ![self.tos_copySourceIfNoneMatch isEqualToString:copySourceIfNoneMatch ?: @""] ||
        self.tos_copySourceIfUnmodifiedSince != copySourceIfUnmodifiedSince ||
        ![self.tos_sourceETag isEqualToString:sourceETag ?: @""] ||
        self.tos_sourceLastModified != sourceLastModified ||
        self.tos_sourceSize != sourceSize ||
        self.tos_sourceCRC64 != sourceCRC64) {
        return TOSCheckpointFail(error, @"复制 checkpoint 与源对象或目标请求身份不一致");
    }
    return YES;
}

@end

static NSArray<TOSTransferPart *> *TOSPlanParts(int64_t size,
                                                int64_t partSize,
                                                BOOL createZeroPart,
                                                NSError * _Nullable * _Nullable error) {
    if (size < 0 || partSize <= 0) {
        if (error) {
            *error = TOSTransferCheckpointError(@"对象大小不能为负数，分段大小必须大于零");
        }
        return nil;
    }

    if (size == 0) {
        if (!createZeroPart) {
            return @[];
        }
        TOSTransferPart *part = [TOSTransferPart new];
        part.tos_partNumber = 1;
        part.tos_offset = 0;
        part.tos_size = 0;
        part.tos_rangeStart = 0;
        part.tos_rangeEnd = -1;
        part.tos_zeroSize = YES;
        return @[part];
    }

    int64_t partCount = size / partSize;
    if (size % partSize != 0) {
        partCount += 1;
    }
    if (partCount > 10000) {
        if (error) {
            *error = TOSTransferCheckpointError(@"分段数量不能超过 10000");
        }
        return nil;
    }

    NSMutableArray<TOSTransferPart *> *parts = [NSMutableArray arrayWithCapacity:(NSUInteger)partCount];
    for (int64_t index = 0; index < partCount; index++) {
        int64_t offset = index * partSize;
        int64_t remaining = size - offset;
        int64_t currentSize = MIN(partSize, remaining);
        TOSTransferPart *part = [TOSTransferPart new];
        part.tos_partNumber = (NSInteger)index + 1;
        part.tos_offset = offset;
        part.tos_size = currentSize;
        part.tos_rangeStart = offset;
        part.tos_rangeEnd = offset + currentSize - 1;
        [parts addObject:part];
    }
    return parts;
}

NSArray<TOSTransferPart *> *TOSUploadParts(int64_t size, int64_t partSize, NSError * _Nullable * _Nullable error) {
    return TOSPlanParts(size, partSize, YES, error);
}

NSArray<TOSTransferPart *> *TOSDownloadParts(int64_t size, int64_t partSize, NSError * _Nullable * _Nullable error) {
    return TOSPlanParts(size, partSize, NO, error);
}

NSArray<TOSTransferPart *> *TOSCopyParts(int64_t size, int64_t partSize, NSError * _Nullable * _Nullable error) {
    return TOSPlanParts(size, partSize, YES, error);
}

static BOOL TOSCheckpointHasTraversal(NSString *path) {
    return [[path pathComponents] containsObject:@".."];
}

static BOOL TOSCheckpointIsSymbolicLink(NSString *path) {
    struct stat fileStat;
    if (lstat(path.fileSystemRepresentation, &fileStat) != 0) {
        return NO;
    }
    return S_ISLNK(fileStat.st_mode);
}

static NSString *TOSCheckpointDigest(NSArray<NSString *> *components) {
    NSString *identity = [components componentsJoinedByString:@"."];
    NSData *data = [identity dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5(data.bytes, (CC_LONG)data.length, digest);
    NSData *digestData = [NSData dataWithBytes:digest length:CC_MD5_DIGEST_LENGTH];
    NSString *encoded = [digestData base64EncodedStringWithOptions:0];
    encoded = [encoded stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    encoded = [encoded stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    while ([encoded hasSuffix:@"="]) {
        encoded = [encoded substringToIndex:encoded.length - 1];
    }
    return encoded;
}

static NSObject *TOSCheckpointLeaseLock(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = [NSObject new];
    });
    return lock;
}

static NSMutableSet<NSString *> *TOSCheckpointLeasedPaths(void) {
    static NSMutableSet<NSString *> *paths;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        paths = [NSMutableSet set];
    });
    return paths;
}

static NSString *TOSCheckpointNormalizedAbsolutePath(NSString *path) {
    if (path.length == 0) {
        return nil;
    }
    NSString *absolutePath = path;
    if (!absolutePath.isAbsolutePath) {
        absolutePath = [[[NSFileManager defaultManager] currentDirectoryPath]
                        stringByAppendingPathComponent:absolutePath];
    }
    return absolutePath.stringByStandardizingPath;
}

@interface TOSTransferCheckpointLease ()
@property (nonatomic, copy, readwrite) NSString *checkpointPath;
@property (nonatomic, assign) int tos_lockFileDescriptor;
@property (nonatomic, assign) BOOL tos_invalidated;
@end

@implementation TOSTransferCheckpointLease

+ (instancetype)acquireCheckpointPath:(NSString *)checkpointPath
                                 error:(NSError * _Nullable * _Nullable)error {
    NSString *normalizedPath = TOSCheckpointNormalizedAbsolutePath(checkpointPath);
    if (normalizedPath.length == 0) {
        TOSCheckpointFail(error, @"checkpoint 租约路径无效");
        return nil;
    }

    NSObject *registryLock = TOSCheckpointLeaseLock();
    @synchronized (registryLock) {
        if ([TOSCheckpointLeasedPaths() containsObject:normalizedPath]) {
            TOSCheckpointFail(error, @"同一 checkpoint 路径已有传输任务正在执行");
            return nil;
        }
        [TOSCheckpointLeasedPaths() addObject:normalizedPath];
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *parent = normalizedPath.stringByDeletingLastPathComponent;
    NSError *fileError = nil;
    BOOL isDirectory = NO;
    BOOL parentExists = [fileManager fileExistsAtPath:parent isDirectory:&isDirectory];
    if ((!parentExists &&
         ![fileManager createDirectoryAtPath:parent
                 withIntermediateDirectories:YES
                                  attributes:nil
                                       error:&fileError]) ||
        (parentExists && (!isDirectory || TOSCheckpointIsSymbolicLink(parent)))) {
        @synchronized (registryLock) {
            [TOSCheckpointLeasedPaths() removeObject:normalizedPath];
        }
        if (fileError && error) {
            *error = fileError;
        } else {
            TOSCheckpointFail(error, @"checkpoint 租约父路径不是安全目录");
        }
        return nil;
    }

    NSString *lockPath = [normalizedPath stringByAppendingString:@".lock"];
    int fileDescriptor = open(lockPath.fileSystemRepresentation,
                              O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                              0600);
    struct stat fileStat;
    if (fileDescriptor < 0 ||
        fstat(fileDescriptor, &fileStat) != 0 ||
        !S_ISREG(fileStat.st_mode) ||
        flock(fileDescriptor, LOCK_EX | LOCK_NB) != 0) {
        int posixError = errno;
        if (fileDescriptor >= 0) {
            close(fileDescriptor);
        }
        @synchronized (registryLock) {
            [TOSCheckpointLeasedPaths() removeObject:normalizedPath];
        }
        if (error) {
            NSString *message =
                (posixError == EWOULDBLOCK || posixError == EAGAIN)
                    ? @"同一 checkpoint 路径已有传输任务正在执行"
                    : @"获取 checkpoint 文件锁失败";
            *error = [NSError errorWithDomain:TOSClientErrorDomain
                                         code:TOSTransferCheckpointInvalidArgument
                                     userInfo:@{NSLocalizedDescriptionKey: message,
                                                NSUnderlyingErrorKey:
                                                    [NSError errorWithDomain:NSPOSIXErrorDomain
                                                                        code:posixError
                                                                    userInfo:nil]}];
        }
        return nil;
    }
    fchmod(fileDescriptor, 0600);

    TOSTransferCheckpointLease *lease = [TOSTransferCheckpointLease new];
    lease.checkpointPath = normalizedPath;
    lease.tos_lockFileDescriptor = fileDescriptor;
    return lease;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _tos_lockFileDescriptor = -1;
    }
    return self;
}

- (void)invalidate {
    NSString *path = nil;
    int fileDescriptor = -1;
    @synchronized (self) {
        if (self.tos_invalidated) {
            return;
        }
        self.tos_invalidated = YES;
        path = self.checkpointPath;
        fileDescriptor = self.tos_lockFileDescriptor;
        self.tos_lockFileDescriptor = -1;
    }
    if (fileDescriptor >= 0) {
        flock(fileDescriptor, LOCK_UN);
        close(fileDescriptor);
    }
    if (path.length > 0) {
        @synchronized (TOSCheckpointLeaseLock()) {
            [TOSCheckpointLeasedPaths() removeObject:path];
        }
    }
}

- (void)dealloc {
    [self invalidate];
}

@end

static NSString *TOSCheckpointPath(NSString *checkpointFile,
                                   NSString *defaultDirectory,
                                   NSString *generatedFileName,
                                   NSError * _Nullable * _Nullable error) {
    NSString *candidate = checkpointFile;
    if (candidate.length == 0) {
        candidate = [defaultDirectory stringByAppendingPathComponent:generatedFileName];
    } else {
        if (TOSCheckpointHasTraversal(candidate)) {
            if (error) {
                *error = TOSTransferCheckpointError(@"checkpoint 路径不能包含上级目录跳转");
            }
            return nil;
        }

        BOOL isDirectory = NO;
        BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:candidate isDirectory:&isDirectory];
        if ((exists && isDirectory) || [candidate hasSuffix:@"/"]) {
            candidate = [candidate stringByAppendingPathComponent:generatedFileName];
        }
    }

    if (candidate.length == 0 || TOSCheckpointHasTraversal(candidate)) {
        if (error) {
            *error = TOSTransferCheckpointError(@"checkpoint 路径无效");
        }
        return nil;
    }

    candidate = candidate.stringByStandardizingPath;
    if (TOSCheckpointIsSymbolicLink(candidate)) {
        if (error) {
            *error = TOSTransferCheckpointError(@"checkpoint 文件不能是符号链接");
        }
        return nil;
    }
    return candidate;
}

NSString *TOSUploadCheckpointPath(NSString *checkpointFile,
                                  NSString *filePath,
                                  NSString *bucket,
                                  NSString *key,
                                  NSError * _Nullable * _Nullable error) {
    if (filePath.length == 0 || bucket.length == 0 || key.length == 0) {
        if (error) {
            *error = TOSTransferCheckpointError(@"上传文件路径、桶名和对象名不能为空");
        }
        return nil;
    }
    NSString *fileName = filePath.lastPathComponent;
    NSString *digest = TOSCheckpointDigest(@[bucket, key]);
    NSString *generatedFileName = [NSString stringWithFormat:@"%@.%@.upload.v2", fileName, digest];
    return TOSCheckpointPath(checkpointFile,
                             filePath.stringByDeletingLastPathComponent,
                             generatedFileName,
                             error);
}

NSString *TOSDownloadCheckpointPath(NSString *checkpointFile,
                                    NSString *filePath,
                                    NSString *bucket,
                                    NSString *key,
                                    NSString *versionID,
                                    NSError * _Nullable * _Nullable error) {
    if (filePath.length == 0 || bucket.length == 0 || key.length == 0) {
        if (error) {
            *error = TOSTransferCheckpointError(@"下载文件路径、桶名和对象名不能为空");
        }
        return nil;
    }
    NSMutableArray<NSString *> *components = [NSMutableArray arrayWithObjects:bucket, key, nil];
    if (versionID.length > 0) {
        [components addObject:versionID];
    }
    NSString *digest = TOSCheckpointDigest(components);
    NSString *generatedFileName = [NSString stringWithFormat:@"%@.%@.download", filePath.lastPathComponent, digest];
    return TOSCheckpointPath(checkpointFile,
                             filePath.stringByDeletingLastPathComponent,
                             generatedFileName,
                             error);
}

NSString *TOSCopyCheckpointPath(NSString *checkpointFile,
                                NSString *srcBucket,
                                NSString *srcKey,
                                NSString *srcVersionID,
                                NSString *bucket,
                                NSString *key,
                                NSError * _Nullable * _Nullable error) {
    if (srcBucket.length == 0 || srcKey.length == 0 || bucket.length == 0 || key.length == 0) {
        if (error) {
            *error = TOSTransferCheckpointError(@"源桶、源对象、目标桶和目标对象不能为空");
        }
        return nil;
    }
    NSMutableArray<NSString *> *components = [NSMutableArray arrayWithObjects:srcBucket, srcKey, nil];
    if (srcVersionID.length > 0) {
        [components addObject:srcVersionID];
    }
    [components addObjectsFromArray:@[bucket, key]];
    NSString *digest = TOSCheckpointDigest(components);
    NSString *generatedFileName = [NSString stringWithFormat:@"tos-copy.%@.copy", digest];
    return TOSCheckpointPath(checkpointFile, NSTemporaryDirectory(), generatedFileName, error);
}

@interface TOSDefaultCheckpointFileSystem : NSObject <TOSTransferCheckpointFileSystem>
@end

@implementation TOSDefaultCheckpointFileSystem

- (BOOL)tos_fileExistsAtPath:(NSString *)path isDirectory:(BOOL * _Nullable)isDirectory {
    return [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:isDirectory];
}

- (BOOL)tos_createDirectoryAtPath:(NSString *)path error:(NSError * _Nullable * _Nullable)error {
    return [[NSFileManager defaultManager] createDirectoryAtPath:path
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:error];
}

- (NSData *)tos_dataAtPath:(NSString *)path error:(NSError * _Nullable * _Nullable)error {
    return [NSData dataWithContentsOfFile:path options:0 error:error];
}

- (BOOL)tos_writeData:(NSData *)data toPath:(NSString *)path error:(NSError * _Nullable * _Nullable)error {
    return [data writeToFile:path options:NSDataWritingAtomic error:error];
}

- (BOOL)tos_setPosixPermissions:(NSNumber *)permissions atPath:(NSString *)path error:(NSError * _Nullable * _Nullable)error {
    return [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: permissions}
                                            ofItemAtPath:path
                                                   error:error];
}

- (BOOL)tos_replaceItemAtPath:(NSString *)path withItemAtPath:(NSString *)temporaryPath error:(NSError * _Nullable * _Nullable)error {
    if (rename(temporaryPath.fileSystemRepresentation, path.fileSystemRepresentation) == 0) {
        return YES;
    }
    if (error) {
        *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
    }
    return NO;
}

- (void)tos_removeItemAtPath:(NSString *)path {
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
}

@end


static TOSTransferCheckpoint *TOSCheckpointFromData(NSData *data,
                                                    NSString *operation,
                                                    NSString *path) {
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![object isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    id persistedOperation = object[@"operation"];
    if (![persistedOperation isKindOfClass:[NSString class]] ||
        ![persistedOperation isEqualToString:operation]) {
        return nil;
    }
    if ([operation isEqualToString:@"upload"]) {
        return [TOSUploadCheckpointV2 tos_checkpointWithData:data checkpointPath:path error:nil];
    }
    if ([operation isEqualToString:@"download"]) {
        return [TOSDownloadCheckpoint tos_checkpointWithData:data checkpointPath:path error:nil];
    }
    if ([operation isEqualToString:@"copy"]) {
        return [TOSCopyCheckpoint tos_checkpointWithData:data checkpointPath:path error:nil];
    }
    return nil;
}

static BOOL TOSCheckpointStoreFail(NSError * _Nullable * _Nullable error,
                                   NSString *message,
                                   NSError * _Nullable underlyingError) {
    if (error) {
        NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithObject:message
                                                                            forKey:NSLocalizedDescriptionKey];
        if (underlyingError) {
            userInfo[NSUnderlyingErrorKey] = underlyingError;
        }
        *error = [NSError errorWithDomain:TOSClientErrorDomain
                                     code:TOSTransferCheckpointInvalidArgument
                                 userInfo:userInfo];
    }
    return NO;
}

@interface TOSTransferCheckpointStore ()
@property (nonatomic, strong) id<TOSTransferCheckpointFileSystem> tos_fileSystem;
@property (nonatomic, strong) dispatch_queue_t tos_queue;
@end

@implementation TOSTransferCheckpointStore

- (instancetype)init {
    return [self initWithFileSystem:[TOSDefaultCheckpointFileSystem new]];
}

- (instancetype)initWithFileSystem:(id<TOSTransferCheckpointFileSystem>)fileSystem {
    self = [super init];
    if (self) {
        _tos_fileSystem = fileSystem;
        _tos_queue = dispatch_queue_create("com.volcengine.tos.transfer.checkpoint", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)writeCheckpoint:(TOSTransferCheckpoint *)checkpoint error:(NSError * _Nullable * _Nullable)error {
    __block BOOL success = NO;
    __block NSError *writeError = nil;
    dispatch_sync(self.tos_queue, ^{
        success = [self tos_writeCheckpointOnQueue:checkpoint error:&writeError];
    });
    if (!success && error) {
        *error = writeError;
    }
    return success;
}

- (BOOL)removeCheckpoint:(TOSTransferCheckpoint *)checkpoint error:(NSError * _Nullable * _Nullable)error {
    __block BOOL success = NO;
    __block NSError *removeError = nil;
    dispatch_sync(self.tos_queue, ^{
        success = [self tos_removeCheckpointOnQueue:checkpoint error:&removeError];
    });
    if (!success && error) {
        *error = removeError;
    }
    return success;
}

- (BOOL)tos_removeCheckpointOnQueue:(TOSTransferCheckpoint *)checkpoint
                              error:(NSError * _Nullable * _Nullable)error {
    NSString *path = checkpoint.tos_checkpointPath;
    if (path.length == 0 || TOSCheckpointHasTraversal(path)) {
        return TOSCheckpointStoreFail(error, @"checkpoint 删除路径无效", nil);
    }
    path = path.stringByStandardizingPath;
    BOOL isDirectory = NO;
    if (![self.tos_fileSystem tos_fileExistsAtPath:path isDirectory:&isDirectory]) {
        return YES;
    }
    if (isDirectory || TOSCheckpointIsSymbolicLink(path)) {
        return TOSCheckpointStoreFail(error, @"checkpoint 删除目标不是普通文件", nil);
    }

    NSError *fileError = nil;
    NSData *existingData = [self.tos_fileSystem tos_dataAtPath:path error:&fileError];
    if (!existingData) {
        return TOSCheckpointStoreFail(error, @"读取待删除 checkpoint 失败", fileError);
    }
    id object = [NSJSONSerialization JSONObjectWithData:existingData options:0 error:nil];
    TOSTransferCheckpoint *existing =
        TOSCheckpointFromData(existingData, checkpoint.tos_operation, path);
    if (!existing) {
        return TOSCheckpointStoreFail(error, @"待删除文件不是当前操作的兼容 checkpoint", nil);
    }
    NSString *persistedCheckpointID =
        [object isKindOfClass:[NSDictionary class]] ? object[@"checkpoint_id"] : nil;
    if (persistedCheckpointID.length > 0 &&
        ![persistedCheckpointID isEqualToString:checkpoint.tos_checkpointID]) {
        return TOSCheckpointStoreFail(error, @"checkpoint 所有者已变化，已拒绝删除", nil);
    }
    [self.tos_fileSystem tos_removeItemAtPath:path];
    if ([self.tos_fileSystem tos_fileExistsAtPath:path isDirectory:NULL]) {
        return TOSCheckpointStoreFail(error, @"删除 checkpoint 失败", nil);
    }
    return YES;
}

- (BOOL)tos_writeCheckpointOnQueue:(TOSTransferCheckpoint *)checkpoint error:(NSError * _Nullable * _Nullable)error {
    NSString *path = checkpoint.tos_checkpointPath;
    if (path.length == 0 || TOSCheckpointHasTraversal(path)) {
        return TOSCheckpointStoreFail(error, @"checkpoint 写入路径无效", nil);
    }
    path = path.stringByStandardizingPath;
    if (TOSCheckpointIsSymbolicLink(path)) {
        return TOSCheckpointStoreFail(error, @"checkpoint 文件不能是符号链接", nil);
    }

    NSString *parent = path.stringByDeletingLastPathComponent;
    if (parent.length == 0) {
        parent = @".";
    }
    BOOL parentIsDirectory = NO;
    BOOL parentExists = [self.tos_fileSystem tos_fileExistsAtPath:parent isDirectory:&parentIsDirectory];
    NSError *fileError = nil;
    if (!parentExists) {
        if (![self.tos_fileSystem tos_createDirectoryAtPath:parent error:&fileError]) {
            return TOSCheckpointStoreFail(error, @"创建 checkpoint 目录失败", fileError);
        }
    } else if (!parentIsDirectory || TOSCheckpointIsSymbolicLink(parent)) {
        return TOSCheckpointStoreFail(error, @"checkpoint 父路径不是安全目录", nil);
    }

    BOOL targetIsDirectory = NO;
    BOOL targetExists = [self.tos_fileSystem tos_fileExistsAtPath:path isDirectory:&targetIsDirectory];
    if (targetExists) {
        if (targetIsDirectory || TOSCheckpointIsSymbolicLink(path)) {
            return TOSCheckpointStoreFail(error, @"checkpoint 目标不是普通文件", nil);
        }
        NSData *existingData = [self.tos_fileSystem tos_dataAtPath:path error:&fileError];
        if (!existingData) {
            return TOSCheckpointStoreFail(error, @"读取已有 checkpoint 失败", fileError);
        }
        id existingObject = [NSJSONSerialization JSONObjectWithData:existingData options:0 error:nil];
        TOSTransferCheckpoint *existing =
            TOSCheckpointFromData(existingData, checkpoint.tos_operation, path);
        if (!existing) {
            return TOSCheckpointStoreFail(error, @"已有文件不是兼容的 JSON checkpoint，已拒绝覆盖", nil);
        }
        NSString *persistedCheckpointID =
            [existingObject isKindOfClass:[NSDictionary class]] ? existingObject[@"checkpoint_id"] : nil;
        if (persistedCheckpointID.length > 0 &&
            ![persistedCheckpointID isEqualToString:checkpoint.tos_checkpointID]) {
            return TOSCheckpointStoreFail(error, @"checkpoint 所有者已变化，已拒绝覆盖", nil);
        }
    }

    NSDictionary *dictionary = checkpoint.tos_dictionaryRepresentation;
    if (![NSJSONSerialization isValidJSONObject:dictionary]) {
        return TOSCheckpointStoreFail(error, @"checkpoint 无法序列化为 JSON", nil);
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:dictionary options:0 error:&fileError];
    if (!data) {
        return TOSCheckpointStoreFail(error, @"序列化 checkpoint JSON 失败", fileError);
    }

    NSString *temporaryName = [NSString stringWithFormat:@"%@.tmp.%@", path.lastPathComponent, NSUUID.UUID.UUIDString];
    NSString *temporaryPath = [parent stringByAppendingPathComponent:temporaryName];
    if (![self.tos_fileSystem tos_writeData:data toPath:temporaryPath error:&fileError]) {
        [self.tos_fileSystem tos_removeItemAtPath:temporaryPath];
        return TOSCheckpointStoreFail(error, @"写入临时 checkpoint 失败", fileError);
    }
    if (![self.tos_fileSystem tos_setPosixPermissions:@0600 atPath:temporaryPath error:&fileError]) {
        [self.tos_fileSystem tos_removeItemAtPath:temporaryPath];
        return TOSCheckpointStoreFail(error, @"设置 checkpoint 文件权限失败", fileError);
    }
    if (TOSCheckpointIsSymbolicLink(path) ||
        ![self.tos_fileSystem tos_replaceItemAtPath:path withItemAtPath:temporaryPath error:&fileError]) {
        [self.tos_fileSystem tos_removeItemAtPath:temporaryPath];
        return TOSCheckpointStoreFail(error, @"原子替换 checkpoint 失败", fileError);
    }
    return YES;
}

@end
