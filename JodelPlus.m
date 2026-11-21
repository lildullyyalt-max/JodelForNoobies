// JodelPlus.m  -  no Substrate / ElleKit needed (pure Objective-C runtime).
// Features: 1) gallery upload on the camera screen  2) copy / paste unlocked  3) ads hidden
// UNTESTED: written from the class/selector names found in the old ACJodel tweak.
// Class names are Swift-mangled (_TtC5Jodel...) exactly as the old tweak used them.

#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - tiny swizzle helper

static NSMutableArray *gReport;
static void hook(Class c, SEL s, IMP n, IMP *orig) {
    if (!gReport) gReport = [NSMutableArray array];
    if (!c) { [gReport addObject:[NSString stringWithFormat:@"NO CLASS  -> %@", NSStringFromSelector(s)]]; return; }
    Method m = class_getInstanceMethod(c, s);
    if (!m) { [gReport addObject:[NSString stringWithFormat:@"NO METHOD -> %s %@", class_getName(c), NSStringFromSelector(s)]]; return; }
    [gReport addObject:[NSString stringWithFormat:@"OK         -> %s %@", class_getName(c), NSStringFromSelector(s)]];
    const char *types = method_getTypeEncoding(m);
    if (class_addMethod(c, s, n, types)) {
        *orig = method_getImplementation(m);          // was inherited
    } else {
        *orig = method_setImplementation(m, n);       // was defined on c
    }
}

#pragma mark - 1) NO ADS

static void (*o_ad_layout)(id, SEL);
static void n_ad_layout(UIView *self, SEL _cmd) {
    if (o_ad_layout) o_ad_layout(self, _cmd);
    self.hidden = YES;
    self.clipsToBounds = YES;
    for (NSLayoutConstraint *c in self.constraints) {
        if (c.firstAttribute == NSLayoutAttributeHeight) c.constant = 0;
    }
}

static void (*o_banner_load)(id, SEL, id);
static void n_banner_load(id self, SEL _cmd, id req) { /* never request an ad */ }

static void (*o_banner_win)(id, SEL);
static void n_banner_win(UIView *self, SEL _cmd) {
    if (o_banner_win) o_banner_win(self, _cmd);
    self.hidden = YES;
}

#pragma mark - 2) COPY / PASTE

static BOOL (*o_can)(id, SEL, SEL, id);
static BOOL n_can(id self, SEL _cmd, SEL action, id sender) {
    if (action == @selector(paste:)) return [UIPasteboard generalPasteboard].hasStrings;
    if (action == @selector(copy:) || action == @selector(cut:) ||
        action == @selector(select:) || action == @selector(selectAll:)) return YES;
    return o_can ? o_can(self, _cmd, action, sender) : NO;
}

// call UIKit's own paste: so Jodel's override (if any) is bypassed
static void n_paste(UITextView *self, SEL _cmd, id sender) {
    Method m = class_getInstanceMethod([UITextView class], @selector(paste:));
    ((void (*)(id, SEL, id))method_getImplementation(m))(self, _cmd, sender);
}

static void collectText(UIView *v, NSMutableArray *out) {
    if ([v isKindOfClass:[UILabel class]] && ((UILabel *)v).text.length) [out addObject:((UILabel *)v).text];
    else if ([v isKindOfClass:[UITextView class]] && ((UITextView *)v).text.length) [out addObject:((UITextView *)v).text];
    for (UIView *s in v.subviews) collectText(s, out);
}

@interface JPHelper : NSObject <PHPickerViewControllerDelegate>
@property (nonatomic, weak) UIViewController *captureVC;
+ (instancetype)shared;
- (void)longPressed:(UILongPressGestureRecognizer *)g;
- (void)galleryTapped:(UIButton *)b;
@end

static char kGestureKey, kButtonKey;

static void (*o_text_win)(id, SEL);
static void n_text_win(UIView *self, SEL _cmd) {
    if (o_text_win) o_text_win(self, _cmd);
    if (!self.window || objc_getAssociatedObject(self, &kGestureKey)) return;
    UILongPressGestureRecognizer *g =
        [[UILongPressGestureRecognizer alloc] initWithTarget:[JPHelper shared] action:@selector(longPressed:)];
    g.minimumPressDuration = 0.8;
    g.cancelsTouchesInView = NO;
    [self addGestureRecognizer:g];
    objc_setAssociatedObject(self, &kGestureKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - 3) GALLERY UPLOAD

static void (*o_cap_appear)(id, SEL, BOOL);
static void n_cap_appear(UIViewController *self, SEL _cmd, BOOL animated) {
    if (o_cap_appear) o_cap_appear(self, _cmd, animated);
    if (objc_getAssociatedObject(self, &kButtonKey)) return;
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImage *icon = [UIImage systemImageNamed:@"photo.on.rectangle"];
    [b setImage:icon forState:UIControlStateNormal];
    b.tintColor = UIColor.whiteColor;
    b.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    b.layer.cornerRadius = 22;
    CGFloat top = self.view.safeAreaInsets.top + 12;
    b.frame = CGRectMake(self.view.bounds.size.width - 64, top + 60, 44, 44);
    b.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
    [b addTarget:[JPHelper shared] action:@selector(galleryTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:b];
    objc_setAssociatedObject(self, &kButtonKey, b, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [JPHelper shared].captureVC = self;
}

@implementation JPHelper
+ (instancetype)shared {
    static JPHelper *s; static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [JPHelper new]; });
    return s;
}

- (void)longPressed:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    NSMutableArray *parts = [NSMutableArray array];
    collectText(g.view, parts);
    if (!parts.count) return;
    [UIPasteboard generalPasteboard].string = [parts componentsJoinedByString:@"\n"];
    [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeSuccess];
}

- (void)galleryTapped:(UIButton *)b {
    PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
    cfg.filter = [PHPickerFilter imagesFilter];
    cfg.selectionLimit = 1;
    PHPickerViewController *p = [[PHPickerViewController alloc] initWithConfiguration:cfg];
    p.delegate = self;
    UIViewController *vc = self.captureVC;
    [vc presentViewController:p animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    PHPickerResult *r = results.firstObject;
    if (!r) return;
    UIViewController *vc = self.captureVC;
    [r.itemProvider loadObjectOfClass:[UIImage class] completionHandler:^(UIImage *img, NSError *err) {
        if (![img isKindOfClass:[UIImage class]]) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            // Same hand-off the old tweak used: the capture screen's "image captured" callback.
            SEL s = NSSelectorFromString(@"captureManagerStillImageCaptured:image:");
            if (vc && [vc respondsToSelector:s]) {
                ((void (*)(id, SEL, id, id))objc_msgSend)(vc, s, nil, img);
            } else {
                UIAlertController *a = [UIAlertController alertControllerWithTitle:@"JodelPlus"
                    message:@"Could not hand the photo to Jodel (callback not found)."
                    preferredStyle:UIAlertControllerStyleAlert];
                [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [vc presentViewController:a animated:YES completion:nil];
            }
        });
    }];
}
@end

#pragma mark - install hooks

__attribute__((constructor))
static void JodelPlusInit(void) {
    // delay so all of Jodel's classes are registered
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // ads
        hook(NSClassFromString(@"_TtC5Jodel17AdCellContentView"), @selector(layoutSubviews), (IMP)n_ad_layout, (IMP *)&o_ad_layout);
        hook(NSClassFromString(@"GADBannerView"), @selector(loadRequest:), (IMP)n_banner_load, (IMP *)&o_banner_load);
        hook(NSClassFromString(@"GADBannerView"), @selector(didMoveToWindow), (IMP)n_banner_win, (IMP *)&o_banner_win);

        // copy / paste
        Class tv = NSClassFromString(@"_TtC5Jodel19PlaceholderTextView");
        hook(tv, @selector(canPerformAction:withSender:), (IMP)n_can, (IMP *)&o_can);
        IMP dummy; hook(tv, @selector(paste:), (IMP)n_paste, &dummy);
        hook(NSClassFromString(@"_TtC5Jodel23FeedCellTextContentView"), @selector(didMoveToWindow), (IMP)n_text_win, (IMP *)&o_text_win);

        // gallery upload
        hook(NSClassFromString(@"_TtC5Jodel26ImageCaptureViewController"), @selector(viewDidAppear:), (IMP)n_cap_appear, (IMP *)&o_cap_appear);

        // DEBUG: show what got hooked (remove later)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIWindow *w = nil;
            for (UIScene *sc in [UIApplication sharedApplication].connectedScenes)
                if ([sc isKindOfClass:[UIWindowScene class]])
                    for (UIWindow *x in ((UIWindowScene *)sc).windows) if (x.isKeyWindow) w = x;
            UIViewController *top = w.rootViewController;
            while (top.presentedViewController) top = top.presentedViewController;
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"JodelPlus loaded"
                message:[gReport componentsJoinedByString:@"\n"] preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [top presentViewController:a animated:YES completion:nil];
        });
    });
}
