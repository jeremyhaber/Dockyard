# swift:latest plus libssh2 (SSH/SFTP backend), ssh-agent/ssh-add for the tests, and the system SQLite headers GRDB needs.
FROM swift:latest
RUN apt-get update \
 && apt-get install -y --no-install-recommends libssh2-1-dev libsqlite3-dev pkg-config openssh-client \
 && rm -rf /var/lib/apt/lists/*
