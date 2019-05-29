#!/bin/sh
echo "******************** working directory is"
echo `pwd`
echo "******************** adding packages"
sudo apt-get update
sudo apt-get install wget tar make
echo "******************** downloading and extracting Stan"
wget https://github.com/stan-dev/cmdstan/releases/download/v2.19.1/cmdstan-2.19.1.tar.gz
tar -xzpf cmdstan-2.19.1.tar.gz
echo "******************** building Stan"
cd cmdstan-2.19.1
make build
