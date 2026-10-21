import json
import os

import boto3

sfn = boto3.client("stepfunctions")
STATE_MACHINE_ARN = os.environ["STATE_MACHINE_ARN"]
PREFIXES = ("avro_datastage_files/customers/", "avro_datastage_files/sales_orders/")


def handler(event, context):
    results = []
    for record in event["Records"]:
        key = record["s3"]["object"]["key"]
        if not key.startswith(PREFIXES):
            results.append({"key": key, "status": "ignored"})
            continue
        run = sfn.start_execution(
            stateMachineArn=STATE_MACHINE_ARN,
            input=json.dumps({"key": key}),
        )
        results.append({"key": key, "execution": run["executionArn"], "status": "started"})
    print(json.dumps(results))
    return results