#ifndef PROGHOSTTY_PTY_H
#define PROGHOSTTY_PTY_H

#include <sys/types.h>

int proghostty_spawn_pty(
  const char *path,
  char *const argv[],
  char *const envp[],
  const char *cwd,
  int rows,
  int cols,
  pid_t *pid_out,
  int *fd_out
);

int proghostty_resize_pty(int fd, int rows, int cols);
int proghostty_wait_pid(pid_t pid, int *exit_code, int *signal_code);

#endif
