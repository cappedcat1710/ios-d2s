/*
 * D2SMetal: the Metal plug-in for the Galaxy Note 10+ (d2s), Mali-G76.
 *
 * Metal finds the IOKit service of class IOAcceleratorES (kernel patch 0138),
 * reads its MetalPluginName / MetalPluginClassName (boot-arg metal=1), opens
 * /System/Library/Extensions/D2SMetal.bundle, takes the class
 * D2SMetalDevice, requires it to be a subclass of Metal's private
 * _MTLDevice, and sends it -initWithAcceleratorPort:. That object is the
 * process's one MTLDevice.
 *
 * Staged bring-up (tools/d2s-metal/PLAN.md). CoreAnimation commits to Metal
 * as soon as a device exists and has no fallback if the device then fails,
 * so the device is only registered in processes started with D2SMETAL=1:
 * the test program (metaltest.c) sets it, and backboardd gets it with
 * d2senv=backboardd:D2SMETAL=1 once the test draws. Every other process sees
 * no Metal device and keeps the renderer it has today.
 *
 * Done so far: the device and its limits, command queues (Metal's own
 * _MTLCommandQueue), buffers in GPU memory (D2SGPU buffers, mapped into the
 * process), linear 2D textures in GPU memory with replaceRegion/getBytes.
 * Everything else is logged once ("asked and not implemented: -selector")
 * and answered with zero: that log is the work list.
 *
 * Built without ARC (objects made here follow Metal's own retain rules).
 * The approach (private-base subclasses built at load time, a logged zero
 * stub for the rest) follows hakios' HakiosMetal.m (MIT); rewritten here.
 */
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <mach/mach.h>
#include "d2sgpu.h"

static Class gBase;			/* _MTLDevice */
static id gDevice;
static unsigned int gPort;
static io_connect_t gConn = MACH_PORT_NULL;
static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
static NSMutableSet *gSeen;
static Class gQueueClass, gBufferClass, gTextureClass;

#define MAX_PROTOCOLS 24
static Protocol *gProtocols[MAX_PROTOCOLS];
static int gNProtocols;

static io_connect_t
gpu(void)
{
	pthread_mutex_lock(&gLock);
	if (gConn == MACH_PORT_NULL) {
		gConn = d2sgpu_open();
	}
	pthread_mutex_unlock(&gLock);
	return gConn;
}

static void
sayc(const char *fmt, ...)
{
	char line[150];
	int n = snprintf(line, sizeof(line), "D2SMetal: ");
	va_list ap;
	va_start(ap, fmt);
	int m = vsnprintf(line + n, sizeof(line) - (size_t)n, fmt, ap);
	va_end(ap);
	if (m < 0) {
		return;
	}
	size_t len = strlen(line);
	io_connect_t c = gpu();
	if (c != MACH_PORT_NULL) {
		d2sgpu_log(c, line, len);
	}
}

static void
say(NSString *text)
{
	sayc("%s", [text UTF8String]);
}

/* ---- the logged zero stub, shared by every class made here ---------- */

static void
addProtocolFamily(const char *prefix)
{
	unsigned int n = 0;
	Protocol **all = (Protocol **)objc_copyProtocolList(&n);
	size_t pl = strlen(prefix);
	for (unsigned int i = 0; i < n && gNProtocols < MAX_PROTOCOLS; i++) {
		const char *name = protocol_getName(all[i]);
		if (strncmp(name, prefix, pl) == 0) {
			gProtocols[gNProtocols++] = all[i];
		}
	}
	free(all);
}

static id
stubSignature(id self, SEL _cmd, SEL selector)
{
	(void)_cmd;
	for (int i = 0; i < gNProtocols; i++) {
		for (int required = 1; required >= 0; required--) {
			struct objc_method_description d = protocol_getMethodDescription(gProtocols[i], selector, required, YES);
			if (d.name != NULL && d.types != NULL) {
				return [NSMethodSignature signatureWithObjCTypes:d.types];
			}
		}
	}
	struct objc_super sup = { self, class_getSuperclass(object_getClass(self)) };
	id (*send)(struct objc_super *, SEL, SEL) = (id (*)(struct objc_super *, SEL, SEL))objc_msgSendSuper;
	id sig = send(&sup, @selector(methodSignatureForSelector:), selector);
	if (sig == nil) {
		sayc("no signature for -%s on %s: Metal will raise", sel_getName(selector), class_getName(object_getClass(self)));
	}
	return sig;
}

static void
stubForward(id self, SEL _cmd, NSInvocation *inv)
{
	(void)_cmd;
	NSMethodSignature *sig = [inv methodSignature];
	NSUInteger length = [sig methodReturnLength];
	char key[200];
	snprintf(key, sizeof(key), "%s -%s", class_getName(object_getClass(self)), sel_getName([inv selector]));
	NSString *k = [NSString stringWithUTF8String:key];
	@synchronized(gBase) {
		if (gSeen == nil) {
			gSeen = [NSMutableSet new];
		}
		if (![gSeen containsObject:k]) {
			[gSeen addObject:k];
			sayc("asked and not implemented: %s (returns %s)", key, [sig methodReturnType]);
		}
	}
	if (length != 0) {
		void *zero = calloc(1, length);
		[inv setReturnValue:zero];
		free(zero);
	}
}

/* every object made here: one pointer of our own state */
static ptrdiff_t gStateOffset[4];
enum { K_QUEUE, K_BUFFER, K_TEXTURE };

static void **
stateOf(id obj, int kind)
{
	return (void **)((char *)obj + gStateOffset[kind]);
}

static Class
makeClass(const char *name, const char *base, const char *const *protocols, int kind)
{
	Class super = objc_getClass(base);
	if (super == Nil) {
		sayc("no %s on this system, %s not made", base, name);
		return Nil;
	}
	Class cls = objc_allocateClassPair(super, name, 0);
	if (cls == Nil) {
		return Nil;
	}
	class_addIvar(cls, "_d2s", sizeof(void *), 3, "^v");
	for (int i = 0; protocols != NULL && protocols[i] != NULL; i++) {
		Protocol *p = objc_getProtocol(protocols[i]);
		if (p != NULL) {
			class_addProtocol(cls, p);
		}
	}
	class_addMethod(cls, @selector(methodSignatureForSelector:), (IMP)stubSignature, "@@::");
	class_addMethod(cls, @selector(forwardInvocation:), (IMP)stubForward, "v@:@");
	return cls;
}

static void
finishClass(Class cls, int kind)
{
	objc_registerClassPair(cls);
	gStateOffset[kind] = ivar_getOffset(class_getInstanceVariable(cls, "_d2s"));
}

/* ---- shared small methods ------------------------------------------- */

struct common {
	id label;
};

static id
objDevice(id self, SEL _cmd)
{
	(void)self; (void)_cmd;
	return gDevice;
}

/* ---- buffers: D2SGPU memory, mapped into this process -------------- */

struct buffer {
	struct common c;
	struct d2sgpu_buf b;
	uint64_t length;
	uint64_t options;
	void *plain;			/* when there is no GPU memory */
};

static id
bufferMake(uint64_t length, uint64_t options, const void *bytes)
{
	if (length == 0 || length > (256ull << 20)) {
		sayc("newBuffer length %llu: refused", (unsigned long long)length);
		return nil;
	}
	struct buffer *s = calloc(1, sizeof(*s));
	s->length = length;
	s->options = options;
	io_connect_t c = gpu();
	if (c == MACH_PORT_NULL ||
	    d2sgpu_buf_create(c, (length + 4095) & ~4095ull, D2SGPU_BUF_GPU_WRITE, &s->b) != KERN_SUCCESS ||
	    s->b.cpu == NULL) {
		sayc("newBuffer length %llu: no GPU memory, plain memory instead", (unsigned long long)length);
		memset(&s->b, 0, sizeof(s->b));
		s->plain = calloc(1, length);
	}
	if (bytes != NULL) {
		memcpy(s->plain ? s->plain : s->b.cpu, bytes, length);
	}
	id obj = class_createInstance(gBufferClass, 0);
	obj = ((id (*)(id, SEL))objc_msgSend)(obj, @selector(init));
	*stateOf(obj, K_BUFFER) = s;
	return obj;
}

static struct buffer *
buf(id self)
{
	return (struct buffer *)*stateOf(self, K_BUFFER);
}

static void *
bufferContents(id self, SEL _cmd)
{
	(void)_cmd;
	struct buffer *s = buf(self);
	return s->plain ? s->plain : s->b.cpu;
}

static uint64_t
bufferLength(id self, SEL _cmd)
{
	(void)_cmd;
	return buf(self)->length;
}

static uint64_t
bufferGPUAddress(id self, SEL _cmd)
{
	(void)_cmd;
	return buf(self)->b.gpu_va;
}

static uint64_t
bufferOptions(id self, SEL _cmd)
{
	(void)_cmd;
	return buf(self)->options;
}

static uint64_t
bufferStorageMode(id self, SEL _cmd)
{
	(void)_cmd;
	return (buf(self)->options >> 4) & 0xf;	/* MTLResourceStorageModeShift */
}

static uint64_t
bufferCacheMode(id self, SEL _cmd)
{
	(void)_cmd;
	return buf(self)->options & 0xf;
}

static void
nothingRange(id self, SEL _cmd, NSRange r)
{
	(void)self; (void)_cmd; (void)r;
}

static id
labelGet(id self, SEL _cmd)
{
	(void)_cmd;
	Class c = object_getClass(self);
	int kind = c == gQueueClass ? K_QUEUE : c == gBufferClass ? K_BUFFER : K_TEXTURE;
	struct common *s = *stateOf(self, kind);
	return s ? s->label : nil;
}

static void
labelSet(id self, SEL _cmd, id label)
{
	(void)_cmd;
	Class c = object_getClass(self);
	int kind = c == gBufferClass ? K_BUFFER : K_TEXTURE;
	struct common *s = *stateOf(self, kind);
	if (s != NULL) {
		id old = s->label;
		s->label = [label copy];
		[old release];
	}
}

static void
bufferDealloc(id self, SEL _cmd)
{
	(void)_cmd;
	struct buffer *s = buf(self);
	if (s != NULL) {
		if (s->b.handle != 0 && gConn != MACH_PORT_NULL) {
			d2sgpu_buf_destroy(gConn, &s->b);
		}
		free(s->plain);
		[s->c.label release];
		free(s);
	}
	struct objc_super sup = { self, class_getSuperclass(gBufferClass) };
	((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, @selector(dealloc));
}

/* ---- textures: one linear 2D image in GPU memory --------------------- */

struct texture {
	struct common c;
	struct d2sgpu_buf b;
	void *plain;
	uint64_t width, height, depth, pixelFormat, type, usage, storage, mips, samples, arrayLength;
	uint64_t bpp, rowBytes;
};

static uint64_t
bytesPerPixel(uint64_t fmt)
{
	switch (fmt) {
	case 10: case 11: case 12: case 13: case 14:		/* R8 */
	case 1:							/* A8 */
		return 1;
	case 20: case 22: case 23: case 24: case 25:		/* R16 */
	case 30: case 32: case 33: case 34:			/* RG8 */
		return 2;
	case 70: case 71: case 72: case 73: case 74:		/* RGBA8 */
	case 80: case 81:					/* BGRA8 */
	case 90: case 91: case 92: case 93: case 94:		/* RGB10A2, RG11B10, RGB9E5 */
	case 53: case 54: case 55:				/* R32 */
	case 60: case 62: case 63: case 64: case 65:		/* RG16 */
	case 252: case 253:					/* Depth32 / Stencil8? sizes: 4 */
		return 4;
	case 110: case 112: case 113: case 114: case 115:	/* RGBA16 */
	case 103: case 104: case 105:				/* RG32 */
		return 8;
	case 123: case 124: case 125:				/* RGBA32 */
		return 16;
	default:
		return 4;
	}
}

static struct texture *
tex(id self)
{
	return (struct texture *)*stateOf(self, K_TEXTURE);
}

#define DESC(obj, name) (((uint64_t (*)(id, SEL))objc_msgSend)(obj, @selector(name)))

static id
deviceNewTexture(id self, SEL _cmd, id desc)
{
	(void)self; (void)_cmd;
	struct texture *t = calloc(1, sizeof(*t));
	t->width = DESC(desc, width);
	t->height = DESC(desc, height);
	t->depth = DESC(desc, depth);
	t->pixelFormat = DESC(desc, pixelFormat);
	t->type = DESC(desc, textureType);
	t->usage = DESC(desc, usage);
	t->storage = DESC(desc, storageMode);
	t->mips = DESC(desc, mipmapLevelCount);
	t->samples = DESC(desc, sampleCount);
	t->arrayLength = DESC(desc, arrayLength);
	t->bpp = bytesPerPixel(t->pixelFormat);
	t->rowBytes = (t->width * t->bpp + 63) & ~63ull;
	uint64_t layers = (t->depth ? t->depth : 1) * (t->arrayLength ? t->arrayLength : 1) * (t->type == 5 ? 6 : 1);
	uint64_t size = t->rowBytes * (t->height ? t->height : 1) * layers;
	size = size * 2;	/* room for mip levels (crude) */
	io_connect_t c = gpu();
	if (c == MACH_PORT_NULL || d2sgpu_buf_create(c, (size + 4095) & ~4095ull, D2SGPU_BUF_GPU_WRITE, &t->b) != KERN_SUCCESS ||
	    t->b.cpu == NULL) {
		memset(&t->b, 0, sizeof(t->b));
		t->plain = calloc(1, size);
	}
	static int logged;
	if (logged++ < 12) {
		sayc("newTexture %llux%llu fmt %llu type %llu usage %#llx storage %llu mips %llu samples %llu",
		    t->width, t->height, t->pixelFormat, t->type, t->usage, t->storage, t->mips, t->samples);
	}
	id obj = class_createInstance(gTextureClass, 0);
	obj = ((id (*)(id, SEL))objc_msgSend)(obj, @selector(init));
	*stateOf(obj, K_TEXTURE) = t;
	return obj;
}

#define TEXGET(field) \
	static uint64_t tex_##field(id self, SEL _cmd) { (void)_cmd; return tex(self)->field; }
TEXGET(width)
TEXGET(height)
TEXGET(pixelFormat)
TEXGET(usage)
TEXGET(storage)
TEXGET(samples)
TEXGET(rowBytes)
static uint64_t tex_type(id self, SEL _cmd) { (void)_cmd; return tex(self)->type; }
static uint64_t tex_depth(id self, SEL _cmd) { (void)_cmd; return tex(self)->depth ? tex(self)->depth : 1; }
static uint64_t tex_mips(id self, SEL _cmd) { (void)_cmd; return tex(self)->mips ? tex(self)->mips : 1; }
static uint64_t tex_array(id self, SEL _cmd) { (void)_cmd; return tex(self)->arrayLength ? tex(self)->arrayLength : 1; }
static uint64_t tex_gpu(id self, SEL _cmd) { (void)_cmd; return tex(self)->b.gpu_va; }

typedef struct { uint64_t x, y, z; } D2SOrigin;
typedef struct { uint64_t w, h, d; } D2SSize;
typedef struct { D2SOrigin o; D2SSize s; } D2SRegion;

static uint8_t *
texBase(struct texture *t)
{
	return t->plain ? t->plain : t->b.cpu;
}

static void
texReplace(id self, SEL _cmd, D2SRegion r, uint64_t level, const void *bytes, uint64_t bpr)
{
	(void)_cmd;
	struct texture *t = tex(self);
	if (level != 0 || bytes == NULL) {
		return;
	}
	for (uint64_t y = 0; y < r.s.h && r.o.y + y < t->height; y++) {
		uint64_t n = r.s.w * t->bpp;
		memcpy(texBase(t) + (r.o.y + y) * t->rowBytes + r.o.x * t->bpp, (const uint8_t *)bytes + y * bpr, n);
	}
}

static void
texReplace6(id self, SEL _cmd, D2SRegion r, uint64_t level, uint64_t slice, const void *bytes, uint64_t bpr, uint64_t bpi)
{
	(void)slice; (void)bpi;
	texReplace(self, _cmd, r, level, bytes, bpr);
}

static void
texGet(id self, SEL _cmd, void *bytes, uint64_t bpr, D2SRegion r, uint64_t level)
{
	(void)_cmd;
	struct texture *t = tex(self);
	if (level != 0 || bytes == NULL) {
		return;
	}
	for (uint64_t y = 0; y < r.s.h && r.o.y + y < t->height; y++) {
		memcpy((uint8_t *)bytes + y * bpr, texBase(t) + (r.o.y + y) * t->rowBytes + r.o.x * t->bpp, r.s.w * t->bpp);
	}
}

static void
texGet6(id self, SEL _cmd, void *bytes, uint64_t bpr, uint64_t bpi, D2SRegion r, uint64_t level, uint64_t slice)
{
	(void)bpi; (void)slice;
	texGet(self, _cmd, bytes, bpr, r, level);
}

static void
textureDealloc(id self, SEL _cmd)
{
	(void)_cmd;
	struct texture *t = tex(self);
	if (t != NULL) {
		if (t->b.handle != 0 && gConn != MACH_PORT_NULL) {
			d2sgpu_buf_destroy(gConn, &t->b);
		}
		free(t->plain);
		[t->c.label release];
		free(t);
	}
	struct objc_super sup = { self, class_getSuperclass(gTextureClass) };
	((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, @selector(dealloc));
}

/* ---- device ---------------------------------------------------------- */

static id
deviceInit(id self, SEL _cmd, unsigned int port)
{
	(void)_cmd;
	struct objc_super sup = { self, gBase };
	self = ((id (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, @selector(init));
	gPort = port;
	gDevice = self;
	sayc("-initWithAcceleratorPort:%u -> %s", port, self ? "device made" : "nil");
	return self;
}

static id deviceName(id s, SEL c) { (void)s; (void)c; return @"D2S Mali-G76 MC12 (Metal bring-up)"; }
static uint64_t deviceRegistryID(id s, SEL c) { (void)s; (void)c; return gPort; }
static uint64_t deviceMaxBufferLength(id s, SEL c) { (void)s; (void)c; return 256ull << 20; }
/* initLimits switches on 0,1,4..9; 7 gives 8 colour attachments (A11-class guess) */
static uint64_t deviceFeatureProfile(id s, SEL c) { (void)s; (void)c; return 7; }
static BOOL deviceYes(id s, SEL c) { (void)s; (void)c; return YES; }
static BOOL deviceNo(id s, SEL c) { (void)s; (void)c; return NO; }
static uint64_t deviceWorkingSet(id s, SEL c) { (void)s; (void)c; return 1ull << 30; }

static BOOL
deviceSupportsFamily(id s, SEL c, int64_t family)
{
	(void)s; (void)c;
	/* MTLGPUFamilyApple1..4 (1001..1004), Common1/2 (3001, 3002) */
	return (family >= 1001 && family <= 1004) || family == 3001 || family == 3002;
}

static BOOL
deviceSupportsFeatureSet(id s, SEL c, uint64_t fs)
{
	(void)s; (void)c;
	return fs <= 11;	/* iOS GPU families 1..4, v1..v2 */
}

static BOOL
deviceSampleCount(id s, SEL c, uint64_t n)
{
	(void)s; (void)c;
	return n == 1 || n == 4;
}

static id
newQueue(id self)
{
	id q = class_createInstance(gQueueClass, 0);
	q = ((id (*)(id, SEL, id))objc_msgSend)(q, @selector(initWithDevice:), self);
	static int logged;
	if (logged++ < 4) {
		sayc("newCommandQueue -> %p", q);
	}
	return q;
}

static id deviceNewQueue(id s, SEL c) { (void)c; return newQueue(s); }
static id deviceNewQueueN(id s, SEL c, uint64_t n) { (void)c; (void)n; return newQueue(s); }
static id deviceNewQueueD(id s, SEL c, id d) { (void)c; (void)d; return newQueue(s); }

static id
deviceNewBuffer(id s, SEL c, uint64_t length, uint64_t options)
{
	(void)s; (void)c;
	return bufferMake(length, options, NULL);
}

static id
deviceNewBufferBytes(id s, SEL c, const void *bytes, uint64_t length, uint64_t options)
{
	(void)s; (void)c;
	return bufferMake(length, options, bytes);
}

static id
deviceNewBufferNoCopy(id s, SEL c, void *bytes, uint64_t length, uint64_t options, void (^dealloc)(void *, NSUInteger))
{
	(void)s; (void)c; (void)dealloc;
	static int logged;
	if (logged++ < 2) {
		sayc("newBufferWithBytesNoCopy: copied (no user-page import yet; writes after this are not seen)");
	}
	return bufferMake(length, options, bytes);
}

__attribute__((constructor)) static void
d2sMetalLoad(void)
{
	const char *prog = getprogname();
	if (getenv("D2SMETAL") == NULL) {
		sayc("loaded in %s without D2SMETAL=1: no device registered", prog ? prog : "?");
		return;
	}
	gBase = objc_getClass("_MTLDevice");
	if (gBase == Nil) {
		sayc("no _MTLDevice on this system");
		return;
	}
	addProtocolFamily("MTLDevice");
	addProtocolFamily("MTLBuffer");
	addProtocolFamily("MTLResource");
	addProtocolFamily("MTLTexture");
	addProtocolFamily("MTLCommandQueue");
	addProtocolFamily("MTLAllocation");

	/* command queue: Metal's own, with our stub for what it asks of us */
	static const char *const qp[] = { "MTLCommandQueue", "MTLCommandQueueSPI", NULL };
	gQueueClass = makeClass("D2SMetalCommandQueue", "_MTLCommandQueue", qp, K_QUEUE);
	if (gQueueClass != Nil) {
		class_addMethod(gQueueClass, @selector(device), (IMP)objDevice, "@@:");
		finishClass(gQueueClass, K_QUEUE);
	}

	static const char *const bp[] = { "MTLBuffer", "MTLBufferSPI", "MTLResource", "MTLResourceSPI", NULL };
	gBufferClass = makeClass("D2SMetalBuffer", "_MTLResource", bp, K_BUFFER);
	if (gBufferClass != Nil) {
		class_addMethod(gBufferClass, @selector(contents), (IMP)bufferContents, "^v@:");
		class_addMethod(gBufferClass, @selector(length), (IMP)bufferLength, "Q@:");
		class_addMethod(gBufferClass, sel_registerName("gpuAddress"), (IMP)bufferGPUAddress, "Q@:");
		class_addMethod(gBufferClass, sel_registerName("resourceOptions"), (IMP)bufferOptions, "Q@:");
		class_addMethod(gBufferClass, sel_registerName("storageMode"), (IMP)bufferStorageMode, "Q@:");
		class_addMethod(gBufferClass, sel_registerName("cpuCacheMode"), (IMP)bufferCacheMode, "Q@:");
		class_addMethod(gBufferClass, sel_registerName("didModifyRange:"), (IMP)nothingRange, "v@:{_NSRange=QQ}");
		class_addMethod(gBufferClass, @selector(device), (IMP)objDevice, "@@:");
		class_addMethod(gBufferClass, @selector(label), (IMP)labelGet, "@@:");
		class_addMethod(gBufferClass, sel_registerName("setLabel:"), (IMP)labelSet, "v@:@");
		class_addMethod(gBufferClass, @selector(dealloc), (IMP)bufferDealloc, "v@:");
		finishClass(gBufferClass, K_BUFFER);
	}

	static const char *const tp[] = { "MTLTexture", "MTLTextureSPI", "MTLTextureImplementation", "MTLResource",
		                          "MTLResourceSPI", NULL };
	gTextureClass = makeClass("D2SMetalTexture", "_MTLResource", tp, K_TEXTURE);
	if (gTextureClass != Nil) {
		Class t = gTextureClass;
		class_addMethod(t, sel_registerName("width"), (IMP)tex_width, "Q@:");
		class_addMethod(t, sel_registerName("height"), (IMP)tex_height, "Q@:");
		class_addMethod(t, sel_registerName("depth"), (IMP)tex_depth, "Q@:");
		class_addMethod(t, sel_registerName("pixelFormat"), (IMP)tex_pixelFormat, "Q@:");
		class_addMethod(t, sel_registerName("textureType"), (IMP)tex_type, "Q@:");
		class_addMethod(t, sel_registerName("usage"), (IMP)tex_usage, "Q@:");
		class_addMethod(t, sel_registerName("storageMode"), (IMP)tex_storage, "Q@:");
		class_addMethod(t, sel_registerName("mipmapLevelCount"), (IMP)tex_mips, "Q@:");
		class_addMethod(t, sel_registerName("sampleCount"), (IMP)tex_samples, "Q@:");
		class_addMethod(t, sel_registerName("arrayLength"), (IMP)tex_array, "Q@:");
		class_addMethod(t, sel_registerName("gpuAddress"), (IMP)tex_gpu, "Q@:");
		class_addMethod(t, sel_registerName("rowBytes"), (IMP)tex_rowBytes, "Q@:");
		class_addMethod(t, sel_registerName("replaceRegion:mipmapLevel:withBytes:bytesPerRow:"), (IMP)texReplace,
		    "v@:{?={?=QQQ}{?=QQQ}}Q^vQ");
		class_addMethod(t, sel_registerName("replaceRegion:mipmapLevel:slice:withBytes:bytesPerRow:bytesPerImage:"),
		    (IMP)texReplace6, "v@:{?={?=QQQ}{?=QQQ}}QQ^vQQ");
		class_addMethod(t, sel_registerName("getBytes:bytesPerRow:fromRegion:mipmapLevel:"), (IMP)texGet,
		    "v@:^vQ{?={?=QQQ}{?=QQQ}}Q");
		class_addMethod(t, sel_registerName("getBytes:bytesPerRow:bytesPerImage:fromRegion:mipmapLevel:slice:"),
		    (IMP)texGet6, "v@:^vQQ{?={?=QQQ}{?=QQQ}}QQ");
		class_addMethod(t, @selector(device), (IMP)objDevice, "@@:");
		class_addMethod(t, @selector(label), (IMP)labelGet, "@@:");
		class_addMethod(t, sel_registerName("setLabel:"), (IMP)labelSet, "v@:@");
		class_addMethod(t, @selector(dealloc), (IMP)textureDealloc, "v@:");
		finishClass(t, K_TEXTURE);
	}

	Class cls = objc_allocateClassPair(gBase, "D2SMetalDevice", 0);
	if (cls == Nil) {
		sayc("could not make D2SMetalDevice");
		return;
	}
	static const char *const dp[] = { "MTLDevice", "MTLDeviceSPI", NULL };
	for (int i = 0; dp[i] != NULL; i++) {
		Protocol *p = objc_getProtocol(dp[i]);
		if (p != NULL) {
			class_addProtocol(cls, p);
		}
	}
	class_addMethod(cls, sel_registerName("initWithAcceleratorPort:"), (IMP)deviceInit, "@@:I");
	class_addMethod(cls, @selector(name), (IMP)deviceName, "@@:");
	class_addMethod(cls, sel_registerName("registryID"), (IMP)deviceRegistryID, "Q@:");
	class_addMethod(cls, sel_registerName("maxBufferLength"), (IMP)deviceMaxBufferLength, "Q@:");
	class_addMethod(cls, sel_registerName("featureProfile"), (IMP)deviceFeatureProfile, "Q@:");
	class_addMethod(cls, sel_registerName("hasUnifiedMemory"), (IMP)deviceYes, "B@:");
	class_addMethod(cls, sel_registerName("isLowPower"), (IMP)deviceYes, "B@:");
	class_addMethod(cls, sel_registerName("isHeadless"), (IMP)deviceNo, "B@:");
	class_addMethod(cls, sel_registerName("isRemovable"), (IMP)deviceNo, "B@:");
	class_addMethod(cls, sel_registerName("recommendedMaxWorkingSetSize"), (IMP)deviceWorkingSet, "Q@:");
	class_addMethod(cls, sel_registerName("supportsFamily:"), (IMP)deviceSupportsFamily, "B@:q");
	class_addMethod(cls, sel_registerName("supportsFeatureSet:"), (IMP)deviceSupportsFeatureSet, "B@:Q");
	class_addMethod(cls, sel_registerName("supportsTextureSampleCount:"), (IMP)deviceSampleCount, "B@:Q");
	class_addMethod(cls, sel_registerName("newCommandQueue"), (IMP)deviceNewQueue, "@@:");
	class_addMethod(cls, sel_registerName("newCommandQueueWithMaxCommandBufferCount:"), (IMP)deviceNewQueueN, "@@:Q");
	class_addMethod(cls, sel_registerName("newCommandQueueWithDescriptor:"), (IMP)deviceNewQueueD, "@@:@");
	class_addMethod(cls, sel_registerName("newBufferWithLength:options:"), (IMP)deviceNewBuffer, "@@:QQ");
	class_addMethod(cls, sel_registerName("newBufferWithBytes:length:options:"), (IMP)deviceNewBufferBytes, "@@:^vQQ");
	class_addMethod(cls, sel_registerName("newBufferWithBytesNoCopy:length:options:deallocator:"),
	    (IMP)deviceNewBufferNoCopy, "@@:^vQQ@?");
	class_addMethod(cls, sel_registerName("newTextureWithDescriptor:"), (IMP)deviceNewTexture, "@@:@");
	class_addMethod(cls, @selector(methodSignatureForSelector:), (IMP)stubSignature, "@@::");
	class_addMethod(cls, @selector(forwardInvocation:), (IMP)stubForward, "v@:@");
	objc_registerClassPair(cls);
	sayc("loaded in %s: D2SMetalDevice registered (queue %s, buffer %s, texture %s, %d protocols)", prog ? prog : "?",
	    gQueueClass ? "yes" : "no", gBufferClass ? "yes" : "no", gTextureClass ? "yes" : "no", gNProtocols);
}
