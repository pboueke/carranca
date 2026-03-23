/*
 * fanotify-watcher.c — monitor file reads via fanotify, emit JSON to stdout
 *
 * Usage: fanotify-watcher /path1 [/path2 ...]
 * Requires CAP_SYS_ADMIN.
 */
#include <sys/fanotify.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <errno.h>
#include <limits.h>

static volatile int running = 1;

static void handle_signal(int sig) {
  (void)sig;
  running = 0;
}

int main(int argc, char *argv[]) {
  if (argc < 2) {
    fprintf(stderr, "Usage: %s <path> [<path> ...]\n", argv[0]);
    return 1;
  }

  signal(SIGTERM, handle_signal);
  signal(SIGINT, handle_signal);

  int fan_fd = fanotify_init(FAN_CLASS_NOTIF, O_RDONLY);
  if (fan_fd < 0) {
    if (errno == EPERM) {
      fprintf(stderr, "fanotify-watcher: permission denied (need CAP_SYS_ADMIN)\n");
    } else {
      fprintf(stderr, "fanotify-watcher: fanotify_init failed: %s\n", strerror(errno));
    }
    return 1;
  }

  for (int i = 1; i < argc; i++) {
    if (fanotify_mark(fan_fd, FAN_MARK_ADD | FAN_MARK_MOUNT,
                      FAN_ACCESS, AT_FDCWD, argv[i]) < 0) {
      fprintf(stderr, "fanotify-watcher: failed to mark %s: %s\n",
              argv[i], strerror(errno));
      close(fan_fd);
      return 1;
    }
  }

  char buf[4096];
  char path_buf[PATH_MAX];

  while (running) {
    ssize_t len = read(fan_fd, buf, sizeof(buf));
    if (len <= 0) {
      if (len < 0 && errno == EINTR)
        continue;
      break;
    }

    struct fanotify_event_metadata *meta =
        (struct fanotify_event_metadata *)buf;

    while (FAN_EVENT_OK(meta, len)) {
      if (meta->vers != FANOTIFY_METADATA_VERSION) {
        fprintf(stderr, "fanotify-watcher: version mismatch\n");
        break;
      }

      if ((meta->mask & FAN_ACCESS) && meta->fd >= 0) {
        char fd_path[64];
        snprintf(fd_path, sizeof(fd_path), "/proc/self/fd/%d", meta->fd);
        ssize_t plen = readlink(fd_path, path_buf, sizeof(path_buf) - 1);
        if (plen > 0) {
          path_buf[plen] = '\0';
          printf("{\"path\":\"%s\",\"pid\":%d}\n", path_buf, (int)meta->pid);
          fflush(stdout);
        }
        close(meta->fd);
      }

      meta = FAN_EVENT_NEXT(meta, len);
    }
  }

  close(fan_fd);
  return 0;
}
