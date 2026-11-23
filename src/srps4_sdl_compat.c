/* srps4_sdl_compat.c — see srps4_sdl_compat.h.
 *
 * SDL 2.0.18 keeps the renderer's window in a private struct, so the mapping is
 * recorded when the renderer is made: SDL_CreateRenderer is wrapped
 * (--wrap=SDL_CreateRenderer) and each successful (renderer, window) pair is
 * kept in a small table. Titles create one or two renderers in their lifetime. */
#if SRPS4_CONSOLE
#include <SDL2/SDL.h>

SDL_Renderer *__real_SDL_CreateRenderer(SDL_Window *window, int index, Uint32 flags);

enum { SRPS4_MAX_RENDERERS = 8 };
static struct { SDL_Renderer *r; SDL_Window *w; } s_pairs[SRPS4_MAX_RENDERERS];
static int s_next;

SDL_Renderer *__wrap_SDL_CreateRenderer(SDL_Window *window, int index, Uint32 flags) {
  SDL_Renderer *r = __real_SDL_CreateRenderer(window, index, flags);
  if (r) {
    s_pairs[s_next].r = r;
    s_pairs[s_next].w = window;
    s_next = (s_next + 1) % SRPS4_MAX_RENDERERS;
  }
  return r;
}

SDL_Window *srps4_SDL_RenderGetWindow(SDL_Renderer *renderer) {
  for (int i = 0; i < SRPS4_MAX_RENDERERS; i++)
    if (renderer && s_pairs[i].r == renderer) return s_pairs[i].w;
  SDL_SetError("srps4: renderer not created through SDL_CreateRenderer");
  return NULL;
}

int srps4_SDL_ResetHint(const char *name) {
  /* OVERRIDE replaces whatever priority the earlier value carried. */
  return SDL_SetHintWithPriority(name, SDL_getenv(name), SDL_HINT_OVERRIDE);
}
#endif
