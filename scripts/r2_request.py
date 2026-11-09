import datetime
import hashlib
import hmac
import mimetypes
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

method, bucket, key, file_path, immutable, maximum_bytes = sys.argv[1:]
maximum_bytes = int(maximum_bytes)
endpoint = os.environ["R2_ENDPOINT"].rstrip("/")
access_key = os.environ["R2_ACCESS_KEY_ID"]
secret_key = os.environ["R2_SECRET_ACCESS_KEY"]
parsed_endpoint = urllib.parse.urlsplit(endpoint)
if (
    parsed_endpoint.scheme != "https"
    or not parsed_endpoint.hostname
    or parsed_endpoint.username
    or parsed_endpoint.password
    or parsed_endpoint.query
    or parsed_endpoint.fragment
):
    raise SystemExit("R2_ENDPOINT must be an HTTPS URL")
encoded_bucket = urllib.parse.quote(bucket, safe="-_.~")
encoded_key = urllib.parse.quote(key, safe="/-_.~")
canonical_uri = (parsed_endpoint.path.rstrip("/") + "/" + encoded_bucket + "/" + encoded_key) or "/"
url = urllib.parse.urlunsplit((parsed_endpoint.scheme, parsed_endpoint.netloc, canonical_uri, "", ""))
def file_hash(path):
    digest = hashlib.sha256()
    with open(path, "rb") as source:
        for chunk in iter(lambda: source.read(4 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()
def file_chunks(path):
    with open(path, "rb") as source:
        for chunk in iter(lambda: source.read(4 * 1024 * 1024), b""):
            yield chunk
payload_hash = file_hash(file_path) if method == "PUT" else hashlib.sha256(b"").hexdigest()
now = datetime.datetime.now(datetime.timezone.utc)
amz_date = now.strftime("%Y%m%dT%H%M%SZ")
date = now.strftime("%Y%m%d")
headers = {
    "host": parsed_endpoint.netloc,
    "x-amz-content-sha256": payload_hash,
    "x-amz-date": amz_date,
}
if method == "PUT":
    headers["content-length"] = str(os.path.getsize(file_path))
    headers["content-type"] = mimetypes.guess_type(file_path)[0] or "application/octet-stream"
    headers["cache-control"] = "public, max-age=31536000, immutable" if immutable == "1" else "no-cache, max-age=0, must-revalidate"
    if immutable == "1":
        headers["if-none-match"] = "*"
canonical_headers = "".join(f"{name}:{headers[name].strip()}\n" for name in sorted(headers))
signed_headers = ";".join(sorted(headers))
scope = f"{date}/auto/s3/aws4_request"
canonical_request = f"{method}\n{canonical_uri}\n\n{canonical_headers}\n{signed_headers}\n{payload_hash}"
request_hash = hashlib.sha256(canonical_request.encode()).hexdigest()
string_to_sign = f"AWS4-HMAC-SHA256\n{amz_date}\n{scope}\n{request_hash}"
def sign(key_bytes, value):
    return hmac.new(key_bytes, value.encode(), hashlib.sha256).digest()
date_key = sign(("AWS4" + secret_key).encode(), date)
region_key = sign(date_key, "auto")
service_key = sign(region_key, "s3")
signing_key = sign(service_key, "aws4_request")
signature = hmac.new(signing_key, string_to_sign.encode(), hashlib.sha256).hexdigest()
headers["authorization"] = (
    "AWS4-HMAC-SHA256 Credential=" + access_key + "/" + scope
    + ", SignedHeaders=" + signed_headers + ", Signature=" + signature
)
request = urllib.request.Request(
    url,
    data=file_chunks(file_path) if method == "PUT" else None,
    method=method,
    headers=headers,
)
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, msg, headers, newurl):
        return None
opener = urllib.request.build_opener(NoRedirect)
try:
    with opener.open(request, timeout=60) as response:
        if method == "GET":
            written = 0
            try:
                with open(file_path, "wb") as output:
                    for chunk in iter(lambda: response.read(4 * 1024 * 1024), b""):
                        written += len(chunk)
                        if maximum_bytes > 0 and written > maximum_bytes:
                            raise RuntimeError("R2 response exceeds the expected object size")
                        output.write(chunk)
            except Exception:
                if os.path.exists(file_path):
                    os.remove(file_path)
                raise
except urllib.error.HTTPError as error:
    sys.stderr.write(f"R2 {method} {key} returned HTTP {error.code}\n")
    raise SystemExit(42 if error.code == 412 and immutable == "1" else 1)
