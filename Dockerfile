FROM gcr.io/google.com/cloudsdktool/google-cloud-cli:slim@sha256:288bee65409ada9168944d1af8050247b556f8c0aeef97a3889ea05ee6294d7c

ENV CLOUDSDK_STORAGE_USE_GCLOUD_CRC32C=false

RUN apt-get update \
  && apt-get upgrade -y \
  && apt-get install -y --no-install-recommends aptly createrepo-c gnupg ca-certificates dpkg-dev rpm \
  && if [ -x /usr/lib/google-cloud-sdk/platform/bundledpythonunix/bin/python3 ]; then \
    /usr/lib/google-cloud-sdk/platform/bundledpythonunix/bin/python3 -m pip install \
      --no-cache-dir \
      --only-binary=:all: \
      cryptography==48.0.1; \
    fi \
  && rm -f /usr/lib/google-cloud-sdk/bin/gcloud-crc32c \
  && rm -rf /var/lib/apt/lists/*
