FROM gcr.io/google.com/cloudsdktool/google-cloud-cli:slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends aptly createrepo-c gnupg ca-certificates dpkg-dev \
  && rm -rf /var/lib/apt/lists/*
