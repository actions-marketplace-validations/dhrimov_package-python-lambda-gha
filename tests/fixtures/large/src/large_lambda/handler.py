"""Lambda entrypoint for the over-the-limit fixture."""

import pandas
import pyarrow
import scipy


def lambda_handler(event, context):
    """Report the versions of the dependencies that make the package large."""
    return {
        "statusCode": 200,
        "body": {
            "pandas": pandas.__version__,
            "pyarrow": pyarrow.__version__,
            "scipy": scipy.__version__,
        },
    }
