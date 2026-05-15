#include "ProGhosttyPTY.h"

#include <errno.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

int proghostty_spawn_pty(
  const char *path,
  char *const argv[],
  char *const envp[],
  const char *cwd,
  int rows,
  int cols,
  pid_t *pid_out,
  int *fd_out
) {
  if (path == NULL || argv == NULL || pid_out == NULL || fd_out == NULL) {
    return EINVAL;
  }

  struct winsize size;
  size.ws_row = rows > 0 ? (unsigned short)rows : 24;
  size.ws_col = cols > 0 ? (unsigned short)cols : 80;
  size.ws_xpixel = 0;
  size.ws_ypixel = 0;

  int master = -1;
  pid_t pid = forkpty(&master, NULL, NULL, &size);
  if (pid < 0) {
    return errno;
  }

  if (pid == 0) {
    if (cwd != NULL && cwd[0] != '\0') {
      (void)chdir(cwd);
    }
    execve(path, argv, envp);
    _exit(127);
  }

  *pid_out = pid;
  *fd_out = master;
  return 0;
}

int proghostty_resize_pty(int fd, int rows, int cols) {
  if (fd < 0) {
    return EBADF;
  }

  struct winsize size;
  size.ws_row = rows > 0 ? (unsigned short)rows : 24;
  size.ws_col = cols > 0 ? (unsigned short)cols : 80;
  size.ws_xpixel = 0;
  size.ws_ypixel = 0;

  if (ioctl(fd, TIOCSWINSZ, &size) < 0) {
    return errno;
  }
  return 0;
}

int proghostty_wait_pid(pid_t pid, int *exit_code, int *signal_code) {
  int status = 0;
  pid_t result = waitpid(pid, &status, WNOHANG);
  if (result == 0) {
    return 0;
  }
  if (result < 0) {
    return -errno;
  }

  if (exit_code != NULL) {
    *exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
  }
  if (signal_code != NULL) {
    *signal_code = WIFSIGNALED(status) ? WTERMSIG(status) : 0;
  }
  return 1;
}
