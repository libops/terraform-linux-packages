FROM gcr.io/google.com/cloudsdktool/google-cloud-cli:slim@sha256:92ff5ee6aee25a5dce34fe85096a9cc2a4f1a0d8babd5084dad362e545579455

RUN apt-get update \
  && apt-get install -y --no-install-recommends aptly createrepo-c gnupg ca-certificates dpkg-dev rpm \
  && rm -rf /var/lib/apt/lists/*
