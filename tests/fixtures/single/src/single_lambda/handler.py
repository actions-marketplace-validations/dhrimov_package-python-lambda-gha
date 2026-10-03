"""Lambda entrypoint for the single-lambda fixture."""

import orjson


def lambda_handler(event, context):
    """Echo the event back, serialised by the compiled dependency."""
    return {
        "statusCode": 200,
        "body": orjson.dumps({"event": event}).decode(),
    }
