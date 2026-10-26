#!/usr/bin/env bash
# alac2flac.sh — convert ALAC (.m4a) to FLAC with the reference encoder (libFLAC)
#
# Run without arguments or with --help for usage.
#
# Per file: ffmpeg decodes ALAC to a temporary WAV at the source bit depth,
# flac (libFLAC) encodes it with --verify and writes tags and cover art,
# then an optional end-to-end check compares the decoded audio of source
# and result. Works with macOS' stock bash 3.2 and with Linux.

set -uo pipefail

PROG="${0##*/}"

usage() {
  cat <<EOF
Usage: $PROG [OPTIONS] SOURCE [OUTPUT]

Convert ALAC (.m4a) files to FLAC using the reference encoder (libFLAC).
Tags and embedded cover art are carried over; non-ALAC files (e.g. AAC)
are skipped.

SOURCE is a folder:
  Converts every .m4a file in it, recursively.
  OUTPUT omitted     .flac files are written next to the originals
  OUTPUT folder      the folder structure is mirrored there

SOURCE is a single file:
  OUTPUT omitted     the .flac is written next to the original
  OUTPUT folder      the .flac is written into that folder
  OUTPUT *.flac      the .flac is written to exactly that path

Options:
  -j, --jobs N       parallel conversions (default: number of CPU cores)
  -l, --level N      FLAC compression level 0-8 (default: 8)
      --no-verify    skip the end-to-end audio check (flac --verify still runs)
  -f, --force        reconvert even if the .flac already exists
  -h, --help         show this help

Results:
  OK      converted cleanly
  WARN    converted, but ffmpeg reported decoding errors: review the file
          (often harmless, e.g. an empty last frame; sometimes real damage)
  FAIL    not converted
  SKIP    not ALAC
  EXIST   .flac already exists (use --force to reconvert)

In folder mode, WARN and FAIL entries are appended to OUTPUT/alac2flac.log.
Exit status: 0 if nothing failed, 1 if a file failed, 2 on usage errors.

Requires: ffmpeg, ffprobe, flac, metaflac, jq
  macOS: brew install ffmpeg flac jq

Examples:
  $PROG ~/Music/ALAC ~/Music/FLAC
  $PROG -j 4 -l 5 ~/Music/ALAC
  $PROG "01 Song.m4a"
  $PROG --force "01 Song.m4a" ~/Desktop/
EOF
}

die_usage() {
  echo "$PROG: $*" >&2
  echo "Try '$PROG --help' for more information." >&2
  exit 2
}

# ---------------------------------------------------------------- options

[[ $# -eq 0 ]] && { usage; exit 0; }

JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"
LEVEL="${LEVEL:-8}"
VERIFY="${VERIFY:-1}"
FORCE=0
POS=()

need_value() { [[ $# -ge 2 && -n "$2" ]] || die_usage "option '$1' needs a value"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)   usage; exit 0 ;;
    -j|--jobs)   need_value "$@"; JOBS="$2"; shift 2 ;;
    --jobs=*)    JOBS="${1#*=}"; shift ;;
    -l|--level)  need_value "$@"; LEVEL="$2"; shift 2 ;;
    --level=*)   LEVEL="${1#*=}"; shift ;;
    --no-verify) VERIFY=0; shift ;;
    -f|--force)  FORCE=1; shift ;;
    --)          shift; POS+=("$@"); break ;;
    -?*)         die_usage "unknown option: $1" ;;
    *)           POS+=("$1"); shift ;;
  esac
done

[[ ${#POS[@]} -ge 1 ]] || die_usage "missing SOURCE"
[[ ${#POS[@]} -le 2 ]] || die_usage "too many arguments"
[[ "$JOBS"  =~ ^[1-9][0-9]*$ ]] || die_usage "invalid number of jobs: $JOBS"
[[ "$LEVEL" =~ ^[0-8]$ ]]       || die_usage "invalid level: $LEVEL (use 0-8)"
[[ "$VERIFY" =~ ^[01]$ ]]       || die_usage "invalid VERIFY value: $VERIFY"

for bin in ffmpeg ffprobe flac metaflac jq; do
  command -v "$bin" >/dev/null || { echo "$PROG: missing dependency: $bin" >&2; exit 1; }
done

# Paths starting with "-" would be read as options by flac/metaflac.
safe_path() { case "$1" in -*) printf './%s' "$1" ;; *) printf '%s' "$1" ;; esac; }
strip_slashes() { local p="$1"; while [[ "$p" == */ && "$p" != / ]]; do p="${p%/}"; done; printf '%s' "$p"; }

SRC="$(strip_slashes "$(safe_path "${POS[0]}")")"
OUTARG="${POS[1]:-}"
[[ -n "$OUTARG" ]] && OUTARG="$(safe_path "$OUTARG")"

if [[ -d "$SRC" ]]; then
  MODE="dir"
  DST="$(strip_slashes "${OUTARG:-$SRC}")"
  [[ -e "$DST" && ! -d "$DST" ]] && die_usage "OUTPUT exists and is not a folder: $DST"
  mkdir -p "$DST" || exit 1
  LOG="$DST/alac2flac.log"
elif [[ -f "$SRC" ]]; then
  MODE="file"
  base="${SRC##*/}"; stem="${base%.*}"; [[ -z "$stem" ]] && stem="$base"
  case "$SRC" in */*) srcdir="${SRC%/*}" ;; *) srcdir="." ;; esac
  [[ -z "$srcdir" ]] && srcdir="/"
  if [[ -z "$OUTARG" ]]; then
    OUTFILE="$srcdir/$stem.flac"
  else
    case "$OUTARG" in
      *.flac|*.FLAC|*.Flac) OUTFILE="$OUTARG" ;;
      *) OUTARG="$(strip_slashes "$OUTARG")"
         [[ -e "$OUTARG" && ! -d "$OUTARG" ]] && die_usage "OUTPUT exists and is not a folder: $OUTARG"
         OUTFILE="$OUTARG/$stem.flac" ;;
    esac
  fi
  [[ "$OUTFILE" -ef "$SRC" || "$OUTFILE" == "$SRC" ]] && die_usage "output would overwrite the source: $SRC"
  LOG=""
else
  die_usage "no such file or folder: ${POS[0]}"
fi

# Run-wide status file: one line per file, "STATUS<TAB>path<TAB>message".
RUNDIR="$(mktemp -d "${TMPDIR:-/tmp}/alac2flac-run.XXXXXX")" || exit 1
STATUS="$RUNDIR/status"
: > "$STATUS"
trap 'rm -rf "$RUNDIR"' EXIT
trap 'echo; echo "$PROG: interrupted" >&2; exit 130' INT TERM

# ------------------------------------------------------------ tag mapping

# jq program: maps iTunes/MP4 tag names (as ffprobe reports them) to
# Vorbis comment names, splits "3/12" track/disc values, drops container
# noise, and passes unknown tags through in upper case.
# Output is NUL-separated "KEY=VALUE" so multi-line values (lyrics) survive.
# shellcheck disable=SC2016,SC2089  # literal jq program, not shell code
JQ_TAGS='
def m: {
  "title":"TITLE", "artist":"ARTIST", "album":"ALBUM",
  "album_artist":"ALBUMARTIST", "date":"DATE", "genre":"GENRE",
  "composer":"COMPOSER", "comment":"COMMENT", "description":"DESCRIPTION",
  "lyrics":"LYRICS", "copyright":"COPYRIGHT", "grouping":"GROUPING",
  "compilation":"COMPILATION",
  "sort_name":"TITLESORT", "sort_artist":"ARTISTSORT",
  "sort_album":"ALBUMSORT", "sort_album_artist":"ALBUMARTISTSORT",
  "sort_composer":"COMPOSERSORT",
  "musicbrainz track id":"MUSICBRAINZ_TRACKID",
  "musicbrainz release track id":"MUSICBRAINZ_RELEASETRACKID",
  "musicbrainz album id":"MUSICBRAINZ_ALBUMID",
  "musicbrainz artist id":"MUSICBRAINZ_ARTISTID",
  "musicbrainz album artist id":"MUSICBRAINZ_ALBUMARTISTID",
  "musicbrainz release group id":"MUSICBRAINZ_RELEASEGROUPID"
};
def skip: ["encoder","major_brand","minor_version","compatible_brands",
           "creation_time","itunsmpb","itunnorm","media_type","hd_video",
           "gapless_playback"];
def numpair($n; $t):
  split("/") as $p
  | ("\($n)=\($p[0])"),
    (select(($p|length) > 1 and $p[1] != "" and $p[1] != "0") | "\($t)=\($p[1])");

(.format.tags // {}) | to_entries[]
| (.key | ascii_downcase) as $k
| (.value | tostring) as $v
| if (skip | any(. == $k)) then empty
  elif $k == "track" then ($v | numpair("TRACKNUMBER"; "TRACKTOTAL"))
  elif $k == "disc"  then ($v | numpair("DISCNUMBER";  "DISCTOTAL"))
  elif m[$k] then "\(m[$k])=\($v)"
  else "\($k | ascii_upcase | gsub(" +"; "_"))=\($v)"
  end
| select(test("^[^=]+=."))
| . + "\u0000"
'

# ------------------------------------------------------- worker functions
# These run in separate bash processes (one per file), so everything they
# need is exported below.

# ffmpeg/ffprobe read "name:rest" as a protocol URL; "file:" forces a path.
ffpath() { printf 'file:%s' "$1"; }

# Hash of the decoded audio, normalised to packed 32-bit PCM so that
# 16-, 20- and 24-bit audio compares correctly regardless of decoder layout.
audio_md5() {
  ffmpeg -nostdin -v error -i "$(ffpath "$1")" -map 0:a:0 -c:a pcm_s32le -f md5 - 2>/dev/null
}

# report STATUS PATH [MESSAGE]: console line plus a line in the run status.
report() {
  local msg="${3:-}"
  msg="${msg%%$'\n'*}"; msg="${msg//$'\t'/ }"
  printf '%-5s %s\n' "$1" "$2"
  [[ -n "$msg" ]] && printf '      %s\n' "$msg"
  printf '%s\t%s\t%s\n' "$1" "$2" "$msg" >> "$STATUS"
}

# convert_one SOURCE OUTPUT_FLAC
convert_one() {
  local f="${1:-}" out="${2:-}" codec bits pcm wav cover vcodec ext t err a b
  local -a args

  # GNU xargs runs the command once even without input; ignore that call.
  [[ -n "$f" && -n "$out" ]] || return 0

  # Globals, so the traps can clean up after an interrupt.
  WORK=""; TMP_OUT="$out.part"
  trap 'rm -rf "$WORK"; rm -f "$TMP_OUT"' EXIT
  trap 'exit 130' INT TERM

  codec=$(ffprobe -v error -select_streams a:0 \
          -show_entries stream=codec_name -of csv=p=0 "$(ffpath "$f")" 2>/dev/null)
  if [[ -z "$codec" ]]; then
    report FAIL "$f" "unreadable: no audio stream found"; return 1
  fi
  if [[ "$codec" != "alac" ]]; then
    report SKIP "$f" "not ALAC ($codec)"; return 0
  fi
  if [[ -e "$out" && "$FORCE" != 1 ]]; then
    TMP_OUT=""   # never touch a .part that may belong to another run
    report EXIST "$out"; return 0
  fi
  mkdir -p "$(dirname "$out")" || { report FAIL "$f" "cannot create output folder"; return 1; }

  # Keep the source bit depth exactly (20-bit ALAC is stored as 24-bit,
  # still lossless; FLAC's wasted-bits detection handles the padding).
  bits=$(ffprobe -v error -select_streams a:0 \
         -show_entries stream=bits_per_raw_sample -of csv=p=0 "$(ffpath "$f")" 2>/dev/null)
  bits="${bits//[^0-9]/}"
  if   [[ -z "$bits" || "$bits" -le 16 ]]; then pcm=pcm_s16le
  elif [[ "$bits" -le 24 ]];               then pcm=pcm_s24le
  else                                          pcm=pcm_s32le
  fi

  WORK=$(mktemp -d "${TMPDIR:-/tmp}/alac2flac.XXXXXX") \
    || { report FAIL "$f" "cannot create temporary folder"; return 1; }
  wav="$WORK/audio.wav"

  # 1) Decode ALAC -> WAV without metadata (tags are added in step 4).
  #    ffmpeg skips frames it can't decode and still exits 0; its error
  #    output is kept and reported as WARN once the file is done.
  err=$(ffmpeg -nostdin -v error -y -i "$(ffpath "$f")" -map 0:a:0 -map_metadata -1 \
          -fflags +bitexact -c:a "$pcm" -f wav "$wav" 2>&1 >/dev/null)
  if [[ $? -ne 0 || ! -s "$wav" ]]; then
    report FAIL "$f" "decode failed: ${err:-no output}"; return 1
  fi

  # 2) Tags -> flac -T arguments
  args=()
  while IFS= read -r -d '' t; do
    args+=( -T "$t" )
  done < <(ffprobe -v error -show_entries format_tags -of json "$(ffpath "$f")" 2>/dev/null \
           | jq -j "$JQ_TAGS" 2>/dev/null)

  # 3) First embedded cover (JPEG/PNG) -> flac --picture as front cover
  vcodec=$(ffprobe -v error -select_streams v:0 \
           -show_entries stream=codec_name -of csv=p=0 "$(ffpath "$f")" 2>/dev/null)
  case "$vcodec" in
    mjpeg) ext=jpg ;;
    png)   ext=png ;;
    *)     ext="" ;;
  esac
  if [[ -n "$ext" ]]; then
    cover="$WORK/cover.$ext"
    if ffmpeg -nostdin -v error -y -i "$(ffpath "$f")" -map 0:v:0 -c:v copy \
         -frames:v 1 -f image2 "$cover" >/dev/null 2>&1 && [[ -s "$cover" ]]; then
      args+=( "--picture=3||||$cover" )
    fi
  fi

  # 4) Encode with libFLAC, with its built-in verify.
  #    --no-utf8-convert: tag values from jq are already UTF-8; without it,
  #    flac re-encodes them from the shell locale and mangles non-ASCII text.
  if ! flac -s -f --verify --no-utf8-convert -"$LEVEL" \
         "${args[@]+"${args[@]}"}" -o "$TMP_OUT" "$wav"; then
    report FAIL "$f" "flac encoding failed"; return 1
  fi

  # flac records the WAV channel mask as a tag for 24-bit sources; for
  # mono/stereo that's just the default layout, so drop the noise.
  if [[ "$(metaflac --show-channels "$TMP_OUT")" -le 2 ]]; then
    metaflac --remove-tag=WAVEFORMATEXTENSIBLE_CHANNEL_MASK "$TMP_OUT"
  fi

  # 5) End-to-end check: source audio (as ffmpeg decodes it) == FLAC audio.
  if [[ "$VERIFY" == 1 ]]; then
    a=$(audio_md5 "$f"); b=$(audio_md5 "$TMP_OUT")
    if [[ -z "$a" || "$a" != "$b" ]]; then
      report FAIL "$f" "verification failed: FLAC audio differs from source"; return 1
    fi
  fi

  mv -f "$TMP_OUT" "$out" || { report FAIL "$f" "cannot write $out"; return 1; }
  TMP_OUT=""
  if [[ -n "$err" ]]; then
    report WARN "$out" "decoding errors (review): $err"
  else
    report OK "$out"
  fi
}

# shellcheck disable=SC2090  # JQ_TAGS is passed to jq verbatim
export FORCE LEVEL VERIFY STATUS JQ_TAGS
export -f ffpath audio_md5 report convert_one

# ------------------------------------------------------------------- run

if [[ "$MODE" == file ]]; then
  # shellcheck disable=SC2016  # expanded by the child bash
  bash -c 'convert_one "$1" "$2"' _ "$SRC" "$OUTFILE"
else
  # Emit "source\0output\0" pairs; xargs hands each pair to one worker.
  # shellcheck disable=SC2016  # expanded by the child bash
  find "$SRC" -type f -iname '*.m4a' ! -name '._*' -print0 \
  | while IFS= read -r -d '' f; do
      rel="${f#"$SRC"/}"
      printf '%s\0%s\0' "$f" "$DST/${rel%.*}.flac"
    done \
  | xargs -0 -n 2 -P "$JOBS" bash -c 'convert_one "$1" "$2"' _
fi

count() { grep -c "^$1"$'\t' "$STATUS"; }
n_ok=$(count OK); n_warn=$(count WARN); n_fail=$(count FAIL)
n_skip=$(count SKIP); n_exist=$(count EXIST)
total=$((n_ok + n_warn + n_fail + n_skip + n_exist))

if [[ -n "$LOG" ]] && grep -Eq $'^(WARN|FAIL)\t' "$STATUS"; then
  {
    echo "=== $(date '+%Y-%m-%d %H:%M:%S')  $SRC"
    grep -E $'^(WARN|FAIL)\t' "$STATUS" | sort -t $'\t' -k2 \
      | while IFS=$'\t' read -r s p m; do
          printf '%-5s %s\n' "$s" "$p"
          [[ -n "$m" ]] && printf '      %s\n' "$m"
        done
  } >> "$LOG"
fi

echo
if [[ "$total" -eq 0 ]]; then
  echo "No .m4a files found in $SRC."
else
  summary="Done: $((n_ok + n_warn)) converted"
  [[ "$n_warn"  -gt 0 ]] && summary+=" ($n_warn with warnings)"
  [[ "$n_exist" -gt 0 ]] && summary+=", $n_exist already existed"
  [[ "$n_skip"  -gt 0 ]] && summary+=", $n_skip skipped (not ALAC)"
  [[ "$n_fail"  -gt 0 ]] && summary+=", $n_fail failed"
  echo "$summary."
  if [[ -n "$LOG" && $((n_warn + n_fail)) -gt 0 ]]; then
    echo "Details: $LOG"
  fi
fi

[[ "$n_fail" -eq 0 ]]
