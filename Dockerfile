# RSE-Server: the WINDOWS RuneScape: Dragonwilds dedicated server under Wine, so
# UE4SS (a Windows DLL) and Lua mods can run on it. The official image
# (ghcr.io/runescape/rsdw-dedicated) runs the Linux build, where UE4SS cannot load.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Wine from WineHQ (newer than Ubuntu's), Xvfb for a virtual display, SteamCMD's
# 32-bit runtime, envsubst (gettext-base) for the config template, tini as PID 1.
RUN dpkg --add-architecture i386 \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg2 xvfb xauth gettext-base lib32gcc-s1 procps tini \
 && mkdir -pm755 /etc/apt/keyrings \
 && wget -qO /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key \
 && wget -qNP /etc/apt/sources.list.d/ https://dl.winehq.org/wine-builds/ubuntu/dists/noble/winehq-noble.sources \
 && apt-get update \
 && apt-get install -y --install-recommends winehq-stable \
 && rm -rf /var/lib/apt/lists/*

# Same user and uid as the official image (steam, 1000), so file ownership on
# the host's save folder stays the same.
RUN (userdel -r ubuntu 2>/dev/null || true) && useradd -m -u 1000 steam
USER steam
WORKDIR /home/steam

RUN mkdir -p steamcmd \
 && curl -fsSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz | tar zxf - -C steamcmd \
 && (steamcmd/steamcmd.sh +quit || true)   # SteamCMD updates itself on first run: do it now, not on every start

# mscoree/mshtml off: Wine would otherwise pop up a dialog offering to install
# Mono and Gecko on first start and wait for a click forever (a server needs neither).
ENV WINEPREFIX=/home/steam/.wine \
    WINEARCH=win64 \
    WINEDEBUG=-all \
    WINEDLLOVERRIDES="mscoree=d;mshtml=d"
# Create the Wine prefix at build time, not on every start.
RUN xvfb-run -a sh -c "wineboot --init && wineserver -w"

# The server folder, down to the saves, owned by steam. Without it Docker creates
# the parents of the SaveGames mount as root, SteamCMD cannot write there and
# silently installs into ~/Steam instead. A new named volume copies these folders
# (and their owner) from the image.
RUN mkdir -p /home/steam/rsdw-windows/RSDragonwilds/Saved/SaveGames \
             /home/steam/rsdw-windows/RSDragonwilds/Saved/Config/WindowsServer

COPY --chown=steam:steam entrypoint.sh DedicatedServer.ini /home/steam/
# Strip Windows line endings (files edited or copied on Windows), then make it executable.
RUN sed -i 's/\r$//' /home/steam/entrypoint.sh /home/steam/DedicatedServer.ini \
 && chmod +x /home/steam/entrypoint.sh

EXPOSE 7777/udp
ENTRYPOINT ["/usr/bin/tini", "--", "/home/steam/entrypoint.sh"]
