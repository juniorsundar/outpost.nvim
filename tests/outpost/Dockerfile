FROM alpine:3.22

RUN apk add --no-cache openssh zsh

# zsh login shell: real hosts commonly run the remote command under a
# non-POSIX shell, which is where word-splitting assumptions break
RUN adduser -D -s /bin/zsh outpost \
    && echo 'outpost:fixture-only-not-a-login-password' | chpasswd \
    && mkdir -p /home/outpost/.ssh \
    && chown outpost:outpost /home/outpost/.ssh \
    && chmod 700 /home/outpost/.ssh \
    && echo 'StrictModes no' >> /etc/ssh/sshd_config \
    && echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config \
    && echo 'LogLevel VERBOSE' >> /etc/ssh/sshd_config

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# A second account reachable only by password: the global ban stays put, a
# Match block lifts it for this user alone, so the key-based account above
# keeps behaving exactly as the rest of the suite expects. The password
# tests authenticate wrongly on purpose, and sshd would otherwise penalise
# the base's address for those failures and drop the suite's later
# connections.
RUN adduser -D -s /bin/zsh outpass \
    && echo 'outpass:fixture-password' | chpasswd \
    && echo 'PerSourcePenalties no' >> /etc/ssh/sshd_config \
    && printf '\nMatch User outpass\n    PasswordAuthentication yes\n' >> /etc/ssh/sshd_config

EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]
