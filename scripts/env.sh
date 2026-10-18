# Source to build for PS4: sets OPENORBIS/OO_PS4_TOOLCHAIN, PATH and the
# cross tools (PacBrew layout). The toolchain file (cmake/ps4.cmake under the
# SDK, used by openorbis-cmake) supplies all compile/link flags itself, so the
# generic CFLAGS/CXXFLAGS that ps4vars.sh exports are cleared: left set, their
# "-isystem <sdk>/include/c++/v1" demotes the toolchain's "-I .../c++/v1" and
# musl's <math.h> then shadows libc++'s wrapper (breaks <cmath>/<charconv>).
SRPS4_SDK="${SRPS4_SDK:-/home/claude/ps4sdk}"
. "$SRPS4_SDK/ps4vars.sh"
export SRPS4_PS4_CFLAGS="$CFLAGS" SRPS4_PS4_CXXFLAGS="$CXXFLAGS" SRPS4_PS4_LDFLAGS="$LDFLAGS"
unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS LIBS
