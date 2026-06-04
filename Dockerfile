FROM gcr.io/google.com/cloudsdktool/google-cloud-cli:slim@sha256:61cdaee8f89a2500c8e93fac2499d98a5b7692fcc3d7d69abbef48200477cb71

RUN apt-get update \
  && apt-get install -y --no-install-recommends aptly createrepo-c gnupg ca-certificates dpkg-dev rpm \
  && rm -rf /var/lib/apt/lists/*
