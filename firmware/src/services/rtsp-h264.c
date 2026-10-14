/*
 * Dump H.264 from RTSP to stdout as Annex-B.
 * Default transport: UDP (TCP interleaved is unreliable on this LIVE555 build).
 * Usage: rtsp-h264 [-t seconds] [rtsp://127.0.0.1:554/unicast]
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
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#define PKT 65536
#define MAX_NAL (512 * 1024)

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
    fd_set fds;
    struct timeval tv = {5, 0};
    FD_ZERO(&fds);
    FD_SET(fd, &fds);
    if (select(fd + 1, &fds, NULL, NULL, &tv) <= 0)
      return -1;
    if (recv(fd, &c, 1, 0) <= 0)
      return -1;
    line[n++] = c;
    if (c == '\n')
      break;
  }
  line[n] = 0;
  return (int)n;
}

static int read_rtsp(int fd, int *code, char *sess, size_t sess_sz, char *body,
                     size_t body_sz, char *headers, size_t headers_sz)
{
  char line[512];
  int content_len = 0;
  size_t hlen = 0;
  *code = 0;
  if (sess && sess_sz)
    sess[0] = 0;
  if (headers && headers_sz)
    headers[0] = 0;
  if (read_line(fd, line, sizeof(line)) < 0)
    return -1;
  if (sscanf(line, "RTSP/%*s %d", code) != 1)
    return -1;
  for (;;) {
    if (read_line(fd, line, sizeof(line)) < 0)
      return -1;
    if (strcmp(line, "\r\n") == 0 || strcmp(line, "\n") == 0)
      break;
    if (headers && hlen + strlen(line) + 1 < headers_sz) {
      memcpy(headers + hlen, line, strlen(line));
      hlen += strlen(line);
      headers[hlen] = 0;
    }
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
      fd_set fds;
      struct timeval tv = {5, 0};
      ssize_t r;
      FD_ZERO(&fds);
      FD_SET(fd, &fds);
      if (select(fd + 1, &fds, NULL, NULL, &tv) <= 0)
        return -1;
      r = recv(fd, body + got, content_len - got, 0);
      if (r <= 0)
        return -1;
      got += (size_t)r;
    }
    body[content_len] = 0;
  } else if (body_sz)
    body[0] = 0;
  return 0;
}

static void write_start_code(void)
{
  static const unsigned char sc[] = {0, 0, 0, 1};
  fwrite(sc, 1, 4, stdout);
}

static int b64_decode(const char *in, unsigned char *out, size_t out_max)
{
  static const char *tbl =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  size_t o = 0;
  int val = 0, valb = -8;
  for (; *in && *in != ',' && *in != ';' && *in != ' ' && *in != '\r'; in++) {
    const char *p = strchr(tbl, *in);
    if (!p)
      break;
    val = (val << 6) + (int)(p - tbl);
    valb += 6;
    if (valb >= 0) {
      if (o >= out_max)
        return -1;
      out[o++] = (unsigned char)((val >> valb) & 0xff);
      valb -= 8;
    }
  }
  return (int)o;
}

static void emit_sprop(const char *sdp)
{
  const char *p = strstr(sdp, "sprop-parameter-sets=");
  if (!p)
    return;
  p += 21;
  while (*p) {
    unsigned char nal[512];
    int n = b64_decode(p, nal, sizeof(nal));
    if (n > 0) {
      write_start_code();
      fwrite(nal, 1, (size_t)n, stdout);
    }
    p = strchr(p, ',');
    if (!p)
      break;
    p++;
  }
  fflush(stdout);
}

static void handle_h264_payload(const unsigned char *pay, size_t paylen,
                                unsigned char *nalbuf, size_t *nal_len,
                                int *collecting_fu)
{
  unsigned nal_type;
  if (paylen < 1)
    return;
  nal_type = pay[0] & 0x1f;
  if (nal_type >= 1 && nal_type <= 23) {
    write_start_code();
    fwrite(pay, 1, paylen, stdout);
    *collecting_fu = 0;
    *nal_len = 0;
  } else if (nal_type == 28 && paylen >= 2) {
    unsigned fu_h = pay[1];
    unsigned start = fu_h & 0x80;
    unsigned end = fu_h & 0x40;
    unsigned type = fu_h & 0x1f;
    if (start) {
      *nal_len = 0;
      nalbuf[(*nal_len)++] = (pay[0] & 0xe0) | type;
      *collecting_fu = 1;
    }
    if (!*collecting_fu)
      return;
    if (*nal_len + (paylen - 2) > MAX_NAL) {
      *collecting_fu = 0;
      *nal_len = 0;
      return;
    }
    memcpy(nalbuf + *nal_len, pay + 2, paylen - 2);
    *nal_len += paylen - 2;
    if (end) {
      write_start_code();
      fwrite(nalbuf, 1, *nal_len, stdout);
      *collecting_fu = 0;
      *nal_len = 0;
    }
  } else if (nal_type == 24) {
    size_t off = 1;
    while (off + 2 <= paylen) {
      unsigned sz = ((unsigned)pay[off] << 8) | pay[off + 1];
      off += 2;
      if (off + sz > paylen)
        break;
      write_start_code();
      fwrite(pay + off, 1, sz, stdout);
      off += sz;
    }
  }
  fflush(stdout);
}

static int bind_udp_pair(int *rtp_fd, int *rtcp_fd, int *port)
{
  int p;
  for (p = 20000; p < 40000; p += 2) {
    struct sockaddr_in sa;
    int a = socket(AF_INET, SOCK_DGRAM, 0);
    int b = socket(AF_INET, SOCK_DGRAM, 0);
    int yes = 1;
    if (a < 0 || b < 0)
      return -1;
    setsockopt(a, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    setsockopt(b, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = htonl(INADDR_ANY);
    sa.sin_port = htons((uint16_t)p);
    if (bind(a, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
      close(a);
      close(b);
      continue;
    }
    sa.sin_port = htons((uint16_t)(p + 1));
    if (bind(b, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
      close(a);
      close(b);
      continue;
    }
    *rtp_fd = a;
    *rtcp_fd = b;
    *port = p;
    return 0;
  }
  return -1;
}

int main(int argc, char **argv)
{
  const char *urlstr = "rtsp://127.0.0.1:554/unicast";
  int seconds = 300, opt, cseq = 1, code, fd;
  int rtp_fd = -1, rtcp_fd = -1, client_port = 0;
  struct url u;
  char body[4096], session[64], control[128] = "track1", hdrs[1024];
  char *p;
  time_t end;
  unsigned char nalbuf[MAX_NAL];
  size_t nal_len = 0;
  int collecting_fu = 0;
  int got_media = 0;
  unsigned udp_pkts = 0;

  while ((opt = getopt(argc, argv, "t:h")) != -1) {
    switch (opt) {
    case 't':
      seconds = atoi(optarg);
      break;
    default:
      fprintf(stderr, "Usage: %s [-t seconds] [rtsp-url]\n", argv[0]);
      return 2;
    }
  }
  if (optind < argc)
    urlstr = argv[optind];
  if (seconds < 1)
    seconds = 1;

  if (parse_url(urlstr, &u) < 0) {
    fprintf(stderr, "bad url\n");
    return 2;
  }
  if (bind_udp_pair(&rtp_fd, &rtcp_fd, &client_port) < 0) {
    fprintf(stderr, "udp bind failed\n");
    return 1;
  }

  fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) {
    perror("socket");
    return 1;
  }
  {
    struct sockaddr_in sa;
    struct timeval tv = {8, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
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
  if (read_rtsp(fd, &code, NULL, 0, body, sizeof(body), NULL, 0) < 0 ||
      code != 200) {
    fprintf(stderr, "DESCRIBE %d\n", code);
    return 1;
  }
  emit_sprop(body);
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

  /* SETUP video (track1) + audio (track2) — LIVE555 often withholds media until all tracks are set up */
  {
    char setup_url[256];
    int a_rtp = -1, a_rtcp = -1, a_port = 0;
    if (!strncmp(control, "rtsp://", 7))
      snprintf(setup_url, sizeof(setup_url), "%s", control);
    else if (control[0] == '/')
      snprintf(setup_url, sizeof(setup_url), "rtsp://%s:%d%s", u.host, u.port, control);
    else
      snprintf(setup_url, sizeof(setup_url), "%s/%s", urlstr, control);
    sendf(fd,
          "SETUP %s RTSP/1.0\r\nCSeq: %d\r\n"
          "Transport: RTP/AVP;unicast;client_port=%d-%d\r\n\r\n",
          setup_url, cseq++, client_port, client_port + 1);
    if (read_rtsp(fd, &code, session, sizeof(session), body, sizeof(body), hdrs,
                  sizeof(hdrs)) < 0 || code != 200 || !session[0]) {
      fprintf(stderr, "SETUP video %d\n", code);
      return 1;
    }
    fprintf(stderr, "SETUP video ok\n%s\n", hdrs);
    /* audio track */
    if (bind_udp_pair(&a_rtp, &a_rtcp, &a_port) == 0) {
      char aurl[256];
      snprintf(aurl, sizeof(aurl), "%s/track2", urlstr);
      sendf(fd,
            "SETUP %s RTSP/1.0\r\nCSeq: %d\r\nSession: %s\r\n"
            "Transport: RTP/AVP;unicast;client_port=%d-%d\r\n\r\n",
            aurl, cseq++, session, a_port, a_port + 1);
      if (read_rtsp(fd, &code, session, sizeof(session), body, sizeof(body), hdrs,
                    sizeof(hdrs)) < 0 || code != 200) {
        fprintf(stderr, "SETUP audio %d (continuing)\n", code);
      } else {
        fprintf(stderr, "SETUP audio ok\n%s\n", hdrs);
      }
      /* keep sockets open so ports stay reserved; ignore audio payload */
      (void)a_rtp;
      (void)a_rtcp;
    }
  }

  sendf(fd, "PLAY %s RTSP/1.0\r\nCSeq: %d\r\nSession: %s\r\n\r\n", urlstr, cseq++,
        session);
  /* Drain PLAY response if present */
  {
    fd_set fds;
    struct timeval tv = {2, 0};
    FD_ZERO(&fds);
    FD_SET(fd, &fds);
    if (select(fd + 1, &fds, NULL, NULL, &tv) > 0) {
      if (read_rtsp(fd, &code, NULL, 0, body, sizeof(body), hdrs, sizeof(hdrs)) == 0)
        fprintf(stderr, "PLAY %d\n%s\n", code, hdrs);
    } else {
      fprintf(stderr, "PLAY no immediate response\n");
    }
  }
  fprintf(stderr, "listening udp %d\n", client_port);

  end = time(NULL) + seconds;
  while (time(NULL) < end) {
    unsigned char pkt[PKT];
    ssize_t r;
    fd_set fds;
    struct timeval tv;
    int remain = (int)(end - time(NULL));
    int maxfd;
    if (remain < 1)
      break;

    FD_ZERO(&fds);
    FD_SET(rtp_fd, &fds);
    FD_SET(fd, &fds);
    maxfd = rtp_fd > fd ? rtp_fd : fd;
    tv.tv_sec = remain > 2 ? 2 : remain;
    tv.tv_usec = 0;
    if (select(maxfd + 1, &fds, NULL, NULL, &tv) <= 0)
      continue;

    if (FD_ISSET(fd, &fds)) {
      /* ignore RTSP keepalives / errors */
      char tmp[256];
      if (recv(fd, tmp, sizeof(tmp), 0) <= 0) {
        /* RTSP socket closed — keep draining UDP briefly */
      }
    }
    if (!FD_ISSET(rtp_fd, &fds))
      continue;

    r = recv(rtp_fd, pkt, sizeof(pkt), 0);
    if (r < 12)
      continue;
    udp_pkts++;
    {
      unsigned pt = pkt[1] & 0x7f;
      unsigned cc = pkt[0] & 0x0f;
      const unsigned char *pay;
      size_t paylen;
      if ((size_t)r < 12 + 4 * cc)
        continue;
      pay = pkt + 12 + 4 * cc;
      paylen = (size_t)r - 12 - 4 * cc;
      got_media = 1; /* accept any PT; H264 map varies */
      handle_h264_payload(pay, paylen, nalbuf, &nal_len, &collecting_fu);
    }
  }

  sendf(fd, "TEARDOWN %s RTSP/1.0\r\nCSeq: %d\r\nSession: %s\r\n\r\n", urlstr,
        cseq++, session);
  close(fd);
  close(rtp_fd);
  close(rtcp_fd);
  fprintf(stderr, "udp_pkts=%u got_media=%d\n", udp_pkts, got_media);
  if (!got_media) {
    fprintf(stderr, "no media\n");
    return 1;
  }
  return 0;
}
