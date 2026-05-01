ARG UBUNTU_CODENAME=noble
FROM ubuntu:${UBUNTU_CODENAME}

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    devscripts \
    dpkg-dev \
    equivs \
    fakeroot \
    git \
  && rm -rf /var/lib/apt/lists/*
