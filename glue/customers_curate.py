import io
import sys
from datetime import date

import boto3
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

COLUMNS = [
    "order_id", "order_date", "customer_id", "product_id", "product_name",
    "category", "quantity", "unit_price", "line_total",
]
SCHEMA = pa.schema([
    ("order_id", pa.string()), ("order_date", pa.date32()),
    ("customer_id", pa.string()), ("product_id", pa.string()),
    ("product_name", pa.string()), ("category", pa.string()),
    ("quantity", pa.int32()), ("unit_price", pa.decimal128(10, 2)),
    ("line_total", pa.decimal128(12, 2)), ("last_updated_date", pa.date32()),
])

s3 = boto3.client("s3")
glue = boto3.client("glue")


def list_objects(prefix):
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=BUCKET, Prefix=prefix):
        for obj in page.get("Contents", []):
            if not obj["Key"].endswith("/"):
                yield obj


def read_parquet_rows(key):
    body = s3.get_object(Bucket=BUCKET, Key=key)["Body"].read()
    return pq.read_table(io.BytesIO(body)).to_pylist()


def read_existing_rows():
    # The curated table is cumulative, so start from what is already stored
    rows = {}
    for obj in list_objects(CURATED_PREFIX):
        if not obj["Key"].endswith(".parquet"):
            continue
        for row in read_parquet_rows(obj["Key"]):
            rows[(row["order_id"], row["product_id"])] = row
    return rows


def merge_incoming(merged):
    # Oldest file first, so ties on last_updated_date go to the newer file
    for obj in sorted(list_objects(RAW_PREFIX), key=lambda o: o["LastModified"]):
        for raw in read_parquet_rows(obj["Key"]):
            row = {c: raw.get(c) for c in COLUMNS}
            # DEV source has no last_updated_date yet, so fall back to order_date
            row["last_updated_date"] = raw.get("last_updated_date") or row["order_date"]
            key = (row["order_id"], row["product_id"])
            current = merged.get(key)
            if current is None or row["last_updated_date"] >= current["last_updated_date"]:
                merged[key] = row
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
        month = row["order_date"].strftime("%Y-%m")
        by_month.setdefault(month, []).append(row)
    for month, month_rows in sorted(by_month.items()):
        table = pa.Table.from_pylist(month_rows, schema=SCHEMA)
        buffer = io.BytesIO()
        pq.write_table(table, buffer, compression="snappy")
        key = f"{CURATED_PREFIX}order_month={month}/part-0000.snappy.parquet"
        s3.put_object(Bucket=BUCKET, Key=key, Body=buffer.getvalue())
    return sorted(by_month)


def register_partitions(months):
    table = glue.get_table(DatabaseName=DATABASE, Name=TABLE)["Table"]
    base_sd = table["StorageDescriptor"]
    for month in months:
        sd = dict(base_sd)
        sd["Location"] = f"s3://{BUCKET}/{CURATED_PREFIX}order_month={month}/"
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
    print(f"Stored {len(rows)} order lines in {len(months)} monthly partitions: {months}")


main()