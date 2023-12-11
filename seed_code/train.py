import io
import os
import boto3
import mlflow
import pickle
import pandas as pd
from sklearn.metrics import mean_squared_error
from sklearn.neighbors import KNeighborsClassifier
from sklearn.model_selection import train_test_split


# Create connection with MLflow server
mlflow_uri = os.environ['MLFLOW_URI']
model_name = os.environ['MODEL_NAME']
mlflow.set_tracking_uri(f'http://{mlflow_uri}')

# Create session and load data
s3_client = boto3.client('s3')
obj = s3_client.get_object(Bucket='mlops-test-data', Key='data.csv')
data = pd.read_csv(io.BytesIO(obj['Body'].read()), index_col=False)
data.drop(columns="Unnamed: 0", inplace=True)

# Data preprocessing
x_train, x_test, y_train, y_test = train_test_split(data.drop(['DELIVERY_TIME_DAYS'], axis=1),
                                                    data['DELIVERY_TIME_DAYS'],
                                                    test_size=0.3,
                                                    random_state=1,
                                                    shuffle=False)

# Model training
params = {'n_neighbors': 5, 'algorithm': 'auto', 'weights': 'distance'}
knn = KNeighborsClassifier(**params)
knn.fit(x_train, y_train)
knn_prediction = knn.predict(x_test)

with mlflow.start_run() as run:
    # Log parameters and metrics
    mlflow.log_params(params)
    mlflow.log_metrics({"mse": mean_squared_error(y_test, knn_prediction)})

    # Model registry
    model = mlflow.sklearn.log_model(sk_model=knn, artifact_path='sklearn-model', registered_model_name=model_name)

pickle.dump(knn, open(f"{model_name}.sav", 'wb'))