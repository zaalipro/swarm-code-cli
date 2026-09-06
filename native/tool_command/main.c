/* Owned POSIX shell job guardian. Original CLI implementation, MIT.
 * argv: timeout_ms command. cwd/environment inherited from the daemon Port.
 * stdin EOF cancels. stdout is packet4: D + bytes, X + uint32 status,
 * T (deadline), E + text. The session leader is retained as a zombie until
 * its process group has been signalled, preventing PGID reuse during cleanup.
 * Commands that deliberately create a separate session/group are unsupported.
 */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/prctl.h>
#endif

#define CAP 131072
static unsigned char queue[CAP];
static size_t queued = 0;
static volatile sig_atomic_t interrupted = 0;

static void interrupt_handler(int sig) { (void)sig; interrupted = 1; }
static int64_t now_ms(void) {
  struct timespec t;
  if (clock_gettime(CLOCK_MONOTONIC, &t) != 0) _exit(125);
  return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
static void u32(unsigned char *p, uint32_t value) {
  p[0] = (unsigned char)(value >> 24); p[1] = (unsigned char)(value >> 16);
  p[2] = (unsigned char)(value >> 8); p[3] = (unsigned char)value;
}
static void packet(unsigned char kind, const unsigned char *data, size_t size) {
  if (queued + size + 5 > CAP) _exit(125);
  u32(queue + queued, (uint32_t)(size + 1));
  queue[queued + 4] = kind;
  if (size) memcpy(queue + queued + 5, data, size);
  queued += size + 5;
}
static int nonblock(int fd) {
  int flags = fcntl(fd, F_GETFL);
  return flags < 0 ? -1 : fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}
static void close_pair(int pair[2]) { close(pair[0]); close(pair[1]); }

int main(int argc, char **argv) {
  if (argc != 3) return 125;
  char *end = NULL;
  long timeout = strtol(argv[1], &end, 10);
  if (!end || *end || timeout <= 0 || timeout > 600000) return 125;
  signal(SIGPIPE, SIG_IGN);
  struct sigaction action;
  memset(&action, 0, sizeof(action));
  action.sa_handler = interrupt_handler;
  sigemptyset(&action.sa_mask);
  sigaction(SIGTERM, &action, NULL);
  sigaction(SIGINT, &action, NULL);
#ifdef __linux__
  /* Adopt only our orphaned descendants so ordinary background jobs are reaped. */
  if (prctl(PR_SET_CHILD_SUBREAPER, 1) != 0) return 125;
#endif
  int output[2], ready[2], launch[2];
  if (pipe(output) < 0) return 125;
  if (pipe(ready) < 0) { close_pair(output); return 125; }
  if (pipe(launch) < 0) { close_pair(output); close_pair(ready); return 125; }
  pid_t child = fork();
  if (child < 0) { close_pair(output); close_pair(ready); close_pair(launch); return 125; }
  if (child == 0) {
    close(output[0]); close(ready[0]); close(launch[1]);
    signal(SIGTERM, SIG_DFL); signal(SIGINT, SIG_DFL); signal(SIGPIPE, SIG_DFL);
    if (setsid() < 0) _exit(125);
    int input = open("/dev/null", O_RDONLY);
    if (input < 0 || dup2(input, STDIN_FILENO) < 0 ||
        dup2(output[1], STDOUT_FILENO) < 0 || dup2(output[1], STDERR_FILENO) < 0) _exit(125);
    close(input); close(output[1]);
    if (write(ready[1], "R", 1) != 1) _exit(125);
    close(ready[1]);
    char go;
    if (read(launch[0], &go, 1) != 1 || go != 'G') _exit(125);
    close(launch[0]);
    execl("/bin/sh", "sh", "-c", argv[2], (char *)NULL);
    _exit(127);
  }
  close(output[1]); close(ready[1]); close(launch[0]);
  if (nonblock(output[0]) < 0 || nonblock(ready[0]) < 0 ||
      nonblock(STDIN_FILENO) < 0 || nonblock(STDOUT_FILENO) < 0) {
    kill(child, SIGKILL); waitpid(child, NULL, 0); return 125;
  }

  int group_ready = 0, output_eof = 0, terminal = 0, reaped = 0;
  int cancelled = 0, abandoned = 0, timed_out = 0, killed = 0, result_queued = 0;
  int credits = 4, final_ack = 0;
  unsigned char input_frame[5];
  size_t input_used = 0;
  int status = 0;
  int64_t deadline = now_ms() + timeout, kill_at = 0;
  int64_t output_idle_at = now_ms();
  for (;;) {
    int64_t now = now_ms();
    if (credits == 0 || queued > 0) output_idle_at = now;
    if (interrupted) { cancelled = 1; abandoned = 1; }
    if (now >= deadline && !terminal) timed_out = 1;
    if (!terminal) {
      siginfo_t info;
      memset(&info, 0, sizeof(info));
      if (waitid(P_PID, child, &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_pid == child)
        terminal = 1;
    }
    if ((terminal || cancelled || timed_out) && kill_at == 0) {
      if (group_ready) kill(-child, SIGTERM);
      else kill(child, SIGTERM);
      kill_at = now + 100;
    }
    if (kill_at && now >= kill_at && !killed) {
      if (group_ready) kill(-child, SIGKILL);
      else kill(child, SIGKILL);
      killed = 1;
    }
    if (killed && !reaped) {
      pid_t result = waitpid(child, &status, WNOHANG);
      if (result == child) reaped = 1;
    }
    if (reaped) {
#ifdef __linux__
      while (waitpid(-1, NULL, WNOHANG) > 0) {}
#endif
      if (abandoned) break;
      /* A deliberately escaped child retaining stdout cannot block completion. */
      if (!output_eof && now >= output_idle_at + 500) { close(output[0]); output_eof = 1; }
      if (output_eof && !result_queued && queued <= CAP - 16) {
        if (cancelled) packet('C', NULL, 0);
        else if (timed_out) packet('T', NULL, 0);
        else {
          unsigned char code[4];
          u32(code, WIFEXITED(status) ? (uint32_t)WEXITSTATUS(status) : (uint32_t)(128 + WTERMSIG(status)));
          packet('X', code, 4);
        }
        result_queued = 1;
      }
      if (result_queued && queued == 0 && final_ack) break;
    }
    struct pollfd fds[4] = {
      {STDIN_FILENO, POLLIN, 0},
      {output_eof ? -1 : output[0], (cancelled || credits > 0) && queued < CAP - 8197 ? POLLIN : 0, 0},
      {STDOUT_FILENO, queued ? POLLOUT : 0, 0},
      {group_ready ? -1 : ready[0], POLLIN, 0}
    };
    int result = poll(fds, 4, 20);
    if (result < 0 && errno != EINTR) { cancelled = 1; abandoned = 1; }
    if (fds[0].revents & (POLLIN | POLLHUP | POLLERR)) {
      unsigned char input[64];
      ssize_t n = read(STDIN_FILENO, input, sizeof(input));
      if (n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR)) {
        cancelled = 1; abandoned = 1;
      }
      for (ssize_t i = 0; i < n; i++) {
        input_frame[input_used++] = input[i];
        if (input_used == 5) {
          if (memcmp(input_frame, "\0\0\0\1", 4) != 0) {
            cancelled = 1; abandoned = 1;
          } else if (input_frame[4] == 'A' && credits < 4) {
            credits++;
          } else if (input_frame[4] == 'F' && result_queued) {
            final_ack = 1;
          } else if (input_frame[4] == 'C') {
            cancelled = 1;
          } else {
            cancelled = 1; abandoned = 1;
          }
          input_used = 0;
        }
      }
    }
    if (!group_ready && (fds[3].revents & (POLLIN | POLLHUP))) {
      char r;
      if (read(ready[0], &r, 1) == 1 && r == 'R') {
        group_ready = 1;
        if (!cancelled && !timed_out && !kill_at) {
          if (write(launch[1], "G", 1) != 1) cancelled = 1;
        }
        close(launch[1]);
        launch[1] = -1;
      }
      /* EOF before R means the child failed before opening a session. */
    }
    if (!output_eof && (cancelled || credits > 0) && queued < CAP - 8197 && (fds[1].revents & (POLLIN | POLLHUP))) {
      unsigned char data[8192];
      ssize_t n = read(output[0], data, sizeof(data));
      if (n > 0) {
        output_idle_at = now_ms();
        if (!cancelled) { packet('D', data, (size_t)n); credits--; }
      }
      else if (n == 0 || (errno != EAGAIN && errno != EINTR)) { close(output[0]); output_eof = 1; }
    }
    if (queued && (fds[2].revents & (POLLOUT | POLLHUP | POLLERR))) {
      ssize_t n = write(STDOUT_FILENO, queue, queued);
      if (n > 0) { memmove(queue, queue + n, queued - (size_t)n); queued -= (size_t)n; }
      else if (n < 0 && errno != EAGAIN && errno != EINTR) { cancelled = 1; abandoned = 1; }
    }
  }
  close(ready[0]);
  if (launch[1] >= 0) close(launch[1]);
  if (!output_eof) close(output[0]);
  return 0;
}
