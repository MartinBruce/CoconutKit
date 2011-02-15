//
//  HeavyViewController.m
//  nut-demo
//
//  Created by Samuel Défago on 2/15/11.
//  Copyright 2011 Hortis. All rights reserved.
//

#import "HeavyViewController.h"

@implementation HeavyViewController

#pragma mark Object creation and destruction

- (id)init
{
    if (self = [super init]) {
        self.title = @"HeavyViewController";
    }
    return self;
}

#pragma mark View lifecycle

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    // Simulate heavy view loading by waiting two seconds
    [NSThread sleepForTimeInterval:2.];
    
    self.view.backgroundColor = [UIColor colorWithRed:(rand() % 256)/256.f
                                                green:(rand() % 256)/256.f 
                                                 blue:(rand() % 256)/256.f 
                                                alpha:1.f];    
}

#pragma mark Orientation management

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation
{
    return YES;
}

@end
