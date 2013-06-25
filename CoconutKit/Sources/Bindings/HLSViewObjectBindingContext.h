//
//  HLSViewObjectBindingContext.h
//  mBanking
//
//  Created by Samuel Défago on 18.06.13.
//  Copyright (c) 2013 Hortis. All rights reserved.
//

@interface HLSViewObjectBindingContext : NSObject

- (id)initWithObject:(id)object keyPath:(NSString *)keyPath formatterName:(NSString *)formatterName view:(UIView *)view;

- (NSString *)text;

@end
