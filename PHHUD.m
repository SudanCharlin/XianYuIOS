//
//  PHHUD.m
//

#import "PHHUD.h"
#import "PHCompat.h"
#import "PHEngine.h"
#import "PHMtop.h"

static char kPHKeyAssoc;

#pragma mark - 悬浮球

@interface PHBallView : UIView
@property (nonatomic, copy) void (^onTap)(void);
@property (nonatomic, weak) UIView *host;
@end

@implementation PHBallView {
    CGPoint _startPoint;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor colorWithRed:1.0 green:0.42 blue:0.10 alpha:0.92];
        self.layer.cornerRadius = frame.size.width / 2;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.25;
        self.layer.shadowRadius = 6;
        self.layer.shadowOffset = CGSizeMake(0, 2);

        UILabel *l = [[UILabel alloc] initWithFrame:self.bounds];
        l.text = @"鱼";
        l.textColor = UIColor.whiteColor;
        l.font = [UIFont boldSystemFontOfSize:17];
        l.textAlignment = NSTextAlignmentCenter;
        l.userInteractionEnabled = NO;
        [self addSubview:l];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap)];
        [self addGestureRecognizer:tap];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];
    }
    return self;
}

- (void)handleTap {
    if (self.onTap) self.onTap();
}

- (void)handlePan:(UIPanGestureRecognizer *)g {
    if (!self.host) return;
    CGPoint p = [g translationInView:self.host];
    if (g.state == UIGestureRecognizerStateBegan) {
        _startPoint = self.center;
    }
    self.center = CGPointMake(_startPoint.x + p.x, _startPoint.y + p.y);
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        CGFloat w = self.host.bounds.size.width;
        CGFloat x = self.center.x < w / 2 ? self.frame.size.width / 2 + 8 : w - self.frame.size.width / 2 - 8;
        CGFloat y = MAX(90, MIN(self.host.bounds.size.height - 90, self.center.y));
        [UIView animateWithDuration:0.22 animations:^{
            self.center = CGPointMake(x, y);
        }];
    }
}

@end

#pragma mark - 面板

@interface PHPanelController : UIViewController
@end

@implementation PHPanelController {
    UIScrollView *_scroll;
    UILabel *_logLabel;
    UIButton *_runBtn;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1.0];

    UILabel *title = [[UILabel alloc] init];
    title.text = @"  闲鱼小猪手 · iOS";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:17];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setTitle:@"关闭" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor colorWithRed:1.0 green:0.42 blue:0.10 alpha:1] forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:15];
    [close addTarget:self action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];

    UIView *bar = [[UIView alloc] init];
    [bar addSubview:title];
    [bar addSubview:close];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [title.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor],
        [title.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [close.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-12],
        [close.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
    ]];

    _scroll = [[UIScrollView alloc] init];
    _scroll.alwaysBounceVertical = YES;

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    [stack addArrangedSubview:[self sectionLabel:@"功能开关"]];
    [stack addArrangedSubview:[self switchRow:@"启用插件" key:@"enabled"]];
    [stack addArrangedSubview:[self switchRow:@"启动后自动跑批" key:@"autoRun"]];
    [stack addArrangedSubview:[self switchRow:@"每日签到" key:@"doSignin"]];
    [stack addArrangedSubview:[self switchRow:@"玩一玩签到" key:@"doPlaySignin"]];
    [stack addArrangedSubview:[self switchRow:@"擦亮宝贝" key:@"doPolish"]];
    [stack addArrangedSubview:[self switchRow:@"小店日福利" key:@"doShop"]];
    [stack addArrangedSubview:[self switchRow:@"任务链(触发+领奖)" key:@"doTasks"]];
    [stack addArrangedSubview:[self switchRow:@"夺宝投注" key:@"doLottery"]];
    [stack addArrangedSubview:[self switchRow:@"详细日志" key:@"verbose"]];
    [stack addArrangedSubview:[self switchRow:@"显示悬浮球" key:@"showBall"]];

    [stack addArrangedSubview:[self sectionLabel:@"跑批间隔（小时）"]];
    UISlider *sl = [[UISlider alloc] init];
    sl.minimumValue = 1; sl.maximumValue = 12; sl.value = [PHConfig shared].intervalH;
    [sl addTarget:self action:@selector(intervalChanged:) forControlEvents:UIControlEventValueChanged];
    [stack addArrangedSubview:sl];

    [stack addArrangedSubview:[self sectionLabel:@"操作"]];

    _runBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [_runBtn setTitle:@"立即跑批" forState:UIControlStateNormal];
    [_runBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    _runBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    _runBtn.backgroundColor = [UIColor colorWithRed:1.0 green:0.42 blue:0.10 alpha:1];
    _runBtn.layer.cornerRadius = 10;
    [_runBtn.heightAnchor constraintEqualToConstant:46].active = YES;
    [_runBtn addTarget:self action:@selector(runNow) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:_runBtn];

    UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [clearBtn setTitle:@"清空日志" forState:UIControlStateNormal];
    [clearBtn addTarget:self action:@selector(clearLog) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:clearBtn];

    [stack addArrangedSubview:[self sectionLabel:@"运行日志"]];

    _logLabel = [[UILabel alloc] init];
    _logLabel.numberOfLines = 0;
    _logLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _logLabel.textColor = [UIColor colorWithWhite:0.82 alpha:1];
    _logLabel.text = @"(尚未运行)";
    [stack addArrangedSubview:_logLabel];

    [_scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:_scroll.topAnchor constant:8],
        [stack.leadingAnchor constraintEqualToAnchor:_scroll.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:_scroll.trailingAnchor constant:-16],
        [stack.bottomAnchor constraintEqualToAnchor:_scroll.bottomAnchor constant:-20],
    ]];

    [self.view addSubview:bar];
    [self.view addSubview:_scroll];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [bar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [bar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [bar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [bar.heightAnchor constraintEqualToConstant:48],
        [_scroll.topAnchor constraintEqualToAnchor:bar.bottomAnchor],
        [_scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    [self reloadLog];
}

- (UILabel *)sectionLabel:(NSString *)t {
    UILabel *l = [[UILabel alloc] init];
    l.text = t;
    l.textColor = [UIColor colorWithWhite:0.55 alpha:1];
    l.font = [UIFont systemFontOfSize:12];
    return l;
}

- (UIView *)switchRow:(NSString *)title key:(NSString *)key {
    UIView *row = [[UIView alloc] init];
    UILabel *l = [[UILabel alloc] init];
    l.text = title;
    l.textColor = [UIColor colorWithWhite:0.92 alpha:1];
    l.font = [UIFont systemFontOfSize:15];

    UISwitch *sw = [[UISwitch alloc] init];
    sw.onTintColor = [UIColor colorWithRed:1.0 green:0.42 blue:0.10 alpha:1];
    sw.on = [[[PHConfig shared] valueForKey:key] boolValue];
    sw.tag = (NSInteger)[key hash];
    objc_setAssociatedObject(sw, &kPHKeyAssoc, key, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];

    [row addSubview:l];
    [row addSubview:sw];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    sw.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:36],
        [l.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [l.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [sw.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [sw.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    ]];
    return row;
}

- (void)switchChanged:(UISwitch *)sw {
    NSString *key = objc_getAssociatedObject(sw, &kPHKeyAssoc);
    if (!key) return;
    [[PHConfig shared] setValue:@(sw.isOn) forKey:key];
    [[PHConfig shared] save];
    [[PHHUD shared] refresh];
}

- (void)intervalChanged:(UISlider *)sl {
    [PHConfig shared].intervalH = (NSInteger)lroundf(sl.value);
}

- (void)clearLog {
    [PHLog reset];
    [self reloadLog];
}

- (void)reloadLog {
    NSArray *lines = [PHLog snapshot];
    _logLabel.text = lines.count ? [lines componentsJoinedByString:@"\n"] : @"(暂无日志)";
}

- (void)runNow {
    if ([PHEngine shared].running) {
        [[PHHUD shared] toast:@"正在执行中…"];
        return;
    }
    _runBtn.enabled = NO;
    [_runBtn setTitle:@"执行中…" forState:UIControlStateNormal];
    [self reloadLog];

    [[PHEngine shared] runWithCompletion:^(NSString *report, NSInteger ok, NSInteger fail) {
        self->_runBtn.enabled = YES;
        [self->_runBtn setTitle:@"立即跑批" forState:UIControlStateNormal];
        [self reloadLog];
        [[PHHUD shared] toast:[NSString stringWithFormat:@"完成 · 成功 %ld · 失败 %ld", (long)ok, (long)fail]];
    }];
}

- (void)dismiss {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

#pragma mark - PHHUD

@implementation PHHUD {
    UIWindow *_win;
    PHBallView *_ball;
    BOOL _presenting;
}

+ (instancetype)shared {
    static PHHUD *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [PHHUD new]; });
    return s;
}

- (UIWindow *)keyWindow {
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            if (w.isKeyWindow) return w;
        }
        if (((UIWindowScene *)sc).windows.count) return ((UIWindowScene *)sc).windows.firstObject;
    }
    return UIApplication.sharedApplication.windows.firstObject;
}

- (void)attach {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_ball) {
            [self refresh];
            return;
        }
        UIWindow *host = [self keyWindow];
        if (!host) {
            PHLOG(@"[ui] 无可用 window，稍后重试");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self attach];
            });
            return;
        }

        CGRect b = host.bounds;
        PHBallView *ball = [[PHBallView alloc] initWithFrame:CGRectMake(b.size.width - 66, b.size.height * 0.55, 54, 54)];
        ball.host = host;
        __weak typeof(self) ws = self;
        ball.onTap = ^{ [ws presentPanel]; };
        [host addSubview:ball];
        self->_ball = ball;
        [self refresh];
        PHLOG(@"[ui] 悬浮球已挂载");
    });
}

- (void)detach {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_ball removeFromSuperview];
        self->_ball = nil;
    });
}

- (void)refresh {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self->_ball) return;
        self->_ball.hidden = ![PHConfig shared].showBall;
    });
}

- (void)presentPanel {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_presenting) return;
        UIViewController *top = [self topController];
        if (!top) { PHLOG(@"[ui] 无 topViewController"); return; }

        PHPanelController *vc = [PHPanelController new];
        vc.modalPresentationStyle = UIModalPresentationPageSheet;
        self->_presenting = YES;
        [top presentViewController:vc animated:YES completion:^{
            self->_presenting = NO;
        }];
    });
}

- (UIViewController *)topController {
    UIWindow *w = [self keyWindow];
    UIViewController *vc = w.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

- (void)toast:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *host = [self keyWindow];
        if (!host) return;
        UILabel *l = [[UILabel alloc] init];
        l.text = text;
        l.textColor = UIColor.whiteColor;
        l.font = [UIFont systemFontOfSize:13];
        l.numberOfLines = 0;
        l.textAlignment = NSTextAlignmentCenter;
        l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.82];
        l.layer.cornerRadius = 10;
        l.clipsToBounds = YES;
        l.alpha = 0;
        CGSize sz = [l sizeThatFits:CGSizeMake(host.bounds.size.width - 80, 200)];
        l.frame = CGRectMake((host.bounds.size.width - sz.width - 28) / 2,
                             host.bounds.size.height - sz.height - 100,
                             sz.width + 28, sz.height + 20);
        [host addSubview:l];
        [UIView animateWithDuration:0.2 animations:^{ l.alpha = 1; } completion:^(BOOL f) {
            [UIView animateWithDuration:0.3 delay:2.0 options:0 animations:^{ l.alpha = 0; } completion:^(BOOL f2) {
                [l removeFromSuperview];
            }];
        }];
    });
}

@end
