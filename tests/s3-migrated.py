"""The objects the migration script moved are readable from the new storage.

Run by the deployment workflow immediately after outline-minio-to-garage.sh.
A migration that reports success and leaves unreadable objects behind is worse
than one that fails, because nothing looks wrong until somebody opens a
document from before the upgrade.
"""
import os
import sys

import boto3
from botocore.config import Config

s3 = boto3.client(
    "s3",
    endpoint_url="https://" + os.environ["S3_HOST"],
    region_name="garage",
    aws_access_key_id=os.environ["AK"],
    aws_secret_access_key=os.environ["SK"],
    config=Config(signature_version="s3v4", s3={"addressing_style": "path"}),
    verify=False,
)
BUCKET = os.environ.get("BUCKET", "data")

ok = True

body = s3.get_object(Bucket=BUCKET, Key="uploads/legacy.txt")["Body"].read()
if b"written under MinIO before the upgrade" in body:
    print("  PASS  the text object written under MinIO reads correctly from Garage")
else:
    print("  FAIL  uploads/legacy.txt came back as %r" % body[:80])
    ok = False

size = s3.head_object(Bucket=BUCKET, Key="uploads/legacy-big.bin")["ContentLength"]
if size == 300000:
    print("  PASS  the 300 KB binary object arrived whole (%d bytes)" % size)
else:
    print("  FAIL  uploads/legacy-big.bin is %d bytes, expected 300000" % size)
    ok = False

sys.exit(0 if ok else 1)
