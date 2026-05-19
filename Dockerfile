FROM gcr.io/google.com/cloudsdktool/google-cloud-cli:slim@sha256:a443f0233e9476f41db019f2b4f07bb6d72dace55aa2b176deefeb6205a2a83a

RUN apt-get update \
  && apt-get install -y --no-install-recommends aptly createrepo-c gnupg ca-certificates dpkg-dev \
  && rm -rf /var/lib/apt/lists/*
