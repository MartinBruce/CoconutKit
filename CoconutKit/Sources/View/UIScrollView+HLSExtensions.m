//
//  UIScrollView+HLSExtensions.m
//  CoconutKit
//
//  Created by Samuel Défago on 20.02.12.
//  Copyright (c) 2012 Hortis. All rights reserved.
//

#import "UIScrollView+HLSExtensions.h"

#import "HLSAssert.h"
#import "HLSFloat.h"
#import "HLSLogger.h"
#import "HLSRuntime.h"
#import "UIView+HLSExtensions.h"
#import <objc/runtime.h>

/**
 * There are at least three way to detect contentOffset changes of the master view:
 *   - use an internal delegate which transparently forwards events to the real scroll view delegate, and which
 *     performs synchronization in its scrollViewDidScroll: method implementation. This might break if 
 *     UIScrollViewDelegate changes, though
 *   - use KVO on contentOffset. The problem is that the observeValue... method to implement could be overridden by
 *     existing subclasses of UIScrollView, or even by categories. This is clearly not robust enough
 *   - swizzling contentOffset mutators. This is the safest approach which has been retained here
 */

static const CGFloat HLSMinimalYOffset = 20.f;

// Associated object keys
static void *s_synchronizedScrollViewsKey = &s_synchronizedScrollViewsKey;
static void *s_parallaxBouncesKey = &s_parallaxBouncesKey;
static void *s_avoidingKeyboardKey = &s_avoidingKeyboardKey;

// Original implementation of the methods we swizzle
static void (*s_UIScrollView__setContentOffset_Imp)(id, SEL, CGPoint) = NULL;

// Swizzled method implementations
static void swizzled_UIScrollView__setContentOffset_Imp(UIScrollView *self, SEL _cmd, CGPoint contentOffset);

static NSArray *s_adjustedScrollViews = nil;
static NSArray *s_keyboardHeightAdjustments = nil;

@interface UIScrollView (HLSExtensionsPrivate)

- (void)synchronizeScrolling;

@end

@implementation UIScrollView (HLSExtensions)

#pragma mark Accessors and mutators

- (BOOL)isAvoidingKeyboard
{
    return objc_getAssociatedObject(self, s_avoidingKeyboardKey);
}

- (void)setAvoidingKeyboard:(BOOL)avoidingKeyboard
{
    objc_setAssociatedObject(self, s_avoidingKeyboardKey, @(avoidingKeyboard), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark Synchronizing scroll views

- (void)synchronizeWithScrollViews:(NSArray *)scrollViews bounces:(BOOL)bounces
{
    HLSAssertObjectsInEnumerationAreKindOfClass(scrollViews, UIScrollView);
    
    if (! scrollViews || [scrollViews count] == 0) {
        HLSLoggerError(@"No scroll views to synchronize");
        return;
    }
    
    if ([scrollViews containsObject:self]) {
        HLSLoggerError(@"A scroll view cannot be synchronized with itself");
        return;
    }
    
    objc_setAssociatedObject(self, s_synchronizedScrollViewsKey, scrollViews, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, s_parallaxBouncesKey, [NSNumber numberWithBool:bounces], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)removeSynchronization
{
    objc_setAssociatedObject(self, s_synchronizedScrollViewsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, s_parallaxBouncesKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end

@implementation UIScrollView (HLSExtensionsPrivate)

#pragma mark Class methods

+ (void)load
{
    s_UIScrollView__setContentOffset_Imp = (void (*)(id, SEL, CGPoint))HLSSwizzleSelector(self, 
                                                                                          @selector(setContentOffset:), 
                                                                                          (IMP)swizzled_UIScrollView__setContentOffset_Imp);
}

#pragma mark Scrolling synchronization

- (void)synchronizeScrolling
{
    NSArray *synchronizedScrollViews = objc_getAssociatedObject(self, s_synchronizedScrollViewsKey);
    if (! synchronizedScrollViews) {
        return;
    }
    
    // Calculate the relative offset position (in [0; 1]) of the receiver
    CGFloat relativeXPos = 0.f;
    if (floatle(self.contentSize.width, CGRectGetWidth(self.frame))) {
        relativeXPos = 0.f;
    }
    else {
        relativeXPos = self.contentOffset.x / (self.contentSize.width - CGRectGetWidth(self.frame));
    }
    
    CGFloat relativeYPos = 0.f;
    if (floatle(self.contentSize.height, CGRectGetHeight(self.frame))) {
        relativeYPos = 0.f;
    }
    else {
        relativeYPos = self.contentOffset.y / (self.contentSize.height - CGRectGetHeight(self.frame));
    }
    
    // If reaching the top or the bottom of the master scroll view, prevent the other scroll views from
    // scrolling further (if enabled)
    BOOL bounces = [objc_getAssociatedObject(self, s_parallaxBouncesKey) boolValue];
    if (! bounces) {
        if (floatlt(relativeXPos, 0.f)) {
            relativeXPos = 0.f;
        }
        else if (floatgt(relativeXPos, 1.f)) {
            relativeXPos = 1.f;
        }
        
        if (floatlt(relativeYPos, 0.f)) {
            relativeYPos = 0.f;
        }
        else if (floatgt(relativeYPos, 1.f)) {
            relativeYPos = 1.f;
        }            
    }
    
    // Apply the same relative offset position to all scroll views to keep in sync
    for (UIScrollView *scrollView in synchronizedScrollViews) {
        CGFloat xPos = relativeXPos * (scrollView.contentSize.width - CGRectGetWidth(scrollView.frame));
        CGFloat yPos = relativeYPos * (scrollView.contentSize.height - CGRectGetHeight(scrollView.frame));
        scrollView.contentOffset = CGPointMake(xPos, yPos);
    }
}

#pragma mark Collecting scroll views which avoid the keyboard

+ (NSArray *)keyboardAvoidingScrollViewsInView:(UIView *)view
{
    if ([view isKindOfClass:[UIScrollView class]]) {
        UIScrollView *scrollView = (UIScrollView *)view;
        
        // Do not go further when we have found a scroll view which avoids the keyboard. Any scroll view within
        // it with the same property does not need to be adjusted
        if (scrollView.avoidingKeyboard) {
            return @[scrollView];
        }
    }
    
    NSMutableArray *keyboardAvoidingScrollViews = [NSMutableArray array];
    for (UIView *subview in view.subviews) {
        [keyboardAvoidingScrollViews addObjectsFromArray:[self keyboardAvoidingScrollViewsInView:subview]];
    }
    return [NSArray arrayWithArray:keyboardAvoidingScrollViews];
}

#pragma mark Notification callbacks

+ (void)keyboardWillShow:(NSNotification *)notification
{
    UIView *mainView = [UIApplication sharedApplication].keyWindow.rootViewController.view;
    NSArray *keyboardAvoidingScrollViews = [UIScrollView keyboardAvoidingScrollViewsInView:mainView];
    
    CGRect keyboardEndFrameInWindow = [[notification.userInfo objectForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue];
    NSTimeInterval keyboardAnimationDuration = [[notification.userInfo objectForKey:UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    
    NSMutableArray *adjustedScrollViews = [NSMutableArray array];
    NSMutableArray *keyboardHeightAdjustments = [NSMutableArray array];
    
    // We manually animate content offset changes (this property is animatable, though not documented as such). The standard
    // -setContentOffset:animated: method has a duration different from the one of the keyboard animation
    [UIView beginAnimations:nil context:NULL];
    [UIView setAnimationDuration:keyboardAnimationDuration];
    
    // Not all scroll views avoiding the keyboard need to be adjusted (depending on where they are located on
    // screen). Frames will be adjusted after the keyboard has been displayed for a perfect result, but we
    // need to trigger content offset animation earler (this is why we need to calculate adjustments earlier)
    for (UIScrollView *scrollView in keyboardAvoidingScrollViews) {
        CGRect keyboardEndFrameInScrollView = [scrollView convertRect:keyboardEndFrameInWindow fromView:nil];
        if (! CGRectIntersectsRect(keyboardEndFrameInScrollView, scrollView.bounds)) {
            continue;
        }
        
        // Find whether a meaningful adjustment is required (other cases, the keyboard either does not cover the scroll
        // view, or covers it entirely)
        CGFloat keyboardHeightAdjustment = CGRectGetHeight(scrollView.frame) - CGRectGetMinY(keyboardEndFrameInScrollView);
        if (floatle(keyboardHeightAdjustment, 0.f) || floatge(keyboardHeightAdjustment, CGRectGetHeight(scrollView.frame))) {
            continue;
        }
        
        [adjustedScrollViews addObject:scrollView];
        [keyboardHeightAdjustments addObject:@(keyboardHeightAdjustment)];
        
        // Find if the first responder is contained within the scroll view
        UIView *firstResponderView = [scrollView firstResponderView];
        if (! firstResponderView) {
            continue;
        }
        
        // If the first responder is not visible, change the offset to make it visible
        // TODO: Call [UIView setAnimationsEnabled:NO] first to short-circuit a previous animation??
        CGRect firstResponderViewFrameInScrollView = [scrollView convertRect:firstResponderView.bounds fromView:firstResponderView];
        CGFloat responderYOffset = CGRectGetMaxY(firstResponderViewFrameInScrollView) + HLSMinimalYOffset
            - CGRectGetMaxY(scrollView.frame) + keyboardHeightAdjustment;
        if (floatgt(responderYOffset, 0.f)) {
            scrollView.contentOffset = CGPointMake(0.f, scrollView.contentOffset.y + responderYOffset);
        }
    }
    
    [UIView commitAnimations];
    
    s_adjustedScrollViews = [NSArray arrayWithArray:adjustedScrollViews];
    s_keyboardHeightAdjustments = [NSArray arrayWithArray:keyboardHeightAdjustments];
}

+ (void)keyboardDidShow:(NSNotification *)notification
{
    // Now that the keyboard has been displayed, we can immediately adjust the scroll view frame
    NSUInteger i = 0;
    for (UIScrollView *scrollView in s_adjustedScrollViews) {
        // Adjusting the scroll view frame moves the content offset. Save it and restore it immediately
        CGPoint previousContentOffset = scrollView.contentOffset;
        
        CGFloat keyboardHeightAdjustment = [[s_keyboardHeightAdjustments objectAtIndex:i] floatValue];
        scrollView.frame = CGRectMake(CGRectGetMinX(scrollView.frame),
                                      CGRectGetMinY(scrollView.frame),
                                      CGRectGetWidth(scrollView.frame),
                                      CGRectGetHeight(scrollView.frame) - keyboardHeightAdjustment);
        scrollView.contentOffset = previousContentOffset;
        
        ++i;
    }
}

+ (void)keyboardWillHide:(NSNotification *)notification
{    
    NSUInteger i = 0;
    for (UIScrollView *scrollView in s_adjustedScrollViews) {
        CGFloat keyboardHeightAdjustment = [[s_keyboardHeightAdjustments objectAtIndex:i] floatValue];
        scrollView.frame = CGRectMake(CGRectGetMinX(scrollView.frame),
                                      CGRectGetMinY(scrollView.frame),
                                      CGRectGetWidth(scrollView.frame),
                                      CGRectGetHeight(scrollView.frame) + keyboardHeightAdjustment);
        ++i;
    }
    
    s_adjustedScrollViews = nil;
    s_keyboardHeightAdjustments = nil;
}

@end

#pragma mark Global notification registration

__attribute__ ((constructor)) static void HLSTextFieldInit(void)
{
    // Those events are only fired when the dock keyboard is used. When the keyboard rotates, we receive willHide, didHide,
    // willShow and didShow in sequence
    [[NSNotificationCenter defaultCenter] addObserver:[UIScrollView class]
                                             selector:@selector(keyboardWillShow:)
                                                 name:UIKeyboardWillShowNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:[UIScrollView class]
                                             selector:@selector(keyboardDidShow:)
                                                 name:UIKeyboardDidShowNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:[UIScrollView class]
                                             selector:@selector(keyboardWillHide:)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];
}

#pragma mark Swizzled method implementations

static void swizzled_UIScrollView__setContentOffset_Imp(UIScrollView *self, SEL _cmd, CGPoint contentOffset)
{
    (*s_UIScrollView__setContentOffset_Imp)(self, _cmd, contentOffset);
    [self synchronizeScrolling];
}
