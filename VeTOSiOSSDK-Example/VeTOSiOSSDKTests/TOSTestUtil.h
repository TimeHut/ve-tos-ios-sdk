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

#import <Foundation/Foundation.h>
#import <VeTOSiOSSDK/VeTOSiOSSDK.h>

NS_ASSUME_NONNULL_BEGIN

@interface TOSTestUtil : NSObject

+ (NSString *)randomBucketNameWithPrefix:(NSString *)prefix testClass:(Class)testClass;
+ (nullable NSError *)createBucket:(NSString *)bucket withClient:(TOSClient *)client;
+ (void)cleanBucket:(nullable NSString *)bucket withClient:(nullable TOSClient *)client;
+ (nullable NSString *)createDeterministicFileAtPath:(NSString *)path
                                                size:(int64_t)size
                                                seed:(uint64_t)seed
                                               error:(NSError **)error;
+ (NSString *)randomString:(int) n;

@end

@interface TOSProgressTestUtil : NSObject

- (void)updateTotalBytes:(int64_t)totalBytesSent totalBytesExpected:(int64_t)totalBytesExpectedToSend;
- (BOOL)completeValidateProgress;

@end

NS_ASSUME_NONNULL_END
