"""Lambda entrypoint for the payments half of the multi-lambda fixture."""

import orjson


def lambda_handler(event, context):
    """Echo the event back, serialised by the compiled dependency."""
    return {
        "statusCode": 200,
        "body": orjson.dumps({"lambda": "payments", "event": event}).decode(),
    }
