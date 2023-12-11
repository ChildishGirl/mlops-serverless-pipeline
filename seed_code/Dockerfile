FROM public.ecr.aws/lambda/python:3.9

ARG FILE_NAME
ENV MODEL_FILE=${FILE_NAME}
COPY requirements.txt .
RUN pip3 install -r requirements.txt --target "${LAMBDA_TASK_ROOT}"
COPY inference.py ${LAMBDA_TASK_ROOT}
COPY ${MODEL_FILE} ${LAMBDA_TASK_ROOT}/model.sav

CMD [ "inference.handler" ]
