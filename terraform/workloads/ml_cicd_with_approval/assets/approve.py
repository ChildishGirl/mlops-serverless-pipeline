import urllib
import urllib3
import json
import os


def lambda_handler(event, context):
    # Parse event
    token = event['token']
    feature_name = os.environ['FEATURE_NAME']
    region = os.environ['REGION']
    deployment_id = os.environ['API_DEPLOYMENT_ID']

    # Send notification to Slack
    encoded_token = urllib.parse.quote_plus(token)
    approval_link = f"{deployment_id}prod/approve?taskToken={encoded_token}"
    reject_link = f"{deployment_id}prod/reject?taskToken={encoded_token}"
    _url = 'https://hooks.slack.com/services/YOUR_HOOK'

    _msg = {
        "blocks": [
            {
                "type": "section",
                "text": {
                    "type": "plain_text",
                    "text": f'🚀 New model for {feature_name} feature was deployed to stage environment. Please approve or reject deployment to production environment.',
                    "emoji": True
                }
            },
            {
                "type": "actions",
                "elements": [
                   {
                        "type": "button",
                        "text": {
                            "type": "plain_text",
                            "text": "Approve"
                        },
                        "style": "primary",
                        "url": approval_link
                   },
                   {
                        "type": "button",
                        "text": {
                            "type": "plain_text",
                            "text": "Reject"
                        },
                        "style": "danger",
                        "url": reject_link
                   }
                ]
            }
        ]
    }

    http = urllib3.PoolManager()
    resp = http.request(method='POST', url=_url, body=json.dumps(_msg).encode('utf-8'))

    return {"Response": 200}