/* Minimal ONVIF WS-Discovery ProbeMatches responder (UDP 3702).
 * Build: zig cc -target arm-linux-musleabi -O2 -static -o wsd-lite wsd-lite.c
 * Usage: wsd-lite <xaddrs-url>
 */
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static const char *tpl =
"<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
"<s:Envelope xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\""
" xmlns:a=\"http://schemas.xmlsoap.org/ws/2004/08/addressing\""
" xmlns:d=\"http://schemas.xmlsoap.org/ws/2005/04/discovery\""
" xmlns:dn=\"http://www.onvif.org/ver10/network/wsdl\">"
"<s:Header>"
"<a:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/ProbeMatches</a:Action>"
"<a:To>http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous</a:To>"
"</s:Header>"
"<s:Body><d:ProbeMatches><d:ProbeMatch>"
"<a:EndpointReference><a:Address>urn:uuid:localcam-isc5</a:Address></a:EndpointReference>"
"<d:Types>dn:NetworkVideoTransmitter</d:Types>"
"<d:Scopes>onvif://www.onvif.org/name/Localcam"
" onvif://www.onvif.org/type/Network_Video_Transmitter</d:Scopes>"
"<d:XAddrs>%s</d:XAddrs>"
"<d:MetadataVersion>1</d:MetadataVersion>"
"</d:ProbeMatch></d:ProbeMatches></s:Body></s:Envelope>";

int main(int argc, char **argv) {
  const char *xaddrs = (argc > 1) ? argv[1] : "http://0.0.0.0:8000/onvif/device_service";
  char msg[2048];
  int n = snprintf(msg, sizeof(msg), tpl, xaddrs);
  if (n <= 0 || n >= (int)sizeof(msg)) return 1;

  int fd = socket(AF_INET, SOCK_DGRAM, 0);
  if (fd < 0) { perror("socket"); return 1; }
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_port = htons(3702);
  addr.sin_addr.s_addr = htonl(INADDR_ANY);
  if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
    perror("bind");
    return 1;
  }

  /* Join WS-Discovery multicast */
  struct ip_mreq mreq;
  memset(&mreq, 0, sizeof(mreq));
  mreq.imr_multiaddr.s_addr = inet_addr("239.255.255.250");
  mreq.imr_interface.s_addr = htonl(INADDR_ANY);
  setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, sizeof(mreq));

  fprintf(stderr, "wsd-lite: listening UDP 3702 xaddrs=%s\n", xaddrs);

  char buf[4096];
  for (;;) {
    struct sockaddr_in peer;
    socklen_t plen = sizeof(peer);
    ssize_t r = recvfrom(fd, buf, sizeof(buf) - 1, 0, (struct sockaddr *)&peer, &plen);
    if (r < 0) {
      if (errno == EINTR) continue;
      perror("recvfrom");
      break;
    }
    buf[r] = 0;
    if (strstr(buf, "Probe") == NULL) continue;
    sendto(fd, msg, (size_t)n, 0, (struct sockaddr *)&peer, plen);
  }
  close(fd);
  return 0;
}
