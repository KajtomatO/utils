#!/bin/bash

sudo apt update
sudo apt install docker

sudo groupadd docker
sudo usermod -aG docker $USER