# Official Python 3.12 image, pinned to the tested multi-platform manifest digest.
FROM python:3.12-slim-bookworm@sha256:935c3c5b12357a7e10caa9c1e6ca5692344d97cf229832ef584be2cec9fc03df
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY --chown=10001:10001 relay.py relay_runtime.py /app/
USER 10001:10001
EXPOSE 8787
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 CMD ["python3", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8787/health/live', timeout=2).close()"]
ENTRYPOINT ["python3", "/app/relay.py"]
CMD ["--host", "0.0.0.0", "--port", "8787"]
