#pragma once

#include <arpa/inet.h>
#include <sys/socket.h>

int lwip_socket(int domain, int type, int protocol);
int lwip_close(int socket);
int lwip_bind(int socket, const struct sockaddr *address,
              socklen_t addressLength);
int lwip_setsockopt(int socket, int level, int option, const void *value,
                    socklen_t valueLength);
ssize_t lwip_sendto(int socket, const void *data, size_t length, int flags,
                    const struct sockaddr *target,
                    socklen_t targetLength);
int lwip_recvfrom(int socket, void *buffer, size_t capacity, int flags,
                  struct sockaddr *source, socklen_t *sourceLength);
