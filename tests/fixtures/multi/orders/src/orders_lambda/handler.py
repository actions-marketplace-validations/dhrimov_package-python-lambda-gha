"""Lambda entrypoint for the orders half of the multi-lambda fixture."""

import orjson


def lambda_handler(event, context):
    """Echo the event back, serialised by the compiled dependency."""
    return {
        "statusCode": 200,
        "body": orjson.dumps({"lambda": "orders", "event": event}).decode(),
    }
