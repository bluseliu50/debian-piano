/*
 * piano-touch-view — inspect the NT36532 THP frame stream on the device.
 *
 * Written from scratch for the linux-xiaomi-piano bring-up initramfs.
 * The kernel driver (linux-piano drivers/input/touchscreen/nt36532e)
 * publishes /proc/nvt_thp_stream: records of a 32-byte little-endian
 * header (magic "NTP1", header_len, frame_len, sequence, timestamp_ns,
 * header_crc, flags, firmware_magic) followed by frame_len bytes. A frame
 * is the 1-byte SPI command slot, the 256-byte event buffer and the
 * Xiaomi host touch computing payload. Payload layout, as parsed by the
 * stock p81 driver (refer/MiCode_piano/.../p81/nt36532/nt36xxx.c,
 * nvt_ts_prase_data_func):
 *
 *   +4 u16 checksum      +8 s32 crc_len (dwords from +20)
 *   +12 u16 ~checksum    +16 s32 ~crc_len
 *   +28 u16 frame_no     +48 u8 columns  +49 u8 rows
 *   +56 u8 data type     +64 s16 matrix[rows][columns] (mutual frames)
 *
 * checksum == -(sum of the crc_len*2 u16 words from +20).
 *
 * This is a bring-up viewer, not a touch service: the reference is the
 * median of the first frames (keep fingers off while it starts) and
 * contacts are plain local maxima with a 3x3 centroid.
 *
 * Usage: piano-touch-view [MODE] [options]
 *   MODE: stats (default) | map | points | paint | dump
 *   --seconds N      stop after N seconds (default 30, 0 = forever)
 *   --type N         matrix frame type (default: most common in the
 *                    first frames, pen types 6/7/9/0x1d excluded)
 *   --threshold T    delta counted as touch (default 200)
 *   --reference N    reference frames (default 32)
 *   --invert         touches lower the value (default: raise)
 *   --swap-xy --flip-x --flip-y   paint orientation
 *
 * PIANO_THP_STREAM=<file> replays a captured stream instead of the proc
 * interface (capture control is left alone then).
 */

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <linux/fb.h>

#define STREAM_PATH "/proc/nvt_thp_stream"
#define CONTROL_PATH "/proc/nvt_thp_raw"
#define STREAM_MAGIC 0x3150544eu
#define TRANSPORT_LEN 257
#define PAYLOAD_MIN 64
#define MAX_NODES 4096
#define MAX_TYPES 256
#define MAX_REF 128
#define MAX_POINTS 10
#define TYPE_PROBE_FRAMES 16

enum mode { MODE_STATS, MODE_MAP, MODE_POINTS, MODE_PAINT, MODE_DUMP };

static volatile sig_atomic_t running = 1;

static struct {
	enum mode mode;
	int seconds;
	int threshold;
	int ref_frames;
	int invert;
	int swap_xy, flip_x, flip_y;
	int type;
} opt = { MODE_STATS, 30, 200, 32, 0, 0, 0, 0, -1 };

static struct {
	unsigned long records, bad_magic, flag_valid, csum_ok, csum_bad;
	unsigned long short_payload, types[MAX_TYPES];
	int rows, cols;
	unsigned int last_frame_no;
	int max_delta;
} st;

static int16_t ref_samples[MAX_REF][MAX_NODES];
static int ref_count, ref_type = -1;
static unsigned long probe_types[MAX_TYPES], probe_count;
static int reference[MAX_NODES];
static int have_reference;
static int delta[MAX_NODES];

static struct {
	uint8_t *mem;
	unsigned int width, height, stride, bpp;
	size_t size;
} fb;

static void on_signal(int sig)
{
	(void)sig;
	running = 0;
}

static uint16_t le16(const uint8_t *p)
{
	return (uint16_t)(p[0] | p[1] << 8);
}

static uint32_t le32(const uint8_t *p)
{
	return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 |
	       (uint32_t)p[3] << 24;
}

static double now_s(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

static int write_control(int value)
{
	int fd = open(CONTROL_PATH, O_WRONLY | O_CLOEXEC);
	int ret;

	if (fd < 0)
		return -errno;
	ret = write(fd, value ? "1\n" : "0\n", 2) == 2 ? 0 : -errno;
	close(fd);
	return ret;
}

/* 1 = checksum matches, 0 = mismatch, -1 = header fields inconsistent */
static int payload_checksum(const uint8_t *p, size_t len)
{
	uint16_t csum = le16(p + 4), csum_inv = le16(p + 12);
	int32_t crc_len = (int32_t)le32(p + 8), crc_len_inv = (int32_t)le32(p + 16);
	uint32_t sum = 0;
	size_t words, i;

	if (csum_inv != (uint16_t)~csum || crc_len_inv != ~crc_len)
		return -1;
	if (crc_len <= 0 || 20 + (size_t)crc_len * 4 > len)
		return -1;
	words = (size_t)crc_len * 2;
	for (i = 0; i < words; i++)
		sum += le16(p + 20 + i * 2);
	return (uint16_t)(~sum + 1) == csum;
}

static int cmp_int16(const void *a, const void *b)
{
	return *(const int16_t *)a - *(const int16_t *)b;
}

static void build_reference(int nodes)
{
	int16_t column[MAX_REF];
	int n, k;

	for (n = 0; n < nodes; n++) {
		for (k = 0; k < ref_count; k++)
			column[k] = ref_samples[k][n];
		qsort(column, ref_count, sizeof(column[0]), cmp_int16);
		reference[n] = column[ref_count / 2];
	}
	have_reference = 1;
	fprintf(stderr, "reference ready (%d frames of type %d, %dx%d)\n",
		ref_count, ref_type, st.rows, st.cols);
}

static void print_map(void)
{
	static const char ramp[] = " .:-=+*#%@";
	int r, c, level;

	printf("\033[H\033[2J");
	for (r = 0; r < st.rows; r++) {
		for (c = 0; c < st.cols; c++) {
			int d = delta[r * st.cols + c];

			level = d <= 0 ? 0 : d * 9 / (opt.threshold * 3);
			if (d > 0 && level == 0 && d >= opt.threshold / 2)
				level = 1;
			putchar(ramp[level > 9 ? 9 : level]);
		}
		putchar('\n');
	}
	printf("max delta %d (threshold %d)\n", st.max_delta, opt.threshold);
	fflush(stdout);
}

struct point {
	double x, y;	/* column, row in sensor pitch units */
	int peak;
};

static int find_points(struct point *pts)
{
	int r, c, dr, dc, n = 0;

	for (r = 0; r < st.rows; r++) {
		for (c = 0; c < st.cols; c++) {
			int v = delta[r * st.cols + c], is_peak = 1;
			double sw = 0, sx = 0, sy = 0;

			if (v < opt.threshold)
				continue;
			for (dr = -1; dr <= 1 && is_peak; dr++)
				for (dc = -1; dc <= 1; dc++) {
					int rr = r + dr, cc = c + dc;

					if ((!dr && !dc) || rr < 0 || cc < 0 ||
					    rr >= st.rows || cc >= st.cols)
						continue;
					/* ties resolve to the first node */
					if (delta[rr * st.cols + cc] > v ||
					    (delta[rr * st.cols + cc] == v &&
					     (dr < 0 || (dr == 0 && dc < 0)))) {
						is_peak = 0;
						break;
					}
				}
			if (!is_peak)
				continue;
			for (dr = -1; dr <= 1; dr++)
				for (dc = -1; dc <= 1; dc++) {
					int rr = r + dr, cc = c + dc, w;

					if (rr < 0 || cc < 0 || rr >= st.rows ||
					    cc >= st.cols)
						continue;
					w = delta[rr * st.cols + cc];
					if (w <= 0)
						continue;
					sw += w;
					sx += w * (cc + 0.5);
					sy += w * (rr + 0.5);
				}
			if (n < MAX_POINTS && sw > 0) {
				pts[n].x = sx / sw;
				pts[n].y = sy / sw;
				pts[n].peak = v;
				n++;
			}
		}
	}
	return n;
}

static int fb_open(void)
{
	struct fb_var_screeninfo var;
	struct fb_fix_screeninfo fix;
	int fd = open("/dev/fb0", O_RDWR | O_CLOEXEC);

	if (fd < 0)
		return -errno;
	if (ioctl(fd, FBIOGET_VSCREENINFO, &var) || ioctl(fd, FBIOGET_FSCREENINFO, &fix)) {
		close(fd);
		return -errno;
	}
	fb.width = var.xres;
	fb.height = var.yres;
	fb.bpp = var.bits_per_pixel;
	fb.stride = fix.line_length;
	fb.size = (size_t)fix.line_length * var.yres;
	if (fb.bpp != 32) {
		close(fd);
		return -ENOTSUP;
	}
	fb.mem = mmap(NULL, fb.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	close(fd);
	if (fb.mem == MAP_FAILED) {
		fb.mem = NULL;
		return -errno;
	}
	memset(fb.mem, 0, fb.size);
	return 0;
}

static void fb_dot(int x, int y, int radius, uint32_t color)
{
	int dx, dy;

	for (dy = -radius; dy <= radius; dy++)
		for (dx = -radius; dx <= radius; dx++) {
			int px = x + dx, py = y + dy;

			if (dx * dx + dy * dy > radius * radius ||
			    px < 0 || py < 0 || px >= (int)fb.width ||
			    py >= (int)fb.height)
				continue;
			memcpy(fb.mem + (size_t)py * fb.stride + px * 4, &color, 4);
		}
}

static void paint(const struct point *pts, int n)
{
	/* a8b8g8r8 in memory order R, G, B, A */
	static const uint32_t colors[] = {
		0xff0000ff, 0xff00ff00, 0xffff0000, 0xff00ffff, 0xffff00ff,
		0xffffff00, 0xffffffff, 0xff0080ff, 0xff8000ff, 0xff80ff00,
	};
	int i;

	for (i = 0; i < n; i++) {
		double u = pts[i].x / st.cols, v = pts[i].y / st.rows, t;

		if (opt.swap_xy) {
			t = u;
			u = v;
			v = t;
		}
		if (opt.flip_x)
			u = 1.0 - u;
		if (opt.flip_y)
			v = 1.0 - v;
		fb_dot((int)(u * fb.width), (int)(v * fb.height), 10,
		       colors[i % 10]);
	}
}

static void handle_frame(const uint8_t *frame, size_t len)
{
	static double last_print;
	const uint8_t *p;
	size_t plen, nodes;
	int type, rows, cols, n, csum;

	if (len < TRANSPORT_LEN + PAYLOAD_MIN) {
		st.short_payload++;
		return;
	}
	p = frame + TRANSPORT_LEN;
	plen = len - TRANSPORT_LEN;
	type = p[56];
	st.types[type]++;
	st.last_frame_no = le16(p + 28);
	csum = payload_checksum(p, plen);
	if (csum > 0)
		st.csum_ok++;
	else
		st.csum_bad++;

	if (opt.mode == MODE_DUMP) {
		printf("type=%d frame_no=%u cols=%u rows=%u csum=%s crc_len=%d ev=%02x %02x %02x %02x\n",
		       type, le16(p + 28), p[48], p[49],
		       csum > 0 ? "ok" : csum == 0 ? "BAD" : "inval",
		       (int32_t)le32(p + 8), frame[1], frame[2], frame[3], frame[4]);
		return;
	}

	cols = p[48];
	rows = p[49];
	nodes = (size_t)rows * cols;
	if (csum <= 0 || !nodes || nodes > MAX_NODES || 64 + nodes * 2 > plen)
		return;
	if (ref_type < 0) {
		/* lock onto the dominant non-pen matrix type */
		if (type == 6 || type == 7 || type == 9 || type == 0x1d)
			return;
		probe_types[type]++;
		if (++probe_count < TYPE_PROBE_FRAMES)
			return;
		for (n = 0; n < MAX_TYPES; n++)
			if (ref_type < 0 || probe_types[n] > probe_types[ref_type])
				ref_type = n;
		return;
	}
	if (type != ref_type)
		return;	/* other frame types (stylus, ...) */

	if (!have_reference) {
		if (!ref_count) {
			st.rows = rows;
			st.cols = cols;
		}
		if (rows != st.rows || cols != st.cols)
			return;
		for (n = 0; n < (int)nodes; n++)
			ref_samples[ref_count][n] = (int16_t)le16(p + 64 + n * 2);
		if (++ref_count >= opt.ref_frames)
			build_reference(nodes);
		return;
	}
	if (rows != st.rows || cols != st.cols)
		return;

	st.max_delta = 0;
	for (n = 0; n < (int)nodes; n++) {
		int d = (int16_t)le16(p + 64 + n * 2) - reference[n];

		delta[n] = opt.invert ? -d : d;
		if (delta[n] > st.max_delta)
			st.max_delta = delta[n];
	}

	if (opt.mode == MODE_MAP) {
		if (now_s() - last_print > 0.2) {
			print_map();
			last_print = now_s();
		}
	} else if (opt.mode == MODE_POINTS || opt.mode == MODE_PAINT) {
		struct point pts[MAX_POINTS];
		int i, count = find_points(pts);

		if (opt.mode == MODE_PAINT && fb.mem)
			paint(pts, count);
		if (count && now_s() - last_print > 0.1) {
			printf("frame %5u:", st.last_frame_no);
			for (i = 0; i < count; i++)
				printf("  [%d] col %.2f row %.2f peak %d", i,
				       pts[i].x, pts[i].y, pts[i].peak);
			putchar('\n');
			fflush(stdout);
			last_print = now_s();
		}
	}
}

static void print_stats(double elapsed)
{
	int t;

	printf("%6.1fs records %lu (bad magic %lu) valid-flag %lu checksum ok %lu bad %lu short %lu types:",
	       elapsed, st.records, st.bad_magic, st.flag_valid, st.csum_ok,
	       st.csum_bad, st.short_payload);
	for (t = 0; t < MAX_TYPES; t++)
		if (st.types[t])
			printf(" %d:%lu", t, st.types[t]);
	printf(" frame_no %u max_delta %d\n", st.last_frame_no, st.max_delta);
	fflush(stdout);
}

static void usage(void)
{
	fputs("usage: piano-touch-view [stats|map|points|paint|dump] [--seconds N]\n"
	      "       [--type N] [--threshold T] [--reference N] [--invert]\n"
	      "       [--swap-xy] [--flip-x] [--flip-y]\n", stderr);
	exit(2);
}

int main(int argc, char **argv)
{
	static uint8_t buf[1 << 20];
	size_t have = 0;
	double start, last_stats;
	const char *replay;
	int fd, i, ret;

	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "stats"))
			opt.mode = MODE_STATS;
		else if (!strcmp(argv[i], "map"))
			opt.mode = MODE_MAP;
		else if (!strcmp(argv[i], "points"))
			opt.mode = MODE_POINTS;
		else if (!strcmp(argv[i], "paint"))
			opt.mode = MODE_PAINT;
		else if (!strcmp(argv[i], "dump"))
			opt.mode = MODE_DUMP;
		else if (!strcmp(argv[i], "--seconds") && i + 1 < argc)
			opt.seconds = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--threshold") && i + 1 < argc)
			opt.threshold = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--reference") && i + 1 < argc)
			opt.ref_frames = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--type") && i + 1 < argc)
			opt.type = strtol(argv[++i], NULL, 0);
		else if (!strcmp(argv[i], "--invert"))
			opt.invert = 1;
		else if (!strcmp(argv[i], "--swap-xy"))
			opt.swap_xy = 1;
		else if (!strcmp(argv[i], "--flip-x"))
			opt.flip_x = 1;
		else if (!strcmp(argv[i], "--flip-y"))
			opt.flip_y = 1;
		else
			usage();
	}
	if (opt.threshold <= 0 || opt.ref_frames < 1 || opt.ref_frames > MAX_REF ||
	    opt.type >= MAX_TYPES)
		usage();
	ref_type = opt.type;

	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);

	if (opt.mode == MODE_PAINT) {
		ret = fb_open();
		if (ret)
			fprintf(stderr, "no framebuffer painting: %s\n", strerror(-ret));
	}

	replay = getenv("PIANO_THP_STREAM");
	fd = open(replay ? replay : STREAM_PATH, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
	if (fd < 0) {
		perror(replay ? replay : STREAM_PATH);
		return 1;
	}
	ret = replay ? 0 : write_control(1);
	if (ret) {
		fprintf(stderr, "%s: %s\n", CONTROL_PATH, strerror(-ret));
		return 1;
	}
	fprintf(stderr, "capturing; keep fingers off the screen for the reference\n");

	start = last_stats = now_s();
	while (running && (!opt.seconds || now_s() - start < opt.seconds)) {
		struct pollfd pfd = { .fd = fd, .events = POLLIN };
		ssize_t n;
		size_t off = 0;

		ret = poll(&pfd, 1, 200);
		if (ret < 0 && errno != EINTR)
			break;
		if (ret > 0 && (pfd.revents & POLLIN)) {
			n = read(fd, buf + have, sizeof(buf) - have);
			if (n > 0)
				have += n;
			else if (!n && replay && have < 32)
				running = 0;	/* end of the replayed file */
		}
		while (have - off >= 32) {
			const uint8_t *h = buf + off;
			uint16_t hlen = le16(h + 4), flen = le16(h + 6);

			if (le32(h) != STREAM_MAGIC || hlen < 32) {
				st.bad_magic++;
				off++;
				continue;
			}
			if (have - off < (size_t)hlen + flen)
				break;
			st.records++;
			if (le16(h + 26) & 1)
				st.flag_valid++;
			handle_frame(h + hlen, flen);
			off += hlen + flen;
		}
		memmove(buf, buf + off, have - off);
		have -= off;

		if (opt.mode == MODE_STATS && now_s() - last_stats >= 1.0) {
			print_stats(now_s() - start);
			last_stats = now_s();
		}
	}

	if (!replay)
		write_control(0);
	close(fd);
	print_stats(now_s() - start);
	return st.csum_ok ? 0 : 3;
}
