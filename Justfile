set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

font_source := "assets/fonts/source/ui.ttf"
font_charset := "assets/fonts/charsets/ui.txt"
font_output_dir := "assets/fonts/generated"
font_name := "ui"

default:
    @just --list

check-font-tools:
    @if ! command -v msdf-atlas-gen >/dev/null 2>&1; then \
        printf '%s\n' 'error: msdf-atlas-gen was not found on PATH.'; \
        printf '%s\n' 'Install https://github.com/Chlumsky/msdf-atlas-gen and make sure the binary is available as msdf-atlas-gen.'; \
        exit 1; \
    fi

fonts: check-font-tools
    @mkdir -p {{font_output_dir}}
    msdf-atlas-gen \
        -font {{font_source}} \
        -fontname {{font_name}} \
        -charset {{font_charset}} \
        -type msdf \
        -format png \
        -size 48 \
        -pxrange 8 \
        -yorigin top \
        -threads 0 \
        -imageout {{font_output_dir}}/{{font_name}}.png \
        -json {{font_output_dir}}/{{font_name}}.json
    msdf-atlas-gen \
        -font {{font_source}} \
        -fontname {{font_name}} \
        -charset {{font_charset}} \
        -type msdf \
        -format bin \
        -size 48 \
        -pxrange 8 \
        -yorigin top \
        -threads 0 \
        -imageout {{font_output_dir}}/{{font_name}}.bin

clean-fonts:
    rm -f {{font_output_dir}}/{{font_name}}.png {{font_output_dir}}/{{font_name}}.json {{font_output_dir}}/{{font_name}}.bin
