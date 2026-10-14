/*
 * Grab one JPEG from an MJPEG RTSP URL (RTP PT 26) using TCP interleaved.
 * Usage: rtsp-jpeg [rtsp://127.0.0.1:8554/mjpeg]
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>

#define MAX_JPEG (512 * 1024)
#define PKT 65536

struct url {
  char host[64];
  int port;
  char path[128];
};

static int parse_url(const char *u, struct url *o)
{
  const char *p, *slash, *colon;
  size_t hlen;
  memset(o, 0, sizeof(*o));
  o->port = 554;
  strcpy(o->path, "/");
  if (strncmp(u, "rtsp://", 7) != 0)
    return -1;
  p = u + 7;
  slash = strchr(p, '/');
  colon = strchr(p, ':');
  if (colon && (!slash || colon < slash)) {
    hlen = (size_t)(colon - p);
    o->port = atoi(colon + 1);
  } else {
    hlen = slash ? (size_t)(slash - p) : strlen(p);
  }
  if (hlen >= sizeof(o->host))
    hlen = sizeof(o->host) - 1;
  memcpy(o->host, p, hlen);
  o->host[hlen] = 0;
  if (slash)
    snprintf(o->path, sizeof(o->path), "%s", slash);
  return 0;
}

static int sendf(int fd, const char *fmt, ...)
{
  char buf[1024];
  va_list ap;
  int n;
  va_start(ap, fmt);
  n = vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);
  if (n < 0 || (size_t)n >= sizeof(buf))
    return -1;
  return send(fd, buf, (size_t)n, 0) == n ? 0 : -1;
}

static int read_line(int fd, char *line, size_t max)
{
  size_t n = 0;
  while (n + 1 < max) {
    char c;
    ssize_t r = recv(fd, &c, 1, 0);
    if (r <= 0)
      return -1;
    line[n++] = c;
    if (c == '\n')
      break;
  }
  line[n] = 0;
  return (int)n;
}

/* Read RTSP response; capture Session header into sess (optional). */
static int read_rtsp(int fd, int *code, char *sess, size_t sess_sz, char *body,
                     size_t body_sz)
{
  char line[512];
  int content_len = 0;
  *code = 0;
  if (sess && sess_sz)
    sess[0] = 0;
  if (read_line(fd, line, sizeof(line)) < 0)
    return -1;
  if (sscanf(line, "RTSP/%*s %d", code) != 1)
    return -1;
  for (;;) {
    if (read_line(fd, line, sizeof(line)) < 0)
      return -1;
    if (strcmp(line, "\r\n") == 0 || strcmp(line, "\n") == 0)
      break;
    if (!strncasecmp(line, "Content-Length:", 15))
      content_len = atoi(line + 15);
    if (sess && !strncasecmp(line, "Session:", 8))
      sscanf(line + 8, " %63[^;\r\n]", sess);
  }
  if (content_len > 0) {
    size_t got = 0;
    if ((size_t)content_len >= body_sz)
      return -1;
    while (got < (size_t)content_len) {
      ssize_t r = recv(fd, body + got, content_len - got, 0);
      if (r <= 0)
        return -1;
      got += (size_t)r;
    }
    body[content_len] = 0;
  } else if (body_sz)
    body[0] = 0;
  return 0;
}

/*
 * Strip RFC 2435 RTP JPEG header; return pointer/length of JPEG bytes.
 * SONiX embeds a full JPEG (starts with SOI) in the payload — just concatenate.
 */
static int jpeg_rtp_payload(const unsigned char *pay, size_t len,
                            const unsigned char **data, size_t *data_len,
                            unsigned *frag_off)
{
  unsigned type, q;
  size_t off = 8;

  if (len < 8)
    return -1;
  *frag_off = ((unsigned)pay[1] << 16) | ((unsigned)pay[2] << 8) | pay[3];
  type = pay[4];
  q = pay[5];

  if (type >= 64 && type <= 127) {
    if (len < off + 4)
      return -1;
    off += 4;
  }
  /* Quantization table header only on first fragment when q >= 128 */
  if (q >= 128 && *frag_off == 0) {
    unsigned qlen;
    if (len < off + 4)
      return -1;
    qlen = ((unsigned)pay[off + 2] << 8) | pay[off + 3];
    off += 4;
    if (off + qlen > len)
      return -1;
    off += qlen;
  }
  *data = pay + off;
  *data_len = len - off;
  return 0;
}

int main(int argc, char **argv)
{
  const char *urlstr = argc > 1 ? argv[1] : "rtsp://127.0.0.1:8554/mjpeg";
  struct url u;
  int fd, cseq = 1, code;
  char body[4096], session[64], control[128] = "track1";
  unsigned char jpeg[MAX_JPEG];
  size_t jpeg_len = 0;
  int collecting = 0, loops = 0;
  char *p;

  if (parse_url(urlstr, &u) < 0) {
    fprintf(stderr, "bad url\n");
    return 2;
  }

  fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) {
    perror("socket");
    return 1;
  }
  {
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = htons((uint16_t)u.port);
    if (!inet_aton(u.host, &sa.sin_addr)) {
      fprintf(stderr, "bad host\n");
      return 1;
    }
    if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
      perror("connect");
      return 1;
    }
  }

  sendf(fd, "DESCRIBE %s RTSP/1.0\r\nCSeq: %d\r\nAccept: application/sdp\r\n\r\n",
        urlstr, cseq++);
  if (read_rtsp(fd, &code, NULL, 0, body, sizeof(body)) < 0 || code != 200) {
    fprintf(stderr, "DESCRIBE %d\n", code);
    return 1;
  }
  p = strstr(body, "m=video");
  if (p) {
    char *c = strstr(p, "a=control:");
    if (c) {
      sscanf(c + 10, "%127s", control);
      {
        char *t = control;
        while (*t && *t != '\r' && *t != '\n')
          t++;
        *t = 0;
      }
    }
  }

  {
    char setup_url[256];
    if (!strncmp(control, "rtsp://", 7))
      snprintf(setup_url, sizeof(setup_url), "%s", control);
    else if (control[0] == '/')
      snprintf(setup_url, sizeof(setup_url), "rtsp://%s:%d%s", u.host, u.port,
               control);
    else
      snprintf(setup_url, sizeof(setup_url), "%s/%s", urlstr, control);
    sendf(fd,
          "SETUP %s RTSP/1.0\r\nCSeq: %d\r\n"
          "Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n\r\n",
          setup_url, cseq++);
  }
  if (read_rtsp(fd, &code, session, sizeof(session), body, sizeof(body)) < 0 ||
      code != 200 || !session[0]) {
    fprintf(stderr, "SETUP %d sess=%s\n", code, session);
    return 1;
  }

  sendf(fd, "PLAY %s RTSP/1.0\r\nCSeq: %d\r\nSession: %s\r\n\r\n", urlstr, cseq++,
        session);
  /* LIVE555 may emit interleaved RTP before the PLAY response — do not block
   * on a pure RTSP read here; demux below. */

  while (loops++ < 800) {
    unsigned char h4[4], pkt[PKT];
    unsigned ch, plen, pt, marker, cc;
    const unsigned char *pay;
    size_t paylen;
    ssize_t r;
    size_t got;
    fd_set fds;
    struct timeval tv;

    FD_ZERO(&fds);
    FD_SET(fd, &fds);
    tv.tv_sec = 2;
    tv.tv_usec = 0;
    if (select(fd + 1, &fds, NULL, NULL, &tv) <= 0)
      continue;

    r = recv(fd, h4, 1, 0);
    if (r <= 0)
      break;
    if (h4[0] != '$') {
      /* Drain an RTSP response (e.g. PLAY 200) that arrived mid-stream */
      char line[512];
      int content_len = 0;
      line[0] = (char)h4[0];
      if (read_line(fd, line + 1, sizeof(line) - 1) < 0)
        break;
      for (;;) {
        if (read_line(fd, line, sizeof(line)) < 0)
          goto fail;
        if (strcmp(line, "\r\n") == 0 || strcmp(line, "\n") == 0)
          break;
        if (!strncasecmp(line, "Content-Length:", 15))
          content_len = atoi(line + 15);
      }
      while (content_len > 0) {
        char tmp[256];
        int chunk = content_len > (int)sizeof(tmp) ? (int)sizeof(tmp) : content_len;
        r = recv(fd, tmp, (size_t)chunk, 0);
        if (r <= 0)
          goto fail;
        content_len -= (int)r;
      }
      continue;
    }
    got = 0;
    while (got < 3) {
      r = recv(fd, h4 + 1 + got, 3 - got, 0);
      if (r <= 0)
        goto fail;
      got += (size_t)r;
    }
    ch = h4[1];
    plen = ((unsigned)h4[2] << 8) | h4[3];
    if (plen > sizeof(pkt))
      goto fail;
    got = 0;
    while (got < plen) {
      r = recv(fd, pkt + got, plen - got, 0);
      if (r <= 0)
        goto fail;
      got += (size_t)r;
    }
    if (ch != 0 || plen < 12)
      continue;
    pt = pkt[1] & 0x7f;
    marker = pkt[1] & 0x80;
    cc = pkt[0] & 0x0f;
    if (plen < 12 + 4 * cc)
      continue;
    pay = pkt + 12 + 4 * cc;
    paylen = plen - 12 - 4 * cc;
    if (pt != 26)
      continue;

    {
      const unsigned char *jdata;
      size_t jlen;
      unsigned foff;
      if (jpeg_rtp_payload(pay, paylen, &jdata, &jlen, &foff) < 0)
        continue;
      if (!collecting) {
        if (foff != 0)
          continue;
        if (jlen < 2 || jdata[0] != 0xff || jdata[1] != 0xd8)
          continue;
        if (jlen > sizeof(jpeg))
          goto fail;
        memcpy(jpeg, jdata, jlen);
        jpeg_len = jlen;
        collecting = 1;
      } else {
        if (jpeg_len + jlen > sizeof(jpeg))
          goto fail;
        memcpy(jpeg + jpeg_len, jdata, jlen);
        jpeg_len += jlen;
      }
    }

    if (marker && collecting && jpeg_len > 200) {
      if (!(jpeg[jpeg_len - 2] == 0xff && jpeg[jpeg_len - 1] == 0xd9)) {
        if (jpeg_len + 2 <= sizeof(jpeg)) {
          jpeg[jpeg_len++] = 0xff;
          jpeg[jpeg_len++] = 0xd9;
        }
      }
      fwrite(jpeg, 1, jpeg_len, stdout);
      fflush(stdout);
      sendf(fd, "TEARDOWN %s RTSP/1.0\r\nCSeq: %d\r\nSession: %s\r\n\r\n", urlstr,
            cseq++, session);
      close(fd);
      return 0;
    }
  }

fail:
  fprintf(stderr, "no frame\n");
  close(fd);
  return 1;
}
