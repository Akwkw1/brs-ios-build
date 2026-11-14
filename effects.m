// System Check's Effects tab: what a Telegram client's look is made of on iOS 16, one effect at a time over moving
// content, timed -- to find what makes such an app stutter on a phone whose compositor is the port's OpenGL ES.
//
// On iOS 16 (not 26) Telegram's "glass" is no Metal: it is a private CABackdropLayer with CAFilter "gaussianBlur"
// (radius 2 or 6) and "colorMatrix", a "variableBlur" with a gradient mask at the edges, springs (CASpringAnimation)
// for its sheets, and grids of thumbnails. All of that is drawn by the render server, not by the app. The scenarios
// below take each piece alone (and one Metal shader, drawn by the app, to compare), written here from those facts --
// no code of Telegram's.
//
// Each scenario runs 10 s with the tab bar and navigation bar hidden (themselves blurred): 1 s to settle, then 8 s
// measured -- the app's display link (frames, late frames, the worst). The result lines ("effectscheck: ...") go to
// the console and to Documents/effectscheck.log with the wall-clock time, so that the port's kernel log (the
// framebuffer's five-second "frames in" lines) can be read against them. systemcheck://effects/run runs them all.
#import <AVFoundation/AVFoundation.h>
#import <Metal/Metal.h>
#import <Photos/Photos.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#include <fcntl.h>
#include <unistd.h>
#import "check.h"

typedef struct {
	float m11, m12, m13, m14, m15, m21, m22, m23, m24, m25, m31, m32, m33, m34, m35, m41, m42, m43, m44, m45;
} EffectsColorMatrix;

static void
effects_log(NSString *line)
{
	NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?:
	    NSTemporaryDirectory();
	NSString *path = [documents stringByAppendingPathComponent:@"effectscheck.log"];
	NSDateFormatter *f = [NSDateFormatter new];
	NSData *bytes;
	int fd;

	f.dateFormat = @"HH:mm:ss";
	bytes = [[NSString stringWithFormat:@"%@ %@\n", [f stringFromDate:[NSDate date]], line] dataUsingEncoding:NSUTF8StringEncoding];
	fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
	if (fd >= 0) {
		(void)write(fd, bytes.bytes, bytes.length);
		close(fd);
	}
	NSLog(@"effectscheck: %@", line);
}

@interface NSObject (EffectsCAFilter)
+ (id)filterWithName:(NSString *)name;          /* (CAFilter's, private) */
@end

/* a CAFilter (private) by name, its inputs set by key-value coding */
static id
filter(NSString *name, NSDictionary *inputs)
{
	Class c = NSClassFromString(@"CAFilter");
	id f = c ? [(id)c filterWithName:name] : nil;

	for (NSString *k in inputs) {
		@try {
			[f setValue:inputs[k] forKey:k];
		} @catch (NSException *e) {
		}
	}
	return f;
}

/* a CABackdropLayer (private): what is behind it, through FILTERS, at SCALE of the screen's resolution */
static CALayer *
backdrop(NSArray *filters, CGFloat scale)
{
	Class c = NSClassFromString(@"CABackdropLayer");
	CALayer *layer = c ? [c new] : [CALayer new];

	@try {
		[layer setValue:filters forKey:@"filters"];
		[layer setValue:@(scale) forKey:@"scale"];
		[layer setValue:@YES forKey:@"enabled"];
	} @catch (NSException *e) {
	}
	return layer;
}

static CAShapeLayer *
capsule_mask(CGRect bounds)
{
	CAShapeLayer *m = [CAShapeLayer layer];

	m.path = [UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:bounds.size.height / 2].CGPath;
	return m;
}

/* a glass capsule (what such a glass view is made of): a backdrop through FILTERS, masked to a capsule, a faint rim */
static CALayer *
glass(CGRect frame, NSArray *filters, CGFloat scale)
{
	CALayer *both = [CALayer layer], *g = backdrop(filters, scale), *rim = [CALayer layer];

	both.frame = frame;
	g.frame = both.bounds;
	g.mask = capsule_mask(g.bounds);
	rim.frame = both.bounds;
	rim.cornerRadius = frame.size.height / 2;
	rim.borderWidth = 1;
	rim.borderColor = [UIColor colorWithWhite:1 alpha:0.35].CGColor;
	rim.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08].CGColor;
	[both addSublayer:g];
	[both addSublayer:rim];
	return both;
}

static NSArray *
blur(CGFloat radius)
{
	return @[ filter(@"gaussianBlur", @{ @"inputRadius": @(radius), @"inputNormalizeEdges": @YES }) ];
}

static NSArray *
tint_blur(CGFloat radius)
{
	EffectsColorMatrix m = { 1.08f, 0, 0, 0, 0.02f, 0, 1.08f, 0, 0, 0.02f, 0, 0, 1.08f, 0, 0.02f, 0, 0, 0, 1, 0 };
	NSValue *v = [NSValue valueWithBytes:&m objCType:"{CAColorMatrix=ffffffffffffffffffff}"];

	return @[ filter(@"colorMatrix", @{ @"inputColorMatrix": v }),
		filter(@"gaussianBlur", @{ @"inputRadius": @(radius), @"inputNormalizeEdges": @YES }) ];
}

#pragma mark the Metal scenario

static NSString *const kGlassShader = @
	"#include <metal_stdlib>\n"
	"using namespace metal;\n"
	"struct V { float4 pos [[position]]; float2 uv; };\n"
	"vertex V glass_vs(uint id [[vertex_id]], constant float2 *pts [[buffer(0)]]) {\n"
	"  V v; v.pos = float4(pts[id], 0, 1); v.uv = pts[id] * 0.5 + 0.5; return v;\n"
	"}\n"
	"static float3 scene(float2 p, float t) {\n"
	"  float2 g = fract(p * float2(6, 13) + float2(0, t * 0.4));\n"
	"  float stripes = step(0.5, g.x) * 0.5 + step(0.5, g.y) * 0.5;\n"
	"  return mix(float3(0.10, 0.35, 0.80), float3(0.95, 0.55, 0.20), stripes) * (0.6 + 0.4 * sin(p.y * 9 + t));\n"
	"}\n"
	"fragment float4 glass_fs(V in [[stage_in]], constant float &t [[buffer(0)]]) {\n"
	"  float2 p = in.uv;\n"
	"  float2 c = float2(0.5, 0.5 + 0.25 * sin(t * 0.7));\n"
	"  float2 d = (p - c) * float2(1.0, 2.2);\n"
	"  float r = length(d);\n"
	"  if (r > 0.42) return float4(scene(p, t), 1);\n"
	"  float edge = smoothstep(0.30, 0.42, r);\n"
	"  float2 q = p + normalize(d + 1e-5) * edge * 0.03;          // refraction at the rim\n"
	"  float3 acc = 0;\n"
	"  for (int i = -2; i <= 2; i++) for (int j = -2; j <= 2; j++)\n"
	"    acc += scene(q + float2(i, j) * 0.004, t);                // a 5x5 blur of what is behind\n"
	"  acc /= 25.0;\n"
	"  acc = mix(acc, float3(1), 0.10 + 0.25 * edge * edge);        // tint, rim light\n"
	"  return float4(acc, 1);\n"
	"}\n";

#pragma mark the tab

@interface EffectsController : UIViewController
@property (strong) UILabel *banner;
@property (strong) UITextView *results;
@property (strong) CALayer *stage;
@property (strong) CADisplayLink *link;
@property (strong) NSMutableArray<NSNumber *> *stamps;
@property (strong) NSMutableString *report;
@property (assign) NSUInteger next;
@property (assign) BOOL running, measuring;
/* the Metal scenario */
@property (strong) id<MTLDevice> device;
@property (strong) id<MTLCommandQueue> queue;
@property (strong) id<MTLRenderPipelineState> pipeline;
@property (strong) CAMetalLayer *metalLayer;
@property (assign) CFTimeInterval metalStart;
/* the photo-library and camera scenarios */
@property (strong) PHCachingImageManager *imageManager;
@property (strong) AVCaptureSession *capture;
- (void)start;
@end

static EffectsController *g_effects;

UIViewController *
effects_controller(void)
{
	g_effects = [EffectsController new];
	return g_effects;
}

/*
 * systemcheck://effects/photos: 60 made-up photos into the library (a photo picker -- Nagram's, the photo-grid
 * scenario -- needs some to scroll; the port's library starts empty at every boot). Each a numbered gradient.
 */
void
effects_photos(void)
{
	void (^add)(void) = ^{
		[PHPhotoLibrary.sharedPhotoLibrary performChanges:^{
			for (int i = 0; i < 60; i++) {
				UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];

				fmt.scale = 1;
				UIImage *img = [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(1200, 1600) format:fmt]
				    imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
					CGFloat hue = (CGFloat)(i % 30) / 30;
					CGFloat comps[8] = { 0 };
					UIColor *a = [UIColor colorWithHue:hue saturation:0.7 brightness:0.9 alpha:1];
					UIColor *b = [UIColor colorWithHue:fmod(hue + 0.4, 1) saturation:0.8 brightness:0.4 alpha:1];

					[a getRed:&comps[0] green:&comps[1] blue:&comps[2] alpha:&comps[3]];
					[b getRed:&comps[4] green:&comps[5] blue:&comps[6] alpha:&comps[7]];
					CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
					CGGradientRef g = CGGradientCreateWithColorComponents(cs, comps, NULL, 2);

					CGContextDrawLinearGradient(ctx.CGContext, g, CGPointZero, CGPointMake(1200, 1600), 0);
					CGGradientRelease(g);
					CGColorSpaceRelease(cs);
					[[NSString stringWithFormat:@"TEST %02d", i] drawAtPoint:CGPointMake(80, 700)
					    withAttributes:@{ NSFontAttributeName: [UIFont boldSystemFontOfSize:180],
						NSForegroundColorAttributeName: UIColor.whiteColor }];
				}];
				[PHAssetChangeRequest creationRequestForAssetFromImage:img];
			}
		} completionHandler:^(BOOL ok, NSError *error) {
			effects_log([NSString stringWithFormat:@"photos: 60 added: %@ %@", ok ? @"yes" : @"NO",
			    error.localizedDescription ?: @""]);
		}];
	};

	[PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelReadWrite handler:^(PHAuthorizationStatus status) {
		effects_log([NSString stringWithFormat:@"photos: access %ld", (long)status]);
		if (status == PHAuthorizationStatusAuthorized || status == PHAuthorizationStatusLimited) {
			add();
		}
	}];
}

void
effects_run(void)
{
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		[g_effects start];
	});
}

static const struct scenario {
	const char *name, *what;
} scenarios[] = {
	{ "base", "moving tiles, no effect" },
	{ "visualeffect", "UIVisualEffectView (system material) over them" },
	{ "backdrop-blur2", "CABackdropLayer + gaussianBlur 2, a capsule (Telegram's normal glass)" },
	{ "backdrop-blur6", "CABackdropLayer + gaussianBlur 6 (Telegram's clear glass)" },
	{ "backdrop-blur20", "CABackdropLayer + gaussianBlur 20" },
	{ "backdrop-blur6-quarter", "gaussianBlur 6 on a backdrop at 1/4 resolution" },
	{ "backdrop-matrix-blur2", "colorMatrix + gaussianBlur 2" },
	{ "variableblur", "variableBlur with a gradient mask, the top quarter (the edge effect)" },
	{ "glass-x4", "four glass capsules (a tab bar)" },
	{ "glass-x8", "eight glass capsules" },
	{ "spring-sheet", "a sheet on springs, the page under it scaled (no blur)" },
	{ "spring-sheet-glass", "the same sheet with glass on it" },
	{ "thumbnails", "120 thumbnails scrolling (a photo picker's grid)" },
	{ "photo-grid", "the photo library's own thumbnails (PHCachingImageManager) scrolling" },
	{ "camera-tile", "a live camera preview tile over the tiles (a photo picker's first cell)" },
	{ "photo-grid-camera", "the library's thumbnails with the camera tile on them" },
	{ "metal-glass", "the app's own Metal: a glass shader drawn every frame (refraction, 5x5 blur)" },
};
#define SCENARIOS (sizeof(scenarios) / sizeof(scenarios[0]))

@implementation EffectsController

- (void)viewDidLoad
{
	[super viewDidLoad];
	self.title = @"Effects";
	self.view.backgroundColor = UIColor.systemBackgroundColor;
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Run" style:UIBarButtonItemStylePlain
	    target:self action:@selector(start)];
	self.results = [UITextView new];
	self.results.editable = NO;
	self.results.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
	self.results.text = @"Run: each effect for 10 s over moving content (about 2.5 minutes), timed.\n\n"
	    "On iOS 16 a Telegram client's glass is CABackdropLayer + blur, drawn by the system's compositor; "
	    "the last scenario is the app's own Metal, for comparison.";
	[self.view addSubview:self.results];
	self.banner = [UILabel new];
	self.banner.font = [UIFont boldSystemFontOfSize:15];
	self.banner.textColor = UIColor.whiteColor;
	self.banner.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
	self.banner.textAlignment = NSTextAlignmentCenter;
	self.banner.numberOfLines = 2;
	self.banner.hidden = YES;
}

- (void)viewDidLayoutSubviews
{
	[super viewDidLayoutSubviews];
	self.results.frame = UIEdgeInsetsInsetRect(self.view.bounds, self.view.safeAreaInsets);
}

- (void)start
{
	if (self.running) {
		return;
	}
	self.running = YES;
	self.next = 0;
	self.report = [NSMutableString stringWithString:@"scenario: fps (display link), late frames, worst\n"];
	effects_log([NSString stringWithFormat:@"START %lu scenarios", (unsigned long)SCENARIOS]);
	self.navigationController.navigationBarHidden = YES;
	self.tabBarController.tabBar.hidden = YES;
	self.results.hidden = YES;
	[self.view.window addSubview:self.banner];
	self.banner.frame = CGRectMake(0, self.view.window.safeAreaInsets.top, self.view.window.bounds.size.width, 44);
	self.banner.hidden = NO;
	[self scenario];
}

/* the moving tiles every scenario has under it: a grid of coloured, labelled tiles going up and down for ever */
- (CALayer *)tilesIn:(CGRect)bounds
{
	CALayer *world = [CALayer layer];
	CGFloat side = bounds.size.width / 4;
	NSArray *colors = @[ UIColor.systemRedColor, UIColor.systemOrangeColor, UIColor.systemYellowColor,
		UIColor.systemGreenColor, UIColor.systemTealColor, UIColor.systemBlueColor, UIColor.systemPurpleColor,
		UIColor.systemPinkColor ];

	world.frame = CGRectMake(0, 0, bounds.size.width, bounds.size.height * 2);
	for (int i = 0; i < 4 * (int)(world.frame.size.height / side); i++) {
		CALayer *t = [CALayer layer];
		CATextLayer *n = [CATextLayer layer];

		t.frame = CGRectMake((i % 4) * side + 4, (i / 4) * side + 4, side - 8, side - 8);
		t.cornerRadius = 14;
		t.backgroundColor = [colors[(NSUInteger)(i * 3 + i / 4) % colors.count] CGColor];
		n.string = [NSString stringWithFormat:@"%d", i];
		n.fontSize = 28;
		n.alignmentMode = kCAAlignmentCenter;
		n.foregroundColor = UIColor.whiteColor.CGColor;
		n.contentsScale = UIScreen.mainScreen.scale;
		n.frame = CGRectMake(0, t.bounds.size.height / 2 - 18, t.bounds.size.width, 36);
		[t addSublayer:n];
		[world addSublayer:t];
	}
	CABasicAnimation *move = [CABasicAnimation animationWithKeyPath:@"position.y"];

	move.fromValue = @(world.position.y);
	move.toValue = @(world.position.y - bounds.size.height * 0.8);
	move.duration = 2.0;
	move.autoreverses = YES;
	move.repeatCount = HUGE_VALF;
	move.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
	[world addAnimation:move forKey:@"move"];
	return world;
}

- (void)springSheetOn:(CALayer *)stage page:(CALayer *)page glass:(BOOL)withGlass
{
	CGRect b = stage.bounds;
	CALayer *sheet = [CALayer layer];

	sheet.frame = CGRectMake(0, b.size.height * 0.35, b.size.width, b.size.height * 0.65 + 40);
	sheet.backgroundColor = [UIColor colorWithWhite:0.97 alpha:1].CGColor;
	sheet.cornerRadius = 24;
	if (withGlass) {
		[sheet addSublayer:glass(CGRectMake(16, 16, b.size.width - 32, 56), blur(6), 1.0)];
		[sheet addSublayer:glass(CGRectMake(b.size.width / 2 - 70, sheet.bounds.size.height - 150, 140, 52),
		    tint_blur(2), 1.0)];
	}
	[stage addSublayer:sheet];
	CASpringAnimation *up = [CASpringAnimation animationWithKeyPath:@"position.y"];

	up.fromValue = @(sheet.position.y + sheet.bounds.size.height);
	up.toValue = @(sheet.position.y);
	up.mass = 1, up.stiffness = 900, up.damping = 60;
	up.duration = 1.0;
	up.autoreverses = YES;
	up.repeatCount = HUGE_VALF;
	[sheet addAnimation:up forKey:@"spring"];
	CASpringAnimation *shrink = [CASpringAnimation animationWithKeyPath:@"transform.scale"];

	shrink.fromValue = @1.0;
	shrink.toValue = @0.92;
	shrink.mass = 1, shrink.stiffness = 900, shrink.damping = 60;
	shrink.duration = 1.0;
	shrink.autoreverses = YES;
	shrink.repeatCount = HUGE_VALF;
	[page addAnimation:shrink forKey:@"spring"];
}

- (void)thumbnailsOn:(CALayer *)stage
{
	CGRect b = stage.bounds;
	CGFloat side = b.size.width / 4;
	CALayer *grid = [CALayer layer];
	UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];

	fmt.scale = 1;
	grid.frame = CGRectMake(0, 0, b.size.width, side * 30);
	grid.backgroundColor = UIColor.blackColor.CGColor;
	for (int i = 0; i < 120; i++) {
		UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(256, 256) format:fmt];
		UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
			CGFloat hue = (CGFloat)(i % 24) / 24;

			[[UIColor colorWithHue:hue saturation:0.6 brightness:0.9 alpha:1] setFill];
			UIRectFill(CGRectMake(0, 0, 256, 256));
			[[UIColor colorWithHue:fmod(hue + 0.5, 1) saturation:0.8 brightness:0.6 alpha:1] setFill];
			[[UIBezierPath bezierPathWithOvalInRect:CGRectMake(40 + i % 50, 60, 160, 120)] fill];
			[[NSString stringWithFormat:@"IMG %d", i] drawAtPoint:CGPointMake(16, 210)
			    withAttributes:@{ NSFontAttributeName: [UIFont boldSystemFontOfSize:28],
				NSForegroundColorAttributeName: UIColor.whiteColor }];
		}];
		CALayer *t = [CALayer layer];

		t.frame = CGRectMake((i % 4) * side + 1, (i / 4) * side + 1, side - 2, side - 2);
		t.contents = (__bridge id)img.CGImage;
		t.contentsGravity = kCAGravityResizeAspectFill;
		t.masksToBounds = YES;
		[grid addSublayer:t];
	}
	[stage addSublayer:grid];
	CABasicAnimation *scroll = [CABasicAnimation animationWithKeyPath:@"position.y"];

	scroll.fromValue = @(grid.position.y);
	scroll.toValue = @(grid.position.y - (grid.bounds.size.height - b.size.height));
	scroll.duration = 4.0;
	scroll.autoreverses = YES;
	scroll.repeatCount = HUGE_VALF;
	[grid addAnimation:scroll forKey:@"scroll"];
}

/* the library's newest photos (up to 120, again from the first when fewer) as a 4-column grid, scrolling */
- (void)photoGridOn:(CALayer *)page
{
	CGRect b = page.bounds;
	CGFloat side = b.size.width / 4, px = side * UIScreen.mainScreen.scale;
	CALayer *grid = [CALayer layer];
	PHFetchOptions *fo = [PHFetchOptions new];
	PHImageRequestOptions *ro = [PHImageRequestOptions new];
	PHFetchResult<PHAsset *> *assets;
	NSUInteger n;

	fo.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"creationDate" ascending:NO] ];
	assets = [PHAsset fetchAssetsWithMediaType:PHAssetMediaTypeImage options:fo];
	n = assets.count;
	effects_log([NSString stringWithFormat:@"photo-grid: %lu photos in the library (access %ld)", (unsigned long)n,
	    (long)[PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelReadWrite]]);
	ro.deliveryMode = PHImageRequestOptionsDeliveryModeOpportunistic;
	ro.resizeMode = PHImageRequestOptionsResizeModeFast;
	self.imageManager = [PHCachingImageManager new];
	grid.frame = CGRectMake(0, 0, b.size.width, side * 30);
	grid.backgroundColor = UIColor.blackColor.CGColor;
	for (NSUInteger i = 0; i < 120; i++) {
		CALayer *t = [CALayer layer];

		t.frame = CGRectMake((i % 4) * side + 1, (i / 4) * side + 1, side - 2, side - 2);
		t.backgroundColor = UIColor.darkGrayColor.CGColor;
		t.contentsGravity = kCAGravityResizeAspectFill;
		t.masksToBounds = YES;
		[grid addSublayer:t];
		if (n > 0) {
			[self.imageManager requestImageForAsset:assets[i % n] targetSize:CGSizeMake(px, px)
			    contentMode:PHImageContentModeAspectFill options:ro resultHandler:^(UIImage *img, NSDictionary *info) {
				dispatch_async(dispatch_get_main_queue(), ^{
					t.contents = (__bridge id)img.CGImage;
				});
			}];
		}
	}
	[page addSublayer:grid];
	CABasicAnimation *scroll = [CABasicAnimation animationWithKeyPath:@"position.y"];

	scroll.fromValue = @(grid.position.y);
	scroll.toValue = @(grid.position.y - (grid.bounds.size.height - b.size.height));
	scroll.duration = 4.0;
	scroll.autoreverses = YES;
	scroll.repeatCount = HUGE_VALF;
	[grid addAnimation:scroll forKey:@"scroll"];
}

/* a live preview of the back camera in FRAME (a photo picker's camera cell); NO when there is no camera to use */
- (BOOL)cameraOn:(CALayer *)stage frame:(CGRect)frame
{
	AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
	NSError *error = nil;
	AVCaptureDeviceInput *input = device ? [AVCaptureDeviceInput deviceInputWithDevice:device error:&error] : nil;

	if (input == nil) {
		effects_log([NSString stringWithFormat:@"camera: none to use (access %ld): %@",
		    (long)[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo], error.localizedDescription ?: @""]);
		return NO;
	}
	AVCaptureSession *session = [AVCaptureSession new];

	if ([session canAddInput:input]) {
		[session addInput:input];
	}
	AVCaptureVideoPreviewLayer *preview = [AVCaptureVideoPreviewLayer layerWithSession:session];

	preview.frame = frame;
	preview.videoGravity = AVLayerVideoGravityResizeAspectFill;
	preview.cornerRadius = 10;
	preview.masksToBounds = YES;
	[stage addSublayer:preview];
	self.capture = session;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		[session startRunning];
		effects_log([NSString stringWithFormat:@"camera: running %@", session.running ? @"yes" : @"NO"]);
	});
	return YES;
}

- (BOOL)metalOn:(CALayer *)stage
{
	NSError *error = nil;

	if (self.device == nil) {
		self.device = MTLCreateSystemDefaultDevice();
		if (self.device == nil) {
			return NO;
		}
		id<MTLLibrary> lib = [self.device newLibraryWithSource:kGlassShader options:nil error:&error];
		MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];

		if (lib == nil) {
			effects_log([NSString stringWithFormat:@"metal-glass: the shader did not build: %@", error.localizedDescription]);
			self.device = nil;
			return NO;
		}
		pd.vertexFunction = [lib newFunctionWithName:@"glass_vs"];
		pd.fragmentFunction = [lib newFunctionWithName:@"glass_fs"];
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
		self.pipeline = [self.device newRenderPipelineStateWithDescriptor:pd error:&error];
		self.queue = [self.device newCommandQueue];
		if (self.pipeline == nil || self.queue == nil) {
			effects_log([NSString stringWithFormat:@"metal-glass: no pipeline: %@", error.localizedDescription]);
			self.device = nil;
			return NO;
		}
	}
	self.metalLayer = [CAMetalLayer layer];
	self.metalLayer.device = self.device;
	self.metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
	self.metalLayer.frame = stage.bounds;
	self.metalLayer.contentsScale = UIScreen.mainScreen.scale;
	self.metalLayer.drawableSize = CGSizeMake(stage.bounds.size.width * UIScreen.mainScreen.scale,
	    stage.bounds.size.height * UIScreen.mainScreen.scale);
	[stage addSublayer:self.metalLayer];
	self.metalStart = CACurrentMediaTime();
	return YES;
}

- (void)drawMetal
{
	id<CAMetalDrawable> drawable = [self.metalLayer nextDrawable];

	if (drawable == nil) {
		return;
	}
	static const float pts[6] = { -1, -1, 3, -1, -1, 3 };
	float t = (float)(CACurrentMediaTime() - self.metalStart);
	MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
	id<MTLCommandBuffer> cb = [self.queue commandBuffer];

	rp.colorAttachments[0].texture = drawable.texture;
	rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
	rp.colorAttachments[0].storeAction = MTLStoreActionStore;
	id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];

	[enc setRenderPipelineState:self.pipeline];
	[enc setVertexBytes:pts length:sizeof(pts) atIndex:0];
	[enc setFragmentBytes:&t length:sizeof(t) atIndex:0];
	[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	[enc endEncoding];
	[cb presentDrawable:drawable];
	[cb commit];
}

/* scenario self.next: set up, 1 s to settle, 8 s measured, then the next */
- (void)scenario
{
	if (self.next >= SCENARIOS) {
		[self finish];
		return;
	}
	const struct scenario *s = &scenarios[self.next];
	CGRect b = self.view.window.bounds;
	CALayer *stage = [CALayer layer], *page;
	BOOL ok = YES;

	self.banner.text = [NSString stringWithFormat:@"%lu/%lu %s\n%s", (unsigned long)self.next + 1,
	    (unsigned long)SCENARIOS, s->name, s->what];
	stage.frame = b;
	stage.backgroundColor = UIColor.blackColor.CGColor;
	page = [CALayer layer];
	page.frame = b;
	[stage addSublayer:page];
	if (strcmp(s->name, "thumbnails") != 0 && strcmp(s->name, "metal-glass") != 0 && strncmp(s->name, "photo-grid", 10) != 0) {
		[page addSublayer:[self tilesIn:b]];
	}
	/* (the stage in the window first: a view added for the scenario -- the visual effect -- goes above it) */
	self.stage = stage;
	[self.view.window.layer insertSublayer:stage below:self.banner.layer];
	CGRect panel = CGRectMake(24, b.size.height * 0.62, b.size.width - 48, 72);

	if (strcmp(s->name, "visualeffect") == 0) {
		UIVisualEffectView *v = [[UIVisualEffectView alloc] initWithEffect:
		    [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];

		v.frame = CGRectMake(24, b.size.height * 0.55, b.size.width - 48, b.size.height * 0.3);
		v.layer.cornerRadius = 28;
		v.clipsToBounds = YES;
		v.tag = 4242;
		[self.view.window insertSubview:v belowSubview:self.banner];
	} else if (strcmp(s->name, "backdrop-blur2") == 0) {
		[stage addSublayer:glass(panel, blur(2), 1.0)];
	} else if (strcmp(s->name, "backdrop-blur6") == 0) {
		[stage addSublayer:glass(panel, blur(6), 1.0)];
	} else if (strcmp(s->name, "backdrop-blur20") == 0) {
		[stage addSublayer:glass(panel, blur(20), 1.0)];
	} else if (strcmp(s->name, "backdrop-blur6-quarter") == 0) {
		[stage addSublayer:glass(panel, blur(6), 0.25)];
	} else if (strcmp(s->name, "backdrop-matrix-blur2") == 0) {
		[stage addSublayer:glass(panel, tint_blur(2), 1.0)];
	} else if (strcmp(s->name, "variableblur") == 0) {
		CGSize ms = CGSizeMake(8, 256);
		UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:ms];
		UIImage *mask = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
			CGFloat comps[8] = { 0, 0, 0, 1, 0, 0, 0, 0 };
			CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
			CGGradientRef g = CGGradientCreateWithColorComponents(cs, comps, NULL, 2);

			CGContextDrawLinearGradient(ctx.CGContext, g, CGPointZero, CGPointMake(0, ms.height), 0);
			CGGradientRelease(g);
			CGColorSpaceRelease(cs);
		}];
		CALayer *edge = backdrop(@[ filter(@"variableBlur", @{ @"inputRadius": @10.0,
			@"inputMaskImage": (__bridge id)mask.CGImage, @"inputNormalizeEdges": @YES }) ], 1.0);

		edge.frame = CGRectMake(0, 0, b.size.width, b.size.height * 0.25);
		[stage addSublayer:edge];
	} else if (strcmp(s->name, "glass-x4") == 0 || strcmp(s->name, "glass-x8") == 0) {
		int n = s->name[7] == '4' ? 4 : 8;

		for (int i = 0; i < n; i++) {
			CGFloat w = (b.size.width - 40) / 2;

			[stage addSublayer:glass(CGRectMake(16 + (i % 2) * (w + 8), b.size.height * 0.2 + (i / 2) * 120, w, 64),
			    blur(6), 1.0)];
		}
	} else if (strcmp(s->name, "spring-sheet") == 0) {
		[self springSheetOn:stage page:page glass:NO];
	} else if (strcmp(s->name, "spring-sheet-glass") == 0) {
		[self springSheetOn:stage page:page glass:YES];
	} else if (strcmp(s->name, "thumbnails") == 0) {
		[self thumbnailsOn:page];
	} else if (strcmp(s->name, "photo-grid") == 0) {
		[self photoGridOn:page];
	} else if (strcmp(s->name, "camera-tile") == 0) {
		ok = [self cameraOn:stage frame:CGRectMake(24, b.size.height * 0.55, b.size.width * 0.5, b.size.width * 0.5)];
	} else if (strcmp(s->name, "photo-grid-camera") == 0) {
		[self photoGridOn:page];
		ok = [self cameraOn:stage frame:CGRectMake(1, b.size.height * 0.3, b.size.width / 4 - 2, b.size.width / 4 - 2)];
	} else if (strcmp(s->name, "metal-glass") == 0) {
		ok = [self metalOn:stage];
	}
	if (!ok) {
		[self.report appendFormat:@"%-24s not run (no Metal device or shader)\n", s->name];
		effects_log([NSString stringWithFormat:@"%s: NOT RUN", s->name]);
		[self teardown];
		self.next++;
		[self scenario];
		return;
	}
	effects_log([NSString stringWithFormat:@"%s: begin (%s)", s->name, s->what]);
	self.stamps = [NSMutableArray array];
	self.measuring = NO;
	self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
	if (@available(iOS 15.0, *)) {
		self.link.preferredFrameRateRange = CAFrameRateRangeMake(60, 120, 120);
	}
	[self.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		self.measuring = YES;
	});
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		[self endScenario];
	});
}

- (void)tick:(CADisplayLink *)link
{
	if (self.metalLayer != nil) {
		[self drawMetal];
	}
	if (self.measuring) {
		[self.stamps addObject:@(link.timestamp)];
	}
}

- (void)endScenario
{
	const struct scenario *s = &scenarios[self.next];
	NSUInteger n = self.stamps.count, late = 0;
	double worst = 0, span = n > 1 ? self.stamps.lastObject.doubleValue - self.stamps.firstObject.doubleValue : 0;
	double budget = 1.0 / MAX(60, UIScreen.mainScreen.maximumFramesPerSecond);

	[self.link invalidate];
	self.link = nil;
	for (NSUInteger i = 1; i < n; i++) {
		double d = self.stamps[i].doubleValue - self.stamps[i - 1].doubleValue;

		worst = MAX(worst, d);
		late += d > budget * 1.5;
	}
	double fps = span > 0 ? (n - 1) / span : 0;
	NSString *line = [NSString stringWithFormat:@"%-24s %5.1f fps, %3.0f%% late, worst %4.0f ms", s->name, fps,
	    n > 1 ? 100.0 * late / (n - 1) : 0, worst * 1000];

	[self.report appendFormat:@"%@\n", line];
	effects_log([NSString stringWithFormat:@"%s: end: %@", s->name, line]);
	[self teardown];
	self.next++;
	[self scenario];
}

- (void)teardown
{
	[[self.view.window viewWithTag:4242] removeFromSuperview];
	[self.capture stopRunning];
	self.capture = nil;
	self.imageManager = nil;
	[self.stage removeFromSuperlayer];
	self.stage = nil;
	self.metalLayer = nil;
}

- (void)finish
{
	effects_log(@"DONE");
	self.running = NO;
	self.banner.hidden = YES;
	[self.banner removeFromSuperview];
	self.navigationController.navigationBarHidden = NO;
	self.tabBarController.tabBar.hidden = NO;
	self.results.hidden = NO;
	self.results.text = [NSString stringWithFormat:@"%@\nThe compositor's own frame count is in the port's kernel log "
	    "(the framebuffer's five-second lines), read against the times in Documents/effectscheck.log.", self.report];
}

@end
