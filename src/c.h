#ifndef MY_C_H
#define MY_C_H

#include <stdlib.h>
#include <unistd.h>
#include <termios.h>

#if defined(__APPLE__)
  #include <sys/ioctl.h>
  #include <sys/types.h>

  // Declare forkpty manually for macOS cross-compilation environments
  // where util.h might be missing from sysroot.
  pid_t forkpty(int *amaster, char *name, const struct termios *termp, const struct winsize *winp);

#elif defined(__OpenBSD__)
  #include <sys/types.h>
  #include <sys/ioctl.h>
  #include <util.h>

#elif defined(__FreeBSD__)
  #include <libutil.h>

#else
  #include <sys/ioctl.h>
  #include <pty.h>

#endif

#endif // MY_C_H
