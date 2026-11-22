# syncwlp

syncwlp configures Syncthing to sync `~/Pictures/Wallpapers` between devices.

## Architecture

```mermaid
flowchart TB
    setup["syncwlp · one-time setup<br/>Install · start · configure"]

    subgraph network["YOUR DEVICES · NO CENTRAL FILE SERVER"]
        direction LR
        subgraph first["First machine · Arch Linux"]
            a["Syncthing<br/>Trusted introducer"]
            fa["Wallpaper folder<br/>~/Pictures/Wallpapers"]
            a <--> fa
        end

        subgraph peer["Peer · Arch Linux"]
            b["Syncthing<br/>Join with device ID"]
            fb["Wallpaper folder<br/>~/Pictures/Wallpapers"]
            b <--> fb
        end

        subgraph other["Optional peer · macOS / Windows"]
            c["Syncthing<br/>Pair manually"]
            fc["Wallpaper folder<br/>Choose a local directory"]
            c <--> fc
        end

        a <-->|"Encrypted file sync"| b
        a <-->|"Encrypted file sync"| c
    end

    setup -. "Local REST API" .-> a
    setup -. "Local REST API · --join" .-> b

    classDef installer fill:#7c3aed,stroke:#a78bfa,color:#ffffff,stroke-width:2px
    classDef engine fill:#0f766e,stroke:#2dd4bf,color:#ffffff,stroke-width:2px
    classDef folder fill:#1e293b,stroke:#94a3b8,color:#f8fafc
    class setup installer
    class a,b,c engine
    class fa,fb,fc folder
    style network fill:transparent,stroke:#94a3b8,stroke-dasharray:5 5
    style first fill:transparent,stroke:#a78bfa
    style peer fill:transparent,stroke:#2dd4bf
    style other fill:transparent,stroke:#94a3b8
```

Solid arrows show two-way file sync; dotted arrows show setup only. Syncthing
handles discovery and encrypted transport, directly or through a relay. The first
machine introduces trusted peers; it is not a central file server. Accept each
peer **and share the folder** before syncing. This syncs files, not the desktop's
active wallpaper selection.

## Setup

The installer targets Arch Linux with a systemd user session and uses pacman for missing packages.
Syncthing's local HTTP GUI must be enabled. **No cloning required—leave an existing
Syncthing instance running.**

On the first machine:

```bash
curl -fsSL https://raw.githubusercontent.com/opx0/syncwlp/main/syncwlp-setup.sh | bash
```

Setup prints a ready-to-copy command for each peer, including your device ID.
The command has this form (replace `FIRST_MACHINE_ID`):

```bash
curl -fsSL https://raw.githubusercontent.com/opx0/syncwlp/main/syncwlp-setup.sh | bash -s -- --join FIRST_MACHINE_ID
```

These commands execute the downloaded script. To inspect it first, open
[`syncwlp-setup.sh`](syncwlp-setup.sh). To check an existing setup without changes:

```bash
curl -fsSL https://raw.githubusercontent.com/opx0/syncwlp/main/syncwlp-setup.sh | bash -s -- --check
```

In the first machine's Syncthing UI, accept each peer and share **Wallpapers**
with it. Peers trust the first machine as an introducer. File edits and
deletions sync both ways.

The folder ID defaults to `wallpapers`. To override it, set
`SYNCWLP_FOLDER_ID` to the same value on every machine before setup. The printed
invite command includes the folder ID automatically.

On Windows or macOS, pair the device in Syncthing and accept the shared folder
at your preferred wallpaper directory.

Existing folder settings, device identity, peer trust settings, and wallpaper
watchers are preserved. Missing peers are added only when you use `--join`.

[MIT license](LICENSE)
