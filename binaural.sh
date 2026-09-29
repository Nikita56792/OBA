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
#
# Опции filter / mpv / render:
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
trap 'rm -rf "${WORK:-}"' EXIT

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
    OPT_AUDIO=""; OPT_SURROUND=side; OPT_CODEC=flac; OPT_OUT=""; OPT_FORCE=0; OPT_FILE=""
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
            -h|--help)     usage; exit 0 ;;
            -*)            die "неизвестная опция $1" ;;
            *)             [ -z "$OPT_FILE" ] || die "лишний аргумент $1"; OPT_FILE=$1; shift ;;
        esac
    done
    is_number "$OPT_GAIN" || die "gain должен быть числом"
    is_number "$OPT_LFE"  || die "lfe должен быть числом"
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
    local in=$OPT_FILE out nb aidx layout lang g pan="" codec_args sub_args="" ow=-n
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

    case "$OPT_CODEC" in
        flac) codec_args="-c:a:$nb flac -sample_fmt:a:$nb s32 -bits_per_raw_sample:a:$nb 24" ;;
        aac)  if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q ' aac_at '; then
                  codec_args="-c:a:$nb aac_at -b:a:$nb 320k"
              else
                  codec_args="-c:a:$nb aac -b:a:$nb 320k"
              fi ;;
        *) die "--codec: flac или aac" ;;
    esac

    [ "$OPT_FORCE" = 1 ] && ow=-y
    case "$in" in *.[mM][pP]4|*.[mM]4[vV]|*.[mM][oO][vV]) sub_args="-c:s srt" ;; esac   # mov_text в MKV не кладётся
    g=$(core_graph "$OPT_PRESET" "$OPT_GAIN" "$OPT_LFE" "$OPT_EQ" "$pan")
    g="[0:a:$aidx]${g}[bin]"
    step "Рендер: пресет $OPT_PRESET → $out"
    # shellcheck disable=SC2086
    ffmpeg -nostdin -hide_banner -loglevel error -stats $ow \
        -i "$in" -filter_complex "$g" \
        -map '0:v?' -map 0:a -map '0:s?' -map '0:t?' -map '[bin]' \
        -c copy $codec_args $sub_args \
        -metadata:s:a:$nb title="Binaural ($OPT_PRESET)" \
        -metadata:s:a:$nb language="${lang:-und}" \
        -disposition:a 0 -disposition:a:$nb default \
        -max_muxing_queue_size 4096 \
        "$out"
    echo "Готово. В плеере выберите аудиодорожку «Binaural ($OPT_PRESET)»."
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
    help|-h|--help) usage ;;
    *) usage; exit 1 ;;
esac
