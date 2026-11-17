/*
 * pantest: GPU step 4a on the d2s. Mesa's panfrost Gallium driver, over
 * d2sdrm and D2SGPU, clears an IOSurface; the CPU checks the pixels through
 * the IOSurface's own mapping.
 *
 * Built as pantest.dylib and inserted into backboardd with the d2senv
 * boot-arg (like tools/d2s-gpu's test): it runs once, on its own thread, a
 * few seconds after load, and reports in the kernel log
 * ("D2S GPU UC: backboardd: pantest: ...").
 */
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <IOSurface/IOSurfaceRef.h>

#include "pipe/p_context.h"
#include "pipe/p_defines.h"
#include "pipe/p_screen.h"
#include "pipe/p_state.h"
#include "frontend/winsys_handle.h"
#include "drm-uapi/drm_fourcc.h"
#include "util/driconf.h"
#include "util/os_time.h"
#include "util/u_simple_shaders.h"
#include "util/u_inlines.h"
#include "util/xmlconfig.h"
#include "panfrost/pan_public.h"
#include "d2sdrm.h"

static const driOptionDescription gallium_conf[] = {
#include "driinfo_gallium.h"
};

static const driOptionDescription pan_conf[] = {
#include "panfrost/driinfo_panfrost.h"
};

static int fd = -1;
#define say(...) d2sdrm_log(fd, "pantest: " __VA_ARGS__)

static IOSurfaceRef
make_surface(int w, int h)
{
	int bpe = 4, fmt = 0x42475241;	/* 'BGRA' */
	const void *keys[] = { kIOSurfaceWidth, kIOSurfaceHeight, kIOSurfaceBytesPerElement,
		               kIOSurfacePixelFormat };
	CFNumberRef vals[] = {
		CFNumberCreate(NULL, kCFNumberIntType, &w), CFNumberCreate(NULL, kCFNumberIntType, &h),
		CFNumberCreate(NULL, kCFNumberIntType, &bpe), CFNumberCreate(NULL, kCFNumberIntType, &fmt),
	};
	CFDictionaryRef props = CFDictionaryCreate(NULL, keys, (const void **)vals, 4,
	    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	IOSurfaceRef s = IOSurfaceCreate(props);
	CFRelease(props);
	for (int i = 0; i < 4; i++) {
		CFRelease(vals[i]);
	}
	return s;
}

/* Clear to colour c; count pixels within 1 of the expected BGRA bytes. */
static int
clear_and_check(struct pipe_screen *screen, struct pipe_context *pipe, struct pipe_resource *res,
    IOSurfaceRef surf, int w, int h, const float c[4])
{
	struct pipe_framebuffer_state fb;
	memset(&fb, 0, sizeof(fb));
	fb.width = (uint32_t)w;
	fb.height = (uint32_t)h;
	fb.layers = 1;
	fb.nr_cbufs = 1;
	fb.cbufs[0].texture = res;
	fb.cbufs[0].format = res->format;
	pipe->set_framebuffer_state(pipe, &fb);

	union pipe_color_union col;
	memcpy(col.f, c, sizeof(col.f));
	pipe->clear(pipe, PIPE_CLEAR_COLOR0, 0xffffffffu, 0xff, NULL, &col, 0.0, 0);
	struct pipe_fence_handle *fence = NULL;
	uint64_t t0 = os_time_get_nano();
	pipe->flush(pipe, &fence, 0);
	bool done = fence != NULL && screen->fence_finish(screen, NULL, fence, OS_TIMEOUT_INFINITE);
	uint64_t t1 = os_time_get_nano();
	screen->fence_reference(screen, &fence, NULL);

	const uint8_t want[4] = { (uint8_t)(c[2] * 255 + 0.5f), (uint8_t)(c[1] * 255 + 0.5f),
		                  (uint8_t)(c[0] * 255 + 0.5f), (uint8_t)(c[3] * 255 + 0.5f) };
	IOSurfaceLock(surf, kIOSurfaceLockReadOnly, NULL);
	const uint8_t *base = IOSurfaceGetBaseAddress(surf);
	size_t bpr = IOSurfaceGetBytesPerRow(surf);
	int good = 0;
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			const uint8_t *p = base + (size_t)y * bpr + (size_t)x * 4;
			int ok = 1;
			for (int k = 0; k < 4; k++) {
				ok &= abs((int)p[k] - (int)want[k]) <= 1;
			}
			good += ok;
		}
	}
	uint32_t first, mid;
	memcpy(&first, base, 4);
	memcpy(&mid, base + (size_t)(h / 2) * bpr + (size_t)(w / 2) * 4, 4);
	IOSurfaceUnlock(surf, kIOSurfaceLockReadOnly, NULL);
	say("clear %.2f,%.2f,%.2f,%.2f: fence %s in %llu us, %d/%d pixels right, first %#x mid %#x",
	    c[0], c[1], c[2], c[3], done ? "done" : "NOT DONE",
	    (unsigned long long)((t1 - t0) / 1000), good, w * h, first, mid);
	return done && good == w * h;
}

static struct pipe_resource *
import_surface(struct pipe_screen *screen, IOSurfaceRef surf, int w, int h, unsigned bind,
    unsigned usage)
{
	int pfd = d2sdrm_surface_fd(fd, IOSurfaceGetID(surf));
	if (pfd < 0) {
		return NULL;
	}
	struct pipe_resource templ;
	memset(&templ, 0, sizeof(templ));
	templ.target = PIPE_TEXTURE_2D;
	templ.format = PIPE_FORMAT_B8G8R8A8_UNORM;
	templ.width0 = (uint32_t)w;
	templ.height0 = (uint16_t)h;
	templ.depth0 = 1;
	templ.array_size = 1;
	templ.bind = bind | PIPE_BIND_SHARED;
	struct winsys_handle wh;
	memset(&wh, 0, sizeof(wh));
	wh.type = WINSYS_HANDLE_TYPE_FD;
	wh.handle = (unsigned)pfd;
	wh.stride = (unsigned)IOSurfaceGetBytesPerRow(surf);
	wh.offset = 0;
	wh.modifier = DRM_FORMAT_MOD_LINEAR;
	struct pipe_resource *res = screen->resource_from_handle(screen, &templ, &wh, usage);
	close(pfd);
	return res;
}

/*
 * Step 4b: what a compositor layer needs. Draw a textured quad (premultiplied
 * alpha, "source over") of one IOSurface onto another, with a vertex and a
 * fragment shader and sampler/blend state, and compare with the same blend
 * computed on the CPU.
 *   source: left half opaque red, right half 50% green (premultiplied)
 *   dest:   opaque blue
 *   result: left half red, right half (0, 128, 127) with alpha 255
 */
static int
quad_test(struct pipe_screen *screen, struct pipe_context *pipe, struct pipe_resource *dst_res,
    IOSurfaceRef dst, int w, int h)
{
	IOSurfaceRef src = make_surface(w, h);
	if (src == NULL) {
		say("QUAD FAIL: source IOSurface");
		return 0;
	}
	IOSurfaceLock(src, 0, NULL);
	uint8_t *sb = IOSurfaceGetBaseAddress(src);
	size_t sbpr = IOSurfaceGetBytesPerRow(src);
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			uint8_t *p = sb + (size_t)y * sbpr + (size_t)x * 4;	/* B G R A */
			if (x < w / 2) {
				p[0] = 0, p[1] = 0, p[2] = 255, p[3] = 255;
			} else {
				p[0] = 0, p[1] = 128, p[2] = 0, p[3] = 128;
			}
		}
	}
	IOSurfaceUnlock(src, 0, NULL);
	struct pipe_resource *src_res =
	    import_surface(screen, src, w, h, PIPE_BIND_SAMPLER_VIEW, 0);
	if (src_res == NULL) {
		say("QUAD FAIL: resource_from_handle (source)");
		return 0;
	}

	/* destination: blue, then draw over it */
	struct pipe_framebuffer_state fb;
	memset(&fb, 0, sizeof(fb));
	fb.width = (uint32_t)w;
	fb.height = (uint32_t)h;
	fb.layers = 1;
	fb.nr_cbufs = 1;
	fb.cbufs[0].texture = dst_res;
	fb.cbufs[0].format = dst_res->format;
	pipe->set_framebuffer_state(pipe, &fb);
	union pipe_color_union blue = { .f = { 0.0f, 0.0f, 1.0f, 1.0f } };
	pipe->clear(pipe, PIPE_CLEAR_COLOR0, 0xffffffffu, 0xff, NULL, &blue, 0.0, 0);

	struct pipe_viewport_state vp;
	memset(&vp, 0, sizeof(vp));
	vp.scale[0] = w / 2.0f, vp.scale[1] = h / 2.0f, vp.scale[2] = 0.5f;
	vp.translate[0] = w / 2.0f, vp.translate[1] = h / 2.0f, vp.translate[2] = 0.5f;
	pipe->set_viewport_states(pipe, 0, 1, &vp);

	struct pipe_rasterizer_state rs;
	memset(&rs, 0, sizeof(rs));
	rs.cull_face = PIPE_FACE_NONE;
	rs.fill_front = rs.fill_back = PIPE_POLYGON_MODE_FILL;
	rs.half_pixel_center = 1;
	rs.bottom_edge_rule = 1;
	rs.depth_clip_near = rs.depth_clip_far = 1;
	void *rast = pipe->create_rasterizer_state(pipe, &rs);

	struct pipe_blend_state bs;
	memset(&bs, 0, sizeof(bs));
	bs.rt[0].blend_enable = 1;
	bs.rt[0].rgb_func = bs.rt[0].alpha_func = PIPE_BLEND_ADD;
	bs.rt[0].rgb_src_factor = bs.rt[0].alpha_src_factor = PIPE_BLENDFACTOR_ONE;
	bs.rt[0].rgb_dst_factor = bs.rt[0].alpha_dst_factor = PIPE_BLENDFACTOR_INV_SRC_ALPHA;
	bs.rt[0].colormask = PIPE_MASK_RGBA;
	void *blend = pipe->create_blend_state(pipe, &bs);

	struct pipe_depth_stencil_alpha_state dsa;
	memset(&dsa, 0, sizeof(dsa));
	void *dsas = pipe->create_depth_stencil_alpha_state(pipe, &dsa);

	struct pipe_sampler_state ss;
	memset(&ss, 0, sizeof(ss));
	ss.wrap_s = ss.wrap_t = ss.wrap_r = PIPE_TEX_WRAP_CLAMP_TO_EDGE;
	ss.min_img_filter = ss.mag_img_filter = PIPE_TEX_FILTER_NEAREST;
	ss.min_mip_filter = PIPE_TEX_MIPFILTER_NONE;
	void *samp = pipe->create_sampler_state(pipe, &ss);

	struct pipe_sampler_view svt;
	memset(&svt, 0, sizeof(svt));
	svt.format = PIPE_FORMAT_B8G8R8A8_UNORM;
	svt.target = PIPE_TEXTURE_2D;
	svt.swizzle_r = PIPE_SWIZZLE_X;
	svt.swizzle_g = PIPE_SWIZZLE_Y;
	svt.swizzle_b = PIPE_SWIZZLE_Z;
	svt.swizzle_a = PIPE_SWIZZLE_W;
	struct pipe_sampler_view *sv = pipe->create_sampler_view(pipe, src_res, &svt);

	const enum tgsi_semantic names[2] = { TGSI_SEMANTIC_POSITION, TGSI_SEMANTIC_GENERIC };
	const unsigned idx[2] = { 0, 0 };
	void *vs = util_make_vertex_passthrough_shader(pipe, 2, names, idx, false);
	void *fs = util_make_fragment_tex_shader(pipe, TGSI_TEXTURE_2D, TGSI_RETURN_TYPE_FLOAT,
	    TGSI_RETURN_TYPE_FLOAT, false, false);

	struct pipe_vertex_element ve[2];
	memset(ve, 0, sizeof(ve));
	ve[0].src_format = PIPE_FORMAT_R32G32B32A32_FLOAT;
	ve[0].src_offset = 0;
	ve[1].src_format = PIPE_FORMAT_R32G32B32A32_FLOAT;
	ve[1].src_offset = 16;
	for (int i = 0; i < 2; i++) {
		ve[i].vertex_buffer_index = 0;
		ve[i].src_stride = 32;	/* bytes per vertex: 8 floats */
	}
	void *vels = pipe->create_vertex_elements_state(pipe, 2, ve);
	if (!rast || !blend || !dsas || !samp || !sv || !vs || !fs || !vels) {
		say("QUAD FAIL: state creation (rast %p blend %p dsa %p samp %p sv %p vs %p fs %p ve %p)",
		    rast, blend, dsas, samp, (void *)sv, vs, fs, vels);
		return 0;
	}
	/* triangle strip, covering the whole target; v up = texture row 0 up */
	static const float verts[4][8] = {
		{ -1, -1, 0, 1,  0, 1, 0, 1 }, { 1, -1, 0, 1,  1, 1, 0, 1 },
		{ -1,  1, 0, 1,  0, 0, 0, 1 }, { 1,  1, 0, 1,  1, 0, 0, 1 },
	};
	/* panfrost has no user-buffer path (u_vbuf normally wraps it): use a real buffer */
	struct pipe_resource *vbuf = pipe_buffer_create_with_data(pipe, PIPE_BIND_VERTEX_BUFFER,
	    PIPE_USAGE_IMMUTABLE, sizeof(verts), verts);
	if (vbuf == NULL) {
		say("QUAD FAIL: vertex buffer");
		return 0;
	}
	struct pipe_vertex_buffer vb;
	memset(&vb, 0, sizeof(vb));
	vb.buffer.resource = vbuf;
	vb.buffer_offset = 0;
	pipe->bind_rasterizer_state(pipe, rast);
	pipe->bind_blend_state(pipe, blend);
	pipe->bind_depth_stencil_alpha_state(pipe, dsas);
	pipe->bind_vertex_elements_state(pipe, vels);
	pipe->set_vertex_buffers(pipe, 1, &vb);
	pipe->bind_vs_state(pipe, vs);
	pipe->bind_fs_state(pipe, fs);
	pipe->bind_sampler_states(pipe, MESA_SHADER_FRAGMENT, 0, 1, &samp);
	pipe->set_sampler_views(pipe, MESA_SHADER_FRAGMENT, 0, 1, 0, &sv);

	struct pipe_draw_info di;
	memset(&di, 0, sizeof(di));
	di.mode = MESA_PRIM_TRIANGLE_STRIP;
	di.instance_count = 1;
	di.min_index = 0;
	di.max_index = 3;
	struct pipe_draw_start_count_bias dr = { .start = 0, .count = 4, .index_bias = 0 };
	pipe->draw_vbo(pipe, &di, 0, NULL, &dr, 1);

	struct pipe_fence_handle *fence = NULL;
	uint64_t t0 = os_time_get_nano();
	pipe->flush(pipe, &fence, 0);
	bool done = fence != NULL && screen->fence_finish(screen, NULL, fence, OS_TIMEOUT_INFINITE);
	uint64_t t1 = os_time_get_nano();
	screen->fence_reference(screen, &fence, NULL);

	IOSurfaceLock(dst, kIOSurfaceLockReadOnly, NULL);
	const uint8_t *base = IOSurfaceGetBaseAddress(dst);
	size_t bpr = IOSurfaceGetBytesPerRow(dst);
	int good = 0;
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			const uint8_t *p = base + (size_t)y * bpr + (size_t)x * 4;
			/* B G R A; the blend of an alpha-128 green over blue is B 127 G 128 R 0 A 255 */
			int ok;
			if (x < w / 2) {
				ok = p[0] <= 2 && p[1] <= 2 && p[2] >= 253 && p[3] >= 253;
			} else {
				ok = abs(p[0] - 127) <= 3 && abs(p[1] - 128) <= 3 && p[2] <= 2 && p[3] >= 253;
			}
			good += ok;
		}
	}
	uint32_t left, right;
	memcpy(&left, base + (size_t)(h / 2) * bpr + (size_t)(w / 4) * 4, 4);
	memcpy(&right, base + (size_t)(h / 2) * bpr + (size_t)(3 * w / 4) * 4, 4);
	IOSurfaceUnlock(dst, kIOSurfaceLockReadOnly, NULL);
	say("quad (texture + shaders + source-over blend): fence %s in %llu us, %d/%d pixels right, "
	    "left %#x (want 0xffff0000) right %#x (want ~0xff008f7f)", done ? "done" : "NOT DONE",
	    (unsigned long long)((t1 - t0) / 1000), good, w * h, left, right);

	pipe->bind_sampler_states(pipe, MESA_SHADER_FRAGMENT, 0, 1, (void *[]){ NULL });
	pipe->set_sampler_views(pipe, MESA_SHADER_FRAGMENT, 0, 0, 1, NULL);
	pipe_sampler_view_reference(&sv, NULL);
	pipe_resource_reference(&src_res, NULL);
	pipe_resource_reference(&vbuf, NULL);
	CFRelease(src);
	return done && good == w * h;
}

static void
run(void)
{
	fd = d2sdrm_open();
	if (fd < 0) {
		return;		/* no D2SGPU: nothing to report to */
	}
	say("start (Mesa panfrost over d2sdrm)");

	unsigned n = (unsigned)(ARRAY_SIZE(gallium_conf) + ARRAY_SIZE(pan_conf));
	driOptionDescription *conf = malloc(n * sizeof(*conf));
	memcpy(conf, gallium_conf, sizeof(gallium_conf));
	memcpy(conf + ARRAY_SIZE(gallium_conf), pan_conf, sizeof(pan_conf));
	driOptionCache info, cache;
	driParseOptionInfo(&info, conf, n);
	driParseConfigFiles(&cache, &info, &(driConfigFileParseParams){ .driverName = "panfrost" });
	free(conf);
	struct pipe_screen_config cfg = { .options = &cache, .options_info = &info };

	struct pipe_screen *screen = panfrost_create_screen(fd, &cfg, NULL);
	if (screen == NULL) {
		say("PANTEST FAIL: panfrost_create_screen returned NULL");
		return;
	}
	say("screen: %s / %s", screen->get_vendor(screen), screen->get_name(screen));
	struct pipe_context *pipe = screen->context_create(screen, NULL, 0);
	if (pipe == NULL) {
		say("PANTEST FAIL: context_create returned NULL");
		return;
	}

	const int w = 64, h = 64;
	IOSurfaceRef surf = make_surface(w, h);
	if (surf == NULL) {
		say("PANTEST FAIL: IOSurfaceCreate");
		return;
	}
	struct pipe_resource *res = import_surface(screen, surf, w, h,
	    PIPE_BIND_RENDER_TARGET, PIPE_HANDLE_USAGE_FRAMEBUFFER_WRITE);
	if (res == NULL) {
		say("PANTEST FAIL: resource_from_handle (IOSurface %u, %zu bytes/row)",
		    IOSurfaceGetID(surf), IOSurfaceGetBytesPerRow(surf));
		return;
	}
	say("IOSurface %u imported as a %ux%u render target", IOSurfaceGetID(surf), w, h);

	const float a[4] = { 0.0f, 0.5f, 1.0f, 1.0f }, b[4] = { 1.0f, 0.25f, 0.0f, 1.0f };
	int ok_a = clear_and_check(screen, pipe, res, surf, w, h, a);
	int ok_b = clear_and_check(screen, pipe, res, surf, w, h, b);
	say("PANTEST %s (clear 1 %s, clear 2 %s)", ok_a && ok_b ? "OK" : "FAIL",
	    ok_a ? "ok" : "FAIL", ok_b ? "ok" : "FAIL");
	int ok_q = quad_test(screen, pipe, res, surf, w, h);
	say("QUADTEST %s", ok_q ? "OK" : "FAIL");

	pipe_resource_reference(&res, NULL);
	pipe->destroy(pipe);
	screen->destroy(screen);
	CFRelease(surf);
}

static void *
test_thread(void *arg)
{
	(void)arg;
	sleep(5);
	run();
	return NULL;
}

__attribute__((constructor)) static void
pantest_load(void)
{
	const char *name = getprogname();
	if (name == NULL || strcmp(name, "backboardd") != 0) {
		return;
	}
	pthread_t t;
	if (pthread_create(&t, NULL, test_thread, NULL) == 0) {
		pthread_detach(t);
	}
}
