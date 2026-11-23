/* srps4_sdl_compat.h — SDL 2.0.22+ entry points missing from PacBrew's SDL 2.0.18.
 *
 * Force-included (-include) into a title's C sources on the console only, so
 * the title's code compiles unchanged. Declarations use the bare struct tags so
 * this header does not have to pull in SDL.h ahead of the title's own include. */
#ifndef SRPS4_SDL_COMPAT_H
#define SRPS4_SDL_COMPAT_H
#if SRPS4_CONSOLE
struct SDL_Window;
struct SDL_Renderer;
/* SDL_RenderGetWindow (2.0.22): the window a renderer was created for. */
struct SDL_Window *srps4_SDL_RenderGetWindow(struct SDL_Renderer *renderer);
#define SDL_RenderGetWindow srps4_SDL_RenderGetWindow
/* SDL_ResetHint (2.24): drop any value set in code, back to the environment's. */
int srps4_SDL_ResetHint(const char *name);
#define SDL_ResetHint srps4_SDL_ResetHint
#endif
#endif
