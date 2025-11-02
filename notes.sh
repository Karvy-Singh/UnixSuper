#!/bin/bash
set -euo pipefail

notesDir="$HOME/notes"
mkdir -p "$notesDir"

editor="${EDITOR:-}"
if [ -z "$editor" ]; then
    for i in nvim vim vi; do
        if command -v "$i" >/dev/null 2>&1; then
            editor="$i"
            break
        fi
    done
fi

preview=(sed -n '1,200p')

cachedNote="$HOME/.local/state/notes"
mkdir -p "$cachedNote"

current="$cachedNote/current_note"
: >"$current"

columns=$(tput cols)
lines=$(tput lines)

alt_screen_on(){
    printf '\e[?1049h'
    tput civis
}

alt_screen_off(){
    tput cnorm
    printf '\e[?1049l'
}

trap 'on_exit' EXIT
on_exit(){
    alt_screen_off
}

trap 'resize' WINCH
resize(){
    columns=$(tput cols)
    lines=$(tput lines)
    draw_all
}

move(){
    tput cup "$2" "$1"
}

browseIndex=0
searchIndex=0
browseOffset=0
searchOffset=0
mode="browse"
status=""

declare -a searchedFiles searchedSnips

slugify() {
    printf '%s' "$1" | tr 'A-Z' 'a-z' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g; s/^$/note/'
}

list_files() {
    if [ -d "$notesDir" ] && [ "$(ls -A "$notesDir" 2>/dev/null)" ]; then
        ls -t "$notesDir" | while read -r f; do
            printf '%s/%s\n' "$notesDir" "$f"
        done
    fi
}

mapfile -t presentFiles < <(list_files)

clampBrowser() {
    local n=${#presentFiles[@]}
    if [ "$n" -eq 0 ]; then
        browseIndex=0
        return
    elif [ "$browseIndex" -lt 0 ]; then
        browseIndex=$((n-1))
    elif [ "$browseIndex" -ge "$n" ]; then
        browseIndex=0
    fi
}

refresh() {
    mapfile -t presentFiles < <(list_files)
    clampBrowser
}

leftWidth=0
listHeight=0
previewWidth=0
previewHeight=0

layoutDim() {
    if (( columns * 40 / 100 < 24 )); then
        leftWidth=24
    else
        leftWidth=$(( columns * 40 / 100 ))
    fi

    previewWidth=$(( columns - leftWidth - 1 ))
    listHeight=$(( lines - 3 ))
    previewHeight=$(( lines - 3 ))
}

partitionH() {
    local y=$1
    move 0 "$y"
    printf '%*s' "$columns" '' | tr ' ' '─'
}

panel_title() {
    local x=$1 y=$2 w=$3 title=$4
    move "$x" "$y"
    tput bold
    printf ' %s ' "$title"
    tput sgr0
}

renderSidePane() {
    panel_title 0 0 "$leftWidth" "Notes (${#presentFiles[@]}) — ${mode^^}"
    local start=$browseOffset
    local n=${#presentFiles[@]}
    local i=$start
    local y

    for ((y=1; y<listHeight; y++, i++)); do
        move 0 "$y"
        printf '%-*s' "$leftWidth" ' '
        if (( i < n )); then
            move 0 "$y"
            if (( i == browseIndex )); then tput rev; fi #reverse vid; for highlighting.
            local basename_file=$(basename "${presentFiles[i]}")
            printf ' %-*.*s' "$((leftWidth-2))" "$((leftWidth-2))" "$basename_file"
            if (( i == browseIndex )); then tput sgr0; fi
        fi
    done
}

renderPreview() {
    panel_title "$leftWidth" 0 "$previewWidth" "Preview"
    local y
    for ((y=1; y<previewHeight; y++)); do
        move "$leftWidth" "$y"
        printf '%-*s' "$previewWidth" ' '
    done

    local file="${presentFiles[browseIndex]:-}"
    [ -n "$file" ] || return

    local content
    if [ -f "$file" ]; then
        content="$("${preview[@]}" "$file" 2>/dev/null | sed "${previewHeight}q")"  #quit sed after those certain number of lines.
    else
        content="(no file)"
    fi

    local line=1
    while IFS= read -r l && (( line < previewHeight )); do  #internal feild seperator, bash used to sep on basis of \n \t, set to nothing to perserve all user data as is
        move "$leftWidth" "$line"
        printf '%-*.*s' "$previewWidth" "$previewWidth" "${l//$'\t'/    }"
        line=$((line+1))
    done <<< "$content"
}

renderStatus() {
    partitionH $((lines-2))
    move 0 $((lines-1))
    printf ' [Enter/e] Edit  [n] New  [r] Rename  [d] Delete  [/] Search  [q] Quit  | Dir: %s ' "$notesDir"
    if [ -n "$status" ]; then
        local trunc=${status:0:$((columns-10))}  #if the status is too long then it will truncate it to max wdith-10
        move 0 $((lines-1))
        printf '%-*s' "$columns" " $trunc"
    fi
}

renderSearchStatus() {
    partitionH $((lines-2))
    move 0 $((lines-1))
    printf ' [Enter/e] Edit  [b] Browse  [q] Quit  | Results: %d ' "${#searchedFiles[@]}"
    if [ -n "$status" ]; then
        local trunc=${status:0:$((columns-10))}
        move 0 $((lines-1))
        printf '%-*s' "$columns" " $trunc"
    fi
}

renderSearchList() {
    panel_title 0 0 "$leftWidth" "Search Results (${#searchedFiles[@]})"
    local start=$searchOffset
    local n=${#searchedFiles[@]}
    local i=$start
    local y

    for ((y=1; y<listHeight; y++, i++)); do
        move 0 "$y"
        printf '%-*s' "$leftWidth" ' '
        if (( i < n )); then
            move 0 "$y"
            if (( i == searchIndex )); then tput rev; fi #reverse vid; for highlighting.
            local basename_file=$(basename "${searchedFiles[i]}")
            printf ' %-*.*s' "$((leftWidth-2))" "$((leftWidth-2))" "$basename_file"
            if (( i == searchIndex )); then tput sgr0; fi
        fi
    done
}

renderSearchPreview() {
    panel_title "$leftWidth" 0 "$previewWidth" "Preview (match)"
    local file="${searchedFiles[searchIndex]:-}"
    local y

    for ((y=1; y<previewHeight; y++)); do
        move "$leftWidth" "$y"
        printf '%-*s' "$previewWidth" ' '
    done

    [ -n "$file" ] || return

    local content
    if [ -f "$file" ]; then
        content="$("${preview[@]}" "$file" 2>/dev/null | sed "${previewHeight}q")"
    else
        content="(no file)"
    fi

    local line=1
    while IFS= read -r l && (( line < previewHeight )); do
        move "$leftWidth" "$line"
        printf '%-*.*s' "$previewWidth" "$previewWidth" "${l//$'\t'/    }"
        line=$((line+1))
    done <<< "$content"
}

runSearch() {
    local query="$1"
    searchedFiles=()
    searchedSnips=()

    if [ -z "$query" ]; then
        return
    fi

    while IFS= read -r line; do
        local f rest s
        f=${line%%:*}
        rest=${line#*:}
        s=${rest#*:}
        searchedFiles+=("$f")
        searchedSnips+=("$s")
    done < <(grep -RIn -- "$query" "$notesDir" 2>/dev/null || true)

    searchIndex=0
    searchOffset=0
}

draw_all() {
    layoutDim
    tput clear
    case "$mode" in
        browse)
            renderSidePane
            renderPreview
            renderStatus
            ;;
        search)
            renderSearchList
            renderSearchPreview
            renderSearchStatus
            ;;
    esac
}

# to read functions like arrow keys etc.
read_key() {
    IFS= read -rsn1 key || return 1
    case "$key" in
        $'\e') #esc seq check
            IFS= read -rsn2 -t 0.001 rest || rest=""
            key+="$rest"
            ;;
    esac
    printf '%s' "$key"
}

moveSelection() {
    local -n idx=$1
    local -n off=$2
    local max=$3
    local delta=$4 #this is to determine the movement of selection up or down

    if ((max<=0)); then
        return
    fi

    #clamping for proper val
    idx=$(( idx + delta ))
    if (( idx<0 )); then
        idx=$((max-1))
    elif (( idx>=max )); then
        idx=0
    fi
    # keep within window
    if (( idx < off )); then
        off=$idx
    fi

    local last=$(( off + listHeight - 2 ))
    if (( idx > last )); then
        off=$(( idx - (listHeight - 2) ))
    fi
}

openEditor() {
    local file="$1"
    [ -f "$file" ] || return
    alt_screen_off
    printf '%s' "$file" >"$current"
    "$editor" "$file"
    alt_screen_on
    refresh
}

newNote() {
    move 0 $((lines-1))
    printf '%-*s' "$columns" ' Title: '
    move 8 $((lines-1))
    tty_settings=$(stty -g)
    stty echo
    IFS= read -r title
    stty "$tty_settings"

    [ -n "$title" ] || { status="Aborted"; return; }

    local slug
    slug=$(slugify "$title")
    local file="$notesDir/${slug}.txt"
    alt_screen_off
    $editor $file
    alt_screen_on

    refresh
    browseIndex=0
    browseOffset=0
    status="Created: $slug.txt "$(date '+%Y-%m-%d %H:%M')""
}

renameNote() {
    local file=${presentFiles[browseIndex]:-}
    [ -f "$file" ] || { status="No file"; return; }

    move 0 $((lines-1))
    printf '%-*s' "$columns" " Rename to: "
    move 12 $((lines-1))
    tty_settings=$(stty -g)
    stty echo
    IFS= read -r title
    stty "$tty_settings"

    [ -n "$title" ] || { status="Aborted"; return; }

    local slug
    slug=$(slugify "$title")
    local new="$notesDir/${slug}.txt"

    mv "$file" "$new"
    status="Renamed to $(basename "$new")"
    refresh
}

deleteNote() {
    local file=${presentFiles[browseIndex]:-}
    [ -f "$file" ] || { status="No file"; return; }

    move 0 $((lines-1))
    printf '%-*s' "$columns" " Delete $(basename "$file") ? [y/N] "
    IFS= read -rsn1 yn

    case "$yn" in
        y|Y)
            rm -f "$file"
            status="Deleted"
            refresh
            ;;
        *)
            status="Aborted"
            ;;
    esac
}

loop_browse() {
    while :; do
        draw_all
        key=$(read_key) || return
        case "$key" in
            $'\e[A'|k) moveSelection browseIndex browseOffset "${#presentFiles[@]}" -1 ;;
            $'\e[B'|j) moveSelection browseIndex browseOffset "${#presentFiles[@]}" 1 ;;
            $'\e[5'*)  moveSelection browseIndex browseOffset "${#presentFiles[@]}" -10 ;;
            $'\e[6'*)  moveSelection browseIndex browseOffset "${#presentFiles[@]}" 10 ;;
            e|$'\n')   [ -n "${presentFiles[browseIndex]:-}" ] && openEditor "${presentFiles[browseIndex]}" ;;
            n)         newNote ;;
            r)         renameNote ;;
            d)         deleteNote ;;
            /)
                move 0 $((lines-1))
                printf '%-*s' "$columns" " Search: "
                move 9 $((lines-1))
                tty_settings=$(stty -g)
                stty echo
                IFS= read -r query
                stty "$tty_settings"
                mode="search"
                runSearch "$query"
                return
                ;;
            q)         return ;;
        esac
    done
}

loop_search() {
    while :; do
        draw_all
        key=$(read_key) || return
        case "$key" in
            $'\e[A'|k) moveSelection searchIndex searchOffset "${#searchedFiles[@]}" -1 ;;
            $'\e[B'|j) moveSelection searchIndex searchOffset "${#searchedFiles[@]}" 1 ;;
            e|$'\n')
                if [ -n "${searchedFiles[searchIndex]:-}" ]; then
                    local entry="${searchedFiles[searchIndex]}"
                    local file="${entry%%:*}"
                    openEditor "$file"
                fi
                ;;
            b)         mode="browse"; return ;;
            q)         return ;;
        esac
    done
}

# Main
alt_screen_on
layoutDim
tput clear
mode="browse"

while :; do
    case "$mode" in
        browse)  loop_browse ;;
        search)  loop_search ;;
        quit)    break ;;
    esac
    refresh
done


