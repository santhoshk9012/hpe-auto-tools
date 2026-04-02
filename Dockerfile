# Use official Python image
FROM python:3.12-slim

# Set working directory inside container
WORKDIR /app

# Copy project files into container
COPY . .

# Install dependencies
RUN pip install --no-cache-dir pytest

# Default command
CMD ["pytest", "-v"]