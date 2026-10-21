import gzip
import io
import sys
from datetime import date, timedelta

import boto3
import csv
import pyarrow as pa
import pyarrow.parquet as pq
from awsglue.utils import getResolvedOptions

args = getResolvedOptions(
    sys.argv, ["bucket", "database", "table", "raw_prefix", "curated_prefix"]
)
BUCKET = args["bucket"]
DATABASE = args["database"]
TABLE = args["table"]
RAW_PREFIX = args["raw_prefix"]
CURATED_PREFIX = args["curated_prefix"]

BASE_COLUMNS = [
    "customer_id", "first_name", "last_name", "email", "city",
    "state", "zip_code", "segment", "signup_date",
]
SCHEMA = pa.schema([
    ("customer_id", pa.string()), ("first_name", pa.string()),
    ("last_name", pa.string()), ("email", pa.string()),
    ("city", pa.string()), ("state", pa.string()),
    ("zip_code", pa.string()), ("segment", pa.string()),
    ("signup_date", pa.date32()), ("last_updated_date", pa.date32()),
])

s3 = boto3.client("s3")
glue = boto3.client("glue")


def decompress_if_needed(data):
    # gzip files start with the bytes 1f 8b
    if data[:2] == b"\x1f\x8b":
        return gzip.decompress(data)
    return data


def to_date(value):
    if isinstance(value, date):
        return value
    if isinstance(value, int):  # Avro date: days since 1970-01-01
        return date(1970, 1, 1) + timedelta(days=value)
    return date.fromisoformat(str(value)[:10])


def list_objects(prefix):
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=BUCKET, Prefix=prefix):
        for obj in page.get("Contents", []):
            if not obj["Key"].endswith("/"):
                yield obj


def read_existing_rows():
    # The curated table is cumulative, so start from what is already stored
    rows = {}
    for obj in list_objects(CURATED_PREFIX):
        if not obj["Key"].endswith(".parquet"):
            continue
        body = s3.get_object(Bucket=BUCKET, Key=obj["Key"])["Body"].read()
        for row in pq.read_table(io.BytesIO(body)).to_pylist():
            rows[row["customer_id"]] = row
    return rows


# def merge_incoming(merged):
#     # Oldest file first, so ties on last_updated_date go to the newer file
#     for obj in sorted(list_objects(RAW_PREFIX), key=lambda o: o["LastModified"]):
#         body = s3.get_object(Bucket=BUCKET, Key=obj["Key"])["Body"].read()
#         for record in fastavro.reader(io.BytesIO(decompress_if_needed(body))):
#             row = {c: record.get(c) for c in BASE_COLUMNS}
#             row["signup_date"] = to_date(row["signup_date"])
#             row["last_updated_date"] = to_date(
#                 record.get("last_updated_date") or record["signup_date"]
#             )
#             current = merged.get(row["customer_id"])
#             if current is None or row["last_updated_date"] >= current["last_updated_date"]:
#                 merged[row["customer_id"]] = row
#     return merged

FIELD_ORDER = BASE_COLUMNS + ["last_updated_date"]  # the tenth column is optional


def merge_incoming(merged):
    # Oldest file first, so ties on last_updated_date go to the newer file
    for obj in sorted(list_objects(RAW_PREFIX), key=lambda o: o["LastModified"]):
        body = s3.get_object(Bucket=BUCKET, Key=obj["Key"])["Body"].read()
        text = decompress_if_needed(body).decode("utf-8")
        for fields in csv.reader(io.StringIO(text)):
            if not fields or fields[0] == "customer_id":  # skip blank and header lines
                continue
            record = dict(zip(FIELD_ORDER, fields))
            row = {c: record.get(c) or None for c in BASE_COLUMNS}
            row["signup_date"] = to_date(row["signup_date"])
            row["last_updated_date"] = to_date(
                record.get("last_updated_date") or row["signup_date"]
            )
            current = merged.get(row["customer_id"])
            if current is None or row["last_updated_date"] >= current["last_updated_date"]:
                merged[row["customer_id"]] = row
    return merged


def clear_curated_prefix():
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=BUCKET, Prefix=CURATED_PREFIX):
        keys = [{"Key": o["Key"]} for o in page.get("Contents", [])]
        if keys:
            s3.delete_objects(Bucket=BUCKET, Delete={"Objects": keys})


def write_partitions(rows):
    by_month = {}
    for row in rows:
        month = row["signup_date"].strftime("%Y-%m")
        by_month.setdefault(month, []).append(row)
    for month, month_rows in sorted(by_month.items()):
        table = pa.Table.from_pylist(month_rows, schema=SCHEMA)
        buffer = io.BytesIO()
        pq.write_table(table, buffer, compression="snappy")
        key = f"{CURATED_PREFIX}signup_month={month}/part-0000.snappy.parquet"
        s3.put_object(Bucket=BUCKET, Key=key, Body=buffer.getvalue())
    return sorted(by_month)


def register_partitions(months):
    table = glue.get_table(DatabaseName=DATABASE, Name=TABLE)["Table"]
    base_sd = table["StorageDescriptor"]
    for month in months:
        sd = dict(base_sd)
        sd["Location"] = f"s3://{BUCKET}/{CURATED_PREFIX}signup_month={month}/"
        partition = {"Values": [month], "StorageDescriptor": sd}
        try:
            glue.create_partition(
                DatabaseName=DATABASE, TableName=TABLE, PartitionInput=partition
            )
        except glue.exceptions.AlreadyExistsException:
            glue.update_partition(
                DatabaseName=DATABASE, TableName=TABLE,
                PartitionValueList=[month], PartitionInput=partition,
            )


def main():
    merged = merge_incoming(read_existing_rows())
    rows = list(merged.values())
    clear_curated_prefix()
    months = write_partitions(rows)
    register_partitions(months)
    print(f"Stored {len(rows)} customers in {len(months)} monthly partitions: {months}")


main()