# RSE-Server

Runs the **Windows** RuneScape: Dragonwilds dedicated server under Wine in Docker, so UE4SS and Lua mods can run server-side. The official image (`ghcr.io/runescape/rsdw-dedicated`) runs the Linux build, and UE4SS (a Windows DLL) can't load into that.

**Status: smoke-tested locally** (Docker Desktop, 2026-09-30):
- the Windows server installs and runs under Wine, and loads a world
- UE4SS loads, as `version.dll`
- RSE-Transmog and RSE-Toolbag start, and Toolbag adds its tab to the template

**Not tested yet:** players joining it, and the Toolbag's server mode with a real player. Test those on a copy of your world first (step 1).

**How it differs from the official image:**
- It runs `Binaries/Win64/RSDragonwildsServer-Win64-Shipping.exe` directly. Unreal's small `RSDragonwildsServer.exe` launcher never starts the server under Wine.
- UE4SS's `dwmapi.dll` goes in as `version.dll`. The dedicated server never loads `dwmapi` (it has no desktop window manager), but it does load `VERSION.dll`.

| File | What it does |
|---|---|
| `Dockerfile` | Ubuntu 24.04 + WineHQ stable + Xvfb + SteamCMD, user `steam` (uid 1000, like the official image) |
| `entrypoint.sh` | on every start: installs or updates the Windows server (app 4019830), adds UE4SS and mods, writes `DedicatedServer.ini` from `RSDW_*`, runs `RSDragonwildsServer.exe` under Wine |
| `DedicatedServer.ini` | settings template, taken from the official image (BSD licence, Jagex) |
| `docker-compose.yaml` | the Coolify service: your compose, with `build:` in place of `image:`, plus the UE4SS mount |

## Step by step

### 1. On the Coolify host: a test copy of your world
Keep your current server running while you test. The new one uses a copy of the saves:
```bash
sudo cp -a /srv/dragonwilds/saves /srv/dragonwilds/saves-test
sudo chown -R 1000:1000 /srv/dragonwilds/saves-test
```

### 2. On the host: UE4SS and the server-side mods
1. Download UE4SS for RSDragonwilds, the same package you use on your PC ([Nexus](https://www.nexusmods.com/runescapedragonwilds/mods/4)).
2. Lay it out like this. It's the contents of your PC's `Binaries\Win64` UE4SS files, minus the client-only mods:
   ```
   /srv/dragonwilds/ue4ss/
     dwmapi.dll            (the same file as on your PC; the server loads it as version.dll)
     ue4ss/
       UE4SS.dll
       UE4SS-settings.ini
       Mods/
         mods.txt
         RSE-Transmog/     (relays looks between players; runs on dedicated servers)
         RSE-Fixes/        (logs what the server sees under arriving players: the building fall-through bug)
         RSE-Toolbag/      (server mode adds the toolbag slots; see below)
   ```
   Leave out RSE-Dock, RSE-ModMenu and other UI mods: a server has no screen.
3. In `UE4SS-settings.ini`, set `ConsoleEnabled = 0` and `GuiConsoleEnabled = 0`, because there is no display.
4. Make it owned by the container user:
   ```bash
   sudo chown -R 1000:1000 /srv/dragonwilds/ue4ss
   ```

### 3. Put this folder in a Git repository
Coolify builds images from Git. Push `RSE-Server/` to a GitHub or GitLab repository, either on its own or inside a larger repository. A private repository works through Coolify's GitHub App or a deploy key.

### 4. In Coolify: create the service
1. **+ New → Resource → Public or Private Repository**, and pick the repository and branch.
2. **Build Pack: Docker Compose.** Set **Base Directory** to the folder that holds this README, and the compose file to `docker-compose.yaml`.
3. **Environment Variables:** the same ones you have now, `RSDW_OWNER_ID`, `RSDW_SERVER_NAME`, `RSDW_WORLD_NAME`, `RSDW_PASSWORD` and `RSDW_ADMIN_PASSWORD`. While testing, give the world a different name so you can tell the two servers apart in the list.
4. **Ports:** while your current server still uses 7777 and 8888, change the test one's `ports:` to, for example, `7787:7777/udp` and `8898:8888/udp`, and open those on your firewall.
5. **Deploy.** The first start downloads the server (about 1.7 GB), so give it a few minutes.

### 5. Check the logs (Coolify → the service → Logs)
In order, you should see:
- `[rse-server] updating app 4019830 (Windows build)`, then SteamCMD's `Success! App '4019830' fully installed.`
- `[rse-server] UE4SS enabled, mods: RSE-Toolbag RSE-Transmog ...`
- `[rse-server] server log: .../Saved/Logs/RSDragonwilds.log`
- `[rse-server] starting RSDragonwildsServer-Win64-Shipping.exe on port 7777`, then the server's own log lines (followed from its log file; set `SERVER_CONSOLE_LOG=true` for the old `-log` console instead)

UE4SS writes its own log to `/srv/dragonwilds/ue4ss/ue4ss/UE4SS.log` on the host. It should contain `[RSE-Transmog] v... loaded`.

### 6. Join and test
Join the test world from the game, with UE4SS and the client mods on your PC. Check that:
- you can join, play for a while, and see the world save
- Transmog: another player running the mod sees your look (`transmog_status` should say `server answered: true`)
- the server keeps running after a restart of the container

### 7. Switch over
Once everything works:
1. Stop the old service.
2. Point the new service's saves mount back at `/srv/dragonwilds/saves`, after taking a backup.
3. Set the ports back to 7777 and 8888, and redeploy.

To go back, redeploy the old compose. The world saves are the same files for both builds.

## Toolbag on a dedicated server
RSE-Toolbag 2.2.0 has a **server mode**. On a host or dedicated server it watches every connected player. Once a player's saved inventory has loaded, it adds the hidden toolbag tab and grows their inventory to 162 slots. It re-checks every 30 s and only ever grows the inventory.

- **The server's `ue4ss/Mods/RSE-Toolbag/config.txt` must use the same `ToolbagMode` as every player** (`private` or `items`). `deploy-ue4ss.ps1` copies your PC's `config.txt`, so they match when you deploy.
- The server's log shows `server mode: adding the toolbag slots ...`, then `player <name>: toolbag ready` for each player.
- The server tells each player's game when their slots are ready (`rsetb1 ready`, over the same engine message RSE-Transmog uses). Your game doesn't poll: it asks once (`rsetb1 hi`) and waits for that message. The PC log then says `the host added the toolbag slots; toolbag ready`. With no answer within 60 s, storage stays off, because the host has no RSE-Toolbag.
- Before turning the mod off on the server, every player should click **Take all**.

## Troubleshooting
| Symptom | Likely cause and fix |
|---|---|
| `Binaries/Win64 not found` | the Windows depot didn't download. Set `STEAMAPPVALIDATE: '1'` for one start |
| Server starts, but there's no `UE4SS.log` | Check the log for `UE4SS enabled (as version.dll)`. It copies `dwmapi.dll` next to the server as `version.dll` and sets `WINEDLLOVERRIDES=...version=n,b`. Check that `dwmapi.dll` is in `/srv/dragonwilds/ue4ss` |
| Server exits right away with a Steam or EOS error | if the log mentions `steamclient64.dll`, copy `steamclient64.dll`, `tier0_s64.dll` and `vstdlib_s64.dll` from a Windows SteamCMD install into `Binaries/Win64` |
| Can't join | UDP 7777 isn't reachable: check the port mapping and firewall. `RSDW_OWNER_ID` must be your EOS id |
| Very slow start or high CPU | normal for the first start under Wine. Stays high: give the container more RAM (2 GB + 1 GB per player) |
| Crash with UE4SS but not with `UE4SS_ENABLED=false` | a mod or UE4SS build problem. Send `UE4SS.log` and the crash dump from `ue4ss/` |

## Rolling back
- `UE4SS_ENABLED=false` runs the plain Windows server with no mods.
- Redeploying the official compose runs the official Linux server. The saves are compatible.
