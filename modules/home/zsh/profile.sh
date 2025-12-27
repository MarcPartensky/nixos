#!/bin/env sh

PROGRAMS_PATH=~/git

trysh() {
    docker exec $1 which $2 >/dev/null &&
    echo "docker exec -it $1 $2" &&
    docker exec -it $1 $2
}

dx() {
    container=`docker ps --format "{{.Names}}" | fzf`
    for shell in zsh bash sh; do
        trysh $container $shell && break
    done
}

fp() {
	cd "$PROGRAMS_PATH/$(env ls -1 $PROGRAMS_PATH | fzf)"
}

dlp() {
    yt-dlp \
        -ciw \
        -o '%(title)s.%(ext)s' \
        -f 'bestvideo[ext=mp4]+bestaudio[ext=m4a]/bestvideo+bestaudio' \
        --progress \
        --audio-quality 0 \
        --embed-thumbnail \
        --embed-metadata \
        --embed-subs \
        --embed-chapters \
        --embed-info-json \
        --embed-chapters \
        --rm-cache-dir \
        --no-keep-fragments \
        --sponsorblock-mark all \
        --sponsorblock-remove all \
        --retry-sleep 10 \
        --retries 1000 \
        --file-access-retries 1000 \
        --extractor-retries 1000 \
        $@
}
