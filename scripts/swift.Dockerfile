# swift:latest plus the system SQLite headers GRDB needs on Linux.
FROM swift:latest
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-dev && rm -rf /var/lib/apt/lists/*
