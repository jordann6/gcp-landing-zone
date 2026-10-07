FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1
WORKDIR /srv
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY handler.py .
RUN useradd --system --uid 10001 runner
USER runner
CMD ["python", "handler.py"]
