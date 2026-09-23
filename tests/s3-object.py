"""One S3 call against this stack's Garage, for the restore test.

    python3 tests/s3-object.py put <key> <text>   store <text> under <key>
    python3 tests/s3-object.py get <key>          print it; exit 1 if absent
    python3 tests/s3-object.py absent <key>       exit 0 only if it is gone

Same client and route as tests/s3-contract.py: path style, through Traefik on
the public S3 hostname, as Outline and a browser reach it. S3_HOST, AK, SK and
BUCKET come from the environment.
"""
import os
import sys

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

s3 = boto3.client(
    "s3",
    endpoint_url="https://" + os.environ["S3_HOST"],
    region_name="garage",
    aws_access_key_id=os.environ["AK"],
    aws_secret_access_key=os.environ["SK"],
    config=Config(signature_version="s3v4", s3={"addressing_style": "path"}),
    verify=False,  # CI terminates TLS with Traefik's own certificate
)
BUCKET = os.environ.get("BUCKET", "data")


def get(key):
    try:
        return s3.get_object(Bucket=BUCKET, Key=key)["Body"].read().decode()
    except ClientError as exc:
        if exc.response["Error"]["Code"] in ("NoSuchKey", "404"):
            return None
        raise


if __name__ == "__main__":
    import urllib3

    urllib3.disable_warnings()
    op, key = sys.argv[1], sys.argv[2]
    if op == "put":
        s3.put_object(Bucket=BUCKET, Key=key, Body=sys.argv[3].encode())
    elif op == "get":
        body = get(key)
        if body is None:
            sys.exit(1)
        print(body)
    elif op == "absent":
        sys.exit(0 if get(key) is None else 1)
    else:
        sys.exit("unknown operation " + op)
