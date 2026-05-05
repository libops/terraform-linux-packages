FROM gcr.io/google.com/cloudsdktool/google-cloud-cli:slim@sha256:f4b6222236123dec92dc575f3769baaf3d4f35de0e91a8ce39b9dbcda84767a2

RUN apt-get update \
  && apt-get install -y --no-install-recommends aptly createrepo-c gnupg ca-certificates dpkg-dev \
  && rm -rf /var/lib/apt/lists/*
