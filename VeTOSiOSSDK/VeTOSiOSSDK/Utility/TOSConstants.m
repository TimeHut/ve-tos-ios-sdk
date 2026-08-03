/**
 * Copyright 2023 Beijing Volcano Engine Technology Ltd.
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

#import "TOSConstants.h"

const int64_t TOSDefaultPartSize = (int64_t)20 * 1024 * 1024;
const int64_t TOSMinPartSize = (int64_t)5 * 1024 * 1024;
const int64_t TOSMaxPartSize = (int64_t)5 * 1024 * 1024 * 1024;
const int TOSMinTaskNum = 1;
const int TOSMaxTaskNum = 5;
const uint64_t TOSMaxPartCount = 10000;

TOSStorageClassType * const TOSStorageClassStandard = @"STANDARD";
TOSStorageClassType * const TOSStorageClassIa = @"IA";
TOSStorageClassType * const TOSStorageClassArchiveFr = @"ARCHIVE_FR";

TOSACLType * const TOSACLPrivate = @"private";
TOSACLType * const TOSACLPublicRead = @"public-read";
TOSACLType * const TOSACLPublicReadWrite = @"public-read-write";
TOSACLType * const TOSACLAuthenticatedRead = @"authenticated-read";
TOSACLType * const TOSACLBucketOwnerRead = @"bucket-owner-read";
TOSACLType * const TOSACLBucketOwnerFullControl = @"bucket-owner-full-control";

TOSMetadataDirectiveType * const TOSMetadataDirectiveCopy = @"COPY";
TOSMetadataDirectiveType * const TOSMetadataDirectiveReplace = @"REPLACE";

TOSAzRedundancyType * const TOSAzRedundancySingleAz = @"single-az";
TOSAzRedundancyType * const TOSAzRedundancyMultiAz = @"multi-az";

TOSPermissionType * const TOSPermissionRead= @"READ";
TOSPermissionType * const TOSPermissionWrite = @"WRITE";
TOSPermissionType * const TOSPermissionReadAcp = @"READ_ACP";
TOSPermissionType * const TOSPermissionWriteAcp = @"WRITE_ACP";
TOSPermissionType * const TOSPermissionFullControl = @"FULL_CONTROL";

TOSGranteeType * const TOSGranteeGroup = @"Group";
TOSGranteeType * const TOSGranteeUser = @"CanonicalUser";

TOSCannedType * const TOSCannedAllUsers = @"AllUsers";
TOSCannedType * const TOSCannedAuthenticatedUsers = @"AuthenticatedUsers";

TOSHTTPMethodType * const TOSHTTPMethodTypeGet = @"GET";
TOSHTTPMethodType * const TOSHTTPMethodTypePut = @"PUT";
TOSHTTPMethodType * const TOSHTTPMethodTypePost = @"POST";
TOSHTTPMethodType * const TOSHTTPMethodTypeDelete = @"DELETE";
TOSHTTPMethodType * const TOSHTTPMethodTypeHead = @"HEAD";

TOSCertStatusType * const TOSCertStatusBound = @"CertBound";
TOSCertStatusType * const TOSCertStatusUnbound = @"CertUnbound";
TOSCertStatusType * const TOSCertStatusExpired = @"CertExpired";

AuthProtocolType *const AuthProtocolTypeTos = @"tos";
AuthProtocolType *const AuthProtocolTypeS3 = @"s3";


TOSUploadEventType const TOSUploadEventCreateMultipartUploadSucceed = 1; // 创建分段上传任务成功
TOSUploadEventType const TOSUploadEventCreateMultipartUploadFailed = 2; // 创建分段上传任务失败
TOSUploadEventType const TOSUploadEventUploadPartSucceed = 3; // 上传段成功
TOSUploadEventType const TOSUploadEventUploadPartFailed = 4; // 上传段失败，出现403、404、405错误中断整个断点续传任务
TOSUploadEventType const TOSUploadEventUploadPartAborted = 5; // 上传段中止
TOSUploadEventType const TOSUploadEventCompleteMultipartUploadSucceed = 6; // 合并段成功
TOSUploadEventType const TOSUploadEventCompleteMultipartUploadFailed = 7; // 合并段失败

TOSDownloadEventType const TOSDownloadEventCreateTempFileSucceed = 1; // 创建临时文件成功
TOSDownloadEventType const TOSDownloadEventCreateTempFileFailed = 2; // 创建临时文件失败
TOSDownloadEventType const TOSDownloadEventDownloadPartSucceed = 3; // 下载段成功
TOSDownloadEventType const TOSDownloadEventDownloadPartFailed = 4; // 下载段失败
TOSDownloadEventType const TOSDownloadEventDownloadPartAborted = 5; // 下载段中止
TOSDownloadEventType const TOSDownloadEventRenameTempFileSucceed = 6; // 重命名临时文件成功
TOSDownloadEventType const TOSDownloadEventRenameTempFileFailed = 7; // 重命名临时文件失败

TOSCopyEventType const TOSCopyEventCreateMultipartUploadSucceed = 1; // 创建分段复制任务成功
TOSCopyEventType const TOSCopyEventCreateMultipartUploadFailed = 2; // 创建分段复制任务失败
TOSCopyEventType const TOSCopyEventUploadPartCopySucceed = 3; // 复制段成功
TOSCopyEventType const TOSCopyEventUploadPartCopyFailed = 4; // 复制段失败
TOSCopyEventType const TOSCopyEventUploadPartCopyAborted = 5; // 复制段中止
TOSCopyEventType const TOSCopyEventCompleteMultipartUploadSucceed = 6; // 合并段成功
TOSCopyEventType const TOSCopyEventCompleteMultipartUploadFailed = 7; // 合并段失败

TOSDataTransferType const TOSDataTransferStarted = 1;
TOSDataTransferType const TOSDataTransferRW = 2;
TOSDataTransferType const TOSDataTransferSucceed = 3;
TOSDataTransferType const TOSDataTransferFailed = 4;

NSString * const TOSHTTPQueryProcess = @"x-tos-process";
NSString * const TOSProcessSaveAsObject = @"x-tos-save-object";
NSString * const TOSProcessSaveAsBucket = @"x-tos-save-bucket";
