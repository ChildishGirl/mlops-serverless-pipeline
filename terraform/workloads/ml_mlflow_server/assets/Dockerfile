FROM python:3.9.0

RUN pip install \
    mlflow==2.0.1 \
    pymysql==1.0.2 \
    boto3 && \
    mkdir /mlflow/

EXPOSE 80

CMD mlflow server \
    --host 0.0.0.0 \
    --port 80 \
    --default-artifact-root ${BUCKET} \
    --backend-store-uri mysql+pymysql://${USERNAME}:${PASSWORD}@${HOST}:${PORT}/${DATABASE}
