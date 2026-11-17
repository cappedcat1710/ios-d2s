/*
 * D2SMetal: the Metal plug-in for the Galaxy Note 10+ (d2s), Mali-G76.
 *
 * Metal finds the IOKit service of class IOAcceleratorES (kernel patch 0138),
 * reads its MetalPluginName / MetalPluginClassName (boot-arg metal=1), opens
 * /System/Library/Extensions/D2SMetal.bundle, takes the class
 * D2SMetalDevice, requires it to be a subclass of Metal's private
 * _MTLDevice, and sends it -initWithAcceleratorPort:. That object is the
 * system's one MTLDevice.
 *
 * Milestone 1 (this file): a device that exists. It answers
 * -initWithAcceleratorPort:, -name and -registryID, and every other message
 * is logged once ("asked and not implemented: -selector") and answered with
 * zero, so the first calls Metal makes can be read off the kernel log.
 * Nothing draws yet. Plan: tools/d2s-metal/PLAN.md.
 *
 * The approach (a private-base subclass built at load time, a logged zero
 * stub for the rest) follows hakios' HakiosMetal.m (MIT), rewritten here.
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

static Class gBase;
static unsigned int gPort;
static io_connect_t gLog = MACH_PORT_NULL;
static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
static NSMutableSet *gSeen;
static Protocol *gProtocols[4];

static void
say(NSString *text)
{
	NSLog(@"D2SMetal: %@", text);
	pthread_mutex_lock(&gLock);
	if (gLog == MACH_PORT_NULL) {
		gLog = d2sgpu_open();
	}
	if (gLog != MACH_PORT_NULL) {
		char line[150];
		int n = snprintf(line, sizeof(line), "D2SMetal: %s", [text UTF8String]);
		if (n > 0) {
			d2sgpu_log(gLog, line, (size_t)n < sizeof(line) ? (size_t)n : sizeof(line) - 1);
		}
	}
	pthread_mutex_unlock(&gLock);
}

static id
deviceInit(id self, SEL _cmd, unsigned int port)
{
	struct objc_super sup = { self, gBase };
	id (*send)(struct objc_super *, SEL) = (id (*)(struct objc_super *, SEL))objc_msgSendSuper;

	(void)_cmd;
	self = send(&sup, sel_registerName("init"));
	gPort = port;
	say([NSString stringWithFormat:@"-initWithAcceleratorPort:%u -> %@", port, self ? @"device made" : @"nil"]);
	return self;
}

static id
deviceName(id self, SEL _cmd)
{
	(void)self; (void)_cmd;
	return @"D2S Mali-G76 MC12 (Metal bring-up)";
}

static uint64_t
deviceRegistryID(id self, SEL _cmd)
{
	(void)self; (void)_cmd;
	return gPort;
}

/* what Metal asks of every device before it will use it: sizes and the feature level of an Apple GPU family 4 (A11) */
static uint64_t
deviceMaxBufferLength(id self, SEL _cmd)
{
	(void)self; (void)_cmd;
	return 256ull << 20;
}

static uint64_t
deviceFeatureProfile(id self, SEL _cmd)
{
	(void)self; (void)_cmd;
	return 7;	/* initLimits compares the profile with 0,1,4,5,6,7,8,9; 7 is the lowest that gives 8 colour attachments (guess) */
}

/* a signature for a message the device does not implement: from the Metal protocols, so the stub knows the return size */
static id
deviceSignature(id self, SEL _cmd, SEL selector)
{
	(void)_cmd;
	for (int i = 0; i < 4 && gProtocols[i] != NULL; i++) {
		for (int required = 1; required >= 0; required--) {
			struct objc_method_description d = protocol_getMethodDescription(gProtocols[i], selector, required, YES);
			if (d.name != NULL && d.types != NULL) {
				id (*make)(Class, SEL, const char *) = (id (*)(Class, SEL, const char *))objc_msgSend;
				return make(objc_getClass("NSMethodSignature"), sel_registerName("signatureWithObjCTypes:"), d.types);
			}
		}
	}
	struct objc_super sup = { self, gBase };
	id (*send)(struct objc_super *, SEL, SEL) = (id (*)(struct objc_super *, SEL, SEL))objc_msgSendSuper;
	return send(&sup, sel_registerName("methodSignatureForSelector:"), selector);
}

static void
deviceForward(id self, SEL _cmd, id invocation)
{
	SEL selector = ((SEL (*)(id, SEL))objc_msgSend)(invocation, sel_registerName("selector"));
	id signature = ((id (*)(id, SEL))objc_msgSend)(invocation, sel_registerName("methodSignature"));
	NSUInteger length = ((NSUInteger (*)(id, SEL))objc_msgSend)(signature, sel_registerName("methodReturnLength"));
	NSString *name = NSStringFromSelector(selector);

	(void)self; (void)_cmd;
	@synchronized(gBase) {
		if (gSeen == nil) {
			gSeen = [NSMutableSet new];
		}
		if (![gSeen containsObject:name]) {
			[gSeen addObject:name];
			const char *enc = ((const char *(*)(id, SEL))objc_msgSend)(signature, sel_registerName("methodReturnType"));
			say([NSString stringWithFormat:@"asked and not implemented: -%@ (returns %lu bytes, type %s; answered with zero)",
			    name, (unsigned long)length, enc ? enc : "?"]);
		}
	}
	if (length != 0) {
		void *zero = calloc(1, length);
		((void (*)(id, SEL, void *))objc_msgSend)(invocation, sel_registerName("setReturnValue:"), zero);
		free(zero);
	}
}

__attribute__((constructor)) static void
d2sMetalLoad(void)
{
	gBase = objc_getClass("_MTLDevice");
	if (gBase == Nil) {
		say(@"no _MTLDevice class on this system; the plug-in registers nothing");
		return;
	}
	Class cls = objc_allocateClassPair(gBase, "D2SMetalDevice", 0);
	if (cls == Nil) {
		say(@"could not make D2SMetalDevice");
		return;
	}
	const char *names[] = { "MTLDevice", "MTLDeviceSPI", "MTLDevicePrivate", NULL };
	int n = 0;
	for (int i = 0; names[i] != NULL; i++) {
		Protocol *p = objc_getProtocol(names[i]);
		if (p != NULL) {
			gProtocols[n++] = p;
			class_addProtocol(cls, p);
		}
	}
	class_addMethod(cls, sel_registerName("initWithAcceleratorPort:"), (IMP)deviceInit, "@@:I");
	class_addMethod(cls, sel_registerName("name"), (IMP)deviceName, "@@:");
	class_addMethod(cls, sel_registerName("registryID"), (IMP)deviceRegistryID, "Q@:");
	class_addMethod(cls, sel_registerName("maxBufferLength"), (IMP)deviceMaxBufferLength, "Q@:");
	class_addMethod(cls, sel_registerName("featureProfile"), (IMP)deviceFeatureProfile, "Q@:");
	class_addMethod(cls, sel_registerName("methodSignatureForSelector:"), (IMP)deviceSignature, "@@::");
	class_addMethod(cls, sel_registerName("forwardInvocation:"), (IMP)deviceForward, "v@:@");
	objc_registerClassPair(cls);
	say([NSString stringWithFormat:@"loaded: D2SMetalDevice registered (subclass of _MTLDevice, %d Metal protocols)", n]);
}
