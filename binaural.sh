#!/bin/bash
#
# binaural.sh — виртуальная система 5.1 / 6.1 / 7.1 в любых наушниках на macOS.
#
# Каждый канал многоканальной дорожки (AC3, E-AC3, DTS, TrueHD, FLAC... в
# раскладке 5.1, 6.1 или 7.1) сворачивается с импульсными откликами (HRIR/BRIR)
# своей виртуальной колонки. На выходе получается бинауральное стерео: фронт
# звучит спереди, боковые каналы сбоку, тыловые сзади. Работает с любыми
# наушниками (Sony WH-1000XM6 по Bluetooth или по кабелю).
#
# Основа — фильтр headphone из FFmpeg и пресеты HeSuVi: Dolby Atmos for
# Headphones, DTS Headphone:X, Sennheiser GSX, Dolby Headphone, Windows Sonic
# и другие, а также HRTF манекенов и людей из баз ARI, CIPIC, IRCAM и прочих.
#
# Команды:
#   setup                   один раз: скачать HeSuVi и подготовить пресеты
#   list                    список пресетов
#   test  [пресет ...]      голосовой тест каналов в наушниках (сравнение пресетов)
#   filter [опции]          строка фильтра для IINA или mpv (обработка в реальном времени)
#   mpv   [опции]           прописать фильтр в ~/.config/mpv (вкл/выкл по Ctrl+b)
#   tracks файл             показать аудиодорожки файла и их номера
#   render [опции] файл     добавить в MKV бинауральную дорожку (для Infuse и любых плееров)
#   atmos  [опции] файл     настоящий объектный рендер Dolby Atmos из TrueHD: объекты с их
#                           координатами раскладываются по виртуальной системе 7.1.4
#                           и добавляются в MKV бинауральной дорожкой
#
# Опции filter / mpv / render / atmos:
#   -p, --preset ИМЯ        пресет (по умолчанию atmos), список: ./binaural.sh list
#   -g, --gain ДБ           усиление после свёртки (по умолчанию 22)
#   -l, --lfe ДБ            уровень сабвуферного канала LFE относительно остальных (по умолчанию 0)
#   -e, --eq ПРОФИЛЬ        коррекция АЧХ наушников: none (по умолчанию),
#                           xm6-bt-kuulokenurkka, xm6-bt-superreview,
#                           xm6-cable-superreview или путь к файлу AutoEq *ParametricEQ.txt
# Только для render:
#   -a, --audio N           номер исходной аудиодорожки (см. tracks), по умолчанию —
#                           дорожка с наибольшим числом каналов
#   -s, --surround ПОЗИЦИЯ  куда ставить тылы 5.1: side (90°, по умолчанию),
#                           back (135–150°), wide (между ними, ≈110° как в ITU-R BS.775)
#   -c, --codec КОДЕК       flac (по умолчанию, без потерь) или aac (320 кбит/с, меньше размер)
#   -o, --output ФАЙЛ       куда писать (по умолчанию «имя.binaural-пресет.mkv»)
#   -f, --force             перезаписать существующий файл
# Только для atmos (кроме того, работают -p -g -l -e -a -c -o -f):
#   -H, --height СИЛА       выраженность признака высоты у потолочных колонок:
#                           0 — без него, 1 — по умолчанию, 1.5 — сильнее
#   -m, --master ФАЙЛ.atmos готовый мастер от truehdd decode (с --bed-conform или без):
#                           извлечение пропускается, файл фильма нужен для видео и дорожек
# Временные файлы atmos (~1 ГБ на 6 минут фильма) пишутся рядом с результатом;
# другой каталог можно задать переменной BINAURAL_TMP.

set -eu

BASE="${BINAURAL_HOME:-$HOME/Binaural}"
HRIR_DIR="$BASE/hrir16"
HESUVI_URL="${HESUVI_URL:-https://sourceforge.net/projects/hesuvi/files/HeSuVi_2.0.0.1.exe/download}"
HESUVI_SHA256="a31774714d8f7a87ae4fd5bdbaa4bfa294a808296bdcc9e9935da4b427a601ba"
HESUVI_7Z_OFFSET=125112   # начало 7z-архива внутри самораспаковывающегося HeSuVi_2.0.0.1.exe

DEF_PRESET="atmos"
DEF_GAIN=22                # громкость ≈ как у обычного стереодаунмикса
DEF_LFE=0
TARGET_LUFS="-50.7"        # громкость эталонного шума через atmos при gain=0; к ней приводятся все пресеты

# Порядок пар (левое ухо, правое ухо) в 16-канальном файле для headphone:hrir=multich.
MAP="FL|FR|FC|LFE|BL|BR|SL|SR"
# HeSuVi, 14 каналов: FL-l FL-r SL-l SL-r BL-l BL-r FC-l FR-r FR-l SR-r SR-l BR-r BR-l FC-r
PAN14="pan=16c|c0=c0|c1=c1|c2=c8|c3=c7|c4=c6|c5=c13|c6=c6|c7=c13|c8=c4|c9=c5|c10=c12|c11=c11|c12=c2|c13=c3|c14=c10|c15=c9"
# HeSuVi, 7 каналов (симметричные HRIR): FL-l FL-r SL-l SL-r BL-l BL-r FC, правая сторона — зеркально
PAN7="pan=16c|c0=c0|c1=c1|c2=c1|c3=c0|c4=c6|c5=c6|c6=c6|c7=c6|c8=c4|c9=c5|c10=c5|c11=c4|c12=c2|c13=c3|c14=c3|c15=c2"

# Профили AutoEq (цель Harman over-ear) для WH-1000XM6, github.com/jaakkopasanen/AutoEq
EQ_XM6_BT_KUULOKENURKKA="Preamp: -4.4 dB
Filter 1: ON LSC Fc 105 Hz Gain -4.0 dB Q 0.70
Filter 2: ON PK Fc 181 Hz Gain -2.7 dB Q 0.79
Filter 3: ON PK Fc 7457 Hz Gain 5.2 dB Q 1.98
Filter 4: ON PK Fc 1298 Hz Gain 4.2 dB Q 1.37
Filter 5: ON PK Fc 2112 Hz Gain -2.9 dB Q 1.13
Filter 6: ON HSC Fc 10000 Hz Gain -4.1 dB Q 0.70
Filter 7: ON PK Fc 53 Hz Gain 0.6 dB Q 1.86
Filter 8: ON PK Fc 637 Hz Gain -0.9 dB Q 3.67
Filter 9: ON PK Fc 840 Hz Gain 0.9 dB Q 4.20
Filter 10: ON PK Fc 93 Hz Gain -0.2 dB Q 1.45"
EQ_XM6_BT_SUPERREVIEW="Preamp: -4.6 dB
Filter 1: ON LSC Fc 105 Hz Gain -8.3 dB Q 0.70
Filter 2: ON PK Fc 171 Hz Gain -4.9 dB Q 0.99
Filter 3: ON PK Fc 648 Hz Gain 2.5 dB Q 0.63
Filter 4: ON PK Fc 2499 Hz Gain -5.2 dB Q 1.50
Filter 5: ON PK Fc 5689 Hz Gain 4.1 dB Q 0.40
Filter 6: ON HSC Fc 10000 Hz Gain 3.3 dB Q 0.70
Filter 7: ON PK Fc 4137 Hz Gain 1.3 dB Q 3.44
Filter 8: ON PK Fc 6747 Hz Gain -2.2 dB Q 3.84
Filter 9: ON PK Fc 1496 Hz Gain -1.5 dB Q 3.88
Filter 10: ON PK Fc 1151 Hz Gain 1.4 dB Q 4.07"
EQ_XM6_CABLE_SUPERREVIEW="Preamp: -6.7 dB
Filter 1: ON LSC Fc 105 Hz Gain -1.5 dB Q 0.70
Filter 2: ON PK Fc 161 Hz Gain -7.5 dB Q 0.69
Filter 3: ON PK Fc 2143 Hz Gain 4.3 dB Q 3.66
Filter 4: ON PK Fc 1019 Hz Gain -5.3 dB Q 1.74
Filter 5: ON PK Fc 8308 Hz Gain 5.3 dB Q 0.21
Filter 6: ON HSC Fc 10000 Hz Gain -1.5 dB Q 0.70
Filter 7: ON PK Fc 57 Hz Gain -2.0 dB Q 2.27
Filter 8: ON PK Fc 463 Hz Gain 1.5 dB Q 2.87
Filter 9: ON PK Fc 103 Hz Gain 1.7 dB Q 2.95
Filter 10: ON PK Fc 4339 Hz Gain 0.9 dB Q 3.49"

# ---------------------------------------------------------------- helpers

WORK=""
HRIR714=""
trap 'rm -rf "${WORK:-}" "${HRIR714:-}"' EXIT

die()  { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

sha256_of() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
    else sha256sum "$1" | awk '{print $1}'; fi
}

need_ffmpeg() {
    if ! command -v ffmpeg >/dev/null 2>&1 || ! command -v ffprobe >/dev/null 2>&1; then
        if command -v brew >/dev/null 2>&1; then
            step "Устанавливаю ffmpeg через Homebrew…"
            brew install ffmpeg
        else
            die "нужен ffmpeg. Установите Homebrew (https://brew.sh), затем: brew install ffmpeg"
        fi
    fi
    ffmpeg -hide_banner -filters 2>/dev/null | grep -q ' headphone ' \
        || die "в вашей сборке ffmpeg нет фильтра headphone"
}

need_presets() {
    [ -f "$HRIR_DIR/$DEF_PRESET.wav" ] || die "пресеты не найдены, сначала выполните: $0 setup"
}

preset_file() {
    local f="$HRIR_DIR/$1.wav"
    [ -f "$f" ] || die "нет пресета «$1». Список: $0 list"
    case "$f" in
        *[\',\;\[\]:\\\"]*) die "путь $f содержит символы , ; : [ ] ' \" \\ — задайте другой каталог через BINAURAL_HOME" ;;
    esac
    printf '%s' "$f"
}

is_number() { printf '%s' "$1" | grep -Eq '^[+-]?[0-9]+([.][0-9]+)?$'; }

# Профиль AutoEq -> цепочка фильтров ffmpeg (пусто для none).
eq_chain() {
    local txt
    case "$1" in
        ""|none) return 0 ;;
        xm6-bt-kuulokenurkka)  txt=$EQ_XM6_BT_KUULOKENURKKA ;;
        xm6-bt-superreview)    txt=$EQ_XM6_BT_SUPERREVIEW ;;
        xm6-cable-superreview) txt=$EQ_XM6_CABLE_SUPERREVIEW ;;
        *) [ -f "$1" ] || die "неизвестный профиль EQ «$1»"; txt=$(cat "$1") ;;
    esac
    printf '%s\n' "$txt" | tr -d '\r' | awk '
        /^Preamp:/ { printf "%svolume=%sdB", sep, $2; sep = "," }
        /^Filter/ && $3 == "ON" {
            t = $4; f = $6; g = $9; q = $12
            if (t == "PK")                   name = "equalizer"
            else if (t == "LSC" || t == "LS") name = "lowshelf"
            else if (t == "HSC" || t == "HS") name = "highshelf"
            else next
            printf "%s%s=f=%s:t=q:w=%s:g=%s", sep, name, f, q, g; sep = ","
        }'
}

# Граф lavfi: вход — любая раскладка, выход — бинауральное стерео.
# $1 пресет, $2 gain, $3 lfe, $4 eq, $5 дополнительный pan после приведения к 7.1 (может быть пустым)
core_graph() {
    local hrir eqc
    hrir=$(preset_file "$1") || exit 1
    eqc=$(eq_chain "$4") || exit 1
    printf 'aformat=channel_layouts=7.1%s[a];amovie=%s[h];[a][h]headphone=map=%s:hrir=multich:gain=%s:lfe=%s%s,alimiter=level=false:limit=0.97' \
        "${5:+,$5}" "$hrir" "$MAP" "$2" "$3" "${eqc:+,$eqc}"
}

# Общие опции -p -g -l -e. Результат в OPT_*; остаток аргументов — в REST (строка через \n).
parse_common() {
    OPT_PRESET=$DEF_PRESET; OPT_GAIN=$DEF_GAIN; OPT_LFE=$DEF_LFE; OPT_EQ=none
    OPT_AUDIO=""; OPT_SURROUND=side; OPT_CODEC=flac; OPT_OUT=""; OPT_FORCE=0; OPT_FILE=""; OPT_HEIGHT=1; OPT_MASTER=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -p|--preset)   OPT_PRESET=${2:?}; shift 2 ;;
            -g|--gain)     OPT_GAIN=${2:?};   shift 2 ;;
            -l|--lfe)      OPT_LFE=${2:?};    shift 2 ;;
            -e|--eq)       OPT_EQ=${2:?};     shift 2 ;;
            -a|--audio)    OPT_AUDIO=${2:?};  shift 2 ;;
            -s|--surround) OPT_SURROUND=${2:?}; shift 2 ;;
            -c|--codec)    OPT_CODEC=${2:?};  shift 2 ;;
            -o|--output)   OPT_OUT=${2:?};    shift 2 ;;
            -f|--force)    OPT_FORCE=1;       shift ;;
            -H|--height)   OPT_HEIGHT=${2:?}; shift 2 ;;
            -m|--master)   OPT_MASTER=${2:?}; shift 2 ;;
            -h|--help)     usage; exit 0 ;;
            -*)            die "неизвестная опция $1" ;;
            *)             [ -z "$OPT_FILE" ] || die "лишний аргумент $1"; OPT_FILE=$1; shift ;;
        esac
    done
    is_number "$OPT_GAIN" || die "gain должен быть числом"
    is_number "$OPT_LFE"  || die "lfe должен быть числом"
    is_number "$OPT_HEIGHT" || die "height должен быть числом"
}

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

# ---------------------------------------------------------------- setup

cmd_setup() {
    need_ffmpeg
    local tmp exe src sum n=0 f name ch pan lufs off
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/binaural.XXXXXX"); tmp=$WORK
    exe="$tmp/HeSuVi.exe"

    step "Скачиваю HeSuVi 2.0.0.1 (≈27 МБ) с SourceForge…"
    curl -fL --retry 3 -o "$exe" "$HESUVI_URL"
    sum=$(sha256_of "$exe")

    step "Распаковываю импульсные отклики…"
    if command -v 7zz >/dev/null 2>&1; then
        7zz x -y -o"$tmp" "$exe" 'HeSuVi/hrir/*' >/dev/null
    elif command -v 7z >/dev/null 2>&1; then
        7z x -y -o"$tmp" "$exe" 'HeSuVi/hrir/*' >/dev/null
    elif [ "$sum" = "$HESUVI_SHA256" ]; then
        # Установщик — самораспаковывающийся 7z; системный tar (libarchive) читает сам архив.
        tail -c +$((HESUVI_7Z_OFFSET + 1)) "$exe" > "$tmp/hesuvi.7z"
        (cd "$tmp" && LC_ALL=en_US.UTF-8 tar -xf hesuvi.7z HeSuVi/hrir 2>/dev/null) || true
    else
        die "скачан неожиданный файл (sha256 $sum). Установите 7-Zip: brew install sevenzip — и повторите"
    fi
    src="$tmp/HeSuVi/hrir"
    [ -f "$src/atmos.wav" ] || die "не удалось распаковать HeSuVi"

    mkdir -p "$HRIR_DIR"
    cp "$src/info.csv" "$HRIR_DIR/info.csv"
    [ -f "$src/more/info.csv" ] && cp "$src/more/info.csv" "$HRIR_DIR/info-more.csv"

    # Эталонный шум 5.1 для выравнивания громкости пресетов (честное сравнение на слух).
    ffmpeg -nostdin -hide_banner -loglevel error -y -filter_complex "\
anoisesrc=c=pink:a=0.1:r=48000:d=4:seed=1[a0];anoisesrc=c=pink:a=0.1:r=48000:d=4:seed=2[a1];\
anoisesrc=c=pink:a=0.1:r=48000:d=4:seed=3[a2];anoisesrc=c=pink:a=0.1:r=48000:d=4:seed=4,lowpass=f=100[a3];\
anoisesrc=c=pink:a=0.1:r=48000:d=4:seed=5[a4];anoisesrc=c=pink:a=0.1:r=48000:d=4:seed=6[a5];\
[a0][a1][a2][a3][a4][a5]join=inputs=6:channel_layout=5.1(side)" -c:a pcm_f32le "$tmp/noise.wav"

    step "Готовлю пресеты для FFmpeg (перестановка каналов и выравнивание громкости)…"
    for f in "$src"/*.wav "$src"/more/*.wav; do
        [ -f "$f" ] || continue
        name=$(basename "$f" .wav)
        case "$name" in dvs|dvs+|none) continue ;; esac   # dvs — для колонок, none — без обработки
        ch=$(ffprobe -v error -show_entries stream=channels -of csv=p=0 "$f")
        case "$ch" in 14) pan=$PAN14 ;; 7) pan=$PAN7 ;; *) continue ;; esac
        ffmpeg -nostdin -hide_banner -loglevel error -y -i "$f" -af "$pan" -c:a pcm_f32le "$tmp/raw.wav"
        lufs=$(ffmpeg -nostdin -hide_banner -nostats -i "$tmp/noise.wav" -filter_complex \
            "[0:a]aformat=channel_layouts=7.1[a];amovie=$tmp/raw.wav[h];[a][h]headphone=map=$MAP:hrir=multich,ebur128" \
            -f null - 2>&1 | awk '/^ *I:/ { v = $2 } END { print v }')
        off=$(awk -v t="$TARGET_LUFS" -v l="$lufs" 'BEGIN { printf "%.2f", (l == "" ? 0 : t - l) }')
        ffmpeg -nostdin -hide_banner -loglevel error -y -i "$tmp/raw.wav" -af "volume=${off}dB" \
            -c:a pcm_f32le "$HRIR_DIR/$name.wav"
        n=$((n + 1))
        printf '\r  готово: %d' "$n"
    done
    printf '\n'
    step "Пресеты ($n шт.) лежат в $HRIR_DIR"
    cat <<EOF

Дальше:
  $0 test                    — послушать, как каналы встают по местам (несколько пресетов подряд)
  $0 filter -p atmos         — строка для IINA
  $0 mpv    -p atmos         — включить в mpv
  $0 render -p atmos фильм.mkv — дорожка для Infuse
EOF
}

# ---------------------------------------------------------------- list

cmd_list() {
    need_presets
    local f name desc
    for f in "$HRIR_DIR"/*.wav; do
        name=$(basename "$f" .wav)
        desc=$(awk -F';' -v n="$name" '
            FNR == 1 { sub(/^[^A-Za-z0-9*]+/, "", $1) }
            $1 == n { e = $2 }
            w == "" && $1 ~ /[*]$/ && $1 != "*" && index(n, substr($1, 1, length($1) - 1)) == 1 { w = $2 }
            END { print (e != "" ? e : w) }' "$HRIR_DIR/info.csv" "$HRIR_DIR/info-more.csv" 2>/dev/null)
        printf '%-14s %s\n' "$name" "$(printf '%s' "$desc" | sed 's#/n/n# — #; s#/n# #g')"
    done
}

# ---------------------------------------------------------------- filter / mpv

cmd_filter() {
    need_presets
    parse_common "$@"
    local g
    g=$(core_graph "$OPT_PRESET" "$OPT_GAIN" "$OPT_LFE" "$OPT_EQ" "")
    cat <<EOF
IINA — «Аудио → Аудиофильтры…» → «+» → «Custom (mpv)»: имя lavfi, строка — всё после «lavfi=»;
либо «Сохранённые фильтры» → «+» (можно назначить сочетание клавиш), строка целиком:

lavfi="$g"

mpv / «Дополнительные параметры mpv» в IINA (Настройки → Дополнительно), параметр af:

@binaural:lavfi="$g"
EOF
}

write_block() { # файл, содержимое — заменяет прошлый блок binaural.sh или дописывает новый
    local file=$1 body=$2 tmp
    mkdir -p "$(dirname "$file")"
    touch "$file"
    tmp=$(mktemp "${TMPDIR:-/tmp}/binaural.XXXXXX")
    awk '/^# >>> binaural.sh >>>$/ { skip = 1 } !skip { print } /^# <<< binaural.sh <<<$/ { skip = 0 }' "$file" > "$tmp"
    printf '# >>> binaural.sh >>>\n%s\n# <<< binaural.sh <<<\n' "$body" >> "$tmp"
    mv "$tmp" "$file"
}

cmd_mpv() {
    need_presets
    parse_common "$@"
    local dir="${MPV_HOME:-$HOME/.config/mpv}" g
    g=$(core_graph "$OPT_PRESET" "$OPT_GAIN" "$OPT_LFE" "$OPT_EQ" "")
    write_block "$dir/mpv.conf" "af=@binaural:lavfi=\"$g\""
    write_block "$dir/input.conf" "Ctrl+b af toggle @binaural ; show-text \"binaural: переключено\""
    echo "Готово: $dir/mpv.conf и $dir/input.conf (пресет $OPT_PRESET). Ctrl+b в mpv — вкл/выкл для сравнения."
}

# ---------------------------------------------------------------- tracks / render

# Аргументы кодека для новой аудиодорожки с номером $1 (по счёту среди аудиодорожек результата).
codec_args() {
    case "$OPT_CODEC" in
        flac) printf '%s' "-c:a:$1 flac -sample_fmt:a:$1 s32 -bits_per_raw_sample:a:$1 24" ;;
        aac)  if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q ' aac_at '; then
                  printf '%s' "-c:a:$1 aac_at -b:a:$1 320k"
              else
                  printf '%s' "-c:a:$1 aac -b:a:$1 320k"
              fi ;;
        *) die "--codec: flac или aac" ;;
    esac
}

cmd_tracks() {
    [ -n "${1:-}" ] && [ -f "$1" ] || die "укажите файл"
    ffprobe -v error -select_streams a \
        -show_entries stream=codec_name,profile,channels,channel_layout:stream_tags=language,title \
        -of default=nw=1 "$1" | awk -F= '
        /^codec_name=/ { if (n++) print line; line = sprintf("-a %d:", n - 1) }
        { v = substr($0, index($0, "=") + 1); if (v != "" && v != "unknown") line = line " " v }
        END { if (n) print line }'
}

cmd_render() {
    need_ffmpeg
    need_presets
    parse_common "$@"
    local in=$OPT_FILE out nb aidx layout lang g pan="" codec sub_args="" ow=-n
    [ -n "$in" ] && [ -f "$in" ] || die "укажите файл фильма"

    nb=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$in" | wc -l | tr -d ' ')
    [ "$nb" -gt 0 ] || die "в файле нет аудиодорожек"
    if [ -n "$OPT_AUDIO" ]; then
        aidx=$OPT_AUDIO
        [ "$aidx" -ge 0 ] 2>/dev/null && [ "$aidx" -lt "$nb" ] || die "нет аудиодорожки -a $aidx (см. $0 tracks)"
    else
        aidx=$(ffprobe -v error -select_streams a -show_entries stream=channels -of csv=p=0 "$in" |
            awk '{ if ($1 + 0 > m) { m = $1 + 0; i = NR - 1 } } END { print i + 0 }')
    fi
    layout=$(ffprobe -v error -select_streams "a:$aidx" -show_entries stream=channel_layout -of csv=p=0 "$in")
    lang=$(ffprobe -v error -select_streams "a:$aidx" -show_entries stream_tags=language -of csv=p=0 "$in")
    echo "Исходная дорожка: -a $aidx, раскладка ${layout:-неизвестна}"
    case "$layout" in
        stereo|mono|"") echo "Внимание: дорожка не многоканальная — будет лишь имитация стереоколонок." ;;
    esac

    # Тылы 5.x (одна пара колонок): где их разместить.
    case "$layout" in
        5.0*|5.1*|4.0|4.1|quad*)
            case "$OPT_SURROUND" in
                side) pan="pan=7.1|FL=FL|FR=FR|FC=FC|LFE=LFE|BL=0*BL|BR=0*BR|SL=SL+BL|SR=SR+BR" ;;
                back) pan="pan=7.1|FL=FL|FR=FR|FC=FC|LFE=LFE|BL=BL+SL|BR=BR+SR|SL=0*SL|SR=0*SR" ;;
                wide) pan="pan=7.1|FL=FL|FR=FR|FC=FC|LFE=LFE|BL=0.7071*BL+0.7071*SL|BR=0.7071*BR+0.7071*SR|SL=0.7071*SL+0.7071*BL|SR=0.7071*SR+0.7071*BR" ;;
                *) die "--surround: side, back или wide" ;;
            esac ;;
    esac

    out=${OPT_OUT:-"${in%.*}.binaural-$OPT_PRESET.mkv"}
    [ "$out" != "$in" ] || die "выходной файл совпадает со входным"
    [ ! -e "$out" ] || [ "$OPT_FORCE" = 1 ] || die "$out уже существует (добавьте -f)"

    codec=$(codec_args "$nb")

    [ "$OPT_FORCE" = 1 ] && ow=-y
    case "$in" in *.[mM][pP]4|*.[mM]4[vV]|*.[mM][oO][vV]) sub_args="-c:s srt" ;; esac   # mov_text в MKV не кладётся
    g=$(core_graph "$OPT_PRESET" "$OPT_GAIN" "$OPT_LFE" "$OPT_EQ" "$pan")
    g="[0:a:$aidx]${g}[bin]"
    step "Рендер: пресет $OPT_PRESET → $out"
    # shellcheck disable=SC2086
    ffmpeg -nostdin -hide_banner -loglevel error -stats $ow \
        -i "$in" -filter_complex "$g" \
        -map '0:v?' -map 0:a -map '0:s?' -map '0:t?' -map '[bin]' \
        -c copy $codec $sub_args \
        -metadata:s:a:$nb title="Binaural ($OPT_PRESET)" \
        -metadata:s:a:$nb language="${lang:-und}" \
        -disposition:a 0 -disposition:a:$nb default \
        -max_muxing_queue_size 4096 \
        "$out"
    echo "Готово. В плеере выберите аудиодорожку «Binaural ($OPT_PRESET)»."
}

# ---------------------------------------------------------------- atmos

PYTHON=${PYTHON:-python3}
TRUEHDD_API="https://api.github.com/repos/truehdd/truehdd/releases/latest"

need_python() {
    command -v "$PYTHON" >/dev/null 2>&1 || die "нужен Python 3 (python3)"
    if ! "$PYTHON" -c 'import numpy' 2>/dev/null; then
        step "Устанавливаю numpy для Python…"
        "$PYTHON" -m pip install --user numpy || die "не удалось установить numpy: $PYTHON -m pip install numpy"
    fi
}

# Декодер TrueHD с поддержкой объектов Atmos: github.com/truehdd/truehdd (Apache-2.0).
need_truehdd() {
    if [ -n "${TRUEHDD:-}" ]; then
        return 0
    elif command -v truehdd >/dev/null 2>&1; then
        TRUEHDD=$(command -v truehdd)
        return 0
    fi
    TRUEHDD="$BASE/bin/truehdd"
    [ -x "$TRUEHDD" ] && return 0

    [ "$(uname -s)" = Darwin ] || die "укажите путь к truehdd в переменной TRUEHDD"
    step "Скачиваю декодер truehdd (github.com/truehdd/truehdd)…"
    local json url sum expected
    json=$(curl -fsSL "$TRUEHDD_API") || die "не удалось получить список выпусков truehdd"
    url=$(printf '%s' "$json" | "$PYTHON" -c '
import json, sys
for a in json.load(sys.stdin)["assets"]:
    if a["name"].endswith("-universal-macOS.zip"):
        print(a["browser_download_url"])
        break')
    [ -n "$url" ] || die "в последнем выпуске truehdd нет сборки для macOS"
    mkdir -p "$BASE/bin"
    curl -fL --retry 3 -o "$BASE/bin/truehdd.zip" "$url"
    expected=$(curl -fsSL "$url.sha256" | awk '{print $1}')
    sum=$(sha256_of "$BASE/bin/truehdd.zip")
    [ -n "$expected" ] && [ "$sum" = "$expected" ] || die "контрольная сумма truehdd не совпала"
    (cd "$BASE/bin" && unzip -o -q truehdd.zip && rm -f truehdd.zip)
    chmod +x "$TRUEHDD"
    xattr -d com.apple.quarantine "$TRUEHDD" 2>/dev/null || true
    "$TRUEHDD" --version >/dev/null 2>&1 || codesign --force -s - "$TRUEHDD" >/dev/null 2>&1 || true
    "$TRUEHDD" --version >/dev/null 2>&1 || die "truehdd не запускается: $TRUEHDD"
}

# Мастер Atmos из дорожки TrueHD: $1 фильм, $2 номер аудиодорожки, $3 путь без расширения.
extract_master() {
    step "1/3 Извлекаю объекты Atmos (truehdd)…"
    set -o pipefail
    # Матрёшка хранит время с точностью до 1 мс, и у соседних блоков TrueHD оно совпадает;
    # в сыром потоке время не нужно, поэтому пакеты просто нумеруются.
    ffmpeg -nostdin -hide_banner -loglevel error -i "$1" -map "0:a:$2" -c copy -bsf:a setts=ts=N -f truehd - |
        "$TRUEHDD" decode - --output-path "$3" --loglevel error \
        || die "truehdd не смог декодировать дорожку; версию 7.1 без высот можно взять командой render"
    set +o pipefail
    [ -f "$3.atmos" ] || die "в дорожке нет объектов Atmos — для неё подойдёт обычный render"
}

cmd_atmos() {
    need_ffmpeg
    need_presets
    need_python
    parse_common "$@"
    local in=$OPT_FILE out nb aidx codec_name lang start dur tmpdir need_kb=0 free_kb g hrir eqc gain rate codec master ow=-n
    [ -n "$in" ] && [ -f "$in" ] || die "укажите файл фильма"
    hrir=$(preset_file "$OPT_PRESET")
    eqc=$(eq_chain "$OPT_EQ")

    nb=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$in" | wc -l | tr -d ' ')
    if [ -n "$OPT_AUDIO" ]; then
        aidx=$OPT_AUDIO
        [ "$aidx" -ge 0 ] 2>/dev/null && [ "$aidx" -lt "$nb" ] || die "нет аудиодорожки -a $aidx (см. $0 tracks)"
    else
        aidx=$(ffprobe -v error -select_streams a -show_entries stream=codec_name -of csv=p=0 "$in" |
            awk '$1 == "truehd" { print NR - 1; exit }')
        [ -n "$aidx" ] || die "в файле нет дорожки TrueHD (Dolby Atmos из DD+ этот режим не декодирует)"
    fi
    codec_name=$(ffprobe -v error -select_streams "a:$aidx" -show_entries stream=codec_name -of csv=p=0 "$in")
    [ "$codec_name" = truehd ] || die "дорожка -a $aidx — $codec_name, а не TrueHD"
    lang=$(ffprobe -v error -select_streams "a:$aidx" -show_entries stream_tags=language -of csv=p=0 "$in")
    start=$(ffprobe -v error -select_streams "a:$aidx" -show_entries stream=start_time -of csv=p=0 "$in")
    is_number "$start" || start=0
    dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$in")
    is_number "$dur" || dur=0

    out=${OPT_OUT:-"${in%.*}.atmos-$OPT_PRESET.mkv"}
    [ "$out" != "$in" ] || die "выходной файл совпадает со входным"
    [ ! -e "$out" ] || [ "$OPT_FORCE" = 1 ] || die "$out уже существует (добавьте -f)"
    [ "$OPT_FORCE" = 1 ] && ow=-y
    codec=$(codec_args "$nb")

    if [ -n "$OPT_MASTER" ]; then
        master=${OPT_MASTER%.atmos}.atmos
        for f in "$master" "$master.audio" "$master.metadata"; do
            [ -f "$f" ] || die "нет файла $f"
        done
        tmpdir=${TMPDIR:-/tmp}
    else
        # Объекты и кровать декодируются во временный файл: 16 каналов по 24 бита (~1 ГБ на 6 минут).
        tmpdir=${BINAURAL_TMP:-$(dirname "$out")}
        need_kb=$(awk -v d="$dur" 'BEGIN { printf "%d", d * 48000 * 16 * 3 / 1024 * 1.05 }')
    fi
    free_kb=$(df -Pk "$(dirname "$out")" | awk 'NR == 2 { print $4 }')
    if [ "$free_kb" -lt $((need_kb + $(du -k "$in" | awk '{print $1}'))) ]; then
        die "мало места: нужно ~$((need_kb / 1048576)) ГБ временно плюс размер фильма для результата (BINAURAL_TMP — другой каталог для временных файлов)"
    fi

    WORK=$(mktemp -d "$tmpdir/.binaural-atmos.XXXXXX")
    write_renderer "$WORK/atmos_render.py"

    if [ -z "$OPT_MASTER" ]; then
        need_truehdd
        master="$WORK/master.atmos"
        extract_master "$in" "$aidx" "$WORK/master"
    fi
    # shellcheck disable=SC2046
    set -- $("$PYTHON" "$WORK/atmos_render.py" info "$master")
    [ $# -ge 4 ] || die "не удалось прочитать мастер Atmos"
    rate=$1
    echo "Кровать: ${*:5}; объектов: $4; частота: $rate Гц"

    step "2/3 Готовлю отклики 7.1.4 из пресета $OPT_PRESET…"
    # Рядом с пресетами: путь к ним уже проверен на символы, ломающие граф фильтров.
    HRIR714="$HRIR_DIR/.hrir714-$$.wav"
    "$PYTHON" "$WORK/atmos_render.py" make-hrir "$hrir" "$HRIR714" "$OPT_HEIGHT"

    # headphone ослабляет на 3 дБ за канал: 12 каналов против 8 в render — компенсируем 12 дБ.
    gain=$(awk -v g="$OPT_GAIN" 'BEGIN { g += 12; if (g > 40) g = 40; print g }')
    g="[1:a]aformat=channel_layouts=7.1.4[a];amovie=${HRIR714}[h];[a][h]headphone=map=FL|FR|FC|LFE|BL|BR|SL|SR|TFL|TFR|TBL|TBR:hrir=multich:gain=$gain:lfe=$OPT_LFE${eqc:+,$eqc},alimiter=level=false:limit=0.97[bin]"

    step "3/3 Рендер объектов и запись: $out"
    set -o pipefail
    # shellcheck disable=SC2086
    if ! "$PYTHON" "$WORK/atmos_render.py" render "$master" |
        ffmpeg -hide_banner -loglevel error -stats $ow \
            -i "$in" -itsoffset "$start" -f f32le -ar "$rate" -ch_layout 7.1.4 -i pipe:0 \
            -filter_complex "$g" \
            -map '0:v?' -map 0:a -map '0:s?' -map '0:t?' -map '[bin]' \
            -c copy $codec \
            -metadata:s:a:$nb title="Atmos binaural ($OPT_PRESET)" \
            -metadata:s:a:$nb language="${lang:-und}" \
            -disposition:a 0 -disposition:a:$nb default \
            -max_muxing_queue_size 9999 \
            "$out"; then
        rm -f "$out"
        die "рендер прерван, неполный файл удалён"
    fi
    set +o pipefail
    echo "Готово. В плеере выберите аудиодорожку «Atmos binaural ($OPT_PRESET)»."
}

# Объектный рендерер (Python + numpy), пишется во временный каталог при каждом запуске atmos.
write_renderer() {
    cat > "$1" <<'PYEOF'
"""Object-based Dolby Atmos renderer for headphones (part of binaural.sh).

Reads a Dolby Atmos master file set (DAMF) written by truehdd: the .atmos header,
the .atmos.metadata object positions and the .atmos.audio CAF with the bed and
object signals. Every bed channel and object is panned by its metadata into a
virtual 7.1.4 speaker array (allocentric, room-centric cube panning, the
coordinate system Atmos metadata is authored in). The 12 speaker feeds are
written to stdout as 32-bit float PCM in FFmpeg's 7.1.4 channel order; FFmpeg's
headphone filter then folds them into binaural stereo.

make-hrir builds the impulse responses for that array from a binaural.sh preset:
the floor layer is the preset itself, the four height speakers are the front and
back speakers of the preset filtered with an elevation cue (the spectral change
from 0 to 40 degrees elevation on the MIT KEMAR dummy head, smoothed to
1/2 octave).
"""

import math
import struct
import sys

import numpy as np

# FFmpeg 7.1.4 order: FL FR FC LFE BL BR SL SR TFL TFR TBL TBR
NSPK = 12
LFE = 3
# Speaker rows of the room cube: x (-1 left .. 1 right), y (1 front .. -1 back), z (0 ear level .. 1 ceiling)
FLOOR_ROWS = [(-1.0, [(-1.0, 4), (1.0, 5)]),
              (0.0, [(-1.0, 6), (1.0, 7)]),
              (1.0, [(-1.0, 0), (0.0, 2), (1.0, 1)])]
TOP_ROWS = [(-1.0, [(-1.0, 10), (1.0, 11)]),
            (1.0, [(-1.0, 8), (1.0, 9)])]

# Bed channel labels as truehdd names them, with their positions in the cube.
W = 42.0 / 62.0
BED_POS = {
    'L': (-1, 1, 0), 'R': (1, 1, 0), 'C': (0, 1, 0), 'Lss': (-1, 0, 0), 'Rss': (1, 0, 0),
    'Lrs': (-1, -1, 0), 'Rrs': (1, -1, 0), 'Lfh': (-1, 1, 1), 'Rfh': (1, 1, 1),
    'Lts': (-1, 0, 1), 'Rts': (1, 0, 1), 'Lrh': (-1, -1, 1), 'Rrh': (1, -1, 1),
    'Lw': (-1, W, 0), 'Rw': (1, W, 0),
}

# Elevation cue, dB at 1/6-octave centres: MIT KEMAR 40 deg over 0 deg elevation
# (front: 45/40 over 30/0 azimuth/elevation, rear: 135/40 over 135/0), 1/2-octave smoothed.
FREQS = [100, 112, 126, 141, 159, 178, 200, 224, 252, 283, 317, 356, 400, 449, 504, 566, 635, 713, 800, 898, 1008, 1131, 1270, 1425, 1600, 1796, 2016, 2263, 2540, 2851, 3200, 3592, 4032, 4525, 5080, 5702, 6400, 7184, 8063, 9051, 10159, 11404, 12800, 14368, 16127, 18102]
CUES = {}  # filled from the table below by _load_cues


def _load_cues(text):
    for line in text.strip().splitlines():
        name, values = line.split('=', 1)
        CUES[name.strip()] = [float(v) for v in values.strip(' []').split(',')]


_load_cues("""
FRONT_L = [0.0, 0.0, 0.0, 0.0, -0.0, -0.0, 0.0, 0.0, 0.0, -0.0, -0.0, -0.1, -0.3, -0.3, -0.5, -1.0, -2.2, -2.7, -2.5, -1.7, -0.1, 2.1, 3.2, 3.0, 1.4, -0.8, -1.6, -0.0, 1.7, 2.4, 1.7, 0.3, 0.8, 1.7, 3.1, 6.4, 8.0, 8.0, 8.0, 8.0, 5.1, -3.8, -5.0, -4.2, -2.8, -2.8]
FRONT_R = [-0.0, -0.0, 0.0, 0.0, 0.0, -0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1, -0.2, -0.2, -0.8, -1.8, -4.1, -3.9, -1.7, 0.6, 2.2, 1.5, 0.2, -2.4, -2.7, -1.6, 0.3, 1.6, 1.5, 0.8, -0.0, 1.8, 3.4, 5.2, 8.0, 8.0, 8.0, 8.0, 8.0, 2.8, -9.2, -10.0, -8.1, -6.9, -6.9]
REAR_L = [0.0, 0.0, -0.0, -0.0, -0.0, -0.0, -0.0, 0.0, 0.0, -0.0, -0.0, -0.1, -0.3, -0.3, -0.6, -1.2, -2.3, -2.8, -2.8, -3.2, -3.4, -2.7, -1.5, -0.3, 0.9, 1.5, 1.3, 0.5, -0.3, -0.4, 0.6, 2.6, 5.1, 6.4, 8.0, 8.0, 8.0, 8.0, 5.0, 8.0, 8.0, 8.0, -9.3, 0.3, 0.8, 0.8]
REAR_R = [0.0, 0.0, 0.0, 0.0, -0.0, -0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.1, 0.1, 0.2, 0.4, 0.3, -0.1, -1.3, 0.3, 0.6, 3.7, 3.9, 4.3, 2.9, 2.4, 1.8, 1.9, 2.1, 2.9, 3.9, 3.7, 2.8, 2.7, 5.1, 7.0, 8.0, 8.0, 8.0, 8.0, 8.0, 6.7, -4.3, 7.0, 6.6, 6.2, 6.2]
""")


# ------------------------------------------------------------------ panning

def _pan1d(v, coords):
    """Power-preserving pan between the two neighbours of v: [(index, gain), ...]."""
    if v <= coords[0]:
        return [(0, 1.0)]
    if v >= coords[-1]:
        return [(len(coords) - 1, 1.0)]
    for i in range(len(coords) - 1):
        a, b = coords[i], coords[i + 1]
        if a <= v <= b:
            t = (v - a) / (b - a)
            return [(i, math.cos(t * math.pi / 2)), (i + 1, math.sin(t * math.pi / 2))]
    return [(0, 1.0)]


def _pan_point(x, y, z, gains, weight=1.0):
    for li, gz in _pan1d(z, [0.0, 1.0]):
        rows = FLOOR_ROWS if li == 0 else TOP_ROWS
        for ri, gy in _pan1d(y, [r[0] for r in rows]):
            spk = rows[ri][1]
            for si, gx in _pan1d(x, [s[0] for s in spk]):
                gains[spk[si][1]] += (weight * gz * gy * gx) ** 2


_pan_cache = {}


def pan(x, y, z, size=0.0, snap=False, elevation=True):
    """Amplitude gains of the 12 speakers for a point (or an extended source) in the cube."""
    key = (round(x, 5), round(y, 5), round(z, 5), round(size, 4), snap, elevation)
    g = _pan_cache.get(key)
    if g is not None:
        return g
    x = min(max(x, -1.0), 1.0)
    y = min(max(y, -1.0), 1.0)
    z = min(max(z, 0.0), 1.0) if elevation else 0.0
    power = np.zeros(NSPK)
    if size > 0:
        offs = (-size, 0.0, size)
        pts = [(x + a, y + b, z + c) for a in offs for b in offs for c in offs]
        for px, py, pz in pts:
            _pan_point(min(max(px, -1), 1), min(max(py, -1), 1), min(max(pz, 0), 1) if elevation else 0.0,
                       power, 1.0 / math.sqrt(len(pts)))
    else:
        _pan_point(x, y, z, power)
    if snap:
        snapped = np.zeros(NSPK)
        snapped[int(np.argmax(power))] = 1.0
        power = snapped
    g = np.sqrt(power / power.sum())
    if len(_pan_cache) < 200000:
        _pan_cache[key] = g
    return g


# ------------------------------------------------------------------ DAMF parsing

def read_header(path):
    """Element labels in audio channel order: beds first, then objects."""
    elements, section, pending = [], None, None
    with open(path, encoding='utf-8') as f:
        for raw in f:
            line = raw.strip()
            if line in ('bedInstances:', 'objects:'):
                section = line[:-1]
                continue
            if raw[:1] not in (' ', '-', '\t') and line.endswith(':'):
                section = None
            if section == 'bedInstances':
                if line.startswith('- channel:') or line.startswith('channel:'):
                    pending = line.split(':', 1)[1].strip()
                elif line.startswith('ID:') and pending is not None:
                    elements.append((int(line.split(':', 1)[1]), pending))
                    pending = None
            elif section == 'objects':
                if line.startswith('- ID:') or line.startswith('ID:'):
                    elements.append((int(line.split(':', 1)[1]), None))
    if not elements:
        raise SystemExit('no bed channels or objects in ' + path)
    return elements


def iter_events(path):
    """Yield (samplePos, ID, {field: text}) in file order (time-ordered)."""
    cur = None
    with open(path, encoding='utf-8') as f:
        for raw in f:
            line = raw.strip()
            if line.startswith('- ID:'):
                if cur is not None:
                    yield cur
                cur = [None, int(line[5:]), {}]
            elif cur is not None and ':' in line:
                k, v = line.split(':', 1)
                v = v.strip()
                if k == 'samplePos':
                    cur[0] = int(v)
                else:
                    cur[2][k] = v
    if cur is not None:
        yield cur


class Element:
    __slots__ = ('label', 'active', 'pos', 'gain', 'ramp', 'size', 'snap', 'elev', 'pts')

    def __init__(self, label):
        self.label = label
        self.active, self.gain, self.ramp, self.size = True, 0.0, 0, 0.0
        self.snap, self.elev = False, True
        self.pos = BED_POS.get(label, (0.0, 1.0, 0.0)) if label else (0.0, 1.0, 0.0)
        # piecewise-linear gain trajectory; bed channels play from the start even without
        # events of their own (truehdd --bed-conform adds 7.1.2 channels that have none)
        self.pts = [(0, self.target() if label else np.zeros(NSPK))]

    def target(self):
        if not self.active or self.gain == -math.inf:
            return np.zeros(NSPK)
        lin = 10.0 ** (self.gain / 20.0)
        if self.label in ('LFE', 'LFE2'):
            g = np.zeros(NSPK)
            g[LFE] = lin
            return g
        return pan(*self.pos, size=self.size, snap=self.snap, elevation=self.elev) * lin

    def value_at(self, t):
        pts = self.pts
        if t >= pts[-1][0]:
            return pts[-1][1]
        for i in range(len(pts) - 1, -1, -1):
            if pts[i][0] <= t:
                (t0, v0), (t1, v1) = pts[i], pts[i + 1]
                return v0 + (v1 - v0) * ((t - t0) / (t1 - t0))
        return pts[0][1]

    def apply(self, t, fields):
        for k, v in fields.items():
            if k == 'active':
                self.active = v == 'true'
            elif k == 'pos':
                x, y, z = (float(a) for a in v.strip('[]').split(','))
                self.pos = (x, y, z)
            elif k == 'gain':
                self.gain = -math.inf if v == '-inf' else float(v)
            elif k == 'rampLength':
                self.ramp = int(v)
            elif k == 'size':
                self.size = float(v)
            elif k == 'snap':
                self.snap = v == 'true'
            elif k == 'elevation':
                self.elev = v == 'true'
        now = self.value_at(t)
        self.pts = [p for p in self.pts if p[0] < t] + [(t, now), (t + max(self.ramp, 1), self.target())]


# ------------------------------------------------------------------ audio I/O

def open_caf(path):
    f = open(path, 'rb')
    if f.read(4) != b'caff':
        raise SystemExit(path + ' is not a CAF file')
    f.read(4)
    fmt = None
    while True:
        hdr = f.read(12)
        if len(hdr) < 12:
            raise SystemExit('no audio data in ' + path)
        ctype, size = hdr[:4], struct.unpack('>q', hdr[4:])[0]
        if ctype == b'desc':
            rate, fid, flags, bpp, fpp, ch, bits = struct.unpack('>d4sIIIII', f.read(32))
            if fid != b'lpcm':
                raise SystemExit('unsupported CAF format ' + fid.decode(errors='replace'))
            fmt = (rate, flags, ch, bits, bpp)
            f.seek(size - 32, 1)
        elif ctype == b'data':
            f.read(4)  # edit count
            return f, fmt
        else:
            f.seek(size, 1)


def read_frames(f, fmt, n):
    rate, flags, ch, bits, bpp = fmt
    raw = f.read(n * bpp)
    frames = len(raw) // bpp
    if frames == 0:
        return None
    raw = raw[:frames * bpp]
    little = bool(flags & 2)
    if flags & 1:
        a = np.frombuffer(raw, ('<' if little else '>') + ('f4' if bits == 32 else 'f8'))
        return a.reshape(frames, ch).astype(np.float32)
    if bits == 24:
        b = np.frombuffer(raw, np.uint8).reshape(-1, 3).astype(np.int32)
        v = (b[:, 0] | (b[:, 1] << 8) | (b[:, 2] << 16)) if little else ((b[:, 0] << 16) | (b[:, 1] << 8) | b[:, 2])
        v = np.where(v >= 1 << 23, v - (1 << 24), v)
        return (v.reshape(frames, ch) / 8388608.0).astype(np.float32)
    dt = {16: 'i2', 32: 'i4'}[bits]
    a = np.frombuffer(raw, ('<' if little else '>') + dt).reshape(frames, ch)
    return (a / float(1 << (bits - 1))).astype(np.float32)


def read_wav(path):
    with open(path, 'rb') as f:
        data = f.read()
    if data[:4] != b'RIFF' or data[8:12] != b'WAVE':
        raise SystemExit(path + ' is not a WAV file')
    pos, fmt = 12, None
    while pos + 8 <= len(data):
        cid, size = data[pos:pos + 4], struct.unpack('<I', data[pos + 4:pos + 8])[0]
        body = data[pos + 8:pos + 8 + size]
        if cid == b'fmt ':
            tag, ch, rate, _, _, bits = struct.unpack('<HHIIHH', body[:16])
            if tag == 0xFFFE:
                tag = struct.unpack('<H', body[24:26])[0]
            fmt = (tag, ch, rate, bits)
        elif cid == b'data':
            tag, ch, rate, bits = fmt
            if tag != 3 or bits != 32:
                raise SystemExit(path + ': expected 32-bit float WAV')
            return np.frombuffer(body, '<f4').reshape(-1, ch).copy(), rate
        pos += 8 + size + (size & 1)
    raise SystemExit('no data in ' + path)


def write_wav(path, a, rate):
    a = np.ascontiguousarray(a, '<f4')
    frames, ch = a.shape
    body = a.tobytes()
    with open(path, 'wb') as f:
        f.write(b'RIFF' + struct.pack('<I', 4 + 26 + 8 + len(body)) + b'WAVE')
        f.write(b'fmt ' + struct.pack('<IHHIIHH', 18, 3, ch, rate, rate * ch * 4, ch * 4, 32) + b'\0\0')
        f.write(b'data' + struct.pack('<I', len(body)) + body)


# ------------------------------------------------------------------ commands

def min_phase_fir(db_points, rate, taps=512):
    n = taps * 8
    f = np.fft.rfftfreq(n, 1.0 / rate)
    d = np.interp(np.log(np.maximum(f, 1.0)), np.log(FREQS), db_points)
    full = np.concatenate([d, d[-2:0:-1]]) * (math.log(10) / 20)
    c = np.fft.ifft(full).real
    fold = np.zeros(n)
    fold[0], fold[n // 2] = c[0], c[n // 2]
    fold[1:n // 2] = 2 * c[1:n // 2]
    h = np.fft.ifft(np.exp(np.fft.fft(fold))).real[:taps]
    return h * np.hanning(2 * taps)[taps:]


def cmd_make_hrir(src, dst, strength):
    """16-channel 7.1 preset -> 24-channel 7.1.4 set (pairs left ear, right ear)."""
    h, rate = read_wav(src)
    if h.shape[1] != 16:
        raise SystemExit(src + ': expected 16 channels')
    cue = {k: min_phase_fir([v * strength for v in CUES[k]], rate) for k in CUES}
    out = np.zeros((h.shape[0] + 511, 24), np.float32)
    out[:h.shape[0], :16] = h
    # pair index in the 7.1 preset: FL 0, FR 1, BL 4, BR 5; right-side speakers mirror the cue
    for dst_pair, src_pair, front, mirrored in ((8, 0, True, False), (9, 1, True, True),
                                                (10, 4, False, False), (11, 5, False, True)):
        name = 'FRONT' if front else 'REAR'
        cue_l, cue_r = cue[name + '_L'], cue[name + '_R']
        if mirrored:
            cue_l, cue_r = cue_r, cue_l
        left = np.convolve(h[:, 2 * src_pair], cue_l)
        right = np.convolve(h[:, 2 * src_pair + 1], cue_r)
        # keep the loudness of the base speaker: pink-weighted power over 100 Hz - 16 kHz, both ears
        n = 1 << int(math.ceil(math.log2(len(left))))
        f = np.fft.rfftfreq(n, 1.0 / rate)
        band = (f >= 100) & (f <= 16000)

        def pink_power(*irs):
            return sum((np.abs(np.fft.rfft(ir, n)[band]) ** 2 / f[band]).sum() for ir in irs)

        scale = math.sqrt(pink_power(h[:, 2 * src_pair], h[:, 2 * src_pair + 1]) / pink_power(left, right))
        out[:, 2 * dst_pair] = left * scale
        out[:, 2 * dst_pair + 1] = right * scale
    write_wav(dst, out, rate)


def cmd_render(header, metadata, audio, block=4096):
    elements = read_header(header)
    f, fmt = open_caf(audio)
    rate, _, ch, _, _ = fmt
    if ch != len(elements):
        raise SystemExit(f'{audio}: {ch} channels, header lists {len(elements)} elements')
    by_id = {}
    order = []
    for eid, label in elements:
        e = Element(label)
        by_id[eid] = e
        order.append(e)
    events = iter_events(metadata)
    pending = next(events, None)
    out_stream = sys.stdout.buffer
    t0 = 0
    while True:
        x = read_frames(f, fmt, block)
        if x is None:
            break
        n = x.shape[0]
        t1 = t0 + n
        while pending is not None and pending[0] is not None and pending[0] < t1:
            e = by_id.get(pending[1])
            if e is not None:
                e.apply(pending[0], pending[2])
            pending = next(events, None)
        y = np.zeros((n, NSPK), np.float32)
        const_idx, const_g = [], []
        for ci, e in enumerate(order):
            inner = [p[0] for p in e.pts if t0 < p[0] < t1]
            if not inner:
                g0, g1 = e.value_at(t0), e.value_at(t1)
                if not g0.any() and not g1.any():
                    continue
                if np.array_equal(g0, g1):
                    const_idx.append(ci)
                    const_g.append(g0)
                    continue
                bounds = [t0, t1]
            else:
                bounds = [t0] + sorted(set(inner)) + [t1]
            # piecewise-linear gains for every sample of the block
            tb = np.array(bounds, np.float64)
            vb = np.array([e.value_at(b) for b in bounds], np.float32)
            t = np.arange(t0, t1, dtype=np.float64)
            k = np.minimum(np.searchsorted(tb, t, side='right') - 1, len(tb) - 2)
            w = ((t - tb[k]) / (tb[k + 1] - tb[k])).astype(np.float32)[:, None]
            y += x[:, ci:ci + 1] * (vb[k] + w * (vb[k + 1] - vb[k]))
            last = e.value_at(t1)
            e.pts = [p for p in e.pts if p[0] > t1]
            e.pts.insert(0, (t1, last))
        if const_idx:
            y += x[:, const_idx] @ np.array(const_g, np.float32)
        out_stream.write(y.astype('<f4').tobytes())
        t0 = t1
    out_stream.flush()


def main(argv):
    if len(argv) >= 3 and argv[0] == 'make-hrir':
        cmd_make_hrir(argv[1], argv[2], float(argv[3]) if len(argv) > 3 else 1.0)
    elif len(argv) == 2 and argv[0] == 'render':
        base = argv[1]
        cmd_render(base, base + '.metadata', base + '.audio')
    elif len(argv) == 2 and argv[0] == 'info':
        els = read_header(argv[1])
        beds = [label for _, label in els if label]
        rate = 48000
        with open(argv[1] + '.metadata', encoding='utf-8') as f:
            for line in f:
                if line.startswith('sampleRate:'):
                    rate = int(line.split(':', 1)[1])
                    break
        print(rate, len(els), len(beds), len(els) - len(beds), ' '.join(beds))
    else:
        raise SystemExit('usage: atmos_render.py make-hrir IN16.wav OUT24.wav [strength] | render FILE.atmos | info FILE.atmos')


if __name__ == '__main__':
    main(sys.argv[1:])
PYEOF
}

# ---------------------------------------------------------------- test

cmd_test() {
    need_ffmpeg
    need_presets
    local tmp presets="${*:-atmos dtshx gsx dh++ ooyh1}" voice="" i txt names dur=2.2 total p g
    for p in $presets; do preset_file "$p" >/dev/null; done
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/binaural.XXXXXX"); tmp=$WORK

    # Фразы по кругу по часовой стрелке; «Тыл, центр» — как задний центр 6.1 (поровну в тылы).
    if command -v say >/dev/null 2>&1; then
        voice=$(say -v '?' 2>/dev/null | awk '/ru_RU/ { print $1; exit }')
        if [ -n "$voice" ]; then
            names="Левый фронт|Центр|Правый фронт|Правый бок|Правый тыл|Тыл, центр|Левый тыл|Левый бок"
        else
            names="Front left|Center|Front right|Right side|Right back|Back center|Left back|Left side"
        fi
        i=0
        printf '%s\n' "$names" | tr '|' '\n' | while IFS= read -r txt; do
            if [ -n "$voice" ]; then say -v "$voice" -o "$tmp/p$i.aiff" "$txt"
            else say -o "$tmp/p$i.aiff" "$txt"; fi
            i=$((i + 1))
        done
    else
        # Без say (не macOS): тональные посылки разной высоты.
        for i in 0 1 2 3 4 5 6 7; do
            ffmpeg -nostdin -hide_banner -loglevel error -y -f lavfi \
                -i "sine=f=$((300 + 100 * i)):d=0.8,afade=t=out:st=0.6:d=0.2" "$tmp/p$i.aiff"
        done
    fi

    total=$(awk -v d="$dur" 'BEGIN { print 8 * d + 0.5 }')
    local inputs="" fc=""
    for i in 0 1 2 3 4 5 6 7; do
        inputs="$inputs -i $tmp/p$i.aiff"
        fc="${fc}[$i:a]aformat=sample_fmts=flt:sample_rates=48000:channel_layouts=mono,adelay=$(awk -v d="$dur" -v i="$i" 'BEGIN { printf "%d", d * i * 1000 }'):all=1,apad=whole_dur=${total}[p$i];"
    done
    # FL=p0 FC=p1 FR=p2 SR=p3 BR=p4+BC BL=p6+BC SL=p7, BC=p5 с -3 дБ в оба тыла
    fc="${fc}[p5]asplit[bc1][bc2];[p4][bc1]amerge=inputs=2,pan=mono|c0=c0+0.7071*c1[br];[p6][bc2]amerge=inputs=2,pan=mono|c0=c0+0.7071*c1[bl];"
    fc="${fc}anullsrc=r=48000:cl=mono:d=${total}[lfe];"
    fc="${fc}[p0][p2][p1][lfe][bl][br][p7][p3]join=inputs=8:channel_layout=7.1:map=0.0-FL|1.0-FR|2.0-FC|3.0-LFE|4.0-BL|5.0-BR|6.0-SL|7.0-SR"
    # shellcheck disable=SC2086
    ffmpeg -nostdin -hide_banner -loglevel error -y $inputs -filter_complex "$fc" -c:a pcm_f32le "$tmp/test71.wav"
    cp "$tmp/test71.wav" "$BASE/test-7.1.wav"

    ffmpeg -nostdin -hide_banner -loglevel error -y -i "$tmp/test71.wav" -ac 2 -c:a pcm_s24le "$BASE/test-plain-downmix.wav"
    echo "Эталон без обработки (обычный даунмикс): $BASE/test-plain-downmix.wav"
    for p in $presets; do
        g=$(core_graph "$p" "$DEF_GAIN" "$DEF_LFE" none "")
        ffmpeg -nostdin -hide_banner -loglevel error -y -i "$tmp/test71.wav" -filter_complex "[0:a]$g" \
            -c:a pcm_s24le "$BASE/test-$p.wav"
        echo "Пресет $p: $BASE/test-$p.wav"
        if command -v afplay >/dev/null 2>&1; then
            command -v say >/dev/null 2>&1 && say "$p"
            afplay "$BASE/test-$p.wav"
        fi
    done
}

# ---------------------------------------------------------------- main

cmd=${1:-help}
[ $# -gt 0 ] && shift
case "$cmd" in
    setup)  cmd_setup "$@" ;;
    list)   cmd_list ;;
    test)   cmd_test "$@" ;;
    filter) cmd_filter "$@" ;;
    mpv)    cmd_mpv "$@" ;;
    tracks) cmd_tracks "${1:-}" ;;
    render) cmd_render "$@" ;;
    atmos)  cmd_atmos "$@" ;;
    help|-h|--help) usage ;;
    *) usage; exit 1 ;;
esac
