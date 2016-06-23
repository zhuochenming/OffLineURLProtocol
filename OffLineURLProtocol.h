//
//  OffLineURLProtocol.h
//  OffLineURLProtocol
//  Created by Zhuochenming on 16/6/20.
//  Copyright © 2016年 Zhuochenming. All rights reserved.
//

#import <Foundation/Foundation.h>


//根据一个大神的改写 兼容iOS7＋
@interface OffLineURLProtocol : NSURLProtocol

+ (NSSet *)supportedSchemes;

+ (void)setSupportedSchemes:(NSSet *)supportedSchemes;

- (NSString *)cachePathForRequest:(NSURLRequest *)aRequest;

- (BOOL)useCache;

@end