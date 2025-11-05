#!/bin/bash

# Start with today
current=$(date +%Y-%m-%d)

while true; do
    clear
    
    # Extract day, month, year
    day=$(date -d "$current" +%d)
    month=$(date -d "$current" +%m)
    year=$(date -d "$current" +%Y)
    
    # Show calendar with current day highlighted
    cal $day $month $year
    
    # Read arrow keys
    read -rsn1 key
    if [[ $key == $'\x1b' ]]; then
        read -rsn2 key
        case $key in
            '[D') # Left arrow - previous day
                current=$(date -d "$current - 1 day" +%Y-%m-%d)
                ;;
            '[C') # Right arrow - next day
                current=$(date -d "$current + 1 day" +%Y-%m-%d)
                ;;
        esac
    fi
done
