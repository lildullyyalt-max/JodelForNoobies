// JodelPlus v2  -  pure Objective-C runtime (no Substrate / ElleKit).
// Floating blue button (bottom-middle, draggable) -> tap to open:
//   [clipboard] paste into the focused text field
//   [photo]     pick a photo from your library (hands it to Jodel's camera screen if open,
//               otherwise copies the image to the clipboard)
//   [eye]       ads hidden ON/OFF
//   [info]      shows which hooks installed (debug)
// Also: long-press a post to copy its text, paste unlocked in the compose box.
// UNTESTED on device - use the [info] button to see what worked.

#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - helpers

static NSMutableArray *gReport;
static BOOL gAdsOff = YES;
static __weak id gFR;

static void hook(Class c, SEL s, IMP n, IMP *orig) {
    if (!gReport) gReport = [NSMutableArray array];
    if (!c) { [gReport addObject:[NSString stringWithFormat:@"NO CLASS: %@", NSStringFromSelector(s)]]; return; }
    Method m = class_getInstanceMethod(c, s);
    if (!m) { [gReport addObject:[NSString stringWithFormat:@"NO METHOD: %s %@", class_getName(c), NSStringFromSelector(s)]]; return; }
    [gReport addObject:[NSString stringWithFormat:@"OK: %s %@", class_getName(c), NSStringFromSelector(s)]];
    const char *types = method_getTypeEncoding(m);
    if (class_addMethod(c, s, n, types)) *orig = method_getImplementation(m);
    else *orig = method_setImplementation(m, n);
}

static UIWindow *keyWin(void) {
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) if (w.isKeyWindow) return w;
    }
    return nil;
}

static UIViewController *topVC(void) {
    UIViewController *t = keyWin().rootViewController;
    while (t.presentedViewController) t = t.presentedViewController;
    return t;
}

static void collectText(UIView *v, NSMutableArray *out) {
    if ([v isKindOfClass:[UILabel class]] && ((UILabel *)v).text.length) [out addObject:((UILabel *)v).text];
    else if ([v isKindOfClass:[UITextView class]] && ((UITextView *)v).text.length) [out addObject:((UITextView *)v).text];
    for (UIView *s in v.subviews) collectText(s, out);
}

static BOOL isAdView(UIView *v) {
    const char *n = class_getName([v class]);
    return strstr(n, "GADBannerView") || strstr(n, "GAMBannerView") || strstr(n, "AdCellContentView") ||
           strstr(n, "GADNativeAdView") || strstr(n, "GADMediaView") || strstr(n, "AdManagerItem");
}

static void hideAds(UIView *v) {
    if (isAdView(v)) { v.hidden = YES; v.alpha = 0; return; }
    for (UIView *s in v.subviews) hideAds(s);
}

#pragma mark - find the object that receives Jodel's capture callbacks

static id delegateIfResponds(id obj, SEL sel) {
    if (!obj) return nil;
    if ([obj respondsToSelector:sel]) return obj;
    @try {
        for (NSString *key in @[@"captureManager", @"videoCapture", @"captureManagerService"]) {
            id cm = [obj valueForKey:key];
            if (cm) {
                if ([cm respondsToSelector:sel]) return cm;
                id d = [cm valueForKey:@"delegate"];
                if (d && [d respondsToSelector:sel]) return d;
            }
        }
    } @catch (NSException *e) {}
    return nil;
}

static id findTarget(UIViewController *vc, SEL sel, int depth) {
    if (!vc || depth > 8) return nil;
    id hit = delegateIfResponds(vc, sel);
    if (hit) return hit;
    for (UIViewController *c in vc.childViewControllers) { hit = findTarget(c, sel, depth + 1); if (hit) return hit; }
    if (vc.presentedViewController) { hit = findTarget(vc.presentedViewController, sel, depth + 1); if (hit) return hit; }
    return nil;
}

static id findCaptureTarget(SEL sel) {
    return findTarget(keyWin().rootViewController, sel, 0);
}

static NSString *classesImplementing(SEL sel) {
    unsigned int n = 0;
    Class *list = objc_copyClassList(&n);
    NSMutableArray *names = [NSMutableArray array];
    for (unsigned int i = 0; i < n && names.count < 6; i++) {
        if (class_getInstanceMethod(list[i], sel) && strstr(class_getName(list[i]), "Jodel")) {
            [names addObject:[NSString stringWithUTF8String:class_getName(list[i])]];
        }
    }
    free(list);
    return names.count ? [names componentsJoinedByString:@", "] : @"none found";
}

#pragma mark - first responder finder

@interface UIResponder (JPFind)
- (void)jp_grab:(id)sender;
@end
@implementation UIResponder (JPFind)
- (void)jp_grab:(id)sender { gFR = self; }
@end

#pragma mark - hooks: ads

static void (*o_ad_layout)(id, SEL);
static void n_ad_layout(UIView *self, SEL _cmd) {
    if (o_ad_layout) o_ad_layout(self, _cmd);
    if (gAdsOff) { self.hidden = YES; self.clipsToBounds = YES; }
}
static void (*o_banner_load)(id, SEL, id);
static void n_banner_load(id self, SEL _cmd, id req) { if (!gAdsOff && o_banner_load) o_banner_load(self, _cmd, req); }

#pragma mark - hooks: copy / paste

static BOOL (*o_can)(id, SEL, SEL, id);
static BOOL n_can(id self, SEL _cmd, SEL a, id sender) {
    if (a == @selector(paste:)) return [UIPasteboard generalPasteboard].hasStrings;
    if (a == @selector(copy:) || a == @selector(cut:) || a == @selector(select:) || a == @selector(selectAll:)) return YES;
    return o_can ? o_can(self, _cmd, a, sender) : NO;
}
static void n_paste(UITextView *self, SEL _cmd, id sender) {
    Method m = class_getInstanceMethod([UITextView class], @selector(paste:));
    ((void (*)(id, SEL, id))method_getImplementation(m))(self, _cmd, sender);
}

@interface JPHelper : NSObject <PHPickerViewControllerDelegate>
@property (nonatomic, weak) UIViewController *captureVC;
@property (nonatomic, strong) UIButton *mainBtn;
@property (nonatomic, strong) NSArray<UIButton *> *items;
@property (nonatomic, assign) BOOL open;
+ (instancetype)shared;
- (void)setupUI;
- (void)toast:(NSString *)t;
@end

static char kGestureKey, kButtonKey;

static void (*o_text_win)(id, SEL);
static void n_text_win(UIView *self, SEL _cmd) {
    if (o_text_win) o_text_win(self, _cmd);
    if (!self.window || objc_getAssociatedObject(self, &kGestureKey)) return;
    UILongPressGestureRecognizer *g = [[UILongPressGestureRecognizer alloc] initWithTarget:[JPHelper shared] action:@selector(longPressed:)];
    g.minimumPressDuration = 0.8; g.cancelsTouchesInView = NO;
    [self addGestureRecognizer:g];
    objc_setAssociatedObject(self, &kGestureKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - hook: camera screen

static void (*o_cap_appear)(id, SEL, BOOL);
static void n_cap_appear(UIViewController *self, SEL _cmd, BOOL animated) {
    if (o_cap_appear) o_cap_appear(self, _cmd, animated);
    [JPHelper shared].captureVC = self;
}

#pragma mark - UI

@implementation JPHelper
+ (instancetype)shared {
    static JPHelper *s; static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [JPHelper new]; });
    return s;
}

- (UIButton *)roundBtn:(NSString *)icon size:(CGFloat)sz color:(UIColor *)c action:(SEL)a {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(0, 0, sz, sz);
    b.backgroundColor = c;
    b.layer.cornerRadius = sz / 2;
    b.layer.shadowColor = UIColor.blackColor.CGColor;
    b.layer.shadowOpacity = 0.35; b.layer.shadowRadius = 5; b.layer.shadowOffset = CGSizeMake(0, 2);
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:sz * 0.42];
    [b setImage:[[UIImage systemImageNamed:icon withConfiguration:cfg] imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal] forState:UIControlStateNormal];
    [b addTarget:self action:a forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)setupUI {
    UIWindow *w = keyWin();
    if (!w) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self setupUI]; }); return; }
    if (self.mainBtn) return;

    self.mainBtn = [self roundBtn:@"slider.horizontal.3" size:52 color:[UIColor systemBlueColor] action:@selector(toggleMenu)];
    CGFloat x = w.bounds.size.width / 2, y = w.bounds.size.height - w.safeAreaInsets.bottom - 110;
    self.mainBtn.center = CGPointMake(x, y);
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragged:)];
    [self.mainBtn addGestureRecognizer:pan];

    UIButton *b1 = [self roundBtn:@"doc.on.clipboard" size:44 color:[UIColor colorWithWhite:0.15 alpha:0.9] action:@selector(doPaste)];
    UIButton *b2 = [self roundBtn:@"photo.on.rectangle" size:44 color:[UIColor colorWithWhite:0.15 alpha:0.9] action:@selector(doGallery)];
    UIButton *b3 = [self roundBtn:@"eye.slash" size:44 color:[UIColor systemGreenColor] action:@selector(doAds:)];
    UIButton *b4 = [self roundBtn:@"info.circle" size:44 color:[UIColor colorWithWhite:0.15 alpha:0.9] action:@selector(doInfo)];
    self.items = @[b1, b2, b3, b4];
    for (UIButton *b in self.items) { b.hidden = YES; [w addSubview:b]; }
    [w addSubview:self.mainBtn];

    // keep on top + hide ads (works even if Jodel's feed is not native)
    [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES block:^(NSTimer *t) {
        UIWindow *kw = keyWin(); if (!kw) return;
        if (self.mainBtn.superview != kw) {
            [kw addSubview:self.mainBtn];
            for (UIButton *b in self.items) [kw addSubview:b];
        }
        for (UIButton *b in self.items) [kw bringSubviewToFront:b];
        [kw bringSubviewToFront:self.mainBtn];
        if (gAdsOff) hideAds(kw);
    }];
}

- (void)layoutItems {
    CGPoint c = self.mainBtn.center;
    for (NSUInteger i = 0; i < self.items.count; i++) {
        UIButton *b = self.items[i];
        b.center = CGPointMake(c.x, c.y - 60 - i * 54);
    }
}
- (void)toggleMenu {
    self.open = !self.open;
    [self layoutItems];
    for (UIButton *b in self.items) b.hidden = !self.open;
}
- (void)dragged:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    CGPoint t = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [g setTranslation:CGPointZero inView:v.superview];
    if (self.open) [self layoutItems];
}

- (void)toast:(NSString *)text {
    UIWindow *w = keyWin(); if (!w) return;
    UILabel *l = [[UILabel alloc] init];
    l.text = [NSString stringWithFormat:@"  %@  ", text];
    l.textColor = UIColor.whiteColor; l.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.8];
    l.layer.cornerRadius = 14; l.clipsToBounds = YES; l.numberOfLines = 0; l.textAlignment = NSTextAlignmentCenter;
    CGSize sz = [l sizeThatFits:CGSizeMake(w.bounds.size.width - 60, 200)];
    l.frame = CGRectMake(0, 0, sz.width, MAX(sz.height, 30));
    l.center = CGPointMake(w.bounds.size.width / 2, w.safeAreaInsets.top + 60);
    [w addSubview:l];
    [UIView animateWithDuration:0.4 delay:2.0 options:0 animations:^{ l.alpha = 0; } completion:^(BOOL f) { [l removeFromSuperview]; }];
}

- (void)doPaste {
    gFR = nil;
    [[UIApplication sharedApplication] sendAction:@selector(jp_grab:) to:nil from:nil forEvent:nil];
    id fr = gFR;
    NSString *t = [UIPasteboard generalPasteboard].string;
    if (!t.length) { [self toast:@"Clipboard is empty"]; return; }
    if (fr && [fr conformsToProtocol:@protocol(UIKeyInput)]) { [(id<UIKeyInput>)fr insertText:t]; [self toast:@"Pasted"]; }
    else [self toast:@"Tap a text field first, then press paste"];
}

- (void)doAds:(UIButton *)b {
    gAdsOff = !gAdsOff;
    b.backgroundColor = gAdsOff ? [UIColor systemGreenColor] : [UIColor systemRedColor];
    [self toast:gAdsOff ? @"Ads hidden: ON" : @"Ads hidden: OFF (restart app)"];
}

- (void)doInfo {
    NSString *m = [NSString stringWithFormat:@"JodelPlus v2 loaded.\n\nVideo callback in: %@\nPhoto callback in: %@\n\n%@",
        classesImplementing(NSSelectorFromString(@"captureManagerRecordingFinished:outputURL:error:")),
        classesImplementing(NSSelectorFromString(@"captureManagerStillImageCaptured:image:")),
        [gReport componentsJoinedByString:@"\n"]];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"JodelPlus" message:m preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [topVC() presentViewController:a animated:YES completion:nil];
}

- (void)longPressed:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    NSMutableArray *parts = [NSMutableArray array];
    collectText(g.view, parts);
    if (!parts.count) return;
    [UIPasteboard generalPasteboard].string = [parts componentsJoinedByString:@"\n"];
    [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeSuccess];
    [self toast:@"Copied"];
}

- (void)doGallery {
    PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
    cfg.filter = [PHPickerFilter anyFilterMatchingSubfilters:@[[PHPickerFilter imagesFilter], [PHPickerFilter videosFilter]]];
    cfg.selectionLimit = 1;
    PHPickerViewController *p = [[PHPickerViewController alloc] initWithConfiguration:cfg];
    p.delegate = self;
    [topVC() presentViewController:p animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    PHPickerResult *r = results.firstObject;
    if (!r) return;
    NSItemProvider *ip = r.itemProvider;

    if ([ip hasItemConformingToTypeIdentifier:@"public.movie"]) {
        // VIDEO: copy to our own temp file, then hand it to Jodel's capture screen
        [ip loadFileRepresentationForTypeIdentifier:@"public.movie" completionHandler:^(NSURL *url, NSError *err) {
            if (!url) return;
            NSString *ext = url.pathExtension.length ? url.pathExtension : @"mov";
            NSURL *dst = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"jp_%@.%@", [[NSUUID UUID] UUIDString], ext]]];
            [[NSFileManager defaultManager] copyItemAtURL:url toURL:dst error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                SEL began = NSSelectorFromString(@"captureManagerRecordingBegan:");
                SEL done  = NSSelectorFromString(@"captureManagerRecordingFinished:outputURL:error:");
                id target = findCaptureTarget(done);
                if (!target && self.captureVC) target = delegateIfResponds(self.captureVC, done);
                if (target) {
                    if ([target respondsToSelector:began]) ((void (*)(id, SEL, id))objc_msgSend)(target, began, nil);
                    ((void (*)(id, SEL, id, id, id))objc_msgSend)(target, done, nil, dst, nil);
                    [self toast:@"Video sent to Jodel"];
                } else {
                    [self toast:@"Open Jodel's camera screen first, then pick the video"];
                }
            });
        }];
        return;
    }

    [ip loadObjectOfClass:[UIImage class] completionHandler:^(UIImage *img, NSError *err) {
        if (![img isKindOfClass:[UIImage class]]) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            SEL s = NSSelectorFromString(@"captureManagerStillImageCaptured:image:");
            id target = findCaptureTarget(s);
            if (!target && self.captureVC) target = delegateIfResponds(self.captureVC, s);
            if (target) {
                ((void (*)(id, SEL, id, id))objc_msgSend)(target, s, nil, img);
                [self toast:@"Photo sent to Jodel"];
            } else {
                [UIPasteboard generalPasteboard].image = img;
                [self toast:@"Camera screen not open - image copied to clipboard"];
            }
        });
    }];
}
@end

#pragma mark - init

__attribute__((constructor))
static void JodelPlusInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        hook(NSClassFromString(@"_TtC5Jodel17AdCellContentView"), @selector(layoutSubviews), (IMP)n_ad_layout, (IMP *)&o_ad_layout);
        hook(NSClassFromString(@"GADBannerView"), @selector(loadRequest:), (IMP)n_banner_load, (IMP *)&o_banner_load);

        Class tv = NSClassFromString(@"_TtC5Jodel19PlaceholderTextView");
        hook(tv, @selector(canPerformAction:withSender:), (IMP)n_can, (IMP *)&o_can);
        IMP dummy; hook(tv, @selector(paste:), (IMP)n_paste, &dummy);
        hook(NSClassFromString(@"_TtC5Jodel23FeedCellTextContentView"), @selector(didMoveToWindow), (IMP)n_text_win, (IMP *)&o_text_win);
        hook(NSClassFromString(@"_TtC5Jodel26ImageCaptureViewController"), @selector(viewDidAppear:), (IMP)n_cap_appear, (IMP *)&o_cap_appear);

        [[JPHelper shared] setupUI];
    });
}
