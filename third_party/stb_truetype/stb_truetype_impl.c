/* Niobium build of stb_truetype without libc: every libc hook resolves to a
 * function exported by bindings.zig. Only freestanding compiler headers may be included. */

#include <stddef.h>

double nb_stbtt_floor(double x);
double nb_stbtt_ceil(double x);
double nb_stbtt_sqrt(double x);
double nb_stbtt_pow(double x, double y);
double nb_stbtt_fmod(double x, double y);
double nb_stbtt_cos(double x);
double nb_stbtt_acos(double x);
double nb_stbtt_fabs(double x);
void *nb_stbtt_malloc(unsigned long long size, void *user);
void nb_stbtt_free(void *ptr, void *user);
void nb_stbtt_assert_fail(void);
unsigned long long nb_stbtt_strlen(const char *s);

#define STBTT_ifloor(x) ((int)nb_stbtt_floor(x))
#define STBTT_iceil(x) ((int)nb_stbtt_ceil(x))
#define STBTT_sqrt(x) nb_stbtt_sqrt(x)
#define STBTT_pow(x, y) nb_stbtt_pow(x, y)
#define STBTT_fmod(x, y) nb_stbtt_fmod(x, y)
#define STBTT_cos(x) nb_stbtt_cos(x)
#define STBTT_acos(x) nb_stbtt_acos(x)
#define STBTT_fabs(x) nb_stbtt_fabs(x)
#define STBTT_malloc(x, u) nb_stbtt_malloc((unsigned long long)(x), (u))
#define STBTT_free(x, u) nb_stbtt_free((x), (u))
#define STBTT_assert(x) ((x) ? (void)0 : nb_stbtt_assert_fail())
#define STBTT_strlen(x) nb_stbtt_strlen(x)
#define STBTT_memcpy __builtin_memcpy
#define STBTT_memset __builtin_memset

#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"

int nb_stbtt_fontinfo_size(void) { return (int)sizeof(stbtt_fontinfo); }
