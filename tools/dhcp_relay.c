#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <linux/if_ether.h>
#include <linux/if_packet.h>
#include <net/if.h>
#include <netinet/ip.h>
#include <netinet/udp.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static volatile sig_atomic_t running = 1;

static void stop_running(int signo)
{
    (void)signo;
    running = 0;
}

static int packet_socket(const char *name, int *ifindex)
{
    struct sockaddr_ll addr = {0};
    int fd;

    *ifindex = (int)if_nametoindex(name);
    if (*ifindex == 0) {
        fprintf(stderr, "dhcp-relay: interface not found: %s\n", name);
        return -1;
    }
    fd = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_IP));
    if (fd < 0) {
        fprintf(stderr, "dhcp-relay: socket: %s\n", strerror(errno));
        return -1;
    }
    addr.sll_family = AF_PACKET;
    addr.sll_protocol = htons(ETH_P_IP);
    addr.sll_ifindex = *ifindex;
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        fprintf(stderr, "dhcp-relay: bind %s: %s\n", name, strerror(errno));
        close(fd);
        return -1;
    }
    return fd;
}

static int is_dhcp(const unsigned char *frame, size_t len)
{
    const struct ethhdr *eth;
    const struct iphdr *ip;
    const struct udphdr *udp;
    size_t ip_offset = sizeof(struct ethhdr);
    size_t ip_size;

    if (len < ip_offset + sizeof(struct iphdr))
        return 0;
    eth = (const struct ethhdr *)frame;
    if (ntohs(eth->h_proto) != ETH_P_IP)
        return 0;
    ip = (const struct iphdr *)(frame + ip_offset);
    ip_size = (size_t)ip->ihl * 4;
    if (ip->version != 4 || ip_size < sizeof(*ip) ||
        len < ip_offset + ip_size + sizeof(struct udphdr) ||
        ip->protocol != IPPROTO_UDP || (ntohs(ip->frag_off) & 0x1fff) != 0)
        return 0;
    udp = (const struct udphdr *)(frame + ip_offset + ip_size);
    return (ntohs(udp->source) == 68 && ntohs(udp->dest) == 67) ||
           (ntohs(udp->source) == 67 && ntohs(udp->dest) == 68);
}

static int forward_one(int input, int output, int output_ifindex)
{
    unsigned char frame[ETH_FRAME_LEN + 64];
    struct sockaddr_ll from = {0};
    struct sockaddr_ll to = {0};
    socklen_t from_len = sizeof(from);
    ssize_t count;

    count = recvfrom(input, frame, sizeof(frame), 0,
                     (struct sockaddr *)&from, &from_len);
    if (count < 0) {
        if (errno == EINTR)
            return 0;
        fprintf(stderr, "dhcp-relay: recvfrom: %s\n", strerror(errno));
        return -1;
    }
    /* Packet sockets see their own transmissions. Ignoring them prevents a
     * DHCP frame from bouncing forever between the two interfaces. */
    if (from.sll_pkttype == PACKET_OUTGOING || !is_dhcp(frame, (size_t)count))
        return 0;

    to.sll_family = AF_PACKET;
    to.sll_protocol = htons(ETH_P_IP);
    to.sll_ifindex = output_ifindex;
    to.sll_halen = ETH_ALEN;
    memcpy(to.sll_addr, frame, ETH_ALEN);
    if (sendto(output, frame, (size_t)count, 0,
               (struct sockaddr *)&to, sizeof(to)) != count) {
        fprintf(stderr, "dhcp-relay: sendto: %s\n", strerror(errno));
        return -1;
    }
    return 0;
}

int main(int argc, char **argv)
{
    struct pollfd pollfds[2];
    int left_index, right_index;
    int left, right;

    if (argc != 3) {
        fprintf(stderr, "usage: %s CLIENT_IFACE OPENWRT_TAP\n", argv[0]);
        return 2;
    }
    left = packet_socket(argv[1], &left_index);
    if (left < 0)
        return 1;
    right = packet_socket(argv[2], &right_index);
    if (right < 0) {
        close(left);
        return 1;
    }
    signal(SIGTERM, stop_running);
    signal(SIGINT, stop_running);
    pollfds[0].fd = left;
    pollfds[0].events = POLLIN;
    pollfds[1].fd = right;
    pollfds[1].events = POLLIN;

    while (running) {
        int ready = poll(pollfds, 2, -1);
        if (ready < 0) {
            if (errno == EINTR)
                continue;
            fprintf(stderr, "dhcp-relay: poll: %s\n", strerror(errno));
            break;
        }
        if ((pollfds[0].revents & POLLIN) &&
            forward_one(left, right, right_index) < 0)
            break;
        if ((pollfds[1].revents & POLLIN) &&
            forward_one(right, left, left_index) < 0)
            break;
    }
    close(right);
    close(left);
    return 0;
}
