/*
 * metaltest.dylib: the Metal bring-up test (tools/d2s-metal/PLAN.md).
 *
 * Inserted into a short-lived system process with d2senv (not backboardd,
 * so the UI keeps working while Metal is incomplete). Its constructor sets
 * D2SMETAL=1, so D2SMetal.bundle registers the device in this process only,
 * then walks the path CoreAnimation's own Metal renderer takes, step by
 * step, and writes each result to the kernel log ("metaltest: ..."):
 *
 *   1 device       MTLCreateSystemDefaultDevice
 *   2 queue        newCommandQueue
 *   3 buffer       newBufferWithLength, write and read back
 *   4 texture      newTextureWithDescriptor, replaceRegion and getBytes
 *   5 CARenderer   +[CARenderer rendererWithMTLTexture:options:], one red
 *                  layer, beginFrame/render/endFrame, read the pixel back:
 *                  the CoreAnimation Metal renderer the UI uses
 *
 * A failing step stops the test; a crash shows as a CRASH line for this
 * process and costs nothing else.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include "d2sgpu.h"

static io_connect_t conn = MACH_PORT_NULL;

static void
say(const char *fmt, ...)
{
	char line[150];
	int n = snprintf(line, sizeof(line), "metaltest: ");
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(line + n, sizeof(line) - (size_t)n, fmt, ap);
	va_end(ap);
	if (conn == MACH_PORT_NULL) {
		conn = d2sgpu_open();
	}
	if (conn != MACH_PORT_NULL) {
		d2sgpu_log(conn, line, strlen(line));
	}
}

static void
run(void)
{
	say("start in %s", getprogname());
	id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
	if (dev == nil) {
		say("1 device: FAIL (nil)");
		return;
	}
	say("1 device: ok, %s", [[dev name] UTF8String]);

	id<MTLCommandQueue> q = [dev newCommandQueue];
	if (q == nil) {
		say("2 queue: FAIL (nil)");
		return;
	}
	say("2 queue: ok, %s", class_getName([(id)q class]));

	id<MTLBuffer> b = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
	if (b == nil || [b contents] == NULL) {
		say("3 buffer: FAIL (%p)", b);
		return;
	}
	uint32_t *w = [b contents];
	for (int i = 0; i < 1024; i++) {
		w[i] = 0x9e3779b9u * (uint32_t)i;
	}
	int bad = 0;
	for (int i = 0; i < 1024; i++) {
		bad += w[i] != 0x9e3779b9u * (uint32_t)i;
	}
	say("3 buffer: %s, length %lu, %d bad words", bad ? "FAIL" : "ok", (unsigned long)[b length], bad);

	MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
		width:64 height:64 mipmapped:NO];
	td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	td.storageMode = MTLStorageModeShared;
	id<MTLTexture> t = [dev newTextureWithDescriptor:td];
	if (t == nil) {
		say("4 texture: FAIL (nil)");
		return;
	}
	uint32_t px[64 * 64];
	for (int i = 0; i < 64 * 64; i++) {
		px[i] = 0xff000000u | (uint32_t)i;
	}
	[t replaceRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0 withBytes:px bytesPerRow:256];
	uint32_t back[64 * 64];
	memset(back, 0, sizeof(back));
	[t getBytes:back bytesPerRow:256 fromRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0];
	bad = 0;
	for (int i = 0; i < 64 * 64; i++) {
		bad += back[i] != px[i];
	}
	say("4 texture: %s, %lux%lu, %d bad pixels", bad ? "FAIL" : "ok", (unsigned long)[t width],
	    (unsigned long)[t height], bad);

	/* clear the texture to black, then let CoreAnimation draw a red layer into it */
	memset(px, 0, sizeof(px));
	[t replaceRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0 withBytes:px bytesPerRow:256];
	say("5 CARenderer: making the renderer");
	CARenderer *r = [CARenderer rendererWithMTLTexture:t options:@{ kCARendererMetalCommandQueue: q }];
	if (r == nil) {
		say("5 CARenderer: FAIL (rendererWithMTLTexture nil)");
		return;
	}
	CALayer *l = [CALayer layer];
	l.frame = CGRectMake(0, 0, 64, 64);
	CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
	const CGFloat red[4] = { 1, 0, 0, 1 };
	CGColorRef c = CGColorCreate(cs, red);
	l.backgroundColor = c;
	r.layer = l;
	r.bounds = CGRectMake(0, 0, 64, 64);
	[CATransaction flush];
	say("5 CARenderer: renderer and layer made, rendering frames");
	for (int f = 0; f < 4; f++) {
		CFTimeInterval now = CACurrentMediaTime();
		CFTimeInterval next = [r nextFrameTime];
		say("5 CARenderer: frame %d: nextFrameTime %.3f (now %.3f)", f, next, now);
		[r beginFrameAtTime:now timeStamp:NULL];
		[r addUpdateRect:r.bounds];
		[r render];
		[r endFrame];
		[CATransaction flush];
		usleep(20000);
	}
	say("5 CARenderer: frame submitted, reading back");
	memset(back, 0, sizeof(back));
	[t getBytes:back bytesPerRow:256 fromRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0];
	int redpx = 0;
	for (int i = 0; i < 64 * 64; i++) {
		uint8_t *p = (uint8_t *)&back[i];	/* B G R A */
		redpx += p[0] < 8 && p[1] < 8 && p[2] > 247;
	}
	say("5 CARenderer: %s, %d/4096 red pixels, first %#x mid %#x", redpx == 4096 ? "OK" : "FAIL", redpx, back[0],
	    back[32 * 64 + 32]);
	CGColorRelease(c);
	CGColorSpaceRelease(cs);
}

__attribute__((constructor)) static void
metaltestLoad(void)
{
	setenv("D2SMETAL", "1", 1);
	@autoreleasepool {
		@try {
			run();
		} @catch (NSException *e) {
			say("exception %s: %s", [[e name] UTF8String], [[e reason] UTF8String]);
		}
	}
	say("done");
}
