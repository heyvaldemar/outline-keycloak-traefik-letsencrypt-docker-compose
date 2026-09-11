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
# BusyBox wget has no --method. The admin API reads with GET and mutates with
# POST, so a plain fetch and --post-data cover every call this makes.
set -eu

A="http://${GARAGE_HOST}:3903"
H="Authorization: Bearer ${GARAGE_ADMIN_TOKEN}"
get()  { wget -q -O- --header="$H" "$A$1"; }
post() { wget -q -O- --header="$H" --header="Content-Type: application/json" --post-data="$2" "$A$1"; }
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
