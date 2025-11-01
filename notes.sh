set -euo pipefail

notesDir="$HOME/notes"
mkdir -p $notesDir

editor="${EDITOR:-}"
if [ -z $editor ]; then
    for i in nvim vim vi; do
        editor=$i;
        break;
    done
fi

preview=(sed -n '1200p')

cachedNote="$HOME/.local/state/notes"
mkdir -p $cachedNote

current="$cachedNote/current_note"
: >$current

columns=$(tput cols)
lines=$(tput lines)

alt_screen_on(){
    printf '\e[?1049h';
    tput civis;
}
alt_screen_off(){
    tput cnorm;
    printf '\e[?1049l';
}

trap 'on_exit' EXIT
on_exit(){
    alt_screen_off;
}

trap 'resize' WINCH
resize(){
    columns=$(tput cols)
    lines=$(tput lines)
    draw_all;
}

move(){
    tput cup "$2" "$1";
}

browseIndex=0
searchIndex=0
browseOffset=0 #dist from the top of application
searchOffset=0
mode="browse"
status=""

declare -a searchedFiles searchedSnips

slugify() {
printf '%s' "$1" | tr 'A-Z' 'a-z' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g; s/^$/note/'; }

# find all files present
list_files() {
    if find "$notesDir" -type f >/dev/null 2>&1; then
        ls -lt "$notesDir" | awk '{print $9}'
    else
        ' '
    fi
}
mapfile -t presentFiles < <(list_files)

clampBrowser() {
    local n=${#presentFiles[@]}
    if [ n==0 ]; then
        return;
    elif [ browseIndex<0 ]; then
        browseIndex=0;
    elif [ browseIndex>=n ]; then
        browseIndex=$((n-1));
    fi
}

printFileCount() {
    printf '%d' "${#presentFiles[@]}";
}

refresh() {
    mapfile -t presentFiles < <(list_files);
    clampBrowser;
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

    listHeight=$(( LINES - 3 ))
    previewHeight=$(( LINES - 3 ))

}

partitionH() {
    local y=$1;
    move 0 "$y";
    printf '%*s' "$columns" '' | tr ' ' '─';
}

panel_title() {
    x=$1 y=$2 w=$3 title=$4;
    move "$x" "$y";
    tput bold;
    printf ' %s ' "$title";
tput sgr0; }

#for BROWSE mode

renderSidePane() {
    panel_title 0 0 "$leftWidth" "Notes (${#presentFiles[@]}) — ${mode^^}"
    local y; local files=$listHeight;
    local start=$browseOffset; local end=$(( start+files+1 ));
    local n=${#presentFiles[@]}
    local i=$start;

    for ((k=1; k<listHeight; k++, i++)); do
        move 0 "$y"; printf '%-*s' "$leftWidth" ' '
        if (( i < n )); then
            move 0 "$y"
            if (( i == $browseIndex )); then tput rev; fi #reverse vid; for highlighting.
            printf ' %-*.*s' "$((leftWidth-2))" "$((leftWidth-2))" "${presentFiles[i]}"
            if (( i == $browseIndex )); then tput sgr0; fi
        fi
    done
}

renderPreview() {
    panel_title "$leftWidth" 0 "$previewWidth" "Preview"
    local y
    for ((y=1; y<previewHeight; y++)); do
        move "$leftWidth" "$y"; printf '%-*s' "$previewWidth" ' '
    done
    local file="${presentFiles[browseIndex]:-}"
    [ -n "$file" ] || return

    local content
    if [ -f "$file" ]; then
        content="$(${preview[@]} "$file" 2>/dev/null | sed "${previewHeight}q")" #quit sed after those certain number of lines.
    else
        content="(no file)"
    fi
    local line=1
    while IFS= read -r l && (( line < previewHeight )); do #internal feild seperator, bash used to sep on basis of \n \t, set to nothing to perserve all user data as is
        move "$leftWidth" "$line"
        printf '%-*.*s' "$previewWidth" "$previewHeight" "${l//$'\t'/ }"
        line=$((line+1))
    done
    echo "$content"

}


renderStatus() {
    partitionH $((lines-2))
    move 0 $((lines-1))
    printf ' [Enter/e] Edit  [n] New  [r] Rename  [d] Delete  [/] Search  [q] Quit  | Dir: %s ' "$notesDir"
    if [ -n "$status" ]; then
        local trunc=${status:0:$((columns-10))} #if the status is too long then it will truncate it to max wdith-10
        move 0 $((lines-1)); printf '%-*s' "$columns" " $trunc"
    fi
}

#for SEARCH mode
renderSearchStatus() {
    partitionH $((lines-2))
    move 0 $((lines-1))
    printf ' [Enter/e] Edit@line  [b] Back  [q] Quit  | Results: %d ' "${#searchedFiles[@]}"
    if [ -n "$status" ]; then
        local trunc=${status:0:$((columns-10))}
        move 0 $((lines-1)); printf '%-*s' "$columns" " $trunc"
    fi
}

renderSearchList() {
    panel_title 0 0 "$leftWidth" "Search Results (${#searchedFiles[@]})"
    local y i start end n
    n=${#searchedFiles[@]}
    start=$searchOffset
    end=$(( start+listHeight - 2 ))
    i=$start
    for ((y=1; y<listHeight; y++, i++)); do
        move 0 "$y"; printf '%-*s' "$leftWidth" ' '
        if (( i < n )); then
            move 0 "$y"
            if (( i == searchIndex )); then tput rev; fi
            printf ' %-*.*s' "$((leftWidth-2))" "$((leftWidth-2))" "${searchedFiles[i]}"
            if (( i == searchIndex )); then tput sgr0; fi
        fi
    done
}

renderSearchPreview() {
    panel_title "$leftWidth" 0 "$previewWidth" "Preview (match)"
    local file="${searchedFiles[searchIndex]:-}"
    local line="${searchedFiles[searchIndex]:-}"
    local y
    for ((y=1; y<previewHeight; y++)); do
        move "$leftWidth" "$y";
        printf '%-*s' "$previewWidth" ' '
    done
    [ -n "$file" ] || return
    local content
    if [ -f "$file" ]; then
        content="$(${preview[@]} "$file" 2>/dev/null | sed "${previewHeight}q")"
    else
        content="(no file)"
    fi
    local line=1
    while IFS= read -r l && (( line < previewHeight )); do
        move "$leftWidth" "$line"
        printf '%-*.*s' "$previewWidth" "$previewHeight" "${l//$'\t'/ }"
        line=$((line+1))
    done
    echo "$content"
}

runSearch() {
    local query="$1"
    searchedFiles=();  searchedSnips=()
    if [ -z "$q" ]; then return; fi
    while IFS= read -r line; do
        local f l s
        f=${line%%:*}; rest=${line#*:}; l=${rest%%:*}; s=${rest#*:}
        searchedFiles+=("$f")
        searchedSnips+=("$s")
    done < <(grep -RIn -- "$query" "$notesDir" 2>/dev/null || true)

    searchIndex=0; searchOffset=0
}

draw_all() {
    layoutDim;
    tput clear;
    case "$mode" in
        browse)
            renderSidePane; renderPreview; renderStatus ;;
        search)
            renderSearchList; renderSearchPreview; renderSearchStatus ;;
    esac
}

# to read functions like arrow keys etc.
read_key() {
    IFS= read -rsn1 key || return 1
    case "$key" in
        $'\e') #esc seq check
            IFS= read -rsn2 -t 0.001 rest || rest=""
            key+="$rest" ;;
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
        idx=0
    elif (( idx>=max )); then
        idx=$((max-1))
    fi

    # keep within window
    if (( idx < off )); then
        off=$idx;
    fi
    local last=$(( off + listHeight - 2 ))
    if (( idx > last )); then
        off=$(( idx - (listHeight - 2) ));
    fi
}

openEditor() {
    local file="$1";
    [ -f "$file" ] || return
    printf '%s' "$file" >"$current"
    "$editor" "$file"
    refresh
}

newNote() {
    move 0 $((lines-1)); printf '%-*s' "$columns" ' Title: '
    move 8 $((lines-1));
    stty -echo;
    IFS= read -r title;
    stty echo
    [ -n "$title" ] || { status="Aborted"; return; }
    local file slug
    slug=$(slugify "$title")
    file=$("$notesDir/$slug.txt")
    { printf '# %s\n\n- Created: %s\n\n' "$title" "$(date '+%Y-%m-%d %H:%M')"; } >"$file"
    presentFiles=("$file" "${presentFiles[@]}")
    browseIndex=0; browseOffset=0
    status="Created: $("$slug")"
}

renameNote() {
    local file=${presentFiles[browseIndex]:-};
    [ -f "$file" ] || { status="No file"; return; }
    move 0 $((lines-1));
    printf '%-*s' "$columns" " Rename to: "
    move 12 $((lines-1));
    stty -echo;
    IFS= read -r title;
    stty echo
    [ -n "$title" ] || { status="Aborted"; return; }
    local new
    new=$("$notesDir/$date-$(slugify "$title").txt")
    mv "$file" "$new"
    status="Renamed to $(basename -- "$new")"
    refresh
}

deleteNote() {
    local file=${presentFiles[browseIndex]:-};
    [ -f "$file" ] || { status="No file"; return; }
    move 0 $((lines-1)); printf '%-*s' "$columns" " Delete $("$file") ? [y/N] "
    IFS= read -rsn1 yn
    case "$yn" in
        y|Y)
            rm -rf "$file"
            status="Deleted"
            refresh ;;
        *) status="Aborted" ;;
    esac
}

loop_browse() {
    while :; do
        draw_all
        key=$(read_key) || return
        case "$key" in
            $'\e[A'|k) moveSelection browserIndex browserOffset "${#presentFiles[@]}" -1 ;;
            $'\e[B'|j) moveSelection browserIndex browserOffset "${#presentFiles[@]}" 1 ;;
            $'\e[5'*)  moveSelection browserIndex browserOffset "${#presentFiles[@]}" -10 ;;
            $'\e[6'*)  moveSelection browserIndex browserOffset "${#presentFiles[@]}" 10 ;;
            e|$'\n')    [ -n "${presentFiles[browserIndex]:-}" ] && openEditor "${presentFiles[browserIndex]}" ;;
            n)          newNote ;;
            r)          renameNote ;;
            d)          deleteNote ;;
            /)          move 0 $((lines-1)); printf '%-*s' "$columns" " Search: "; move 9 $((lines-1)); stty -echo; IFS= read -r query; stty echo; mode="search"; runSearch "$query" ;;
            q)          return ;;
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
            e|$'\n')    [ -n "${searchedFiles[searchIndex]:-}" ] ;;
            b)          mode="browse" ;;
            q)          return ;;
        esac
    done
}

# int main()
alt_screen_on
layoutDim; tput clear;
status="Arrows/jk to move. Enter to edit. / to search. q to quit."
while :; do
    case "$mode" in
        browse) loop_browse; [[ $mode == browse ]] && break ;;
        search) loop_search; mode="browse" ;;
    esac
    refresh
done


