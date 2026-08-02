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

#import <XCTest/XCTest.h>
#import <VeTOSiOSSDK/TOSNetworkingResponseParser.h>
#import <math.h>

@interface VeTOSiOSSDKTests : XCTestCase

@end

@implementation VeTOSiOSSDKTests

- (id)parsedOutputForOperation:(TOSOperationType)operation
                          JSON:(NSString *)JSON
                  headerFields:(NSDictionary<NSString *, NSString *> *)headerFields
                         error:(NSError **)error {
    TOSNetworkingResponseParser *parser =
        [[TOSNetworkingResponseParser alloc] initWithOperationType:operation];
    NSURL *URL = [NSURL URLWithString:@"https://example.com/example-object"];
    NSHTTPURLResponse *response =
        [[NSHTTPURLResponse alloc] initWithURL:URL
                                   statusCode:200
                                  HTTPVersion:@"HTTP/1.1"
                                 headerFields:headerFields];

    [parser consumeNetworkingResponse:response];
    if (JSON) {
        TOSTask *task =
            [parser consumeNetworkingResponseBody:[JSON dataUsingEncoding:NSUTF8StringEncoding]];
        [task waitUntilFinished];
    }

    return [parser buildOutputObject:error];
}

- (NSString *)listObjectsResponseJSON {
    return @"{"
            "\"Name\":\"example-bucket\","
            "\"MaxKeys\":1000,"
            "\"IsTruncated\":false,"
            "\"Contents\":[{"
              "\"Key\":\"video.mp4\","
              "\"LastModified\":\"2021-08-20T06:43:36.000Z\","
              "\"ETag\":\"etag-1\","
              "\"Size\":4194304,"
              "\"StorageClass\":\"STANDARD\","
              "\"Owner\":{\"ID\":\"owner-id\",\"DisplayName\":\"owner-name\"}"
            "}]"
           "}";
}

- (NSString *)listMultipartUploadsResponseJSON {
    return @"{"
            "\"Bucket\":\"example-bucket\","
            "\"MaxUploads\":1000,"
            "\"IsTruncated\":false,"
            "\"Uploads\":[{"
              "\"Key\":\"video.mp4\","
              "\"UploadId\":\"upload-id\","
              "\"StorageClass\":\"STANDARD\","
              "\"Initiated\":\"2021-08-20T06:43:36.000Z\","
              "\"Owner\":{\"ID\":\"owner-id\",\"DisplayName\":\"owner-name\"}"
            "}],"
            "\"CommonPrefixes\":[{\"Prefix\":\"videos/\"}]"
           "}";
}

- (NSString *)listPartsResponseJSON {
    return @"{"
            "\"Bucket\":\"example-bucket\","
            "\"Key\":\"example-object\","
            "\"UploadId\":\"example-upload-id\","
            "\"PartNumberMarker\":0,"
            "\"NextPartNumberMarker\":2,"
            "\"MaxParts\":1000,"
            "\"IsTruncated\":false,"
            "\"StorageClass\":\"STANDARD\","
            "\"Owner\":{\"ID\":\"owner-id\",\"DisplayName\":\"owner-name\"},"
            "\"Parts\":["
              "{\"PartNumber\":1,\"LastModified\":\"2021-08-20T06:43:36.000Z\","
               "\"ETag\":\"etag-1\",\"Size\":4194304},"
              "{\"PartNumber\":2,\"LastModified\":\"2021-08-20T06:43:37.000Z\","
               "\"ETag\":\"etag-2\",\"Size\":1024}"
            "]"
           "}";
}

- (void)testListPartsResponseParserPopulatesParts {
    NSError *error = nil;
    TOSListPartsOutput *output =
        [self parsedOutputForOperation:TOSOperationTypeListParts
                                 JSON:[self listPartsResponseJSON]
                         headerFields:@{
                             @"x-tos-request-id" : @"request-id",
                             @"x-tos-id-2" : @"request-id-2",
                         }
                                error:&error];

    XCTAssertNil(error);
    XCTAssertTrue([output isKindOfClass:[TOSListPartsOutput class]]);
    XCTAssertEqual(output.tosStatusCode, 200);
    XCTAssertEqualObjects(output.tosRequestID, @"request-id");
    XCTAssertEqualObjects(output.tosID2, @"request-id-2");
    XCTAssertEqualObjects(output.tosBucket, @"example-bucket");
    XCTAssertEqualObjects(output.tosKey, @"example-object");
    XCTAssertEqualObjects(output.tosUploadID, @"example-upload-id");
    XCTAssertEqual(output.tosPartNumberMarker, 0);
    XCTAssertEqual(output.tosNextPartNumberMarker, 2);
    XCTAssertEqual(output.tosMaxParts, 1000);
    XCTAssertFalse(output.tosIsTruncated);
    XCTAssertEqualObjects(output.tosStorageClass, @"STANDARD");

    XCTAssertNotNil(output.tosParts);
    XCTAssertEqual(output.tosParts.count, 2);

    TOSUploadedPart *firstPart = output.tosParts[0];
    XCTAssertEqual(firstPart.tosPartNumber, 1);
    XCTAssertEqualObjects(firstPart.tosETag, @"etag-1");
    XCTAssertEqual(firstPart.tosSize, 4194304);

    TOSUploadedPart *secondPart = output.tosParts[1];
    XCTAssertEqual(secondPart.tosPartNumber, 2);
    XCTAssertEqualObjects(secondPart.tosETag, @"etag-2");
    XCTAssertEqual(secondPart.tosSize, 1024);
}

- (void)testGetObjectACLResponseParserPopulatesOwner {
    NSString *JSON =
        @"{"
         "\"Owner\":{\"ID\":\"owner-id\",\"DisplayName\":\"owner-name\"},"
         "\"Grants\":[]"
        "}";

    NSError *error = nil;
    TOSGetObjectACLOutput *output =
        [self parsedOutputForOperation:TOSOperationTypeGetObjectACL
                                 JSON:JSON
                         headerFields:@{}
                                error:&error];

    XCTAssertNil(error);
    XCTAssertNotNil(output.tosOwner);
    XCTAssertEqualObjects(output.tosOwner.tosID, @"owner-id");
    XCTAssertEqualObjects(output.tosOwner.tosDisplayName, @"owner-name");
}

- (void)testListObjectsResponseParserUsesOwnerFromEachContent {
    NSError *error = nil;
    TOSListObjectsOutput *output =
        [self parsedOutputForOperation:TOSOperationTypeListObjects
                                 JSON:[self listObjectsResponseJSON]
                         headerFields:@{}
                                error:&error];

    XCTAssertNil(error);
    XCTAssertEqual(output.tosContents.count, 1);
    XCTAssertEqualObjects(output.tosContents.firstObject.tosOwner.tosID, @"owner-id");
    XCTAssertEqualObjects(output.tosContents.firstObject.tosOwner.tosDisplayName, @"owner-name");
}

- (void)testListObjectsResponseParserParsesISO8601LastModified {
    NSError *error = nil;
    TOSListObjectsOutput *output =
        [self parsedOutputForOperation:TOSOperationTypeListObjects
                                 JSON:[self listObjectsResponseJSON]
                         headerFields:@{}
                                error:&error];

    XCTAssertNil(error);
    NSDate *lastModified = output.tosContents.firstObject.tosLastModified;
    XCTAssertNotNil(lastModified);
    if (lastModified) {
        XCTAssertEqualWithAccuracy(lastModified.timeIntervalSince1970, 1629441816, 0.001);
    }
}

- (void)testListMultipartUploadsResponseParserPopulatesOwnerDisplayName {
    NSError *error = nil;
    TOSListMultipartUploadsOutput *output =
        [self parsedOutputForOperation:TOSOperationTypeListMultipartUploads
                                 JSON:[self listMultipartUploadsResponseJSON]
                         headerFields:@{}
                                error:&error];

    XCTAssertNil(error);
    XCTAssertEqual(output.tosUploads.count, 1);
    XCTAssertEqualObjects(output.tosUploads.firstObject.tosOwner.tosID, @"owner-id");
    XCTAssertEqualObjects(output.tosUploads.firstObject.tosOwner.tosDisplayName, @"owner-name");
}

- (void)testListMultipartUploadsResponseParserExtractsCommonPrefixString {
    NSError *error = nil;
    TOSListMultipartUploadsOutput *output =
        [self parsedOutputForOperation:TOSOperationTypeListMultipartUploads
                                 JSON:[self listMultipartUploadsResponseJSON]
                         headerFields:@{}
                                error:&error];

    XCTAssertNil(error);
    XCTAssertEqual(output.tosCommonPrefixes.count, 1);
    XCTAssertTrue([output.tosCommonPrefixes.firstObject.tosPrefix isKindOfClass:[NSString class]]);
    XCTAssertEqualObjects(output.tosCommonPrefixes.firstObject.tosPrefix, @"videos/");
}

- (void)testListMultipartUploadsResponseParserParsesISO8601Initiated {
    NSError *error = nil;
    TOSListMultipartUploadsOutput *output =
        [self parsedOutputForOperation:TOSOperationTypeListMultipartUploads
                                 JSON:[self listMultipartUploadsResponseJSON]
                         headerFields:@{}
                                error:&error];

    XCTAssertNil(error);
    NSDate *initiated = output.tosUploads.firstObject.tosInitiated;
    XCTAssertNotNil(initiated);
    if (initiated) {
        XCTAssertEqualWithAccuracy(initiated.timeIntervalSince1970, 1629441816, 0.001);
    }
}

- (void)testListPartsResponseParserPopulatesOwnerDisplayName {
    NSError *error = nil;
    TOSListPartsOutput *output =
        [self parsedOutputForOperation:TOSOperationTypeListParts
                                 JSON:[self listPartsResponseJSON]
                         headerFields:@{}
                                error:&error];

    XCTAssertNil(error);
    XCTAssertEqualObjects(output.tosOwner.tosID, @"owner-id");
    XCTAssertEqualObjects(output.tosOwner.tosDisplayName, @"owner-name");
}

- (void)testListPartsResponseParserParsesISO8601LastModified {
    NSError *error = nil;
    TOSListPartsOutput *output =
        [self parsedOutputForOperation:TOSOperationTypeListParts
                                 JSON:[self listPartsResponseJSON]
                         headerFields:@{}
                                error:&error];

    XCTAssertNil(error);
    NSDate *lastModified = output.tosParts.firstObject.tosLastModified;
    XCTAssertNotNil(lastModified);
    if (lastModified) {
        XCTAssertEqualWithAccuracy(lastModified.timeIntervalSince1970, 1629441816, 0.001);
    }
}

- (void)testGetObjectResponseParserConvertsLastModifiedHeaderToDate {
    NSError *error = nil;
    TOSGetObjectOutput *output =
        [self parsedOutputForOperation:TOSOperationTypeGetObject
                                 JSON:nil
                         headerFields:@{@"Last-Modified" : @"Fri, 20 Aug 2021 06:43:36 GMT"}
                                error:&error];

    XCTAssertNil(error);
    XCTAssertTrue([output.tosLastModified isKindOfClass:[NSDate class]]);
    if ([output.tosLastModified isKindOfClass:[NSDate class]]) {
        XCTAssertEqualWithAccuracy(output.tosLastModified.timeIntervalSince1970, 1629441816, 0.001);
    }
}

- (void)testHeadObjectResponseParserParsesRFC1123Dates {
    NSError *error = nil;
    TOSHeadObjectOutput *output =
        [self parsedOutputForOperation:TOSOperationTypeHeadObject
                                 JSON:nil
                         headerFields:@{
                             @"Last-Modified" : @"Fri, 20 Aug 2021 06:43:36 GMT",
                             @"Expires" : @"Sat, 21 Aug 2021 06:43:36 GMT",
                         }
                                error:&error];

    XCTAssertNil(error);
    XCTAssertEqualWithAccuracy(output.tosLastModified.timeIntervalSince1970, 1629441816, 0.001);
    XCTAssertEqualWithAccuracy(output.tosExpires.timeIntervalSince1970, 1629528216, 0.001);
}

- (void)testGetObjectToFileResponseParserConvertsLastModifiedHeaderToDate {
    NSError *error = nil;
    TOSGetObjectToFileOutput *output =
        [self parsedOutputForOperation:TOSOperationTypeGetObjectToFile
                                 JSON:nil
                         headerFields:@{@"Last-Modified" : @"Fri, 20 Aug 2021 06:43:36 GMT"}
                                error:&error];

    XCTAssertNil(error);
    XCTAssertTrue([output.tosLastModified isKindOfClass:[NSDate class]]);
    if ([output.tosLastModified isKindOfClass:[NSDate class]]) {
        XCTAssertEqualWithAccuracy(output.tosLastModified.timeIntervalSince1970, 1629441816, 0.001);
    }
}

- (void)testCopyObjectResponseParserParsesISO8601LastModified {
    NSError *error = nil;
    TOSCopyObjectOutput *output =
        [self parsedOutputForOperation:TOSOperationTypeCopyObject
                                 JSON:@"{\"ETag\":\"etag-1\","
                                       "\"LastModified\":\"2021-08-20T06:43:36.000Z\"}"
                         headerFields:@{}
                                error:&error];

    XCTAssertNil(error);
    XCTAssertEqualWithAccuracy(output.tosLastModified.timeIntervalSince1970, 1629441816, 0.001);
}

- (void)testUploadPartCopyResponseParserParsesISO8601WithoutFractionalSeconds {
    NSError *error = nil;
    TOSUploadPartCopyOutput *output =
        [self parsedOutputForOperation:TOSOperationTypeUploadPartCopy
                                 JSON:@"{\"ETag\":\"etag-1\","
                                       "\"LastModified\":\"2021-08-20T06:43:36Z\"}"
                         headerFields:@{}
                                error:&error];

    XCTAssertNil(error);
    XCTAssertEqualWithAccuracy(output.tosLastModified.timeIntervalSince1970, 1629441816, 0.001);
}

- (void)testListObjectVersionsResponseParserParsesAllISO8601Dates {
    NSString *JSON =
        @"{"
         "\"Name\":\"example-bucket\","
         "\"MaxKeys\":1000,"
         "\"IsTruncated\":false,"
         "\"Versions\":[{"
           "\"Key\":\"video.mp4\","
           "\"VersionId\":\"version-1\","
           "\"LastModified\":\"2021-08-20T06:43:36.000Z\","
           "\"ETag\":\"etag-1\","
           "\"IsLatest\":true,"
           "\"Size\":10,"
           "\"StorageClass\":\"STANDARD\","
           "\"HashCrc64ecma\":\"0\","
           "\"Owner\":{\"ID\":\"owner-id\",\"DisplayName\":\"owner-name\"}"
         "}],"
         "\"DeleteMarkers\":[{"
           "\"Key\":\"deleted.mp4\","
           "\"VersionId\":\"version-2\","
           "\"LastModified\":\"2021-08-20T06:43:37.000Z\","
           "\"IsLatest\":false,"
           "\"Owner\":{\"ID\":\"owner-id\",\"DisplayName\":\"owner-name\"}"
         "}]"
        "}";
    NSError *error = nil;
    TOSListObjectVersionsOutput *output =
        [self parsedOutputForOperation:TOSOperationTypeListObjectVersions
                                 JSON:JSON
                         headerFields:@{}
                                error:&error];

    XCTAssertNil(error);
    XCTAssertEqualWithAccuracy(output.tosVersions.firstObject.tosLastModified.timeIntervalSince1970,
                               1629441816, 0.001);
    XCTAssertEqualWithAccuracy(output.tosDeleteMarkers.firstObject.tosLastModified.timeIntervalSince1970,
                               1629441817, 0.001);
}

- (void)testMalformedAndMissingOptionalDatesReturnNil {
    NSString *JSON =
        @"{"
         "\"Name\":\"example-bucket\","
         "\"MaxKeys\":1000,"
         "\"IsTruncated\":false,"
         "\"Contents\":[{"
           "\"Key\":\"video.mp4\","
           "\"LastModified\":\"not-a-date\","
           "\"Size\":10,"
           "\"Owner\":{}"
         "}]"
        "}";
    NSError *error = nil;
    TOSListObjectsOutput *listOutput =
        [self parsedOutputForOperation:TOSOperationTypeListObjects
                                 JSON:JSON
                         headerFields:@{}
                                error:&error];
    TOSHeadObjectOutput *headOutput =
        [self parsedOutputForOperation:TOSOperationTypeHeadObject
                                 JSON:nil
                         headerFields:@{@"Last-Modified" : @"not-a-date"}
                                error:&error];
    TOSHeadObjectOutput *wrongWeekdayOutput =
        [self parsedOutputForOperation:TOSOperationTypeHeadObject
                                 JSON:nil
                         headerFields:@{
                             @"Last-Modified" :
                                 @"Thu, 20 Aug 2021 06:43:36 GMT"
                         }
                                error:&error];
    TOSGetObjectOutput *getOutput =
        [self parsedOutputForOperation:TOSOperationTypeGetObject
                                 JSON:nil
                         headerFields:@{}
                                error:&error];

    XCTAssertNil(error);
    XCTAssertNil(listOutput.tosContents.firstObject.tosLastModified);
    XCTAssertNil(headOutput.tosLastModified);
    XCTAssertNil(wrongWeekdayOutput.tosLastModified);
    XCTAssertNil(getOutput.tosLastModified);
}

- (void)testISO8601ResponseParserValidatesCalendarAndWireShape {
    NSArray<NSString *> *invalidDates = @[
        @"2021-13-20T06:43:36.123Z",
        @"2021-02-29T06:43:36.123Z",
        @"2020-02-30T06:43:36.123Z",
        @"2021-08-20T24:43:36.123Z",
        @"2021-08-20T06:60:36.123Z",
        @"2021-08-20T06:43:60.123Z",
        @"2021-08-20 06:43:36.123Z",
        @"2021-08-20T06:43:36.12Z",
        @"2021-08-20T06:43:36+00:00",
    ];
    for (NSString *dateString in invalidDates) {
        NSError *error = nil;
        NSString *JSON =
            [NSString stringWithFormat:
                (@"{\"Contents\":[{\"Key\":\"key\","
                  "\"LastModified\":\"%@\",\"Owner\":{}}]}"),
                dateString];
        TOSListObjectsOutput *output =
            [self parsedOutputForOperation:TOSOperationTypeListObjects
                                      JSON:JSON
                              headerFields:@{}
                                     error:&error];
        XCTAssertNil(error);
        XCTAssertNil(output.tosContents.firstObject.tosLastModified,
                     @"Accepted invalid date: %@", dateString);
    }

    NSError *error = nil;
    TOSListObjectsOutput *leapDayOutput =
        [self parsedOutputForOperation:TOSOperationTypeListObjects
                                  JSON:(@"{\"Contents\":[{\"Key\":\"key\","
                                        "\"LastModified\":"
                                        "\"2020-02-29T23:59:59.999Z\","
                                        "\"Owner\":{}}]}")
                          headerFields:@{}
                                 error:&error];
    XCTAssertNil(error);
    XCTAssertNotNil(leapDayOutput.tosContents.firstObject.tosLastModified);
}

- (void)testConcurrentRequestAndResponseDateHandlingIsStable {
    const NSUInteger iterationCount = 1000;
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:1629441816];
    NSString *expectedRequestDate = @"Fri, 20 Aug 2021 06:43:36 GMT";
    NSMutableArray<NSString *> *failures = [NSMutableArray array];
    NSLock *failureLock = [NSLock new];

    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t queue =
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    for (NSUInteger index = 0; index < iterationCount; index++) {
        dispatch_group_async(group, queue, ^{
            @autoreleasepool {
                TOSGetObjectInput *input = [TOSGetObjectInput new];
                input.tosIfModifiedSince = date;
                NSString *requestDate =
                    [input headerParamsDict][@"If-Modified-Since"];

                NSError *error = nil;
                TOSCopyObjectOutput *output =
                    [self parsedOutputForOperation:TOSOperationTypeCopyObject
                                              JSON:(@"{\"ETag\":\"etag\","
                                                    "\"LastModified\":"
                                                    "\"2021-08-20T06:43:36.123Z\"}")
                                      headerFields:@{}
                                             error:&error];
                BOOL validResponse =
                    error == nil &&
                    [output.tosLastModified isKindOfClass:[NSDate class]] &&
                    fabs(output.tosLastModified.timeIntervalSince1970 -
                         1629441816.123) < 0.001;
                if (![requestDate isEqualToString:expectedRequestDate] ||
                    !validResponse) {
                    [failureLock lock];
                    [failures addObject:
                        [NSString stringWithFormat:@"iteration=%lu",
                                                   (unsigned long)index]];
                    [failureLock unlock];
                }
            }
        });
    }
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

    XCTAssertEqual(failures.count, 0, @"Concurrent date failures: %@",
                   [failures subarrayWithRange:
                       NSMakeRange(0, MIN(failures.count, 10))]);
}

- (void)testConditionalRequestModelsUseRFC1123Dates {
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:1629441816];
    NSString *expected = @"Fri, 20 Aug 2021 06:43:36 GMT";

    TOSCopyObjectInput *copyInput = [TOSCopyObjectInput new];
    copyInput.tosCopySourceIfModifiedSince = date;
    copyInput.tosCopySourceIfUnmodifiedSince = date;
    NSDictionary *copyHeaders = [copyInput headerParamsDict];
    XCTAssertEqualObjects(copyHeaders[@"x-tos-copy-source-if-modified-since"], expected);
    XCTAssertEqualObjects(copyHeaders[@"x-tos-copy-source-if-unmodified-since"], expected);

    TOSGetObjectInput *getInput = [TOSGetObjectInput new];
    getInput.tosIfModifiedSince = date;
    getInput.tosIfUnmodifiedSince = date;
    NSDictionary *getHeaders = [getInput headerParamsDict];
    XCTAssertEqualObjects(getHeaders[@"If-Modified-Since"], expected);
    XCTAssertEqualObjects(getHeaders[@"If-Unmodified-Since"], expected);

    TOSHeadObjectInput *headInput = [TOSHeadObjectInput new];
    headInput.tosIfModifiedSince = date;
    headInput.tosIfUnmodifiedSince = date;
    NSDictionary *headHeaders = [headInput headerParamsDict];
    XCTAssertEqualObjects(headHeaders[@"If-Modified-Since"], expected);
    XCTAssertEqualObjects(headHeaders[@"If-Unmodified-Since"], expected);

    TOSUploadPartCopyInput *partCopyInput = [TOSUploadPartCopyInput new];
    partCopyInput.tosCopySourceIfModifiedSince = date;
    partCopyInput.tosCopySourceIfUnmodifiedSince = date;
    NSDictionary *partCopyHeaders = [partCopyInput headerParamsDict];
    XCTAssertEqualObjects(partCopyHeaders[@"x-tos-copy-source-if-modified-since"], expected);
    XCTAssertEqualObjects(partCopyHeaders[@"x-tos-copy-source-if-unmodified-since"], expected);
}

- (void)testObjectMetadataRequestModelsUseRFC1123Expires {
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:1629441816];
    NSString *expected = @"Fri, 20 Aug 2021 06:43:36 GMT";

    TOSPutObjectInput *putInput = [TOSPutObjectInput new];
    putInput.tosExpires = date;
    XCTAssertEqualObjects([putInput headerParamsDict][@"Expires"], expected);

    TOSPutObjectFromFileInput *fileInput = [TOSPutObjectFromFileInput new];
    fileInput.tosExpires = date;
    XCTAssertEqualObjects([fileInput headerParamsDict][@"Expires"], expected);

    TOSPutObjectFromStreamInput *streamInput = [TOSPutObjectFromStreamInput new];
    streamInput.tosExpires = date;
    XCTAssertEqualObjects([streamInput headerParamsDict][@"Expires"], expected);

    TOSSetObjectMetaInput *metaInput = [TOSSetObjectMetaInput new];
    metaInput.tosExpires = date;
    XCTAssertEqualObjects([metaInput headerParamsDict][@"Expires"], expected);

    TOSCreateMultipartUploadInput *multipartInput = [TOSCreateMultipartUploadInput new];
    multipartInput.tosExpires = date;
    XCTAssertEqualObjects([multipartInput headerParamsDict][@"Expires"], expected);
}

- (void)testGetObjectResponseExpiresQueryUsesRFC1123Date {
    TOSGetObjectInput *input = [TOSGetObjectInput new];
    input.tosResponseExpires = [NSDate dateWithTimeIntervalSince1970:1629441816];

    XCTAssertEqualObjects([input queryParamsDict][@"response-expires"],
                          @"Fri, 20 Aug 2021 06:43:36 GMT");
}

- (void)testUploadPartInfoArchiveRoundTripPreservesETag {
    TOSUploadPartInfo *part = [TOSUploadPartInfo new];
    part.tosPartNumber = 1;
    part.tosETag = @"etag-1";
    part.tosIsCompleted = YES;

    NSError *error = nil;
    NSData *data =
        [NSKeyedArchiver archivedDataWithRootObject:part requiringSecureCoding:NO error:&error];
    XCTAssertNil(error);
    XCTAssertNotNil(data);

    NSKeyedUnarchiver *unarchiver =
        [[NSKeyedUnarchiver alloc] initForReadingFromData:data error:&error];
    unarchiver.requiresSecureCoding = NO;
    TOSUploadPartInfo *decoded = [unarchiver decodeObjectForKey:NSKeyedArchiveRootObjectKey];
    [unarchiver finishDecoding];
    XCTAssertNil(error);
    XCTAssertEqualObjects(decoded.tosETag, @"etag-1");
}

- (void)testCopyObjectHeaderIncludesVersionIDSeparator {
    TOSCopyObjectInput *input = [TOSCopyObjectInput new];
    input.tosSrcBucket = @"source-bucket";
    input.tosSrcKey = @"source-key";
    input.tosSrcVersionID = @"version-1";

    NSDictionary *headers = [input headerParamsDict];

    XCTAssertEqualObjects(headers[@"x-tos-copy-source"],
                          @"/source-bucket/source-key?versionId=version-1");
}

- (void)testListMultipartUploadsInputUsesDocumentedEncodingTypeQueryName {
    TOSListMultipartUploadsInput *input = [TOSListMultipartUploadsInput new];
    input.tosEncodingType = @"url";

    NSDictionary *query = [input queryParamsDict];

    XCTAssertEqualObjects(query[@"encoding-type"], @"url");
    XCTAssertNil(query[@"encodint-type"]);
}

@end
