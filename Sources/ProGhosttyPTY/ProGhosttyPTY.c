#include "ProGhosttyPTY.h"

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

// execve uses the provided envp, not process environ — inject the key into a
// shallow copy (pointers into envp except the one PROGHOSTTY_NOTIFY_TTY entry).
static char **envp_with_notify_tty(char *const envp[], const char *tty_path) {
  if (envp == NULL || tty_path == NULL || tty_path[0] == '\0') {
    return NULL;
  }

  size_t count = 0;
  while (envp[count] != NULL) {
    count += 1;
  }

  char **copy = calloc(count + 2, sizeof(char *));
  if (copy == NULL) {
    return NULL;
  }

  const char *prefix = "PROGHOSTTY_NOTIFY_TTY=";
  const size_t prefix_len = strlen(prefix);
  const size_t entry_len = prefix_len + strlen(tty_path) + 1;
  char *entry = malloc(entry_len);
  if (entry == NULL) {
    free(copy);
    return NULL;
  }
  snprintf(entry, entry_len, "%s%s", prefix, tty_path);

  size_t out = 0;
  int replaced = 0;
  for (size_t i = 0; i < count; i++) {
    if (strncmp(envp[i], prefix, prefix_len) == 0) {
      copy[out++] = entry;
      replaced = 1;
    } else {
      copy[out++] = envp[i];
    }
  }
  if (!replaced) {
    copy[out++] = entry;
  }
  copy[out] = NULL;
  return copy;
}

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

  char slave_name[128];
  slave_name[0] = '\0';
  int master = -1;
  // forkpty fills slave_name with the path (e.g. /dev/ttys00N) for both sides.
  pid_t pid = forkpty(&master, slave_name, NULL, &size);
  if (pid < 0) {
    return errno;
  }

  if (pid == 0) {
    if (cwd != NULL && cwd[0] != '\0') {
      (void)chdir(cwd);
    }
    // Inject concrete slave path so Stop hooks / `pg notify` need not open /dev/tty.
    char **owned = envp_with_notify_tty(envp, slave_name);
    execve(path, argv, owned != NULL ? owned : envp);
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
