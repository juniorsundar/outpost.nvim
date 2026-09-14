FROM alpine:3.22

RUN apk add --no-cache openssh

RUN adduser -D outpost \
    && echo 'outpost:fixture-only-not-a-login-password' | chpasswd \
    && mkdir -p /home/outpost/.ssh \
    && chown outpost:outpost /home/outpost/.ssh \
    && chmod 700 /home/outpost/.ssh \
    && echo 'StrictModes no' >> /etc/ssh/sshd_config \
    && echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config \
    && echo 'LogLevel VERBOSE' >> /etc/ssh/sshd_config

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]
