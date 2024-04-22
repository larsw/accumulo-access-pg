#!/bin/bash

docker build -f Dockerfile.build -o out .
docker build -f Dockerfile.postgres -t larsw/postgres-accumulo-access:15.6-bullseye .
docker tag larsw/postgres-accumulo-access:15.6-bullseye larsw/postgres-accumulo-access:latest
docker build -f Dockerfile.postgis -t larsw/postgis-accumulo-access:15-3.4 .
docker tag larsw/postgis-accumulo-access:15-3.4 larsw/postgis-accumulo-access:latest
