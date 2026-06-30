## intersystems-challenge1-docker-template

This is a template for [Employee Programming Challenge #1](https://openexchange.intersystems.com/contest/47). This template spins up InterSystems IRIS Community Edition in a docker container and contains the RunScript.mac that *you need to modify*.

## Prerequisites

Make sure you have [git](https://git-scm.com/book/en/v2/Getting-Started-Installing-Git) and [Docker desktop](https://www.docker.com/products/docker-desktop) installed.

# Build

Clone the repository

```bash
git clone https://github.com/Gra-ach/intersystems-challenge1-docker-template.git
cd smart-grid-pyprod
```

Start up the Docker container:

```bash
docker-compose up --build -d
```

## How we will check your work

We will build your project in Docker container and run the following in IRIS terminal:

```
$ docker-compose exec iris iris session iris
USER>do ^RunScript
```
