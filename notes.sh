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

# ----- Color support -----
if tput colors >/dev/null 2>&1; then
    color_count=$(tput colors)
else
    color_count=0
fi

if [ "$color_count" -ge 8 ]; then
    COLOR_RESET=$(tput sgr0)
    COLOR_BOLD=$(tput bold)
    COLOR_DIM=$(tput dim)
    COLOR_TITLE=$(tput setaf 6)      # cyan
    COLOR_STATUS=$(tput setaf 2)     # green-ish status line
    COLOR_ACCENT=$(tput setaf 4)     # blue accent if needed
    COLOR_PREVIEW=$(tput setaf 3)    # preview text color
    COLOR_SELECTION_BG=$(tput setab 4)  # blue background for selection
    COLOR_SELECTION_FG=$(tput setaf 7)  # white foreground for selection
else
    COLOR_RESET=""
    COLOR_BOLD=""
    COLOR_DIM=""
    COLOR_TITLE=""
    COLOR_STATUS=""
    COLOR_ACCENT=""
    COLOR_PREVIEW=""
    COLOR_SELECTION_BG=""
    COLOR_SELECTION_FG=""
fi
# --------------------------

alt_screen_on(){
    printf '\e[?1049h'
    tput civis
    tput clear
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
    force_redraw=1
    draw_all
}

move(){
    tput cup "$2" "$1"
}

browseIndex=0
searchIndex=0
browseOffset=0
searchOffset=0
calendarDate=$(date +%Y-%m-%d)
calendarIndex=0
calendarOffset=0
mode="browse"
status=""
force_redraw=0

set_status() {
    status="$1"
    status_until=$(( $(date +%s) + 2 ))
}

declare -a searchedFiles searchedSnips

slugify() {
    printf '%s' "$1" | tr 'A-Z' 'a-z' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g; s/^$/note/'
}

list_files() {
    if [ -d "$notesDir" ] && [ "$(ls -A "$notesDir" 2>/dev/null)" ]; then
        ls -t -- "$notesDir" | while read -r f; do
            printf '%s/%s\n' "$notesDir" "$f"
        done
    fi
    return 0
}

mapfile -t presentFiles < <(list_files) || presentFiles=()

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
    mapfile -t presentFiles < <(list_files) || presentFiles=()
    clampBrowser
    force_redraw=1
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
    if [ -n "$COLOR_DIM" ]; then
        printf '%s' "$COLOR_DIM"
    fi
    for ((i=0; i < columns; i++)); do
        printf '─'
    done
    if [ -n "$COLOR_RESET" ]; then
        printf '%s' "$COLOR_RESET"
    fi
}

panel_title() {
    local x=$1 y=$2 w=$3 title=$4
    move "$x" "$y"
    if [ -n "$COLOR_TITLE" ]; then
        printf '%s%s' "$COLOR_TITLE" "$COLOR_BOLD"
    else
        tput bold
    fi
    printf ' %s ' "$title"
    if [ -n "$COLOR_RESET" ]; then
        printf '%s' "$COLOR_RESET"
    else
        tput sgr0
    fi
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
            if (( i == browseIndex )); then
                if [ -n "$COLOR_SELECTION_BG" ]; then
                    printf '%s%s' "$COLOR_SELECTION_BG" "$COLOR_SELECTION_FG"
                else
                    tput rev
                fi
            fi
            local basename_file
            basename_file=$(basename "${presentFiles[i]}")
            printf ' %-*.*s' "$((leftWidth-2))" "$((leftWidth-2))" "$basename_file"
            if (( i == browseIndex )); then
                if [ -n "$COLOR_RESET" ]; then
                    printf '%s' "$COLOR_RESET"
                else
                    tput sgr0
                fi
            fi
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

    if [ ${#presentFiles[@]} -eq 0 ]; then
        move "$leftWidth" 1
        if [ -n "$COLOR_DIM" ]; then
            printf '%s' "$COLOR_DIM"
        fi
        printf ' No notes yet. Press [n] to create one.'
        if [ -n "$COLOR_RESET" ]; then
            printf '%s' "$COLOR_RESET"
        fi
        return
    fi

    local file="${presentFiles[browseIndex]:-}"
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
        if [ -n "$COLOR_PREVIEW" ]; then
            printf '%s' "$COLOR_PREVIEW"
        fi
        printf '%-*.*s' "$previewWidth" "$previewWidth" "${l//$'\t'/    }"
        if [ -n "$COLOR_RESET" ]; then
            printf '%s' "$COLOR_RESET"
        fi
        line=$((line+1))
    done <<< "$content"
}

renderStatus() {
    partitionH $((lines-2))
    move 0 $((lines-1))
    
    if [ -n "$COLOR_STATUS" ]; then
        printf '%s' "$COLOR_STATUS"
    fi

    if [ -n "$status" ]; then
        local max_len=$((columns - 2))
        local trunc="${status:0:$max_len}"
        printf '%-*.*s' "$columns" "$columns" " $trunc"
    else
        local base_msg=' [Enter/e] Edit  [n] New  [r] Rename  [d] Delete  [/] Search  [c] Calendar  [q] Quit  | Dir: '
        local max_dir_len=$((columns - ${#base_msg} - 2))
        if (( max_dir_len > 0 )); then
            local dir_trunc="${notesDir:0:$max_dir_len}"
            printf '%-*.*s' "$columns" "$columns" "${base_msg}${dir_trunc}"
        else
            printf '%-*.*s' "$columns" "$columns" " [e]Edit [n]New [r]Rename [d]Del [/]Search [c]Cal [q]Quit"
        fi
    fi

    if [ -n "$COLOR_RESET" ]; then
        printf '%s' "$COLOR_RESET"
    fi
}

renderSearchStatus() {
    partitionH $((lines-2))
    move 0 $((lines-1))

    if [ -n "$COLOR_STATUS" ]; then
        printf '%s' "$COLOR_STATUS"
    fi
    
    if [ -n "$status" ]; then
        local max_len=$((columns - 2))
        local trunc="${status:0:$max_len}"
        printf '%-*.*s' "$columns" "$columns" " $trunc"
    else
        local base_msg=' [Enter/e] Edit  [b] Browse  [q] Quit  | Results: '
        local n_res=${#searchedFiles[@]}
        local max_res_len=$((columns - ${#base_msg} - 2))
        if (( max_res_len > 0 )); then
            local res_trunc="${n_res:0:$max_res_len}"
            printf '%-*.*s' "$columns" "$columns" "${base_msg}${res_trunc}"
        else
            printf '%-*.*s' "$columns" "$columns" "[enter/e]Edit [b]Browse [q]Quit"
        fi
    fi

    if [ -n "$COLOR_RESET" ]; then
        printf '%s' "$COLOR_RESET"
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
            if (( i == searchIndex )); then
                if [ -n "$COLOR_SELECTION_BG" ]; then
                    printf '%s%s' "$COLOR_SELECTION_BG" "$COLOR_SELECTION_FG"
                else
                    tput rev
                fi
            fi
            local basename_file
            basename_file=$(basename "${searchedFiles[i]}")
            printf ' %-*.*s' "$((leftWidth-2))" "$((leftWidth-2))" "$basename_file"
            if (( i == searchIndex )); then
                if [ -n "$COLOR_RESET" ]; then
                    printf '%s' "$COLOR_RESET"
                else
                    tput sgr0
                fi
            fi
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

    if [ ${#searchedFiles[@]} -eq 0 ]; then
        move "$leftWidth" 1
        if [ -n "$COLOR_DIM" ]; then
            printf '%s' "$COLOR_DIM"
        fi
        printf ' No results found.'
        if [ -n "$COLOR_RESET" ]; then
            printf '%s' "$COLOR_RESET"
        fi
        return
    fi

    local content
    if [ -f "$file" ]; then
        content="$("${preview[@]}" "$file" 2>/dev/null | sed "${previewHeight}q")"
    else
        content="(no file)"
    fi

    local line=1
    while IFS= read -r l && (( line < previewHeight )); do
        move "$leftWidth" "$line"
        if [ -n "$COLOR_PREVIEW" ]; then
            printf '%s' "$COLOR_PREVIEW"
        fi
        printf '%-*.*s' "$previewWidth" "$previewWidth" "${l//$'\t'/    }"
        if [ -n "$COLOR_RESET" ]; then
            printf '%s' "$COLOR_RESET"
        fi
        line=$((line+1))
    done <<< "$content"
}

renderCalendar() {
    panel_title 0 0 "$leftWidth" "Calendar"

    local day
    day=$(date -d "$calendarDate" +%d)
    local month
    month=$(date -d "$calendarDate" +%m)
    local year
    year=$(date -d "$calendarDate" +%Y)

    local cal_output
    cal_output=$(cal "$month" "$year")
    local day_no_zero=$((10#$day))

    local line=1
    while IFS= read -r l && (( line < listHeight )); do
        move 0 "$line"
        if echo "$l" | grep -qE "(^| )$day_no_zero( |$)"; then
            l=$(echo "$l" | sed "s/\<$day_no_zero\>/$(tput rev)$day_no_zero$(tput sgr0)/")
        fi
        printf '%-*s' "$leftWidth" "$l"
        line=$((line+1))
    done<<<"$cal_output"
}

renderTasks() {
    panel_title "$leftWidth" 0 "$previewWidth" "Tasks - $(date -d "$calendarDate" +%Y-%m-%d)"

    mapfile -t tasks < <(list_tasks)

    local y
    for ((y=1; y<previewHeight; y++)); do
        move "$leftWidth" "$y"
        printf '%-*s' "$previewWidth" ' '
    done

    if [ ${#tasks[@]} -eq 0 ]; then
        move "$leftWidth" 1
        if [ -n "$COLOR_DIM" ]; then
            printf '%s' "$COLOR_DIM"
        fi
        printf ' No tasks. Press [n] to add.'
        if [ -n "$COLOR_RESET" ]; then
            printf '%s' "$COLOR_RESET"
        fi
        return
    fi

    local line=1
    for task in "${tasks[@]}"; do
        [ $line -ge $previewHeight ] && break
        move "$leftWidth" "$line"

        local kind jobid taskline src_line display
        IFS='|' read -r kind jobid taskline <<< "$task"

        if [ "$kind" = "cron" ]; then
            src_line="$jobid"
        elif [ "$kind" = "at" ]; then
            src_line="$taskline"
        else
            src_line="$task"
        fi

        display="${src_line#*\# TASK:*:}"

        if (( line-1 == calendarIndex )); then
            if [ -n "$COLOR_SELECTION_BG" ]; then
                printf '%s%s' "$COLOR_SELECTION_BG" "$COLOR_SELECTION_FG"
            else
                tput rev
            fi
        fi
        printf ' %-*.*s' "$((previewWidth-2))" "$((previewWidth-2))" "$display"
        if (( line-1 == calendarIndex )); then
            if [ -n "$COLOR_RESET" ]; then
                printf '%s' "$COLOR_RESET"
            else
                tput sgr0
            fi
        fi
        line=$((line+1))
    done
}

renderCalendarStatus() {
    partitionH $((lines-2))
    move 0 $((lines-1))

    if [ -n "$COLOR_STATUS" ]; then
        printf '%s' "$COLOR_STATUS"
    fi
    
    if [ -n "$status" ]; then
        local max_len=$((columns - 2))
        local trunc="${status:0:$max_len}"
        printf '%-*.*s' "$columns" "$columns" " $trunc"
    else
        local msg=' [←→] Change Day  [↑/↓] Select Task  [n] New Task  [d] Delete  [b] Browse  [q] Quit'
        printf '%-*.*s' "$columns" "$columns" "$msg"
    fi

    if [ -n "$COLOR_RESET" ]; then
        printf '%s' "$COLOR_RESET"
    fi
}

runSearch() {
    local query="$1"
    searchedFiles=()
    searchedSnips=()

    if [ -z "$query" ]; then
        set_status "Aborted Search"
        mode="browse"
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

    local now
    now=$(date +%s)
    if (( ${status_until:-0} > 0 && now >= ${status_until:-0} )); then
        status=""
        status_until=0
        force_redraw=1
    fi

    layoutDim

    if [ "$force_redraw" -eq 1 ]; then
        tput clear
        force_redraw=0
    fi
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
        calendar)
            renderCalendar
            renderTasks
            renderCalendarStatus
            ;;
    esac
}

read_key() {
    IFS= read -rsn1 key || return 1
    case "$key" in
        $'\e')
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
    local delta=$4

    if ((max<=0)); then
        return
    fi

    idx=$(( idx + delta ))
    if (( idx<0 )); then
        idx=$((max-1))
    elif (( idx>=max )); then
        idx=0
    fi

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
    tput clear
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

    [ -n "$title" ] || { set_status "Aborted"; return; }

    local slug
    slug=$(slugify "$title")
    local file="$notesDir/${slug}.txt"
    alt_screen_off
    $editor "$file"
    alt_screen_on

    tput clear
    refresh
    browseIndex=0
    browseOffset=0
    set_status "Created: $slug.txt $(date '+%Y-%m-%d %H:%M')"
}

renameNote() {
    local file=${presentFiles[browseIndex]:-}
    [ -f "$file" ] || { set_status "No file"; return; }

    move 0 $((lines-1))
    printf '%-*s' "$columns" " Rename to: "
    move 12 $((lines-1))
    tty_settings=$(stty -g)
    stty echo
    IFS= read -r title
    stty "$tty_settings"

    [ -n "$title" ] || { set_status "Aborted"; return; }

    local slug
    slug=$(slugify "$title")
    local new="$notesDir/${slug}.txt"

    mv "$file" "$new"
    set_status "Renamed to $(basename "$new")"
    refresh
}

deleteNote() {
    local file=${presentFiles[browseIndex]:-}
    [ -f "$file" ] || { set_status "No file"; return; }

    move 0 $((lines-1))
    printf '%-*s' "$columns" " Delete $(basename "$file") ? [y/N] "
    IFS= read -rsn1 yn

    case "$yn" in
        y|Y)
            rm -f "$file"
            set_status "Deleted"
            refresh
            ;;
        *)
            set_status "Aborted"
            ;;
    esac
}

list_tasks() {
    local day
    day=$(date -d "$calendarDate" +%Y-%m-%d)

    # Cron-based tasks (repetitive)
    crontab -l 2>/dev/null | grep "# TASK:$day:" | sed 's/^/cron|/' || true

    # One-off tasks scheduled with "at"
    if command -v at >/dev/null 2>&1; then
        atq 2>/dev/null | while read -r job rest; do
            [ -z "$job" ] && continue
            # Look for our TASK marker for this day in the job body
            local line
            line=$(at -c "$job" 2>/dev/null | grep "# TASK:$day:" | head -n1 || true)
            [ -z "$line" ] && continue
            printf 'at|%s|%s\n' "$job" "$line"
        done
    fi
}

newTask() {
    local day
    day=$(date -d "$calendarDate" +%Y-%m-%d)

    # Get task description
    move 0 $((lines-1))
    printf '%-*s' "$columns" ' Task: '
    move 7 $((lines-1))
    tty_settings=$(stty -g)
    stty echo
    IFS= read -r task
    stty "$tty_settings"

    [ -n "$task" ] || { set_status "Aborted"; return; }

    # Get time
    move 0 $((lines-1))
    printf '%-*s' "$columns" ' Time (HH:MM): '
    move 15 $((lines-1))
    stty echo
    IFS= read -r time
    stty "$tty_settings"

    [ -n "$time" ] || { set_status "Aborted"; return; }

    local hour="${time%%:*}"
    local min="${time##*:}"

    # Ask if repetitive
    move 0 $((lines-1))
    printf '%-*s' "$columns" ' Repetitive task? [y/N]: '
    IFS= read -rsn1 repeat

    case "$repeat" in
        y|Y)
            # Repeating task: use crontab (current flow)
            (crontab -l 2>/dev/null; \
                printf '%s %s %s %s * XDG_RUNTIME_DIR=/run/user/%s DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/%s/bus DISPLAY=:0 /usr/bin/notify-send --app-name=Task "Task" %q # TASK:%s:%s\n' \
                    "$min" "$hour" "$(date -d "$day" +%d)" "$(date -d "$day" +%m)" \
                    "$(id -u)" "$(id -u)" \
                    "$task" "$day" "$task") | crontab -
            set_status "Repeating task added: $task at $time"
            ;;
        *)
            # One-off task: use at
            if ! command -v at >/dev/null 2>&1; then
                set_status "'at' command not found"
                return
            fi

            local at_time
            if ! at_time=$(date -d "$day $time" +%Y%m%d%H%M 2>/dev/null); then
                set_status "Invalid date/time"
                return
            fi

            if printf 'XDG_RUNTIME_DIR=/run/user/%s DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/%s/bus DISPLAY=:0 /usr/bin/notify-send --app-name=Task "Task" %q # TASK:%s:%s\n' \
                "$(id -u)" "$(id -u)" \
                "$task" "$day" "$task" | at -t "$at_time" 2>/dev/null; then
                set_status "One-off task added: $task at $time"
            else
                set_status "Failed to schedule task with at"
            fi
            ;;
    esac
}

deleteTask() {
    mapfile -t tasks < <(list_tasks)

    [ ${#tasks[@]} -eq 0 ] && { set_status "No tasks"; return; }
    [ $calendarIndex -ge ${#tasks[@]} ] && { set_status "No task selected"; return; }

    local task="${tasks[calendarIndex]}"

    move 0 $((lines-1))
    printf '%-*s' "$columns" " Delete task? [y/N] "
    IFS= read -rsn1 yn

    case "$yn" in
        y|Y)
            local kind jobid taskline
            IFS='|' read -r kind jobid taskline <<< "$task"
            if [ "$kind" = "cron" ]; then
                # jobid is the original cron line
                crontab -l 2>/dev/null | grep -vF "$jobid" | crontab - 2>/dev/null || true
            elif [ "$kind" = "at" ]; then
                # jobid is the at job id
                at -d "$jobid" 2>/dev/null || atrm "$jobid" 2>/dev/null || true
            fi
            calendarIndex=0
            set_status "Deleted"
            ;;
        *)
            set_status "Aborted"
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
            e|'')      [ -n "${presentFiles[browseIndex]:-}" ] && openEditor "${presentFiles[browseIndex]}" ;;
            n)         newNote ;;
            r)         renameNote ;;
            d)         deleteNote ;;
            c)         mode="calendar"; force_redraw=1; return ;;
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
                force_redraw=1
                return
                ;;
            q)         mode="quit"; return ;;
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
            e|'')
                if [ -n "${searchedFiles[searchIndex]:-}" ]; then
                    local entry="${searchedFiles[searchIndex]}"
                    local file="${entry%%:*}"
                    openEditor "$file"
                fi
                ;;
            b)         mode="browse"; force_redraw=1; return ;;
            q)         mode="quit"; return ;;
        esac
    done
}

loop_calendar() {
    while :; do
        draw_all
        key=$(read_key) || return
        case "$key" in
            $'\e[A'|k)
                mapfile -t tasks < <(list_tasks)
                [ ${#tasks[@]} -gt 0 ] && moveSelection calendarIndex calendarOffset "${#tasks[@]}" -1
                ;;
            $'\e[B'|j)
                mapfile -t tasks < <(list_tasks)
                [ ${#tasks[@]} -gt 0 ] && moveSelection calendarIndex calendarOffset "${#tasks[@]}" 1
                ;;
            $'\e[D')
                calendarDate=$(date -d "$calendarDate - 1 day" +%Y-%m-%d)
                calendarIndex=0
                ;;
            $'\e[C')
                calendarDate=$(date -d "$calendarDate + 1 day" +%Y-%m-%d)
                calendarIndex=0
                ;;
            n) newTask ;;
            d) deleteTask ;;
            b) mode="browse"; force_redraw=1; return ;;
            q) mode="quit"; return ;;
        esac
    done
}

# Main
alt_screen_on
layoutDim
force_redraw=1
mode="browse"

while :; do
    case "$mode" in
        browse)   loop_browse ;;
        search)   loop_search ;;
        calendar) loop_calendar ;;
        quit)     break ;;
    esac
    refresh
done
