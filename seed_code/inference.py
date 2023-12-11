import json
import pickle
import numpy as np
import pandas as pd


# Load model
loaded_model = pickle.load(open('model.sav', 'rb'))

def handler(event, context):
    # Get features for prediction
    data = pd.DataFrame(event)

    # Make prediction
    response = int(loaded_model.predict(data)[0])
    probability = np.max(loaded_model.predict_proba(data)).item()

    return {'statusCode': 200,
            'body': json.dumps(
                {'predicted_label': response,
                 'probability': probability})}