/* pam_gaze.c: PAM authentication module that lets Gaze approve `sudo` with a
 * face check instead of a password.
 *
 * Installed as `auth sufficient /usr/local/lib/pam/pam_gaze.so` in
 * /etc/pam.d/sudo_local. "sufficient" is what makes this safe to fail: whenever
 * this module returns PAM_IGNORE, PAM carries on to the normal password prompt
 * as if Gaze were not there. It only ever returns PAM_SUCCESS after Gaze itself
 * replied OK over its own socket; every error, timeout, malformed reply, or
 * sign of a non-interactive session falls through to PAM_IGNORE.
 *
 * Why each guard exists: malware running as the user could invoke sudo in the
 * background and hope the user nods without reading. So this module only asks
 * for approval when sudo is interactive in a real terminal (stdin is a tty in
 * sudo's own foreground process group and PAM_TTY is set), and it forwards the
 * exact command line so the Gaze panel can show the user what they are
 * approving; a command that does not fit carries a " [+more]" marker so Gaze
 * refuses it instead of approving half the story. Gaze itself re-checks the
 * peer before trusting any request.
 *
 * The socket path alone proves nothing: the same user could replace sudo.sock
 * with an impostor listener that answers OK to everything. So after
 * connecting, this module reads the listener's audit token
 * (LOCAL_PEERTOKEN) and requires its code signature to satisfy the designated
 * requirement stored in the root-owned file
 * /usr/local/lib/pam/pam_gaze.requirement (written by Gaze's installer as
 * root, mode 0444). Anything unverifiable falls through to PAM_IGNORE.
 */

#include <security/pam_modules.h>
#include <security/pam_appl.h>

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>

#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/un.h>

#include <bsm/audit.h>
#include <errno.h>
#include <fcntl.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define GAZE_SOCKET_REL "/Library/Application Support/Gaze/sudo.sock"
#define GAZE_REQUIREMENT_PATH "/usr/local/lib/pam/pam_gaze.requirement"
#define GAZE_REQUIREMENT_MAX 1024
#define GAZE_COMMAND_MAX 300
#define GAZE_MORE " [+more]"
#define GAZE_TIMEOUT_SEC 35
#define GAZE_PATH_MAX 1024
#define GAZE_PROCARGS_MAX 8192
#define GAZE_LINE_MAX 512
#define GAZE_TTY_MAX 64

/* Copies src into dst, replacing control characters with '?', capped at max
 * bytes (not counting the NUL). Always NUL-terminates. Returns the length. */
static size_t sanitize_copy(char *dst, const char *src, size_t max) {
	size_t len = 0;
	while (len < max && src[len] != '\0') {
		unsigned char c = (unsigned char)src[len];
		dst[len] = (c < 0x20 || c == 0x7f) ? '?' : src[len];
		len++;
	}
	dst[len] = '\0';
	return len;
}

/* Joins argv[1..argc-1] of this process with spaces into cmd (capped at
 * GAZE_COMMAND_MAX bytes, controls replaced with '?'). When the command does
 * not fit, the tail is replaced with the marker " [+more]" so Gaze can tell a
 * truncated command from a whole one and refuse it. Returns 0 on success. */
static int own_command(char *cmd) {
	int mib[3];
	mib[0] = CTL_KERN;
	mib[1] = KERN_PROCARGS2;
	mib[2] = getpid();
	size_t needed = 0;
	if (sysctl(mib, 3, NULL, &needed, NULL, 0) != 0) {
		return -1;
	}
	if (needed < sizeof(int) + 2 || needed > GAZE_PROCARGS_MAX) {
		return -1;
	}
	char *procargs = malloc(needed);
	if (procargs == NULL) {
		return -1;
	}
	size_t size = needed;
	if (sysctl(mib, 3, procargs, &size, NULL, 0) != 0) {
		free(procargs);
		return -1;
	}
	char *end = procargs + size;
	int argc = 0;
	memcpy(&argc, procargs, sizeof(argc));
	if (argc < 1) {
		free(procargs);
		return -1;
	}
	char *p = procargs + sizeof(int);
	while (p < end && *p != '\0') {
		p++;
	}
	if (p >= end) {
		free(procargs);
		return -1;
	}
	while (p < end && *p == '\0') {
		p++;
	}
	size_t len = 0;
	int cut = 0;
	cmd[0] = '\0';
	for (int i = 0; i < argc && p < end && !cut; i++) {
		char *s = p;
		while (p < end && *p != '\0') {
			p++;
		}
		if (p >= end) {
			free(procargs);
			return -1;
		}
		if (i > 0) {
			if (len < GAZE_COMMAND_MAX) {
				cmd[len++] = ' ';
			} else {
				cut = 1;
				break;
			}
			for (char *q = s; q < p; q++) {
				if (len >= GAZE_COMMAND_MAX) {
					cut = 1;
					break;
				}
				unsigned char c = (unsigned char)*q;
				cmd[len++] = (c < 0x20 || c == 0x7f) ? '?' : *q;
			}
			cmd[len] = '\0';
		}
		p++;
	}
	free(procargs);
	if (cut) {
		size_t mark = sizeof(GAZE_MORE) - 1;
		if (len + mark > GAZE_COMMAND_MAX) {
			len = GAZE_COMMAND_MAX - mark;
		}
		memcpy(cmd + len, GAZE_MORE, mark);
		len += mark;
		cmd[len] = '\0';
	}
	return 0;
}

/* Writes the whole buffer, retrying EINTR. Returns 0 on success. */
static int write_all(int fd, const char *buf, size_t count) {
	size_t done = 0;
	while (done < count) {
		ssize_t n = write(fd, buf + done, count - done);
		if (n < 0) {
			if (errno == EINTR) {
				continue;
			}
			return -1;
		}
		if (n == 0) {
			return -1;
		}
		done += (size_t)n;
	}
	return 0;
}

/* Reads one '\n'-terminated line (the '\n' is consumed, not stored) into resp,
 * which holds up to capacity bytes plus NUL. Returns the length, or -1 on
 * error, EOF before any byte, or a line that does not fit. */
static long read_line(int fd, char *resp, size_t capacity) {
	size_t len = 0;
	for (;;) {
		char c = 0;
		ssize_t n = read(fd, &c, 1);
		if (n < 0) {
			if (errno == EINTR) {
				continue;
			}
			return -1;
		}
		if (n == 0) {
			return -1;
		}
		if (c == '\n') {
			resp[len] = '\0';
			return (long)len;
		}
		if (len >= capacity) {
			return -1;
		}
		resp[len++] = c;
	}
}

/* Checks that the connected socket listener really is Gaze: takes the
 * listener's audit token and requires its code signature to satisfy the
 * designated requirement in the root-owned requirement file. The file must be
 * owned by uid 0 and not group/world writable, so the user cannot substitute
 * their own requirement. Returns 0 when verified, -1 otherwise. */
static int verify_listener(int fd) {
	audit_token_t token;
	memset(&token, 0, sizeof(token));
	socklen_t token_len = sizeof(token);
	if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &token_len) != 0) {
		return -1;
	}
	int reqfd = open(GAZE_REQUIREMENT_PATH, O_RDONLY);
	if (reqfd < 0) {
		return -1;
	}
	struct stat st;
	if (fstat(reqfd, &st) != 0) {
		close(reqfd);
		return -1;
	}
	if (!S_ISREG(st.st_mode) || st.st_uid != 0
		|| (st.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
		close(reqfd);
		return -1;
	}
	if (st.st_size <= 0 || st.st_size > GAZE_REQUIREMENT_MAX) {
		close(reqfd);
		return -1;
	}
	char reqbuf[GAZE_REQUIREMENT_MAX + 1];
	size_t got = 0;
	while (got < (size_t)st.st_size) {
		ssize_t n = read(reqfd, reqbuf + got, (size_t)st.st_size - got);
		if (n < 0) {
			if (errno == EINTR) {
				continue;
			}
			close(reqfd);
			return -1;
		}
		if (n == 0) {
			break;
		}
		got += (size_t)n;
	}
	close(reqfd);
	if (got != (size_t)st.st_size || got == 0) {
		return -1;
	}
	reqbuf[got] = '\0';

	CFDataRef token_data = CFDataCreate(kCFAllocatorDefault,
		(const UInt8 *)&token, sizeof(token));
	if (token_data == NULL) {
		return -1;
	}
	const void *keys[1];
	keys[0] = kSecGuestAttributeAudit;
	const void *values[1];
	values[0] = token_data;
	CFDictionaryRef attrs = CFDictionaryCreate(kCFAllocatorDefault, keys, values,
		1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFRelease(token_data);
	if (attrs == NULL) {
		return -1;
	}
	SecCodeRef code = NULL;
	OSStatus ok = SecCodeCopyGuestWithAttributes(NULL, attrs, kSecCSDefaultFlags,
		&code);
	CFRelease(attrs);
	if (ok != errSecSuccess || code == NULL) {
		return -1;
	}
	CFStringRef text = CFStringCreateWithBytes(kCFAllocatorDefault,
		(const UInt8 *)reqbuf, (CFIndex)got, kCFStringEncodingUTF8, false);
	if (text == NULL) {
		CFRelease(code);
		return -1;
	}
	SecRequirementRef requirement = NULL;
	ok = SecRequirementCreateWithString(text, kSecCSDefaultFlags, &requirement);
	CFRelease(text);
	if (ok != errSecSuccess || requirement == NULL) {
		CFRelease(code);
		return -1;
	}
	ok = SecCodeCheckValidity(code, kSecCSDefaultFlags, requirement);
	CFRelease(requirement);
	CFRelease(code);
	return (ok == errSecSuccess) ? 0 : -1;
}

int pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc, const char *argv[]) {
	(void)flags;
	(void)argc;
	(void)argv;
	if (pamh == NULL) {
		return PAM_IGNORE;
	}

	/* Only interactive sudo in a real terminal may skip the password. The
	 * foreground check keeps a background or hidden sudo on the password. */
	if (isatty(STDIN_FILENO) != 1) {
		return PAM_IGNORE;
	}
	if (tcgetpgrp(STDIN_FILENO) != getpgrp()) {
		return PAM_IGNORE;
	}
	const char *tty = NULL;
	if (pam_get_item(pamh, PAM_TTY, (const void **)&tty) != PAM_SUCCESS) {
		return PAM_IGNORE;
	}
	if (tty == NULL || tty[0] == '\0') {
		return PAM_IGNORE;
	}

	const char *user = NULL;
	if (pam_get_item(pamh, PAM_USER, (const void **)&user) != PAM_SUCCESS) {
		return PAM_IGNORE;
	}
	if (user == NULL || user[0] == '\0') {
		return PAM_IGNORE;
	}
	struct passwd *pw = getpwnam(user);
	if (pw == NULL || pw->pw_dir == NULL || pw->pw_dir[0] == '\0') {
		return PAM_IGNORE;
	}
	const char rel[] = GAZE_SOCKET_REL;
	size_t home_len = strlen(pw->pw_dir);
	if (home_len + sizeof(rel) > GAZE_PATH_MAX) {
		return PAM_IGNORE;
	}
	char path[GAZE_PATH_MAX];
	memcpy(path, pw->pw_dir, home_len);
	memcpy(path + home_len, rel, sizeof(rel));

	/* The socket must be the user's own: a planted socket elsewhere could
	 * answer OK to anything. */
	struct stat st;
	if (lstat(path, &st) != 0) {
		return PAM_IGNORE;
	}
	if (!S_ISSOCK(st.st_mode)) {
		return PAM_IGNORE;
	}
	if (st.st_uid != pw->pw_uid) {
		return PAM_IGNORE;
	}

	char cmd[GAZE_COMMAND_MAX + 1];
	if (own_command(cmd) != 0) {
		return PAM_IGNORE;
	}
	char tty_clean[GAZE_TTY_MAX + 1];
	sanitize_copy(tty_clean, tty, GAZE_TTY_MAX);

	int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0) {
		return PAM_IGNORE;
	}
	struct timeval tv;
	tv.tv_sec = GAZE_TIMEOUT_SEC;
	tv.tv_usec = 0;
	if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)) != 0
		|| setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv)) != 0) {
		close(fd);
		return PAM_IGNORE;
	}
	struct sockaddr_un addr;
	memset(&addr, 0, sizeof(addr));
	addr.sun_family = AF_UNIX;
	size_t path_len = strlen(path);
	if (path_len + 1 > sizeof(addr.sun_path)) {
		close(fd);
		return PAM_IGNORE;
	}
	memcpy(addr.sun_path, path, path_len + 1);
	if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
		close(fd);
		return PAM_IGNORE;
	}

	/* The path may be Gaze's, but the listener behind it may not be: require
	 * its code signature to match Gaze before saying anything. */
	if (verify_listener(fd) != 0) {
		close(fd);
		return PAM_IGNORE;
	}

	char line[GAZE_LINE_MAX];
	int n = snprintf(line, sizeof(line), "SUDO %s\t%s\n", tty_clean, cmd);
	if (n < 0) {
		close(fd);
		return PAM_IGNORE;
	}
	if ((size_t)n >= sizeof(line)) {
		/* Truncated: keep it one well-formed line so Gaze either reads a
		 * prefix of the command or rejects it; never a split message. */
		line[sizeof(line) - 2] = '\n';
		line[sizeof(line) - 1] = '\0';
		n = (int)sizeof(line) - 1;
	}
	if (write_all(fd, line, (size_t)n) != 0) {
		close(fd);
		return PAM_IGNORE;
	}

	char resp[16];
	long rlen = read_line(fd, resp, sizeof(resp) - 1);
	close(fd);
	if (rlen == 2 && resp[0] == 'O' && resp[1] == 'K') {
		return PAM_SUCCESS;
	}
	return PAM_IGNORE;
}

int pam_sm_setcred(pam_handle_t *pamh, int flags, int argc, const char *argv[]) {
	(void)pamh;
	(void)flags;
	(void)argc;
	(void)argv;
	return PAM_SUCCESS;
}

int pam_sm_acct_mgmt(pam_handle_t *pamh, int flags, int argc, const char *argv[]) {
	(void)pamh;
	(void)flags;
	(void)argc;
	(void)argv;
	return PAM_IGNORE;
}

int pam_sm_open_session(pam_handle_t *pamh, int flags, int argc, const char *argv[]) {
	(void)pamh;
	(void)flags;
	(void)argc;
	(void)argv;
	return PAM_IGNORE;
}

int pam_sm_close_session(pam_handle_t *pamh, int flags, int argc, const char *argv[]) {
	(void)pamh;
	(void)flags;
	(void)argc;
	(void)argv;
	return PAM_IGNORE;
}

int pam_sm_chauthtok(pam_handle_t *pamh, int flags, int argc, const char *argv[]) {
	(void)pamh;
	(void)flags;
	(void)argc;
	(void)argv;
	return PAM_IGNORE;
}
