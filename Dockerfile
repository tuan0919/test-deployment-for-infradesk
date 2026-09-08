FROM nginx:1.27-alpine
ARG APP_VERSION=latest
COPY public/ /usr/share/nginx/html/
RUN printf '{"version":"%s"}\n' "$APP_VERSION" > /usr/share/nginx/html/version.json
