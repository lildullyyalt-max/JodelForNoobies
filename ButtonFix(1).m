// ButtonFix: finds ACJodel's round blue button (stuck under the glass tab bar),
// re-parents it to the top of the key window, lifts it above the tab bar and makes it draggable.
// Inject it TOGETHER with ACJodel.dylib. Pure ObjC runtime, no Substrate.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static __weak UIButton *gBtn;
static BOOL gToastShown = NO;

static UIWindow *keyWin(void) {
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) if (w.isKeyWindow) return w;
    }
    return nil;
}

static BOOL insideTabBar(UIView *v) {
    for (UIView *p = v.superview; p; p = p.superview) {
        if ([p isKindOfClass:[UITabBar class]]) return YES;
        if (strstr(class_getName([p class]), "TabBar")) return YES;
    }
    return NO;
}

static void findBtn(UIView *v, UIWindow *w, UIButton **out) {
    if (*out) return;
    if ([v isKindOfClass:[UIButton class]] && !v.hidden && v.alpha > 0.1) {
        CGRect f = [v convertRect:v.bounds toView:w];
        CGFloat W = w.bounds.size.width, H = w.bounds.size.height;
        BOOL sizeOK = f.size.width >= 28 && f.size.width <= 90 && fabs(f.size.width - f.size.height) < 5;
        BOOL centered = fabs(CGRectGetMidX(f) - W / 2) < 70;
        BOOL low = f.origin.y > H * 0.60;
        BOOL round = v.layer.cornerRadius >= f.size.width / 2 - 3;
        if (sizeOK && centered && low && round && !insideTabBar(v)) { *out = (UIButton *)v; return; }
    }
    for (UIView *s in v.subviews) findBtn(s, w, out);
}

@interface BFHelper : NSObject
+ (instancetype)shared;
- (void)drag:(UIPanGestureRecognizer *)g;
@end
@implementation BFHelper
+ (instancetype)shared { static BFHelper *s; static dispatch_once_t t; dispatch_once(&t, ^{ s = [BFHelper new]; }); return s; }
- (void)drag:(UIPanGestureRecognizer *)g {
    UIView *v = g.view; CGPoint t = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [g setTranslation:CGPointZero inView:v.superview];
}
@end

static char kMoved;

static void tick(void) {
    UIWindow *w = keyWin(); if (!w) return;
    UIButton *b = gBtn;
    if (!b) {
        UIButton *found = nil;
        findBtn(w, w, &found);
        if (found) {
            b = found; gBtn = b;
            CGSize sz = b.bounds.size;
            [b removeFromSuperview];
            b.translatesAutoresizingMaskIntoConstraints = YES;
            b.frame = CGRectMake(0, 0, sz.width, sz.height);
            CGFloat bottom = w.safeAreaInsets.bottom;
            b.center = CGPointMake(w.bounds.size.width / 2, w.bounds.size.height - bottom - 170);
            [w addSubview:b];
            if (!objc_getAssociatedObject(b, &kMoved)) {
                UIPanGestureRecognizer *p = [[UIPanGestureRecognizer alloc] initWithTarget:[BFHelper shared] action:@selector(drag:)];
                [b addGestureRecognizer:p];
                objc_setAssociatedObject(b, &kMoved, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    }
    if (b) { if (b.superview != w) [w addSubview:b]; [w bringSubviewToFront:b]; }
}

__attribute__((constructor))
static void BFInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
            tick();
            static int n = 0; n++;
            if (n == 12 && !gBtn && !gToastShown) {
                gToastShown = YES;
                UIWindow *w = keyWin(); if (!w) return;
                UILabel *l = [UILabel new];
                l.text = @"  ButtonFix: ACJodel button not found  ";
                l.textColor = UIColor.whiteColor; l.font = [UIFont systemFontOfSize:13];
                l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.8];
                l.layer.cornerRadius = 12; l.clipsToBounds = YES; [l sizeToFit];
                l.center = CGPointMake(w.bounds.size.width / 2, w.safeAreaInsets.top + 50);
                [w addSubview:l];
                [UIView animateWithDuration:0.4 delay:3 options:0 animations:^{ l.alpha = 0; } completion:^(BOOL f) { [l removeFromSuperview]; }];
            }
        }];
    });
}
