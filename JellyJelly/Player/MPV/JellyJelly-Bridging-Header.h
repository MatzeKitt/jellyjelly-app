// The mpv headers only provide types and constants. libmpv itself is loaded
// at runtime (see LibMPV.swift), so the app builds and runs without it.
#include "mpv/client.h"
#include "mpv/render.h"
#include "mpv/render_gl.h"
