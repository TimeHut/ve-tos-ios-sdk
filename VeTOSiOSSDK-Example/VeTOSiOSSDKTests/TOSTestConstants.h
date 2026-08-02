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


#ifndef TOSTestConstants_h
#define TOSTestConstants_h

#import <Foundation/Foundation.h>
#include <stdlib.h>

NS_INLINE NSString * _Nullable TOSTestEnvironmentValue(NSString * _Nonnull name) {
    const char *value = getenv(name.UTF8String);
    if (value == NULL || value[0] == '\0') {
        return nil;
    }
    return [NSString stringWithUTF8String:value];
}

NS_INLINE NSString * _Nonnull TOSTestRequiredEnvironmentValue(NSString * _Nonnull name) {
    NSString *value = TOSTestEnvironmentValue(name);
    if (value.length == 0) {
        [NSException raise:NSInvalidArgumentException
                    format:@"Missing required test environment variable: %@", name];
    }
    return value;
}

NS_INLINE NSString * _Nonnull TOSTestBucketDomain(NSString * _Nonnull bucket,
                                                   NSString * _Nonnull endpoint) {
    BOOL includesScheme = [endpoint hasPrefix:@"https://"] || [endpoint hasPrefix:@"http://"];
    NSString *normalizedEndpoint = includesScheme ? endpoint : [@"https://" stringByAppendingString:endpoint];
    NSURLComponents *components = [NSURLComponents componentsWithString:normalizedEndpoint];
    if (components.host.length == 0) {
        [NSException raise:NSInvalidArgumentException
                    format:@"Invalid TOS_ENDPOINT test environment variable: %@", endpoint];
    }

    NSString *bucketHost = [NSString stringWithFormat:@"%@.%@", bucket, components.host];
    if (!includesScheme) {
        return components.port == nil
            ? bucketHost
            : [NSString stringWithFormat:@"%@:%@", bucketHost, components.port];
    }

    NSURLComponents *bucketComponents = [NSURLComponents new];
    bucketComponents.scheme = components.scheme;
    bucketComponents.host = bucketHost;
    bucketComponents.port = components.port;
    return bucketComponents.string;
}

#define TOS_ACCESSKEY TOSTestRequiredEnvironmentValue(@"TOS_ACCESS_KEY")
#define TOS_SECRETKEY TOSTestRequiredEnvironmentValue(@"TOS_SECRET_KEY")
#define TOS_ENDPOINT TOSTestRequiredEnvironmentValue(@"TOS_ENDPOINT")
#define TOS_REGION TOSTestRequiredEnvironmentValue(@"TOS_REGION")
#define TOS_CALLBACK_URL TOSTestEnvironmentValue(@"TOS_CALLBACK_URL")
#define CUSTOM_DOMAIN TOSTestBucketDomain(TOS_BUCKET, TOS_ENDPOINT)

#define TOS_BUCKET TOSTestRequiredEnvironmentValue(@"TOS_BUCKET")
#define TOS_FILE @"file"

#define TOS_STREAM_URL TOSTestEnvironmentValue(@"TOS_STREAM_URL")

#endif /* TOSTestConstants_h */
