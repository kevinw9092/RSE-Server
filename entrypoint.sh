#!/usr/bin/env bash
# RSE-Server start script: install/update the Windows server, add UE4SS and
# mods, write the server config from RSDW_* variables, run it under Wine.
set -euo pipefail

APPID=4019830                                   # RuneScape: Dragonwilds Dedicated Server
APPDIR=/home/steam/rsdw-windows
GAME="$APPDIR/RSDragonwilds"
BIN="$GAME/Binaries/Win64"
UE4SS_SRC=/ue4ss                                # bind mount: dwmapi.dll + ue4ss/ (see README)

: "${RSDW_OWNER_ID:?RSDW_OWNER_ID must be set (your EOS id, in game under Settings)}"
export RSDW_PORT="${RSDW_PORT:-7777}"
export RSDW_SERVER_NAME="${RSDW_SERVER_NAME:-Dragonwilds}"
export RSDW_WORLD_NAME="${RSDW_WORLD_NAME:-World}"
export RSDW_PASSWORD="${RSDW_PASSWORD:-}"
export RSDW_ADMIN_PASSWORD="${RSDW_ADMIN_PASSWORD:-}"
export RSDW_ADMINS="${RSDW_ADMINS:-}"
UE4SS_ENABLED="${UE4SS_ENABLED:-true}"

# 0. SteamCMD installs somewhere else (and still says "Success") when it cannot write here.
for dir in "$APPDIR" "$GAME" "$GAME/Saved"; do
    if [[ -d "$dir" && ! -w "$dir" ]]; then
        echo "[rse-server] $dir is not writable by $(id -un) (uid $(id -u)). Fix: chown -R 1000:1000 on the host folder or volume behind it."
        exit 1
    fi
done

# 1. Install or update the WINDOWS build (a Linux host would pick the Linux one).
echo "[rse-server] updating app $APPID (Windows build)"
steam_args=(+@sSteamCmdForcePlatformType windows +force_install_dir "$APPDIR"
            +@bClientTryRequestManifestWithoutCode 1 +login anonymous +app_update "$APPID")
[[ "${STEAMAPPVALIDATE:-0}" == "1" ]] && steam_args+=(validate)
# A fresh SteamCMD often fails the first time with "Missing configuration"
# (it has not fetched the app's config yet); the next attempt works.
installed=0
for attempt in 1 2 3; do
    /home/steam/steamcmd/steamcmd.sh "${steam_args[@]}" +quit > /tmp/steamcmd.log 2>&1 || true
    grep -E "Success!|ERROR!" /tmp/steamcmd.log || true
    if grep -q "Success! App '$APPID'" /tmp/steamcmd.log; then
        installed=1
        break
    fi
    echo "[rse-server] SteamCMD attempt $attempt did not finish; retrying"
    sleep 5
done
[[ "$installed" == "1" ]] || { echo "[rse-server] SteamCMD failed 3 times:"; tail -5 /tmp/steamcmd.log; exit 1; }

if [[ ! -d "$BIN" ]]; then
    echo "[rse-server] $BIN not found after install; listing binaries:"
    find "$GAME/Binaries" -maxdepth 2 -iname '*.exe' || true
    exit 1
fi

# 2. UE4SS and mods. They live on the host (bind mount) so a server update never
#    touches them. UE4SS's loader DLL goes next to the server exe as version.dll:
#    the dedicated server never loads dwmapi.dll (no desktop window manager), but it
#    does import VERSION.dll, and UE4SS's proxy passes calls on to the real DLL of
#    whatever name it has (verified in the smoke test, 2026-09-30). ue4ss/ is linked.
if [[ "$UE4SS_ENABLED" == "true" && -f "$UE4SS_SRC/dwmapi.dll" && -d "$UE4SS_SRC/ue4ss" ]]; then
    cp -f "$UE4SS_SRC/dwmapi.dll" "$BIN/version.dll"
    rm -f "$BIN/dwmapi.dll"                     # left by earlier versions of this script
    rm -rf "$BIN/ue4ss"
    ln -s "$UE4SS_SRC/ue4ss" "$BIN/ue4ss"
    # Wine uses its own version.dll unless told to prefer the one next to the exe.
    export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:+$WINEDLLOVERRIDES;}version=n,b"
    echo "[rse-server] UE4SS enabled (as version.dll), mods: $(ls "$UE4SS_SRC/ue4ss/Mods" 2>/dev/null | tr '\n' ' ')"
else
    rm -f "$BIN/version.dll" "$BIN/dwmapi.dll" "$BIN/ue4ss"
    echo "[rse-server] UE4SS disabled (UE4SS_ENABLED=$UE4SS_ENABLED, or $UE4SS_SRC is incomplete)"
fi

# 3. Server settings, the same file the official image writes (Linux uses
#    Config/LinuxServer, Windows Config/WindowsServer).
mkdir -p "$GAME/Saved/Config/WindowsServer"
envsubst < /home/steam/DedicatedServer.ini > "$GAME/Saved/Config/WindowsServer/DedicatedServer.ini"

# 4. Run. Wine needs a display even for a headless server: xvfb-run gives it one.
# The real server, not the RSDragonwildsServer.exe launcher in the install root:
# under Wine the launcher never starts the server (it sits idle, no log), while
# the shipping exe runs fine (smoke test 2026-09-30). UE4SS's version.dll sits next to it.
SERVER_EXE=RSDragonwildsServer-Win64-Shipping.exe
[[ -f "$BIN/$SERVER_EXE" ]] || { echo "[rse-server] $BIN/$SERVER_EXE not found"; exit 1; }
cd "$BIN"
extra=()
[[ -n "${RSDW_ADDITIONAL_ARGS:-}" ]] && read -r -a extra <<< "$RSDW_ADDITIONAL_ARGS"
echo "[rse-server] starting $SERVER_EXE on port $RSDW_PORT"
exec xvfb-run -a wine "$SERVER_EXE" -log -Port "$RSDW_PORT" "${extra[@]}"
