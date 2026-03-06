#!/bin/sh

KINDLEFETCH_ROOT=""
TMP_DIR="/tmp"

print_marker() {
    printf '__KF_%s__=%s\n' "$1" "$2"
}

resolve_kindlefetch_root() {
    if [ -n "$KINDLEFETCH_ROOT" ]; then
        if [ -f "$KINDLEFETCH_ROOT/bin/kindlefetch.sh" ]; then
            printf '%s\n' "$KINDLEFETCH_ROOT"
            return 0
        fi
        if [ -f "$KINDLEFETCH_ROOT/kindlefetch/bin/kindlefetch.sh" ]; then
            printf '%s/kindlefetch\n' "$KINDLEFETCH_ROOT"
            return 0
        fi
    fi

    for candidate in \
        "/mnt/us/extensions/kindlefetch" \
        "/mnt/us/extensions/KindleFetch" \
        "/home/nullvoid/scratch/KindleFetch/kindlefetch" \
        "/home/nullvoid/scratch/KindleFetch"
    do
        if [ -f "$candidate/bin/kindlefetch.sh" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
        if [ -f "$candidate/kindlefetch/bin/kindlefetch.sh" ]; then
            printf '%s/kindlefetch\n' "$candidate"
            return 0
        fi
    done

    return 1
}

load_kindlefetch_environment() {
    KF_ROOT="$(resolve_kindlefetch_root)" || return 1

    SCRIPT_DIR="$KF_ROOT/bin"
    CONFIG_FILE="$SCRIPT_DIR/kindlefetch_config"
    LINK_CONFIG_FILE="$SCRIPT_DIR/link_config"
    VERSION_FILE="$SCRIPT_DIR/.version"
    ZLIB_COOKIES_FILE="$SCRIPT_DIR/zlib_cookies.txt"
    BASE_DIR="/mnt/us"

    CREATE_SUBFOLDERS=false
    COMPACT_OUTPUT=false
    ENFORCE_DNS=false
    RESULTS_PER_PAGE=10
    COVER_CACHE=false
    COVER_CACHE_LIMIT=8
    KINDLE_DOCUMENTS="$BASE_DIR/documents"
    ZLIB_AUTH=false

    if [ -f "$LINK_CONFIG_FILE" ]; then
        eval "$(base64 -d "$LINK_CONFIG_FILE" 2>/dev/null)"
    fi

    if [ -f "$CONFIG_FILE" ]; then
        . "$CONFIG_FILE"
    fi

    if [ -z "$KINDLE_DOCUMENTS" ]; then
        KINDLE_DOCUMENTS="$BASE_DIR/documents"
    fi

    . "$SCRIPT_DIR/misc.sh"
    . "$SCRIPT_DIR/downloads/lgli_download.sh"
    . "$SCRIPT_DIR/downloads/zlib_download.sh"

    if [ -z "$ANNAS_URL" ] && [ -n "$ANNAS_MIRROR_URLS" ]; then
        ANNAS_URL="$(find_working_url $ANNAS_MIRROR_URLS 2>/dev/null)"
    fi
    if [ -z "$LGLI_URL" ] && [ -n "$LGLI_MIRROR_URLS" ]; then
        LGLI_URL="$(find_working_url $LGLI_MIRROR_URLS 2>/dev/null)"
    fi
    if [ -z "$ZLIB_URL" ] && [ -n "$ZLIB_MIRROR_URLS" ]; then
        ZLIB_URL="$(find_working_url $ZLIB_MIRROR_URLS 2>/dev/null)"
    fi

    return 0
}

command_probe() {
    if ! load_kindlefetch_environment; then
        print_marker "FOUND" "0"
        echo "KindleFetch installation not found." >&2
        return 1
    fi

    print_marker "FOUND" "1"
    print_marker "ROOT" "$KF_ROOT"
    print_marker "DOCS" "$KINDLE_DOCUMENTS"
    print_marker "COVER_CACHE" "$COVER_CACHE"
    print_marker "COVER_CACHE_LIMIT" "$COVER_CACHE_LIMIT"
    return 0
}

command_search() {
    query=""
    page=1
    source=""
    extension=""
    language=""
    sort=""
    results_per_page=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --query)
                query="$2"
                shift 2
                ;;
            --page)
                page="$2"
                shift 2
                ;;
            --source)
                source="$2"
                shift 2
                ;;
            --format)
                extension="$2"
                shift 2
                ;;
            --language)
                language="$2"
                shift 2
                ;;
            --sort)
                sort="$2"
                shift 2
                ;;
            --results-per-page)
                results_per_page="$2"
                shift 2
                ;;
            *)
                echo "Unknown search option: $1" >&2
                return 2
                ;;
        esac
    done

    if [ -z "$query" ]; then
        echo "Missing --query argument." >&2
        return 2
    fi

    if ! load_kindlefetch_environment; then
        echo "KindleFetch installation not found." >&2
        return 1
    fi

    if [ -n "$results_per_page" ] && echo "$results_per_page" | grep -qE '^[0-9]+$'; then
        RESULTS_PER_PAGE="$results_per_page"
    fi

    if [ "$source" = "all" ]; then
        source=""
    fi

    filters=""
    [ -n "$source" ] && filters="${filters}&src=${source}"
    [ -n "$extension" ] && filters="${filters}&ext=${extension}"
    [ -n "$language" ] && filters="${filters}&lang=${language}"
    [ -n "$sort" ] && filters="${filters}&sort=${sort}"

    if [ -z "$ANNAS_URL" ]; then
        echo "Anna's Archive mirror is not configured." >&2
        return 1
    fi

    encoded_query="$(printf '%s' "$query" | sed 's/ /+/g')"
    search_url="$ANNAS_URL/search?page=${page}&q=${encoded_query}${filters}"

    html_content="$(curl -s -L --max-time 60 "$search_url" 2>/dev/null)"
    if [ -z "$html_content" ] && [ -n "$PROXY_URL" ]; then
        html_content="$(curl -s -L --max-time 60 -x "$PROXY_URL" "$search_url" 2>/dev/null)"
    fi

    if [ -z "$html_content" ]; then
        echo "Search request failed." >&2
        return 1
    fi

    last_page="$(printf '%s' "$html_content" | grep -o 'page=[0-9]\+"' | sort -t= -k2 -nr | head -1 | cut -d= -f2 | tr -d '"')"
    [ -z "$last_page" ] && last_page=1

    books="$(
        printf '%s' "$html_content" | awk -v base_url="$ANNAS_URL" '
            BEGIN {
                RS = "<div class=\"flex[^\"]*pt-3 pb-3 border-b last:border-b-0 border-gray-100\">"
                print "["
                count = 0
            }
            NR > 1 {
                title = ""; author = ""; md5 = ""; format = ""; size = ""; description = ""; cover_url = ""

                if (match($0, /href="\/md5\/[a-f0-9]+"/)) {
                    md5 = substr($0, RSTART + 11, RLENGTH - 12)
                }

                if (match($0, /<div class="font-bold text-violet-900 line-clamp-\[5\]" data-content="[^"]+"/)) {
                    block = substr($0, RSTART, RLENGTH)
                    if (match(block, /data-content="[^"]+"/)) {
                        title = substr(block, RSTART+14, RLENGTH-15)
                    }
                }

                if ($0 ~ /<div[^>]*class="[^"]*font-bold[^"]*text-amber-900[^"]*line-clamp-\[2\][^"]*"/) {
                    if (match($0, /<div[^>]*class="[^"]*font-bold[^"]*text-amber-900[^"]*line-clamp-\[2\][^"]*" data-content="[^"]+"/)) {
                        block = substr($0, RSTART, RLENGTH)
                        if (match(block, /data-content="[^"]+"/)) {
                            author = substr(block, RSTART+14, RLENGTH-15)
                        }
                    }
                }

                if (match($0, /<img[^>]*data-src="[^"]+"/)) {
                    block = substr($0, RSTART, RLENGTH)
                    if (match(block, /data-src="[^"]+"/)) {
                        cover_url = substr(block, RSTART + 10, RLENGTH - 11)
                    }
                }
                if (cover_url == "" && match($0, /<img[^>]*src="[^"]+"/)) {
                    block = substr($0, RSTART, RLENGTH)
                    if (match(block, /src="[^"]+"/)) {
                        cover_url = substr(block, RSTART + 5, RLENGTH - 6)
                    }
                }
                if (cover_url ~ /^\/\//) {
                    cover_url = "https:" cover_url
                } else if (cover_url ~ /^\//) {
                    cover_url = base_url cover_url
                }

                if (match($0, /<div class="text-gray-800[^>]*>[^<]+/)) {
                    line = substr($0, RSTART, RLENGTH)
                    if (match(line, />[^<]+/)) {
                        content = substr(line, RSTART+1, RLENGTH-1)
                        n = split(content, parts, " · ")
                        if (n >= 2) {
                            format = parts[2]
                        }
                        if (match(content, /[0-9]+([.][0-9]+)?[[:space:]]*[KkMmGgTt][Bb]/)) {
                            size = substr(content, RSTART, RLENGTH)
                        }
                    }
                }

                if (match($0, /<div[^>]*class="[^"]*text-gray-800[^"]*font-semibold[^"]*text-sm[^"]*leading-\[1\.2\][^"]*mt-2[^"]*"[^>]*>.*?<\/div>/)) {
                    line = substr($0, RSTART, RLENGTH)
                    gsub(/<script[^>]*>[^<]*(<[^>]*>[^<]*)*<\/script>/, "", line)
                    gsub(/<a[^>]*>[^<]*(<[^>]*>[^<]*)*<\/a>/, "", line)
                    gsub(/<[^>]*>/, "", line)
                    gsub(/&[#a-zA-Z0-9]+;/, "", line)
                    gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", line)
                    description = line
                }

                gsub(/🚀/, "Partner Server", description)
                gsub(/📗|📘|📕|📰|💬|📝|🤨|🎶|✅/, "", description)

                gsub(/[\r\n\t]+/, " ", title)
                gsub(/[\r\n\t]+/, " ", author)
                gsub(/[\r\n\t]+/, " ", size)
                gsub(/[\r\n\t]+/, " ", description)
                gsub(/[\r\n\t]+/, " ", cover_url)
                gsub(/[ ]+/, " ", title)
                gsub(/[ ]+/, " ", author)
                gsub(/[ ]+/, " ", size)
                gsub(/[ ]+/, " ", description)
                gsub(/[ ]+/, " ", cover_url)
                gsub(/^[ ]+|[ ]+$/, "", title)
                gsub(/^[ ]+|[ ]+$/, "", author)
                gsub(/^[ ]+|[ ]+$/, "", size)
                gsub(/^[ ]+|[ ]+$/, "", description)
                gsub(/^[ ]+|[ ]+$/, "", cover_url)

                gsub(/"/, "\\\"", title)
                gsub(/"/, "\\\"", author)
                gsub(/"/, "\\\"", size)
                gsub(/"/, "\\\"", description)
                gsub(/"/, "\\\"", cover_url)

                format_lc = tolower(format)
                if (title != "" && (format_lc == "epub" || format_lc == "pdf")) {
                    if (count > 0) {
                        printf ",\n"
                    }
                    printf "  {\"author\": \"%s\", \"cover_url\": \"%s\", \"format\": \"%s\", \"md5\": \"%s\", \"size\": \"%s\", \"title\": \"%s\", \"url\": \"%s/md5/%s\", \"description\": \"%s\"}", author, cover_url, format, md5, size, title, base_url, md5, description
                    count++
                }
            }
            END {
                print "\n]"
            }'
    )"

    results_file="$TMP_DIR/search_results.json"
    printf '%s\n' "$books" > "$results_file"

    count="$(grep -o '"title":' "$results_file" | wc -l | tr -d '[:space:]')"
    [ -z "$count" ] && count=0

    printf '%s\n' "$query" > "$TMP_DIR/last_search_query"
    printf '%s\n' "$page" > "$TMP_DIR/last_search_page"
    printf '%s\n' "$last_page" > "$TMP_DIR/last_search_last_page"

    print_marker "PAGE" "$page"
    print_marker "LAST_PAGE" "$last_page"
    print_marker "COUNT" "$count"
    print_marker "RESULTS_FILE" "$results_file"
    return 0
}

command_download() {
    index=""
    source=""
    custom_filename=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --index)
                index="$2"
                shift 2
                ;;
            --source)
                source="$2"
                shift 2
                ;;
            --filename)
                custom_filename="$2"
                shift 2
                ;;
            *)
                echo "Unknown download option: $1" >&2
                return 2
                ;;
        esac
    done

    if ! echo "$index" | grep -qE '^[0-9]+$'; then
        echo "Invalid or missing --index argument." >&2
        return 2
    fi

    if [ "$source" != "lgli" ] && [ "$source" != "zlib" ]; then
        echo "Invalid or missing --source argument." >&2
        return 2
    fi

    if ! load_kindlefetch_environment; then
        echo "KindleFetch installation not found." >&2
        return 1
    fi

    err_file="$TMP_DIR/kf_bridge_download_err.$$"
    output=""
    status=1

    if [ "$source" = "lgli" ]; then
        if [ -n "$custom_filename" ]; then
            output="$({ printf 'y\n%s\n' "$custom_filename"; } | lgli_download "$index" 2> "$err_file")"
            status=$?
        else
            output="$(printf 'n\n' | lgli_download "$index" 2> "$err_file")"
            status=$?
        fi
    else
        if [ -n "$custom_filename" ]; then
            output="$({ printf 'y\n%s\n' "$custom_filename"; } | zlib_download "$index" 2> "$err_file")"
            status=$?
        else
            output="$(printf 'n\n' | zlib_download "$index" 2> "$err_file")"
            status=$?
        fi
    fi

    if [ -s "$err_file" ]; then
        err_summary="$(tr '\r' '\n' < "$err_file" | sed '/^[[:space:]]*$/d' | tail -n 12)"
        if [ -n "$err_summary" ]; then
            if [ -n "$output" ]; then
                output="$output
$err_summary"
            else
                output="$err_summary"
            fi
        fi
    fi
    rm -f "$err_file"

    printf '%s\n' "$output"

    if [ "$status" -eq 0 ]; then
        saved_path="$(printf '%s\n' "$output" | sed -n 's/^Saved to: //p' | tail -n 1 | tr -d '\r')"
        [ -n "$saved_path" ] && print_marker "SAVED_PATH" "$saved_path"
        print_marker "STATUS" "ok"
        return 0
    fi

    print_marker "STATUS" "error"
    return 1
}

command_cache_covers() {
    results_file="$TMP_DIR/search_results.json"
    limit=""
    force="false"

    while [ $# -gt 0 ]; do
        case "$1" in
            --results-file)
                results_file="$2"
                shift 2
                ;;
            --limit)
                limit="$2"
                shift 2
                ;;
            --force)
                force="true"
                shift
                ;;
            *)
                echo "Unknown cache-covers option: $1" >&2
                return 2
                ;;
        esac
    done

    if ! load_kindlefetch_environment; then
        echo "KindleFetch installation not found." >&2
        return 1
    fi

    if [ ! -f "$results_file" ]; then
        echo "Results file not found: $results_file" >&2
        return 1
    fi

    if [ -z "$limit" ]; then
        limit="$COVER_CACHE_LIMIT"
    fi

    if [ "$COVER_CACHE" != "true" ] && [ "$force" != "true" ]; then
        print_marker "COVER_CACHE_ENABLED" "0"
        return 0
    fi

    cache_search_result_covers "$results_file" "$limit" "$force" >/dev/null 2>&1 &
    print_marker "COVER_CACHE_ENABLED" "1"
    print_marker "COVER_CACHE_STARTED" "1"
    return 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --root)
            KINDLEFETCH_ROOT="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        probe|search|download|cache-covers)
            break
            ;;
        *)
            break
            ;;
    esac
done

command="$1"
shift || true

case "$command" in
    probe)
        command_probe "$@"
        ;;
    search)
        command_search "$@"
        ;;
    download)
        command_download "$@"
        ;;
    cache-covers)
        command_cache_covers "$@"
        ;;
    *)
        echo "Usage: $0 [--root PATH] {probe|search|download|cache-covers} ..." >&2
        exit 2
        ;;
esac
