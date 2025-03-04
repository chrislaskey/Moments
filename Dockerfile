ARG MIX_ENV="prod"

# =============================================================================== #
# Build
# =============================================================================== #
FROM elixir:1.12-alpine as build

# Install sytem and build dependencies
RUN apk add --no-cache build-base git python3 curl npm

# Prepare build dir
WORKDIR /app

# Install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Set build ENV
ARG MIX_ENV
ENV MIX_ENV="${MIX_ENV}"

# Install mix dependencies
#
# Copy compile-time config files before we compile dependencies
# to ensure any relevant config change will trigger the dependencies
# to be re-compiled.
COPY mix.exs mix.lock ./
COPY config/config.exs config/$MIX_ENV.exs config/
RUN mix deps.get --only $MIX_ENV
RUN mix deps.compile

# Copy application
COPY lib ./lib

# Copy priv
COPY priv ./priv

# Build assets - node modules
COPY assets ./assets
WORKDIR /app/assets
RUN rm -rf node_modules
RUN npm install

# Build assets - phoenix, esbuild
WORKDIR /app
RUN mix assets.deploy

# Compile and build the release
RUN mix compile

# Changes to config/runtime.exs don't require recompiling the code
COPY config/runtime.exs config/

# COPY rel/ (comment out if it doesn't exist)
COPY rel rel

# Create release
RUN mix release

# =============================================================================== #
# App
# =============================================================================== #

# Start a new build stage so that the final image will only contain
# the compiled release and other runtime necessities
FROM node:16-alpine AS app

RUN echo "http://dl-cdn.alpinelinux.org/alpine/edge/main" > /etc/apk/repositories \
    && echo "http://dl-cdn.alpinelinux.org/alpine/edge/community" >> /etc/apk/repositories \
    && echo "http://dl-cdn.alpinelinux.org/alpine/edge/testing" >> /etc/apk/repositories \
    && echo "http://dl-cdn.alpinelinux.org/alpine/v3.12/main" >> /etc/apk/repositories \
    && apk upgrade -U -a \
    && apk update \
    && apk add --no-cache libstdc++ openssl ncurses-libs bash ffmpeg

# Setup App environment
ENV USER="elixir"

ARG MIX_ENV
ENV MIX_ENV="${MIX_ENV}"

ARG MOMENTS_DATABASE_POOL_SIZE
ENV MOMENTS_DATABASE_POOL_SIZE=5

ARG MOMENTS_DATABASE_PATH
ENV MOMENTS_DATABASE_PATH=/home/elixir/app/data/moments.prod.db

ARG MOMENTS_SECRET_KEY_BASE
ENV MOMENTS_SECRET_KEY_BASE=mgRkBeyntabuFKhFbHC3rUWiitMBM1Y8OCqBi8xKt1vedZYnVRV/h3RHYy1HF4W6

ARG MOMENTS_DOMAIN
ENV MOMENTS_DOMAIN=moments

ARG MOMENTS_PORT
ENV MOMENTS_PORT=80

# Create an unprivileged user to be used exclusively to run the Phoenix app
WORKDIR "/home/${USER}/app"
RUN addgroup -g 1111 -S "${USER}" && \
    adduser -s /bin/sh -u 1111 -G "${USER}" -h "/home/${USER}" -D "${USER}" && \
    su "${USER}"

# Fix file ownership
RUN chown -R "${USER}:${USER}" "/home/${USER}"

# Everything from this line onwards will run in the context of the unprivileged user.
# ----------------------------------------------------------------------------------- #
USER "${USER}"

# Create directories
RUN mkdir -p "/home/${USER}/app/code" && \
    mkdir -p "/home/${USER}/app/data"

# Copy release from `build` container and set entrypoint
COPY --from=build --chown="${USER}":"${USER}" /app/_build/"${MIX_ENV}"/rel/moments ./code/

# Switch back to root user so user id and group id can be updated using special Docker
# environmental variables `PUID` and `PGID`
# ----------------------------------------------------------------------------------- #
USER root

# Setup the mix release binary as the container entrypoint
ENTRYPOINT ["code/bin/moments"]

# Usage:
#  * build: sudo docker image build -t moments .
#  * shell: sudo docker container run --rm -it --entrypoint "" -p 0.0.0.0:4000:4000 moments sh
#  * run:   sudo docker container run --rm -it -p 0.0.0.0:4000:4000 --name moments moments
#  * exec:  sudo docker container exec -it moments sh
#  * exec:  sudo docker container exec -it moments code/bin/moments remote
#  * logs:  sudo docker container logs --follow --tail 100 moments
CMD ["start"]
