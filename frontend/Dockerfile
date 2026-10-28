FROM node:24.19.0-alpine3.24 AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

# nginx-unprivileged runs as uid 101 and listens on 8080, so the container needs no root
FROM nginxinc/nginx-unprivileged:1.30.6-alpine3.24 AS runner
# Alpine security fixes released after the base image was built (Trivy found one in brotli)
USER root
RUN apk upgrade --no-cache
USER 101
COPY --from=builder /app/dist /usr/share/nginx/html
# the image entrypoint renders templates/*.template with envsubst into conf.d/ on start
COPY nginx.conf.template /etc/nginx/templates/default.conf.template
ENV BACKEND_HOST=backend \
    BACKEND_PORT=3001
EXPOSE 8080
