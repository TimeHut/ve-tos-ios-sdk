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

#import <XCTest/XCTest.h>
#import <VeTOSiOSSDK/VeTOSiOSSDK.h>
#import "TOSTestConstants.h"
#import "TOSTestUtil.h"

@interface TOSTestCleanBucketClient : TOSClient
@property (nonatomic, assign) NSInteger tos_networkCallCount;
@end

@implementation TOSTestCleanBucketClient

- (TOSTask *)listObjects:(TOSListObjectsInput *)request {
    self.tos_networkCallCount += 1;
    return [TOSTask taskWithResult:[TOSListObjectsOutput new]];
}

- (TOSTask *)listMultipartUploads:(TOSListMultipartUploadsInput *)request {
    self.tos_networkCallCount += 1;
    return [TOSTask taskWithResult:[TOSListMultipartUploadsOutput new]];
}

- (TOSTask *)deleteBucket:(TOSDeleteBucketInput *)request {
    self.tos_networkCallCount += 1;
    return [TOSTask taskWithResult:[TOSDeleteBucketOutput new]];
}

@end

@interface TOSTransferModelTests : XCTestCase
@end

@implementation TOSTransferModelTests

- (void)testUploadV2DefaultsAndInheritance {
    TOSUploadFileInputV2 *input = [TOSUploadFileInputV2 new];

    XCTAssertTrue([input isKindOfClass:[TOSUploadFileInput class]]);
    XCTAssertEqual(input.tosTaskNum, 1);
    XCTAssertEqual(input.tosMaxRetryCount, 3);
    XCTAssertEqual(input.tosPartSize, 0);
    XCTAssertNil(input.tosCancelHook);
    XCTAssertNil(input.tosRateLimiter);
}

- (void)testUploadV2MutableCopyPreservesNewProperties {
    TOSUploadFileInputV2 *input = [TOSUploadFileInputV2 new];
    input.tosTrafficLimit = 1024;
    input.tosMaxRetryCount = 0;
    input.tosCallback = @"callback";
    input.tosCallbackVar = @"callback-var";

    TOSUploadFileInputV2 *copy = [input mutableCopy];

    XCTAssertTrue([copy isKindOfClass:[TOSUploadFileInputV2 class]]);
    XCTAssertEqual(copy.tosTrafficLimit, input.tosTrafficLimit);
    XCTAssertEqual(copy.tosMaxRetryCount, input.tosMaxRetryCount);
    XCTAssertEqualObjects(copy.tosCallback, input.tosCallback);
    XCTAssertEqualObjects(copy.tosCallbackVar, input.tosCallbackVar);
}

- (void)testDownloadDefaultsAndInheritance {
    TOSDownloadFileInput *input = [TOSDownloadFileInput new];

    XCTAssertTrue([input isKindOfClass:[TOSHeadObjectInput class]]);
    XCTAssertEqual(input.tosTaskNum, 1);
    XCTAssertEqual(input.tosMaxRetryCount, 3);
    XCTAssertEqual(input.tosPartSize, 0);
    XCTAssertNil(input.tosCancelHook);
    XCTAssertNil(input.tosRateLimiter);
    XCTAssertTrue([[TOSDownloadFileOutput new] isKindOfClass:[TOSHeadObjectOutput class]]);
}

- (void)testCopyDefaultsAndInheritance {
    TOSResumableCopyObjectInput *input = [TOSResumableCopyObjectInput new];

    XCTAssertTrue([input isKindOfClass:[TOSCreateMultipartUploadInput class]]);
    XCTAssertEqual(input.tosTaskNum, 1);
    XCTAssertEqual(input.tosMaxRetryCount, 3);
    XCTAssertEqual(input.tosPartSize, 0);
    XCTAssertNil(input.tosCancelHook);
    XCTAssertTrue([[TOSResumableCopyObjectOutput new] isKindOfClass:[TOSOutput class]]);
}

- (void)testTransferAndOperationEventConstantValues {
    XCTAssertEqual(TOSDataTransferStarted, 1);
    XCTAssertEqual(TOSDataTransferRW, 2);
    XCTAssertEqual(TOSDataTransferSucceed, 3);
    XCTAssertEqual(TOSDataTransferFailed, 4);

    XCTAssertEqual(TOSDownloadEventCreateTempFileSucceed, 1);
    XCTAssertEqual(TOSDownloadEventCreateTempFileFailed, 2);
    XCTAssertEqual(TOSDownloadEventDownloadPartSucceed, 3);
    XCTAssertEqual(TOSDownloadEventDownloadPartFailed, 4);
    XCTAssertEqual(TOSDownloadEventDownloadPartAborted, 5);
    XCTAssertEqual(TOSDownloadEventRenameTempFileSucceed, 6);
    XCTAssertEqual(TOSDownloadEventRenameTempFileFailed, 7);

    XCTAssertEqual(TOSCopyEventCreateMultipartUploadSucceed, 1);
    XCTAssertEqual(TOSCopyEventCreateMultipartUploadFailed, 2);
    XCTAssertEqual(TOSCopyEventUploadPartCopySucceed, 3);
    XCTAssertEqual(TOSCopyEventUploadPartCopyFailed, 4);
    XCTAssertEqual(TOSCopyEventUploadPartCopyAborted, 5);
    XCTAssertEqual(TOSCopyEventCompleteMultipartUploadSucceed, 6);
    XCTAssertEqual(TOSCopyEventCompleteMultipartUploadFailed, 7);
}

- (void)testBucketDomainIsDerivedFromEndpoint {
    XCTAssertEqualObjects(TOSTestBucketDomain(@"example-bucket", @"tos-cn-beijing.volces.com"),
                          @"example-bucket.tos-cn-beijing.volces.com");
    XCTAssertEqualObjects(TOSTestBucketDomain(@"example-bucket", @"https://tos-cn-beijing.volces.com:443"),
                          @"https://example-bucket.tos-cn-beijing.volces.com:443");
}

- (void)testCleanBucketWithMissingBucketDoesNotInvokeClient {
    TOSTestCleanBucketClient *client = [TOSTestCleanBucketClient new];

    [TOSTestUtil cleanBucket:nil withClient:client];

    XCTAssertEqual(client.tos_networkCallCount, 0);
}

- (void)testCleanBucketWithMissingClientReturnsSafely {
    XCTAssertNoThrow([TOSTestUtil cleanBucket:@"unused-bucket" withClient:nil]);
}

- (void)testDeterministicFileGeneratorProducesStableNonRepeatingDataAndSHA256 {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTAssertTrue([fileManager createDirectoryAtPath:root
                         withIntermediateDirectories:YES
                                          attributes:nil
                                               error:nil]);
    NSString *firstPath = [root stringByAppendingPathComponent:@"first.bin"];
    NSString *secondPath = [root stringByAppendingPathComponent:@"second.bin"];
    NSString *differentPath = [root stringByAppendingPathComponent:@"different.bin"];
    NSError *error = nil;

    NSString *firstSHA256 =
        [TOSTestUtil createDeterministicFileAtPath:firstPath
                                             size:4097
                                             seed:UINT64_C(0x0123456789abcdef)
                                            error:&error];
    XCTAssertNil(error);
    XCTAssertEqualObjects(firstSHA256, @"f055891e3ef2a0465daccb134587c1df7c65412a4f23593ffc444bba574a07ed");

    NSString *secondSHA256 =
        [TOSTestUtil createDeterministicFileAtPath:secondPath
                                             size:4097
                                             seed:UINT64_C(0x0123456789abcdef)
                                            error:&error];
    XCTAssertNil(error);
    XCTAssertEqualObjects(secondSHA256, firstSHA256);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:secondPath],
                          [NSData dataWithContentsOfFile:firstPath]);

    NSString *differentSHA256 =
        [TOSTestUtil createDeterministicFileAtPath:differentPath
                                             size:4097
                                             seed:UINT64_C(0xfedcba9876543210)
                                            error:&error];
    XCTAssertNil(error);
    XCTAssertNotEqualObjects(differentSHA256, firstSHA256);
    XCTAssertNotEqualObjects([NSData dataWithContentsOfFile:differentPath],
                             [NSData dataWithContentsOfFile:firstPath]);

    [fileManager removeItemAtPath:root error:nil];
}

@end
