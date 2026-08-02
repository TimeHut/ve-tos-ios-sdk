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

#import "TOSTestUtil.h"
#import <CommonCrypto/CommonDigest.h>
#import <XCTest/XCTest.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

static NSString *TOSTestNormalizedBucketComponent(NSString *value) {
    NSString *lowercase = value.lowercaseString ?: @"";
    NSMutableString *normalized = [NSMutableString stringWithCapacity:lowercase.length];
    BOOL previousCharacterWasSeparator = NO;
    for (NSUInteger index = 0; index < lowercase.length; index++) {
        unichar character = [lowercase characterAtIndex:index];
        BOOL isLowercaseLetter = character >= 'a' && character <= 'z';
        BOOL isDigit = character >= '0' && character <= '9';
        if (isLowercaseLetter || isDigit) {
            [normalized appendFormat:@"%C", character];
            previousCharacterWasSeparator = NO;
        } else if (!previousCharacterWasSeparator && normalized.length > 0) {
            [normalized appendString:@"-"];
            previousCharacterWasSeparator = YES;
        }
    }
    while ([normalized hasSuffix:@"-"]) {
        [normalized deleteCharactersInRange:NSMakeRange(normalized.length - 1, 1)];
    }
    return normalized;
}

static BOOL TOSTestShouldRetryBucketCreation(NSError *error) {
    NSError *candidate = error;
    while (candidate) {
        if ([candidate.domain isEqualToString:TOSClientErrorDomain] &&
            candidate.code == TOSClientErrorCodeNetworkError) {
            id originCode = candidate.userInfo[@"OriginErrorCode"];
            return ![originCode respondsToSelector:@selector(integerValue)] ||
                [originCode integerValue] != NSURLErrorCancelled;
        }
        if ([candidate.domain isEqualToString:NSURLErrorDomain] &&
            candidate.code == NSURLErrorTimedOut) {
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

static BOOL TOSTestBucketExists(NSString *bucket, TOSClient *client) {
    TOSHeadBucketInput *input = [TOSHeadBucketInput new];
    input.tosBucket = bucket;
    TOSTask *task = [client headBucket:input];
    [task waitUntilFinished];
    return task.error == nil;
}

@implementation TOSTestUtil

+ (NSString *)randomBucketNameWithPrefix:(NSString *)prefix testClass:(Class)testClass {
    static const NSUInteger randomSuffixLength = 12;
    static const NSUInteger maximumClassComponentLength = 24;
    static const NSUInteger maximumBucketNameLength = 63;

    NSString *prefixComponent = TOSTestNormalizedBucketComponent(prefix);
    if (prefixComponent.length == 0) {
        prefixComponent = @"tos";
    }
    NSString *classComponent = TOSTestNormalizedBucketComponent(NSStringFromClass(testClass));
    if (classComponent.length == 0) {
        classComponent = @"test";
    }
    if (classComponent.length > maximumClassComponentLength) {
        classComponent = [classComponent substringToIndex:maximumClassComponentLength];
        classComponent = [classComponent stringByTrimmingCharactersInSet:
                          [NSCharacterSet characterSetWithCharactersInString:@"-"]];
    }

    NSUInteger maximumPrefixLength =
        maximumBucketNameLength - classComponent.length - randomSuffixLength - 2;
    if (prefixComponent.length > maximumPrefixLength) {
        prefixComponent = [prefixComponent substringToIndex:maximumPrefixLength];
        prefixComponent = [prefixComponent stringByTrimmingCharactersInSet:
                           [NSCharacterSet characterSetWithCharactersInString:@"-"]];
    }
    if (prefixComponent.length == 0) {
        prefixComponent = @"tos";
    }

    return [NSString stringWithFormat:@"%@-%@-%@",
            prefixComponent,
            classComponent,
            [self randomString:(int)randomSuffixLength]];
}

+ (NSError *)createBucket:(NSString *)bucket withClient:(TOSClient *)client {
    if (bucket.length == 0 || client == nil) {
        return [NSError errorWithDomain:@"TOSTestUtilErrorDomain"
                                   code:1
                               userInfo:@{NSLocalizedDescriptionKey:
                                              @"A test bucket name and client are required"}];
    }
    TOSCreateBucketInput *input = [TOSCreateBucketInput new];
    input.tosBucket = bucket;
    static const NSInteger maximumAttempts = 3;
    NSError *lastError = nil;
    for (NSInteger attempt = 0; attempt < maximumAttempts; attempt++) {
        TOSTask *task = [client createBucket:input];
        [task waitUntilFinished];
        lastError = task.error;
        if (task.error == nil) {
            return nil;
        }
        if (!TOSTestShouldRetryBucketCreation(task.error)) {
            return task.error;
        }
        if (TOSTestBucketExists(bucket, client)) {
            return nil;
        }
    }
    return lastError;
}

+ (void)cleanBucket:(NSString *)bucket withClient:(TOSClient *)client {
    if (bucket.length == 0 || client == nil) {
        return;
    }

    TOSListObjectsInput *listObjectsInput = [TOSListObjectsInput new];
    listObjectsInput.tosBucket = bucket;
    listObjectsInput.tosMaxKeys = 1000;
    TOSTask *task = [client listObjects:listObjectsInput];
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [[task continueWithBlock:^id _Nullable(TOSTask * _Nonnull task) {
        TOSListObjectsOutput *listObjectsOutput = task.result;
        for (TOSListedObject *o in listObjectsOutput.tosContents) {
            NSString *key = o.tosKey;
            TOSDeleteObjectInput *deleteInput = [TOSDeleteObjectInput new];
            deleteInput.tosBucket = bucket;
            deleteInput.tosKey = key;
            [[client deleteObject:deleteInput] waitUntilFinished];
        }
        dispatch_semaphore_signal(semaphore);
        return nil;
    }] waitUntilFinished];
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    TOSListMultipartUploadsInput *listMultipartUploadsInput = [TOSListMultipartUploadsInput new];
    listMultipartUploadsInput.tosBucket = bucket;
    listMultipartUploadsInput.tosMaxUploads = 1000;
    task = [client listMultipartUploads:listMultipartUploadsInput];
    
    [[task continueWithBlock:^id _Nullable(TOSTask * _Nonnull task) {
        TOSListMultipartUploadsOutput *listMultipartUploadsOutput = task.result;
        for (TOSListedUpload *upload in listMultipartUploadsOutput.tosUploads) {
            NSString *uploadId = upload.tosUploadID;
            NSString *key = upload.tosKey;
            TOSAbortMultipartUploadInput *abortInput = [TOSAbortMultipartUploadInput new];
            abortInput.tosBucket = bucket;
            abortInput.tosKey = key;
            abortInput.tosUploadID = uploadId;
            [[client abortMultipartUpload:abortInput] waitUntilFinished];
        }
        return nil;
    }] waitUntilFinished];
    
    TOSDeleteBucketInput *deleteBucketInput = [TOSDeleteBucketInput new];
    deleteBucketInput.tosBucket = bucket;
    [[client deleteBucket:deleteBucketInput] waitUntilFinished];
}

+ (NSString *)createDeterministicFileAtPath:(NSString *)path
                                       size:(int64_t)size
                                       seed:(uint64_t)seed
                                      error:(NSError **)error {
    if (error) {
        *error = nil;
    }
    if (path.length == 0 || size < 0) {
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];
        }
        return nil;
    }

    int descriptor = open(path.fileSystemRepresentation,
                          O_CREAT | O_TRUNC | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
                          0600);
    if (descriptor < 0) {
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        }
        return nil;
    }

    static const size_t bufferSize = 1024 * 1024;
    uint8_t *buffer = malloc(bufferSize);
    if (!buffer) {
        int allocationError = errno == 0 ? ENOMEM : errno;
        close(descriptor);
        unlink(path.fileSystemRepresentation);
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:allocationError userInfo:nil];
        }
        return nil;
    }

    uint64_t state = seed == 0 ? UINT64_C(0x9e3779b97f4a7c15) : seed;
    int64_t remaining = size;
    CC_SHA256_CTX sha256;
    CC_SHA256_Init(&sha256);
    BOOL succeeded = YES;
    int fileError = 0;
    while (remaining > 0 && succeeded) {
        size_t count = (size_t)MIN((int64_t)bufferSize, remaining);
        size_t offset = 0;
        while (offset < count) {
            state ^= state >> 12;
            state ^= state << 25;
            state ^= state >> 27;
            uint64_t word = state * UINT64_C(2685821657736338717);
            for (NSUInteger byteIndex = 0; byteIndex < sizeof(word) && offset < count;
                 byteIndex++, offset++) {
                buffer[offset] = (uint8_t)(word >> (byteIndex * 8));
            }
        }

        size_t written = 0;
        while (written < count) {
            ssize_t result = write(descriptor, buffer + written, count - written);
            if (result > 0) {
                written += (size_t)result;
                continue;
            }
            if (result < 0 && errno == EINTR) {
                continue;
            }
            fileError = result < 0 ? errno : EIO;
            succeeded = NO;
            break;
        }
        if (succeeded) {
            CC_SHA256_Update(&sha256, buffer, (CC_LONG)count);
            remaining -= (int64_t)count;
        }
    }
    free(buffer);

    if (close(descriptor) != 0 && succeeded) {
        fileError = errno;
        succeeded = NO;
    }
    if (!succeeded) {
        unlink(path.fileSystemRepresentation);
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:fileError == 0 ? EIO : fileError
                                     userInfo:nil];
        }
        return nil;
    }

    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &sha256);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        [hex appendFormat:@"%02x", digest[index]];
    }
    return hex;
}

+ (NSString *)randomString:(int) n {
    NSString *letters = @"abcdefghijklmnopqrstuvwxyz0123456789";
    NSMutableString *randomString = [NSMutableString stringWithCapacity: n];
    for (int i=0; i < n; i++) {
         [randomString appendFormat: @"%C", [letters characterAtIndex: arc4random_uniform((uint32_t)[letters length])]];
    }
    return randomString;
}

@end

@interface TOSProgressTestUtil ()

@property (nonatomic, assign) int64_t totalBytesSent;
@property (nonatomic, assign) int64_t totalBytesExpectedToSend;

@end

@implementation TOSProgressTestUtil

- (void)updateTotalBytes:(int64_t)totalBytesSent totalBytesExpected:(int64_t)totalBytesExpectedToSend {
    XCTAssertTrue(totalBytesSent <= totalBytesExpectedToSend);
    self.totalBytesSent = totalBytesSent;
    self.totalBytesExpectedToSend = totalBytesExpectedToSend;
}


- (BOOL)completeValidateProgress {
    return self.totalBytesSent == self.totalBytesExpectedToSend;
}
@end
