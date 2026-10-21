# Tools Collection

A grab bag of small scripts and macOS helpers, kept here so they don't get
lost and stay easy to reuse or modify. Each tool stands on its own; there's
nothing to install for the repo as a whole. Many of them have paths,
account names or IDs hardcoded near the top of the file, so check those
before running one on a new machine.

| Tool | Language | What it does |
| --- | --- | --- |
| [vmboot.sh](#vmbootsh) | Bash | Pick an ISO or existing VM from a menu and boot it in QEMU |
| [setup_wp.sh](#setup_wpsh) | Bash | Stand up a new WordPress site behind Apache on a Linux server |
| [github_mirror.py](#github_mirrorpy) | Python | Mirror every bare repo on a self-hosted git server to GitHub |
| [convert.py](#convertpy) | Python | Convert a tree of FLAC files to 320 kbps MP3 |
| [convert.sh](#convertsh) | Bash | Convert `.mp4` files to ProRes 422 `.mov` for Mac editing |
| [compress-audio.app](#compress-audioapp) | Automator | Pick audio files and encode them to MP3 |
| [music.py](#musicpy) | Python | Log audio file metadata to a Google Sheet |
| [set_audio.swift](#set_audioswift) | Swift | Set the default macOS app for common audio formats |
| [Logic-Mainstage](#logic-mainstage) | AppleScript | Open a Logic Pro project and a MainStage concert together |
| [web-to-stem.scpt](#web-to-stemscpt) | AppleScript | Download audio from a URL and stem-split it in Logic Pro |
| [unzipdir.py](#unzipdirpy) | Python | Extract every `.zip` in a folder into its own subfolder |
| [zipremove.py](#zipremovepy) | Python | Strip unwanted entries out of ROM-set zip files, in place |
| [sizegetter.py](#sizegetterpy) | Python | Total the MiB/GiB sizes on lines matching a keyword |
| [lsblk.py](#lsblkpy) | Python | An `lsblk`-style disk listing for FreeBSD |
| [cpp-project-gen.py](#cpp-project-genpy) | Python | Scaffold a CMake + GoogleTest C++ project |
| [packet.py](#packetpy) | Python | Send a single crafted UDP broadcast frame with Scapy |

---

## Virtual machines

### vmboot.sh

Menu-driven QEMU launcher for macOS. It lists the `.iso`/`.img` files in
`~/Downloads` plus any VMs already in `~/VMs`, works out the guest
architecture (from the file name, the ISO volume label, or the EFI loader
inside the image), creates a qcow2 disk for new VMs, and boots it. It uses
HVF acceleration when the guest matches the host CPU and falls back to TCG
emulation when it doesn't. arm64 guests default to a serial console in the
terminal; x86 guests default to a Cocoa window.

```bash
./vmboot.sh                     # pick from ~/Downloads and ~/VMs
./vmboot.sh -s ~/isos -m 4G -c 4
./vmboot.sh -n                  # dry run: print the QEMU command only
./vmboot.sh -h                  # all options
```

Each VM lives in `~/VMs/<name>/` as `disk.qcow2` plus an `arch` file
(override the location with `VM_ROOT`). Quit a serial-console guest with
Ctrl-A then X.

**Needs:** `brew install qemu`.

---

## Servers and git

### setup_wp.sh

Provisions a new WordPress site on a RHEL-style host (Apache `httpd`,
php-fpm, MySQL/MariaDB, SELinux). It prompts for a domain and admin email,
then:

1. picks the next free port after the last `Listen` in
   `/etc/httpd/conf.d/ports.conf`;
2. creates a database and user with a random password;
3. unpacks WordPress into `/mnt/storage/www/<domain>` (from a local
   `latest.tar.gz`/`latest.zip`, or via `wp core download`);
4. writes `wp-config.php` (honouring `X-Forwarded-Proto` so it works behind
   an HTTPS proxy), an Apache vhost, and SELinux port/file labels;
5. installs WordPress and the Wordfence plugin, then restarts `httpd` and
   `php-fpm`.

It prints the generated DB and admin credentials at the end, and reminds you
to point the domain at `http://localhost:<port>` in Cloudflare. If the
database, web directory or vhost already exists, it asks before replacing it.

```bash
sudo ./setup_wp.sh
```

**Needs:** root, `mysql`, `wp` (WP-CLI), `openssl`, and optionally `semanage`.

### github_mirror.py

Walks `LOCAL_REPOS_BASE_DIR` (default `/var/git`, e.g. a Gitea data dir) and
pushes every `*.git` repo to GitHub with `git push --mirror`. The first time
it sees a repo, it makes a mirror clone in `MIRROR_WORK_DIR` and, if
`USE_GH_FOR_REPO_CREATION` is on, creates the GitHub repo with `gh repo create`.
After that it just fetches and pushes. Logs go to the console and to
`mirror_sync_python.log` in the work directory. It's designed to run from cron.

```bash
./github_mirror.py
```

Set `GITHUB_USER_OR_ORG`, `LOCAL_REPOS_BASE_DIR`, `MIRROR_WORK_DIR` and
`GH_REPO_VISIBILITY` at the top of the file first.

**Needs:** `git`, an SSH key GitHub accepts, and `gh` (logged in) if
auto-creating repos.

---

## Audio and video

### convert.py

Recursively converts every `.flac` under the current directory to a
320 kbps MP3 in `mp3_output/`. It keeps the folder structure and copies the
tags across (as ID3v2.3).

```bash
python3 convert.py
```

To use other folders, edit the arguments to `convert_flac_to_mp3()` at the
bottom of the file. **Needs:** `ffmpeg`.

### convert.sh

Converts every `.mp4` in the current directory to ProRes 422 HQ with
uncompressed PCM audio, writing `.mov` files into `mac_ready/`. This is
useful for footage that Final Cut or iMovie won't import cleanly.

```bash
cd ~/footage && /path/to/convert.sh
```

**Needs:** `ffmpeg`.

### compress-audio.app

An Automator app. When you launch it, it asks you to pick audio files in
Finder and encodes them to MP3 with Automator's **Encode to MPEG Audio**
action. To change the encoding settings, open it in Automator.

### music.py

Walks a folder of audio files (`.mp3`, `.wav`, `.flac`, `.aac`, `.ogg`) and
appends one row per file to a Google Sheet: file name, duration (m:ss), size
in KB, and creation date. It adds a header row if the sheet is empty.

Before running it, set `audio_dir`, `SPREADSHEET_ID` and
`SERVICE_ACCOUNT_FILE` (a Google service-account JSON key that has access to
the sheet) in the script.

```bash
python3 music.py
```

**Needs:** `pip install pydub gspread google-auth`, plus `ffmpeg` for
pydub to decode non-WAV files.

### set_audio.swift

Makes one app (QuickTime Player by default) the default handler for MP3,
M4A/AAC, WAV, AIFF and AIFC files using Launch Services. To use a different
player, change `preferredPlayer` to its bundle ID. Some examples are in the
comments.

```bash
swift set_audio.swift
```

Finder icons may not update until you relaunch Finder or log out.

### Logic-Mainstage

`Logic-Mainstage.scpt` (source) and `Logic-Mainstage.app` (the compiled
applet) open `~/Documents/Logic.logicx` in Logic Pro and
`~/Documents/Mainstage.concert` in MainStage, then bring MainStage to the
front. The template project and concert in this repo are the ones it expects.
Copy them to `~/Documents` or change the paths in the script.

### web-to-stem.scpt

Takes a URL, downloads its audio as MP3 with `yt-dlp`, opens the
`web-to-stem.logicx` template in Logic Pro, imports the audio, and runs
Logic's **Stem Splitter** on it. It drives Logic's menus through System
Events, so the terminal running it needs Accessibility permission. The
fixed `delay`s may need tuning on slower machines.

```bash
osascript web-to-stem.scpt "https://www.youtube.com/watch?v=…"
```

**Needs:** `yt-dlp` at `/opt/homebrew/bin/yt-dlp`, and the template at
`~/Documents/web-to-stem.logicx`.

---

## Files and archives

### unzipdir.py

Extracts each `.zip` in a directory into a sibling folder named after the
zip, so `foo.zip` goes into `foo/`.

```bash
python3 unzipdir.py ~/Downloads/batch
```

### zipremove.py

Filters ROM-set archives. It rewrites each zip **in place**, keeping only
entries whose names contain `(USA`, `(Proto` or `[BIOS` and deleting
everything else. It takes a single zip or a directory of zips. Keep a backup;
the original archives are replaced.

```bash
python3 zipremove.py ~/roms/snes
python3 zipremove.py ~/roms/snes/set.zip
```

### sizegetter.py

Scans a text file (for example, a pasted download listing) for lines that
contain a keyword followed later by a size like `700 MiB` or `1.4 GiB`, and
adds up the sizes.

```bash
python3 sizegetter.py listing.txt "(USA)"
# Total size of files containing '(USA)': 12.34 GiB (12636 MiB)
```

---

## System and development

### lsblk.py

A small FreeBSD take on Linux's `lsblk`. It reads `geom disk list` and
`mount`, then prints each disk's name, size, description and mount point.

```bash
python3 lsblk.py
```

### cpp-project-gen.py

Prompts for a project name and scaffolds a C++17 CMake project:
`include/<name>/`, `src/`, `tests/` (with a GoogleTest example),
`third_party/`, `build/`, `docs/`, plus a starter `main.cpp`, `example.h`,
`example.cpp` and `README.md`.

```bash
python3 cpp-project-gen.py
```

### packet.py

Builds one Ethernet/IP/UDP frame (from `192.168.1.1:14236` to the broadcast
address on port `14235`) and sends it with Scapy. It's handy for poking at a
device or VM listening on that port. Edit the MACs, IPs and ports at the top
to suit.

```bash
sudo python3 packet.py
```

**Needs:** `pip install scapy` and root, for raw sockets.
