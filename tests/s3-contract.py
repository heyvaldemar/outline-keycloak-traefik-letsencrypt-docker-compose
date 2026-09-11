"""Every S3 operation Outline performs, against the storage this stack ships.

Run by the deployment workflow after the stack is up, and usable by hand:

    set -a; . ./.env; set +a
    S3_HOST=$OUTLINE_S3_HOSTNAME AK=$OUTLINE_S3_ACCESS_KEY \
    SK=$OUTLINE_S3_SECRET_KEY BUCKET=data python3 tests/s3-contract.py

"Garage speaks S3" is not the claim worth checking. What matters is the
handful of calls Outline actually makes, and the one most likely to fail
quietly is the presigned POST: Outline's default upload method hands the
browser a signed policy rather than a signed PUT, and a signature that covers
the Host header stops matching the moment a proxy rewrites it. So every request
below goes through Traefik on the public hostname, exactly as a browser's would.
"""
import io
import os
import ssl
import sys
import urllib.error
import urllib.request
import uuid

import boto3
from botocore.config import Config

HOST = os.environ["S3_HOST"]
BUCKET = os.environ.get("BUCKET", "data")
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE  # CI terminates TLS with Traefik's own cert

s3 = boto3.client(
    "s3",
    endpoint_url="https://" + HOST,
    region_name="garage",
    aws_access_key_id=os.environ["AK"],
    aws_secret_access_key=os.environ["SK"],
    config=Config(signature_version="s3v4", s3={"addressing_style": "path"}),
    verify=False,
)

passed, failed = 0, []


def check(name, fn):
    global passed
    try:
        detail = fn()
        print("  PASS  %-34s %s" % (name, detail or ""))
        passed += 1
    except Exception as exc:  # noqa: BLE001 - the report is the point
        print("  FAIL  %-34s %s: %s" % (name, type(exc).__name__, exc))
        failed.append(name)


def put_get():
    key = "contract/%s.txt" % uuid.uuid4()
    s3.put_object(Bucket=BUCKET, Key=key, Body=b"direct", ACL="private")
    got = s3.get_object(Bucket=BUCKET, Key=key)["Body"].read()
    assert got == b"direct", got
    s3.delete_object(Bucket=BUCKET, Key=key)
    return "put, get and delete with ACL private"


def presigned_put():
    key = "contract/%s.bin" % uuid.uuid4()
    url = s3.generate_presigned_url(
        "put_object",
        Params={"Bucket": BUCKET, "Key": key, "ContentType": "application/octet-stream"},
        ExpiresIn=300)
    req = urllib.request.Request(url, data=b"z" * 2048, method="PUT",
                                 headers={"Content-Type": "application/octet-stream"})
    with urllib.request.urlopen(req, context=CTX) as r:
        assert r.status in (200, 204), r.status
    assert s3.head_object(Bucket=BUCKET, Key=key)["ContentLength"] == 2048
    return "signature survived the proxy"


def presigned_post():
    """Outline's default upload method (AWS_S3_UPLOAD_METHOD=post)."""
    key = "contract/%s-post.txt" % uuid.uuid4()
    p = s3.generate_presigned_post(
        Bucket=BUCKET, Key=key,
        Fields={"acl": "private", "Content-Type": "text/plain"},
        Conditions=[{"acl": "private"}, {"Content-Type": "text/plain"},
                    ["content-length-range", 1, 1048576]],
        ExpiresIn=300)
    boundary = "----contract%s" % uuid.uuid4().hex
    body = io.BytesIO()
    for name, value in p["fields"].items():
        body.write(('--%s\r\nContent-Disposition: form-data; name="%s"\r\n\r\n'
                    % (boundary, name)).encode())
        body.write(value.encode() + b"\r\n")
    body.write(('--%s\r\nContent-Disposition: form-data; name="file"; filename="a.txt"\r\n'
                'Content-Type: text/plain\r\n\r\n' % boundary).encode())
    body.write(b"posted by a browser-shaped request\r\n")
    body.write(("--%s--\r\n" % boundary).encode())
    req = urllib.request.Request(
        p["url"], data=body.getvalue(), method="POST",
        headers={"Content-Type": "multipart/form-data; boundary=%s" % boundary})
    with urllib.request.urlopen(req, context=CTX) as r:
        assert r.status in (200, 204), r.status
    got = s3.get_object(Bucket=BUCKET, Key=key)["Body"].read()
    assert b"browser-shaped" in got, got
    return "the default upload path"


def presigned_get():
    key = "contract/%s-served.txt" % uuid.uuid4()
    s3.put_object(Bucket=BUCKET, Key=key, Body=b"served to a reader")
    url = s3.generate_presigned_url("get_object",
                                    Params={"Bucket": BUCKET, "Key": key}, ExpiresIn=300)
    with urllib.request.urlopen(url, context=CTX) as r:
        assert r.read() == b"served to a reader"
    return "how attachments reach a browser"


def multipart():
    key = "contract/%s-multipart.bin" % uuid.uuid4()
    up = s3.create_multipart_upload(Bucket=BUCKET, Key=key)
    part = s3.upload_part(Bucket=BUCKET, Key=key, UploadId=up["UploadId"],
                          PartNumber=1, Body=b"m" * (5 * 1024 * 1024))
    s3.list_parts(Bucket=BUCKET, Key=key, UploadId=up["UploadId"])
    s3.complete_multipart_upload(
        Bucket=BUCKET, Key=key, UploadId=up["UploadId"],
        MultipartUpload={"Parts": [{"ETag": part["ETag"], "PartNumber": 1}]})
    n = s3.head_object(Bucket=BUCKET, Key=key)["ContentLength"]
    assert n == 5 * 1024 * 1024, n
    aborted = s3.create_multipart_upload(Bucket=BUCKET, Key=key + ".aborted")
    s3.abort_multipart_upload(Bucket=BUCKET, Key=key + ".aborted",
                              UploadId=aborted["UploadId"])
    return "create, upload, list, complete and abort"


def cors():
    """A browser uploading to a different origin needs this to be settable."""
    s3.put_bucket_cors(Bucket=BUCKET, CORSConfiguration={"CORSRules": [{
        "AllowedHeaders": ["*"],
        "AllowedMethods": ["GET", "PUT", "POST", "HEAD"],
        "AllowedOrigins": ["https://" + os.environ.get("APP_HOSTNAME", "example.com")],
        "ExposeHeaders": ["ETag"]}]})
    rules = s3.get_bucket_cors(Bucket=BUCKET)["CORSRules"]
    assert "POST" in rules[0]["AllowedMethods"], rules
    return "settable and readable back"


print("=== the S3 contract Outline depends on, through Traefik at %s ===" % HOST)
check("direct put/get/delete", put_get)
check("presigned PUT", presigned_put)
check("presigned POST", presigned_post)
check("presigned GET", presigned_get)
check("multipart upload", multipart)
check("bucket CORS", cors)

print()
print("passed: %d  failed: %d" % (passed, len(failed)))
if failed:
    print("failures: " + ", ".join(failed))
    sys.exit(1)
