# alac2flac

Convert ALAC (`.m4a`) files to FLAC with the reference encoder (libFLAC), keeping tags and cover art and checking that the audio is unchanged.

- **Lossless and verified:** each file is encoded with `flac --verify`, then the decoded audio of source and result is compared end to end.
- **Keeps metadata:** iTunes tags are mapped to Vorbis comments (including track/disc totals, sort fields and MusicBrainz IDs), and the embedded cover becomes the FLAC front cover.
- **Keeps the bit depth:** 16- and 24-bit sources stay as they are.
- **Works on whole libraries:** converts folders recursively in parallel, mirrors the folder structure, and skips non-ALAC files such as AAC.
- **Portable:** a single Bash script that runs on macOS' stock bash 3.2 and on Linux.

## Requirements

`ffmpeg`, `ffprobe`, `flac`, `metaflac` and `jq`.

```sh
# macOS
brew install ffmpeg flac jq

# Debian/Ubuntu
sudo apt install ffmpeg flac jq

# Fedora (ffmpeg-free includes the ALAC decoder)
sudo dnf install ffmpeg-free flac jq

# NixOS: temporary shell
nix-shell -p ffmpeg flac jq
```

To install the dependencies permanently on NixOS, add them to `configuration.nix`:

```nix
environment.systemPackages = with pkgs; [ ffmpeg flac jq ];
```

## Usage

```sh
./alac2flac.sh [OPTIONS] SOURCE [OUTPUT]
```

`SOURCE` can be a folder or a single `.m4a` file. If `OUTPUT` is omitted, `.flac` files are written next to the originals. For a folder, `OUTPUT` is a folder where the structure is mirrored. For a file, `OUTPUT` is either a folder or an exact `.flac` path.

```sh
./alac2flac.sh ~/Music/ALAC ~/Music/FLAC     # mirror a library into a new folder
./alac2flac.sh -j 4 -l 5 ~/Music/ALAC        # 4 jobs, compression level 5, in place
./alac2flac.sh "01 Song.m4a"                 # a single file
```

| Option | Description |
| --- | --- |
| `-j`, `--jobs N` | parallel conversions (default: number of CPU cores) |
| `-l`, `--level N` | FLAC compression level 0–8 (default: 8) |
| `--no-verify` | skip the end-to-end audio check (`flac --verify` still runs) |
| `-f`, `--force` | reconvert even if the `.flac` already exists |
| `-h`, `--help` | show the full help |

## Results

Each file is reported as one of the following:

| Status | Meaning |
| --- | --- |
| `OK` | converted cleanly |
| `WARN` | converted, but ffmpeg reported decoding errors, so review the file |
| `FAIL` | not converted |
| `SKIP` | not ALAC |
| `EXIST` | `.flac` already exists (use `--force` to reconvert) |

In folder mode, `WARN` and `FAIL` entries are appended to `OUTPUT/alac2flac.log`. The exit status is 0 if nothing failed, 1 if any file failed and 2 on usage errors.
