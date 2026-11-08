#!/bin/sh
# Garage bootstrap: storage layout, access key, bucket, permissions.
#
# Runs once on every `up -d`, exits, and the Outline container waits for it to
# have exited successfully. It is idempotent by construction: every step asks
# first and says what it found.
#
# WHY THIS TALKS TO THE ADMIN API INSTEAD OF RUNNING `garage`.
# The Garage image is built FROM scratch and contains nothing but the `garage`
# binary — there is no /bin/sh in it, so an init container that runs a script
# inside that image cannot start at all. The alternative people reach for is a
# host script driving `docker exec`, which means the bootstrap is a thing you
# have to remember after `up -d` rather than part of it. The admin API needs no
# shell on the other side and no Docker socket on this one.
#
# THE REQUEST TRAVELS ON STDIN, NOT ON A COMMAND LINE. This used BusyBox wget,
# with the admin token in --header and the S3 secret key in --post-data: both
# in wget's arguments, which every user on the host reads with ps while the
# call runs. BusyBox wget takes headers from nowhere else, so each request is
# written by the shell's own printf into nc through a FIFO, and the reply's
# status line decides success the way wget's exit status did.
# The FIFO stays open until the reply is whole (its Content-Length is in):
# BusyBox nc half-closes the connection the moment its input ends, the admin
# API drops a request whose client did that before it answered, and it keeps
# an answered connection open for a minute.
set -eu

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
mkfifo "$W/in"
# reply_whole <file>: the headers have ended and Content-Length bytes followed
reply_whole() {
  hdr=$(awk '{ n += length($0) + 1 } /^\r?$/ { print n; exit }' "$1")
  [ -n "$hdr" ] || return 1
  len=$(tr -d '\r' < "$1" | sed -n 's/^[Cc][Oo][Nn][Tt][Ee][Nn][Tt]-[Ll][Ee][Nn][Gg][Tt][Hh]: *\([0-9]*\).*/\1/p' | head -n 1)
  [ "$(wc -c < "$1")" -ge $((hdr + ${len:-0})) ]
}
# http <METHOD> <path> [json body]: prints the reply body; fails unless 2xx.
http() {
  : > "$W/reply"
  nc "$GARAGE_HOST" 3903 < "$W/in" > "$W/reply" &
  nc_pid=$!
  exec 3> "$W/in"
  printf '%s %s HTTP/1.1\r\nHost: %s:3903\r\nAuthorization: Bearer %s\r\nConnection: close\r\n' "$1" "$2" "$GARAGE_HOST" "$GARAGE_ADMIN_TOKEN" >&3
  if [ -n "${3:-}" ]; then
    printf 'Content-Type: application/json\r\nContent-Length: %s\r\n\r\n%s' "${#3}" "$3" >&3
  else
    printf '\r\n' >&3
  fi
  i=0
  until reply_whole "$W/reply"; do
    i=$((i + 1))
    if [ "$i" -gt 300 ] || ! kill -0 "$nc_pid" 2>/dev/null; then break; fi
    sleep 0.1
  done
  exec 3>&-
  wait "$nc_pid" || true
  reply_whole "$W/reply" || return 1
  tr -d '\r' < "$W/reply" | sed '1,/^$/d'
  case "$(head -n 1 "$W/reply")" in
    "HTTP/1."?" 2"??" "*) return 0 ;;
    *) return 1 ;;
  esac
}
get()  { http GET "$1"; }
post() { http POST "$1" "$2"; }
# The admin API answers with pretty-printed JSON; these pull one scalar out of
# it without adding a JSON parser to this image.
jnum() { tr ',{}' '\n' | sed -n "s/.*\"$1\"[: ]*\([0-9]*\).*/\1/p" | head -1; }
jstr() { tr ',{}' '\n' | sed -n "s/.*\"$1\"[: ]*\"\([^\"]*\)\".*/\1/p" | head -1; }

echo "==> waiting for garage"
i=0
until get /v2/GetClusterStatus >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -gt 60 ] && { echo "garage did not answer its admin API in two minutes" >&2; exit 1; }
  sleep 2
done
NODE=$(get /v2/GetClusterStatus | jstr id)
[ -n "$NODE" ] || { echo "could not read the node id from the cluster status" >&2; exit 1; }
echo "    node $(echo "$NODE" | cut -c1-16)..."

echo "==> storage layout"
LV=$(get /v2/GetClusterLayout | jnum version)
if [ "${LV:-0}" -gt 0 ]; then
  echo "    already applied, version $LV"
else
  post /v2/UpdateClusterLayout \
    "{\"roles\":[{\"id\":\"$NODE\",\"zone\":\"$GARAGE_ZONE\",\"capacity\":$GARAGE_CAPACITY,\"tags\":[]}]}" > /dev/null
  # Read the pending version back rather than assuming 1: a re-run against a
  # partly configured node would otherwise apply a stale number and fail.
  NV=$(get /v2/GetClusterLayout | jnum version)
  post /v2/ApplyClusterLayout "{\"version\":$((NV + 1))}" > /dev/null
  echo "    assigned and applied as version $((NV + 1))"
fi

echo "==> access key"
if get "/v2/GetKeyInfo?id=$S3_ACCESS_KEY" > /dev/null 2>&1; then
  echo "    already present"
else
  # Imported rather than created. `CreateKey` invents a pair and returns it,
  # which a human would then have to paste into .env after every rebuild.
  # Importing the pair that is already there keeps .env the source of truth and
  # makes a rebuild reproducible instead of transcribed.
  post /v2/ImportKey \
    "{\"accessKeyId\":\"$S3_ACCESS_KEY\",\"secretAccessKey\":\"$S3_SECRET_KEY\",\"name\":\"$S3_KEY_NAME\"}" > /dev/null
  echo "    imported from .env"
fi

echo "==> bucket"
if get "/v2/GetBucketInfo?globalAlias=$S3_BUCKET" > /dev/null 2>&1; then
  echo "    already present"
else
  post /v2/CreateBucket "{\"globalAlias\":\"$S3_BUCKET\"}" > /dev/null
  echo "    created"
fi
BID=$(get "/v2/GetBucketInfo?globalAlias=$S3_BUCKET" | jstr id)
[ -n "$BID" ] || { echo "the bucket exists but its id could not be read" >&2; exit 1; }

echo "==> permissions"
post /v2/AllowBucketKey \
  "{\"bucketId\":\"$BID\",\"accessKeyId\":\"$S3_ACCESS_KEY\",\"permissions\":{\"read\":true,\"write\":true,\"owner\":true}}" > /dev/null
echo "    read, write and owner granted to $S3_KEY_NAME"

echo "bootstrap complete: bucket $S3_BUCKET is ready"
