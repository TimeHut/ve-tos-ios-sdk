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
#import <VeTOSiOSSDK/TOSEndpoint.h>
#import <VeTOSiOSSDK/TOSNetworking.h>
#import <VeTOSiOSSDK/TOSCredential.h>

NS_ASSUME_NONNULL_BEGIN

@interface TOSClientConfiguration : TOSNetworkingConfiguration

@property (nonatomic, readonly) BOOL enableCRC;
@property (nonatomic, strong, readonly) TOSEndpoint *tosEndpoint;
@property (nonatomic, strong, readonly) TOSCredential *credential;
/// 同一个客户端中断点续传上传、下载和复制共享的分片请求并发上限。
/// 默认为 5，设置值会归一化到 [1, 1000]。
/// 该配置在创建 TOSClient 时生效；修改配置不会影响已经创建的客户端。
@property (nonatomic, assign) uint32_t maxConcurrentResumableTransferTaskCount;

- (instancetype)initWithEndpoint:(TOSEndpoint *)endpoint
                      credential:(TOSCredential *)credential;

- (void)withEnableCRC;

@end

NS_ASSUME_NONNULL_END
