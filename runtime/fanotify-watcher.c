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

/*
 * json_escape_string — escape a string per RFC 8259 into dst.
 * Returns 0 on success, -1 if the escaped form would exceed dst_size
 * (including the NUL terminator).
 */
static int json_escape_string(const char *src, char *dst, size_t dst_size) {
  size_t di = 0;

  for (size_t si = 0; src[si] != '\0'; si++) {
    unsigned char ch = (unsigned char)src[si];
    const char *esc = NULL;
    char ubuf[7]; /* \uXXXX + NUL */
    size_t elen;

    switch (ch) {
    case '"':  esc = "\\\""; break;
    case '\\': esc = "\\\\"; break;
    case '\n': esc = "\\n";  break;
    case '\r': esc = "\\r";  break;
    case '\t': esc = "\\t";  break;
    case '\b': esc = "\\b";  break;
    case '\f': esc = "\\f";  break;
    default:
      if (ch < 0x20) {
        snprintf(ubuf, sizeof(ubuf), "\\u%04x", ch);
        esc = ubuf;
      }
      break;
    }

    if (esc) {
      elen = strlen(esc);
      if (di + elen >= dst_size)
        return -1;
      memcpy(dst + di, esc, elen);
      di += elen;
    } else {
      if (di + 1 >= dst_size)
        return -1;
      dst[di++] = (char)ch;
    }
  }

  dst[di] = '\0';
  return 0;
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
  char escaped_path[PATH_MAX * 6]; /* worst case: every byte → \uXXXX */

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
        if (plen <= 0 || plen >= (ssize_t)(sizeof(path_buf) - 1)) {
          /* readlink failed or path was truncated — skip this event */
          close(meta->fd);
          meta = FAN_EVENT_NEXT(meta, len);
          continue;
        }
        path_buf[plen] = '\0';

        if (json_escape_string(path_buf, escaped_path,
                               sizeof(escaped_path)) < 0) {
          fprintf(stderr,
                  "fanotify-watcher: path too long to escape, skipping\n");
          close(meta->fd);
          meta = FAN_EVENT_NEXT(meta, len);
          continue;
        }

        printf("{\"path\":\"%s\",\"pid\":%d}\n",
               escaped_path, (int)meta->pid);
        fflush(stdout);
        close(meta->fd);
      }

      meta = FAN_EVENT_NEXT(meta, len);
    }
  }

  close(fan_fd);
  return 0;
}
