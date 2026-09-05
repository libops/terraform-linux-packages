FROM gcr.io/google.com/cloudsdktool/google-cloud-cli:slim@sha256:87eaf69da735ab8dfc1c640df1e85a467a4feedf2256d35dad368f970d9cd35f AS build

RUN apt-get update \
  && apt-get upgrade -y \
  && apt-get install -y --no-install-recommends aptly createrepo-c gnupg ca-certificates dpkg-dev rpm \
  && if [ -x /usr/lib/google-cloud-sdk/platform/bundledpythonunix/bin/python3 ]; then \
    /usr/lib/google-cloud-sdk/platform/bundledpythonunix/bin/python3 -m pip install \
      --no-cache-dir \
      --only-binary=:all: \
      cryptography==50.0.0 \
      msgpack==1.2.1 \
      pyopenssl==26.4.0 \
      setuptools==80.10.2 \
      && /usr/lib/google-cloud-sdk/platform/bundledpythonunix/bin/python3 -m pip check \
      && /usr/lib/google-cloud-sdk/platform/bundledpythonunix/bin/python3 -m pip uninstall --yes pip setuptools \
      && gcloud version >/dev/null \
      && gcloud storage --help >/dev/null; \
    fi \
  && rm -f /usr/lib/google-cloud-sdk/bin/gcloud-crc32c \
  && rm -rf /var/lib/apt/lists/*

# Copy the merged, patched filesystem into one final layer so scanners and
# downstream consumers cannot recover superseded vulnerable Python packages
# from the external base image's lower layers.
FROM scratch
COPY --from=build / /

ENV CLOUDSDK_STORAGE_USE_GCLOUD_CRC32C=false
