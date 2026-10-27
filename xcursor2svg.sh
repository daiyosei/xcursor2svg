#!/usr/bin/env bash
# Convert an Xcursor theme to SVG cursors with embedded bitmaps.
set -euo pipefail
export LC_ALL=C

usage() {
    echo "Usage: $0 [--res SIZE] [--pixel] [-y | -n] THEME_DIRECTORY_OR_NAME"
    echo "Point to the Xcursor theme directory containing the cursors/ subdirectory."
    echo "An installed theme name can also be used."
    echo "  --res SIZE  Nominal cursor size (default: 32)."
    echo "  --pixel     Draw each pixel as an SVG rectangle instead of embedding the bitmap."
    echo "  -y          Automatically install after conversion."
    echo "  -n          Convert only; do not install."
    echo "Example: $0 --res 64 -y miku-cursor-linux"
}

die() { echo "Error: $*" >&2; exit 1; }

res=32
theme=
method=embed
install_mode=ask
while (($#)); do
    case "$1" in
        --res)
            (($# >= 2)) || die "--res needs a size."
            res=$2
            shift 2
            ;;
        --pixel) method=pixel; shift ;;
        -y) [[ $install_mode != n ]] || die "Use either -y or -n, not both."; install_mode=y; shift ;;
        -n) [[ $install_mode != y ]] || die "Use either -y or -n, not both."; install_mode=n; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; (($# == 1)) || die "Give one theme directory or name."; theme=$1; shift ;;
        -*) die "Unknown option: $1" ;;
        *) [[ -z $theme ]] || die "Give one theme directory or name."; theme=$1; shift ;;
    esac
done
[[ -n $theme ]] || { usage >&2; exit 1; }
[[ $res =~ ^[1-9][0-9]*$ && ${#res} -le 4 ]] || die "Resolution must be a positive integer (maximum 4096)."
((res <= 4096)) || die "Resolution must be at most 4096."

for command in xcur2png awk readlink; do
    command -v "$command" >/dev/null || die "Required command not found: $command"
done
if [[ $method == embed ]]; then
    command -v base64 >/dev/null || die "Required command not found: base64"
fi
if command -v magick >/dev/null; then
    image_command=magick
elif command -v convert >/dev/null; then
    image_command=convert
else
    die "Install ImageMagick (magick or convert)."
fi

icons=${XDG_DATA_HOME:-"$HOME/.local/share"}/icons
if [[ ! -d $theme && $theme != */* ]]; then
    for base in "$icons" "$HOME/.icons" /usr/local/share/icons /usr/share/icons; do
        if [[ -d $base/$theme/cursors ]]; then
            theme=$base/$theme
            break
        fi
    done
fi
[[ -d $theme/cursors ]] || die "Theme has no cursors directory: $theme"
theme=$(cd -- "$theme" && pwd -P)
name=${theme##*/}-svg-${res}x${res}
output=$PWD/$name
[[ ! -e $output && ! -L $output ]] || die "Output already exists: $output"

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
build=$work/$name
mkdir -p "$build/cursors_scalable" "$work/extract"
cp -a -- "$theme/cursors" "$build/cursors"
note="[converted using xcursor2svg.sh at ${res}x${res}]"
# Keep the original metadata, adding only a note to the description.
if [[ -f $theme/index.theme ]]; then
    awk -v note="$note" -v name="$name" '
        /^\[/ {
            if (section && !comment) print "Comment=" note
            section = ($0 ~ /^\[Icon Theme\]\r?$/)
            if (section) {found=1; comment=0}
        }
        section && /^Comment(\[[^]]+\])?=/ {
            if ($0 ~ /^Comment=/) comment=1
            cr = sub(/\r$/, "") ? "\r" : ""
            print $0 " " note cr
            next
        }
        {print}
        END {
            if (!found) print "[Icon Theme]\nName=" name "\nComment=" note
            else if (section && !comment) print "Comment=" note
        }
    ' "$theme/index.theme" > "$build/index.theme"
else
    printf '[Icon Theme]\nName=%s\nComment=%s\n' "$name" "$note" > "$build/index.theme"
fi

convert_cursor() {
    local cursor=$1 shape=$2 selected size xhot yhot png delay bitmap
    local width height scaled_width scaled_height hotspot_x hotspot_y extraction_log frame=0 comma=
    local directory=$build/cursors_scalable/$shape

    rm -f -- "$work/extract/"*
    # A fixed input name keeps xcur2png's config paths free of spaces.
    cp -- "$cursor" "$work/extract/cursor"
    if ! extraction_log=$(cd "$work/extract" && xcur2png -q -d . -c cursor.conf cursor 2>&1); then
        die "Cannot extract $cursor: $extraction_log"
    fi
    selected=$(awk -v res="$res" '
        !/^#/ && NF >= 4 {
            distance = $1 - res; if (distance < 0) distance = -distance
            if (!found || distance < best || (distance == best && $1 > size)) {
                found = 1; best = distance; size = $1
            }
        }
        END {if (found) print size}
    ' "$work/extract/cursor.conf")
    [[ -n $selected ]] || die "No frames found in $cursor"
    mkdir -p -- "$directory"
    printf '[\n' > "$directory/metadata.json"
    while read -r size xhot yhot png delay; do
        [[ $size == "$selected" ]] || continue
        png=$work/extract/${png#./}
        read -r width height < <("$image_command" "$png" -format '%w %h\n' info:)
        read -r scaled_width scaled_height < <(awk -v w="$width" -v h="$height" -v r="$res" -v s="$size" \
            'BEGIN {w=int(w*r/s+0.5); h=int(h*r/s+0.5); print (w<1?1:w), (h<1?1:h)}')
        read -r hotspot_x hotspot_y < <(awk -v x="$xhot" -v y="$yhot" -v w="$width" -v h="$height" \
            -v sw="$scaled_width" -v sh="$scaled_height" 'BEGIN {printf "%.8f %.8f\n", x*sw/w, y*sh/h}')

        # Nearest-neighbor resizing preserves hard pixel edges. By default the
        # bitmap is resized and embedded in the SVG as a base64 data URI.
        # With --pixel, each visible pixel becomes a unit rectangle instead.
        if [[ $method == pixel ]]; then
            "$image_command" "$png" -filter point -resize "${scaled_width}x${scaled_height}!" \
                -colorspace sRGB -alpha on -depth 8 txt:- |
                awk -v w="$scaled_width" -v h="$scaled_height" '
                    BEGIN {
                        printf "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%d\" height=\"%d\" viewBox=\"0 0 %d %d\" shape-rendering=\"crispEdges\">\n", w,h,w,h
                    }
                    /^#/ {next}
                    {
                        split($1, xy, /[:,]/)
                        hex=""
                        for (i=2; i<=NF; i++) if ($i ~ /^#[[:xdigit:]]+$/) {hex=$i; break}
                        if (length(hex) != 9) exit 1
                        alpha=16*(index("0123456789ABCDEF", toupper(substr(hex,8,1)))-1) + index("0123456789ABCDEF", toupper(substr(hex,9,1)))-1
                        if (alpha == 0) next
                        printf "<rect x=\"%d\" y=\"%d\" width=\"1\" height=\"1\" fill=\"%s\"", xy[1],xy[2],substr(hex,1,7)
                        if (alpha < 255) printf " fill-opacity=\"%.8f\"", alpha/255
                        print "/>"
                    }
                    END {print "</svg>"}
                ' > "$directory/frame-$frame.svg"
        else
            bitmap=$("$image_command" "$png" -filter point -resize "${scaled_width}x${scaled_height}!" \
                -colorspace sRGB -alpha on -depth 8 png:- | base64 -w0) ||
                die "Cannot encode $png"
            [[ -n $bitmap ]] || die "Cannot encode $png"
            printf '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="%d" height="%d" viewBox="0 0 %d %d" image-rendering="optimizeSpeed">\n<image width="%d" height="%d" xlink:href="data:image/png;base64,%s"/>\n</svg>\n' \
                "$scaled_width" "$scaled_height" "$scaled_width" "$scaled_height" \
                "$scaled_width" "$scaled_height" "$bitmap" > "$directory/frame-$frame.svg"
        fi
        printf '%s  {"filename":"frame-%s.svg","delay":%s,"hotspot_x":%s,"hotspot_y":%s,"nominal_size":%s}' \
            "$comma" "$frame" "${delay:-0}" "$hotspot_x" "$hotspot_y" "$res" >> "$directory/metadata.json"
        comma=$',\n'
        frame=$((frame + 1))
    done < "$work/extract/cursor.conf"
    printf '\n]\n' >> "$directory/metadata.json"
    printf 'Converted %s (%s frames, source size %s)\n' "$shape" "$frame" "$selected"
}

count=0
for cursor in "$theme/cursors/"*; do
    [[ -f $cursor && ! -L $cursor ]] || continue
    convert_cursor "$cursor" "${cursor##*/}"
    count=$((count + 1))
done

# Resolve alias chains to the final cursor, then use relative directory links.
for cursor in "$theme/cursors/"*; do
    [[ -L $cursor ]] || continue
    if [[ ! -f $cursor ]]; then
        printf 'Warning: skipping broken alias %s\n' "${cursor##*/}" >&2
        continue
    fi
    target=$(readlink -f -- "$cursor")
    target_name=${target##*/}
    if [[ $target == "$theme/cursors/$target_name" && -d $build/cursors_scalable/$target_name ]]; then
        ln -s -- "$target_name" "$build/cursors_scalable/${cursor##*/}"
    else
        # A theme can also link to an Xcursor file outside its own directory.
        convert_cursor "$cursor" "${cursor##*/}"
        count=$((count + 1))
    fi
done
((count > 0)) || die "No readable Xcursor files found."

# Supply GNOME/CSS names only when the theme has no explicit version.
while read -r alias target; do
    if [[ ! -e $build/cursors_scalable/$alias && -d $build/cursors_scalable/$target ]]; then
        ln -s -- "$target" "$build/cursors_scalable/$alias"
    fi
done <<'ALIASES'
default left_ptr
context-menu left_ptr
help question_arrow
pointer hand
pointer hand2
pointer hand1
progress left_ptr_watch
wait watch
cell crosshair
crosshair cross
text xterm
vertical-text xterm
alias dnd-link
copy dnd-copy
move dnd-move
no-drop dnd-none
not-allowed crossed_circle
grab hand2
grabbing hand2
e-resize right_side
n-resize top_side
ne-resize top_right_corner
nw-resize top_left_corner
s-resize bottom_side
se-resize bottom_right_corner
sw-resize bottom_left_corner
w-resize left_side
ew-resize h_double_arrow
ns-resize v_double_arrow
nesw-resize fd_double_arrow
nwse-resize bd_double_arrow
col-resize h_double_arrow
row-resize v_double_arrow
all-scroll left_ptr
zoom-in left_ptr
zoom-out left_ptr
dnd-ask dnd-copy
all-resize dnd-move
ALIASES

mv -- "$build" "$output"
printf '\nCreated: %s\n' "$output"
answer=$install_mode
if [[ $install_mode == ask ]]; then
    printf 'Install in %s/%s? [y/N] ' "$icons" "$name"
    answer=
    read -r answer || true
fi
case "$answer" in
    y|Y)
        destination=$icons/$name
        [[ ! -e $destination && ! -L $destination ]] || die "Installation already exists: $destination (converted theme kept at $output)"
        mkdir -p -- "$icons"
        cp -a -- "$output" "$destination"
        printf 'Installed: %s\nSelect "%s" in your cursor settings.\n' "$destination" "$name"
        ;;
    *) echo "Not installed; the converted theme is available at $output." ;;
esac
