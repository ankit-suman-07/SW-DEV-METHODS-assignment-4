FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt && useradd --uid 10001 --create-home appuser
COPY common/transforms.py ./transforms.py
COPY filter_reading/main.py ./main.py
USER appuser
CMD ["python", "-u", "main.py"]
