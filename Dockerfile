FROM gcr.io/google.com/cloudsdktool/google-cloud-cli:slim@sha256:c088d422d70a0c1238349c4b1a127ae924ec85ea517e8f2df06011715a8dc9ca

RUN apt-get update \
  && apt-get install -y --no-install-recommends aptly createrepo-c gnupg ca-certificates dpkg-dev \
  && rm -rf /var/lib/apt/lists/*
