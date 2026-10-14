/*
 * Grab one MJPEG/JPEG frame from a V4L2 device (SONiX /dev/video0).
 * Writes raw JPEG bytes to stdout. Exit 0 on success.
 */
#include <errno.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#define NBUF 2
#define DEF_W 640
#define DEF_H 360

struct buf {
  void *start;
  size_t len;
};

static int xioctl(int fd, unsigned long req, void *arg)
{
  int r;
  do {
    r = ioctl(fd, req, arg);
  } while (r == -1 && errno == EINTR);
  return r;
}

static void usage(const char *argv0)
{
  fprintf(stderr,
          "Usage: %s [-d /dev/videoN] [-W width] [-H height] [-t tries]\n",
          argv0);
}

int main(int argc, char **argv)
{
  const char *dev = "/dev/video0";
  int width = DEF_W, height = DEF_H, tries = 8;
  int opt, fd = -1, i, n = 0;
  struct v4l2_capability cap;
  struct v4l2_format fmt;
  struct v4l2_requestbuffers req;
  struct v4l2_buffer buf;
  struct buf *bufs = NULL;
  enum v4l2_buf_type type;
  unsigned int pix = V4L2_PIX_FMT_MJPEG;

  while ((opt = getopt(argc, argv, "d:W:H:t:h")) != -1) {
    switch (opt) {
    case 'd':
      dev = optarg;
      break;
    case 'W':
      width = atoi(optarg);
      break;
    case 'H':
      height = atoi(optarg);
      break;
    case 't':
      tries = atoi(optarg);
      break;
    default:
      usage(argv[0]);
      return 2;
    }
  }

  fd = open(dev, O_RDWR | O_NONBLOCK, 0);
  if (fd < 0) {
    perror(dev);
    return 1;
  }

  memset(&cap, 0, sizeof(cap));
  if (xioctl(fd, VIDIOC_QUERYCAP, &cap) < 0) {
    perror("VIDIOC_QUERYCAP");
    goto fail;
  }
  if (!(cap.capabilities & V4L2_CAP_VIDEO_CAPTURE) &&
      !(cap.capabilities & V4L2_CAP_VIDEO_CAPTURE_MPLANE)) {
    fprintf(stderr, "%s: not a capture device\n", dev);
    goto fail;
  }

  memset(&fmt, 0, sizeof(fmt));
  fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
  fmt.fmt.pix.width = (unsigned)width;
  fmt.fmt.pix.height = (unsigned)height;
  fmt.fmt.pix.pixelformat = pix;
  fmt.fmt.pix.field = V4L2_FIELD_NONE;
  if (xioctl(fd, VIDIOC_S_FMT, &fmt) < 0) {
    /* Fall back to JPEG fourcc used by some SONiX builds */
    pix = V4L2_PIX_FMT_JPEG;
    fmt.fmt.pix.pixelformat = pix;
    if (xioctl(fd, VIDIOC_S_FMT, &fmt) < 0) {
      perror("VIDIOC_S_FMT");
      goto fail;
    }
  }

  memset(&req, 0, sizeof(req));
  req.count = NBUF;
  req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
  req.memory = V4L2_MEMORY_MMAP;
  if (xioctl(fd, VIDIOC_REQBUFS, &req) < 0 || req.count < 1) {
    perror("VIDIOC_REQBUFS");
    goto fail;
  }

  bufs = calloc(req.count, sizeof(*bufs));
  if (!bufs)
    goto fail;
  n = (int)req.count;

  for (i = 0; i < n; i++) {
    memset(&buf, 0, sizeof(buf));
    buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    buf.memory = V4L2_MEMORY_MMAP;
    buf.index = (unsigned)i;
    if (xioctl(fd, VIDIOC_QUERYBUF, &buf) < 0) {
      perror("VIDIOC_QUERYBUF");
      goto fail;
    }
    bufs[i].len = buf.length;
    bufs[i].start =
        mmap(NULL, buf.length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, buf.m.offset);
    if (bufs[i].start == MAP_FAILED) {
      perror("mmap");
      goto fail;
    }
  }

  for (i = 0; i < n; i++) {
    memset(&buf, 0, sizeof(buf));
    buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    buf.memory = V4L2_MEMORY_MMAP;
    buf.index = (unsigned)i;
    if (xioctl(fd, VIDIOC_QBUF, &buf) < 0) {
      perror("VIDIOC_QBUF");
      goto fail;
    }
  }

  type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
  if (xioctl(fd, VIDIOC_STREAMON, &type) < 0) {
    perror("VIDIOC_STREAMON");
    goto fail;
  }

  for (i = 0; i < tries; i++) {
    fd_set fds;
    struct timeval tv;
    int r;

    FD_ZERO(&fds);
    FD_SET(fd, &fds);
    tv.tv_sec = 2;
    tv.tv_usec = 0;
    r = select(fd + 1, &fds, NULL, NULL, &tv);
    if (r == -1) {
      if (errno == EINTR)
        continue;
      perror("select");
      goto fail_stream;
    }
    if (r == 0)
      continue;

    memset(&buf, 0, sizeof(buf));
    buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    buf.memory = V4L2_MEMORY_MMAP;
    if (xioctl(fd, VIDIOC_DQBUF, &buf) < 0) {
      if (errno == EAGAIN)
        continue;
      perror("VIDIOC_DQBUF");
      goto fail_stream;
    }

    if (buf.bytesused >= 4) {
      unsigned char *p = bufs[buf.index].start;
      /* Prefer a buffer that looks like JPEG (SOI) */
      if (p[0] == 0xff && p[1] == 0xd8) {
        if (fwrite(p, 1, buf.bytesused, stdout) != buf.bytesused) {
          perror("fwrite");
          goto fail_stream;
        }
        fflush(stdout);
        xioctl(fd, VIDIOC_STREAMOFF, &type);
        for (i = 0; i < n; i++)
          if (bufs[i].start && bufs[i].start != MAP_FAILED)
            munmap(bufs[i].start, bufs[i].len);
        free(bufs);
        close(fd);
        return 0;
      }
    }
    if (xioctl(fd, VIDIOC_QBUF, &buf) < 0) {
      perror("VIDIOC_QBUF");
      goto fail_stream;
    }
  }

  fprintf(stderr, "no JPEG frame from %s\n", dev);

fail_stream:
  type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
  xioctl(fd, VIDIOC_STREAMOFF, &type);
fail:
  if (bufs) {
    for (i = 0; i < n; i++)
      if (bufs[i].start && bufs[i].start != MAP_FAILED)
        munmap(bufs[i].start, bufs[i].len);
    free(bufs);
  }
  if (fd >= 0)
    close(fd);
  return 1;
}
